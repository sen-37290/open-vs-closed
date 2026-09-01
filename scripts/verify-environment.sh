#!/usr/bin/env bash
#
# verify-environment.sh — PASS/FAIL preflight for the A/B harness.
# Never prints a secret value; only whether a variable is present.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
FAILURES=0
load_config

echo "=================================================================="
echo " open-vs-closed — environment verification"
echo "=================================================================="

echo; echo "-- toolchain -----------------------------------------------------"
if command -v kilo >/dev/null 2>&1; then
  KV="$(kilo --version 2>/dev/null | grep -v '^INFO' | head -1 | tr -d '[:space:]')"
  pass "kilo CLI installed (version $KV)"
else fail "kilo CLI not found on PATH (npm install -g @kilocode/cli)"; fi

command -v git  >/dev/null 2>&1 && pass "git $(git --version | awk '{print $3}')" || fail "git not found"
command -v node >/dev/null 2>&1 && pass "node $(node --version)"                  || warn "node not found (only needed if a lead chooses a node toolchain)"
command -v npm  >/dev/null 2>&1 && pass "npm $(npm --version)"                    || warn "npm not found"
command -v curl >/dev/null 2>&1 && pass "curl present (liveness monitor)"          || fail "curl not found; liveness monitoring will not work"

# The skill's own finder calls shutil.which(), so anything on PATH works. This
# check mirrors that, plus the macOS app-bundle paths which are not on PATH.
BROWSER=""
for b in "${ONESHOT_WEBSITES_BROWSER:-}" \
         "$(command -v chromium 2>/dev/null)" \
         "$(command -v chromium-browser 2>/dev/null)" \
         "$(command -v google-chrome 2>/dev/null)" \
         "$(command -v google-chrome-stable 2>/dev/null)" \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  [ -n "$b" ] && [ -x "$b" ] && { BROWSER="$b"; break; }
done
[ -n "$BROWSER" ] && pass "Chromium-family browser for the directional-controls gate: $(basename "$BROWSER")" \
                  || warn "no Chromium-family browser found; prompts with directional controls cannot pass the browser gate"

if command -v caffeinate >/dev/null 2>&1; then pass "keep-awake available: caffeinate"
else fail "no keep-awake mechanism; a host sleep mid-run corrupts wall-clock and liveness data"; fi

echo; echo "-- uv + python for skill helpers (>= 3.11) -----------------------"
if command -v uv >/dev/null 2>&1; then
  pass "uv $(uv --version 2>/dev/null | awk '{print $2}') (manages and pins the interpreter)"
  [ -f "$EXP_ROOT/.python-version" ] && pass "interpreter pinned: $(cat "$EXP_ROOT/.python-version")" \
                                     || warn ".python-version missing; uv will pick an interpreter per invocation"
  [ -f "$EXP_ROOT/pyproject.toml" ] && pass "pyproject.toml present (requires-python >= 3.11)" \
                                    || warn "pyproject.toml missing"
else
  warn "uv not installed; falling back to PATH discovery (brew install uv)"
fi
if ensure_python; then
  pass "ONESHOT_WEBSITES_PYTHON=$ONESHOT_WEBSITES_PYTHON ($("$ONESHOT_WEBSITES_PYTHON" --version 2>&1))"
else
  fail "no Python >= 3.11 found; the oneshot-websites helpers require it"
fi

echo; echo "-- pinned skill --------------------------------------------------"
if [ -f "$SKILL_DIR/SKILL.md" ]; then
  pass "skill present at .kilo/skills/oneshot-websites (harness discovery path)"
else
  fail "skill missing at $SKILL_DIR"
fi
SC="$(cat "$EXP_ROOT/experiment-config/SKILL_COMMIT.txt" 2>/dev/null || echo '')"
[ -n "$SC" ] && pass "pinned upstream commit: $SC" || fail "experiment-config/SKILL_COMMIT.txt missing"
SV="$("${ONESHOT_WEBSITES_PYTHON:-python3}" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$SKILL_DIR/metadata.json" 2>/dev/null || echo '')"
[ -n "$SV" ] && pass "skill version: $SV" || fail "cannot read skill metadata.json version"

echo; echo "-- skill self-tests ----------------------------------------------"
if [ -n "${ONESHOT_WEBSITES_PYTHON:-}" ]; then
  V_OUT="$("$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/validate.py" "$SKILL_DIR" 2>&1)"
  echo "$V_OUT" | grep -q '"valid": true' && pass "validate.py: valid" || fail "validate.py: $(echo "$V_OUT" | head -3)"

  # test_skill.py includes the directional-controls browser gate, which drives
  # headless Chrome. That step is timing-sensitive under load, so a single
  # failure is retried once before it is reported as a real failure.
  T_OUT="$("$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/test_skill.py" "$SKILL_DIR" 2>&1)"
  if ! printf '%s' "$T_OUT" | grep -q '^PASS:'; then
    warn "test_skill.py failed once (browser gate is load-sensitive); retrying"
    T_OUT="$("$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/test_skill.py" "$SKILL_DIR" 2>&1)"
  fi
  if printf '%s' "$T_OUT" | grep -q '^PASS:'; then
    pass "test_skill.py: $(printf '%s' "$T_OUT" | grep '^PASS:' | head -1)"
  else
    fail "test_skill.py: $(printf '%s' "$T_OUT" | grep -E '^- ' | head -1 | cut -c1-140)"
    printf '        (full output: %s)\n' "$(printf '%s' "$T_OUT" | head -1 | cut -c1-100)"
  fi

  for helper in prepare_run.py build_catalog_index.py validate_catalog.py cleanup_run_tmp.py; do
    if "$ONESHOT_WEBSITES_PYTHON" "$SKILL_DIR/scripts/$helper" --help >/dev/null 2>&1 \
       || "$ONESHOT_WEBSITES_PYTHON" -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$SKILL_DIR/scripts/$helper" >/dev/null 2>&1; then
      pass "helper executes: $helper"
    else
      fail "helper does not execute: $helper"
    fi
  done
fi

echo; echo "-- harness capabilities ------------------------------------------"
AGENTS="$(kilo agent list 2>/dev/null | grep -v '^INFO' | grep -E '^\S+ \((primary|subagent|all)\)')"
echo "$AGENTS" | grep -q '^oneshot-lead (subagent)'   && pass "no-history subagent dispatch: oneshot-lead registered as a subagent" \
                                                      || fail "oneshot-lead subagent not registered (UNSUPPORTED_NO_FRESH_SUBAGENT risk)"
echo "$AGENTS" | grep -q '^oneshot-critic (subagent)' && pass "critic subagent registered" \
                                                      || fail "oneshot-critic subagent not registered"

# The experiment runs ONE model per run. Any per-agent model pin in kilo.jsonc
# would introduce a second model into an arm, so its ABSENCE is the check.
if "${ONESHOT_WEBSITES_PYTHON:-python3}" - "$EXP_ROOT/kilo.jsonc" <<'PYCHK'
import json, re, sys, pathlib
cfg = json.loads(re.sub(r"^\s*//.*$", "", pathlib.Path(sys.argv[1]).read_text(), flags=re.M))
pinned = [n for n, a in (cfg.get("agent") or {}).items() if isinstance(a, dict) and a.get("model")]
if cfg.get("model"):        pinned.append("<top-level model>")
if cfg.get("small_model"):  pinned.append("<small_model>")
sys.exit(1 if pinned else 0)
PYCHK
then
  pass "single-model design intact: no agent in kilo.jsonc pins a model, so every subagent inherits the run's one model"
else
  fail "kilo.jsonc pins a model somewhere; that would put a SECOND model inside one arm and invalidate the comparison"
fi

DEPTH="$(grep -o '"subagent_depth"[^,]*' "$EXP_ROOT/kilo.jsonc" | grep -o '[0-9]\+' || echo 0)"
[ "${DEPTH:-0}" -ge 1000 ] && pass "recursive delegation enabled (subagent_depth=$DEPTH; kilo's default of 1 would block any subagent from spawning a subagent)" \
                           || fail "subagent_depth is $DEPTH; the lead could not run its quality gauntlet"

grep -q '"question": "deny"' "$EXP_ROOT/kilo.jsonc" \
  && pass "autonomous mode: interactive question tool denied, so no run can block on a human" \
  || fail "the question tool is not denied; a run could stall waiting for a human"
grep -q '"bash": "allow"' "$EXP_ROOT/kilo.jsonc" \
  && pass "autonomous mode: full tool surface pre-approved (bash/edit/webfetch) + kilo run --auto" \
  || fail "tool permissions are not pre-approved; runs would prompt for approval"

kilo serve --help >/dev/null 2>&1 \
  && pass "background execution with observable status (session store + filesystem progress, used by monitor-liveness.sh)" \
  || fail "kilo serve unavailable; liveness monitoring cannot observe run status"

echo; echo "-- config isolation ----------------------------------------------"
GLOBAL_CFG="$HOME/.config/kilo/kilo.jsonc"
if [ -f "$GLOBAL_CFG" ] && [ "$(tr -d '[:space:]' < "$GLOBAL_CFG" | sed 's/{"\$schema":"[^"]*"}//')" != "" ]; then
  fail "user-level $GLOBAL_CFG defines settings that would leak into BOTH arms and can silently invalidate the A/B — review it"
else
  pass "user-level kilo config is empty; no ambient settings leak into runs"
fi
for d in "$HOME/.kilo" "$HOME/.kilocode"; do
  [ -d "$d" ] && warn "user-level config dir exists and is always loaded: $d (review for agents/plugins/skills)" || true
done

echo; echo "-- models --------------------------------------------------------"
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  pass "OPENROUTER_API_KEY present (value not shown)"
else
  fail "OPENROUTER_API_KEY is empty — fill it in experiment-config/models.env (that file exists and is gitignored)"
fi

check_model() {
  local label="$1" full="$2" provider="${2%%/*}"
  if kilo models "$provider" 2>/dev/null | grep -v '^INFO' | grep -Fxq "$full"; then
    pass "$label visible to harness: $full"
  else
    fail "$label NOT visible to harness: $full"
  fi
}
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  check_model "GLM arm"   "$(resolve_model glm-5.3)"
  check_model "Fable arm" "$(resolve_model fable-5)"
fi

# These are leftovers from an earlier design and are now ignored entirely.
if [ -n "${COORDINATOR_MODEL:-}" ] || [ -n "${CRITIC_MODEL:-}" ]; then
  warn "models.env still sets COORDINATOR_MODEL and/or CRITIC_MODEL. They are IGNORED now (one model per run). You can delete those two lines."
fi

echo; echo "-- workspace -----------------------------------------------------"
for d in runs metadata prompts experiment-config; do
  [ -w "$EXP_ROOT/$d" ] && pass "writable: $d/" || fail "not writable: $d/"
done
PROBE="$RUNS_ROOT/.write-probe.$$"
if mkdir -p "$PROBE" 2>/dev/null && touch "$PROBE/x" 2>/dev/null; then
  pass "isolated run workspaces can be created under runs/"; rm -rf "$PROBE"
else
  fail "cannot create isolated run workspaces under runs/"
fi

git -C "$EXP_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && pass "experiment directory is a git repository ($(git -C "$EXP_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'no commits yet'))" \
  || warn "not a git repository; provenance will not be recorded"

if git -C "$EXP_ROOT" check-ignore -q experiment-config/models.env 2>/dev/null; then
  pass "experiment-config/models.env is gitignored (secrets stay out of commits)"
else
  fail "experiment-config/models.env is NOT gitignored"
fi
if git -C "$EXP_ROOT" check-ignore -q runs 2>/dev/null; then
  pass "runs/ is local-only and gitignored (the record is preserved on disk, not in git)"
else
  warn "runs/ is NOT gitignored; generated sites and screenshots will bloat the repository"
fi
if [ -d "$EXP_ROOT/runs" ] && [ -w "$EXP_ROOT/runs" ]; then
  pass "runs/ exists and is writable ($(find "$EXP_ROOT/runs" -maxdepth 1 -type d 2>/dev/null | tail +2 | wc -l | tr -d ' ') runs preserved locally)"
else
  fail "runs/ is missing or not writable"
fi

echo; echo "=================================================================="
if [ "$FAILURES" -eq 0 ]; then
  echo " RESULT: ALL CHECKS PASSED"
else
  echo " RESULT: $FAILURES CHECK(S) FAILED — do not start the benchmark"
fi
echo "=================================================================="
exit $([ "$FAILURES" -eq 0 ] && echo 0 || echo 1)
