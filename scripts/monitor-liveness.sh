#!/usr/bin/env bash
#
# monitor-liveness.sh PORT RUN_DIR INTERVENTIONS_FILE
#
# Bounded, content-free liveness monitoring for one in-flight run.
#
# The skill requires the coordinator to perform bounded liveness checks every
# 2-5 minutes. Kilo's `task` tool is synchronous: while the lead subagent runs,
# the coordinator model cannot act. So the liveness observer runs OUTSIDE the
# coordinator session and reads that session's live state from the harness's
# own HTTP server. It is content-free by construction: it only reads status and
# appends heartbeat records. It never sends anything to the coordinator or the
# lead, so it cannot leak guidance into either arm.
#
# Interval is fixed at 180s (mid-band) and identical for both arms.

set -uo pipefail
PORT="$1"; RUN_DIR="$2"; INTERVENTIONS="$3"
INTERVAL="${MONITOR_INTERVAL_SECONDS:-180}"
BASE="http://127.0.0.1:$PORT"

hb() {
  printf '{"time":"%s","type":"heartbeat","trigger":"periodic_liveness_check","detail":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$INTERVENTIONS"
}

# Wait for the harness server to come up before the first heartbeat.
for _ in $(seq 1 60); do
  curl -sf -m 3 "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 2
done

while :; do
  sleep "$INTERVAL"

  ACTIVE="$(curl -sf -m 8 "$BASE/api/session/active" 2>/dev/null || echo '')"
  SESSIONS="$(curl -sf -m 8 "$BASE/api/session" 2>/dev/null || echo '')"

  DETAIL="$(ACTIVE_JSON="$ACTIVE" SESSIONS_JSON="$SESSIONS" python3 - "$RUN_DIR" <<PY 2>/dev/null || echo '{"observed":"unavailable"}'
import json, os, sys, subprocess, pathlib
run = pathlib.Path(sys.argv[1])

def newest(rel):
    p = run / rel
    if not p.exists():
        return None
    newest_t = 0.0
    for dirpath, _dirnames, filenames in os.walk(p):
        for f in filenames:
            try:
                newest_t = max(newest_t, os.path.getmtime(os.path.join(dirpath, f)))
            except OSError:
                pass
    return newest_t or None

def count(rel):
    p = run / rel
    if not p.exists():
        return 0
    return sum(len(fs) for _d, _dn, fs in os.walk(p))

active_raw = os.environ.get("ACTIVE_JSON", "")
sessions_raw = os.environ.get("SESSIONS_JSON", "")
out = {
    "harnessReachable": bool(sessions_raw),
    "workspaceFiles": count("workspace"),
    "artifactFiles": count("artifact"),
    "tmpPresent": (run / ".tmp").exists(),
}
for key, raw in (("activeSessions", active_raw), ("sessions", sessions_raw)):
    try:
        d = json.loads(raw)
        out[key] = len(d) if isinstance(d, list) else 1
    except Exception:
        out[key] = None
try:
    d = json.loads(sessions_raw)
    if isinstance(d, list) and d:
        tot = {"input": 0, "output": 0}
        cost = 0.0
        for s in d:
            t = (s or {}).get("tokens") or {}
            tot["input"] += t.get("input") or 0
            tot["output"] += t.get("output") or 0
            cost += (s or {}).get("cost") or 0
        out["tokens"] = tot
        out["cost"] = cost
except Exception:
    pass
newest_ws = newest("workspace") or 0
newest_ar = newest("artifact") or 0
import time
out["secondsSinceLastWrite"] = int(time.time() - max(newest_ws, newest_ar)) if max(newest_ws, newest_ar) else None
print(json.dumps(out))
PY
)"
  hb "$DETAIL"

  # Stop once the harness server is gone (the coordinator process has exited).
  curl -sf -m 3 "$BASE/api/health" >/dev/null 2>&1 || exit 0
done
