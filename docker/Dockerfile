# Sandbox image for one open-vs-closed run.
#
# Each run executes in its own container with ONLY its own run directory and a
# read-only copy of the pinned skill mounted. It cannot see sibling runs, other
# prompts, the experiment metadata, or the README/protocol that name both models
# and describe the comparison. That makes experiment isolation ENFORCED rather
# than merely instructed -- a model performing the skill's required
# write-boundary self-audit finds nothing revealing to read.
FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# chromium: the skill's directional-control browser gate drives it over CDP.
# It lives INSIDE the sandbox so that verification is sandboxed too.
# python3: the skill's coordinator helpers (stdlib only, needs >= 3.11;
#          bookworm ships 3.11).
# git/ca-certificates/curl: ordinary build tooling a lead may reasonably use.
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium \
      python3 python3-venv \
      git curl ca-certificates \
      fonts-liberation fonts-dejavu-core \
      procps \
    && rm -rf /var/lib/apt/lists/*

# Kilo CLI, version-pinned exactly as on the host so both arms and both
# platforms share one harness version.
ARG KILO_VERSION=7.5.6
RUN npm install -g "@kilocode/cli@${KILO_VERSION}" \
    && npm cache clean --force

ENV ONESHOT_WEBSITES_PYTHON=/usr/bin/python3 \
    ONESHOT_WEBSITES_BROWSER=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium \
    npm_config_update_notifier=false

# Non-root: a run should not be able to modify the image or escalate.
RUN useradd -m -u 1001 runner && mkdir -p /work && chown runner:runner /work
USER runner
WORKDIR /work

# Sanity: fail the build rather than discover a missing tool mid-experiment.
RUN kilo --version && python3 --version && chromium --version && node --version
