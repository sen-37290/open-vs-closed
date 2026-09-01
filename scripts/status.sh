#!/usr/bin/env bash
#
# status.sh [-w] [RUN_FILTER]
#
# Show the state of every run under runs/. Read-only: it never touches a run.
#
#   ./scripts/status.sh            one snapshot of all runs
#   ./scripts/status.sh -w         refresh every 20s until you press Ctrl-C
#   ./scripts/status.sh interactive   only runs whose name matches "interactive"

set -uo pipefail
EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH=0
[ "${1:-}" = "-w" ] && { WATCH=1; shift; }
FILTER="${1:-}"

snapshot() {
  printf '\n%s  open-vs-closed run status\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "----------------------------------------------------------------------------------------"
  printf '%-34s %-9s %-8s %-7s %-6s %s\n' "RUN" "STATUS" "ELAPSED" "ARTIFACT" "HB" "LAST ACTIVITY"
  printf '%s\n' "----------------------------------------------------------------------------------------"

  local found=0
  for d in "$EXP_ROOT"/runs/*/; do
    [ -d "$d" ] || continue
    local name; name="$(basename "$d")"
    [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac
    found=1

    local short status elapsed artifact hb last
    short="$(printf '%s' "$name" | sed 's/^[0-9-]*-open-vs-closed-//')"

    if [ -f "$d/status.txt" ]; then
      status="$(cat "$d/status.txt")"
    elif [ -f "$d/run.json" ]; then
      status="$(sed -n 's/.*"status": *"\([A-Z]*\)".*/\1/p' "$d/run.json" | head -1)"
    else
      status="?"
    fi
    [ -f "$d/OPERATOR-INVALIDATION.md" ] && status="$status*"

    # elapsed: run start -> now (or -> status.txt mtime once finished)
    local start now human
    # Portable: BSD date wants -j -f, GNU date wants -d. Try both.
    human="$(printf '%s' "$name" | sed -n 's/^\([0-9]\{4\}\)-\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\).*/\1-\2-\3 \4:\5:\6/p')"
    start="$(date -j -f '%Y-%m-%d %H:%M:%S' "$human" +%s 2>/dev/null \
             || date -d "$human" +%s 2>/dev/null || echo 0)"
    if [ -f "$d/status.txt" ]; then
      # Portable: BSD stat -f %m, GNU stat -c %Y.
      now="$(stat -f %m "$d/status.txt" 2>/dev/null || stat -c %Y "$d/status.txt" 2>/dev/null || echo 0)"
    else
      now="$(date +%s)"
    fi
    if [ "$start" -gt 0 ] && [ "$now" -ge "$start" ]; then
      elapsed="$(( (now - start) / 60 ))m"
    else elapsed="-"; fi

    artifact="$(find "$d/artifact" -type f 2>/dev/null | wc -l | tr -d ' ') files"
    hb="$(grep -c heartbeat "$d/interventions.jsonl" 2>/dev/null)"; hb="${hb:-0}"

    last="$(grep heartbeat "$d/interventions.jsonl" 2>/dev/null | tail -1 | \
      sed -n 's/.*"secondsSinceLastWrite": *\([0-9]*\).*/wrote \1s ago/p')"
    [ -z "$last" ] && last="$(grep -v heartbeat "$d/interventions.jsonl" 2>/dev/null | tail -1 | sed -n 's/.*"type":"\([a-z_]*\)".*/\1/p')"

    printf '%-34s %-9s %-8s %-7s %-6s %s\n' "${short:0:34}" "$status" "$elapsed" "$artifact" "$hb" "${last:-—}"
  done
  [ "$found" = "0" ] && printf '  (no runs yet)\n'

  printf '%s\n' "----------------------------------------------------------------------------------------"
  printf 'live processes: %s   * = excluded from analysis (see OPERATOR-INVALIDATION.md)\n' \
    "$(pgrep -f 'run-one.sh' | wc -l | tr -d ' ')"
}

if [ "$WATCH" = "1" ]; then
  while :; do clear; snapshot; sleep 20; done
else
  snapshot
fi
