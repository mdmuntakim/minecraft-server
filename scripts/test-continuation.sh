#!/usr/bin/env bash
# Fast checks for the session split and the continuation request.  No server,
# no network: they run before the end-to-end test.
#
#   ./scripts/test-continuation.sh
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

failures=0
check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s (expected "%s", got "%s")\n' "$name" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

check "six hours split into 320 + 40" "320 40" "$(plan_session 360 0 320)"
check "second session serves the last 40" "40 0" "$(plan_session 360 320 320)"
check "short run stays in one session" "100 0" "$(plan_session 100 0 320)"
check "remaining time below the cap is one session" "200 0" "$(plan_session 360 160 320)"

payload="$(
    DURATION_MINUTES=360 \
    ELAPSED_MINUTES=320 \
    PUBLIC_PORT=25565 \
    MEMORY=2G \
    PAPER_VERSION=26.3 \
    MOBHEAD=1 \
    ONLINE_MODE=true \
    SAVE_WORLD=1 \
    SESSION_MINUTES=320 \
    GITHUB_RUN_ID=123456789 \
    GITHUB_REF_NAME=main \
        ./dispatch-continuation.sh --dry-run
)"
check "continuation ref" "main" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["ref"])' "$payload")"
check "continuation elapsed" "320" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["inputs"]["elapsed_minutes"])' "$payload")"
check "continuation total" "360" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["inputs"]["duration_minutes"])' "$payload")"
check "continuation world source" "123456789" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["inputs"]["previous_run"])' "$payload")"
check "continuation keeps the public port" "25565" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["inputs"]["public_port"])' "$payload")"
check "continuation keeps MobHead" "true" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["inputs"]["mobhead"])' "$payload")"

if DURATION_MINUTES=360 ELAPSED_MINUTES=360 ./dispatch-continuation.sh --dry-run >/dev/null 2>&1; then
    printf 'FAIL  a finished run must not dispatch a continuation\n' >&2
    failures=$((failures + 1))
else
    printf 'PASS  a finished run does not dispatch a continuation\n'
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s continuation check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\ncontinuation checks: PASS\n'
