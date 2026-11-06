set -eu
umask 077
panel=/data/lx06-panel
audio=/data/lx06-lg-native
location=/data/location
lock=/tmp/lx06-panel-install.lock
new=/data/.lx06-panel-uninstall.$$
test "$(id -u)" = 0
mkdir "$lock" 2>/dev/null || { echo 'An install or uninstall is already in progress.' >&2; exit 1; }
trap 'rm -f "$new"; rmdir "$lock" 2>/dev/null || true' EXIT
trap 'exit 1' INT TERM HUP
for dir in "$panel" "$audio" "$location"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] &&
        [ "$(cat "$dir/installed-by")" = xiaoai-lx06-panel ] || {
        echo "Cannot establish installer ownership of $dir; left untouched." >&2
        exit 1
    }
done
[ -f /data/init.sh ] && [ ! -L /data/init.sh ]
awk '
    $0=="# LX06_PANEL_BEGIN" { if (inside || ++starts != 1) exit 1; inside=1; next }
    $0=="# LX06_PANEL_END" { if (!inside || ++ends != 1) exit 1; inside=0; next }
    !inside { print }
    END { if (inside || starts!=1 || ends!=1) exit 1 }
' /data/init.sh > "$new"
sh -n "$new"
chmod 700 "$new"

ubus -t 3 call service delete '{"name":"lx06_panel"}' >/dev/null 2>&1 || true
"$audio/restore.sh"
"$location/disable.sh"
if [ -f "$panel/init.before" ] && tail -n +2 "$new" | cmp -s - "$panel/init.before"; then
    cp -p "$panel/init.before" "$new"
fi
if [ ! -f "$panel/init.before" ] && [ "$(cat "$new")" = '#!/bin/sh' ]; then
    rm /data/init.sh
else
    mv "$new" /data/init.sh
fi
rm -rf "$panel" "$audio" "$location" /tmp/lx06-lg-native
sync
echo 'Panel removed. Original player and Bluetooth receive routing restored.'
