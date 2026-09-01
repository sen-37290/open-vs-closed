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
MEM="${SANDBOX_MEMORY:-12g}"
CPUS="${SANDBOX_CPUS:-3}"
PIDS="${SANDBOX_PIDS:-2048}"

exec docker run --rm \
  --name "ovc-$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-100)" \
  --memory "$MEM" --cpus "$CPUS" --pids-limit "$PIDS" \
  --security-opt no-new-privileges \
  -v "$RUN_DIR:/work/run" \
  -v "$SKILL_DIR:/work/.kilo/skills/oneshot-websites:ro" \
  -v "$EXP_ROOT/kilo.jsonc:/work/kilo.jsonc:ro" \
  -e OPENROUTER_API_KEY \
  -e KILO_CONFIG_CONTENT \
  -e ONESHOT_WEBSITES_PYTHON=/usr/bin/python3 \
  -e ONESHOT_WEBSITES_BROWSER=/usr/bin/chromium \
  -e TMPDIR=/work/run/.harness-tmp \
  -e TMP=/work/run/.harness-tmp \
  -e TEMP=/work/run/.harness-tmp \
  -e HOME=/home/runner \
  -w /work \
  "$IMAGE" \
  "$@"
