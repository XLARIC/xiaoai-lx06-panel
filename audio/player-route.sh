#!/bin/sh
set -eu
config=$1
case "$config" in ''|/tmp/lx06-lg-native/alsa-[0-9]*.conf) ;; *) exit 1 ;; esac
test "$(sha256sum /etc/init.d/mediaplayer | cut -d ' ' -f 1)" = b190336455397795279313f703d7c68bec27da165e081d301f7328a7b0e751c0
player_pid() {
    ubus -t 2 call service list '{"name":"mediaplayer"}' | jsonfilter -e '@.mediaplayer.instances.instance1.pid'
}
routing() {
    tr '\000' '\n' < "/proc/$1/environ" | sed -n 's/^ALSA_CONFIG_PATH=//p'
}
pid=$(player_pid)
test "$(readlink "/proc/$pid/exe")" = /usr/bin/mediaplayer
previous=$(routing "$pid")
[ "$previous" != "$config" ] || exit 0
if [ -n "$previous" ] && ! printf '%s\n' "$previous" | grep -Eq '^/tmp/lx06-lg-native/alsa-[0-9]+[.]conf$'; then
    echo 'Existing unrelated audio routing retained.' >&2
    exit 1
fi
stock='{"name":"mediaplayer","script":"/etc/init.d/mediaplayer","instances":{"instance1":{"command":["/usr/bin/mediaplayer"],"nice":-15,"respawn":[3600,5,0],"term_timeout":5}}}'
player_config() {
    if [ -z "$1" ]; then
        printf '%s' "$stock"
    else
        printf '%s' "$stock" | sed "s@\"nice\":-15@\"env\":{\"ALSA_CONFIG_PATH\":\"$1\"},\"nice\":-15@"
    fi
}
rollback=$(player_config "$previous")
trap 'ubus -t 3 call service add "$rollback" >/dev/null || true' EXIT
ubus -t 3 call service add "$(player_config "$config")" >/dev/null
for attempt in 1 2 3 4 5 6; do
    new_pid=$(player_pid || true)
    if [ -n "$new_pid" ] && [ "$new_pid" != "$pid" ] && [ -r "/proc/$new_pid/environ" ] &&
        [ "$(routing "$new_pid")" = "$config" ] &&
        ubus -t 2 call mediaplayer get_media_volume >/dev/null 2>&1; then
        trap - EXIT
        exit 0
    fi
    sleep 1
done
echo 'The audio route did not become ready. Restoring the previous route.' >&2
exit 1
