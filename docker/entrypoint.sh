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

# One SteamCMD pass over the redist and the server ($1 is "validate" or empty).
# Sets steam_rc to its exit code (a pipe into tee would hide it); the output is
# kept in $steam_out so a failure can quote the last lines.
run_steamcmd() {
    {
        if "$steamcmd" +force_install_dir "$install" +login anonymous \
                +app_update 1007 ${1:+"$1"} \
                +app_update "$app_id" ${1:+"$1"} \
                +quit; then
            echo 0 > "$steam_out.rc"
        else
            echo $? > "$steam_out.rc"
        fi
    } 2>&1 | tee "$steam_out" >&2
    read -r steam_rc < "$steam_out.rc"
}

# True when the last SteamCMD pass failed, or the installed build is not the
# public branch's. Sets installed and latest for the caller's log lines.
update_incomplete() {
    installed=$(installed_build)
    latest=$(steam_build)
    [ "$steam_rc" != "0" ] && return 0
    [ -n "$installed" ] && [ -n "$latest" ] && [ "$installed" != "$latest" ]
}

# Install or update the server into $install.
#
# A failed or partial update is retried once from a clean slate: the app
# manifest and SteamCMD's download state are removed and the files validated,
# because a stale manifest makes SteamCMD believe it is current while the
# files are not. If the update still fails, an installed build is run only
# when it is the latest one (or Steam cannot say what the latest is, so an
# outage does not take a working server down). An installed build known to be
# older is never run: players on the current version cannot join it, and
# starting it hides that from the orchestrator. The container exits non-zero
# instead.
update_server() {
    validate=""
    [ "${UPTIME_VALIDATE:-0}" = "1" ] && validate=validate
    steam_out=$(mktemp)
    log "updating server (app $app_id) in $install"
    run_steamcmd "$validate"
    if update_incomplete; then
        log "update did not complete (SteamCMD exit $steam_rc, installed build ${installed:-none}, latest ${latest:-unknown}); retrying once with validate after clearing the app manifest"
        manifest=$install/steamapps/appmanifest_$app_id.acf
        cp "$manifest" "$steam_out.acf" 2>/dev/null || true
        rm -f "$manifest"
        rm -rf "$install/steamapps/downloading" "$install/steamapps/temp"
        run_steamcmd validate
        # A retry that wrote nothing must not leave the installed build unnamed.
        [ -e "$manifest" ] || [ ! -e "$steam_out.acf" ] || cp "$steam_out.acf" "$manifest" 2>/dev/null || true
    fi
    if update_incomplete; then
        log "update failed again (SteamCMD exit $steam_rc, installed build ${installed:-unknown}, latest ${latest:-unknown}); last SteamCMD output:"
        tail -n 10 "$steam_out" | sed 's/^/uptime:   /' >&2
        if [ ! -x "$install/uptime-server" ]; then
            log "Steam download failed and no server is installed"
            log "a segfault right after 'Loading Steam API' is SteamCMD's 32-bit x86 client under ARM emulation."
            log "  No container platform flag fixes that: on an arm64 host it segfaults as linux/386 too."
            log "  Stage the server on a machine whose SteamCMD works, bind-mount it, set UPTIME_SERVER_DIR."
            rm -f "$steam_out" "$steam_out.rc" "$steam_out.acf"
            fail "otherwise check that app $app_id allows anonymous login and that Steam is reachable"
        elif [ -z "$latest" ]; then
            log "Steam is unreachable, starting the installed build ${installed:-unknown} (build not verified)"
        elif [ "$installed" = "$latest" ]; then
            log "installed build $installed is the latest, starting it"
        else
            rm -f "$steam_out" "$steam_out.rc" "$steam_out.acf"
            fail "refusing to run build ${installed:-unknown}: Steam has $latest and players on it cannot join an older server. Check that $install is writable and has free space, then restart (UPTIME_VALIDATE=1 forces a full check)."
        fi
    else
        log "server is up to date${installed:+, build $installed}"
    fi
    rm -f "$steam_out" "$steam_out.rc" "$steam_out.acf"
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
# The build a restart was last requested for. If the restart came back on the
# same old build, restarting again cannot help (the update itself is failing),
# so the check backs off and logs instead of looping every interval.
marker=$data/.update-restart-for
tried=$(head -n 1 "$marker" 2>/dev/null || true)
[ "$tried" != "$current" ] || { rm -f "$marker"; tried=""; }
wait_secs=$check_secs
while [ -z "$stopping" ] && kill -0 "$runner" 2>/dev/null; do
    sleep "$wait_secs" &
    wait $! || true
    if [ -n "$stopping" ] || ! kill -0 "$runner" 2>/dev/null; then
        break
    fi
    latest=$(steam_build)
    [ -n "$latest" ] && [ -n "$current" ] && [ "$latest" != "$current" ] || continue
    if [ "$latest" = "$tried" ]; then
        wait_secs=$(( wait_secs * 2 ))
        [ "$wait_secs" -le 86400 ] || wait_secs=86400
        log "Steam has build $latest but a restart already came back on build $current: the update is failing, not restarting again. Next check in $wait_secs s; see the SteamCMD output above."
        continue
    fi
    players=$(players_connected)
    if [ "$players" = "0" ]; then
        log "Steam has build $latest (running $current), no players connected, restarting to update"
        printf '%s\n' "$latest" > "$marker" 2>/dev/null || true
        kill -TERM "$runner" 2>/dev/null
        break
    fi
    log "Steam has build $latest (running $current), ${players:-unknown} player(s) connected, waiting"
done
wait "$runner" || exit $?
