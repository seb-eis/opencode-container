# opencode-container

A podman image and launcher for running the [OpenCode](https://opencode.ai) CLI in a
disposable, single-user container with a polyglot toolchain — no sudo, everything
installed per-user.

## Contents

| Path | Purpose |
| --- | --- |
| `containerfile` | Image build: Debian 13 (trixie), Node 22, rustup, .NET SDK, ruff, OpenCode CLI |
| `makefile` | `make build`, `make rebuild` (no cache), `make clean`, `make install-token` |
| `install-token.sh` | Stores/rotates a GitHub token in the persistent credential file |
| `opencode` | Launcher: `podman run ... "$IMAGE" "$@"` |
| `docs/AGENTS.md` | Notes for agent runs inside the container (runtime, persistence, secret handling) |

## Requirements

- podman (rootless)
- GNU make
- Network access for the image build

## Build

```sh
make build            # cached
make rebuild          # --no-cache
make clean            # remove the image
```

The build installs everything as the runtime user (`node`, uid 1000) and ends with
a verification block that exercises every tool as that user, plus a guard that
nothing under `/home/node` is root-owned.

## Run

```sh
./opencode                    # mounts the current directory at /workspace
./opencode <command> [...]    # run a single command instead of the TUI
```

What the launcher mounts and sets:

| Host | Container | Notes |
| --- | --- | --- |
| `$(pwd)` | `/workspace` | Your project; the only persistent work area |
| volume `opencode-data` | `~/.local/share/opencode` | Sessions, logs, shell history |
| `~/.config/git` | `~/.config/git` | Global git config + credentials |
| tmpfs | `~/.local/share/opencode/snapshot` | Wiped on every run |

The container runs with `--userns=keep-id`, `--cap-drop=ALL`,
`--security-opt=no-new-privileges` and `--init`. There is no sudo and no setuid
escalation; install extra tools with `npm i -g` (into `~/.local`), `pip --user`,
`rustup` or `dotnet-install.sh`.

## GitHub token

```sh
make install-token                      # prompts for username, then token (hidden)
make install-token GITHUB_USER=me       # prompts for the token only
GITHUB_TOKEN=... make install-token     # non-interactive
SKIP_VERIFY=1 ...                       # skip the api.github.com check (offline)
```

The token is verified against `api.github.com` (login + scopes are printed, never
the token), then written as `https://user:token@github.com` to
`${OPENCODE_GITCONFIG:-~/.config/git}/credentials` with mode `600`. Re-running
replaces the existing `@github.com` entry and preserves other hosts. Only the
single-line URL form is used, because that is the only format
`git credential-store` can read back.

Remove it again with:

```sh
printf 'protocol=https\nhost=github.com\n\n' | git credential reject
```

Note that a credential git itself rejects with `401` is erased automatically;
other hosts accumulate until removed explicitly.

## Launcher knobs

| Variable | Default |
| --- | --- |
| `OPENCODE_IMAGE` | `opencode:latest` |
| `OPENCODE_VOLUME` | `opencode-data` |
| `OPENCODE_GITCONFIG` | host `~/.config/git` |

## License

MIT — see [LICENSE](LICENSE).
