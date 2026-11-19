#!/usr/bin/env bash
# Installs the newest MobHead jar published in the MobHead repository.
#
#   scripts/install-mobhead.sh --dir server
#   MOBHEAD_REPO=mdmuntakim/mobhead scripts/install-mobhead.sh --dir /tmp/test-server
#
# The release is resolved through the GitHub API on every run, so a new MobHead
# release is picked up without changing this repository.  When the API is not
# reachable (rate limit, no network) the stable "latest" download URL is used.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

MOBHEAD_REPO="${MOBHEAD_REPO:-mdmuntakim/mobhead}"
MOBHEAD_ASSET="${MOBHEAD_ASSET:-mobhead-26.3.jar}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) SERVER_DIR="${2:?--dir needs a value}"; shift 2 ;;
        *)     die "unknown argument: $1" ;;
    esac
done

# Resolves the latest release: "<tag>\t<asset name>\t<size>\t<url>".
# Prints nothing and fails when the API cannot be used.
mobhead_release() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}" header=()
    [ -n "$token" ] && header=(-H "Authorization: Bearer $token")
    curl -fsSL --retry 2 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' ${header[@]+"${header[@]}"} \
        "https://api.github.com/repos/$MOBHEAD_REPO/releases/latest" \
        | MOBHEAD_ASSET="$MOBHEAD_ASSET" python3 -c '
import json, os, sys

release = json.load(sys.stdin)
wanted = os.environ["MOBHEAD_ASSET"]
assets = [asset for asset in release.get("assets", [])
          if asset.get("name", "").endswith(".jar")
          and not asset.get("name", "").endswith("-sources.jar")]
chosen = next((asset for asset in assets if asset["name"] == wanted), None)
if chosen is None and assets:
    chosen = assets[0]
if chosen is None:
    sys.exit("release has no jar asset")
print("\t".join([
    release.get("tag_name", ""),
    chosen["name"],
    str(chosen.get("size", 0)),
    chosen["browser_download_url"],
]))
'
}

url="${MOBHEAD_JAR_URL:-}"
tag=""
asset="$MOBHEAD_ASSET"
meta=""
if [ -z "$url" ]; then
    log "resolving the latest MobHead release of $MOBHEAD_REPO"
    meta="$(mobhead_release 2>/dev/null || true)"
fi

if [ -n "$meta" ]; then
    IFS=$'\t' read -r tag asset size url <<<"$meta"
    log "MobHead release $tag: $asset (${size:-?} bytes)"
elif [ -z "$url" ]; then
    asset="$MOBHEAD_ASSET"
    url="https://github.com/$MOBHEAD_REPO/releases/latest/download/$asset"
    warn "could not query the GitHub API, falling back to $url"
fi

mkdir -p "$SERVER_DIR/plugins"
part="$SERVER_DIR/plugins/mobhead.jar.part"
rm -f "$part"
curl -fsSL --retry 3 --retry-delay 2 -o "$part" "$url"
if [ ! -s "$part" ]; then
    rm -f "$part"
    die "MobHead download is empty: $url"
fi
if [ "$(head -c 2 "$part")" != "PK" ]; then
    rm -f "$part"
    die "MobHead download is not a jar: $url"
fi
mv -f "$part" "$SERVER_DIR/plugins/mobhead.jar"
sum="$(sha256sum "$SERVER_DIR/plugins/mobhead.jar" | cut -d' ' -f1)"
log "MobHead installed: ${tag:-latest} $asset sha256 $sum"
printf '%s\t%s\t%s\n' "${tag:-latest}" "$asset" "$sum" \
    >"$SERVER_DIR/plugins/mobhead.version"
