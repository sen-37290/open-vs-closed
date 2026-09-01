#!/usr/bin/env bash
#
# vm-bootstrap.sh — provision a fresh Debian 12 (bookworm) VM to run this
# experiment. Idempotent: safe to re-run.
#
#   sudo bash scripts/vm-bootstrap.sh          # system packages + docker
#   bash scripts/vm-bootstrap.sh --user        # per-user tools (uv, kilo)
#
# After this: create experiment-config/models.env with OPENROUTER_API_KEY,
# then ./scripts/build-sandbox.sh && ./scripts/verify-environment.sh

set -euo pipefail
MODE="${1:-}"

if [ "$MODE" != "--user" ]; then
  [ "$(id -u)" -eq 0 ] || { echo "run the system phase with sudo, or pass --user"; exit 1; }
  echo "=== system packages ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git rsync jq unzip \
    python3 python3-venv \
    chromium \
    build-essential \
    tmux screen \
    lsof procps

  echo "=== node 22 (for the host-side kilo CLI) ==="
  if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi

  echo "=== docker engine (the run sandbox) ==="
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  fi
  systemctl enable --now docker

  # let the invoking user run docker without sudo
  TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
  [ -n "$TARGET_USER" ] && usermod -aG docker "$TARGET_USER" && \
    echo "added $TARGET_USER to the docker group (log out and back in for it to apply)"

  echo
  echo "system phase done. Now run WITHOUT sudo:  bash scripts/vm-bootstrap.sh --user"
  exit 0
fi

echo "=== user tools ==="
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
uv python install 3.13 || true

if ! command -v kilo >/dev/null 2>&1; then
  npm install -g @kilocode/cli@7.5.6 2>/dev/null \
    || sudo npm install -g @kilocode/cli@7.5.6
fi

echo
echo "versions:"
printf '  %-10s %s\n' node "$(node --version 2>/dev/null)" \
                      npm "$(npm --version 2>/dev/null)" \
                      kilo "$(kilo --version 2>/dev/null | tail -1)" \
                      uv "$(uv --version 2>/dev/null)" \
                      docker "$(docker --version 2>/dev/null)" \
                      chromium "$(chromium --version 2>/dev/null)"
cat <<'MSG'

next:
  1. cp experiment-config/models.example.env experiment-config/models.env
     and set OPENROUTER_API_KEY
  2. ./scripts/build-sandbox.sh
  3. ./scripts/verify-environment.sh        # expect ALL CHECKS PASSED
MSG
