set -eu
fail() { echo "$1" >&2; exit 1; }
test "$(id -u)" = 0 || fail 'Root SSH access is required.'
for cmd in sha256sum jsonfilter ubus ip bluetoothctl hcitool aplay mktemp; do
    command -v "$cmd" >/dev/null || fail "Missing device command: $cmd"
done
sha() { sha256sum "$1" | cut -d ' ' -f 1; }
[ "$(sha /etc/init.d/mediaplayer)" = b190336455397795279313f703d7c68bec27da165e081d301f7328a7b0e751c0 ] &&
[ "$(sha /etc/asound.conf)" = defde08aca52aefc86a9b9233bc68e0276537b716a70efc64c1831de5279d659 ] &&
[ "$(sha /usr/lib/libaivs_sdk.so)" = 6ba3668e9fc39d5580bfd0ee79bee1b54e1f6ee76a13dee805a3c945e4a5eb45 ] &&
[ "$(sha /usr/bin/mico_aivs_lab)" = e7d03a1ddc5cd95caabfe6b87b0114236d2f54de07fd66b4e1f738252132f606 ] &&
[ "$(sha /etc/init.d/mico_aivs_lab)" = cc17eb3e7b4981098aa145c88804be57dbd931fb0cf7dd9ea19fafd7a432c819 ] ||
    fail 'Firmware or active service differs from the supported LX06 1.94.13 baseline.'
grep -Fq '/data/init.sh' /etc/rc.local ||
    fail 'The /data/init.sh boot hook is missing. See the upstream Open-XiaoAI guide.'
[ -r /usr/lib/libasound.so.2 ] && [ -r /lib/ld-linux-armhf.so.3 ] ||
    fail 'The ARM hard-float audio runtime is missing.'
net=$(ip -4 addr show dev wlan0 | awk '/inet / { print $2; exit }')
[ -n "$net" ] || fail 'Connect the speaker to Wi-Fi first.'
for path in /data/lx06-panel /data/lx06-lg-native /data/location; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "Existing installation or custom configuration at $path. It has been left untouched."
done
if [ -e /data/init.sh ] || [ -L /data/init.sh ]; then
    [ -f /data/init.sh ] && [ ! -L /data/init.sh ] || fail 'Unexpected /data/init.sh.'
    if grep -Fq 'LX06_PANEL_BEGIN' /data/init.sh; then fail 'Existing panel boot hook.'; fi
fi
available=$(df -k /data | awk 'NR==2 {print $4}')
[ "${available:-0}" -ge 5200 ] || fail 'At least 5.2 MB of free space on /data is required.'
player_pid=$(ubus -t 2 call service list '{"name":"mediaplayer"}' | jsonfilter -e '@.mediaplayer.instances.instance1.pid')
[ -n "$player_pid" ] && [ -r "/proc/$player_pid/environ" ] || fail 'The original music service must be running.'
if tr '\000' '\n' < "/proc/$player_pid/environ" | grep -q '^ALSA_CONFIG_PATH='; then
    fail 'Existing audio routing customization detected.'
fi
if netstat -lnt 2>/dev/null | grep -q ':8086[[:space:]]'; then fail 'TCP port 8086 is already in use.'; fi
echo 'LX06 1.94.13 compatibility checks passed.'
