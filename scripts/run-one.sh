#!/usr/bin/env bash
#
# run-one.sh — execute ONE autonomous one-shot website run for ONE model arm.
#
#   ./scripts/run-one.sh MODEL_ALIAS PROMPT_FILE [RUN_LABEL]
#   ./scripts/run-one.sh glm-5.3 prompts/pilot.md
#
# Never retries. A failed run is preserved as a failed run.

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

# ---------------------------------------------------------------- 1. arguments
[ $# -ge 2 ] || die "usage: run-one.sh MODEL_ALIAS PROMPT_FILE [RUN_LABEL]"
MODEL_ALIAS="$1"
PROMPT_FILE_IN="$2"
RUN_LABEL="${3:-}"

load_config
ensure_python || die "no Python >= 3.11 found for the oneshot-websites helpers; set ONESHOT_WEBSITES_PYTHON"

command -v kilo >/dev/null 2>&1 || die "kilo CLI not found on PATH"
command -v caffeinate >/dev/null 2>&1 || warn "caffeinate not found; a host sleep mid-run will corrupt wall-clock measurement"

case "$PROMPT_FILE_IN" in
  /*) PROMPT_FILE="$PROMPT_FILE_IN" ;;
  *)  PROMPT_FILE="$EXP_ROOT/$PROMPT_FILE_IN" ;;
esac
[ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE"
[ -d "$SKILL_DIR" ]   || die "pinned skill not found at $SKILL_DIR"
[ -n "${OPENROUTER_API_KEY:-}" ] || die "OPENROUTER_API_KEY is not set (put it in experiment-config/models.env, which is gitignored)"

LEAD_MODEL="$(resolve_model "$MODEL_ALIAS")"
assert_model_visible "$LEAD_MODEL"
assert_model_visible "$COORDINATOR_MODEL"
assert_model_visible "$CRITIC_MODEL"

EXPERIMENT_LABEL="${RUN_LABEL:-$EXPERIMENT_NAME-$MODEL_ALIAS-$(basename "$PROMPT_FILE" .md)}"

# ------------------------------------------------------------ 2. seal + digest
PROMPT_SHA="$(prompt_digest "$PROMPT_FILE")" || die "prompt failed the strict UTF-8 seal check"
log "prompt sealed: sha256=$PROMPT_SHA  file=$PROMPT_FILE"

# ------------------------------------------------------------- 3. reserve run
mkdir -p "$RUNS_ROOT" "$METADATA_ROOT"
PREPARE_JSON="$("$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/prepare_run.py" \
  --output-root "$RUNS_ROOT" \
  --model "$LEAD_MODEL" \
  --harness "$HARNESS_NAME" \
  --experiment "$EXPERIMENT_LABEL" \
  --prompt-file "$PROMPT_FILE")" || die "prepare_run.py failed; no run was reserved"

RUN_DIR="$("$ONESHOT_WEBSITES_PYTHON" -c 'import json,sys; print(json.loads(sys.argv[1])["runDirectory"])' "$PREPARE_JSON")"
RUN_ID="$(basename "$RUN_DIR")"
log "run reserved: $RUN_DIR"

STATUS_FILE="$RUN_DIR/status.txt"
META_FILE="$RUN_DIR/metadata.json"
AGENT_LOG="$RUN_DIR/agent.log"
STDERR_LOG="$RUN_DIR/stderr.log"
INTERVENTIONS="$RUN_DIR/interventions.jsonl"
NORMALIZE_LOG="$RUN_DIR/record-normalizations.jsonl"
: > "$INTERVENTIONS"

record_intervention() {
  printf '{"time":"%s","type":"%s","trigger":"%s","detail":"%s"}\n' \
    "$(now_iso)" "$1" "$2" "${3:-}" >> "$INTERVENTIONS"
}
record_intervention "run_reserved" "harness" "$RUN_ID"

# ------------------------------------------------- 4. verify the sealed digest
SEALED_SHA="$(file_sha256 "$RUN_DIR/artifact/PROMPT.md")"
if [ "$SEALED_SHA" != "$PROMPT_SHA" ]; then
  record_intervention "seal_mismatch" "digest_check" "$SEALED_SHA != $PROMPT_SHA"
  echo "ERROR" > "$STATUS_FILE"
  die "sealed prompt digest mismatch — run $RUN_ID preserved as failed, nothing dispatched"
fi
log "sealed digest verified"

# -------------------------------------------------------- failure-safe trap
START_ISO="$(now_iso)"; START_EPOCH="$(epoch)"
EXIT_CODE=""; TIMEOUT_HIT=0; MONITOR_PID=""

NORMALIZED=0
normalize_records() {
  [ "$NORMALIZED" = "1" ] && return 0
  NORMALIZED=1
  "$ONESHOT_WEBSITES_PYTHON" "$EXP_ROOT/scripts/normalize-records.py" \
    --run-dir "$RUN_DIR" --log "$NORMALIZE_LOG" --timeout-hit "$TIMEOUT_HIT" \
    >/dev/null 2>>"$STDERR_LOG" || warn "normalize-records.py reported a problem"
}

finalize_metadata() {
  local rc="$1"
  local end_iso end_epoch wall
  end_iso="$(now_iso)"; end_epoch="$(epoch)"; wall=$((end_epoch - START_EPOCH))
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null || true

  # A run killed or crashed before writing a terminal status must still land on
  # one. normalize-records.py turns a stranded PLANNED/RUNNING into ERROR and
  # logs why. Without this an aborted run keeps a non-terminal status forever.
  normalize_records

  ONESHOT_WEBSITES_PYTHON="$ONESHOT_WEBSITES_PYTHON" \
  "$ONESHOT_WEBSITES_PYTHON" "$EXP_ROOT/scripts/assemble_metadata.py" \
    --run-dir "$RUN_DIR" \
    --run-id "$RUN_ID" \
    --model-alias "$MODEL_ALIAS" \
    --provider "${LEAD_MODEL%%/*}" \
    --exact-model-id "$LEAD_MODEL" \
    --coordinator-model "$COORDINATOR_MODEL" \
    --critic-model "$CRITIC_MODEL" \
    --prompt-file "$PROMPT_FILE" \
    --prompt-hash "$PROMPT_SHA" \
    --start-time "$START_ISO" \
    --end-time "$end_iso" \
    --wall-clock-seconds "$wall" \
    --exit-code "$rc" \
    --harness-name "$HARNESS_NAME" \
    --harness-version "${HARNESS_VERSION:-unknown}" \
    --skill-commit "${SKILL_COMMIT:-unknown}" \
    --skill-version "${SKILL_VERSION:-unknown}" \
    --git-commit "${GIT_COMMIT:-unknown}" \
    --timeout-seconds "$RUN_TIMEOUT_SECONDS" \
    --timeout-hit "$TIMEOUT_HIT" \
    --kilo-session-file "$RUN_DIR/.session-id" \
    >/dev/null 2>>"$STDERR_LOG" || warn "metadata assembly reported a problem (see stderr.log)"

  "$ONESHOT_WEBSITES_PYTHON" - "$RUN_DIR" <<'PY' > "$STATUS_FILE" 2>/dev/null || echo "ERROR" > "$STATUS_FILE"
import json, pathlib, sys
run = pathlib.Path(sys.argv[1])
try:
    print(json.loads((run / "run.json").read_text())["status"])
except Exception:
    print("ERROR")
PY
  log "status: $(cat "$STATUS_FILE")  wall_clock=${wall}s  run=$RUN_DIR"
}

on_signal() {
  local sig="$1"
  record_intervention "signal" "received_sig$sig" "run terminated by signal"
  EXIT_CODE=$((128 + $2))
  finalize_metadata "$EXIT_CODE" || true
  exit "$EXIT_CODE"
}
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2'  INT

on_exit() {
  local rc=$?
  if [ -z "$EXIT_CODE" ]; then
    record_intervention "harness_abort" "nonzero_exit_before_completion" "rc=$rc"
    finalize_metadata "$rc" || true
  fi
  exit "$rc"
}
trap on_exit EXIT

# -------------------------------------------------------- provenance snapshot
SKILL_COMMIT="$(cat "$EXP_ROOT/experiment-config/SKILL_COMMIT.txt" 2>/dev/null || echo unknown)"
SKILL_VERSION="$("$ONESHOT_WEBSITES_PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$SKILL_DIR/metadata.json" 2>/dev/null || echo unknown)"
HARNESS_VERSION="$(kilo --version 2>/dev/null | grep -v '^INFO' | head -1 | tr -d '[:space:]')"
GIT_COMMIT="$(git -C "$EXP_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
export SKILL_COMMIT SKILL_VERSION HARNESS_VERSION GIT_COMMIT

# --------------------------------------------------------- 5. build the brief
BRIEF="$RUN_DIR/.tmp/coordinator-brief.md"
mkdir -p "$RUN_DIR/.tmp"
"$ONESHOT_WEBSITES_PYTHON" - \
  "$EXP_ROOT/experiment-config/coordinator-brief.template.md" "$BRIEF" \
  "$RUN_DIR" "$RUN_ID" "$LEAD_MODEL" "$CRITIC_MODEL" "$HARNESS_NAME" \
  "$EXPERIMENT_LABEL" "$PROMPT_SHA" "$SKILL_DIR" "$ONESHOT_WEBSITES_PYTHON" "$RUNS_ROOT" <<'PY'
import pathlib, sys
tpl, out, run_dir, run_id, lead, critic, harness, exp, sha, skill, py, runs_root = sys.argv[1:13]
text = pathlib.Path(tpl).read_text(encoding="utf-8")
for k, v in {
    "@@RUN_DIR@@": run_dir, "@@RUN_ID@@": run_id, "@@LEAD_MODEL@@": lead,
    "@@CRITIC_MODEL@@": critic, "@@HARNESS@@": harness, "@@EXPERIMENT@@": exp,
    "@@PROMPT_SHA256@@": sha, "@@SKILL_DIR@@": skill, "@@PY@@": py,
    "@@RUNS_ROOT@@": runs_root,
}.items():
    text = text.replace(k, v)
assert "@@" not in text, "unsubstituted placeholder remains in coordinator brief"
pathlib.Path(out).write_text(text, encoding="utf-8")
PY

# ------------------------------------------------- 6. launch the coordinator
# Per-run override of the LEAD model only. The coordinator, the critic, the
# permissions and every other harness setting come from the pinned kilo.jsonc.
KILO_CONFIG_CONTENT="$("$ONESHOT_WEBSITES_PYTHON" -c '
import json,sys
print(json.dumps({"agent":{
  "oneshot-lead":{"model":sys.argv[1]},
  "oneshot-critic":{"model":sys.argv[2]},
}}))' "$LEAD_MODEL" "$CRITIC_MODEL")"
export KILO_CONFIG_CONTENT

export TMPDIR="$RUN_DIR/.tmp" TMP="$RUN_DIR/.tmp" TEMP="$RUN_DIR/.tmp"

log "launching coordinator: coordinator=$COORDINATOR_MODEL lead=$LEAD_MODEL critic=$CRITIC_MODEL timeout=${RUN_TIMEOUT_SECONDS}s"
record_intervention "dispatch" "coordinator_launch" "lead=$LEAD_MODEL"

# External bounded liveness monitor (content-free: it only observes).
"$EXP_ROOT/scripts/monitor-liveness.sh" "$RUN_DIR" "$INTERVENTIONS" "$RUN_ID" "$$" \
  >>"$STDERR_LOG" 2>&1 &
MONITOR_PID=$!

KEEPAWAKE=""
command -v caffeinate >/dev/null 2>&1 && KEEPAWAKE="caffeinate -i -m -s"

set +e
run_with_timeout "$RUN_TIMEOUT_SECONDS" \
  $KEEPAWAKE kilo run \
    --auto \
    --agent code \
    --model "$COORDINATOR_MODEL" \
    --format json \
    --title "$RUN_ID" \
    "$(cat "$BRIEF")" \
  >"$AGENT_LOG" 2>"$STDERR_LOG"
EXIT_CODE=$?
set -e

kill "$MONITOR_PID" 2>/dev/null || true; MONITOR_PID=""

if [ "$TIMEOUT_HIT" = "1" ]; then
  record_intervention "timeout_kill" "wall_clock_budget_exhausted" "${RUN_TIMEOUT_SECONDS}s"
  log "TIMEOUT after ${RUN_TIMEOUT_SECONDS}s — terminated, preserved as failed, NOT retried"
fi
log "coordinator exited: rc=$EXIT_CODE"

# Capture the coordinator session id for telemetry.
grep -o 'ses_[A-Za-z0-9]\{20,\}' "$AGENT_LOG" 2>/dev/null | head -1 > "$RUN_DIR/.session-id" || true

# ------------------------------------------------------ 7. verify finalization
record_intervention "finalization_check" "post_exit" ""
normalize_records

# ----------------------------------------- 8. catalogue validate + rebuild
set +e
"$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/validate_catalog.py" "$RUNS_ROOT" \
  > "$RUN_DIR/catalog-validate.txt" 2>&1
CATALOG_RC=$?
"$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/build_catalog_index.py" "$RUNS_ROOT" \
  >> "$RUN_DIR/catalog-validate.txt" 2>&1
set -e
log "catalogue validate rc=$CATALOG_RC (details: $RUN_DIR/catalog-validate.txt)"

# ------------------------------------------------------------- 9. metadata
finalize_metadata "$EXIT_CODE"

echo
echo "run_id:   $RUN_ID"
echo "run_dir:  $RUN_DIR"
echo "arm:      $MODEL_ALIAS ($LEAD_MODEL)"
echo "status:   $(cat "$STATUS_FILE")"
echo "metadata: $META_FILE"
exit 0
}

main "$@"
