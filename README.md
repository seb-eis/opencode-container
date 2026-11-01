# opencode-container

A podman image and launcher for running the [OpenCode](https://opencode.ai) CLI in a
single-user, disposable container with a polyglot toolchain — no sudo, runtime
tools installed per-user. This repository defines the image and provides the
make/launcher tooling.

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

The default variant includes the full toolchain: Debian 13 (trixie), Node 22,
rustup, .NET SDK 10.0.403, Python 3, pip/venv, ruff, gcc/g++, gdb, strace,
ltrace, pkg-config, and the OpenCode CLI.

### Variants

Three variants are provided in `variants/`, each with the same launcher contract
(`USER node`, `/workspace`, `ENTRYPOINT opencode`):

| Variant | Contains | Build |
| --- | --- | --- |
| `standard` (default) | Full toolchain: rustup, .NET SDK, Python 3, ruff, compilers/debuggers, Node + OpenCode CLI | `make build` |
| `minimal` | System CLI tools only — `git`, `rg`, `fd`, `jq`, `sqlite3`, `tree`, `less`, `procps`, `curl`, plus the Node runtime the CLI needs | `make build VARIANT=minimal` |
| `python` | Minimal plus Python 3 (`python3`, `pip`, `venv`) | `make build VARIANT=python` |

Each variant maps to the `opencode:<name>` tag (or `<IMAGE_NAME>:<name>` if
`IMAGE_NAME` is set): `opencode:standard`, `opencode:minimal`, `opencode:python`.
Build a variant first, then run it:

```sh
make build VARIANT=minimal       # -f variants/minimal.containerfile -t opencode:minimal
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

## Build system

| Target | Description |
| --- | --- |
| `make build` | Builds the default `standard` image (cached layers). |
| `make rebuild` | Builds with `--no-cache`, exercising the whole chain. |
| `make rebuild VARIANT=<name>` | Builds a variant without cache. |
| `make clean VARIANT=<name>` | `podman image rm -f opencode:<name>`. |
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
2. Prompt OpenCode to integrate the change in the repository: adjust the relevant
   `variants/<name>.containerfile` (bump a pinned version, extend the `apt-get`
   list, add a step and its check in the `USER node` verification block) and
   update `docs/AGENTS.md` (the canonical copy; `/workspace/AGENTS.md` is a
   symlink) and this README to match. If you want to add or change tools that do
   not fit the existing variants, create a new named variant with its own
   `variants/<variant-name>.containerfile`.
3. Exit the container and rebuild:
   ```sh
   make rebuild                  # default (standard) image
   make rebuild VARIANT=minimal  # or any other variant
   ```
4. Start the wrapper again and prompt OpenCode for a self health check, using the
   repository as the source of truth: every command in the verification block must
   run as `node`, the pinned versions in `variants/*.containerfile`,
   `docs/AGENTS.md`, and this README must agree, and the "no root‑owned files
   under `/home/node`" guard must pass.

Example prompts:

- "Bump ruff to 0.18.0: update the pin in `variants/standard.containerfile`, the
  verification block, and the version list in `docs/AGENTS.md`."
- "Health check this image: run everything in the `USER node` verification block
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