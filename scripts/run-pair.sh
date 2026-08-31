#!/usr/bin/env bash
#
# run-pair.sh PROMPT_FILE
#
# Launches the GLM-5.3 arm and the Fable 5 arm at approximately the same time,
# in completely separate run directories, on byte-identical prompt bytes.
# Waits for both. Reports each arm's run ID and status. Never retries either.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ---------------------------------------------------------------------------
# EDIT-SAFETY: the entire body lives inside main(), invoked as `main "$@"` on
# the last line. Bash reads a script incrementally by byte offset, so editing a
# plain script while a long run is executing it makes the running shell resume
# at a shifted offset and re-execute arbitrary blocks. Bash parses a complete
# function definition before executing it, so wrapping the body makes an
# in-flight run immune to edits of this file.
# ---------------------------------------------------------------------------
main() {

[ $# -ge 1 ] || die "usage: run-pair.sh PROMPT_FILE"
PROMPT_FILE_IN="$1"
load_config
ensure_python || die "no Python >= 3.11 available for the skill helpers"

case "$PROMPT_FILE_IN" in
  /*) PROMPT_FILE="$PROMPT_FILE_IN" ;;
  *)  PROMPT_FILE="$EXP_ROOT/$PROMPT_FILE_IN" ;;
esac
[ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE"

PAIR_SHA="$(prompt_digest "$PROMPT_FILE")" || die "prompt failed the strict UTF-8 seal check"
PAIR_ID="pair-$(date -u +%Y%m%d-%H%M%S)-$(basename "$PROMPT_FILE" .md)"
PAIR_DIR="$METADATA_ROOT/$PAIR_ID"
mkdir -p "$PAIR_DIR"

# Prove, before anything is dispatched, that both arms are keyed to one digest.
cat > "$PAIR_DIR/pair.json" <<JSON
{
  "pairId": "$PAIR_ID",
  "promptFile": "$PROMPT_FILE",
  "promptSha256": "$PAIR_SHA",
  "startedAt": "$(now_iso)",
  "arms": ["glm-5.3", "fable-5"],
  "coordinatorModel": "$COORDINATOR_MODEL",
  "criticModel": "$CRITIC_MODEL",
  "timeoutSeconds": $RUN_TIMEOUT_SECONDS,
  "retryPolicy": "none"
}
JSON
log "pair $PAIR_ID  prompt sha256=$PAIR_SHA"

GLM_OUT="$PAIR_DIR/glm-5.3.out"
FABLE_OUT="$PAIR_DIR/fable-5.out"

"$EXP_ROOT/scripts/run-one.sh" glm-5.3 "$PROMPT_FILE" > "$GLM_OUT" 2>&1 &
GLM_PID=$!
"$EXP_ROOT/scripts/run-one.sh" fable-5 "$PROMPT_FILE" > "$FABLE_OUT" 2>&1 &
FABLE_PID=$!
log "dispatched both arms (glm pid=$GLM_PID, fable pid=$FABLE_PID); waiting"

GLM_RC=0;   wait "$GLM_PID"   || GLM_RC=$?
FABLE_RC=0; wait "$FABLE_PID" || FABLE_RC=$?

arm_field() { grep -E "^$2:" "$1" 2>/dev/null | tail -1 | sed "s/^$2:[[:space:]]*//"; }

GLM_RUN="$(arm_field "$GLM_OUT" run_id)";     GLM_STATUS="$(arm_field "$GLM_OUT" status)"
FABLE_RUN="$(arm_field "$FABLE_OUT" run_id)"; FABLE_STATUS="$(arm_field "$FABLE_OUT" status)"

"$ONESHOT_WEBSITES_PYTHON" - "$PAIR_DIR/pair.json" \
  "$GLM_RUN" "${GLM_STATUS:-UNKNOWN}" "$GLM_RC" \
  "$FABLE_RUN" "${FABLE_STATUS:-UNKNOWN}" "$FABLE_RC" "$(now_iso)" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["finishedAt"] = sys.argv[8]
d["results"] = {
    "glm-5.3":  {"runId": sys.argv[2] or None, "status": sys.argv[3], "exitCode": int(sys.argv[4])},
    "fable-5":  {"runId": sys.argv[5] or None, "status": sys.argv[6], "exitCode": int(sys.argv[7])},
}
p.write_text(json.dumps(d, indent=2) + "\n")
PY

# Independently re-verify that both arms really did seal the same bytes.
verify_seal() {
  local rid="$1"
  [ -n "$rid" ] && [ -f "$RUNS_ROOT/$rid/artifact/PROMPT.md" ] \
    && file_sha256 "$RUNS_ROOT/$rid/artifact/PROMPT.md" || echo "MISSING"
}
GLM_SEAL="$(verify_seal "$GLM_RUN")"; FABLE_SEAL="$(verify_seal "$FABLE_RUN")"

echo
echo "=========================== PAIR RESULT ==========================="
echo "pair_id:     $PAIR_ID"
echo "prompt:      $PROMPT_FILE"
echo "prompt_sha:  $PAIR_SHA"
echo "-------------------------------------------------------------------"
printf '%-10s %-46s %-9s %s\n' "ARM" "RUN_ID" "STATUS" "SEAL"
printf '%-10s %-46s %-9s %s\n' "glm-5.3"  "${GLM_RUN:-<none>}"   "${GLM_STATUS:-UNKNOWN}"   "$([ "$GLM_SEAL" = "$PAIR_SHA" ] && echo MATCH || echo "$GLM_SEAL")"
printf '%-10s %-46s %-9s %s\n' "fable-5"  "${FABLE_RUN:-<none>}" "${FABLE_STATUS:-UNKNOWN}" "$([ "$FABLE_SEAL" = "$PAIR_SHA" ] && echo MATCH || echo "$FABLE_SEAL")"
echo "-------------------------------------------------------------------"
echo "pair record: $PAIR_DIR/pair.json"
echo "no retries were performed; failed arms are preserved as failures"
echo "==================================================================="
}

main "$@"
