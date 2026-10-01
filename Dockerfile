# syntax=docker/dockerfile:1
# Paseo workstation: the Paseo daemon driving Claude Code, Codex and Pi, with
# bladebro + headless Chromium, dev toolchains and language servers.
#
# CI (.github/workflows/build.yml) passes exact versions from
# scripts/probe-versions.sh. For a local build:
#   docker build $(scripts/probe-versions.sh | sed 's/^/--build-arg /') -t paseo-workstation .
#
# Layers run from slowest- to fastest-changing, so a new agent CLI release
# rebuilds only the last layers.

ARG NODE_IMAGE=public.ecr.aws/docker/library/node:22-trixie-slim
FROM ${NODE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
USER 0
WORKDIR /tmp

# System packages. chromium/xvfb/xauth/fonts: headless browsing for bladebro
# and projects. ffmpeg: media work (yoto-mcp). libicu76: .NET globalization.
# DEBIAN_REFRESH is the ISO week from the probe: it changes weekly, so Debian
# security updates are picked up at least once a week.
ARG DEBIAN_REFRESH
# Unpinned on purpose: the weekly refresh is how security updates arrive.
# hadolint ignore=DL3008
RUN echo "Debian refresh: ${DEBIAN_REFRESH:-unset}" \
    && apt-get -o Acquire::Retries=3 update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
         bash ca-certificates curl git tini tmux less file procps openssh-client \
         ripgrep fd-find jq sqlite3 tree zip unzip xz-utils lbzip2 \
         poppler-utils shellcheck ffmpeg \
         build-essential cmake pkg-config \
         python3 python3-venv python3-tomlkit \
         libicu76 \
         chromium xvfb xauth fonts-liberation fonts-noto-color-emoji \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# UID/GID 568 matches the TrueNAS app datasets.
RUN groupadd --gid 568 paseo \
    && useradd --uid 568 --gid 568 --create-home --home-dir /home/paseo --shell /bin/bash paseo \
    && mkdir -p /workspace \
    && chown 568:568 /workspace

# Toolchains live under /opt so the /home/paseo bind mount cannot hide them.
# Caches (cargo registry, NuGet, uv, npm) stay in the persistent home.
ENV HOME=/home/paseo \
    LANG=C.UTF-8 \
    PASEO_HOME=/home/paseo/.paseo \
    PASEO_LISTEN=0.0.0.0:6767 \
    PASEO_WEB_UI_ENABLED=true \
    PASEO_LOG_FORMAT=json \
    PASEO_LOG_LEVEL=info \
    ONNXRUNTIME_NODE_INSTALL=skip \
    CLAUDE_CONFIG_DIR=/home/paseo/.claude \
    CODEX_HOME=/home/paseo/.codex \
    XDG_CONFIG_HOME=/home/paseo/.config \
    XDG_DATA_HOME=/home/paseo/.local/share \
    XDG_STATE_HOME=/home/paseo/.local/state \
    XDG_CACHE_HOME=/home/paseo/.cache \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/home/paseo/.cargo \
    DOTNET_ROOT=/opt/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    PATH=/opt/cargo/bin:/opt/dotnet:/opt/dotnet-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/paseo/.local/bin:/home/paseo/.cargo/bin:/home/paseo/.dotnet/tools

# Rust stable with WASM. rust-src lets rust-analyzer resolve std. /opt/rustup is
# owned by 568 so repos pinning another toolchain can install it at runtime
# (lost on recreate, re-downloaded on demand).
ARG RUST_STABLE
RUN echo "Rust stable: ${RUST_STABLE:-unpinned}" \
    && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o rustup-init.sh \
    && CARGO_HOME=/opt/cargo sh rustup-init.sh -y --no-modify-path --profile minimal \
         --default-toolchain stable \
         --component rustfmt,clippy,rust-analyzer,rust-src \
         --target wasm32-unknown-unknown \
    && rm rustup-init.sh \
    && chown -R 568:568 /opt/rustup

# .NET: SDK 8 for net8.0 mods/tests plus the current LTS SDK, which also runs
# csharp-ls and ilspycmd. SDK-style net48/net472/net40 targets build through
# reference-assembly packages restored from NuGet.
ARG DOTNET8_SDK
ARG DOTNET_LTS_CHANNEL=LTS
ARG DOTNET_LTS_SDK
ARG CSHARP_LS_VERSION
ARG ILSPYCMD_VERSION
RUN echo ".NET SDKs: ${DOTNET8_SDK:-8.0 latest}, ${DOTNET_LTS_SDK:-${DOTNET_LTS_CHANNEL} latest}" \
    && curl -fsSL https://dot.net/v1/dotnet-install.sh -o dotnet-install.sh \
    && bash dotnet-install.sh --channel 8.0 --install-dir /opt/dotnet --no-path \
    && bash dotnet-install.sh --channel "$DOTNET_LTS_CHANNEL" --install-dir /opt/dotnet --no-path \
    && export DOTNET_CLI_HOME=/tmp/dotnet-home NUGET_PACKAGES=/tmp/nuget \
    && /opt/dotnet/dotnet tool install --tool-path /opt/dotnet-tools csharp-ls ${CSHARP_LS_VERSION:+--version "$CSHARP_LS_VERSION"} \
    && /opt/dotnet/dotnet tool install --tool-path /opt/dotnet-tools ilspycmd ${ILSPYCMD_VERSION:+--version "$ILSPYCMD_VERSION"} \
    && rm -rf dotnet-install.sh /tmp/dotnet-home /tmp/nuget

# Single-binary tools from upstream releases (exact versions from the probe).
ARG UV_VERSION
ARG RUFF_VERSION
ARG MARKSMAN_VERSION
ARG YQ_VERSION
ARG GH_VERSION
ARG TEA_VERSION
# uv and ruff are verified against their published SHA-256 files.
RUN : "${UV_VERSION:?}" "${RUFF_VERSION:?}" "${MARKSMAN_VERSION:?}" "${YQ_VERSION:?}" "${GH_VERSION:?}" "${TEA_VERSION:?}" \
    && gh_release() { echo "https://github.com/$1/releases/download/$2/$3"; } \
    && fetch_verified() { curl -fsSLO "$(gh_release "$@")" && curl -fsSLO "$(gh_release "$1" "$2" "$3.sha256")" && sha256sum -c "$3.sha256"; } \
    && fetch_verified astral-sh/uv "$UV_VERSION" uv-x86_64-unknown-linux-gnu.tar.gz \
    && tar -xzf uv-x86_64-unknown-linux-gnu.tar.gz --strip-components=1 -C /usr/local/bin \
         uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx \
    && fetch_verified astral-sh/ruff "$RUFF_VERSION" ruff-x86_64-unknown-linux-gnu.tar.gz \
    && tar -xzf ruff-x86_64-unknown-linux-gnu.tar.gz --strip-components=1 -C /usr/local/bin \
         ruff-x86_64-unknown-linux-gnu/ruff \
    && rm -f ./*.tar.gz ./*.sha256 \
    && curl -fsSL -o /usr/local/bin/marksman "$(gh_release artempyanykh/marksman "$MARKSMAN_VERSION" marksman-linux-x64)" \
    && curl -fsSL -o /usr/local/bin/yq "$(gh_release mikefarah/yq "$YQ_VERSION" yq_linux_amd64)" \
    && curl -fsSL "$(gh_release cli/cli "$GH_VERSION" "gh_${GH_VERSION#v}_linux_amd64.tar.gz")" \
         | tar -xz --strip-components=2 -C /usr/local/bin "gh_${GH_VERSION#v}_linux_amd64/bin/gh" \
    && curl -fsSL -o /usr/local/bin/tea "https://dl.gitea.com/tea/${TEA_VERSION#v}/tea-${TEA_VERSION#v}-linux-amd64" \
    && chmod 755 /usr/local/bin/marksman /usr/local/bin/yq /usr/local/bin/tea

# npm language servers. typescript@6 stays on major 6: TypeScript 7 (the Go
# port) ships no tsserver.js for typescript-language-server.
ARG PYRIGHT_VERSION=latest
ARG TS_LS_VERSION=latest
ARG TYPESCRIPT_VERSION=6
ARG YAML_LS_VERSION=latest
RUN npm install -g --no-audit --no-fund \
         "pyright@$PYRIGHT_VERSION" \
         "typescript-language-server@$TS_LS_VERSION" \
         "typescript@$TYPESCRIPT_VERSION" \
         "yaml-language-server@$YAML_LS_VERSION" \
    && npm cache clean --force

# Paseo daemon, installed from npm exactly as upstream's own image does.
ARG PASEO_VERSION=latest
RUN npm install -g --no-audit --no-fund "@getpaseo/cli@$PASEO_VERSION" \
    && npm cache clean --force \
    && entry="$(npm root -g)/@getpaseo/server/dist/scripts/supervisor-entrypoint.js" \
    && node --check "$entry" \
    && echo "$entry" > /etc/paseo-server-entry

# Agent CLIs and bladebro change most often, so they come last. Pi recommends
# --ignore-scripts. Image rebuilds own updates (see ENV below).
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG PI_VERSION=latest
ARG BLADEBRO_VERSION=latest
RUN npm install -g --no-audit --no-fund \
         "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" \
         "@openai/codex@$CODEX_VERSION" \
         "bladebro@$BLADEBRO_VERSION" \
    && npm install -g --ignore-scripts --no-audit --no-fund \
         "@earendil-works/pi-coding-agent@$PI_VERSION" \
    && npm cache clean --force

COPY rootfs/ /

# Updates come from new images, not in-app updaters. CHROME_PATH and
# BLADE_* configure bladebro for the image's Chromium; --no-sandbox because
# Chromium's own sandbox cannot start under no-new-privileges and the default
# seccomp profile (the container is the boundary).
ENV CLAUDE_CODE_PLUGIN_DIRS=/opt/claude-plugins/pyright-lsp:/opt/claude-plugins/csharp-lsp:/opt/claude-plugins/rust-analyzer-lsp:/opt/claude-plugins/typescript-lsp:/opt/claude-plugins/marksman-lsp:/opt/claude-plugins/yaml-lsp \
    DISABLE_AUTOUPDATER=1 \
    PI_SKIP_VERSION_CHECK=1 \
    BLADE_NO_UPDATE_CHECK=1 \
    BLADE_CHROME_FLAGS=--no-sandbox \
    CHROME_PATH=/usr/bin/chromium

# Build checks run as the runtime user; any failure fails the build, so a
# broken image is never published. Versions are recorded in the image.
USER 568:568
WORKDIR /workspace
RUN workstation-check | tee /tmp/versions.txt
USER 0
ARG BUILD_INPUTS=""
RUN install -D -m 644 /tmp/versions.txt /etc/paseo-workstation/versions.txt \
    && printf '%s\n' "$BUILD_INPUTS" | tr ' ' '\n' > /etc/paseo-workstation/build-inputs.txt \
    && rm /tmp/versions.txt

USER 568:568
EXPOSE 6767
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --start-interval=5s --retries=3 \
  CMD ["node", "-e", "require('http').get('http://127.0.0.1:6767/api/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/workstation-start"]
