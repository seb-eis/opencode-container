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
escalation; for a one-off, install per-user with `npm i -g` (into `~/.local`),
`pip --user`, `rustup` or `dotnet-install.sh`. Anything you want to keep belongs in
the image instead — see [Upgrade or add tools](#upgrade-or-add-tools).

## Upgrade or add tools

The image is the source of truth for the toolchain — change it in the repository,
not by installing into a running container (it is `--rm`, so ad-hoc installs are
lost). The loop is:

1. Start the wrapper from the repository root, so the repository itself is mounted
   at `/workspace`:

   ```sh
   ./opencode
   ```

2. Prompt OpenCode to integrate the change in the repository: adjust the
   `containerfile` (bump a pinned version, extend the `apt-get` list, add a step
   and its check in the `USER node` verification block) and update
   `docs/AGENTS.md` and this README to match.

3. Exit the container and rebuild:

   ```sh
   make rebuild
   ```

4. Start the wrapper again and prompt OpenCode for a self health check, using the
   repository as the source of truth: every command in the verification block must
   run as `node`, the pinned versions in `containerfile` and `docs/AGENTS.md` must
   agree, and the "no root-owned files under `/home/node`" guard must pass.

Example prompts:

- "Bump ruff to 0.18.0: update the containerfile pin, the verification block, and
  the version list in docs/AGENTS.md."
- "Health check this image: run everything in the `USER node` verification block
  as the runtime user and report any mismatch with docs/AGENTS.md."

`make build` reuses cached layers, so use `make rebuild` after tool changes to
exercise the whole chain.

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
