#!/bin/sh
# Build each runnable variant and run the common health check inside it.
# Invoked by `make check`; kept in a script so `make -n check` stays a dry run.
set -eu
cd "$(dirname "$0")/.."

image_name=${IMAGE_NAME:-opencode}
for variant in "$@"; do
	make --no-print-directory build VARIANT="$variant"
	podman run --rm --entrypoint sh "$image_name:$variant" \
		/usr/local/lib/opencode/verify-common.sh
done
