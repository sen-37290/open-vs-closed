#!/usr/bin/env bash
#
# run-all.sh [PROMPT_DIR_OR_FILES...]
#
# Batch runner over prompt x model pairs. PREPARED BUT NOT FOR USE until the
# pilot smoke tests pass and you are ready to start the real benchmark.
#
#   ./scripts/run-all.sh                    # every prompt in prompts/, minus pilot
#   ./scripts/run-all.sh prompts/a.md prompts/b.md
#
# Guarantees: bounded parallelism (default 2, never unlimited), an isolated run
# directory per run, no shared generated artifact directory, no automatic retry,
# every failure preserved.

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
load_config
ensure_python || die "no Python >= 3.11 available for the skill helpers"

if [ "${I_HAVE_FINISHED_THE_PILOT:-0}" != "1" ]; then
  cat >&2 <<'MSG'
run-all.sh is prepared but intentionally gated.

It starts the REAL benchmark: every prompt against both arms. Run the pilot and
the failure drill first, then re-run with:

    I_HAVE_FINISHED_THE_PILOT=1 ./scripts/run-all.sh

MSG
  exit 3
fi

ARMS="${ARMS:-glm-5.3 fable-5}"
PROMPTS=""
if [ $# -gt 0 ]; then
  PROMPTS="$*"
else
  for f in "$EXP_ROOT"/prompts/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in pilot.md) continue ;; esac
    PROMPTS="$PROMPTS $f"
  done
fi
[ -n "$(echo "$PROMPTS" | tr -d '[:space:]')" ] || die "no prompt files to run"

BATCH_ID="batch-$(date -u +%Y%m%d-%H%M%S)"
BATCH_DIR="$METADATA_ROOT/$BATCH_ID"
mkdir -p "$BATCH_DIR"
SUMMARY="$BATCH_DIR/summary.tsv"
printf 'arm\tprompt\trun_id\tstatus\texit_code\n' > "$SUMMARY"

log "batch $BATCH_ID  parallelism=$MAX_PARALLEL  arms=[$ARMS]"

# macOS ships bash 3.2, which has no `wait -n`. Track PIDs and poll instead, so
# a finished run frees its slot immediately rather than forcing whole waves.
PIDS=""
inflight() {
  local alive="" n=0 p
  for p in $PIDS; do
    if kill -0 "$p" 2>/dev/null; then alive="$alive $p"; n=$((n + 1)); fi
  done
  PIDS="$alive"
  echo "$n"
}
wait_for_slot() {
  while [ "$(inflight)" -ge "$MAX_PARALLEL" ]; do sleep 5; done
}

for prompt in $PROMPTS; do
  for arm in $ARMS; do
    wait_for_slot

    out="$BATCH_DIR/$(basename "$prompt" .md).$arm.out"
    (
      rc=0
      "$EXP_ROOT/scripts/run-one.sh" "$arm" "$prompt" > "$out" 2>&1 || rc=$?
      rid="$(grep -E '^run_id:' "$out" 2>/dev/null | tail -1 | sed 's/^run_id:[[:space:]]*//')"
      st="$(grep -E '^status:' "$out" 2>/dev/null | tail -1 | sed 's/^status:[[:space:]]*//')"
      printf '%s\t%s\t%s\t%s\t%s\n' "$arm" "$(basename "$prompt")" \
        "${rid:-<none>}" "${st:-UNKNOWN}" "$rc" >> "$SUMMARY"
    ) &
    PIDS="$PIDS $!"
    log "started $arm  $(basename "$prompt")  (in flight: $(inflight)/$MAX_PARALLEL)"
  done
done

log "all runs dispatched; waiting for the last ones to finish"
wait

TOTAL=$(($(wc -l < "$SUMMARY") - 1))
OKC=$(awk -F'\t' 'NR>1 && $4=="OK"' "$SUMMARY" | wc -l | tr -d ' ')
BAD=$((TOTAL - OKC))

echo
echo "========================== BATCH SUMMARY =========================="
column -t -s "$(printf '\t')" "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo "-------------------------------------------------------------------"
echo "total: $TOTAL   OK: $OKC   not-OK (preserved, not retried): $BAD"
echo "batch record: $BATCH_DIR"
echo "==================================================================="
}

main "$@"
