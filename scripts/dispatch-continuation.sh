#!/usr/bin/env bash
# Queues the next session of a long public run.
#
# GitHub ends a hosted job after six hours.  A run that is asked to stay
# online longer than one session therefore stops before the limit, saves the
# world and dispatches this same workflow again with the world artifact of the
# finished run.  The next job restores that world and keeps the same bore.pub
# port, so a six hour request is served by two sessions without ever touching
# the six hour job limit.
#
# This script only builds the workflow_dispatch request.  It is called by
# scripts/run-server.sh at the end of a session:
#
#   ELAPSED_MINUTES=320 ./scripts/dispatch-continuation.sh
#   ELAPSED_MINUTES=320 ./scripts/dispatch-continuation.sh --dry-run
#
# Environment:
#   DURATION_MINUTES   total minutes of the whole public run
#   ELAPSED_MINUTES    minutes already served, including this session
#   PUBLIC_PORT        fixed bore.pub port to request again
#   MEMORY, PAPER_VERSION, MOBHEAD, ONLINE_MODE, SAVE_WORLD
#   GITHUB_TOKEN       token with actions: write
#   GITHUB_RUN_ID      the run whose world artifact is restored
#   GITHUB_REF_NAME    branch or tag the next run is dispatched on
#   GITHUB_REPOSITORY  owner/repository
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) awk 'NR>1 { if ($0 ~ /^set -euo pipefail/) exit; sub(/^# ?/, ""); print }' \
                           "$ROOT/scripts/dispatch-continuation.sh"; exit 0 ;;
        *)         die "unknown argument: $1" ;;
    esac
done

DURATION_MINUTES="${DURATION_MINUTES:?DURATION_MINUTES is required}"
ELAPSED_MINUTES="${ELAPSED_MINUTES:?ELAPSED_MINUTES is required}"
[ "$ELAPSED_MINUTES" -lt "$DURATION_MINUTES" ] \
    || die "nothing left to continue: $ELAPSED_MINUTES of $DURATION_MINUTES minutes served"

payload="$(
DURATION_MINUTES="$DURATION_MINUTES" ELAPSED_MINUTES="$ELAPSED_MINUTES" python3 - <<'PY'
import json
import os

inputs = {
    "duration_minutes": os.environ["DURATION_MINUTES"],
    "elapsed_minutes": os.environ["ELAPSED_MINUTES"],
    "previous_run": os.environ.get("GITHUB_RUN_ID", ""),
    "public_port": os.environ.get("PUBLIC_PORT", ""),
    "fallback_port": os.environ.get("PUBLIC_PORT_FALLBACK", ""),
    "memory": os.environ.get("MEMORY", "2G"),
    "paper_version": os.environ.get("PAPER_VERSION", "26.3"),
    "mobhead": "true" if os.environ.get("MOBHEAD", "1") == "1" else "false",
    "online_mode": "true" if os.environ.get("ONLINE_MODE", "true") == "true" else "false",
    "save_world": "true" if os.environ.get("SAVE_WORLD", "1") == "1" else "false",
    "session_minutes": os.environ.get("SESSION_MINUTES", "320"),
}
print(json.dumps({
    "ref": os.environ.get("GITHUB_REF_NAME", "main"),
    "inputs": inputs,
}, sort_keys=True))
PY
)"

if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n' "$payload"
    exit 0
fi

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to dispatch the continuation run}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

url="https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/server.yml/dispatches"
for attempt in 1 2 3; do
    if curl -fsS -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -d "$payload" "$url"; then
        log "continuation run queued: $((DURATION_MINUTES - ELAPSED_MINUTES)) minutes left, world from run $GITHUB_RUN_ID"
        exit 0
    fi
    warn "could not dispatch the continuation run (attempt $attempt/3)"
    sleep 3
done
die "the continuation run could not be dispatched; the session is the last one"
