#!/bin/sh
set -eu

data=${UPTIME_DATA_DIR:-/data}
install=$data/server
steamcmd=$HOME/steamcmd/steamcmd.sh
app_id=5053430

log()  { printf 'uptime: %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }

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
        log "server is up to date"
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

log "starting"
cd "$install"
exec ./start_server.sh "$@"
