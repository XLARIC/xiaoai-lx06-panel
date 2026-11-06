#!/bin/sh
set -eu
umask 077
dir=/data/lx06-panel
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    subnet=$(ip -4 addr show dev wlan0 2>/dev/null | awk '/inet / { print $2; exit }')
    if [ -n "$subnet" ]; then
        export GOMAXPROCS=1 GOGC=40 GOMEMLIMIT=8MiB
        exec "$dir/lx06-panel" -listen "${subnet%/*}:8086" -subnet "$subnet" -password-file "$dir/password"
    fi
    sleep 3
done
exit 1
