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
