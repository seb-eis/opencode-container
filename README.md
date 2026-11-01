# opencode-container

A podman image and launcher for running the [OpenCode](https://opencode.ai) CLI in a
single-user, disposable container with a polyglot toolchain — no sudo, runtime
tools installed per-user. The container is effectively self-maintaining: because
the image ships the OpenCode CLI, starting it from the repository root mounts the
checkout at `/workspace`, so the agent that changes the image definition, pinned
versions, and docs runs inside the image it describes and can lint and
health-check the result. That mount is only needed for this purpose — otherwise
the launcher just mounts whatever directory you start it from — and rebuilds
still happen on the host with `make rebuild`, so nothing is installed into the
running container.

> **Scope:** a local, single-user OpenCode setup for work, balancing security
> against convenience: the working directory and `~/.config` are mounted writable,
> credentials are stored in plaintext, and the agent runs commands as your user.
> It is deliberately not a hardened sandbox — running sensitive data or untrusted
> code is still possible, with weaker isolation than a hardened setup; whether
> that fits depends on your threat model.

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
required; language toolchains are installed per-user inside the image.

### Default image (standard)

The default variant is the shared base plus the full toolchain: rustup, .NET SDK
10.0.403, Python 3, pip/venv, ruff, cmake, ninja, yq, gcc/g++, gdb, strace,
ltrace, pkg-config, and the OpenCode CLI. The base itself provides Debian 13
(trixie), Node 22, the OpenCode CLI, and a common toolbox: `file`,
`unzip`/`zip`, `zstd`, `lsof`, `iproute2` (`ss`/`ip`), `psmisc`, `man-db`,
`openssh-client`, `rsync`, `xxd`, `shellcheck`, `shfmt`, and `git-lfs`.

Debian's `yq` package is the Python-based 3.x implementation, not mikefarah's
v4; its syntax differs from v4 examples. It lives in the standard variant only,
which already has Python.

### Variants and the shared base

The common system setup lives in `variants/base.containerfile` exactly once. It
is not a user-selectable variant: every runnable variant builds `FROM
${BASE_IMAGE}` (`opencode:base`) and adds only its own toolchain. All images share
the same launcher contract (`USER node`, `/workspace`, `ENTRYPOINT opencode`).

| Containerfile | Contains | Build |
| --- | --- | --- |
| `base` | Shared base: Debian 13, Node 22, the common toolbox, OpenCode CLI. Not selectable | `make base` |
| `standard` (default) | Base + rustup, .NET SDK, Python 3, ruff, cmake, ninja, yq, compilers/debuggers | `make build` |
| `minimal` | Base only (includes the common toolbox) | `make build VARIANT=minimal` |
| `python` | Base + Python 3 (`python3`, `pip`, `venv`) | `make build VARIANT=python` |

Each variant maps to the `opencode:<name>` tag (or `<IMAGE_NAME>:<name>` if
`IMAGE_NAME` is set): `opencode:standard`, `opencode:minimal`, `opencode:python`.
`base` is reserved: `VARIANT=base` is rejected by `make` and `--variant base` is
rejected by the launcher. Build a variant first, then run it:

```sh
make build VARIANT=minimal       # builds opencode:base, then opencode:minimal
./opencode --variant minimal     # runs the minimal image
```

Variant names are validated against `[a-z0-9-]`; errors list the available
variant names. `VARIANT` is the only way to select a containerfile —
`CONTAINERFILE=` is no longer supported.

### Selecting a variant

- `--variant NAME` / `-v NAME` / `--variant=NAME` on the launcher, or
  `OPENCODE_VARIANT=NAME`. A selected variant (flag or env var) wins over
  `OPENCODE_IMAGE`; an explicit flag wins over `OPENCODE_VARIANT`.
- `OPENCODE_IMAGE=opencode:custom` is used only when no variant is selected.
- The name must match `variants/<name>.containerfile`; path traversal (e.g.
  `-v ../x`) is rejected.
- `base` is reserved for the shared base image and cannot be selected.

## Build system

| Target | Description |
| --- | --- |
| `make build` | Builds `opencode:base`, then the default `standard` image (cached layers). |
| `make rebuild` | Rebuilds the base and the selected variant with `--no-cache`. |
| `make rebuild VARIANT=<name>` | Rebuilds the base and that variant without cache. |
| `make base` / `make rebuild-base` | Builds / rebuilds the shared `opencode:base` image. |
| `make clean VARIANT=<name>` | `podman image rm -f opencode:<name>`. |
| `make clean-base` | `podman image rm -f opencode:base`. |
| `make lint` | Checks that every runnable variant builds `FROM ${BASE_IMAGE}`. |
| `make check` | Builds the base and each variant, then runs the common health check inside every image. |
| `make install-token` | Prompts for a GitHub username and token, verifies it against `api.github.com`, and writes it to `$GITCONFIG/credentials` (default `<repo>/.config/git/credentials`). |

`make` with no target is equivalent to `make build`. Set `IMAGE_NAME` to change
the image name prefix (`opencode` by default).

## Launcher (`opencode`)

The launcher script (`opencode`) resolves the image and mounts the current working
directory at `/workspace`. It does not require being run from the repository root —
any directory will work, and that directory becomes the mounted `/workspace`. It
also mounts the repository's `.config/` and, when the podman secret exists, the
repository's `opencode.json`. It parses options until the first non‑option
argument, so subcommands (`./opencode run "…"`, `./opencode serve`) pass through
unchanged; `--` stops option parsing explicitly.

### Secrets and container user configuration

The launcher uses an existing podman secret named `openai_api_key`; it does not
read `OPENAI_API_KEY` or create the secret itself. When the secret exists, the
launcher passes `--secret openai_api_key` and mounts the repository's
`opencode.json` read-only at `/home/node/.config/opencode/opencode.json`. That
file points the OpenAI provider at `{file:/run/secrets/openai_api_key}`. Create
the secret without putting the key in argv, for example:

```sh
read -rsp 'OpenAI API key: ' OPENAI_API_KEY; echo
printf '%s' "$OPENAI_API_KEY" | podman secret create openai_api_key -
unset OPENAI_API_KEY
```

If no `openai_api_key` secret exists, the launcher runs without the secret and
without the `opencode.json` mount.

The container user configuration `/home/node/.config` is the repository's
`.config/` directory (override with `OPENCODE_USERCONFIG`), mounted writable to
share tool configuration and credentials, e.g. `.config/git`. It is
**intentionally gitignored** because it carries secrets such as
`.config/git/credentials` and `.config/opencode/service.json`; never commit it.
Because the mount is writable, container-written secrets and config are visible
in the host checkout.

### Variant selection

| Flag / env | Effect |
| --- | --- |
| `--variant NAME` / `-v NAME` | Selects `opencode:<name>`; name must match a `variants/*.containerfile`. |
| `--variant=NAME` | Same, using `=`. |
| `OPENCODE_VARIANT=NAME` | Same, via environment. |
| `OPENCODE_IMAGE=…` | Used only when no variant is selected. |

`base` is reserved for the shared base image and is rejected by the launcher.

### What it mounts

| Host | Container | Notes |
| --- | --- | --- |
| `$(pwd)` | `/workspace` | Your project; primary persistent work area. |
| volume `opencode-data` | `~/.local/share/opencode` | Sessions, logs, shell history. |
| `<repo-directory>/.config/` | `~/.config/` | Writable config/credentials (gitignored); override with `OPENCODE_USERCONFIG`. |
| `<repo-directory>/opencode.json` | `~/.config/opencode/opencode.json` | Read-only; only when the `openai_api_key` secret exists. |
| tmpfs | `~/.local/share/opencode/snapshot` | Wiped on every run. |

The launcher also sets `GIT_CONFIG_GLOBAL=/home/node/.config/git/config` and runs
with working directory `/workspace`.

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
`$GITCONFIG/credentials` with mode `600`. `GITCONFIG` defaults to
`<repo>/.config/git`, the directory mounted at `~/.config/git` in the container;
set `OPENCODE_GITCONFIG` to override it. Running `install-token.sh` directly
without `GITCONFIG` uses the same repo default. Re-running replaces the existing
`@github.com` entry and preserves other hosts. Only the single‑line URL form is
used, because that is the only format `git credential-store` can read back.

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
2. Prompt OpenCode to integrate the change in the repository. Common system
   packages, directories, the OpenCode CLI, and the common health check belong in
   `variants/base.containerfile` and `scripts/verify-common.sh`; variant-specific
   toolchains go in the relevant `variants/<name>.containerfile` (bump a pinned
   version, extend the `apt-get` list, add a step and its check in the `USER node`
   verification block). Update `docs/AGENTS.md` (the canonical copy;
   `/workspace/AGENTS.md` is a symlink) and this README to match. If you want to
   add or change tools that do not fit the existing variants, create a new named
   variant with its own `variants/<variant-name>.containerfile` that starts with
   `FROM ${BASE_IMAGE}`.
3. Exit the container and rebuild:
   ```sh
   make lint                     # variants must build FROM the shared base
   make rebuild                  # base + default (standard) image
   make rebuild VARIANT=minimal  # or any other variant
   make check                    # common health check inside every variant
   ```
4. Start the wrapper again and prompt OpenCode for a self health check, using the
   repository as the source of truth: every command in the verification blocks must
   run as `node`, the pinned versions in `variants/*.containerfile`,
   `docs/AGENTS.md`, and this README must agree, and the "no root‑owned files
   under `/home/node`" guard must pass (the runtime snapshot tmpfs is the one
   expected exception).

Example prompts:

- "Bump ruff to 0.18.0: update the pin in `variants/standard.containerfile`, the
  verification block, and the version list in `docs/AGENTS.md`."
- "Add a common CLI tool: extend `variants/base.containerfile`, add it to
  `scripts/verify-common.sh`, and update `docs/AGENTS.md` and this README."
- "Health check this image: run everything in the `USER node` verification blocks
  as the runtime user and report any mismatch with docs/AGENTS.md."

`make build` reuses cached layers, so use `make rebuild` after tool changes to
exercise the whole chain.

## Launcher knobs

| Variable | Default |
| --- | --- |
| `OPENCODE_IMAGE` | `opencode:standard` — used only when no variant is selected |
| `OPENCODE_VARIANT` | unset — selects `opencode:<variant>`; `--variant` overrides it |
| `OPENCODE_VOLUME` | `opencode-data` |
| `OPENCODE_USERCONFIG` | `<repo-directory>/.config/` |

`OPENCODE_GITCONFIG` is not a launcher knob; it only overrides where
`make install-token` writes (default `<repo>/.config/git`).

## Persistence

| Location | Persists across runs? |
| --- | --- |
| `/workspace` | Host directory — yes. Put all work here. |
| `~/.local/share/opencode` | Named podman volume `opencode-data` — yes (sessions, logs, shell history). |
| `<repo-directory>/.config/` | Repository `.config/` mounted at `~/.config/` — yes (gitignored config + credentials; override with `OPENCODE_USERCONFIG`). |
| `~/.local/share/opencode/snapshot` | tmpfs, mode `1777` — **wiped every run**. Do not store anything needed later. |
| `/`, `/tmp`, rest of `$HOME` | Container‑local — lost on exit. |

## License

MIT — see [LICENSE](LICENSE).