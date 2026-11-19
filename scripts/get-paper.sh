#!/usr/bin/env bash
# Downloads the Paper server jar for PAPER_VERSION (default 26.3), verifies the
# published SHA-256 and records the build next to the jar.
#
#   scripts/get-paper.sh [--dir DIR] [--version 26.3] [--build latest] [--force]
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)     SERVER_DIR="${2:?--dir needs a value}"; shift 2 ;;
        --version) PAPER_VERSION="${2:?--version needs a value}"; shift 2 ;;
        --build)   PAPER_BUILD="${2:?--build needs a value}"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown argument: $1" ;;
    esac
done

mkdir -p "$SERVER_DIR"
jar="$SERVER_DIR/paper.jar"
stamp="$SERVER_DIR/paper.version"
FORCE="${FORCE:-0}"

metadata="$(paper_metadata "$PAPER_VERSION" "$PAPER_BUILD")"
IFS=$'\t' read -r build name sha url <<<"$metadata"
record="$PAPER_VERSION build $build $name $sha"

if [ "$FORCE" = 0 ] && [ -s "$jar" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$record" ]; then
    log "$jar is up to date (Paper $PAPER_VERSION build $build)"
    exit 0
fi

download_verified "$url" "$sha" "$jar"
printf '%s\n' "$record" >"$stamp"
log "Paper $PAPER_VERSION build $build -> $jar"
