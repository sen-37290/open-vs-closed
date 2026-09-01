#!/usr/bin/env bash
#
# sandbox-exec.sh RUN_DIR -- <command and args to run inside the sandbox>
#
# Runs one experiment inside a container that can see ONLY:
#   /work/run                              this run's directory (read-write)
#   /work/.kilo/skills/oneshot-websites    the pinned skill (read-only)
#   /work/kilo.jsonc                       the pinned harness config (read-only)
#
# It cannot see sibling runs, other prompts, metadata/, README.md or
# protocol.md. Those last three name both models and describe the comparison,
# so a model performing the skill's REQUIRED write-boundary self-audit would
# otherwise stumble across the experiment design. This makes isolation
# enforced by the kernel rather than requested in a prompt.
#
# Network egress stays open: the run must reach the model provider. The API key
# is passed per-container at runtime and is never baked into the image.

set -euo pipefail

RUN_DIR="${1:?usage: sandbox-exec.sh RUN_DIR -- cmd...}"; shift
[ "${1:-}" = "--" ] && shift

EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$EXP_ROOT/.kilo/skills/oneshot-websites"
IMAGE="${SANDBOX_IMAGE:-ovc-sandbox:7.5.6}"
RUN_ID="$(basename "$RUN_DIR")"

command -v docker >/dev/null 2>&1 || { echo "sandbox: docker not found" >&2; exit 127; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "sandbox: image $IMAGE missing; build it with scripts/build-sandbox.sh" >&2; exit 127; }

# Resource caps keep one run from starving its sibling on a shared VM. These
# are host-capacity limits, not model budgets: they are identical for both arms
# and are never disclosed to the model.
# Defaults adapt to the host and to how many runs are already in flight, so
# launching a third concurrent run cannot silently overcommit memory and get a
# container OOM-killed mid-experiment (which would look like a model failure).
# Explicit SANDBOX_MEMORY / SANDBOX_CPUS always win.
detect_total_mem_gb() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}'
  else
    echo 8
  fi
}
detect_cpus() { command -v nproc >/dev/null 2>&1 && nproc || sysctl -n hw.ncpu 2>/dev/null || echo 2; }

if [ -z "${SANDBOX_MEMORY:-}" ] || [ -z "${SANDBOX_CPUS:-}" ]; then
  # NB: `grep -c` prints 0 AND exits 1 when there is no match, so `|| echo 0`
  # would emit "0\n0" and break the arithmetic below. Count with wc instead.
  _inflight="$(docker ps --filter 'name=ovc-' --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' \n')"
  [ -z "$_inflight" ] && _inflight=0
  _slots=$(( _inflight + 1 ))
  _totmem="$(detect_total_mem_gb)"; _totcpu="$(detect_cpus)"
  # leave ~20% of RAM for the host and the harness itself
  _mem=$(( (_totmem * 80 / 100) / _slots )); [ "$_mem" -lt 2 ] && _mem=2
  _cpu=$(( _totcpu / _slots )); [ "$_cpu" -lt 1 ] && _cpu=1
fi
MEM="${SANDBOX_MEMORY:-${_mem:-4}g}"
CPUS="${SANDBOX_CPUS:-${_cpu:-2}}"
PIDS="${SANDBOX_PIDS:-2048}"
echo "sandbox: mem=$MEM cpus=$CPUS (host ${_totmem:-?}GB/${_totcpu:-?}cpu, ${_inflight:-0} run(s) already in flight)" >&2

# Run as the HOST user. The run directory is a bind mount owned by the host
# user, so the container's own uid could not write to it -- every run would fail
# at the first file write.
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

# Per-run HOME, inside the run directory. Two reasons this is not incidental:
#   1. Isolation. Kilo keeps its session store under HOME. A shared HOME would
#      let any sandboxed run call `kilo session list` and read SIBLING RUNS'
#      sessions -- defeating the point of the sandbox.
#   2. The session store, which holds every subagent trajectory, is then
#      preserved per run instead of accumulating in one multi-gigabyte global
#      database.
# Telemetry on the host must read this same HOME (see run-one.sh).
KILO_HOME="$RUN_DIR/.kilo-home"
mkdir -p "$KILO_HOME" "$RUN_DIR/.harness-tmp"

# The skill's run-layout contract, which the sandbox must not break:
#   * cleanup_run_tmp.py derives the expected identity from the run DIRECTORY
#     NAME and requires it to equal run.json.runId. Mounting at a generic path
#     like /work/run makes the basename "run" and the cleanup gate fails, so a
#     run can never reach OK.
#   * It also requires the run's PARENT to contain .oneshot-provenance/ with
#     this run's receipt and its empty .commit marker.
# So the run is mounted under its real name inside a minimal output root, and
# only THIS run's two provenance files are exposed -- never the whole receipt
# inventory, which would reveal every sibling run.
RUNS_ROOT="$(cd "$(dirname "$RUN_DIR")" && pwd)"
PROV="$RUNS_ROOT/.oneshot-provenance"
PROV_MOUNTS=""
for suffix in json commit; do
  f="$PROV/$RUN_ID.$suffix"
  [ -e "$f" ] && PROV_MOUNTS="$PROV_MOUNTS -v $f:/work/runs/.oneshot-provenance/$RUN_ID.$suffix:ro"
done

exec docker run --rm \
  --name "ovc-$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-100)" \
  --user "$HOST_UID:$HOST_GID" \
  --memory "$MEM" --cpus "$CPUS" --pids-limit "$PIDS" \
  --security-opt no-new-privileges \
  -v "$RUN_DIR:/work/runs/$RUN_ID" \
  $PROV_MOUNTS \
  -v "$SKILL_DIR:/work/.kilo/skills/oneshot-websites:ro" \
  -v "$EXP_ROOT/kilo.jsonc:/work/kilo.jsonc:ro" \
  -e OPENROUTER_API_KEY \
  -e KILO_CONFIG_CONTENT \
  -e ONESHOT_WEBSITES_PYTHON=/usr/bin/python3 \
  -e ONESHOT_WEBSITES_BROWSER=/usr/bin/chromium \
  -e TMPDIR=/work/runs/$RUN_ID/.harness-tmp \
  -e TMP=/work/runs/$RUN_ID/.harness-tmp \
  -e TEMP=/work/runs/$RUN_ID/.harness-tmp \
  -e HOME=/work/runs/$RUN_ID/.kilo-home \
  -e XDG_CONFIG_HOME=/work/runs/$RUN_ID/.kilo-home/.config \
  -e XDG_DATA_HOME=/work/runs/$RUN_ID/.kilo-home/.local/share \
  -e npm_config_cache=/work/runs/$RUN_ID/.harness-tmp/npm \
  -w /work \
  "$IMAGE" \
  "$@"
