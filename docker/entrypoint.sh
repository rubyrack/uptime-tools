#!/bin/sh
set -eu

app_id=5053430

log()  { printf 'uptime: %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }

# PUID/PGID: when started as root, make the `uptime` user those ids, give it
# the data and its home, and re-run this script as that user.
if [ "$(id -u)" = "0" ]; then
    puid=${PUID:-1000}
    pgid=${PGID:-1000}
    case "$puid$pgid" in *[!0-9]*) fail "PUID and PGID must be numeric" ;; esac
    [ "$(id -g uptime)" = "$pgid" ] || groupmod -o -g "$pgid" uptime
    [ "$(id -u uptime)" = "$puid" ] || usermod -o -u "$puid" -g "$pgid" uptime
    chown -R uptime:uptime /home/uptime
    [ -d "${UPTIME_DATA_DIR:-/data}" ] && chown -R uptime:uptime "${UPTIME_DATA_DIR:-/data}"
    log "running as uid $puid gid $pgid"
    exec setpriv --reuid=uptime --regid=uptime --init-groups env HOME=/home/uptime USER=uptime "$0" "$@"
fi

installed_build() {
    grep -o '"buildid"[[:space:]]*"[0-9]*"' "$install/steamapps/appmanifest_$app_id.acf" 2>/dev/null \
        | head -n 1 | grep -o '[0-9][0-9]*' || true
}

# The public branch's buildid; the dump lists every branch.
steam_build() {
    "$steamcmd" +login anonymous +app_info_update 1 +app_info_print "$app_id" +quit 2>/dev/null \
        | awk '/"public"/ { p = 1 } p && /"buildid"/ { print; exit }' \
        | grep -o '[0-9][0-9]*' | head -n 1 || true
}

# Connected players, from the runner's loopback API. The first request wakes
# its read model, the second reads a fresh one. Empty when unknown.
players_connected() {
    url="http://127.0.0.1:$http_port/api/v1/world"
    curl -fsS -m 5 "$url" >/dev/null 2>&1 || return 0
    sleep 3
    curl -fsS -m 5 "$url" 2>/dev/null | grep -o '"sessions_connected":[0-9]*' | grep -o '[0-9]*$' || true
}

# Install or update the server into $install. Leaves an installed build in
# place when Steam is unreachable.
update_server() {
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
        log "a segfault right after 'Loading Steam API' is SteamCMD's 32-bit x86 client under ARM emulation."
        log "  No container platform flag fixes that: on an arm64 host it segfaults as linux/386 too."
        log "  Stage the server on a machine whose SteamCMD works, bind-mount it, set UPTIME_SERVER_DIR."
        fail "otherwise check that app $app_id allows anonymous login and that Steam is reachable"
    fi
}

# Non-zero when there is no 64-bit steamclient.so to link, so a staged server
# missing Valve's redist says so at start instead of failing the Steam link.
link_steamclient() {
    for candidate in "$install/linux64/steamclient.so" "$(dirname "$steamcmd")/linux64/steamclient.so"; do
        if [ -f "$candidate" ]; then
            mkdir -p "$HOME/.steam/sdk64"
            ln -sf "$candidate" "$HOME/.steam/sdk64/steamclient.so"
            return 0
        fi
    done
    return 1
}

make_access_lists() {
    mkdir -p "$1"
    for f in adminlist.txt bannedlist.txt permittedlist.txt; do
        [ -e "$1/$f" ] || : > "$1/$f"
    done
}

# This image is for `docker run` / compose. Pterodactyl runs the egg on the
# community SteamCMD image instead (see pterodactyl/egg-uptime.json): Wings
# owns the server directory and the uid it runs containers as, and this image
# bakes its own user and HOME.
data=${UPTIME_DATA_DIR:-/data}
steamcmd=$HOME/steamcmd/steamcmd.sh

# UPTIME_SERVER_DIR runs a build the operator staged, instead of one SteamCMD
# downloads here. It exists because Steam's Linux SteamCMD is a 32-bit x86
# binary: on an arm64 host (Apple Silicon, Graviton, Ampere, Asahi) it
# segfaults in `Loading Steam API` whatever the container platform says, so
# the download simply cannot happen in-container there. Stage the depot on a
# machine whose SteamCMD works, bind-mount it (read-only is fine, nothing is
# written to it) and point this at it. Updating a directory the operator
# supplied is not this container's business, so setting it turns the Steam
# update off unless UPTIME_UPDATE says otherwise.
install=${UPTIME_SERVER_DIR:-$data/server}
if [ -n "${UPTIME_UPDATE:-}" ]; then
    update=$UPTIME_UPDATE
elif [ -n "${UPTIME_SERVER_DIR:-}" ]; then
    update=0
else
    update=1
fi

password=${UPTIME_PASSWORD:-}
if [ -z "$password" ] && [ -n "${UPTIME_PASSWORD_FILE:-}" ]; then
    [ -r "$UPTIME_PASSWORD_FILE" ] || fail "UPTIME_PASSWORD_FILE is not readable: $UPTIME_PASSWORD_FILE"
    password=$(head -n 1 "$UPTIME_PASSWORD_FILE")
fi
[ -n "$password" ] || log "no UPTIME_PASSWORD: this is an open server, anyone with the address or the SteamID can join"

mkdir -p "$data/worlds"
if [ -n "${UPTIME_SERVER_DIR:-}" ]; then
    [ -d "$install" ] || fail "UPTIME_SERVER_DIR is not a directory in the container: $install (bind-mount the staged server there)"
else
    mkdir -p "$install"
fi
if [ "$update" = "1" ]; then
    update_server
fi

# Best effort before the check, not after it: a depot copied from another
# machine can arrive without the execute bit, and this is what restores it.
# A read-only mount is the case where it cannot, hence the second message.
chmod 0755 "$install/uptime-server" "$install/start_server.sh" 2>/dev/null || true
if [ ! -x "$install/start_server.sh" ] || [ ! -x "$install/uptime-server" ]; then
    [ -z "${UPTIME_SERVER_DIR:-}" ] \
        || fail "no runnable server in UPTIME_SERVER_DIR ($install): both uptime-server and start_server.sh must be present and executable. On a read-only mount this container cannot add the execute bit; chmod +x them on the host."
    fail "no server in $install; set UPTIME_UPDATE=1, or stage one yourself and set UPTIME_SERVER_DIR"
fi
link_steamclient \
    || log "no 64-bit steamclient.so under $install/linux64 or in the steamcmd install: the Steam link will not come up. Stage Valve's redist beside the server (+app_update 1007)."

world=${UPTIME_WORLD:-worlds/main.save}
case "$world" in
    /*) ;;
    *) world="$data/$world" ;;
esac
make_access_lists "$(dirname "$world")"

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
    --query-port "$query_port" \
    --steam-port "${UPTIME_STEAM_PORT:-27015}" \
    "$@"

http_port=${UPTIME_HTTP_PORT:-9875}
[ -n "$password" ]                 && set -- --password "$password" "$@"
[ "$http_port" != "0" ]            && set -- --http-port "$http_port" "$@"
[ -n "${UPTIME_MAX_PLAYERS:-}" ]   && set -- --max-players "$UPTIME_MAX_PLAYERS" "$@"
[ -n "${UPTIME_AUTOSAVE_SECS:-}" ] && set -- --autosave-secs "$UPTIME_AUTOSAVE_SECS" "$@"
[ -n "${UPTIME_SEED:-}" ]          && set -- --seed "$UPTIME_SEED" "$@"
[ -n "${UPTIME_SITE:-}" ]          && set -- --site "$UPTIME_SITE" "$@"
[ -n "$public_addr" ]              && set -- --public-addr "$public_addr" "$@"
[ "${UPTIME_PUBLIC:-0}" = "1" ]    && set -- --public "$@"
[ "${UPTIME_HARD:-0}" = "1" ]      && set -- --hard "$@"

cd "$install"
check_secs=$(( ${UPTIME_UPDATE_CHECK_MINS:-30} * 60 ))
[ -n "${UPTIME_UPDATE_CHECK_SECS:-}" ] && check_secs=$UPTIME_UPDATE_CHECK_SECS
if [ "$update" != "1" ] || [ "$check_secs" -le 0 ] || [ "$http_port" = "0" ]; then
    log "starting"
    exec ./start_server.sh "$@"
fi

# When Steam has a new build and nobody is connected, stop the runner (it
# saves on SIGTERM); the restart policy brings the container back through
# the update above. With players on, check again next interval.
log "starting, checking Steam for a new build every $check_secs s"
./start_server.sh "$@" &
runner=$!
stopping=""
trap 'stopping=1; kill -TERM "$runner" 2>/dev/null' TERM INT
current=$(installed_build)
while [ -z "$stopping" ] && kill -0 "$runner" 2>/dev/null; do
    sleep "$check_secs" &
    wait $! || true
    if [ -n "$stopping" ] || ! kill -0 "$runner" 2>/dev/null; then
        break
    fi
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
