#!/bin/sh
set -eu
. /data/lx06-lg-native/settings.sh
dir=/tmp/lx06-lg-native
profile=/data/lx06-lg-native/profile.sh
sender_service='{"name":"lx06_lg_pcm"}'
sender_start='{"name":"lx06_lg_pcm","instances":{"sender":{"command":["/data/lx06-lg-native/launch-sender"],"term_timeout":2}}}'

connect_paired() {
    connect_target=$target
    info=$({
        sleep 1
        printf 'info %s\nquit\n' "$target"
    } | timeout -t 4 bluetoothctl 2>/dev/null) || return 1
    printf '%s\n' "$info" | grep -Fq 'Paired: yes' || return 1
    {
        sleep 1
        if ! load_audio_settings || [ "$mode" != output ] || [ "$target" != "$connect_target" ]; then
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
    connection_snapshot=$(hcitool con 2>/dev/null) || return 2
    printf '%s\n' "$connection_snapshot" | awk -v mac="$target" '
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

recover_idle_output() {
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


music_identity() {
    printf '%s\n' "$1" | sed -E 's/"position"[[:space:]]*:[[:space:]]*[0-9]+/"position":0/g'
}

current_player_pid() {
    ubus -t 2 call service list '{"name":"mediaplayer"}' | jsonfilter -e '@.mediaplayer.instances.instance1.pid'
}

resume_auto_pause() {
    [ "$auto_pause_pending" = 1 ] || return 0
    auto_pause_pending=0
    load_audio_settings && [ "$mode" = output ] && [ "$target" = "$auto_pause_target" ] || return 0
    [ "$(current_player_pid)" = "$auto_pause_pid" ] || return 0
    current=$(ubus -t 2 call mediaplayer player_get_play_status | jsonfilter -e '@.info') || return 0
    [ "$(printf '%s\n' "$current" | jsonfilter -e '@.status')" = 2 ] || return 0
    detail=$(printf '%s\n' "$current" | jsonfilter -e '@.play_song_detail') || return 0
    [ "$(music_identity "$detail")" = "$auto_pause_identity" ] || return 0
    if [ -n "$auto_pause_detail" ]; then
        [ "$detail" = "$auto_pause_detail" ] || return 0
    fi
    ubus -t 2 call mediaplayer player_play_operation '{"action":"play","media":"app_ios"}' >/dev/null || return 0
}

pause_music_for() {
    pause_action=$1
    pause_marker=$2
    pause_key=$3
    selected=$target
    state=
    if playback_idle; then return 0; fi
    load_audio_settings && [ "$mode" = output ] && [ "$target" = "$selected" ] || return 0
    [ "${state:-}" = 1 ] || return 0
    [ "$(printf '%s\n' "$info" | jsonfilter -e '@.media_type')" = 3 ] || return 0
    [ "$(cat "$pause_marker" 2>/dev/null || true)" != "$pause_key" ] || return 0
    before=$(printf '%s\n' "$info" | jsonfilter -e '@.play_song_detail') || return 0
    [ -n "$before" ] || return 0
    auto_pause_pid=$(current_player_pid) || return 0
    auto_pause_target=$target
    auto_pause_identity=$(music_identity "$before")
    auto_pause_detail=
    printf '%s\n' "$pause_key" > "$pause_marker"
    ubus -t 2 call mediaplayer player_play_operation '{"action":"pause","media":"app_ios"}' >/dev/null || return 0
    auto_pause_pending=1
    sleep 1
    if playback_idle && [ "$state" = 2 ]; then
        auto_pause_detail=$(printf '%s\n' "$info" | jsonfilter -e '@.play_song_detail' || true)
        if [ -n "$auto_pause_detail" ] &&
            [ "$(music_identity "$auto_pause_detail")" = "$auto_pause_identity" ]; then
            load_audio_settings && [ "$mode" = output ] && [ "$target" = "$auto_pause_target" ] &&
                "$pause_action" || true
        fi
    fi
    resume_auto_pause
}

prepare_sender() {
    # Do not keep music paused while waiting for an absent speaker.
    link_up || return 1
    stop_sender
    start_sender
}

prepare_profile() {
    stop_sender
    if "$profile" output; then return 0; else profile_result=$?; fi
    [ "$profile_result" = 2 ] || return 1
    for attempt in 1 2; do
        sleep 1
        if "$profile" output --check; then return 0; fi
    done
    return 1
}

recover_profile() {
    state=
    if playback_idle; then
        prepare_profile || true
    else
        profile_pid=$(ubus -t 2 call service list '{"name":"bluetooth"}' |
            jsonfilter -e '@.bluetooth.instances.instance1.pid') || return 0
        [ -n "$profile_pid" ] || return 0
        # One short pause per native Bluetooth service generation.
        pause_music_for prepare_profile "$dir/auto-profile-attempt" "$profile_pid $target"
    fi
}

recover_output() {
    rm -f "$dir/ready"
    if link_up; then link_result=0; else link_result=$?; fi
    if [ "$link_result" = 1 ]; then rm -f "$dir/auto-attach-target"; fi
    state=
    if playback_idle; then
        recover_idle_output || true
    elif [ "$link_result" = 0 ]; then
        pause_music_for prepare_sender "$dir/auto-attach-target" "$target" || true
    elif [ "$link_result" = 1 ]; then
        # Establish the paired link first. PCM acquisition still requires a pause.
        connect_paired || true
    fi
}

auto_pause_pending=0
trap resume_auto_pause EXIT
trap 'exit 0' INT TERM HUP

while :; do
    if ! load_audio_settings; then
        sleep 12
        continue
    fi
    sender=$(ubus -t 2 call service list "$sender_service" | jsonfilter -e '@.lx06_lg_pcm.instances.sender.pid' || true)
    if [ "$mode" = receive ]; then
        rm -f "$dir/auto-attach-target"
        stop_sender
        "$profile" receive || true
    elif "$profile" output --check; then
        if ! link_up || [ -z "$sender" ] || [ ! -r "/proc/$sender/cmdline" ] ||
            [ ! -f "$dir/ready" ] ||
            ! tr '\000' '\n' < "/proc/$sender/cmdline" | grep -Fxq "bluealsa:DEV=$target,PROFILE=a2dp"; then
            recover_output || true
        elif [ -f "$dir/send.log" ] && [ "$(wc -c < "$dir/send.log")" -gt 131072 ]; then
            : > "$dir/send.log"
        fi
    else
        profile_result=$?
        if [ "$profile_result" = 3 ]; then recover_profile || true; fi
    fi
    sleep 12
done
