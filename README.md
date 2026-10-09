# paseo-workstation

A container image for a homelab [Paseo](https://github.com/getpaseo/paseo)
workstation: the Paseo daemon driving **Claude Code**, **Codex** and **Pi**
against shared projects. It also bundles **bladebro**, headless **Chromium**,
dev toolchains and language servers.

The image is published to `ghcr.io/realbeepmcjeep/paseo-workstation`.
Updating is meant to be just **Update** in Dockge.

## What's inside

| Area | Contents |
|---|---|
| Base | `node:22-trixie-slim` (Debian 13, Node 22, the Node major Paseo's own image uses). Runs as UID/GID 568 |
| Agents | Paseo daemon (npm), Claude Code, Codex, Pi, bladebro |
| Browser | Debian Chromium, Xvfb (for bladebro's headful stealth mode). All tools share this one browser |
| Rust | stable, rustfmt, clippy, rust-analyzer, rust-src, `wasm32-unknown-unknown` |
| .NET | SDK 8 and the current LTS SDK; csharp-ls; ilspycmd. SDK-style net48/net472/net40 targets build via reference-assembly packages |
| Python | Debian Python 3.13, uv/uvx, ruff, pyright |
| TS/JS | Node 22, typescript-language-server, TypeScript 6 |
| Language servers for Claude | pyright, csharp-ls, rust-analyzer, typescript-language-server, marksman (Markdown), yaml-language-server (with Compose and GitHub Actions schemas). Loaded from image-owned plugins in `/opt/claude-plugins` |
| CLI tools | git, gh, tea (Gitea), jq, yq, ripgrep, fd, sqlite3, tree, shellcheck, ffmpeg, pdftotext, tmux, build-essential, cmake |

Exact versions of the running image are in `/etc/paseo-workstation/versions.txt`.

## How updates work

```
every 6 h ─► probe upstream versions ─► same as :latest? ─► stop (≈1 min)
                                              │ no
                                              ▼
            build ─► build checks ─► run container + self-test ─► push :latest,
                                                                  :YYYYMMDD-HHMMSS, :sha-…
```

- `scripts/probe-versions.sh` resolves every input to an exact version: the base
  image digest, npm packages, GitHub/NuGet releases, Rust stable, .NET SDKs, and
  the ISO week. The ISO week makes Debian security updates land at least weekly.
- The hash of that output, plus every tracked build input (`Dockerfile`, `rootfs/`,
  `.dockerignore`, the probe script and the workflow), is stored as a label
  on the image. A scheduled run that computes the same hash builds nothing.
- A failed build or self-test publishes nothing, so `:latest` is always a build
  that passed.
- In-app updaters are disabled (Claude, Pi, bladebro, Codex update check). The
  image is the only update path.
- The workflow summary shows a diff of what changed since the published image.

## Repository flow

Source of truth: Gitea `AI-Goes-Fast/paseo-workstation`. A one-way Gitea **push
mirror** sends it to GitHub, where Actions builds the image. Nothing writes back
to the GitHub repo: the mirror would overwrite it. The workflow keeps its own
schedule alive through the API.

## One-time setup

1. Gitea → repo Settings → Mirror settings: add a push mirror to
   `https://github.com/RealBeepMcJeep/paseo-workstation.git` with "sync when
   commits are pushed" enabled. The GitHub repository must exist first.
2. After the first successful run: GitHub → Packages → `paseo-workstation` →
   Package settings → change visibility to **Public** so Dockge can pull
   without credentials.
3. Optional: in MCPHub create a `paseo` group and key, and add it to Dockge
   as `MCPHUB_KEY`.

## Deploying in Dockge

Use [`compose.yaml`](compose.yaml) as the stack file. It is a drop-in for the
earlier locally built `paseo` stack: same container name, network, datasets
and UID. Paseo's identity, relay pairing, agent logins and history live in
the home dataset and carry over.

Before the first switch, take a TrueNAS snapshot of the `paseo/home` dataset.
Recreating the container ends running agent sessions; their history is kept.

What startup manages (in `rootfs/usr/local/bin/workstation-start` and
`workstation-config`). Everything else in the home is left alone:

- Git identity, plus a Gitea credential helper that reads `GITEA_TOKEN` from
  the environment and stores nothing.
- A `tea` login refreshed from `GITEA_TOKEN` on each start. It is stored in a
  0600 file, because tea cannot log in from the environment.
- MCP entries `mcphub` (Claude, Codex, Pi; only when `MCPHUB_KEY` is set) and
  `bladebro` (Claude, Codex). Configs reference `${MCPHUB_TOKEN}`, never the
  key. Pi keeps its own bladebro extension.
- Codex defaults `sandbox_mode = "danger-full-access"` and
  `approval_policy = "never"`. The container is the sandbox. In Paseo, pick
  **Full Access** for Codex sessions, because Paseo's own modes override these
  defaults.

Startup problems never stop the container. Check
`~/.paseo/workstation-startup-warnings.txt` and `~/.paseo/workstation-status.json`.

## Checking a deployment

```sh
docker exec paseo workstation-selftest
```

This checks Paseo health, Chromium, the bladebro MCP handshake, Rust native and
WASM builds, net8.0 and SDK-style net48 builds with an ilspycmd round trip,
pyright/ruff, tsc and shellcheck, and reports memory use. It uses a scratch
directory and needs no credentials.

## Rollback

Set `PASEO_IMAGE_TAG` in the stack's `.env` to an earlier **dated** tag
(`YYYYMMDD-HHMMSS`) and click Update. Each dated tag is one specific build, and
the workflow summary records its digest. Don't roll back with `sha-<commit>` tags:
they name the source commit, and scheduled rebuilds of the same commit with newer
upstream tools reuse them. If a newer agent version migrated its data, also
restore the home dataset snapshot while the stack is stopped.

## Secrets

The repository and image are public and contain no credentials. Tokens come
only from the Dockge environment at runtime: `PASEO_PASSWORD`, `GITEA_TOKEN`,
`GH_TOKEN`, `MCPHUB_KEY`. Agent logins live in the home dataset.

## Changing the image

- New CLI tool from apt: add it to the first `RUN` in the `Dockerfile` and a
  `version` line in `workstation-check`.
- New upstream binary or npm package: add an `ARG`, install it with that exact
  version, and add an `emit` line to `scripts/probe-versions.sh`, so the probe
  notices new releases.
- New Claude language server: add a plugin directory under
  `rootfs/opt/claude-plugins/` and append it to `CLAUDE_CODE_PLUGIN_DIRS`.

Local build: `docker build $(scripts/probe-versions.sh | sed 's/^/--build-arg /') -t paseo-workstation .`
