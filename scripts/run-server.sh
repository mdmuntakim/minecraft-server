#!/usr/bin/env bash
# Runs a public Paper server for a fixed amount of time: the pinned Paper
# build, the newest MobHead release, and a bore.pub tunnel whose game address
# is printed as soon as the server is online.  This is what the "server"
# GitHub Actions workflow runs.
#
#   DURATION_MINUTES=120 ./scripts/run-server.sh
#   DURATION_MINUTES=120 PUBLIC_PORT=25565 ./scripts/run-server.sh
#   DURATION_MINUTES=30 ./scripts/run-server.sh --no-tunnel
#
# A request longer than one session (six hours is the GitHub job limit) is
# split automatically: the session saves the world, the world is uploaded as
# an artifact and the workflow is dispatched again with that artifact.  The
# next session restores the world and keeps the same bore.pub port.
#
# Environment:
#   DURATION_MINUTES  total minutes to keep the server up (default 360, max 1440)
#   ELAPSED_MINUTES   minutes already served by earlier sessions (default 0)
#   SESSION_MINUTES   longest single job (default 320 on GitHub, no split
#                     locally; a GitHub session must stay at or below 330)
#   PUBLIC_PORT       fixed public port to request from bore.pub (default any)
#   PUBLIC_PORT_FALLBACK  second fixed port to try when PUBLIC_PORT is taken
#   SAVE_WORLD        1 upload the world for the continuation run (default 1)
#   MEMORY            Java heap (default 2G)
#   SERVER_PORT       local port (default 25565, a free port is used if taken)
#   PAPER_VERSION     Paper version (default 26.3)
#   MOBHEAD           1 install the latest MobHead jar, 0 skip (default 1)
#   ONLINE_MODE       Minecraft online-mode (default true)
#   MAX_PLAYERS       player limit (default 20)
#   MOTD              server list message
#   SUMMARY_FILE      markdown file to append the address to
#                     (default $GITHUB_STEP_SUMMARY when set)
#   RUN_DIR           logs and the address file (default run/)
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

DURATION_MINUTES="${DURATION_MINUTES:-360}"
ELAPSED_MINUTES="${ELAPSED_MINUTES:-0}"
if [ -z "${SESSION_MINUTES:-}" ]; then
    # A local run is not bound to the six hour job limit.
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        SESSION_MINUTES=320
    else
        SESSION_MINUTES=1440
    fi
fi
PUBLIC_PORT="${PUBLIC_PORT:-}"
PUBLIC_PORT_FALLBACK="${PUBLIC_PORT_FALLBACK:-}"
MEMORY="${MEMORY:-2G}"
MOBHEAD="${MOBHEAD:-1}"
ONLINE_MODE="${ONLINE_MODE:-true}"
SAVE_WORLD="${SAVE_WORLD:-1}"
MAX_PLAYERS="${MAX_PLAYERS:-20}"
MOTD="${MOTD:-PaperMC $PAPER_VERSION \u00a77| \u00a7aPublic server}"
TUNNEL="${TUNNEL:-1}"
SUMMARY_FILE="${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-}}"
RUN_DIR="${RUN_DIR:-$ROOT/run}"

while [ $# -gt 0 ]; do
    case "$1" in
        --duration)    DURATION_MINUTES="${2:?--duration needs a value}"; shift 2 ;;
        --elapsed)     ELAPSED_MINUTES="${2:?--elapsed needs a value}"; shift 2 ;;
        --session)     SESSION_MINUTES="${2:?--session needs a value}"; shift 2 ;;
        --public-port) PUBLIC_PORT="${2:?--public-port needs a value}"; shift 2 ;;
        --fallback-port) PUBLIC_PORT_FALLBACK="${2:?--fallback-port needs a value}"; shift 2 ;;
        --memory)      MEMORY="${2:?--memory needs a value}"; shift 2 ;;
        --no-tunnel)   TUNNEL=0; shift ;;
        --summary)     SUMMARY_FILE="${2:?--summary needs a value}"; shift 2 ;;
        --run-dir)     RUN_DIR="${2:?--run-dir needs a value}"; shift 2 ;;
        -h|--help)     awk 'NR>1 { if ($0 ~ /^set -euo pipefail/) exit; sub(/^# ?/, ""); print }' \
                           "$ROOT/scripts/run-server.sh"; exit 0 ;;
        *)             die "unknown argument: $1" ;;
    esac
done

case "$DURATION_MINUTES" in
    ''|*[!0-9]*) die "duration must be a whole number of minutes" ;;
esac
case "$ELAPSED_MINUTES" in
    ''|*[!0-9]*) die "elapsed must be a whole number of minutes" ;;
esac
case "$SESSION_MINUTES" in
    ''|*[!0-9]*) die "session must be a whole number of minutes" ;;
esac
[ "$DURATION_MINUTES" -ge 1 ] || die "duration must be at least 1 minute"
[ "$DURATION_MINUTES" -le 1440 ] || die "duration must be 1440 minutes or less"
[ "$ELAPSED_MINUTES" -lt "$DURATION_MINUTES" ] \
    || die "elapsed ($ELAPSED_MINUTES) must be smaller than the total duration ($DURATION_MINUTES)"
# GitHub cancels a hosted job after 6 hours; a session there stays well below
# it so the world save and the artifact upload still finish.  Locally there is
# no such limit.
[ "$SESSION_MINUTES" -ge 1 ] || die "a session must be at least 1 minute"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
    [ "$SESSION_MINUTES" -le 330 ] || die "a GitHub session must be 330 minutes or less"
fi

read -r SESSION_LENGTH REMAINING_AFTER <<<"$(plan_session "$DURATION_MINUTES" "$ELAPSED_MINUTES" "$SESSION_MINUTES")"
SESSIONS=$(( (DURATION_MINUTES - ELAPSED_MINUTES + SESSION_LENGTH - 1) / SESSION_LENGTH ))
SESSION_NUMBER=$(( ELAPSED_MINUTES / SESSION_LENGTH + 1 ))
if [ "$REMAINING_AFTER" -gt 0 ] && [ "$SAVE_WORLD" != 1 ]; then
    die "a run longer than one session needs SAVE_WORLD=1 so the next session can restore the world"
fi

need "$JAVA_BIN"
need curl
need_python

major="$("$JAVA_BIN" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)"
[ -n "$major" ] && [ "$major" -ge 25 ] \
    || die "Paper $PAPER_VERSION needs Java 25+, found $("$JAVA_BIN" -version 2>&1 | head -1)"

mkdir -p "$RUN_DIR"
CONSOLE_LOG="$RUN_DIR/console.log"
TUNNEL_LOG="$RUN_DIR/tunnel.log"
ADDRESS_FILE="$RUN_DIR/address.txt"
: >"$CONSOLE_LOG"
: >"$TUNNEL_LOG"
rm -f "$ADDRESS_FILE"

SERVER_PID=""
TUNNEL_PID=""
PUBLIC_ADDRESS=""
ADDRESS_HOST=""
ADDRESS_PORT=""
STARTED_AT="$(date +%s)"
SUMMARY_WRITTEN=0
CONTINUING=0

log "== Minecraft server run =="
log "duration:   ${DURATION_MINUTES} minutes total ($ELAPSED_MINUTES already served)"
log "session:    ${SESSION_LENGTH} minutes (${SESSION_NUMBER} of ${SESSIONS})$([ "$REMAINING_AFTER" -gt 0 ] && echo ", continuation follows")"
log "paper:      $PAPER_VERSION"
log "mobhead:    $([ "$MOBHEAD" = 1 ] && echo latest || echo disabled)"
log "run dir:    $RUN_DIR"

write_summary() {
    [ -n "$SUMMARY_FILE" ] || return 0
    [ "$SUMMARY_WRITTEN" = 0 ] || return 0
    SUMMARY_WRITTEN=1
    {
        printf '\n## Minecraft server\n\n'
        printf '### Connect in Minecraft\n\n'
        printf '| | |\n| --- | --- |\n'
        printf '| Address | `%s` |\n' "$PUBLIC_ADDRESS"
        printf '| Paper | %s |\n' "$PAPER_INFO"
        printf '| MobHead | %s |\n' "$MOBHEAD_INFO"
        printf '| Started | %s UTC |\n' "$(date -u -d "@$STARTED_AT" '+%Y-%m-%d %H:%M')"
        printf '| Runs until | %s UTC (session %s of %s, about %s minutes) |\n' \
            "$(date -u -d "@$((STARTED_AT + SESSION_LENGTH * 60))" '+%Y-%m-%d %H:%M')" \
            "$SESSION_NUMBER" "$SESSIONS" "$SESSION_LENGTH"
        printf '| Total run | %s minutes%s |\n' "$DURATION_MINUTES" \
            "$([ "$REMAINING_AFTER" -gt 0 ] && echo ", split into ${SESSIONS} sessions")"
        printf '| Server log | `run/console.log` in the run artifacts |\n\n'
        printf 'Use **Direct Connection** in Minecraft and enter `%s`.\n\n' "$PUBLIC_ADDRESS"
        if [ "$REMAINING_AFTER" -gt 0 ]; then
            printf 'This session saves the world and a continuation run restores it after\n'
            printf 'a short restart, so the server stays online for the full %s minutes.\n' \
                "$DURATION_MINUTES"
        else
            printf 'The address works while this workflow run is alive. Cancel the run\n'
            printf 'to stop the server; the world and logs are uploaded as an artifact.\n'
        fi
    } >>"$SUMMARY_FILE"
}

stop_server() {
    [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null || return 0
    log "stopping the server (world save)"
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 90); do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}

stop_tunnel() {
    [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null || return 0
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
}

cleanup() {
    local code=$?
    trap - EXIT INT TERM
    stop_server
    stop_tunnel
    if [ "$SUMMARY_WRITTEN" = 1 ] && [ -n "$SUMMARY_FILE" ]; then
        if [ "${CONTINUING:-0}" = 1 ]; then
            {
                printf '\n### Session handed over\n\n'
                printf 'Session %s of %s ended at %s UTC after %s minutes. The world\n' \
                    "$SESSION_NUMBER" "$SESSIONS" "$(date -u '+%Y-%m-%d %H:%M')" \
                    "$((($(date +%s) - STARTED_AT) / 60))"
                printf 'is uploaded and a continuation run (%s minutes left) restores it.\n' \
                    "$REMAINING_AFTER"
                printf 'The public address returns as soon as that run has booted.\n'
            } >>"$SUMMARY_FILE"
        else
            {
                printf '\n### Server stopped\n\n'
                printf 'Stopped at %s UTC after %s minutes. `run/console.log` and the\n' \
                    "$(date -u '+%Y-%m-%d %H:%M')" "$((($(date +%s) - STARTED_AT) / 60))"
                printf 'world are in the run artifacts of this workflow run.\n'
            } >>"$SUMMARY_FILE"
        fi
    fi
    if [ "$code" -ne 0 ]; then
        printf '\n--- console tail ---\n' >&2
        tail -n 40 "$CONSOLE_LOG" >&2 || true
        printf '\n--- tunnel tail ---\n' >&2
        tail -n 20 "$TUNNEL_LOG" >&2 || true
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- prepare ---------------------------------------------------------------
mkdir -p "$SERVER_DIR"
# A fresh SERVER_DIR needs the default configuration and the accepted EULA
# that live in the source tree; the repository server/ directory already has
# them.
[ -f "$SERVER_DIR/server.properties" ] || cp "$ROOT/server/server.properties" "$SERVER_DIR/server.properties"
[ -f "$SERVER_DIR/eula.txt" ] || cp "$ROOT/server/eula.txt" "$SERVER_DIR/eula.txt"
"$ROOT/scripts/get-paper.sh" --dir "$SERVER_DIR" --version "$PAPER_VERSION" --build "$PAPER_BUILD"
PAPER_INFO="$(awk '{print "Paper " $1 " build " $3}' "$SERVER_DIR/paper.version" 2>/dev/null || echo "Paper $PAPER_VERSION")"

MOBHEAD_INFO="disabled"
if [ "$MOBHEAD" = 1 ]; then
    "$ROOT/scripts/install-mobhead.sh" --dir "$SERVER_DIR"
    MOBHEAD_INFO="$(cut -f1,2 "$SERVER_DIR/plugins/mobhead.version" 2>/dev/null \
        | tr '\t' ' ' || echo latest)"
fi

if ! SERVER_PORT="$(python3 - "$SERVER_PORT" <<'PY'
import socket
import sys

preferred = int(sys.argv[1])
for port in [preferred, 0]:
    try:
        with socket.socket() as sock:
            sock.bind(("0.0.0.0", port))
            print(sock.getsockname()[1])
            break
    except OSError:
        continue
else:
    sys.exit(1)
PY
)"; then
    die "no free local port for the server"
fi

set_property "$SERVER_DIR/server.properties" server-port "$SERVER_PORT"
set_property "$SERVER_DIR/server.properties" server-ip ""
set_property "$SERVER_DIR/server.properties" online-mode "$ONLINE_MODE"
set_property "$SERVER_DIR/server.properties" max-players "$MAX_PLAYERS"
set_property "$SERVER_DIR/server.properties" motd "$MOTD"
set_property "$SERVER_DIR/server.properties" white-list "false"
set_property "$SERVER_DIR/server.properties" enforce-whitelist "false"
set_property "$SERVER_DIR/server.properties" enable-status "true"
grep -q '^server-port=' "$SERVER_DIR/server.properties" \
    || die "could not write $SERVER_DIR/server.properties"

# --- boot ------------------------------------------------------------------
log "starting Paper $PAPER_VERSION on 127.0.0.1:$SERVER_PORT with $MEMORY heap"
SERVER_DIR="$SERVER_DIR" SERVER_PORT="$SERVER_PORT" MEMORY="$MEMORY" \
    "$ROOT/scripts/start.sh" >>"$CONSOLE_LOG" 2>&1 &
SERVER_PID=$!

BOOT_WAIT=600
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -q 'Done (' "$CONSOLE_LOG" 2>/dev/null; then
        break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || die "the server exited while booting"
    sleep 1
done
grep -q 'Done (' "$CONSOLE_LOG" 2>/dev/null || die "the server did not finish booting"
log "server is up (local port $SERVER_PORT)"

# --- tunnel ----------------------------------------------------------------
start_tunnel() {
    # $1 is the fixed public port to request, empty for a random one.
    stop_tunnel
    : >"$TUNNEL_LOG"
    PUBLIC_ADDRESS=""
    # Clear the inherited PUBLIC_PORT so tunnel.sh only requests the port
    # given here; otherwise a failed fixed-port attempt would be repeated
    # instead of falling back.
    PUBLIC_PORT= "$ROOT/scripts/tunnel.sh" --port "$SERVER_PORT" \
        ${1:+--address "$1"} >>"$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 120); do
        PUBLIC_ADDRESS="$(sed 's/\x1b\[[0-9;]*m//g' "$TUNNEL_LOG" 2>/dev/null \
            | grep -o 'listening at [^ ]*' | awk '{print $3}' | head -1 || true)"
        [ -n "$PUBLIC_ADDRESS" ] && return 0
        kill -0 "$TUNNEL_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

open_public_tunnel() {
    PUBLIC_ADDRESS=""
    for candidate in "$PUBLIC_PORT" "$PUBLIC_PORT_FALLBACK"; do
        [ -n "$candidate" ] || continue
        log "opening the public tunnel, requesting port $candidate"
        start_tunnel "$candidate" || true
        [ -n "$PUBLIC_ADDRESS" ] && break
        warn "public port $candidate is not available"
    done
    if [ -z "$PUBLIC_ADDRESS" ]; then
        if [ -n "$PUBLIC_PORT$PUBLIC_PORT_FALLBACK" ]; then
            warn "no requested port is available, using a random port"
        else
            log "opening the public tunnel"
        fi
        start_tunnel "" || return 1
    fi
    ADDRESS_HOST="${PUBLIC_ADDRESS%:*}"
    ADDRESS_PORT="${PUBLIC_ADDRESS##*:}"
    printf '%s\n' "$PUBLIC_ADDRESS" >"$ADDRESS_FILE"
    return 0
}

if [ "$TUNNEL" = 1 ]; then
    open_public_tunnel || die "the tunnel did not report a public address"

    log "public address: $PUBLIC_ADDRESS"

    for attempt in 1 2 3 4 5; do
        if python3 "$ROOT/scripts/ping.py" "$ADDRESS_HOST" "$ADDRESS_PORT" --timeout 20; then
            break
        fi
        [ "$attempt" -eq 5 ] && die "the server is not reachable through $PUBLIC_ADDRESS"
        log "public ping attempt $attempt failed, retrying"
        sleep 2
    done

    printf '\n============================================================\n'
    printf ' Minecraft is public:  %s\n' "$PUBLIC_ADDRESS"
    printf ' Add it with Direct Connection in Minecraft.\n'
    printf '============================================================\n\n'
    write_summary
else
    log "tunnel disabled; joining works on 127.0.0.1:$SERVER_PORT only"
fi

# --- keep alive ------------------------------------------------------------
DEADLINE=$((STARTED_AT + SESSION_LENGTH * 60))
LAST_STATUS=0
TUNNEL_RESTARTS=0
while :; do
    NOW="$(date +%s)"
    [ "$NOW" -ge "$DEADLINE" ] && break
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        die "the server stopped before the end of the run"
    fi
    if [ "$TUNNEL" = 1 ] && ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        TUNNEL_RESTARTS=$((TUNNEL_RESTARTS + 1))
        [ "$TUNNEL_RESTARTS" -le 2 ] || die "the tunnel keeps stopping"
        warn "the tunnel stopped, reopening it ($TUNNEL_RESTARTS/2)"
        open_public_tunnel || die "could not reopen the tunnel"
        log "new public address: $PUBLIC_ADDRESS"
    fi
    if [ $((NOW - LAST_STATUS)) -ge 60 ]; then
        LAST_STATUS="$NOW"
        printf '==> session up %s/%s min' "$(( (NOW - STARTED_AT) / 60 ))" "$SESSION_LENGTH"
        [ -n "$PUBLIC_ADDRESS" ] && printf ', address %s' "$PUBLIC_ADDRESS"
        printf '\n'
    fi
    sleep 10
done

if [ "$REMAINING_AFTER" -gt 0 ]; then
    log "session $SESSION_NUMBER of $SESSIONS is over; queueing the continuation run for the remaining $REMAINING_AFTER minutes"
    env \
        DURATION_MINUTES="$DURATION_MINUTES" \
        ELAPSED_MINUTES="$((ELAPSED_MINUTES + SESSION_LENGTH))" \
        SESSION_MINUTES="$SESSION_MINUTES" \
        PUBLIC_PORT="$PUBLIC_PORT" \
        PUBLIC_PORT_FALLBACK="$PUBLIC_PORT_FALLBACK" \
        MEMORY="$MEMORY" \
        PAPER_VERSION="$PAPER_VERSION" \
        MOBHEAD="$MOBHEAD" \
        ONLINE_MODE="$ONLINE_MODE" \
        SAVE_WORLD="$SAVE_WORLD" \
        "$ROOT/scripts/dispatch-continuation.sh" \
        || die "the continuation run could not be queued"
    CONTINUING=1
else
    log "run time is over after $DURATION_MINUTES minutes"
fi
