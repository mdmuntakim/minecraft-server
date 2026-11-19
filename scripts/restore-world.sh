#!/usr/bin/env bash
# Restores the world uploaded by an earlier session of the same public run.
#
#   GITHUB_REPOSITORY=mdmuntakim/minecraft-server \
#       ./scripts/restore-world.sh 123456789
#
# The run artifact is called minecraft-world-<run number>; the run id is what
# scripts/dispatch-continuation.sh passes as previous_run.  Nothing is restored
# when the artifact is missing, so a continuation still boots (with a fresh
# world) instead of failing.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

RUN_ID="${1:-${PREVIOUS_RUN:-}}"
[ -n "$RUN_ID" ] || die "usage: restore-world.sh <run-id>"
REPO="${GITHUB_REPOSITORY:-mdmuntakim/minecraft-server}"

need gh

artifact="$(
    gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=100" \
        --jq '.artifacts[] | select(.name | startswith("minecraft-world-")) | .name' \
        2>/dev/null | head -1 || true
)"
if [ -z "$artifact" ]; then
    warn "run $RUN_ID has no world artifact, starting with a fresh world"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/minecraft-world.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

log "restoring $artifact from run $RUN_ID"
if ! gh run download "$RUN_ID" --repo "$REPO" --name "$artifact" --dir "$tmp"; then
    warn "could not download $artifact; starting with a fresh world"
    exit 0
fi

[ -d "$tmp" ] || die "the world artifact could not be unpacked"
# upload-artifact stores the files relative to their least common ancestor:
# either server/ (one search path) or the workspace root (several paths).
if [ -d "$tmp/server/world" ]; then
    src="$tmp/server"
elif [ -d "$tmp/world" ] || [ -d "$tmp/world_nether" ]; then
    src="$tmp"
else
    die "$artifact does not contain a world directory"
fi
mkdir -p "$SERVER_DIR"
cp -a "$src/." "$SERVER_DIR/"
if [ -f "$SERVER_DIR/world/level.dat" ]; then
    log "world restored: $SERVER_DIR/world (level.dat present)"
else
    warn "world artifact restored but level.dat is missing"
fi
