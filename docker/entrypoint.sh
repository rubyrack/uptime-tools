#!/bin/sh
set -eu

data=${UPTIME_DATA_DIR:-/data}
install=$data/server
steamcmd=$HOME/steamcmd/steamcmd.sh
app_id=5053430

log()  { printf 'uptime: %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }

installed_build() {
    grep -o '"buildid"[[:space:]]*"[0-9]*"' "$install/steamapps/appmanifest_$app_id.acf" 2>/dev/null \
        | head -n 1 | grep -o '[0-9][0-9]*' || true
}

steam_build() {
    "$steamcmd" +login anonymous +app_info_update 1 +app_info_print "$app_id" +quit 2>/dev/null \
        | grep -o '"buildid"[[:space:]]*"[0-9]*"' | head -n 1 | grep -o '[0-9][0-9]*' || true
}

# Connected players, from the runner's loopback API. The first request wakes
# its read model, the second reads a fresh one. Empty when unknown.
players_connected() {
    url="http://127.0.0.1:$http_port/api/v1/world"
    curl -fsS -m 5 "$url" >/dev/null 2>&1 || return 0
    sleep 3
    curl -fsS -m 5 "$url" 2>/dev/null | grep -o '"sessions_connected":[0-9]*' | grep -o '[0-9]*$' || true
}

password=${UPTIME_PASSWORD:-}
if [ -z "$password" ] && [ -n "${UPTIME_PASSWORD_FILE:-}" ]; then
    [ -r "$UPTIME_PASSWORD_FILE" ] || fail "UPTIME_PASSWORD_FILE is not readable: $UPTIME_PASSWORD_FILE"
    password=$(head -n 1 "$UPTIME_PASSWORD_FILE")
fi
[ -n "$password" ] || fail "UPTIME_PASSWORD (or UPTIME_PASSWORD_FILE) is required"

mkdir -p "$install" "$data/worlds"
if [ "${UPTIME_UPDATE:-1}" = "1" ]; then
    validate=""
    [ "${UPTIME_VALIDATE:-0}" = "1" ] && validate=validate
    log "updating server (app $app_id)"
    # shellcheck disable=SC2086
    if "$steamcmd" +force_install_dir "$install" +login anonymous \
            +app_update 1007 $validate \
            +app_update "$app_id" $validate \
            +quit; then
        build=$(installed_build)
        log "server is up to date${build:+, build $build}"
    elif [ -x "$install/uptime-server" ]; then
        log "Steam update failed, starting the installed build"
    else
        log "Steam download failed and no server is installed"
        log "a segfault right after 'Loading Steam API' means SteamCMD is running under x86_64 emulation; use an amd64 host"
        fail "otherwise check that app $app_id allows anonymous login and that Steam is reachable"
    fi
fi
[ -x "$install/start_server.sh" ] || fail "no server in $install; set UPTIME_UPDATE=1"
chmod 0755 "$install/uptime-server" "$install/start_server.sh" 2>/dev/null || true

for candidate in "$install/linux64/steamclient.so" "$HOME/steamcmd/linux64/steamclient.so"; do
    if [ -f "$candidate" ]; then
        mkdir -p "$HOME/.steam/sdk64"
        ln -sf "$candidate" "$HOME/.steam/sdk64/steamclient.so"
        break
    fi
done

world=${UPTIME_WORLD:-worlds/main.save}
case "$world" in
    /*) ;;
    *) world="$data/$world" ;;
esac
world_dir=$(dirname "$world")
mkdir -p "$world_dir"
for f in adminlist.txt bannedlist.txt permittedlist.txt; do
    [ -e "$world_dir/$f" ] || : > "$world_dir/$f"
done

query_port=${UPTIME_QUERY_PORT:-27016}
tunnel=${UPTIME_TUNNEL:-none}
tunnel_addr=""
case "$tunnel" in
    none) ;;
    playit|pinggy)
        tunnel_addr=$(QUERY_PORT="$query_port" sh "$HOME/tunnels/$tunnel.sh") \
            || fail "tunnel '$tunnel' failed, see $HOME/$tunnel.log"
        ;;
    *) fail "UPTIME_TUNNEL must be none, playit or pinggy" ;;
esac

# The game stores favourites by IPv4, so a hostname is resolved once here.
public_addr=${UPTIME_PUBLIC_ADDR:-$tunnel_addr}
if [ -n "$public_addr" ]; then
    host=${public_addr%:*}
    port=${public_addr##*:}
    case "$host" in
        *[!0-9.]*)
            ip=$(getent ahostsv4 "$host" 2>/dev/null | head -n 1 | cut -d ' ' -f 1)
            [ -n "$ip" ] || fail "cannot resolve $host"
            log "public address $host:$port -> $ip:$port"
            public_addr="$ip:$port"
            ;;
    esac
fi

set -- \
    --world "$world" \
    --scenario "${UPTIME_SCENARIO:-garage-to-glory}" \
    --name "${UPTIME_NAME:-Uptime server}" \
    --password "$password" \
    --query-port "$query_port" \
    --steam-port "${UPTIME_STEAM_PORT:-27015}" \
    "$@"

http_port=${UPTIME_HTTP_PORT:-9875}
[ "$http_port" != "0" ]            && set -- --http-port "$http_port" "$@"
[ -n "${UPTIME_MAX_PLAYERS:-}" ]   && set -- --max-players "$UPTIME_MAX_PLAYERS" "$@"
[ -n "${UPTIME_AUTOSAVE_SECS:-}" ] && set -- --autosave-secs "$UPTIME_AUTOSAVE_SECS" "$@"
[ -n "${UPTIME_SEED:-}" ]          && set -- --seed "$UPTIME_SEED" "$@"
[ -n "$public_addr" ]              && set -- --public-addr "$public_addr" "$@"
[ "${UPTIME_PUBLIC:-0}" = "1" ]    && set -- --public "$@"
[ "${UPTIME_HARD:-0}" = "1" ]      && set -- --hard "$@"

cd "$install"
check_secs=$(( ${UPTIME_UPDATE_CHECK_MINS:-30} * 60 ))
[ -n "${UPTIME_UPDATE_CHECK_SECS:-}" ] && check_secs=$UPTIME_UPDATE_CHECK_SECS
if [ "${UPTIME_UPDATE:-1}" != "1" ] || [ "$check_secs" -le 0 ] || [ "$http_port" = "0" ]; then
    log "starting"
    exec ./start_server.sh "$@"
fi

# When Steam has a new build and nobody is connected, stop the runner (it
# saves on SIGTERM); the restart policy brings the container back through
# the update above. With players on, check again next interval.
log "starting, checking Steam for a new build every $check_secs s"
./start_server.sh "$@" &
runner=$!
trap 'kill -TERM "$runner" 2>/dev/null' TERM INT
current=$(installed_build)
while kill -0 "$runner" 2>/dev/null; do
    sleep "$check_secs" &
    wait $! || true
    kill -0 "$runner" 2>/dev/null || break
    latest=$(steam_build)
    [ -n "$latest" ] && [ -n "$current" ] && [ "$latest" != "$current" ] || continue
    players=$(players_connected)
    if [ "$players" = "0" ]; then
        log "Steam has build $latest (running $current), no players connected, restarting to update"
        kill -TERM "$runner" 2>/dev/null
        break
    fi
    log "Steam has build $latest (running $current), ${players:-unknown} player(s) connected, waiting"
done
wait "$runner" || exit $?
