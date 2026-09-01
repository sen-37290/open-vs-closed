#!/usr/bin/env bash
#
# vm-status.sh [-w] [FILTER]
#
# Run the status board on the VM from your laptop, without SSH-ing in first.
#
#   ./scripts/vm-status.sh              one snapshot of every run
#   ./scripts/vm-status.sh -w           refresh every 30s until Ctrl-C
#   ./scripts/vm-status.sh steam        only runs matching "steam"
#
# Read-only: it never touches a run.

set -uo pipefail
VM="${OVC_VM:-open-vs-closed-oneshot-website-vm}"
ZONE="${OVC_ZONE:-us-central1-a}"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

WATCH=0
[ "${1:-}" = "-w" ] && { WATCH=1; shift; }
FILTER="${1:-}"

remote() {
  gcloud compute ssh "$VM" --zone "$ZONE" -q --command \
    "cd ~/open-vs-closed && ./scripts/status.sh ${FILTER} 2>/dev/null; \
     echo; echo 'containers:'; \
     sg docker -c 'docker ps --filter name=ovc- --format \"  {{.Status}}  {{.Names}}\"' 2>/dev/null \
       | sed 's/ovc-[0-9-]*-open-vs-closed-//'" 2>&1 | grep -v '^Warning:'
}

if [ "$WATCH" = 1 ]; then
  while :; do clear; remote; echo; echo "(refreshing every 30s — Ctrl-C to stop)"; sleep 30; done
else
  remote
fi
