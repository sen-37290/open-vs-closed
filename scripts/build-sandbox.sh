#!/usr/bin/env bash
# Build the run sandbox image. Pinned to the same Kilo version as the host so
# both arms and both platforms share one harness version.
set -euo pipefail
EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KILO_VERSION="${KILO_VERSION:-7.5.6}"
IMAGE="${SANDBOX_IMAGE:-ovc-sandbox:$KILO_VERSION}"
echo "building $IMAGE (kilo $KILO_VERSION)"
docker build --build-arg "KILO_VERSION=$KILO_VERSION" -t "$IMAGE" -f "$EXP_ROOT/docker/Dockerfile" "$EXP_ROOT/docker"
echo
docker run --rm "$IMAGE" sh -c 'echo "  kilo:     $(kilo --version 2>/dev/null | tail -1)"; echo "  python:   $(python3 --version)"; echo "  chromium: $(chromium --version)"; echo "  node:     $(node --version)"'
