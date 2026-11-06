#!/bin/sh
set -eu
base=/data/lx06-lg-native
ubus -t 3 call service delete '{"name":"lx06_lg_reconnect"}' >/dev/null 2>&1 || true
ubus -t 3 call service delete '{"name":"lx06_lg_pcm"}' >/dev/null 2>&1 || true
rm -f /tmp/lx06-lg-native/ready
"$base/player-route.sh" ""
if "$base/profile.sh" receive; then
    exit 0
else
    test "$?" = 2
fi
for attempt in 1 2 3 4 5 6; do
    sleep 1
    if "$base/profile.sh" receive; then
        exit 0
    fi
done
echo 'Bluetooth receive service did not restart.' >&2
exit 1
