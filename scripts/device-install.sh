umask 077
lock=/tmp/lx06-panel-install.lock
mkdir "$lock" 2>/dev/null || fail 'An install or uninstall is already in progress.'
stage=
panel=/data/lx06-panel
audio=/data/lx06-lg-native
location=/data/location
boot=/data/.lx06-panel-boot.$$
created_panel=0
created_audio=0
created_location=0
success=0
cleanup() {
    rm -f "$boot"
    if [ "$success" = 0 ]; then
        if [ "$created_panel" = 1 ]; then
            ubus -t 3 call service delete '{"name":"lx06_panel"}' >/dev/null 2>&1 || true
            rm -rf "$panel"
        fi
        if [ "$created_audio" = 1 ]; then
            ubus -t 3 call service delete '{"name":"lx06_lg_reconnect"}' >/dev/null 2>&1 || true
            rm -rf "$audio"
        fi
        if [ "$created_location" = 1 ]; then rm -rf "$location"; fi
    fi
    if [ -n "$stage" ]; then rm -rf "$stage"; fi
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
stage=$(mktemp -d /data/.lx06-panel.XXXXXX)
tar -xzf - -C "$stage"
(cd "$stage" && sha256sum -c package.sha256 >/dev/null)
chown -R 0:0 "$stage"
for dir in panel audio location; do
    chmod 700 "$stage/$dir"
    printf 'xiaoai-lx06-panel\n' > "$stage/$dir/installed-by"
done
cp /etc/init.d/mico_aivs_lab "$stage/location/original.init"
password=$(head -c 48 /dev/urandom | sha256sum | cut -c1-28)
[ "${#password}" = 28 ] || fail 'Password generation failed.'
printf '%s\n' "$password" > "$stage/panel/password"
chmod 600 "$stage/panel/password"

original=/data/init.sh
if [ -f "$original" ]; then cp -p "$original" "$stage/panel/init.before"; fi
{
    printf '#!/bin/sh\n# LX06_PANEL_BEGIN\n[ ! -x /data/lx06-panel/boot.sh ] || /data/lx06-panel/boot.sh\n# LX06_PANEL_END\n'
    if [ -f "$original" ]; then cat "$original"; fi
} > "$boot"
chmod 700 "$boot"
sh -n "$boot"

for path in "$panel" "$audio" "$location"; do [ ! -e "$path" ] || fail "Path was created during install: $path"; done
mv "$stage/location" "$location"; created_location=1
mv "$stage/audio" "$audio"; created_audio=1
mv "$stage/panel" "$panel"; created_panel=1
"$audio/activate.sh"
"$panel/start.sh" >/dev/null
ready=0
for attempt in 1 2 3 4 5 6; do
    pid=$(ubus -t 2 call service list '{"name":"lx06_panel"}' | jsonfilter -e '@.lx06_panel.instances.web.pid' || true)
    if [ -n "$pid" ] && [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$panel/lx06-panel" ] &&
        netstat -lnt 2>/dev/null | awk -v addr="${net%/*}:8086" '$4==addr {ok=1} END {exit !ok}'; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" = 1 ] || fail 'Web server did not start. Installation rolled back.'
if [ -f "$panel/init.before" ]; then
    cmp -s "$original" "$panel/init.before" || fail 'Boot configuration changed during installation.'
else
    [ ! -e "$original" ] && [ ! -L "$original" ] || fail 'Boot configuration appeared during installation.'
fi
mv "$boot" "$original"
success=1
sync
printf '\nURL      http://%s:8086/\nUsername admin\nPassword %s\n' "${net%/*}" "$password"
