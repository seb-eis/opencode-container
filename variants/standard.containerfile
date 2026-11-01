# Standard variant: shared base plus the full polyglot toolchain.
#
# Build: make build            (default)
# Run:   ./opencode

ARG BASE_IMAGE=opencode:base
FROM ${BASE_IMAGE}

# --------------------------------------------------
# Build tools, debuggers and Python (no .NET tooling here)
# --------------------------------------------------
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential gdb pkg-config strace ltrace \
        cmake ninja-build yq \
        python3 python3-pip python3-venv \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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
    && chown -R node:node /home/node/.cargo /home/node/.rustup /home/node/.dotnet

# --------------------------------------------------
# Everything below runs as the runtime user
# --------------------------------------------------
USER node

ENV CARGO_HOME=/home/node/.cargo \
    RUSTUP_HOME=/home/node/.rustup \
    DOTNET_ROOT=/home/node/.dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    PATH="/home/node/.cargo/bin:/home/node/.dotnet:${PATH}"

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

# --------------------------------------------------
# Verification as the actual runtime user
# --------------------------------------------------
RUN set -eux; \
    gcc --version; \
    gdb --version; \
    pkg-config --version; \
    strace --version; \
    ltrace --version; \
    cmake --version; \
    ninja --version; \
    yq --version; \
    python3 --version; \
    python3 -m pip --version; \
    ruff --version; \
    dotnet --version; \
    dotnet --list-sdks; \
    test "$(command -v dotnet)" = "$DOTNET_ROOT/dotnet"; \
    rustc --version; \
    cargo --version; \
    rustup --version; \
    tmp="$(mktemp -d)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    python3 -m venv "$tmp/venv"; \
    "$tmp/venv/bin/python" -c 'import sys; print(sys.version.split()[0])'

# Guard: root must not own anything in the runtime user's home.
RUN test -z "$(find /home/node -user root -print -quit)"

WORKDIR /workspace

ENTRYPOINT ["opencode"]
