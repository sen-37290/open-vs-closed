#!/usr/bin/env bash
#
# serve-artifacts.sh [--bind ADDR] [--base PORT]
#
# Serve every run's artifact/ on its own port, and print an index.
# Read-only: it never modifies a run.
#
# On a VM, reach these from your laptop WITHOUT opening firewall ports:
#   gcloud compute ssh VM --zone ZONE -- -L 8899:localhost:8899 -L 8900:localhost:8900 ...
# then open http://localhost:8899 locally. Default bind is 127.0.0.1 so the
# sites are not exposed to the internet.

set -uo pipefail
EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIND="127.0.0.1"; BASE=8899
while [ $# -gt 0 ]; do
  case "$1" in
    --bind) BIND="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

PY="$(command -v python3)"
port=$BASE
printf '\n%-6s %-11s %-46s %s\n' PORT STATUS RUN TITLE
printf '%s\n' "---------------------------------------------------------------------------------------------"
for d in "$EXP_ROOT"/runs/*/; do
  [ -f "$d/artifact/index.html" ] || continue
  id="$(basename "$d")"
  short="$(printf '%s' "$id" | sed 's/^[0-9-]*-open-vs-closed-//')"
  status="$(cat "$d/status.txt" 2>/dev/null || echo '?')"
  [ -f "$d/OPERATOR-INVALIDATION.md" ] && status="$status*"
  title="$(sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p' "$d/artifact/index.html" 2>/dev/null | head -1)"

  # already serving on this port? leave it be.
  if ! curl -sf -m 1 "http://$BIND:$port/index.html" >/dev/null 2>&1; then
    ( cd "$d/artifact" && nohup "$PY" -m http.server "$port" --bind "$BIND" >/dev/null 2>&1 & ) 
  fi
  printf '%-6s %-11s %-46s %s\n' "$port" "$status" "${short:0:46}" "${title:0:44}"
  port=$((port + 1))
done
printf '%s\n' "---------------------------------------------------------------------------------------------"
printf 'bound to %s   * = excluded from analysis\n' "$BIND"
if [ "$BIND" = "127.0.0.1" ]; then
  printf 'to view from your laptop, forward the ports over ssh:\n  gcloud compute ssh VM --zone ZONE --'
  p=$BASE; while [ "$p" -lt "$port" ]; do printf ' -L %s:localhost:%s' "$p" "$p"; p=$((p+1)); done; echo
fi
