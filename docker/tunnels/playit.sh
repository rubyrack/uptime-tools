#!/bin/sh
# Starts the playit.gg agent. The tunnel itself is configured in the playit
# dashboard (UDP, local port = query port); its address goes in UPTIME_PUBLIC_ADDR.
set -eu
log=$HOME/playit.log
[ -n "${PLAYIT_SECRET_KEY:-}" ] || { echo "uptime: PLAYIT_SECRET_KEY is required for UPTIME_TUNNEL=playit" >&2; exit 1; }
SECRET_KEY="$PLAYIT_SECRET_KEY" playit >"$log" 2>&1 </dev/null &
echo "uptime: playit agent started, tunnel target 127.0.0.1:${QUERY_PORT:-27016} udp" >&2
[ -n "${UPTIME_PUBLIC_ADDR:-}" ] || echo "uptime: UPTIME_PUBLIC_ADDR is not set; joiners will get this host's address" >&2
