#!/usr/bin/env bash
# Builds the distributable server bundle in dist/.
#
#   PAPER_VERSION=26.3 ./scripts/build-dist.sh
#
# The bundle contains the launcher scripts, the default configuration, the
# Docker files and the documentation.  The Paper jar and the world are runtime
# output and are not bundled; start.sh downloads the pinned Paper build on the
# first run.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

VERSION="${PAPER_VERSION:-26.3}"
DIST="${DIST:-$ROOT/dist}"
stage_root="$(mktemp -d)"
stage="$stage_root/minecraft-server-$VERSION"
trap 'rm -rf "$stage_root"' EXIT

mkdir -p "$stage/server" "$DIST"
cp "$ROOT/README.md" "$ROOT/build.sh" "$ROOT/docker-compose.yml" "$stage/"
cp -a "$ROOT/scripts" "$stage/scripts"
cp -a "$ROOT/docker" "$stage/docker"
tar -C "$ROOT" \
    --exclude='server/paper.jar' \
    --exclude='server/paper.jar.part' \
    --exclude='server/paper.version' \
    --exclude='server/world*' \
    --exclude='server/logs' \
    --exclude='server/cache' \
    --exclude='server/libraries' \
    --exclude='server/versions' \
    --exclude='server/plugins' \
    --exclude='server/banned-*' \
    --exclude='server/ops.json' \
    --exclude='server/usercache.json' \
    --exclude='server/whitelist.json' \
    -cf - server | tar -C "$stage" -xf -
chmod +x "$stage"/scripts/*.sh "$stage"/scripts/*.py "$stage/build.sh"

archive="$DIST/minecraft-server-$VERSION.tar.gz"
rm -f "$archive" "$archive.sha256"
tar -C "$stage_root" -czf "$archive" "minecraft-server-$VERSION"
(cd "$DIST" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")

log "bundle: $archive"
printf 'size:    %s bytes\n' "$(wc -c <"$archive")"
printf 'sha256:  %s\n' "$(cut -d' ' -f1 "$archive.sha256")"
