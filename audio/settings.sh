#!/bin/sh
load_audio_settings() {
    mode=receive
    target=-
    delay=320
    settings=/data/lx06-lg-native/audio.conf
    if [ -e "$settings" ]; then
        IFS=' ' read -r mode target delay extra < "$settings" || return 1
        [ -z "$extra" ] || return 1
    fi
    case "$mode" in output|receive) ;; *) return 1 ;; esac
    case "$target" in
        -) [ "$mode" = receive ] || return 1 ;;
        [0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]) ;;
        *) return 1 ;;
    esac
    case "$delay" in ''|*[!0-9]*) return 1 ;; esac
    [ "$delay" -le 750 ]
}

# Only a confirmed pause or stop is safe for opening a new Bluetooth PCM.
playback_idle() {
    info=$(ubus -t 2 call mediaplayer player_get_play_status | jsonfilter -e '@.info') || return 1
    state=$(printf '%s\n' "$info" | jsonfilter -e '@.status') || return 1
    case "$state" in 0|2) return 0 ;; *) return 1 ;; esac
}
