#!/bin/sh
# Common health check for every opencode image.
#
# Runs as the runtime user during the base image build and from `make check`
# inside each derived variant. Keep it limited to tools the shared base
# provides; variant-specific checks stay in the variant containerfile.
set -eu

git --version
rg --version
fd --version
jq --version
sqlite3 --version
opencode --version

test -w /home/node/.config/opencode
test -w /home/node/.local/share/opencode
test -w /home/node/.local/share/opencode/snapshot

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" /tmp/npm-cache' EXIT
npm install --cache /tmp/npm-cache --prefix "$tmp" cowsay >/dev/null
"$tmp/node_modules/.bin/cowsay" -t ok >/dev/null
