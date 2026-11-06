#!/bin/sh
set -eu
umask 077
dir=/data/location
incoming=${1:-}
case "$incoming" in /tmp/native-location-*.conf) ;; *) echo 'Unexpected input path' >&2; exit 1;; esac
[ "${incoming%/*}" = /tmp ] && [ -f "$incoming" ] && [ ! -L "$incoming" ] || {
    echo 'Invalid location file' >&2; exit 1;
}
[ -f "$dir/original.init" ] || { echo 'Location module is not installed' >&2; exit 1; }
mkdir /tmp/native-location-update-lock 2>/dev/null || { echo 'Another location update is running'; exit 1; }
trap 'rm -f "$dir/location.conf.new" "$dir/location.previous.conf"; rmdir /tmp/native-location-update-lock' EXIT
had_previous=0
was_disabled=0
if [ -f "$dir/location.conf" ]; then
    cp "$dir/location.conf" "$dir/location.previous.conf"
    had_previous=1
fi
[ ! -e "$dir/disabled" ] || was_disabled=1
cp "$incoming" "$dir/location.conf.new"
chmod 600 "$dir/location.conf.new"
mv "$dir/location.conf.new" "$dir/location.conf"
rm -f "$dir/disabled"
if sh "$dir/activate.sh"; then
    rm -f "$incoming"
    exit 0
fi
if [ "$had_previous" = 1 ]; then
    mv "$dir/location.previous.conf" "$dir/location.conf"
else
    rm -f "$dir/location.conf"
fi
if [ "$was_disabled" = 1 ] || [ "$had_previous" = 0 ]; then
    sh "$dir/disable.sh" || { echo 'Could not restore the original service' >&2; exit 1; }
else
    rm -f "$dir/disabled"
    sh "$dir/activate.sh" || { echo 'Could not reapply the previous location' >&2; exit 1; }
fi
echo 'Update failed; previous location restored' >&2
exit 1
