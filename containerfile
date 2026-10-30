FROM node:22-trixie-slim

ENV HOME=/home/node \
    LANG=C.UTF-8 \
    CARGO_HOME=/home/node/.cargo \
    RUSTUP_HOME=/home/node/.rustup \
    NPM_CONFIG_PREFIX=/home/node/.local \
    DOTNET_ROOT=/home/node/.dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    PATH="/home/node/.local/bin:/home/node/.cargo/bin:/home/node/.dotnet:${PATH}"

# --------------------------------------------------
# System packages (no .NET tooling here)
# --------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git ripgrep fd-find jq sqlite3 \
        build-essential gdb pkg-config strace ltrace \
        python3 python3-pip python3-venv \
        tree \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# --------------------------------------------------
# OS-level native libraries required by the .NET runtime.
# These are the only root-owned pieces of the .NET setup;
# the SDK itself is installed per-user further below.
# --------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libicu76 libssl3t64 libgssapi-krb5-2 libunwind8 zlib1g \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------
# Directories: create every path you chown
# --------------------------------------------------
RUN mkdir -p \
    /home/node/.cargo \
    /home/node/.rustup \
    /home/node/.dotnet \
    /home/node/.config/opencode \
    /home/node/.local/bin \
    /home/node/.local/share/opencode \
    /home/node/.local/share/opencode/snapshot \
    /home/node/.cache \
    /workspace \
    /tmp/opencode \
    && chown -R node:node /home/node /workspace /tmp/opencode

# --------------------------------------------------
# Everything below runs as the runtime user
# --------------------------------------------------
USER node

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain 1.99.1

RUN curl --proto '=https' --tlsv1.2 -LsSf \
    https://astral.sh/ruff/0.17.3/install.sh | sh

# --------------------------------------------------
# .NET SDK - user-local, no root, no Microsoft apt repo
# --------------------------------------------------
# Installs into $DOTNET_ROOT (~/.dotnet) and leaves the
# system untouched. Pin the patch version for reproducibility.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && bash /tmp/dotnet-install.sh --version 10.0.403 --install-dir "$DOTNET_ROOT" --no-path \
    && rm -f /tmp/dotnet-install.sh \
    && dotnet --version

# Install as node into ~/.local (already first on PATH).
# Cache lives in /tmp and is deleted, so no ~/.npm in the image.
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
    gcc --version; \
    gdb --version; \
    pkg-config --version; \
    strace --version; \
    ltrace --version; \
    python3 --version; \
    python3 -m pip --version; \
    ruff --version; \
    dotnet --version; \
    dotnet --list-sdks; \
    test "$(command -v dotnet)" = "$DOTNET_ROOT/dotnet"; \
    rustc --version; \
    cargo --version; \
    rustup --version; \
    opencode --version; \
    test -w /home/node/.config/opencode; \
    test -w /home/node/.local/share/opencode; \
    test -w /home/node/.local/share/opencode/snapshot; \
    tmp="$(mktemp -d)"; \
    npm install --cache /tmp/npm-cache --prefix "$tmp" cowsay >/dev/null; \
    "$tmp/node_modules/.bin/cowsay" -t ok >/dev/null; \
    rm -rf "$tmp" /tmp/npm-cache; \
    python3 -m venv /tmp/venv-probe; \
    /tmp/venv-probe/bin/python -c 'import sys; print(sys.version.split()[0])'; \
    rm -rf /tmp/venv-probe

# Guard: root must not own anything in the runtime user's home
RUN test -z "$(find /home/node -user root -print -quit)"

WORKDIR /workspace

ENTRYPOINT ["opencode"]