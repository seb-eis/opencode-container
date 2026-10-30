# AGENTS.md

Instructions for agent runs inside this container. Read before changing anything.

## What this workspace is

`/workspace` is a host bind mount (`$(pwd):/workspace:Z`) into a single-user podman
container that ships the OpenCode CLI and a polyglot toolchain. The only project
content currently here is `opencode/`, the container image definition:

| Path | Purpose |
| --- | --- |
| `opencode/containerfile` | Image build: Debian 13, Node 22, toolchains (all per-user) |
| `opencode/makefile` | `make build`, `make rebuild` (no cache), `make clean`, `make install-token` |
| `opencode/install-token.sh` | Stores/rotates the GitHub token in the credential helper file |
| `opencode/opencode` | Launcher: `podman run ... "$IMAGE" "$@"` |

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
gcc/g++/gdb/make, strace, ltrace, pkg-config, tree
```

`fd` is a symlink to `fdfind`. `opencode2` on PATH is the same CLI.

## Persistence: what survives a run

| Location | Persistence |
| --- | --- |
| `/workspace` | Host directory — persists. Put all work here. |
| `~/.local/share/opencode` | Named podman volume `opencode-data` — persists (sessions, logs, shell history). |
| `~/.config/git` | Host `~/.config/git` bind mount (`OPENCODE_GITCONFIG` overrides) — persists (global git config + credentials). |
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
- **Global git config is host-backed.** `~/.config/git` is bind-mounted from the
  host (override with `OPENCODE_GITCONFIG`), and `GIT_CONFIG_GLOBAL` points at it,
  so `git config --global` persists across runs. Identity is set to
  `Sebastian Eisele <sebastian.eisele@rwth-aachen.de>`; commits are authored as
  that, so do not change it unless asked. Credentials live in
  `~/.config/git/credentials` — see [Secrets](#secrets). Never store tokens in
  `/workspace`.
- **Secrets are one `cat` away from permanent.** Everything printed is captured in
  the transcript, `~/.local/share/opencode/shell/<project>/` and `opencode.db`.
  Read [Secrets](#secrets) before touching a token, key, or password.
- `~/.local/share/opencode/shell/<project>/` and `tool-output/` contain captured
  shell output from earlier sessions; treat as logs, not source — and remember
  they may already contain pasted secrets.

## Secrets

Treat every secret as already logged. Anything that reaches stdout/stderr lands in
the transcript, in `~/.local/share/opencode/shell/<project>/` and in
`opencode.db`; there is no "just this once".

| Secret | Where it lives | Notes |
| --- | --- | --- |
| GitHub token (classic PAT, scopes `repo`, `read:org`, `workflow`, account `seb-eis`) | `~/.config/git/credentials`, mode `600`, host bind mount | Plaintext. Written by `make -C opencode install-token`, read by git via `credential.helper 'store --file=...'`. |
| OpenCode server password | `~/.config/opencode/service.json` | Never print, copy, or commit. |
| Host git credentials | same file as the GitHub token | Shared with the host user; rotating it affects host git too. |

Install or rotate a token:

```sh
make -C opencode install-token                        # prompts, input hidden
make -C opencode install-token GITHUB_USER=seb-eis     # prompts for token only
GITHUB_TOKEN=... make -C opencode install-token        # non-interactive
SKIP_VERIFY=1 ...                                      # offline
```

It verifies against `api.github.com` (prints login + scopes, never the token),
replaces any existing `@github.com` line, preserves other hosts, and writes
`https://user:token@github.com`. **Only that single-line form works** —
`git credential-store` silently ignores the `protocol=`/`host=` multi-line form.
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
| Any token in `/workspace` | Persists in the host repo and can be pushed | Never; use the credential file |
| `git config credential.helper` change, repo-local helper, `GIT_ASKPASS` | Can silently bypass the store and prompt or write elsewhere | Keep the global helper; set `GIT_TERMINAL_PROMPT=0` for non-interactive runs |
| `git -c credential.helper='store --file=...'` while testing | **Appends** to the helper chain instead of replacing it; `reject`/`approve` are sent to *every* helper, so a test `reject` erases the real entry too | Isolate with `GIT_CONFIG_GLOBAL=/dev/null` and a temp file, or back up `~/.config/git/credentials` first |

`stty -echo` in `install-token.sh` only stops the characters appearing on screen.
It does not protect the token from `ps`, `/proc`, shell tracing, or any process
running as uid 1000 — the file is plaintext by design (that is what git's `store`
helper is).

If a token leaks: revoke it on GitHub first, then re-run `make install-token`.
`gh` is not installed; if you add it, do not use `gh auth login` (its config under
`~/.config/gh` is container-local and lost on exit) — derive `GH_TOKEN` per
command from the credential file instead.

## Changing the image

1. Edit `opencode/containerfile`. Keep pinned versions (opencode 2.2.4, ruff
   0.17.3, rust 1.99.1, dotnet 10.0.403) unless the task is to upgrade.
2. Extend the `USER node` verification block when adding a tool — every new
   binary should be exercised as the runtime user, not root.
3. Build and test:
   ```sh
   make -C opencode build      # or: make -C opencode rebuild (--no-cache)
   ./opencode/opencode         # mounts the current dir at /workspace
   ```
   Or verify a build without the TUI: `podman run --rm opencode:latest <cmd>`.

Launcher knobs (see `opencode/opencode`): `OPENCODE_IMAGE` (default
`opencode:latest`), `OPENCODE_VOLUME` (default `opencode-data`),
`OPENCODE_GITCONFIG` (default host `~/.config/git`).
