#!/bin/sh
set -eu
export COPYFILE_DISABLE=1
usage() {
    echo 'Usage: ./install.sh [--check | --uninstall] <speaker-ip>' >&2
    exit 2
}
action=install
case "${1:-}" in
    --check) action=check; shift ;;
    --uninstall) action=uninstall; shift ;;
    --help|-h) usage ;;
esac
[ "$#" = 1 ] || usage
ip=$1
if ! printf '%s\n' "$ip" | awk -F. '
    NF != 4 || NR != 1 { exit 1 }
    { for (i=1; i<=4; i++) if ($i !~ /^(0|[1-9][0-9]*)$/ || $i>255) exit 1 }
    $1==10 || ($1==172 && $2>=16 && $2<=31) || ($1==192 && $2==168) { ok=1 }
    END { if (!ok) exit 1 }
'; then
    echo 'Use the private IPv4 address of your speaker.' >&2
    exit 2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
device_script="$root/scripts/device-$action.sh"
if [ ! -r "$device_script" ]; then
    echo 'Extract a complete release archive first.' >&2
    exit 2
fi
if [ "$action" = install ] && [ ! -r "$root/package/panel/lx06-panel" ]; then
    echo 'Download and extract a release archive, or build one with scripts/build.sh.' >&2
    exit 2
fi
if [ "$action" = install ]; then
    remote=$(cat "$root/scripts/device-check.sh" "$device_script")
else
    remote=$(cat "$device_script")
fi
connect() {
    ssh -T -o ConnectTimeout=8 -o StrictHostKeyChecking=ask \
        -o HostKeyAlgorithms=+ssh-rsa -o ForwardAgent=no -o ClearAllForwardings=yes \
        "root@$ip" "$remote"
}
if [ "$action" = install ]; then
    tar -czf - -C "$root/package" . | connect
else
    connect < /dev/null
fi
