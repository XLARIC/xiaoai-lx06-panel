#!/bin/sh
set -eu
case "${1:-}" in ''|*[!0-9]*) exit 2;; esac
test "$1" -le 750
base=/tmp/lx06-lg-native
test "$(sha256sum /etc/asound.conf | cut -d ' ' -f 1)" = defde08aca52aefc86a9b9233bc68e0276537b716a70efc64c1831de5279d659
sed '/"\/etc\/asound\.conf"/d' /usr/share/alsa/alsa.conf
awk '
    /^pcm\.dtsladspa[[:space:]]*\{/ { in_dts=1 }
    in_dts && $1 == "slave.pcm" && $2 == "plug:dmixer" {
        print "  slave.pcm plug:lg_sync_stage"
        modified++
        next
    }
    /^}/ { in_dts=0 }
    {print}
    END {if (modified!=1) exit 1}
' /etc/asound.conf
cat <<PCM
pcm.lg_sync_stage {
    type ladspa
    slave.pcm "plug:dmixer"
    channels 2
    path "$base/plugins"
    playback_plugins [{
        label lx06_lg_sync
        policy none
        input {
            bindings { 0 "Left In" 1 "Right In" }
            controls [ $1 ]
        }
        output {
            bindings { 0 "Left Out" 1 "Right Out" }
        }
    }]
}
PCM
