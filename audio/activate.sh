#!/bin/sh
set -eu
umask 077
base=/data/lx06-lg-native
dir=/tmp/lx06-lg-native
. "$base/settings.sh"
load_audio_settings
test "$(sha256sum /etc/init.d/mediaplayer | cut -d ' ' -f 1)" = b190336455397795279313f703d7c68bec27da165e081d301f7328a7b0e751c0
test "$(sha256sum /etc/asound.conf | cut -d ' ' -f 1)" = defde08aca52aefc86a9b9233bc68e0276537b716a70efc64c1831de5279d659
(cd "$base" && sha256sum -c package.sha256 >/dev/null)
mkdir -p "$dir/plugins"
config=
if [ "$mode" = output ]; then
    config="$dir/alsa-$delay.conf"
    cp "$base/lx06_lg_sync.so" "$dir/plugins/.new.so"
    mv "$dir/plugins/.new.so" "$dir/plugins/lx06_lg_sync.so"
    "$base/configure.sh" "$delay" > "$dir/.alsa-new.conf"
    mv "$dir/.alsa-new.conf" "$config"
fi
"$base/player-route.sh" "$config"
ubus -t 3 call service add '{"name":"lx06_lg_reconnect","instances":{"supervisor":{"command":["/data/lx06-lg-native/supervise.sh"],"respawn":[3600,5,5],"term_timeout":2}}}' >/dev/null
