#!/usr/bin/env bash
#
# monitor-liveness.sh RUN_DIR INTERVENTIONS_FILE RUN_ID COORDINATOR_PID
#
# Bounded, content-free liveness monitoring for one in-flight run.
#
# WHY THIS RUNS OUTSIDE THE COORDINATOR
# The skill requires bounded coordinator liveness checks every 2-5 minutes.
# Kilo's `task` tool is synchronous: while the lead subagent runs, the
# coordinator model cannot act, so it cannot heartbeat about its own lead.
# The observer therefore runs as a separate process.
#
# WHY IT IS SAFE FOR AN A/B
# It is content-free by construction. It has no channel to the coordinator or
# the lead and can only read: filesystem progress, harness session state, and
# process liveness. It cannot leak guidance into either arm, which is the
# property the content-free-nudge rule exists to protect.
#
# NOTE: `kilo run` does not expose an HTTP server (only `kilo serve` does), so
# harness state is read from the session store via `kilo session list`.

set -uo pipefail
RUN_DIR="$1"; INTERVENTIONS="$2"; RUN_ID="$3"; COORD_PID="${4:-}"
INTERVAL="${MONITOR_INTERVAL_SECONDS:-180}"

while :; do
  sleep "$INTERVAL"

  # Has the coordinator process gone? Then the run is over; stop observing.
  if [ -n "$COORD_PID" ] && ! kill -0 "$COORD_PID" 2>/dev/null; then
    exit 0
  fi

  SESSIONS="$(kilo session list 2>/dev/null | grep -v '^INFO' | grep -c '^ses_')"
  SESSION_SEEN="$(kilo session list 2>/dev/null | grep -c "$RUN_ID")"

  DETAIL="$(RUN_ID="$RUN_ID" SESSIONS="$SESSIONS" SESSION_SEEN="$SESSION_SEEN" \
            python3 - "$RUN_DIR" <<'PY' 2>/dev/null || echo '{"observed":"unavailable"}'
import json, os, sys, time, pathlib
run = pathlib.Path(sys.argv[1])

def scan(rel):
    p = run / rel
    if not p.exists():
        return 0, 0, 0.0
    files = bytes_ = 0
    newest = 0.0
    for dirpath, _dn, filenames in os.walk(p):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            try:
                st = os.stat(fp)
            except OSError:
                continue
            files += 1
            bytes_ += st.st_size
            newest = max(newest, st.st_mtime)
    return files, bytes_, newest

ws_f, ws_b, ws_t = scan("workspace")
ar_f, ar_b, ar_t = scan("artifact")
newest = max(ws_t, ar_t)

def as_int(name):
    try:
        return int((os.environ.get(name) or "0").strip() or 0)
    except ValueError:
        return 0

out = {
    "harnessReachable": as_int("SESSIONS") > 0,
    "harnessSessions": as_int("SESSIONS"),
    "runSessionVisible": as_int("SESSION_SEEN") > 0,
    "workspaceFiles": ws_f, "workspaceBytes": ws_b,
    "artifactFiles": ar_f, "artifactBytes": ar_b,
    "tmpPresent": (run / ".tmp").exists(),
    "secondsSinceLastWrite": int(time.time() - newest) if newest else None,
}
for name in ("agent.log", "stderr.log"):
    p = run / name
    out[name.replace(".", "_")] = p.stat().st_size if p.exists() else 0
print(json.dumps(out))
PY
)"

  printf '{"time":"%s","type":"heartbeat","trigger":"periodic_liveness_check","detail":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DETAIL" >> "$INTERVENTIONS"
done
