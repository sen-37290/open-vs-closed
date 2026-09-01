#!/usr/bin/env bash
#
# export-trajectory.sh RUN_DIR [OUT_DIR]
#
# Export the complete trajectory of a run: the top-level session AND every
# descendant session the model spawned.
#
# Why this is needed: agent.log holds only the TOP-LEVEL session. When a model
# delegates, the descendant runs in its own harness session and only its final
# result comes back to the parent log. Those descendant trajectories live in
# ~/.local/share/kilo/kilo.db, outside the run directory -- so copying runs/
# alone does not preserve them.
#
# Writes, per session: <id>.json (raw) and <id>.txt (readable transcript).

set -uo pipefail
RUN_DIR="${1:?usage: export-trajectory.sh RUN_DIR [OUT_DIR]}"
RUN_ID="$(basename "$RUN_DIR")"
EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-$EXP_ROOT/trajectories/$RUN_ID}"
mkdir -p "$OUT"

PY="${ONESHOT_WEBSITES_PYTHON:-python3}"

# A sandboxed run keeps its Kilo session store inside the run directory, so the
# subagent trajectories live there rather than in the operator's HOME.
if [ -d "$RUN_DIR/.kilo-home" ]; then
  export HOME="$RUN_DIR/.kilo-home"
  export XDG_DATA_HOME="$RUN_DIR/.kilo-home/.local/share"
  export XDG_CONFIG_HOME="$RUN_DIR/.kilo-home/.config"
  echo "note: reading this run's own sandboxed session store"
fi

# top-level session: match by the title run-one.sh set (--title "$RUN_ID")
TOP="$(kilo session list 2>/dev/null | grep -v '^INFO' | grep -F "$RUN_ID" | awk '{print $1}' | head -1)"

# descendants recorded by the model in its own report
DESC="$("$PY" -c "
import json,sys
try:
    w=json.load(open('$RUN_DIR/worker-report.json'))
except Exception: sys.exit()
ids=[w.get('leadWorkerId')]+(w.get('descendantWorkerIds') or [])
print(' '.join(sorted({i for i in ids if i})))
" 2>/dev/null)"

echo "run:  $RUN_ID"
echo "top:  ${TOP:-<not found>}"
echo "desc: ${DESC:-<none>}"
echo

for sid in $TOP $DESC; do
  [ -n "$sid" ] || continue
  if ! kilo export "$sid" > "$OUT/$sid.json" 2>/dev/null || [ ! -s "$OUT/$sid.json" ]; then
    echo "  MISSING  $sid (not in the session store)"; rm -f "$OUT/$sid.json"; continue
  fi
  "$PY" - "$OUT/$sid.json" "$OUT/$sid.txt" <<'PYEOF'
import json, sys, datetime, pathlib
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src)); info = d.get("info") or {}
out = []
mdl = info.get("model") or {}
out.append(f"SESSION {info.get('id')}")
out.append(f"title   {info.get('title')}")
out.append(f"model   {mdl.get('providerID')}/{mdl.get('id')}")
out.append(f"tokens  {info.get('tokens')}")
out.append(f"cost    {info.get('cost')}")
out.append("=" * 100)
for m in d.get("messages") or []:
    mi = m.get("info") or {}
    ts = mi.get("time", {}).get("created")
    when = datetime.datetime.fromtimestamp(ts/1000, datetime.timezone.utc).strftime("%H:%M:%SZ") if ts else "?"
    err = mi.get("error")
    out.append(f"\n[{when}] {str(mi.get('role','?')).upper()}"
               f"{'  model=' + str(mi.get('modelID')) if mi.get('modelID') else ''}"
               f"{'  ERROR=' + json.dumps(err)[:120] if err else ''}")
    for p in m.get("parts") or []:
        t = p.get("type")
        if t == "text" and p.get("text"):
            out.append("  TEXT: " + p["text"].strip()[:4000])
        elif t == "reasoning" and p.get("text"):
            out.append("  THINK: " + p["text"].strip()[:2000])
        elif t == "tool":
            st = p.get("state") or {}
            inp = st.get("input") or {}
            desc = inp.get("description") or inp.get("command") or inp.get("filePath") or ""
            out.append(f"  TOOL[{p.get('tool')}] {st.get('status')}: {str(desc)[:300]}")
            o = st.get("output")
            if o: out.append("    -> " + str(o).strip()[:800])
pathlib.Path(dst).write_text("\n".join(out), encoding="utf-8")
PYEOF
  printf "  ok  %s  (%s raw, %s readable)\n" "$sid" \
    "$(du -h "$OUT/$sid.json" | awk '{print $1}')" "$(du -h "$OUT/$sid.txt" | awk '{print $1}')"
done
echo
echo "exported to: $OUT"
