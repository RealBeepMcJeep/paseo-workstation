#!/usr/bin/env bash
# Print the exact upstream inputs an image build would use, one KEY=VALUE per
# line (also valid as Docker build args). CI hashes this output together with
# the Dockerfile and rootfs: an unchanged hash means there is nothing to rebuild.
#
# Needs: curl, jq, npm, git. GitHub API calls use GH_TOKEN when it is set.
set -euo pipefail

emit() {
  # Fail loudly on an empty value rather than building with a blank version.
  [ -n "$2" ] || { echo "probe: no value for $1" >&2; exit 1; }
  printf '%s=%s\n' "$1" "$2"
}
github_release() {
  curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    "https://api.github.com/repos/$1/releases/latest"
}
github_latest() { github_release "$1" | jq -er .tag_name; }
asset_sha256() {
  # SHA-256 that GitHub records for a release asset; the build verifies against it.
  jq -er --arg name "$2" '.assets[] | select(.name == $name) | .digest
    | select(startswith("sha256:")) | ltrimstr("sha256:")' <<<"$1"
}
npm_latest() {
  # Highest version matching a range ("latest" when no range is given).
  npm view "$1@${2:-latest}" version --json | jq -er 'if type == "array" then last else . end'
}
nuget_latest() {
  curl -fsSL "https://api.nuget.org/v3-flatcontainer/$1/index.json" \
    | jq -er '[.versions[] | select(test("-") | not)] | last'
}
image_digest() {
  # Digest of the multi-arch index for public.ecr.aws/<repository>:<tag>.
  local token
  token=$(curl -fsSL "https://public.ecr.aws/token/?scope=repository:$1:pull" | jq -er .token)
  curl -fsSI -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://public.ecr.aws/v2/$1/manifests/$2" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

node_repository=docker/library/node
node_tag=22-trixie-slim
node_digest=$(image_digest "$node_repository" "$node_tag")
golang_repository=docker/library/golang
golang_tag=1-trixie
golang_digest=$(image_digest "$golang_repository" "$golang_tag")
# The Cloudflare DNS module publishes git tags, not GitHub releases.
caddy_cloudflare=$(git ls-remote --tags --refs https://github.com/caddy-dns/cloudflare.git \
  | awk -F/ '{ print $3 }' | sort -V | tail -n 1)

dotnet_index=$(curl -fsSL https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json)
dotnet_sdk() { jq -er --arg c "$1" '."releases-index"[] | select(."channel-version" == $c) | ."latest-sdk"' <<<"$dotnet_index"; }
dotnet_lts=$(jq -er '[."releases-index"[] | select(."release-type" == "lts" and ."support-phase" == "active")]
  | max_by(."channel-version" | split(".") | map(tonumber)) | ."channel-version"' <<<"$dotnet_index")

rust_stable=$(curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml \
  | awk '/^\[pkg\.rust\]/ { found = 1 } found && !done && /^version = / { gsub(/"/, "", $3); print $3; done = 1 }')
# (awk reads to the end: exiting early would make curl fail under pipefail.)

emit NODE_IMAGE "public.ecr.aws/$node_repository:$node_tag@$node_digest"
emit GOLANG_IMAGE "public.ecr.aws/$golang_repository:$golang_tag@$golang_digest"
emit DEBIAN_REFRESH "$(date -u +%G-W%V)"
emit RUST_STABLE "$rust_stable"
emit DOTNET8_SDK "$(dotnet_sdk 8.0)"
emit DOTNET_LTS_CHANNEL "$dotnet_lts"
emit DOTNET_LTS_SDK "$(dotnet_sdk "$dotnet_lts")"
emit CSHARP_LS_VERSION "$(nuget_latest csharp-ls)"
emit ILSPYCMD_VERSION "$(nuget_latest ilspycmd)"
emit UV_VERSION "$(github_latest astral-sh/uv)"
emit RUFF_VERSION "$(github_latest astral-sh/ruff)"
marksman=$(github_release artempyanykh/marksman)
emit MARKSMAN_VERSION "$(jq -er .tag_name <<<"$marksman")"
emit MARKSMAN_SHA256 "$(asset_sha256 "$marksman" marksman-linux-x64)"
yq=$(github_release mikefarah/yq)
emit YQ_VERSION "$(jq -er .tag_name <<<"$yq")"
emit YQ_SHA256 "$(asset_sha256 "$yq" yq_linux_amd64)"
gh=$(github_release cli/cli)
gh_version=$(jq -er .tag_name <<<"$gh")
emit GH_VERSION "$gh_version"
emit GH_SHA256 "$(asset_sha256 "$gh" "gh_${gh_version#v}_linux_amd64.tar.gz")"
emit TEA_VERSION "$(curl -fsSL https://gitea.com/api/v1/repos/gitea/tea/releases/latest | jq -er .tag_name)"
emit CADDY_VERSION "$(github_latest caddyserver/caddy)"
emit XCADDY_VERSION "$(github_latest caddyserver/xcaddy)"
emit CADDY_CLOUDFLARE_VERSION "$caddy_cloudflare"
emit PYRIGHT_VERSION "$(npm_latest pyright)"
emit TS_LS_VERSION "$(npm_latest typescript-language-server)"
emit TYPESCRIPT_VERSION "$(npm_latest typescript '^6')"
emit YAML_LS_VERSION "$(npm_latest yaml-language-server)"
emit PASEO_VERSION "$(npm_latest @getpaseo/cli)"
emit CLAUDE_CODE_VERSION "$(npm_latest @anthropic-ai/claude-code)"
emit CODEX_VERSION "$(npm_latest @openai/codex)"
emit PI_VERSION "$(npm_latest @earendil-works/pi-coding-agent)"
emit BLADEBRO_VERSION "$(npm_latest bladebro)"
