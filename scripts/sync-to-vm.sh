#!/usr/bin/env bash
#
# sync-to-vm.sh VM_NAME [ZONE]
#
# Push the pipeline and the EXISTING RESULTS to the VM.
#
#   ./scripts/sync-to-vm.sh open-vs-closed-oneshot-website-vm us-central1-a
#
# What goes:
#   - the git repo (pipeline, pinned skill, prompts, config)
#   - experiment-config/models.env       (the key; gitignored, so rsync'd)
#   - each existing run's ARTIFACT + records only, so the sites are viewable
#
# What deliberately does NOT go:
#   - workspace/  (source, evidence captures)   ~250 MB
#   - .tmp/ .harness-tmp/ node_modules/
#   - trajectories/ and the 5.9 GB kilo session DB
# Those are historical detail; the sites and their provenance are what you
# asked to view on the VM. Runs performed ON the VM record everything in full,
# exactly as they do locally -- this trimming applies only to back-filling
# results that already exist here.

set -euo pipefail
VM="${1:?usage: sync-to-vm.sh VM_NAME [ZONE]}"
ZONE="${2:-us-central1-a}"
EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="~/open-vs-closed"

command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found"; exit 127; }

echo "=== 1/3 pipeline (git-tracked files) ==="
gcloud compute ssh "$VM" --zone "$ZONE" --command "mkdir -p $REMOTE_DIR" -- -q
git -C "$EXP_ROOT" ls-files -z | rsync -az --files-from=- --from0 \
  -e "gcloud compute ssh $VM --zone $ZONE --" \
  "$EXP_ROOT/" ":$REMOTE_DIR/" 2>/dev/null \
  || { echo "  (rsync-over-gcloud unavailable; falling back to tar)"; \
       git -C "$EXP_ROOT" archive --format=tar HEAD \
       | gcloud compute ssh "$VM" --zone "$ZONE" --command "tar -x -C $REMOTE_DIR" -- -q; }

echo "=== 2/3 secret (models.env, never committed) ==="
gcloud compute scp "$EXP_ROOT/experiment-config/models.env" \
  "$VM:$REMOTE_DIR/experiment-config/models.env" --zone "$ZONE" -q
gcloud compute ssh "$VM" --zone "$ZONE" -q \
  --command "chmod 600 $REMOTE_DIR/experiment-config/models.env"

echo "=== 3/3 existing results (artifacts + records only) ==="
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
for d in "$EXP_ROOT"/runs/*/; do
  [ -d "$d/artifact" ] || continue
  id="$(basename "$d")"
  mkdir -p "$STAGE/runs/$id"
  cp -R "$d/artifact" "$STAGE/runs/$id/" 2>/dev/null || true
  for f in run.json worker-report.json metadata.json status.txt \
           .finalization.json interventions.jsonl record-normalizations.jsonl \
           directional-controls.txt catalog-validate.txt OPERATOR-INVALIDATION.md; do
    [ -f "$d/$f" ] && cp "$d/$f" "$STAGE/runs/$id/" 2>/dev/null || true
  done
done
[ -d "$EXP_ROOT/runs/.oneshot-provenance" ] && cp -R "$EXP_ROOT/runs/.oneshot-provenance" "$STAGE/runs/"
[ -d "$EXP_ROOT/metadata" ] && cp -R "$EXP_ROOT/metadata" "$STAGE/"
echo "  staged: $(find "$STAGE" -type f | wc -l | tr -d ' ') files, $(du -sh "$STAGE" | awk '{print $1}')"

tar -C "$STAGE" -czf "$STAGE/../ovc-results.tgz" . 2>/dev/null
gcloud compute scp "$STAGE/../ovc-results.tgz" "$VM:/tmp/ovc-results.tgz" --zone "$ZONE" -q
gcloud compute ssh "$VM" --zone "$ZONE" -q \
  --command "tar -xzf /tmp/ovc-results.tgz -C $REMOTE_DIR && rm -f /tmp/ovc-results.tgz && echo '  extracted'"
rm -f "$STAGE/../ovc-results.tgz"

cat <<MSG

done. On the VM:
  cd ~/open-vs-closed
  sudo bash scripts/vm-bootstrap.sh && bash scripts/vm-bootstrap.sh --user
  ./scripts/build-sandbox.sh
  ./scripts/verify-environment.sh
  ./scripts/serve-artifacts.sh            # view the sites
MSG
