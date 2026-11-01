# Python variant: system CLI tools plus the Python 3 toolchain only.
#
# No Rust, .NET or ruff. Add python3-dev and build-essential if you need to
# compile C extensions.
#
# Build: make build VARIANT=python
# Run:   ./opencode --variant python

FROM node:22-trixie-slim

ENV HOME=/home/node \
    LANG=C.UTF-8 \
    NPM_CONFIG_PREFIX=/home/node/.local \
    PATH="/home/node/.local/bin:${PATH}" \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

# --------------------------------------------------
# System tools + Python 3 (no compilers, no other runtimes)
# --------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git jq less procps \
        ripgrep fd-find sqlite3 tree \
        python3 python3-pip python3-venv \
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
    python3 --version; \
    python3 -m pip --version; \
    opencode --version; \
    test -w /home/node/.config/opencode; \
    test -w /home/node/.local/share/opencode; \
    test -w /home/node/.local/share/opencode/snapshot; \
    tmp="$(mktemp -d)"; \
    python3 -m venv "$tmp/venv"; \
    "$tmp/venv/bin/python" -c 'import sys; print(sys.version.split()[0])'; \
    "$tmp/venv/bin/pip" install --quiet --no-input six; \
    "$tmp/venv/bin/python" -c 'import six; print(six.__version__)'; \
    rm -rf "$tmp"

# Guard: root must not own anything in the runtime user's home
RUN test -z "$(find /home/node -user root -print -quit)"

WORKDIR /workspace

ENTRYPOINT ["opencode"]
