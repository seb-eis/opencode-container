# AGENTS.md

Instructions for agent runs inside this container. Read before changing anything.

## What this workspace is

`/workspace` is a host bind mount (`$(pwd):/workspace:Z`) into a single-user podman
container that ships the OpenCode CLI and a polyglot toolchain. The project
content is `opencode/`, the container image and launcher definition.
`/workspace/AGENTS.md` is a symlink to `opencode/docs/AGENTS.md`, the canonical
copy:

| Path | Purpose |
| --- | --- |
| `opencode/variants/base.containerfile` | Shared base: common system setup for every variant (not user-selectable) |
| `opencode/variants/standard.containerfile` | Default variant: shared base + full toolchain |
| `opencode/variants/minimal.containerfile` | Shared base only |
| `opencode/variants/python.containerfile` | Shared base + Python 3 |
| `opencode/scripts/verify-common.sh` | Common health check run by the base build and `make check` |
| `opencode/scripts/check-variants.sh` | Builds each runnable variant and runs the common health check (used by `make check`) |
| `opencode/.containerignore` | Keeps `.config/`, `.git/` out of the podman build context |
| `opencode/makefile` | `make build`/`rebuild` (base + variant), `make base`, `make clean`, `make lint`, `make check`, `make install-token`; selects a variant with `VARIANT=<name>` |
| `opencode/install-token.sh` | Stores/rotates the GitHub token in the credential helper file |
| `opencode/opencode` | Launcher: `podman run ... "$IMAGE" "$@"` |
| `opencode/opencode.json` | Maps the OpenAI provider to the `openai_api_key` podman secret; mounted read-only when the secret exists |
| `opencode/.config/` | Gitignored, mounted at `~/.config`; holds git credentials and `service.json` |
| `opencode/README.md` | User-facing build/run/token documentation |
| `opencode/LICENSE` | MIT license |
| `opencode/.gitignore` | Keeps `.config/`, credentials, and service config out of git |

## Runtime environment (verified)

- Debian GNU/Linux 13 (trixie), user `node` (uid/gid 1000), `$HOME=/home/node`.
- userns `keep-id`, `--cap-drop=ALL` (CapEff `0000000000000000`),
  `--security-opt=no-new-privileges`, `--init`. **No sudo, no setuid escalation.**
- 16 vCPU, ~14 GiB RAM. Network egress works (npm, curl, dotnet).
- `PATH` order: `~/.local/bin`, `~/.cargo/bin`, `~/.dotnet`, then system.
  `NPM_CONFIG_PREFIX=~/.local`, so `npm i -g` needs no root.

Installed versions:

```
node 22.23.4     npm 10.9.9       opencode 2.2.4   git 2.47.3
rg 14.1.1        fd 10.2.0        jq 1.7           sqlite3 3.46.1
python 3.13.5    pip 25.1.1       ruff 0.17.3
dotnet SDK 10.0.403 (~/.dotnet)   rustc/cargo 1.99.1 (rustup)
gcc/g++/gdb/make, strace, ltrace, pkg-config, tree, less, procps
```

`fd` is a symlink to `fdfind`. `opencode2` on PATH is the same CLI.

## Persistence: what survives a run

| Location | Persistence |
| --- | --- |
| `/workspace` | Host directory — persists. Put all work here. |
| `~/.local/share/opencode` | Named podman volume `opencode-data` — persists (sessions, logs, shell history). |
| `~/.config` | Repository `<repo>/.config/` mounted at `~/.config` (`OPENCODE_USERCONFIG` overrides) — persists (gitignored git config, credentials, and `service.json`). |
| `~/.local/share/opencode/snapshot` | **tmpfs**, mode `1777` — wiped every run. `git init` works, but never store anything needed later. |
| `/`, `/tmp`, rest of `$HOME` | Container-local — lost on exit. |

`/tmp/opencode` is pre-created and approved for scratch work.

## Gotchas

- **No sudo.** Install per-user only: `npm i -g` (→ `~/.local`), `pip --user`/venv,
  `rustup`, `dotnet-install.sh --install-dir "$DOTNET_ROOT"`.
- **Do not write to `opencode.db`.** It is a live SQLite DB owned by the running
  OpenCode service (`~/.local/share/opencode/opencode.db` plus `-wal`/`-shm`).
  Read-only queries with `sqlite3 -readonly` are OK; writes can corrupt sessions.
- **Never create root-owned files under `/home/node`.** The image build ends with
  `test -z "$(find /home/node -user root -print -quit)"` and will fail.
- **Git config lives in the mounted repo `.config/`.** The launcher mounts
  `<repo>/.config/` at `~/.config/` (override with `OPENCODE_USERCONFIG`) and
  sets `GIT_CONFIG_GLOBAL=/home/node/.config/git/config`, so
  `git config --global` persists across runs in the repository checkout. That
  directory is gitignored by design because it carries credentials and
  `service.json`. Identity is set in `.config/git/config` to
  `<username> <email>`; commits are authored as that, so do not change it unless
  asked. Credentials live in
  `.config/git/credentials` — see [Secrets](#secrets). Never commit tokens or put
  them in tracked files; the gitignored `.config/git/credentials` is the intended
  location.
- **Pushing needs consent.** Never push to `main` or to a branch you did not create
  yourself without asking first — see [Pushing and branches](#pushing-and-branches).
- **Never print or expose the mounted git credentials.** Do not `cat`, grep,
  search, copy, or otherwise read `.config/git/credentials` into the transcript,
  shell logs, or any tool output — see [Secrets](#secrets).
- **Secrets are one `cat` away from permanent.** Everything printed is captured in
  the transcript, `~/.local/share/opencode/shell/<project>/` and `opencode.db`.
  Read [Secrets](#secrets) before touching a token, key, or password.
- `~/.local/share/opencode/shell/<project>/` and `tool-output/` contain captured
  shell output from earlier sessions; treat as logs, not source — and remember
  they may already contain pasted secrets.

## Pushing and branches

A push is the one git action that is hard to take back, so treat it as requiring
consent:

- **Never push to `main`** (or any other long-lived or shared branch) unless the
  user asked for that push in the current conversation. An earlier "publish this"
  does not cover later commits.
- **Never push to a branch you did not create yourself** — including branches you
  merely checked out, remote-tracking branches, and branches belonging to a PR.
- Pushing to a branch you created in this session, other than `main`, is fine.
- **If in doubt, prompt.** Always prompt for: force-push (`--force`,
  `--force-with-lease`), deleting or renaming a remote branch, pushing tags,
  rewriting published history, or changing a repository's visibility.
- Preferred shape: `git switch -c agent/<topic>`, commit, push that branch, then
  offer a PR instead of touching `main`.

Local commits are fine; the gate is on `git push` and anything that lands on a
remote (`gh pr merge`, `gh release create`, API writes).

## Secrets

Treat every secret as already logged. Anything that reaches stdout/stderr lands in
the transcript, in `~/.local/share/opencode/shell/<project>/` and in
`opencode.db`; there is no "just this once".

**Never print, read, or otherwise expose the mounted git credentials.** The file
`<repo>/.config/git/credentials` (mounted at `~/.config/git/credentials`) must
not be `cat`ed, grepped, searched, copied, hashed, or passed to any command whose
output could enter the context. Do not use recursive searches or shell globs that
may match it. If a check is unavoidable, use `git credential fill` and print only
a boolean or a short prefix. If it is exposed, treat the token as compromised:
revoke it on GitHub, then rotate it with `make -C opencode install-token`.

| Secret | Where it lives | Notes |
| --- | --- | --- |
| GitHub token (classic PAT, scopes `repo`, `read:org`, `workflow`, account `<username>`) | `<repo>/.config/git/credentials` (mounted at `~/.config/git/credentials`), mode `600` | Plaintext. Written by `make -C opencode install-token` (which defaults to the repo `.config/git`), read by git via `credential.helper 'store --file=...'`. |
| OpenCode server password | `<repo>/.config/opencode/service.json` (mounted at `~/.config/opencode/service.json`) | Never print, copy, or commit; gitignored. |
| Host git credentials | host `~/.config/git/credentials` | Only the same file if `OPENCODE_USERCONFIG`/`OPENCODE_GITCONFIG` points the mount/writer at the host config; otherwise repo-local and independent. |

Install or rotate a token:

```sh
make -C opencode install-token                        # prompts, input hidden
make -C opencode install-token GITHUB_USER=<username>  # prompts for token only
GITHUB_TOKEN=... make -C opencode install-token        # non-interactive
SKIP_VERIFY=1 ...                                      # offline
```

It verifies against `api.github.com` (prints login + scopes, never the token),
replaces any existing `@github.com` line, preserves other hosts, and writes
`https://user:token@github.com`. `make -C opencode install-token` defaults to
`<repo>/.config/git/credentials`; `OPENCODE_GITCONFIG` overrides the destination.
**Only that single-line form works** — `git credential-store` silently ignores
the `protocol=`/`host=` multi-line form.
Read it back without printing it:

```sh
pass=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | sed -n 's/^password=//p')
```

Leak channels — all observed in practice, not hypothetical:

| Channel | Why it leaks | Instead |
| --- | --- | --- |
| `cat`/`grep`/`jq` on the credentials file | Whole token in the transcript and shell logs | `git credential fill`, then print only a prefix or a length |
| `curl -H "Authorization: Bearer $T"` | Header is `argv`; any same-uid process sees it in `ps` | `printf 'header = "..."\n'` to stdin and `curl --config -` |
| `make ... GITHUB_TOKEN=...` | Token is in make's `argv` and in the expanded recipe line | Use the prompt, or export in the environment |
| `export GITHUB_TOKEN=...` | Readable via `/proc/<pid>/environ`, inherited by every child | Prefer stdin; `unset` immediately after use |
| `sh -x`, `make -n`, `SHELL='sh -x'` | Echoes the recipe and variables | Never trace token-handling code |
| `printf '...\nTOKEN\n' \| make install-token` | The token becomes a command in shell history | Use the hidden prompt |
| `git remote add https://user:token@host/...` | Token is persisted in `.git/config` and copied by clones | Token-free remotes; let the helper supply auth |
| Any token in tracked repo files | Persists in the host repo and can be pushed | Never; use the gitignored `.config/git/credentials` |
| `git config credential.helper` change, repo-local helper, `GIT_ASKPASS` | Can silently bypass the store and prompt or write elsewhere | Keep the global helper; set `GIT_TERMINAL_PROMPT=0` for non-interactive runs |
| `git -c credential.helper='store --file=...'` while testing | **Appends** to the helper chain instead of replacing it; `reject`/`approve` are sent to *every* helper, so a test `reject` erases the real entry too | Isolate with `GIT_CONFIG_GLOBAL=/dev/null` and a temp file, or back up `~/.config/git/credentials` first |

`stty -echo` in `install-token.sh` only stops the characters appearing on screen.
It does not protect the token from `ps`, `/proc`, shell tracing, or any process
running as uid 1000 — the file is plaintext by design (that is what git's `store`
helper is).

If a token leaks: revoke it on GitHub first, then re-run `make -C opencode install-token`.
`gh` is not installed; if you add it, do not use `gh auth login` (its config under
`~/.config/gh` is container-local and lost on exit) — derive `GH_TOKEN` per
command from the credential file instead.

## Changing the image

1. Common packages and system setup go in `opencode/variants/base.containerfile`;
   variant-specific toolchains go in `opencode/variants/<name>.containerfile`.
   Keep pinned versions (opencode 2.2.4, ruff 0.17.3, rust 1.99.1,
   dotnet 10.0.403) unless the task is to upgrade.
2. Add common checks to `opencode/scripts/verify-common.sh`; add variant-specific
   checks to the `USER node` verification block in that variant. Every new binary
   should be exercised as the runtime user, not root.
3. Build and test:
   ```sh
   make -C opencode lint                   # every variant must build FROM ${BASE_IMAGE}
   make -C opencode build                  # base + default (standard)
   make -C opencode build VARIANT=minimal  # base + any other variant
   make -C opencode check                  # common health check in every variant
   cd opencode && ./opencode               # mounts the repo at /workspace
   ```
   Or verify a build without the TUI: `podman run --rm opencode:standard <cmd>`.
   `VARIANT=<name>` is the only way to select a containerfile; `CONTAINERFILE=`
   is no longer supported, and `base` is reserved for the shared base image.

Launcher knobs (see `opencode/opencode`): `OPENCODE_IMAGE` (default
`opencode:standard`, used only when no variant is selected), `OPENCODE_VARIANT`
(selects `opencode:<name>`; `--variant` overrides it), `OPENCODE_VOLUME` (default
`opencode-data`), `OPENCODE_USERCONFIG` (default `<repo>/.config/`).
`OPENCODE_GITCONFIG` is a make/install-token knob only.
