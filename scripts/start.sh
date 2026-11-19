#!/usr/bin/env bash
# Starts the Paper server in server/ (or SERVER_DIR). Downloads the pinned
# Paper build on first run, then replaces this script with the server process.
#
#   ./scripts/start.sh                # 2G heap
#   MEMORY=4G ./scripts/start.sh      # bigger heap
#   SERVER_DIR=/srv/mc ./scripts/start.sh --nogui
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

need "$JAVA_BIN"
"$ROOT/scripts/get-paper.sh" --dir "$SERVER_DIR" --version "$PAPER_VERSION" --build "$PAPER_BUILD"

major="$("$JAVA_BIN" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)"
if [ -n "$major" ] && [ "$major" -lt 25 ] 2>/dev/null; then
    die "Paper $PAPER_VERSION needs Java 25 or newer, found $("$JAVA_BIN" -version 2>&1 | head -1)"
fi

mkdir -p "$SERVER_DIR"
cd "$SERVER_DIR"
log "starting Paper $PAPER_VERSION on port $SERVER_PORT with ${MEMORY} heap"
exec "$JAVA_BIN" -Xms"$MEMORY" -Xmx"$MEMORY" -XX:+UseG1GC \
    -jar paper.jar --nogui "$@"
