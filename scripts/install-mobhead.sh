#!/usr/bin/env bash
# Installs the latest published MobHead jar into a server's plugins folder.
#
#   scripts/install-mobhead.sh --dir server
#   MOBHEAD_JAR_URL=... scripts/install-mobhead.sh --dir /tmp/test-server
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) SERVER_DIR="${2:?--dir needs a value}"; shift 2 ;;
        *)     die "unknown argument: $1" ;;
    esac
done

url="${MOBHEAD_JAR_URL:-https://github.com/mdmuntakim/mobhead/releases/latest/download/mobhead-26.3.jar}"
mkdir -p "$SERVER_DIR/plugins"
curl -fL --retry 3 --retry-delay 2 -o "$SERVER_DIR/plugins/mobhead.jar.part" "$url"
if [ ! -s "$SERVER_DIR/plugins/mobhead.jar.part" ]; then
    rm -f "$SERVER_DIR/plugins/mobhead.jar.part"
    die "MobHead download is empty: $url"
fi
mv -f "$SERVER_DIR/plugins/mobhead.jar.part" "$SERVER_DIR/plugins/mobhead.jar"
log "MobHead installed from $url"
