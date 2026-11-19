#!/usr/bin/env bash
# Shared paths and helpers for the server scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAPER_VERSION="${PAPER_VERSION:-26.3}"
PAPER_BUILD="${PAPER_BUILD:-latest}"
SERVER_DIR="${SERVER_DIR:-$ROOT/server}"
SERVER_PORT="${SERVER_PORT:-25565}"
JAVA_BIN="${JAVA_BIN:-java}"
MEMORY="${MEMORY:-2G}"
CACHE_DIR="${CACHE_DIR:-$ROOT/.cache}"
FILL_API="${FILL_API:-https://fill.papermc.io/v3}"
BORE_VERSION="${BORE_VERSION:-0.5.3}"
BORE_SERVER="${BORE_SERVER:-bore.pub}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found in PATH"
}

need_python() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required but was not found in PATH"
}

# Latest build metadata for a Paper version, as tab separated
# "<build id>\t<file name>\t<sha256>\t<url>".
paper_metadata() {
    local version="$1" build="${2:-latest}"
    need curl
    need_python
    curl -fsSL --retry 3 --retry-delay 2 \
        "$FILL_API/projects/paper/versions/$version/builds/$build" \
        | python3 -c '
import json, sys
data = json.load(sys.stdin)
download = data["downloads"]["server:default"]
print("\t".join([
    str(data["id"]),
    download["name"],
    download["checksums"]["sha256"],
    download["url"],
]))
'
}

# Downloads a URL to a file and verifies its SHA-256 before moving it into
# place, so an interrupted download can never be used as a server jar.
download_verified() {
    local url="$1" sha256="$2" target="$3"
    local temp="${target}.part"
    need curl
    log "downloading $(basename "$target")" >&2
    curl -fL --retry 3 --retry-delay 2 -o "$temp" "$url"
    local actual
    actual="$(sha256sum "$temp" | cut -d' ' -f1)"
    if [ "$actual" != "$sha256" ]; then
        rm -f "$temp"
        die "checksum mismatch for $(basename "$target"): expected $sha256, got $actual"
    fi
    mv -f "$temp" "$target"
}

# Replaces a key in a properties file, appending it when it is missing.
set_property() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
}

# A free TCP port, used by the test suite so it never collides with a real
# server.  Tries the preferred port, then nearby ports, then a random high
# port.
free_port() {
    local preferred="${1:-25565}"
    python3 - "$preferred" <<'PY'
import random
import socket
import sys

preferred = int(sys.argv[1])
ports = [preferred] + list(range(preferred, preferred + 40)) \
    + random.sample(range(30000, 40000), 200) + [0]
for port in ports:
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", port))
            print(sock.getsockname()[1])
            break
    except OSError:
        continue
PY
}
