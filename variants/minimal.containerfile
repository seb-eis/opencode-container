# Minimal variant: system CLI tools only, no language toolchains.
#
# Node is inherited from the base image because the OpenCode CLI is distributed
# as an npm package; nothing else (Rust, .NET, Python, ruff) is installed.
#
# Build: make build CONTAINERFILE=variants/minimal.containerfile IMAGE_TAG=minimal
# Run:   OPENCODE_IMAGE=opencode:minimal ./opencode

FROM node:22-trixie-slim

ENV HOME=/home/node \
    LANG=C.UTF-8 \
    NPM_CONFIG_PREFIX=/home/node/.local \
    PATH="/home/node/.local/bin:${PATH}"

# --------------------------------------------------
# System tools (no compilers, no language runtimes)
# --------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git jq less procps \
        ripgrep fd-find sqlite3 tree \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# --------------------------------------------------
# Directories: create every path you chown
# --------------------------------------------------
RUN mkdir -p \
    /home/node/.config/opencode \
    /home/node/.local/bin \
    /home/node/.local/share/opencode/snapshot \
    /home/node/.cache \
    /workspace \
    /tmp/opencode \
    && chown -R node:node /home/node /workspace /tmp/opencode

# --------------------------------------------------
# Everything below runs as the runtime user
# --------------------------------------------------
USER node

RUN npm install --global --cache /tmp/npm-cache @opencode/cli@2.2.4 \
    && rm -rf /tmp/npm-cache

# --------------------------------------------------
# Verification as the actual runtime user
# --------------------------------------------------
RUN set -eux; \
    git --version; \
    rg --version; \
    fd --version; \
    jq --version; \
    sqlite3 --version; \
    opencode --version; \
    test -w /home/node/.config/opencode; \
    test -w /home/node/.local/share/opencode; \
    test -w /home/node/.local/share/opencode/snapshot

# Guard: root must not own anything in the runtime user's home
RUN test -z "$(find /home/node -user root -print -quit)"

WORKDIR /workspace

ENTRYPOINT ["opencode"]
