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
if ! command -v caffeinate >/dev/null 2>&1 && [ "$(uname -s)" != "Linux" ]; then
  warn "caffeinate not found; a host sleep mid-run will corrupt wall-clock measurement"
fi

case "$PROMPT_FILE_IN" in
  /*) PROMPT_FILE="$PROMPT_FILE_IN" ;;
  *)  PROMPT_FILE="$EXP_ROOT/$PROMPT_FILE_IN" ;;
esac
[ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE"
[ -d "$SKILL_DIR" ]   || die "pinned skill not found at $SKILL_DIR"
[ -n "${OPENROUTER_API_KEY:-}" ] || die "OPENROUTER_API_KEY is not set (put it in experiment-config/models.env, which is gitignored)"

# ONE model for the whole run: the session, and every subagent it chooses to
# spawn at any depth, all run on this. Nothing else is pinned.
RUN_MODEL="$(resolve_model "$MODEL_ALIAS")"
assert_model_visible "$RUN_MODEL"

if [ -n "${COORDINATOR_MODEL:-}" ] || [ -n "${CRITIC_MODEL:-}" ]; then
  warn "COORDINATOR_MODEL / CRITIC_MODEL are set but IGNORED: this experiment runs one model per run. You can delete those lines from models.env."
fi

EXPERIMENT_LABEL="${RUN_LABEL:-$EXPERIMENT_NAME-$MODEL_ALIAS-$(basename "$PROMPT_FILE" .md)}"

# ------------------------------------------------------------ 2. seal + digest
PROMPT_SHA="$(prompt_digest "$PROMPT_FILE")" || die "prompt failed the strict UTF-8 seal check"
log "prompt sealed: sha256=$PROMPT_SHA  file=$PROMPT_FILE"

# ------------------------------------------------ 2b. locate prompt materials
# Convention: a prompt may live in its own directory alongside binary inputs
# (screenshots, logos, data files). Every sibling of the prompt file, plus the
# contents of any sibling .zip, becomes that run's materials.
#
# Materials are NOT part of the sealed prompt: PROMPT.md stays exactly the text
# the operator wrote. They are staged into the run directory and described to
# the model through the operational brief, so the sealed bytes remain identical
# across arms while every arm still receives byte-identical inputs -- which the
# materials manifest proves.
PROMPT_DIR="$(cd "$(dirname "$PROMPT_FILE")" && pwd)"
MATERIALS_SRC=""
if [ "$PROMPT_DIR" != "$EXP_ROOT/prompts" ]; then
  MATERIALS_SRC="$PROMPT_DIR"
fi

# Per-arm materials. A subdirectory named for-<alias> is supplied ONLY to that
# arm; every other sibling is shared by all arms.
#
# This exists because a source document can be unreadable to one model and
# native to another: Kilo refuses a PDF for a model that does not declare file
# input ("Cannot read pdf"), so an arm would fail before starting rather than
# attempt the task. Giving each arm the same source in a form it can consume
# measures the actual task instead of the file format.
#
# The cost is real and is recorded: arms no longer receive byte-identical
# materials, so materialsCombinedSha256 legitimately differs between them.
MATERIALS_ARM_DIR=""
if [ -n "$MATERIALS_SRC" ] && [ -d "$MATERIALS_SRC/for-$MODEL_ALIAS" ]; then
  MATERIALS_ARM_DIR="$MATERIALS_SRC/for-$MODEL_ALIAS"
fi

# ------------------------------------------------------------- 3. reserve run
mkdir -p "$RUNS_ROOT" "$METADATA_ROOT"
PREPARE_JSON="$("$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/prepare_run.py" \
  --output-root "$RUNS_ROOT" \
  --model "$RUN_MODEL" \
  --harness "$HARNESS_NAME" \
  --experiment "$EXPERIMENT_LABEL" \
  --prompt-file "$PROMPT_FILE")" || die "prepare_run.py failed; no run was reserved"

RUN_DIR="$("$ONESHOT_WEBSITES_PYTHON" -c 'import json,sys; print(json.loads(sys.argv[1])["runDirectory"])' "$PREPARE_JSON")"
RUN_ID="$(basename "$RUN_DIR")"

# The skill infers from the prompt whether this run needs the digest-bound
# directional-control browser gate. When it does, the model must be given the
# transient technical contract, and the gate must be run after an OK handoff --
# catalogue validation rejects an applicable OK run without passing evidence.
# Sandbox mode. On by default when docker and the image are both available:
# the model then sees ONLY its own run directory and the read-only skill, so it
# cannot reach sibling runs, other prompts, or the files that name both models.
SANDBOX="${SANDBOX:-auto}"
if [ "$SANDBOX" = "auto" ]; then
  if command -v docker >/dev/null 2>&1 \
     && docker image inspect "${SANDBOX_IMAGE:-ovc-sandbox:7.5.6}" >/dev/null 2>&1; then
    SANDBOX=1
  else
    SANDBOX=0
  fi
fi
if [ "$SANDBOX" = "1" ]; then
  MODEL_RUN_DIR="/work/runs/$RUN_ID"
  MODEL_SKILL_DIR="/work/.kilo/skills/oneshot-websites"
  MODEL_RUNS_ROOT="/work/runs"       # holds only this run and its own receipt
  MODEL_PY="/usr/bin/python3"
  log "sandbox: ENABLED (container-isolated run)"
else
  MODEL_RUN_DIR="$RUN_DIR"
  MODEL_SKILL_DIR="$SKILL_DIR"
  MODEL_RUNS_ROOT="$RUNS_ROOT"
  MODEL_PY="$ONESHOT_WEBSITES_PYTHON"
  warn "sandbox: DISABLED - the run can read sibling runs, other prompts and the experiment docs. Build the image with scripts/build-sandbox.sh."
fi

DIRECTIONAL_REQUIRED="$("$ONESHOT_WEBSITES_PYTHON" -c 'import json,sys; print("1" if json.loads(sys.argv[1]).get("directionalControlsRequired") else "0")' "$PREPARE_JSON")"
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

# ---------------------------------------------------- 4b. stage the materials
MATERIALS_COUNT=0
MATERIALS_SHA=""
if [ -n "$MATERIALS_SRC" ]; then
  mkdir -p "$RUN_DIR/materials"
  for f in "$MATERIALS_SRC"/* ${MATERIALS_ARM_DIR:+"$MATERIALS_ARM_DIR"/*}; do
    [ -e "$f" ] || continue
    case "$f" in
      "$PROMPT_FILE") continue ;;                      # the sealed prompt itself
      "$MATERIALS_SRC"/for-*) continue ;;              # another arm's materials
      *.zip)
        command -v unzip >/dev/null 2>&1 \
          || die "materials include a zip but unzip is not installed"
        # -x __MACOSX/*: macOS resource forks are not experimental input
        unzip -q -o -j "$f" -x '__MACOSX/*' '*/.DS_Store' -d "$RUN_DIR/materials" \
          || die "could not extract materials archive: $f"
        ;;
      *) cp -R "$f" "$RUN_DIR/materials/" ;;
    esac
  done
  # drop any resource-fork strays the archive smuggled through
  find "$RUN_DIR/materials" -name '._*' -delete 2>/dev/null || true
  MATERIALS_COUNT="$(find "$RUN_DIR/materials" -type f | wc -l | tr -d ' ')"
  [ -n "$MATERIALS_ARM_DIR" ] && log "arm-specific materials from $(basename "$MATERIALS_ARM_DIR")/"

  # Manifest: proves every arm received byte-identical inputs.
  "$ONESHOT_WEBSITES_PYTHON" - "$RUN_DIR" > "$RUN_DIR/materials-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
run = pathlib.Path(sys.argv[1]); mat = run / "materials"
entries = []
for f in sorted(mat.rglob("*")):
    if f.is_file():
        b = f.read_bytes()
        entries.append({"path": str(f.relative_to(mat)), "bytes": len(b),
                        "sha256": hashlib.sha256(b).hexdigest()})
combined = hashlib.sha256(
    "".join(f"{e['path']}:{e['sha256']}" for e in entries).encode()).hexdigest()
print(json.dumps({"count": len(entries), "combinedSha256": combined, "files": entries}, indent=2))
PY
  MATERIALS_SHA="$("$ONESHOT_WEBSITES_PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["combinedSha256"])' "$RUN_DIR/materials-manifest.json")"
  log "materials staged: $MATERIALS_COUNT file(s)  combined sha256=$MATERIALS_SHA"
fi

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
    --provider "${RUN_MODEL%%/*}" \
    --exact-model-id "$RUN_MODEL" \
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
    --sandbox "$SANDBOX" \
    --upstream "${RUN_UPSTREAM:-}" \
    --upstream-ignore "${RUN_UPSTREAM_IGNORE:-}" \
    --materials-sha "${MATERIALS_SHA:-}" \
    --materials-count "${MATERIALS_COUNT:-0}" \
    --materials-arm-specific "$([ -n "$MATERIALS_ARM_DIR" ] && echo yes || echo no)" \
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
BRIEF="$RUN_DIR/.tmp/run-brief.md"
mkdir -p "$RUN_DIR/.tmp"

MATERIALS_FILE="$RUN_DIR/.tmp/.materials.md"
if [ "$MATERIALS_COUNT" -gt 0 ]; then
  {
    echo "This run supplies $MATERIALS_COUNT input file(s) alongside the prompt."
    echo "They are in \`materials/\` inside your run directory, listed below."
    echo
    echo "Read image files with your \`read\` tool: it returns real image content,"
    echo "so you can actually look at screenshots rather than guess from filenames."
    echo "Copy any asset you use into your built artifact; never link to a path"
    echo "outside \`artifact/\`, and never fetch an external replacement."
    echo
    "$ONESHOT_WEBSITES_PYTHON" - "$RUN_DIR/materials-manifest.json" <<'PYLIST'
import json, sys
for e in json.load(open(sys.argv[1]))["files"]:
    print("- materials/%s  (%s bytes)" % (e["path"], format(e["bytes"], ",")))
PYLIST
  } > "$MATERIALS_FILE"
else
  echo "NOT_APPLICABLE: this run supplies no materials beyond the prompt." > "$MATERIALS_FILE"
fi

DIRECTIONAL_GUIDANCE_FILE="$RUN_DIR/.tmp/.directional-guidance.md"
if [ "$DIRECTIONAL_REQUIRED" = "1" ]; then
  log "directional-control gate REQUIRED for this prompt"
  {
    echo "This run REQUIRES the directional-control contract. Implement its"
    echo "production-state adapter in the built artifact and exercise it during"
    echo "verification. Never copy any of this into artifact/PROMPT.md: that file"
    echo "stays the human task brief only."
    echo
    echo "----- BEGIN .tmp/TECHNICAL_PROMPT.md -----"
    cat "$RUN_DIR/.tmp/TECHNICAL_PROMPT.md" 2>/dev/null
    echo "----- END .tmp/TECHNICAL_PROMPT.md -----"
    echo
    echo "----- BEGIN references/directional-controls.md -----"
    cat "$SKILL_DIR/references/directional-controls.md" 2>/dev/null
    echo "----- END references/directional-controls.md -----"
  } > "$DIRECTIONAL_GUIDANCE_FILE"
else
  echo "NOT_APPLICABLE: no prepared directional-control browser gate." > "$DIRECTIONAL_GUIDANCE_FILE"
fi
"$ONESHOT_WEBSITES_PYTHON" - \
  "$EXP_ROOT/experiment-config/run-brief.template.md" "$BRIEF" "$DIRECTIONAL_GUIDANCE_FILE" "$MATERIALS_FILE" \
  "$MODEL_RUN_DIR" "$RUN_ID" "$RUN_MODEL" "$HARNESS_NAME" \
  "$EXPERIMENT_LABEL" "$PROMPT_SHA" "$MODEL_SKILL_DIR" "$MODEL_PY" "$MODEL_RUNS_ROOT" <<'PY'
import pathlib, sys
tpl, out, guidance_file, materials_file, run_dir, run_id, model, harness, exp, sha, skill, py, runs_root = sys.argv[1:14]
text = pathlib.Path(tpl).read_text(encoding="utf-8")
for k, v in {
    "@@RUN_DIR@@": run_dir, "@@RUN_ID@@": run_id, "@@RUN_MODEL@@": model,
    "@@HARNESS@@": harness, "@@EXPERIMENT@@": exp,
    "@@PROMPT_SHA256@@": sha, "@@SKILL_DIR@@": skill, "@@PY@@": py,
    "@@RUNS_ROOT@@": runs_root,
    "@@DIRECTIONAL_CONTROL_GUIDANCE@@": pathlib.Path(guidance_file).read_text(encoding="utf-8"),
    "@@MATERIALS@@": pathlib.Path(materials_file).read_text(encoding="utf-8"),
}.items():
    text = text.replace(k, v)
assert "@@" not in text, "unsubstituted placeholder remains in coordinator brief"
pathlib.Path(out).write_text(text, encoding="utf-8")
PY

# ------------------------------------------------- 6. launch the coordinator
# Per-run override of the LEAD model only. The coordinator, the critic, the
# permissions and every other harness setting come from the pinned kilo.jsonc.
# Set the single model for the run. `small_model` is pinned to the same model
# so even incidental harness traffic (title/summary generation) cannot pull in
# a second model. No per-agent model is set, so every subagent inherits this.
# Optionally pin the OpenRouter upstream. Safe to set provider-wide here
# because a run uses exactly one model, so this cannot affect another arm.
# allow_fallbacks is false: silently falling back to a different upstream at a
# different quantization would defeat the point of pinning.
RUN_UPSTREAM="$(resolve_upstream "$MODEL_ALIAS")"
RUN_UPSTREAM_IGNORE="$(resolve_upstream_ignore "$MODEL_ALIAS")"
KILO_CONFIG_CONTENT="$("$ONESHOT_WEBSITES_PYTHON" -c '
import json,sys
model, order, ignore = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {"model": model, "small_model": model}
routing = {}
if order:  routing["order"] = [x.strip() for x in order.split(",") if x.strip()]
if ignore: routing["ignore"] = [x.strip() for x in ignore.split(",") if x.strip()]
if routing:
    # Fallbacks ON: a stalling upstream costs a retry, not the whole run.
    routing["allow_fallbacks"] = True
    cfg["provider"] = {"openrouter": {"options": {"extraBody": {"provider": routing}}}}
print(json.dumps(cfg))' "$RUN_MODEL" "$RUN_UPSTREAM" "$RUN_UPSTREAM_IGNORE")"
export KILO_CONFIG_CONTENT
if [ -n "$RUN_UPSTREAM" ] || [ -n "$RUN_UPSTREAM_IGNORE" ]; then
  log "upstream order: ${RUN_UPSTREAM:-<any>}  ignore: ${RUN_UPSTREAM_IGNORE:-<none>}  fallbacks: enabled"
else
  log "upstream: unpinned (OpenRouter default routing)"
fi

# The harness process writes into TMPDIR continuously, including AFTER the
# model's cleanup helper has removed .tmp/. Pointing TMPDIR at .tmp/ therefore
# re-creates it moments later and makes the skill's "OK requires .tmp/ absent"
# contract structurally unreachable: every successful run would fail catalogue
# validation through no fault of the model.
#
# So the HARNESS gets its own run-local temp dir. The model's own scratch still
# belongs in .tmp/, which the skill's dispatch envelope instructs it to use and
# which stays under the model's control. Both live inside the run directory, so
# both remain part of the preserved record.
mkdir -p "$RUN_DIR/.harness-tmp"
export TMPDIR="$RUN_DIR/.harness-tmp" TMP="$RUN_DIR/.harness-tmp" TEMP="$RUN_DIR/.harness-tmp"

log "launching run: model=$RUN_MODEL (single model for every turn at every depth) timeout=${RUN_TIMEOUT_SECONDS}s"
record_intervention "dispatch" "session_launch" "model=$RUN_MODEL"

# External bounded liveness monitor (content-free: it only observes).
"$EXP_ROOT/scripts/monitor-liveness.sh" "$RUN_DIR" "$INTERVENTIONS" "$RUN_ID" "$$" \
  >>"$STDERR_LOG" 2>&1 &
MONITOR_PID=$!

KEEPAWAKE=""
command -v caffeinate >/dev/null 2>&1 && KEEPAWAKE="caffeinate -i -m -s"

set +e
if [ "$SANDBOX" = "1" ]; then
  LAUNCH="$EXP_ROOT/scripts/sandbox-exec.sh $RUN_DIR --"
else
  LAUNCH="$KEEPAWAKE"
fi

run_with_timeout "$RUN_TIMEOUT_SECONDS" \
  $LAUNCH kilo run \
    --auto \
    --agent code \
    --model "$RUN_MODEL" \
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

# Verify the skill's finalization contract WITHOUT repairing it. A violation is
# recorded honestly; the model's own status is never rewritten to hide it, so a
# claimed OK that broke the contract stays visible as exactly that.
FINALIZATION_REPORT="$RUN_DIR/.finalization.json"
"$ONESHOT_WEBSITES_PYTHON" "$EXP_ROOT/scripts/check_finalization.py" \
  --run-dir "$RUN_DIR" --expected-digest "$PROMPT_SHA" \
  > "$FINALIZATION_REPORT" 2>>"$STDERR_LOG" || true

if [ -s "$FINALIZATION_REPORT" ] && ! grep -q '"contractHolds": true' "$FINALIZATION_REPORT"; then
  log "finalization contract VIOLATED (recorded, not repaired): $FINALIZATION_REPORT"
  record_intervention "finalization_violation" "contract_check" "see .finalization.json"
fi

normalize_records

# ------------------------------- 7b. directional-control browser gate
# Coordinator-owned, per the skill: run only after the model reaches OK, and
# only when the prepared run requires it. It writes digest-bound evidence
# outside the run. A failure is recorded, never retried and never repaired.
if [ "$DIRECTIONAL_REQUIRED" = "1" ]; then
  RUN_STATUS_NOW="$("$ONESHOT_WEBSITES_PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status"))' "$RUN_DIR/run.json" 2>/dev/null || echo "")"
  if [ "$RUN_STATUS_NOW" = "OK" ]; then
    log "running directional-control browser gate"
    record_intervention "directional_gate" "post_ok_verification" "start"
    set +e
    "$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/verify_directional_controls.py" \
      --run "$RUN_DIR" > "$RUN_DIR/directional-controls.txt" 2>&1
    DIRECTIONAL_RC=$?
    set -e
    record_intervention "directional_gate" "post_ok_verification" "rc=$DIRECTIONAL_RC"
    [ "$DIRECTIONAL_RC" -eq 0 ] && log "directional gate PASSED" \
                                || log "directional gate FAILED (recorded, not retried): $RUN_DIR/directional-controls.txt"
  else
    log "directional gate skipped: run status is $RUN_STATUS_NOW, not OK"
    record_intervention "directional_gate" "skipped_non_ok" "status=$RUN_STATUS_NOW"
  fi
fi

# ----------------------------------------- 8. catalogue validate + rebuild
set +e
"$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/validate_catalog.py" "$RUNS_ROOT" \
  > "$RUN_DIR/catalog-validate.txt" 2>&1
CATALOG_RC=$?
"$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/build_catalog_index.py" \
  --root "$RUNS_ROOT" --out "$RUNS_ROOT/index.html" \
  >> "$RUN_DIR/catalog-validate.txt" 2>&1
set -e
log "catalogue validate rc=$CATALOG_RC (details: $RUN_DIR/catalog-validate.txt)"

# ------------------------------------------------------------- 9. metadata
finalize_metadata "$EXIT_CODE"

echo
echo "run_id:   $RUN_ID"
echo "run_dir:  $RUN_DIR"
echo "arm:      $MODEL_ALIAS ($RUN_MODEL)  [single model for the whole run]"
echo "status:   $(cat "$STATUS_FILE")"
echo "metadata: $META_FILE"
exit 0
}

main "$@"
