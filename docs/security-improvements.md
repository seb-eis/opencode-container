# Possible security improvements

> **Status:** proposal only. Neither option below is implemented. The current
> launcher still mounts the GitHub credential file and the `opencode_api_key`
> Podman secret into the container.

This note records two possible future improvements to credential handling. They
are alternatives, not a package that has to be adopted together.

## Current credential handling

| Credential | Where it is today | Why it matters |
| --- | --- | --- |
| GitHub token | `<repo>/.config/git/credentials`, plaintext, mode `600`, read by `credential.helper=store --file ...` | The whole `.config/` directory is mounted writable at `~/.config`, so any process in the container can read the token. |
| OpenCode API key | Podman secret `opencode_api_key`, mounted at `/run/secrets/opencode_api_key` and read by `opencode.json` via `{file:/run/secrets/opencode_api_key}` | A Podman secret is a plaintext file in a tmpfs; it is convenient, but it is not a boundary against a compromised container. |

Both credentials are revocable. The practical concerns are accidental disclosure
(reading the file into a transcript, log, or session database), credential theft
by code running in the container, and reuse of a stolen credential after the
container has exited.

The options below do not protect against a compromised host. They reduce what a
compromised **container** can take away, and they change a durable raw secret
into a capability that is only usable while the container is running.

## Option 1: SSH agent for Git

This is the smaller, lower-risk change. It removes the GitHub token from the
container and replaces it with access to a host-side SSH agent. The private key
never enters the container.

### Design

```
container: git -> ssh -> /run/opencode-ssh/agent.sock
                                      |
                                      v
host: dedicated ssh-agent (one GitHub key) -> github.com:22
```

The container can ask the agent to sign an SSH authentication challenge. It
cannot read the private key.

Recommended mode: start a **dedicated per-run agent** with a GitHub-only key.
Mounting the normal host agent socket is simpler but exposes every key in that
agent, including unrelated server keys.

### Host setup

Use a dedicated key, ideally a per-repository deploy key rather than an
account-wide key:

```sh
ssh-keygen -t ed25519 -C "opencode-container" -f ~/.ssh/id_ed25519_opencode
# Add ~/.ssh/id_ed25519_opencode.pub to GitHub or as a deploy key.
ssh -T git@github.com
```

Add the GitHub host key to `~/.ssh/known_hosts` by verifying the fingerprint
against GitHub's published keys.

### Git configuration

The current configuration rewrites SSH remotes to HTTPS:

```ini
url.https://github.com/.insteadOf = git@github.com:
```

For this option the direction must be reversed. Remove the old rewrite and the
credential helper from the shared `.config/git/config`, then add a
container-only include at launch:

```ini
# /run/opencode-ssh/gitconfig
[url "git@github.com:"]
    insteadOf = https://github.com/

[core]
    sshCommand = ssh -F /run/opencode-ssh/ssh_config
```

Pass the include with `GIT_CONFIG_COUNT` so the persistent git config is not
polluted with container-only paths:

```sh
-e GIT_CONFIG_COUNT=1 \
-e GIT_CONFIG_KEY_0=include.path \
-e GIT_CONFIG_VALUE_0=/run/opencode-ssh/gitconfig
```

Set `GIT_TERMINAL_PROMPT=0` so a missing agent fails fast instead of prompting.

An existing remote such as
`https://github.com/seb-eis/opencode-container.git` will then be used as
`git@github.com:seb-eis/opencode-container.git`. The rewrite also covers other
repositories and most submodule URLs.

### SSH configuration

Generate a minimal config per run:

```sshconfig
# /run/opencode-ssh/ssh_config
Host github.com
    User git
    IdentityAgent /run/opencode-ssh/agent.sock
    IdentitiesOnly yes
    UserKnownHostsFile /run/opencode-ssh/known_hosts
    StrictHostKeyChecking yes
```

For networks that block port 22, use GitHub's SSH-over-443 endpoint:

```sshconfig
Host github.com
    HostName ssh.github.com
    Port 443
    HostKeyAlias github.com
    User git
    IdentityAgent /run/opencode-ssh/agent.sock
    IdentitiesOnly yes
    UserKnownHostsFile /run/opencode-ssh/known_hosts
    StrictHostKeyChecking yes
```

Prefer extracting the GitHub entry from the host `known_hosts` with
`ssh-keygen -F github.com`. Do not use `StrictHostKeyChecking=no`. If no host key
is available, fail with instructions rather than silently trusting a scanned
key; an explicit opt-in `OPENCODE_SSH_SCAN=1` may use `ssh-keyscan`.

### Launcher lifecycle

Create a per-run directory, start the agent, add only the GitHub key, generate
the config files, mount the socket and configs, and clean up on exit:

```sh
run_dir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/opencode-ssh.XXXXXX")
chmod 700 "$run_dir"

eval "$(ssh-agent -s -a "$run_dir/agent.sock")" >/dev/null
ssh_pid=$SSH_AGENT_PID
ssh-add -t "${OPENCODE_SSH_KEY_TTL:-8h}" \
    "${OPENCODE_SSH_KEY:-$HOME/.ssh/id_ed25519_opencode}"

cleanup() {
    [ -n "${ssh_pid:-}" ] && kill "$ssh_pid" 2>/dev/null || true
    rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

podman run --rm -it \
    ... \
    --mount type=bind,src="$run_dir/agent.sock",dst=/run/opencode-ssh/agent.sock \
    --mount type=bind,src="$run_dir/ssh_config",dst=/run/opencode-ssh/ssh_config,ro \
    --mount type=bind,src="$run_dir/known_hosts",dst=/run/opencode-ssh/known_hosts,ro \
    --mount type=bind,src="$run_dir/gitconfig",dst=/run/opencode-ssh/gitconfig,ro \
    -e SSH_AUTH_SOCK=/run/opencode-ssh/agent.sock \
    -e GIT_TERMINAL_PROMPT=0 \
    -e GIT_CONFIG_COUNT=1 \
    -e GIT_CONFIG_KEY_0=include.path \
    -e GIT_CONFIG_VALUE_0=/run/opencode-ssh/gitconfig \
    ...
```

The launcher currently uses `exec podman run`; this option requires running
Podman in the foreground so the cleanup trap can stop the agent.

If using the existing host agent instead, resolve `SSH_AUTH_SOCK` with
`readlink -f`, mount that socket, and do not start or kill an agent. Warn that
all keys in the host agent become available to the container.

### Security properties and limits

- The private key stays on the host; the container gets a signing capability.
- A GitHub account SSH key is account-wide. A per-repo deploy key is narrower.
- `ssh-add -t` limits the key lifetime; a dedicated agent limits which keys are
  exposed. `ssh-add -c` can require host-side confirmation per use.
- The socket directory must be mode `700`; `--userns=keep-id` makes the socket
  owned by the same UID inside the container.
- Do not mount `~/.ssh` or any private key.
- SELinux-enforcing hosts may deny the socket bind mount; use an appropriate
  label or a dedicated runtime directory rather than relabelling the whole
  `$XDG_RUNTIME_DIR`.
- Git LFS is not covered: GitHub LFS transfers over HTTPS and may still need a
  token or a separately configured LFS credential.
- `gh` and GitHub REST API calls are not covered; they need a token if used.
- Host compromise still bypasses the improvement.

### Integration points

- `opencode` launcher: agent lifecycle, mounts, environment, cleanup.
- `.config/git/config`: remove the credential helper and the old SSH-to-HTTPS
  rewrite.
- `.config/git/credentials`: delete after verifying SSH.
- `README.md` and `AGENTS.md`: replace the token-first documentation with
  SSH setup; keep the token as an optional LFS/API fallback.
- No image change is required: `openssh-client` is already installed and
  `verify-common.sh` already checks `ssh -V`.

### Tests

```sh
ssh-add -l                         # only the intended key
ssh -T git@github.com              # authenticated, but no shell
git ls-remote origin
git push origin HEAD:refs/heads/test-branch
git config --show-origin --get-regexp 'url|credential|sshCommand'
```

Also verify that removing the agent socket makes Git fail rather than fall back
to HTTPS, that no `id_*` private key exists in the container, and that
submodules and port 443 work if they are used.

## Option 2: Host credential proxy for Git and the API key

This is the larger option. A host-side reverse proxy holds both secrets and
injects the correct authentication header. The container receives only a proxy
URL, a per-run capability token that is not the real credential, and a dummy API
key.

```
┌──────────────── container ────────────────┐      ┌──────────── host ────────────┐
│ opencode.json                             │      │ opencode-proxy               │
│   baseURL -> proxy/inference/go/...       │─────▶│  /inference/go/*             │──Bearer──▶ opencode.ai
│   apiKey = dummy                          │      │                              │
│   X-Proxy-Auth = <per-run token>          │      │  git listener                │──Basic───▶ github.com
│                                           │      │                              │
│ git config                                │      │ reads host-only secrets      │
│   insteadOf https://github.com/ -> proxy  │─────▶│                              │
└───────────────────────────────────────────┘      └──────────────────────────────┘
```

### Transport

Two viable transports:

1. **Preferred: Unix socket plus a tiny `socat` bridge in the container.** The
   host proxy listens on sockets under `$XDG_RUNTIME_DIR`; the container mounts
   them read-only and bridges them to loopback TCP. This avoids host port
   exposure and `host.containers.internal` binding ambiguity, at the cost of
   adding `socat` and an entrypoint wrapper.
2. **Simpler: TCP on `host.containers.internal`.** In this environment that name
   currently resolves to `169.254.1.2`, not `127.0.0.1`, so a loopback-only host
   listener is not enough. Bind to the Podman gateway or `0.0.0.0` with a
   firewall scoped to the Podman network, and always require the capability
   token.

### Routes and authentication

| Route | Upstream | Injected auth |
| --- | --- | --- |
| `/inference/go/openai/**` | `https://opencode.ai` | `Authorization: Bearer <opencode key>` |
| `/inference/go/anthropic/**` | `https://opencode.ai` | `x-api-key: <opencode key>` |
| `/inference/go/google/**` | `https://opencode.ai` | `x-goog-api-key: <opencode key>` |
| Git smart HTTP paths | `https://github.com` | `Authorization: Basic base64(<user>:<token>)` |
| Optional `/api.github.com/**` | `https://api.github.com` | `Authorization: Bearer <token>` |

The proxy should strip inbound `Authorization`, `x-api-key`, `x-goog-api-key`,
`Cookie`, and `Proxy-Authorization`; preserve `x-opencode-session`, `User-Agent`,
`Accept`, `Content-Type`, and `Git-Protocol`; rewrite same-host redirects only;
reject `CONNECT` and unknown paths; and avoid logging headers, bodies, or tokens.
For streaming, flush each chunk and use `Accept-Encoding: identity` for SSE.

### OpenCode configuration

The current `opencode.json` uses the deprecated V1 `provider.options` shape. The
V2 form uses `providers.<id>.settings`. The current model is
`opencode-go/deepseek-v4.1-flash`, whose upstream is:

```
https://opencode.ai/inference/go/openai/v1/chat/completions
```

Models in the `opencode-go` catalog currently declare their own `provider.api`
endpoint, which OpenCode turns into model-level settings. Set the override on
the model (or verify that a provider-level `settings.baseURL` is honored by your
OpenCode version) rather than assuming provider-level is enough:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode-go/deepseek-v4.1-flash",
  "providers": {
    "opencode-go": {
      "settings": {
        "apiKey": "proxy"
      },
      "models": {
        "deepseek-v4.1-flash": {
          "settings": {
            "baseURL": "http://127.0.0.1:18787/inference/go/openai/v1"
          },
          "headers": {
            "X-Proxy-Auth": "{env:OPENCODE_PROXY_TOKEN}"
          }
        }
      }
    }
  }
}
```

Replace `127.0.0.1` with `host.containers.internal` for the TCP transport.
Anthropic- and Google-family models need their own model-level `baseURL` paths
if they are used. Any unproxied model will send the dummy key directly upstream
and fail closed.

### Git configuration

```ini
[url "http://127.0.0.1:18788/"]
    insteadOf = https://github.com/

[http "http://127.0.0.1:18788/"]
    extraHeader = X-Proxy-Auth: <per-run-token>
```

Remove the credential helper and do not mount `.config/git/credentials`. Set
`GIT_TERMINAL_PROMPT=0` and allow only Git smart HTTP and, if needed, LFS paths
on the git listener.

### Host secrets and launcher

Store the real secrets outside the repository, for example:

```
~/.config/opencode-host/       # mode 700
├── github-user                # 0600
├── github-token               # 0600
├── opencode-key               # 0600
└── proxy.json                 # 0644, non-secret
```

Prefer an OS keyring, `pass`, or `systemd-creds` over plaintext files. The
launcher should start the proxy per run, pass only a random capability token and
the proxy URLs to the container, remove `--secret opencode_api_key`, and stop the
proxy on exit. The proxy must read secrets from files/stdin, never from argv, and
must not log them.

### Security properties and limits

- Neither real credential enters the container.
- The capability token grants only the allowlisted proxy operations while the
  container runs.
- The proxy is a confused-deputy endpoint: the agent can still use the allowed
  Git and LLM capabilities, and can still exfiltrate data through allowed
  channels.
- A misconfigured or broadly bound proxy can be worse than a local secret file.
  Bind narrowly, require the capability token, and keep the allowlist small.
- Host compromise still bypasses the improvement.
- The proxy sees request bodies, including prompts and source code. Do not log
  them and protect the host process accordingly.

### Integration points

- New host-side proxy source and tests.
- `opencode` launcher: proxy lifecycle, capability token, mounts, removal of the
  Podman secret and credential file.
- `opencode.json`: V2 provider shape, proxy `baseURL`, dummy key, capability
  header.
- `.config/git/config`: proxy URL rewrite and capability header.
- `install-token.sh`: write host-only secrets instead of the repo `.config`.
- `README.md` and `AGENTS.md`: secret storage and rotation.
- `variants/base.containerfile`: only for the Unix-socket transport, add
  `socat` and an entrypoint bridge.

### Tests

- `git ls-remote` and `git push` through the git listener with no token file.
- `opencode run "say hi"` streams through the LLM listener.
- No real secret in `env`, `/run/secrets`, `~/.config`, or the container
  filesystem.
- Stop the proxy; Git and OpenCode fail closed.
- The proxy rejects unknown paths, missing capability tokens, `CONNECT`, and
  non-allowlisted upstream hosts.
- Proxy logs contain no credentials, prompts, or bodies.

## Comparison

| | SSH agent for Git | Full host proxy |
| --- | --- | --- |
| Covers | Git only | Git and the OpenCode API key |
| Complexity | Low to medium | High |
| Image changes | None | Optional `socat` for the Unix-socket transport |
| Container receives | Agent signing capability | Proxy capability and a dummy API key |
| Git LFS | Not covered | Can be covered by allowing LFS paths |
| GitHub API / `gh` | Not covered | Optional `api.github.com` route |
| Main risk | Broad agent keys if the host agent is reused | Confused-deputy proxy and more moving parts |
| Host compromise | Not mitigated | Not mitigated |
| Best fit | Personal, trusted-code use | Untrusted code, broad tokens, or a need to keep the API key out of the container |

## Suggested order

1. Start with the SSH agent option for Git. It removes the most exposed
   credential from the container with no image change.
2. Add the full proxy only if the OpenCode API key must also stay out of the
   container, or if Git must remain on HTTPS.
3. In both cases, rotate the old credentials after cutover: they have been
   readable inside the container and may already appear in shell logs, tool
   output, or session history.

## Non-goals

Neither option turns this setup into a hardened sandbox. The agent still has
network access, can run commands as the container user, and can use any
capability it is given. The repository's existing scope note still applies.
