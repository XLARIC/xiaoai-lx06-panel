#!/bin/sh
set -eu
. /data/lx06-lg-native/settings.sh
dir=/tmp/lx06-lg-native
profile=/data/lx06-lg-native/profile.sh
sender_service='{"name":"lx06_lg_pcm"}'
sender_start='{"name":"lx06_lg_pcm","instances":{"sender":{"command":["/data/lx06-lg-native/launch-sender"],"term_timeout":2}}}'

connect_paired() {
    info=$({
        sleep 1
        printf 'info %s\nquit\n' "$target"
    } | timeout -t 4 bluetoothctl 2>/dev/null) || return 1
    printf '%s\n' "$info" | grep -Fq 'Paired: yes' || return 1
    {
        sleep 1
        printf 'connect %s\n' "$target"
        sleep 5
        printf 'quit\n'
    } | timeout -t 8 bluetoothctl >/dev/null 2>&1 || true
}

stop_sender() {
    rm -f "$dir/ready"
    if [ -n "$sender" ]; then
        ubus -t 3 call service delete "$sender_service" >/dev/null || true
    fi
}

while :; do
    if ! load_audio_settings; then
        sleep 12
        continue
    fi
    sender=$(ubus -t 2 call service list "$sender_service" | jsonfilter -e '@.lx06_lg_pcm.instances.sender.pid' || true)
    if [ "$mode" = receive ]; then
        stop_sender
        "$profile" receive || true
    elif "$profile" output; then
        if ! hcitool con | grep -Fq "$target"; then
            stop_sender
            connect_paired || true
        elif [ -z "$sender" ] || [ ! -r "/proc/$sender/cmdline" ]; then
            rm -f "$dir/ready" "$dir/pcm.sock"
            ubus -t 3 call service add "$sender_start" >/dev/null || true
        elif ! tr '\000' '\n' < "/proc/$sender/cmdline" | grep -Fxq "bluealsa:DEV=$target,PROFILE=a2dp"; then
            stop_sender
        elif [ -f "$dir/send.log" ] && [ "$(wc -c < "$dir/send.log")" -gt 131072 ]; then
            : > "$dir/send.log"
        fi
    fi
    sleep 12
done
