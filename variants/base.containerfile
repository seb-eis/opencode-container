# Shared base image for the opencode variants.
#
# This is deliberately not a user-selectable variant: every
# variants/*.containerfile builds FROM ${BASE_IMAGE}, so the common system
# setup lives in exactly one place.
#
# Standalone build: make base
# Variants build it automatically: make build / make build VARIANT=<name>

FROM node:22-trixie-slim

ENV HOME=/home/node \
    LANG=C.UTF-8 \
    NPM_CONFIG_PREFIX=/home/node/.local \
    PATH="/home/node/.local/bin:${PATH}"

# --------------------------------------------------
# Common system packages. Variant-specific packages belong in the variant.
# These are Debian trixie packages (unpinned); keeping the list here guarantees
# every variant gets the same basic toolbox.
# --------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git ripgrep fd-find jq sqlite3 less procps \
        tree file unzip zip zstd lsof iproute2 psmisc man-db openssh-client \
        rsync xxd shellcheck shfmt git-lfs bzip2 xz-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# --------------------------------------------------
# Common directories. Variants create their own toolchain directories.
# --------------------------------------------------
RUN mkdir -p \
    /home/node/.config/opencode \
    /home/node/.local/bin \
    /home/node/.local/share/opencode \
    /home/node/.local/share/opencode/snapshot \
    /home/node/.cache \
    /workspace \
    /tmp/opencode \
    && chown -R node:node /home/node /workspace /tmp/opencode

# The same health check runs at build time and from `make check` in every
# derived image.
COPY scripts/verify-common.sh /usr/local/lib/opencode/verify-common.sh
RUN chmod 0755 /usr/local/lib/opencode/verify-common.sh

# --------------------------------------------------
# Everything below runs as the runtime user.
# --------------------------------------------------
USER node

RUN npm install --global --cache /tmp/npm-cache @opencode/cli@2.2.4 \
    && rm -rf /tmp/npm-cache

RUN /usr/local/lib/opencode/verify-common.sh

# Guard: root must not own anything in the runtime user's home.
RUN test -z "$(find /home/node -user root -print -quit)"

WORKDIR /workspace

ENTRYPOINT ["opencode"]
