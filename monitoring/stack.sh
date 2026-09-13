#!/bin/sh
# Bring the Uptime monitoring stack up, down, or tell you where it is.
#
#   ./stack.sh up              watch a game running on this machine
#   ./stack.sh up server       watch the dedicated server container in this repo
#   ./stack.sh down            stop it, keep the recorded history
#   ./stack.sh down --wipe     stop it and throw the history away
#   ./stack.sh logs [server]   follow the stack's logs
#   ./stack.sh status          what is running, and is it scraping
#   ./stack.sh urls            where to point a browser
#
# The only thing this does that `docker compose` cannot is pick the right
# compose file for the machine it is on, and then say whether the scrape
# actually landed. It prints the command it runs, so you can stop using it the
# moment you know which one you want.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$here")

GRAFANA_URL=http://127.0.0.1:3000
PROM_URL=http://127.0.0.1:9090

die() { echo "stack.sh: $*" >&2; exit 1; }

# Which compose file set to use.
#
# "local" splits again by host, because the game's API is loopback-only and the
# two cases reach a loopback listener differently. Docker Desktop and OrbStack
# proxy host.docker.internal to the host and reach it; a plain Linux daemon
# cannot, and has to share the host's network stack instead. Override with
# UPTIME_MONITORING_LAYER=desktop|hostnet|server when the guess is wrong.
resolve_layer() {
    if [ -n "${UPTIME_MONITORING_LAYER:-}" ]; then
        echo "$UPTIME_MONITORING_LAYER"
        return
    fi
    case ${1:-local} in
        server) echo server; return ;;
        local) ;;
        *) die "unknown target '$1' (expected 'local' or 'server')" ;;
    esac
    if [ "$(uname -s)" != Linux ]; then
        echo desktop
        return
    fi
    # Docker Desktop for Linux runs the daemon in a VM, so host networking
    # would join the VM rather than this machine. The daemon's own report is
    # the reliable way to tell it apart from a native one.
    if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
        echo desktop
    else
        echo hostnet
    fi
}

# Set compose_dir and compose_args for a layer.
compose_cmd() {
    case $1 in
        desktop) compose_dir=$here; compose_args="-f docker-compose.yml" ;;
        hostnet) compose_dir=$here; compose_args="-f compose.linux.yml" ;;
        server)  compose_dir=$root; compose_args="-f docker-compose.yml -f monitoring/compose.server.yml" ;;
        *) die "unknown layer '$1' (expected desktop, hostnet or server)" ;;
    esac
}

run_compose() {
    echo "+ (cd $compose_dir && docker compose $compose_args $*)"
    # shellcheck disable=SC2086
    ( cd "$compose_dir" && docker compose $compose_args "$@" )
}

# Pull the target word off the front of the argument list, if there is one.
# Everything else is passed through, so `down --wipe` still works.
take_target() {
    case ${1:-} in
        local|server) target=$1 ;;
        *) target=local ;;
    esac
}

# Poll Prometheus until the uptime job reports up, or give up and say why.
wait_for_scrape() {
    i=0
    while [ "$i" -lt 30 ]; do
        body=$(curl -fsS -m 3 "$PROM_URL/api/v1/targets?state=active" 2>/dev/null || true)
        # The API lists targets grouped by scrape pool, and "health" comes
        # after the pool name within each entry, so this matches the uptime
        # pool's own health and not the self-scrape's.
        case $body in
            *'"scrapePool":"uptime"'*'"health":"up"'*) echo "scraping: yes"; return 0 ;;
        esac
        i=$((i + 1))
        sleep 2
    done
    echo "scraping: NOT YET"
    echo
    case ${1:-local} in
        server)
            echo "  The server container has to be running and past its first world publish."
            echo "  Check it with:  docker logs uptime | tail -20"
            ;;
        *)
            echo "  Nothing is answering on 127.0.0.1:9875. Start a game, or a runner with"
            echo "  --http-port 9875, and this connects on its own within a few seconds."
            echo "  Nothing here needs restarting."
            ;;
    esac
    echo "  Live target state: $PROM_URL/targets"
}

cmd=${1:-up}
[ $# -gt 0 ] && shift

case $cmd in
    up)
        take_target "${1:-}"
        layer=$(resolve_layer "$target")
        compose_cmd "$layer"
        run_compose up -d
        echo
        echo "layer:   $layer"
        printf 'grafana: '
        i=0
        while [ "$i" -lt 45 ]; do
            curl -fsS -m 3 "$GRAFANA_URL/api/health" >/dev/null 2>&1 && break
            i=$((i + 1))
            sleep 1
        done
        if [ "$i" -lt 45 ]; then
            echo "$GRAFANA_URL"
        else
            echo "not answering yet; try $GRAFANA_URL in a moment"
        fi
        echo "prom:    $PROM_URL"
        wait_for_scrape "$target"
        ;;
    down)
        take_target "${1:-}"
        [ "$target" = local ] || shift
        layer=$(resolve_layer "$target")
        compose_cmd "$layer"
        if [ "${1:-}" = --wipe ]; then
            run_compose down --volumes
        else
            run_compose down
        fi
        ;;
    logs)
        take_target "${1:-}"
        layer=$(resolve_layer "$target")
        compose_cmd "$layer"
        run_compose logs -f --tail 50
        ;;
    status)
        for name in uptime-grafana uptime-prometheus uptime-metrics-relay; do
            state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo absent)
            echo "$name: $state"
        done
        wait_for_scrape
        ;;
    urls)
        echo "grafana: $GRAFANA_URL"
        echo "prom:    $PROM_URL"
        ;;
    -h|--help|help)
        grep '^#' "$0" | head -16 | cut -c3-
        ;;
    *)
        die "unknown command '$cmd' (up | down | logs | status | urls)"
        ;;
esac
