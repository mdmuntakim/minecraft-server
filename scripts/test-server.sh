#!/usr/bin/env bash
# End-to-end test: boot Paper, query it with the Minecraft status protocol,
# run the MobHead self test over RCON, then ping it through a public bore
# tunnel.  Nothing here touches the checkout except the download cache.
#
#   ./scripts/test-server.sh
#   SKIP_TUNNEL=1 ./scripts/test-server.sh      # no public tunnel
#   WITH_MOBHEAD=0 ./scripts/test-server.sh     # plain Paper
#   KEEP_WORK=1 ./scripts/test-server.sh        # keep console.log and world
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

SKIP_TUNNEL="${SKIP_TUNNEL:-0}"
WITH_MOBHEAD="${WITH_MOBHEAD:-1}"
KEEP_WORK="${KEEP_WORK:-0}"

need "$JAVA_BIN"
need curl
need_python
need tar

major="$("$JAVA_BIN" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)"
[ -n "$major" ] && [ "$major" -ge 25 ] \
    || die "Paper $PAPER_VERSION needs Java 25+, found $("$JAVA_BIN" -version 2>&1 | head -1)"

PORT="$(free_port "${SERVER_PORT:-25565}")"
RCON_PORT="$(free_port 25575)"
while [ "$RCON_PORT" = "$PORT" ]; do
    RCON_PORT="$(free_port 25575)"
done
RCON_PASS="rcon-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/minecraft-server-test.XXXXXX")}"
CONSOLE="$WORK/console.log"

SERVER_PID=""
TUNNEL_PID=""
BOOT_SECONDS=0
RESULT_BOOT=FAIL
RESULT_PING=FAIL
RESULT_MOBHEAD=SKIP
RESULT_TUNNEL=SKIP
PUBLIC_ADDRESS=""

cleanup() {
    local code=$?
    trap - EXIT
    if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        log "stopping the test server"
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ "$code" -ne 0 ] && [ -f "$CONSOLE" ]; then
        printf '\n--- console tail ---\n' >&2
        tail -n 60 "$CONSOLE" >&2 || true
    fi
    if [ "$code" -eq 0 ] && [ "$KEEP_WORK" != 1 ]; then
        rm -rf "$WORK"
    elif [ "$KEEP_WORK" = 1 ]; then
        log "work directory kept at $WORK"
    fi
    exit "$code"
}
trap cleanup EXIT

log "work directory: $WORK"
mkdir -p "$WORK"
cp -a "$ROOT/server/." "$WORK/"

"$ROOT/scripts/get-paper.sh" --dir "$WORK" --version "$PAPER_VERSION" --build "$PAPER_BUILD"

if [ "$WITH_MOBHEAD" = 1 ]; then
    "$ROOT/scripts/install-mobhead.sh" --dir "$WORK"
fi

set_property "$WORK/server.properties" server-port "$PORT"
set_property "$WORK/server.properties" server-ip "127.0.0.1"
set_property "$WORK/server.properties" motd "PaperMC $PAPER_VERSION test"
set_property "$WORK/server.properties" max-players "5"
set_property "$WORK/server.properties" view-distance "4"
set_property "$WORK/server.properties" simulation-distance "4"
set_property "$WORK/server.properties" level-type "minecraft:flat"
set_property "$WORK/server.properties" generate-structures "false"
set_property "$WORK/server.properties" spawn-monsters "false"
set_property "$WORK/server.properties" online-mode "false"
set_property "$WORK/server.properties" enable-rcon "true"
set_property "$WORK/server.properties" rcon.port "$RCON_PORT"
set_property "$WORK/server.properties" rcon.password "$RCON_PASS"

log "starting Paper $PAPER_VERSION on 127.0.0.1:$PORT (RCON $RCON_PORT)"
# No subshell here: start.sh execs Java, so $! is the server process and the
# cleanup trap can stop it.  A subshell would leave an orphaned Java process.
SERVER_DIR="$WORK" SERVER_PORT="$PORT" MEMORY="${MEMORY:-1G}" \
    "$ROOT/scripts/start.sh" >>"$CONSOLE" 2>&1 &
SERVER_PID=$!

STARTED_AT="$(date +%s)"
for _ in $(seq 1 300); do
    if grep -q 'Done (' "$CONSOLE" 2>/dev/null; then
        BOOT_SECONDS=$(( $(date +%s) - STARTED_AT ))
        RESULT_BOOT=PASS
        break
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1
done
[ "$RESULT_BOOT" = PASS ] || die "the server did not finish booting (see $CONSOLE)"
log "server boot: PASS (${BOOT_SECONDS}s)"

if [ "$WITH_MOBHEAD" = 1 ]; then
    output=""
    for _ in $(seq 1 60); do
        if output="$(python3 "$ROOT/scripts/rcon.py" 127.0.0.1 "$RCON_PORT" \
                "$RCON_PASS" "mobhead selftest" 2>&1)"; then
            break
        fi
        output=""
        sleep 1
    done
    [ -n "$output" ] || die "could not run the MobHead self test over RCON"
    printf '%s\n' "$output"
    case "$output" in
        *"PASS"*) RESULT_MOBHEAD=PASS ;;
        *) die "MobHead self test did not report PASS" ;;
    esac
    log "MobHead selftest: PASS"

    log "mobhead info iron_golem"
    python3 "$ROOT/scripts/rcon.py" 127.0.0.1 "$RCON_PORT" "$RCON_PASS" \
        "mobhead info iron_golem"
fi

log "status ping 127.0.0.1:$PORT"
python3 "$ROOT/scripts/ping.py" 127.0.0.1 "$PORT"
RESULT_PING=PASS

if [ "$SKIP_TUNNEL" != 1 ]; then
    TUNNEL_LOG="$WORK/tunnel.log"
    log "starting the public tunnel for port $PORT"
    # tunnel.sh execs bore, so $! is the tunnel process that cleanup stops.
    "$ROOT/scripts/tunnel.sh" --port "$PORT" >"$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!

    for _ in $(seq 1 120); do
        PUBLIC_ADDRESS="$(sed 's/\x1b\[[0-9;]*m//g' "$TUNNEL_LOG" 2>/dev/null \
            | grep -o 'listening at [^ ]*' | awk '{print $3}' | head -1 || true)"
        [ -n "$PUBLIC_ADDRESS" ] && break
        kill -0 "$TUNNEL_PID" 2>/dev/null || break
        sleep 1
    done
    [ -n "$PUBLIC_ADDRESS" ] || die "the tunnel did not report a public address (see $TUNNEL_LOG)"

    host="${PUBLIC_ADDRESS%:*}"
    public_port="${PUBLIC_ADDRESS##*:}"
    log "public address: $PUBLIC_ADDRESS"
    for attempt in 1 2 3 4 5; do
        if python3 "$ROOT/scripts/ping.py" "$host" "$public_port" --timeout 20; then
            RESULT_TUNNEL=PASS
            break
        fi
        log "tunnel ping attempt $attempt failed, retrying"
        sleep 2
    done
    [ "$RESULT_TUNNEL" = PASS ] || die "the server is not reachable through $PUBLIC_ADDRESS"
    log "tunnel ping: PASS"
fi

printf '\n=== test matrix ===\n'
printf 'paper boot         %s (%ss)\n' "$RESULT_BOOT" "$BOOT_SECONDS"
printf 'status protocol    %s\n' "$RESULT_PING"
printf 'mobhead selftest   %s\n' "$RESULT_MOBHEAD"
printf 'public tunnel      %s%s\n' "$RESULT_TUNNEL" "${PUBLIC_ADDRESS:+ ($PUBLIC_ADDRESS)}"
