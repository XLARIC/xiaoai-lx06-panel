#!/bin/sh
set -eu
umask 077
dir=/data/location
service=/etc/init.d/mico_aivs_lab
mkdir /tmp/native-location-lock 2>/dev/null || { echo 'Another location change is running'; exit 1; }
trap 'rmdir /tmp/native-location-lock' EXIT
if mount | grep -Fq " on $service "; then
    cmp -s "$service" "$dir/service.init" || { echo 'Unrecognized service mount; retained' >&2; exit 1; }
    touch "$dir/disabled"
    umount "$service"
    "$service" restart > /tmp/native-location.restart.log 2>&1
elif [ -f "$dir/location.conf" ]; then
    touch "$dir/disabled"
fi
printf 'disabled; original voice service restored\n' > /tmp/native-location.status
