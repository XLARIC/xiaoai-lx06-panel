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
        if ! playback_idle; then
            printf 'quit\n'
            exit 0
        fi
        printf 'connect %s\n' "$target"
        sleep 15
        printf 'quit\n'
    } | timeout -t 19 bluetoothctl 2>&1 |
        grep -E 'Attempting to connect|Connection successful|Failed to connect' > "$dir/reconnect.log" || true
}

stop_sender() {
    rm -f "$dir/ready"
    if [ -n "$sender" ]; then
        ubus -t 3 call service delete "$sender_service" >/dev/null || true
    fi
}

link_up() {
    # A pending ACL can already appear in hcitool with handle 65535.
    hcitool con | awk -v mac="$target" '
        $2 == "ACL" && $3 == mac && $4 == "handle" &&
        $5 ~ /^[0-9]+$/ && $5 < 3840 && $6 == "state" && $7 == 1 { connected=1 }
        END { exit !connected }
    '
}

start_sender() {
    # Do not unlink a socket while the previous sender is still closing it.
    if [ -n "$sender" ] && [ -r "/proc/$sender/cmdline" ]; then
        sleep 1
        [ ! -r "/proc/$sender/cmdline" ] || return 1
    fi
    playback_idle || return 1
    rm -f "$dir/ready" "$dir/pcm.sock"
    ubus -t 3 call service add "$sender_start" >/dev/null || return 1
    for attempt in 1 2; do
        sleep 1
        [ ! -f "$dir/ready" ] || return 0
    done
    return 1
}

recover_output() {
    # Fall back to the local output without changing Bluetooth during playback.
    rm -f "$dir/ready"
    playback_idle || return 0
    stop_sender
    if link_up && start_sender; then
        return 0
    fi
    # ACL can be established before BlueALSA has an A2DP transport.
    selected=$target
    playback_idle || return 0
    connect_paired || return 1
    load_audio_settings && [ "$mode" = output ] && [ "$target" = "$selected" ] && link_up && playback_idle || return 1
    sender=$(ubus -t 2 call service list "$sender_service" | jsonfilter -e '@.lx06_lg_pcm.instances.sender.pid' || true)
    [ -z "$sender" ] || stop_sender
    start_sender
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
        if ! link_up || [ -z "$sender" ] || [ ! -r "/proc/$sender/cmdline" ] ||
            [ ! -f "$dir/ready" ] ||
            ! tr '\000' '\n' < "/proc/$sender/cmdline" | grep -Fxq "bluealsa:DEV=$target,PROFILE=a2dp"; then
            recover_output || true
        elif [ -f "$dir/send.log" ] && [ "$(wc -c < "$dir/send.log")" -gt 131072 ]; then
            : > "$dir/send.log"
        fi
    fi
    sleep 12
done
