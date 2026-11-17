#!/bin/sh
# Exit 2 after requesting a change, or 3 when a probe finds a change is needed.
set -eu
mode=$1
case "$mode" in output|receive) ;; *) exit 1 ;; esac
probe=${2:-}
case "$probe" in ''|--check) ;; *) exit 1 ;; esac
service='{"name":"bluetooth"}'
apply_profile() {
    pid=$(ubus -t 2 call service list "$service" | jsonfilter -e '@.bluetooth.instances.instance1.pid') || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    args=$(tr '\000' ' ' < "/proc/$pid/cmdline") || return 1
    case "$args" in
        '/usr/bin/bluealsa -i hci0 -p a2dp-sink '|'/usr/bin/bluealsa -i hci0 -p a2dp-sink -p a2dp-source ') debug= ;;
        '/usr/bin/bluealsa -i hci0 -p a2dp-sink -S '|'/usr/bin/bluealsa -i hci0 -p a2dp-sink -p a2dp-source -S ') debug=',"-S"' ;;
        *) return 1 ;;
    esac
    case "$mode:$args" in
        output:*'-p a2dp-source '*) return 0 ;;
        receive:*'-p a2dp-source '*) profile= ;;
        receive:*) return 0 ;;
        output:*) profile=',"-p","a2dp-source"' ;;
    esac
    [ "$probe" != --check ] || return 3
    if [ "$mode" = output ]; then
        . /data/lx06-lg-native/settings.sh
        playback_idle || return 1
    fi
    ubus -t 3 call service add '{"name":"bluetooth","script":"/etc/init.d/bluetooth","instances":{"instance1":{"command":["/usr/bin/bluealsa","-i","hci0","-p","a2dp-sink"'"$profile$debug"'],"respawn":[3600,5,5],"term_timeout":5}}}' >/dev/null || return 1
    return 2
}

apply_profile
