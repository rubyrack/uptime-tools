#!/bin/sh
# Opens a Pinggy UDP tunnel to the query port and prints the public host:port.
set -eu
log=$HOME/pinggy.log
port=${QUERY_PORT:-27016}
: > "$log"
if [ -n "${PINGGY_TOKEN:-}" ]; then
    pinggy --type udp --token "$PINGGY_TOKEN" -l "$port" >"$log" 2>&1 </dev/null &
else
    pinggy --type udp -l "$port" >"$log" 2>&1 </dev/null &
fi
echo "uptime: pinggy started, waiting for the public address" >&2

i=0
while [ "$i" -lt 60 ]; do
    addr=$(grep -o -E '[A-Za-z0-9.-]+\.pinggy\.(link|io):[0-9]+' "$log" | head -n 1 || true)
    if [ -n "$addr" ]; then
        echo "uptime: pinggy public address $addr" >&2
        echo "$addr"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done
echo "uptime: pinggy did not print a public address within 60s" >&2
cat "$log" >&2
exit 1
