# opencode-container

A podman image and launcher for running the [OpenCode](https://opencode.ai) CLI in a
single-user, disposable container with a polyglot toolchain — no sudo, everything
installed per-user. The repository at `/workspace/opencode` defines the image and
provides the make/launcher tooling.

## Quick start

| Action | Command |
| --- | --- |
| Build the default image | `make build` |
| Rebuild (no cache) | `make rebuild` |
| Remove the image | `make clean` |
| Select a variant | `make build VARIANT=minimal` or `make build VARIANT=python` |
| Run the default image | `./opencode` |
| Run a variant | `./opencode --variant minimal` or `./opencode -v python` |
| Install / rotate your GitHub token | `make install-token` |

## Container image

The image runs as user `node` (uid 1000) with `--userns=keep-id`,
`--cap-drop=ALL`, `--security-opt=no-new-privileges` and `--init`. No sudo is
required; extra tools are installed per-user inside the image.

### Default image (standard)

The default variant includes the full toolchain: Debian 13 (trixie), Node 22,
rustup, .NET SDK 10.0.403, ruff, and the OpenCode CLI.

### Variants

Three variants are provided in `variants/`, each with the same launcher contract
(`USER node`, `/workspace`, `ENTRYPOINT opencode`):

| Variant | Contains | Build |
| --- | --- | --- |
| `standard` (default) | Full toolchain: rustup, .NET SDK, ruff, Node + OpenCode CLI | `make build` |
| `minimal` | System CLI tools only — `git`, `rg`, `fd`, `jq`, `sqlite3`, `tree`, `less`, `procps`, `curl`, plus the Node runtime the CLI needs | `make build VARIANT=minimal` |
| `python` | Minimal plus Python 3 (`python3`, `pip`, `venv`) | `make build VARIANT=python` |

Each variant maps to the `opencode:<name>` tag: `opencode:standard`,
`opencode:minimal`, `opencode:python`. Build a variant first, then run it:

```sh
make build VARIANT=minimal       # -f variants/minimal.containerfile -t opencode:minimal
./opencode --variant minimal     # runs the minimal image
```

Variant names are validated against `[a-z0-9-]`; errors list the three available
names. You cannot combine `VARIANT` with `CONTAINERFILE`; `CONTAINERFILE=some/path`
still works on its own.

### Selecting a variant

- `--variant NAME` / `-v NAME` / `--variant=NAME` on the launcher, or
  `OPENCODE_VARIANT=NAME` — an explicit flag wins over the env var and over
  `OPENCODE_IMAGE`.
- `OPENCODE_IMAGE=opencode:custom` still overrides everything.
- The name must match `variants/<name>.containerfile`; path traversal (e.g.
  `-v ../x`) is rejected.

## Build system

| Target | Description |
| --- | --- |
| `make build` | Builds the default `standard` image (cached layers). |
| `make rebuild` | Builds with `--no-cache`, exercising the whole chain. |
| `make rebuild VARIANT=<name>` | Builds a variant without cache. |
| `make clean VARIANT=<name>` | `podman image rm -f opencode:<name>`. |
| `make install-token` | Prompts for a GitHub username and token, verifies it against `api.github.com`, and writes it to `.config/git/credentials`. 

## Launcher (`opencode`)

The launcher script (`opencode`) resolves the image and mounts the current working
directory at `/workspace`. It does not require being run from the repository root —
any directory will work, and the repository at that location becomes the mounted
`/workspace`. It parses options until the first non‑option argument, so subcommands
(`./opencode run "…"`, `./opencode serve`) pass through unchanged; `--` stops option
parsing explicitly.

### Secrets and container user configuration

The `OPENAI_API_KEY` is injected as a podman secret named `openai_api_key` by the launcher only if such a secret is defined for podman. It then mounts `opencode.json` to `/home/node/.config/opencode/opencode.json` to point opencode to the podman managed secret location.

The container user configuration `/home/node/.config` is mounted to a writable `.config` directory in the host repository root to share tool configuration and credentials, e.g., for GIT under `.config/git`. Note that this makes some secrets of the container visible to the host.

### Variant selection

| Flag / env | Effect |
| --- | --- |
| `--variant NAME` / `-v NAME` | Selects `opencode:<name>`; name must match a `variants/*.containerfile`. |
| `--variant=NAME` | Same, using `=`. |
| `OPENCODE_VARIANT=NAME` | Same, via environment. |
| `OPENCODE_IMAGE=…` | Overrides the image entirely. |

### What it mounts

| Host | Container | Notes |
| --- | --- | --- |
| `$(pwd)` | `/workspace` | Your project; the only persistent work area. |
| volume `opencode-data` | `~/.local/share/opencode` | Sessions, logs, shell history. |
| `<repo-directory>/.config/` | `~/.config/` | Global user config + credentials (host‑backed). |
| tmpfs | `~/.local/share/opencode/snapshot` | Wiped on every run. |

### Run a single command

```sh
./opencode <command> [...]    # e.g. ./opencode explain this repo
```

Options are consumed only up to the first non‑option argument; everything after
that is forwarded to the OpenCode CLI.

## GitHub token

Store or rotate your token in the persistent credential file:

```sh
make install-token                      # prompts for username, then token (hidden)
make install-token GITHUB_USER=me       # prompts for the token only
GITHUB_TOKEN=... make install-token     # non-interactive
SKIP_VERIFY=1 ...                       # skip the api.github.com check (offline)
```

The token is verified against `api.github.com` (login + scopes are printed, never
the token), then written as `https://user:token@github.com` to
`${GITCONFIG:-$repo_dir/.config/git}/credentials` with mode `600`. Re-running
replaces the existing `@github.com` entry and preserves other hosts. Only the
single‑line URL form is used, because that is the only format
`git credential-store` can read back.

Remove a token:

```sh
printf 'protocol=https\nhost=github.com\n\n' | git credential reject
```

Note that a `401` from git itself erases the entry automatically; other hosts
accumulate until removed explicitly.

## Upgrade or add tools

The image is the source of truth for the toolchain — change it in the repository,
not by installing into a running container (it is `--rm`, so ad‑hoc installs are
lost). The loop is:

1. Start the wrapper from the repository root, so the repository itself is mounted
   at `/workspace`:
   ```sh
   ./opencode
   ```
2. Prompt OpenCode to integrate the change in the repository: adjust the
   `containerfile` (bump a pinned version, extend the `apt-get` list, add a step
   and its check in the `USER node` verification block) and update
   `docs/AGENTS.md` and this README to match. If you want to add or change tools
   that do not fit the existing variants, then prompt to create a new named
   variant with its own `variants/<variant-name>.containerfile`.
3. Exit the container and rebuild:
   ```sh
   make rebuild                  # default (standard) image
   make rebuild VARIANT=minimal  # or any other variant
   ```
4. Start the wrapper again and prompt OpenCode for a self health check, using the
   repository as the source of truth: every command in the verification block must
   run as `node`, the pinned versions in `containerfile` and `docs/AGENTS.md` must
   agree, and the "no root‑owned files under `/home/node`" guard must pass.

Example prompts:

- "Bump ruff to 0.18.0: update the containerfile pin, the verification block,
  and the version list in docs/AGENTS.md."
- "Health check this image: run everything in the `USER node` verification block
  as the runtime user and report any mismatch with docs/AGENTS.md."

`make build` reuses cached layers, so use `make rebuild` after tool changes to
exercise the whole chain.

## Launcher knobs

| Variable | Default |
| --- | --- |
| `OPENCODE_IMAGE` | `opencode:standard` |
| `OPENCODE_VARIANT` | unset — selects `opencode:<variant>`; `--variant` overrides it |
| `OPENCODE_VOLUME` | `opencode-data` |
| `OPENCODE_GITCONFIG` | host `~/.config/git` |

## Persistence

| Location | Persists across runs? |
| --- | --- |
| `/workspace` | Host directory — yes. Put all work here. |
| `~/.local/share/opencode` | Named podman volume `opencode-data` — yes (sessions, logs, shell history). |
| `<repo-directory>/.config/` | Host `~/.config/` bind mount — yes (global user config + credentials). |
| `~/.local/share/opencode/snapshot` | tmpfs, mode `1777` — **wiped every run**. Do not store anything needed later. |
| `/`, `/tmp`, rest of `$HOME` | Container‑local — lost on exit. |

## License

MIT — see [LICENSE](LICENSE).