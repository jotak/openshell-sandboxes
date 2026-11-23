# OpenShell Setup — Sandboxed agents for NetObserv development

The repo contains a setup for running AI agents with OpenShell, ie. sandboxed.
The provided sandbox(es) have common build tooling for NetObserv development, all baked-in:
Go, node, clang, etc. Sandbox network policy rules are also tuned for netobserv common development tasks.

The agent used here is goose. More agents can be added in a similar way.

- OpenShell docs: https://docs.nvidia.com/openshell/v0.1.8/ (CLI/gateway: v0.1.8)
- goose docs: https://goose-docs.ai/

## Architecture

```
┌─ Host (Fedora) ───────────────────┐    ┌─ OpenShell sandbox "goose-desktop" ─────────┐
│ goose Desktop (RPM)               │    │ (podman container, no network interfaces)   │
│   Settings → Agent →              │    │                                             │
│   External Backend (ACP) ─────────┼────┼─► goose serve --host 127.0.0.1 --port 3199  │
│        https://127.0.0.1:3199     │TLS │   │  (ACP backend, TLS, secret-key auth)    │
│        (openshell forward 3199)   │    │   ├─ LLM → provider profile "enmaas":       │
│                                   │    │   │   $ENMAAS_API_KEY = placeholder;        │
│ openshell CLI ↔ local gateway     │    │   │   real key injected only at             │
│   (https://127.0.0.1:17670, mTLS) │    │   │   api.enmaas.devshift.net/v1/**         │
└───────────────────────────────────┘    │   ├─ FS: /workspace + /home/goose rw,       │
                                         │   │   system paths ro (Landlock)            │
                                         │   └─ Net: default-deny + read-only HTTPS    │
                                         │       allowlist                             │
                                         └─────────────────────────────────────────────┘
```

## Initial setup and Sandbox creation

Prereqs: openshell installed with local gateway running (`openshell status`),
podman (or docker) working. All commands run from the host.

```bash
# 1. Import the provider profile (declares the enmaas endpoint + credential binding)
openshell profile lint -f netobserv/enmaas.yaml
openshell profile import -f netobserv/enmaas.yaml

# 2. Create the provider with the real key  ← the only manual/secret step
openshell provider create --name enmaas --type enmaas --credential ENMAAS_API_KEY=<api key>

# 3. Build the sandbox image (goose CLI + toolchain + goose config; no secrets baked in)
podman build -t localhost/sandbox-netobserv-base:latest -f netobserv/base.Dockerfile .
podman build -t goose-desktop-agent:latest netobserv/goose

# 4. ACP shared secret for goose Desktop ↔ goose serve
umask 077 && openssl rand -hex 32 > netobserv/goose/acp-secret.txt

# 5. Create the sandbox
openshell sandbox create \
  --name goose-desktop \
  --from localhost/goose-desktop-agent:latest \
  --policy netobserv/policy.yaml \
  --provider enmaas \
  --forward 3199 \
  --env GOOSE_SERVER__SECRET_KEY="$(cat netobserv/goose/acp-secret.txt)" \
  --detach \
  -- goose serve --platform desktop --enable-scheduler --host 127.0.0.1 --port 3199 --tls

# 6. Forward the ACP port to host loopback (if not already running from step 5)
openshell forward start 3199 goose-desktop --background
```

## goose Desktop configuration (GUI, one time)

1. Install goose Desktop (RPM from https://goose-docs.ai/docs/getting-started/installation).
2. Configure the Desktop app to use the sandboxed backend:
   In ~/.config/Goose/settings.json:
   ```json
     "externalGoosed": {
       "enabled": false,
       "url": "https://127.0.0.1:3199",
       "secret": (contents of netobserv/goose/acp-secret.txt),
       "workingDir": "/workspace"
     },
   ```
   Or configure from the GUI: Settings → Agent → External Backend (ACP) → Use external backend

## Switching between sandboxed and host goose (jq toggle)

The Desktop's backend choice is a single boolean in `~/.config/Goose/settings.json`
(`externalGoosed.enabled`). **quit goose Desktop first** (the app
keeps settings in memory and overwrites the file on exit), then restart it:

```bash
./enable-sandboxed-goose-backend.sh on
# or
./enable-sandboxed-goose-backend.sh off
```

Notes:

- Both backends can coexist; sessions are kept separately (host sessions stay on the
  host, sandbox sessions live in `/workspace/.local/share/goose/sessions` inside the
  sandbox and survive stop/start, but not a sandbox recreate).
- `settings.json` stores the ACP secret in plain text — keep the file private:
  `chmod 600 ~/.config/Goose/settings.json`.

## Daily operations

```bash
openshell status                                  # gateway health
openshell sandbox list                            # sandbox state
openshell sandbox stop goose-desktop              # stop (workspace preserved)
openshell sandbox start goose-desktop             # start again
openshell forward start 3199 goose-desktop --background   # (re)start ACP forward
openshell logs goose-desktop --since 5m           # logs (policy events included)
openshell sandbox exec -n goose-desktop -- <cmd>  # run a command inside
openshell sandbox upload goose-desktop <path>     # files in (gitignore-aware)
openshell sandbox download goose-desktop <path> ./out   # files out (workdir only)
```

Policy / rule management:

```bash
openshell policy get goose-desktop --full         # effective policy (incl. provider rules)
openshell rule get goose-desktop                  # advisor proposals (pending/approved)
openshell rule approve goose-desktop --chunk-id <id>   # hot-reloads, no restart
openshell rule reject goose-desktop --chunk-id <id> --reason "scope to docs/ only"
openshell rule approve-all goose-desktop          # approve all pending (skips security-flagged)
# Add a read-only domain permanently:
openshell policy update goose-desktop --rule-name web_read_common \
  --add-endpoint '<host>:443:read-only:rest:enforce' --wait
```

## Working with git repos (push/pull scripts)

`sandbox upload` strips `.git`, not configurable. `git clone` from inside the sandbox also
fails per policy. To include git data (with full branches and history) in the sandbox, we
use git bundles. Two scripts wrap the whole round trip:

```bash
./push-to-sandbox.sh /path/to/repo [name-in-sandbox]    # host → sandbox (clone or refresh)
./pull-from-sandbox.sh name-in-sandbox [/path/to/repo]  # sandbox → host (default repo: cwd)
```

The sandbox copy lives at `/workspace/<name-in-sandbox>` (default: the repo's
basename).

**Push (first time)** bundles every branch + tag and uploads it; the bundle stays
at `/workspace/<name>.in.bundle` and serves as the clone's `origin`, so `origin/*`
in the sandbox always means *the uploaded state* (`git diff origin/main` there shows
the agent's work). `/workspace/<name>` is then cloned from it.

**Push (again)** re-uploads the bundle and runs `git fetch origin` inside the sandbox
copy: only `origin/*` refs move — the agent's branches, index and working tree are
never touched. Uncommitted host changes are never shipped (bundles carry commits
only); the script warns on a dirty tree.

**Pull** bundles, inside the sandbox, exactly the commits beyond `origin/*` (the
agent's new work — typically a few kB), downloads it, fetches it into the host repo
under `refs/remotes/sandbox/*`, then integrates, fast-forward-only:

| Situation | Result |
|---|---|
| branch new on the sandbox side | created locally (no upstream set) → `git push -u origin <b>` |
| local branch behind the sandbox one | fast-forwarded (also when it is the checked-out branch) |
| diverged (you committed on the host meanwhile) | left untouched, reported → `git rebase sandbox/<b>` or merge |
| nothing new | "nothing to pull" |

Pulling never pushes and never rewrites a local branch (fast-forwards only), and
the commits keep their exact SHAs — what you push is byte-for-byte what the agent
made. The summary prints the push commands; pushing stays manual.

Opening the sandbox copy in VSCode / Codium:

```bash
code --folder-uri vscode-remote://ssh-remote+openshell-goose-desktop.default/workspace/<name>
```

### Under the hood (raw bundle commands)

```bash
# In: full bundle on the host → upload → clone inside (branches appear as origin/*)
git -C /path/to/repo bundle create /tmp/repo.bundle --all
openshell sandbox upload goose-desktop /tmp/repo.bundle
openshell sandbox exec goose-desktop -- git clone /workspace/repo.bundle /workspace/<name>

# Refresh an existing copy: re-upload the bundle (same path), then inside the sandbox:
openshell sandbox exec goose-desktop -- git -C /workspace/<name> fetch origin

# Out: bundle only the new commits → download → fetch into the real repo
openshell sandbox exec goose-desktop -- sh -c \
  "git -C /workspace/<name> bundle create /workspace/out.bundle --branches --tags \
   \$(git -C /workspace/<name> for-each-ref --format='^%(refname)' refs/remotes/origin)"
openshell sandbox download goose-desktop /workspace/out.bundle
git -C /path/to/repo fetch out.bundle '+refs/heads/*:refs/remotes/sandbox/*'
git -C /path/to/repo merge --ff-only sandbox/main     # per branch — or let the script do it
```

Notes:

- With `.git` present inside (bundle flow), Codium's source-control view shows the
  agent's edits as live diffs against HEAD — plain uploads have no history.
- Commits inside the sandbox are attributed to the user via `/etc/gitconfig`
  (baked into the image, system scope — `HOME=/workspace` has no `.gitconfig`,
  and `/etc` is read-only at runtime so the agent can't change the identity).
- Public-repo history can also be read through the GitHub HTTP API (`api.github.com` is
  covered by the `**.github.com` read-only rule) without moving any files.

## IDE access from the host (Codium Remote-SSH)

Watch the agent's edits live in Codium — SSH into the sandbox through the OpenShell
gateway. No shared volume, no sandbox egress. One-time setup:

- "Open Remote - SSH" extension in Codium (from the Open VSX registry — Codium can't
  use MS's marketplace Remote-SSH).
- SSH config is OpenShell-managed: host alias `openshell-goose-desktop.default` in
  `~/.config/openshell/ssh_config`, included from `~/.ssh/config` (created by
  `openshell sandbox connect --editor vscode`; view the entry with
  `openshell sandbox ssh-config goose-desktop`).
- Codium setting `"remote.SSH.localServerDownload": "always"`: the ~85 MB server
  tarball is downloaded on the host and pushed over the gateway channel via scp —
  the sandbox makes zero network requests for the install. (Set it explicitly: the
  extension's default value for this setting is a typo, `autor`.)
- `~/.local/bin/code` wrapper (`exec /usr/bin/codium "$@"`) so `code` resolves for
  non-interactive callers (e.g. `connect --editor`). TODO: check whether a simple symlink works.

```bash
# Open Codium on the sandbox working dir
openshell sandbox connect goose-desktop --editor vscode

# Open one nested project directly (path is absolute on the remote side)
code --folder-uri vscode-remote://ssh-remote+openshell-goose-desktop.default/workspace/flowlogs-pipeline

# Quick shell into the sandbox (works from any terminal)
ssh openshell-goose-desktop.default
```

The Codium server installs under `/workspace/.vscodium-server` (HOME is `/workspace`):
first connect takes ~1–3 min (host-side download + a "Copy server to host" scp
terminal), subsequent connects are instant. It survives sandbox stop/start;
re-transfers only on recreate or a Codium version bump.

## Verified behavior (2026-11-19)

| Test | Result |
|---|---|
| `curl -k https://127.0.0.1:3199/status` (host → ACP) | `ok` |
| `GET https://example.com` (allowlisted, read-only) | HTTP 200 |
| `POST https://example.com` | `policy_denied` (read-only preset blocks writes) |
| `GET https://www.bbc.com` (not allowlisted) | denied → advisor proposal → prover: no findings → auto-approved → retry HTTP 200 |
| Write `/workspace`, `/home/goose` | allowed |
| Write `/etc`, `/usr` | `Permission denied` (Landlock) |
| Read `/etc/passwd` | allowed (read-only system paths) |
| goose startup fetch of `models.dev` | denied → auto-approved (hot-reloaded) |

## Extending

- **More read-only domains**: add endpoints under `network_policies.web_read_common` in `policy.yaml`, then `openshell policy set goose-desktop --policy policy.yaml`; or rely on auto-approval for one-offs.
- **Default model**: edit `goose-config.yaml` (`providers.custom_enmaas.model`), rebuild image, recreate sandbox. Models available: `rits/zai-org/glm-5-3`, `rits/deepseek-ai/DeepSeek-V4.1-Flash-1017`, `rits/meta-models/Muse-Spark-Open-816B-A42B-NVFP4`.
- **More sandboxes**: rerun step 5 with a different `--name` (and another `--forward` port).
- **Relaxed posture**: add `--approval-mode auto` to sandbox and/or extend the allowlist.

## Troubleshooting

- **Forward shows `dead` / Desktop can't connect**: `openshell forward start 3199 goose-desktop --background`, then `curl -sk https://127.0.0.1:3199/status` should return `ok`.
- **401 from ACP**: secret mismatch — Desktop's *Secret Key* must equal `GOOSE_SERVER__SECRET_KEY` (`acp-secret.txt`).
- **Fingerprint error in Desktop**: cert was regenerated after a sandbox recreate; re-read it (command above) or leave the field empty for trust-on-first-use.
- **`credential_endpoint_mismatch` in logs**: a placeholder was used at a non-enmaas endpoint — correct the provider binding, don't widen network policy.
- **`WorkspaceValidationFailed: OCI WorkingDir is not usable`**: image WORKDIR must be owned by the non-root user (handled in the Dockerfile).
- **Policy rejected with `missing field: version`**: policy YAML must start with `version: 1`.
- **Telemetry** (optional, corporate): disable with `OPENSHELL_TELEMETRY_ENABLED=false` on the gateway.
