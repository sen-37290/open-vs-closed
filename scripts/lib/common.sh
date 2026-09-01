#!/usr/bin/env bash
# Shared helpers for the open-vs-closed A/B harness.
# Sourced by run-one.sh, run-pair.sh, run-all.sh and verify-environment.sh.
# Targets bash 3.2 (the macOS system bash): no associative arrays, no ${x,,}.

EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export EXP_ROOT

SKILL_DIR="$EXP_ROOT/.kilo/skills/oneshot-websites"
RUNS_ROOT="$EXP_ROOT/runs"
METADATA_ROOT="$EXP_ROOT/metadata"
export SKILL_DIR RUNS_ROOT METADATA_ROOT

# --- output -----------------------------------------------------------------
log()  { printf '%s %s\n' "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]" "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES+1)); }
warn() { printf '  WARN  %s\n' "$*"; }

# --- configuration ----------------------------------------------------------
# Loads models.env (untracked, real values). Never echoes values.
# Loads models.env WITHOUT clobbering variables the caller already set, so
# `RUN_TIMEOUT_SECONDS=600 ./scripts/run-one.sh ...` actually takes effect.
# An explicit environment value always wins over the file.
load_config() {
  local envfile="${MODELS_ENV:-$EXP_ROOT/experiment-config/models.env}"
  if [ -f "$envfile" ]; then
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) continue ;; esac
      key="${line%%=*}"
      val="${line#*=}"
      key="$(printf '%s' "$key" | tr -d '[:space:]')"
      case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
      # Only set it if the caller has not already provided a non-empty value.
      if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
        eval "export $key=\$val"
      fi
    done < "$envfile"
  fi
  : "${GLM_PROVIDER:=openrouter}"
  : "${FABLE_PROVIDER:=openrouter}"
  : "${GLM_MODEL:=z-ai/glm-5.3}"
  : "${FABLE_MODEL:=anthropic/claude-fable-5}"
  : "${KIMI_PROVIDER:=openrouter}"
  : "${KIMI_MODEL:=moonshotai/kimi-k3}"
  # OpenRouter routes an open-weights model to many upstreams at different
  # quantizations, so two runs of the "same" model can differ materially.
  # Pinning the upstream makes a run reproducible. Empty means "let OpenRouter
  # choose", which is the current behaviour for GLM and Fable.
  : "${KIMI_UPSTREAM:=moonshotai}"
  : "${GLM_UPSTREAM:=}"
  : "${FABLE_UPSTREAM:=}"
  : "${RUN_TIMEOUT_SECONDS:=14400}"
  : "${MAX_PARALLEL:=2}"
  : "${HARNESS_NAME:=kilo-cli}"
  : "${EXPERIMENT_NAME:=open-vs-closed}"
}

# Resolve a model alias to a fully-qualified "<provider>/<model>" id.
resolve_model() {
  case "$1" in
    glm-5.3|glm|GLM)     printf '%s/%s\n' "$GLM_PROVIDER" "$GLM_MODEL" ;;
    fable-5|fable|FABLE) printf '%s/%s\n' "$FABLE_PROVIDER" "$FABLE_MODEL" ;;
    kimi-k3|kimi|KIMI)   printf '%s/%s\n' "$KIMI_PROVIDER" "$KIMI_MODEL" ;;
    */*/*|*/*)           printf '%s\n' "$1" ;;
    *) die "unknown model alias '$1' (expected: glm-5.3, fable-5, kimi-k3, or an explicit provider/model id)" ;;
  esac
}

# Which OpenRouter upstream, if any, this alias pins.
resolve_upstream() {
  case "$1" in
    glm-5.3|glm|GLM)     printf '%s\n' "${GLM_UPSTREAM:-}" ;;
    fable-5|fable|FABLE) printf '%s\n' "${FABLE_UPSTREAM:-}" ;;
    kimi-k3|kimi|KIMI)   printf '%s\n' "${KIMI_UPSTREAM:-}" ;;
    *)                   printf '%s\n' "${UPSTREAM:-}" ;;
  esac
}

# Confirm the harness can actually see the model. Never guesses.
#
# Retries deliberately: the first `kilo models` call may populate a cache and
# return a short list, and concurrent launches can race each other. A single
# attempt once reported a perfectly available model as missing and aborted an
# arm, which would silently have turned a paired comparison into a single-arm
# run. Only a list that looks complete counts as evidence of absence.
assert_model_visible() {
  local full="$1" provider list n tries=0
  provider="${full%%/*}"
  while [ "$tries" -lt 4 ]; do
    list="$(kilo models "$provider" 2>/dev/null | grep -v '^INFO')"
    n="$(printf '%s\n' "$list" | grep -c . | tr -d ' \n')"
    if [ "${n:-0}" -gt 10 ]; then
      printf '%s\n' "$list" | grep -Fxq "$full" && return 0
      die "model '$full' is not visible to the kilo harness (provider list had $n models). Refusing to run a comparison against a model the harness cannot address."
    fi
    tries=$((tries + 1))
    sleep 5
  done
  die "could not retrieve the '$provider' model list after 4 attempts; refusing to dispatch without confirming the model is addressable"
}

# --- prompt sealing ---------------------------------------------------------
# Strict UTF-8 read; rejects mojibake/replacement characters. Prints sha256.
prompt_digest() {
  "${ONESHOT_WEBSITES_PYTHON:-python3}" - "$1" <<'PY'
import hashlib, sys, pathlib
p = pathlib.Path(sys.argv[1])
raw = p.read_bytes()
if not raw.strip():
    sys.exit("prompt file is empty")
try:
    text = raw.decode("utf-8", errors="strict")
except UnicodeDecodeError as e:
    sys.exit(f"prompt file is not strict UTF-8: {e}")
if "�" in text:
    sys.exit("prompt file contains U+FFFD replacement characters (mojibake); refusing to seal")
if raw.startswith(b"\xef\xbb\xbf"):
    sys.exit("prompt file has a UTF-8 BOM; strip it so both arms receive identical bytes")
print(hashlib.sha256(raw).hexdigest())
PY
}

# Portable SHA-256. Linux ships sha256sum (coreutils, always present); macOS
# ships shasum (perl). This sits in the prompt-seal integrity path, so it must
# never silently produce an empty digest -- it fails loudly instead.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "no sha256 tool found (need sha256sum or shasum); refusing to run without digest verification"
  fi
}

# --- portable wall-clock timeout -------------------------------------------
# macOS ships no timeout(1)/gtimeout(1). This runs "$@" in its own process
# group and kills the whole tree on expiry. Sets TIMEOUT_HIT=1 when it fires.
TIMEOUT_HIT=0
run_with_timeout() {
  local secs="$1"; shift
  # GNU mktemp requires XXXXXX in the template; BSD does not. Without this the
  # call failed on Linux, the flag file was never created, and a run killed by
  # the wall-clock watchdog was NOT recorded as a timeout.
  local flag
  flag="$(mktemp -t ovc-timeout.XXXXXX 2>/dev/null || mktemp "${TMPDIR:-/tmp}/ovc-timeout.XXXXXX")"
  [ -n "$flag" ] || die "cannot create a timeout flag file; refusing to run without timeout detection"
  rm -f "$flag"

  set -m
  "$@" &
  local cmd_pid=$!
  set +m

  (
    local waited=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
      if [ "$waited" -ge "$secs" ]; then
        : > "$flag"
        kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
        sleep 20
        kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
        break
      fi
      sleep 5
      waited=$((waited + 5))
    done
  ) &
  local wd_pid=$!

  local rc=0
  wait "$cmd_pid" || rc=$?
  kill "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true

  if [ -f "$flag" ]; then TIMEOUT_HIT=1; rm -f "$flag"; else TIMEOUT_HIT=0; fi
  return "$rc"
}

# --- misc -------------------------------------------------------------------
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch()   { date +%s; }

python_ok() {
  local py="${ONESHOT_WEBSITES_PYTHON:-python3}"
  "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null
}

# Resolve a Python >= 3.11 for the skill helpers and export the override.
#
# uv is the preferred source: it pins one interpreter for the whole experiment
# (see .python-version / pyproject.toml) rather than depending on whatever
# `python3` happens to be first on PATH. This machine's default python3 is 3.9,
# which the skill helpers reject.
#
# ONESHOT_WEBSITES_PYTHON must name a single executable with no flags, per the
# skill contract, so we resolve uv's interpreter to a concrete path rather than
# wrapping it in `uv run`.
ensure_python() {
  # An explicit caller-provided interpreter always wins.
  if [ -n "${ONESHOT_WEBSITES_PYTHON:-}" ] && python_ok; then
    export ONESHOT_WEBSITES_PYTHON
    return 0
  fi

  # uv installs to ~/.local/bin, which a non-login ssh shell may not have on PATH
  [ -x "$HOME/.local/bin/uv" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH"; export PATH ;; esac
  if command -v uv >/dev/null 2>&1; then
    local uvpy
    uvpy="$(cd "$EXP_ROOT" && uv python find '>=3.11' 2>/dev/null | head -1)"
    if [ -z "$uvpy" ] || [ ! -x "$uvpy" ]; then
      (cd "$EXP_ROOT" && uv python install >/dev/null 2>&1) || true
      uvpy="$(cd "$EXP_ROOT" && uv python find '>=3.11' 2>/dev/null | head -1)"
    fi
    if [ -n "$uvpy" ] && [ -x "$uvpy" ]; then
      export ONESHOT_WEBSITES_PYTHON="$uvpy"
      return 0
    fi
  fi

  if python_ok; then
    export ONESHOT_WEBSITES_PYTHON="${ONESHOT_WEBSITES_PYTHON:-python3}"
    return 0
  fi

  local c
  for c in python3.13 python3.12 python3.11 \
           /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
           /usr/local/bin/python3.12 /usr/local/bin/python3.11; do
    if command -v "$c" >/dev/null 2>&1 && \
       "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
      export ONESHOT_WEBSITES_PYTHON="$(command -v "$c")"
      return 0
    fi
  done
  return 1
}
