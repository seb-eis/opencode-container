#!/bin/sh
# Store a GitHub token for git/gh in the credential helper file of the local repo.
#
# Usage:  make install-token [GITHUB_USER=<login>] [GITHUB_TOKEN=<token>]
#
# GITCONFIG overrides the destination directory; it defaults to
# <repo>/.config/git (the launcher's mounted config directory).
#
# The token is taken from $GITHUB_TOKEN if set, otherwise prompted for with
# echo disabled. Only the single-line URL form is written, because that is the
# only format `git credential-store` can read back.
set -eu

# get container repo location
self=$(readlink -f -- "$0" 2>/dev/null || printf '%s\n' "$0")
repo_dir=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)

CREDENTIALS="${GITCONFIG:-$repo_dir/.config/git}/credentials"
user="${GITHUB_USER:-}"
token="${GITHUB_TOKEN:-}"

die() {
	echo "error: $*" >&2
	exit 1
}

if [ -z "$user" ]; then
	printf 'GitHub username: '
	read -r user || die "no username given"
fi

if [ -z "$token" ]; then
	printf 'GitHub token for %s (input hidden): ' "$user"
	if [ -t 0 ]; then
		stty -echo
		trap 'stty echo' EXIT INT TERM
	fi
	read -r token || die "no token given"
	if [ -t 0 ]; then
		stty echo
		trap - EXIT INT TERM
	fi
	printf '\n'
fi

[ -n "$user" ] || die "empty username"
[ -n "$token" ] || die "empty token"

# Both values are embedded in a URL-ish line, so refuse anything that could
# break the format or inject a second entry.
case "$user" in
*[!A-Za-z0-9-]*) die "username '$user' contains unexpected characters" ;;
esac
case "$token" in
*[!A-Za-z0-9_]*) die "token contains unexpected characters (expected [A-Za-z0-9_])" ;;
esac

if [ "${SKIP_VERIFY:-0}" != 1 ]; then
	if ! command -v curl >/dev/null 2>&1; then
		echo "warning: curl not found, skipping token verification" >&2
	else
		body=$(mktemp)
		head=$(mktemp)
		trap 'rm -f "$body" "$head"' EXIT INT TERM
		# Keep the token out of argv/ps by passing the headers via stdin.
		code=$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$token" |
			curl --config - -sS -o "$body" -D "$head" -w '%{http_code}' \
				https://api.github.com/user) || code=000
		if [ "$code" != 200 ]; then
			echo "error: GitHub rejected the token (HTTP $code)" >&2
			sed -n 's/.*"message": *"\([^"]*\)".*/  GitHub says: \1/p' "$body" >&2 || true
			exit 1
		fi
		login=$(sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' "$body" | head -n 1)
		scopes=$(sed -n 's/^[Xx]-[Oo]auth-[Ss]copes: *//p' "$head" | tr -d '\r')
		echo "verified: token belongs to '${login:-unknown}'"
		if [ -n "$scopes" ]; then
			echo "scopes: $scopes"
		else
			echo "scopes: none reported (fine-grained token, or no scopes)"
		fi
		if [ -n "$login" ] && [ "$login" != "$user" ]; then
			echo "warning: token login '$login' differs from username '$user'" >&2
		fi
		rm -f "$body" "$head"
		trap - EXIT INT TERM
	fi
fi

dir=$(dirname "$CREDENTIALS")
mkdir -p "$dir"
chmod 700 "$dir"

umask 077
tmp="$CREDENTIALS.tmp.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
# Drop any previous github.com entry so re-running replaces instead of piling up.
{ [ -f "$CREDENTIALS" ] && grep -v '@github\.com' "$CREDENTIALS"; } >"$tmp" 2>/dev/null || true
printf 'https://%s:%s@github.com\n' "$user" "$token" >>"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$CREDENTIALS"
chmod 600 "$CREDENTIALS"
trap - EXIT INT TERM

# Prove the store can read back what we just wrote.
if command -v git >/dev/null 2>&1; then
	# Reset the helper chain so the round-trip reads only this file, not the
	# global helper (which may point at a different credentials file).
	got=$(printf 'protocol=https\nhost=github.com\n\n' |
		git -c credential.helper= -c credential.helper="store --file=$CREDENTIALS" credential fill 2>/dev/null |
		sed -n 's/^password=//p') || got=
	[ "$got" = "$token" ] || die "credential store round-trip failed for $CREDENTIALS"
fi

echo "stored GitHub credential for '$user' in $CREDENTIALS (mode 600)"
