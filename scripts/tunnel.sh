#!/usr/bin/env bash
# Publishes the local Minecraft port through a public TCP tunnel.
#
# bore.pub needs no account and prints the public address:
#
#   ./scripts/tunnel.sh
#   ==> listening at bore.pub:41234
#
# Players then connect to bore.pub:41234.  For a stable, named address use a
# playit.gg agent instead and keep this script for quick tests, or pass
# BORE_SERVER / extra arguments to a self-hosted bore server.
#
#   ./scripts/tunnel.sh --port 25565 --to bore.example.org
#   ./scripts/tunnel.sh --secret my-shared-secret
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

while [ $# -gt 0 ]; do
    case "$1" in
        --port)   SERVER_PORT="${2:?--port needs a value}"; shift 2 ;;
        --to)     BORE_SERVER="${2:?--to needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)        break ;;
    esac
done

case "$(uname -m)" in
    x86_64|amd64)
        arch="x86_64"
        sha="101536e3f26fb3b87b592d602674ede7169ec9fd616939f9544407ef6b0d361f"
        ;;
    aarch64|arm64)
        arch="aarch64"
        sha="adb2cf47c7daaa3775c298fd5d4578500e321fff554211a1a0920ccf9fd9a5ff"
        ;;
    *)
        die "no pinned bore binary for $(uname -m); install bore or use playit.gg"
        ;;
esac

asset="bore-v${BORE_VERSION}-${arch}-unknown-linux-musl.tar.gz"
bin="$CACHE_DIR/bore"
if [ ! -x "$bin" ]; then
    mkdir -p "$CACHE_DIR"
    tarball="$CACHE_DIR/$asset"
    if [ ! -f "$tarball" ]; then
        download_verified \
            "https://github.com/ekzhang/bore/releases/download/v${BORE_VERSION}/${asset}" \
            "$sha" "$tarball"
    fi
    actual="$(sha256sum "$tarball" | cut -d' ' -f1)"
    [ "$actual" = "$sha" ] || die "bore archive is corrupt: $tarball"
    tar -xzf "$tarball" -C "$CACHE_DIR" bore
    chmod +x "$bin"
fi

log "tunneling 127.0.0.1:$SERVER_PORT to $BORE_SERVER (bore $BORE_VERSION)"
exec "$bin" local "$SERVER_PORT" --to "$BORE_SERVER" "$@"
