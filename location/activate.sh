#!/bin/sh
# LX06 1.94.13 only. Keep the voice process's original local timezone.
set -eu
umask 077
dir=/data/location
service=/etc/init.d/mico_aivs_lab
service_hash=cc17eb3e7b4981098aa145c88804be57dbd931fb0cf7dd9ea19fafd7a432c819
[ -f "$dir/location.conf" ] && [ ! -e "$dir/disabled" ] || exit 0
mkdir /tmp/native-location-lock 2>/dev/null || { echo 'Another location change is running'; exit 1; }
trap 'rm -f "$dir/service.init.new"; rmdir /tmp/native-location-lock' EXIT
fail() { printf '%s\n' "$1" > /tmp/native-location.status; echo "$1" >&2; exit 1; }
check_hash() { printf '%s  %s\n' "$1" "$2" | sha256sum -c >/dev/null; }
check_hash 6ba3668e9fc39d5580bfd0ee79bee1b54e1f6ee76a13dee805a3c945e4a5eb45 /usr/lib/libaivs_sdk.so || fail 'Unsupported SDK; voice service retained'
check_hash e7d03a1ddc5cd95caabfe6b87b0114236d2f54de07fd66b4e1f738252132f606 /usr/bin/mico_aivs_lab || fail 'Unsupported voice service; retained'
check_hash "$service_hash" "$dir/original.init" || fail 'Unexpected saved service script; voice service retained'
(cd "$dir" && sha256sum -c module.sha256 >/dev/null) || fail 'Module checksum mismatch'
awk -F= '
    NF != 2 { invalid = 1; exit }
    $1 == "latitude" { if ($2 !~ /^[+-]?[0-9]+([.][0-9]+)?$/ || $2 < -90 || $2 > 90) invalid = 1; a++; next }
    $1 == "longitude" { if ($2 !~ /^[+-]?[0-9]+([.][0-9]+)?$/ || $2 < -180 || $2 > 180) invalid = 1; b++; next }
    $1 == "time_zone" { if ($2 !~ /^[A-Za-z0-9_+\/-]+$/ || $2 ~ /^\// || length($2) > 127) invalid = 1; c++; next }
    { invalid = 1 }
    END { if (invalid || a != 1 || b != 1 || c != 1) exit 1 }
' "$dir/location.conf" || fail 'Invalid location config; voice service retained'
awk '
    { print }
    /procd_set_param command \/usr\/bin\/mico_aivs_lab/ {
        print "    procd_set_param env LD_PRELOAD=/data/location/native-location.so XIAOAI_LOCATION_CONFIG=/data/location/location.conf"
        found++
    }
    END { if (found != 1) exit 1 }
' "$dir/original.init" > "$dir/service.init.new" || fail 'Service injection failed'
chmod 755 "$dir/service.init.new"
sh -n "$dir/service.init.new" || fail 'Generated service script is invalid'
if mount | grep -Fq " on $service "; then
    cmp -s "$service" "$dir/service.init.new" || fail 'Unrecognized service mount; retained'
else
    check_hash "$service_hash" "$service" || fail 'Unexpected service script; retained'
    mv "$dir/service.init.new" "$dir/service.init"
    mount --bind "$dir/service.init" "$service" || fail 'Could not mount location service'
fi
"$service" restart > /tmp/native-location.restart.log 2>&1 || true
for attempt in 1 2 3 4 5; do
    sleep 1
    for pid in $(pidof mico_aivs_lab || true); do
        if grep -Fq '/data/location/native-location.so' "/proc/$pid/maps" 2>/dev/null; then
            printf 'enabled; %s; pid=%s; process timezone unchanged\n' "$(grep '^time_zone=' "$dir/location.conf")" "$pid" > /tmp/native-location.status
            exit 0
        fi
    done
done
touch "$dir/disabled"
umount "$service" || fail 'Voice module failed and the service mount could not be removed'
"$service" restart > /tmp/native-location.restart.log 2>&1 || true
fail 'Voice module failed; original service restored'
