# Minimal variant: the shared base and nothing else.
#
# Build: make build VARIANT=minimal
# Run:   ./opencode --variant minimal

ARG BASE_IMAGE=opencode:base
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="opencode minimal"
