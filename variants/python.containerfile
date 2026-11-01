# Python variant: shared base plus the Python 3 toolchain.
#
# No Rust, .NET or ruff. Add python3-dev and build-essential if you need to
# compile C extensions.
#
# Build: make build VARIANT=python
# Run:   ./opencode --variant python

ARG BASE_IMAGE=opencode:base
FROM ${BASE_IMAGE}

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER node

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

# Verification as the actual runtime user.
RUN set -eux; \
    python3 --version; \
    python3 -m pip --version; \
    tmp="$(mktemp -d)"; \
    trap 'rm -rf "$tmp"' EXIT; \
    python3 -m venv "$tmp/venv"; \
    "$tmp/venv/bin/python" -c 'import sys; print(sys.version.split()[0])'; \
    "$tmp/venv/bin/pip" install --quiet --no-input six; \
    "$tmp/venv/bin/python" -c 'import six; print(six.__version__)'

# Guard: root must not own anything in the runtime user's home.
RUN test -z "$(find /home/node -user root -print -quit)"

WORKDIR /workspace

ENTRYPOINT ["opencode"]
