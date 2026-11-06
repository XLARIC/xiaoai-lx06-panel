#!/bin/sh
set -eu
export COPYFILE_DISABLE=1
cd "$(dirname "$0")/.."
go=${GO:-go}
zig=${ZIG:-zig}
target=arm-linux-gnueabihf.2.25
case "$("$go" version)" in *' go1.26.'*) ;; *) echo 'Go 1.26.x is required.' >&2; exit 1 ;; esac
[ "$("$zig" version)" = 0.15.2 ] || { echo 'Zig 0.15.2 is required.' >&2; exit 1; }
version=v0.1.0
name=xiaoai-lx06-panel-$version
mkdir -p build dist
work=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$work"' EXIT
bundle="$work/$name"
payload="$bundle/package"
mkdir -p "$payload/panel" "$payload/audio" "$payload/location" "$bundle/scripts"
export GOTOOLCHAIN=local CGO_ENABLED=0
GOOS=linux GOARCH=arm64 "$go" build -trimpath -buildvcs=false -ldflags='-s -w' -o "$payload/panel/lx06-panel" .
"$zig" cc -target "$target" -mcpu=cortex_a53 -O2 -s -Wall -Wextra -Werror \
    -fPIC -shared -fvisibility=hidden native/tap.c -o "$payload/audio/lx06_lg_sync.so" -lm
"$zig" cc -target "$target" -fPIC -shared -Wl,-soname,libasound.so.2 \
    native/alsa-link-stub.c -o "$work/libasound.so.2"
"$zig" cc -target "$target" -mcpu=cortex_a53 -O2 -s -Wall -Wextra -Werror \
    native/send.c "$work/libasound.so.2" -o "$payload/audio/lg-pcm-send"
"$zig" cc -target "$target" -mcpu=cortex_a53 -O2 -s -Wall -Wextra -Werror \
    -fPIC -shared location/native_location.c -o "$payload/location/native-location.so" -ldl -lpthread
cp panel/*.sh "$payload/panel/"
cp audio/*.sh audio/launch-sender "$payload/audio/"
cp location/*.sh "$payload/location/"
cp location/LICENSE "$payload/location/"

cp install.sh README.md README.en.md LICENSE "$bundle/"
cp scripts/device-*.sh "$bundle/scripts/"
cp -R licenses "$bundle/"
goroot=$("$go" env GOROOT)
cp "$goroot/LICENSE" "$bundle/licenses/GO-LICENSE"
cp "$goroot/PATENTS" "$bundle/licenses/GO-PATENTS"
for license in "$goroot"/src/vendor/golang.org/x/*/LICENSE; do
    component=$(basename "$(dirname "$license")")
    cp "$license" "$bundle/licenses/GO-X-$component-LICENSE"
done
chmod 700 "$payload"/panel/*.sh "$payload"/audio/*.sh "$payload"/audio/launch-sender "$payload"/location/*.sh
chmod 700 "$payload/panel/lx06-panel" "$payload/audio/lg-pcm-send"
chmod 755 "$bundle/install.sh"
(
    cd "$payload/audio"
    shasum -a 256 ./*.sh launch-sender lx06_lg_sync.so lg-pcm-send > package.sha256
)
(
    cd "$payload/location"
    shasum -a 256 native-location.so > module.sha256
)
(
    cd "$payload"
    shasum -a 256 panel/* audio/* location/* > package.sha256
    shasum -a 256 -c package.sha256 >/dev/null
)
tar -czf "$work/$name.tar.gz" -C "$work" "$name"
mv "$work/$name.tar.gz" "dist/$name.tar.gz"
(cd dist && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
printf 'Built %s\n' "dist/$name.tar.gz"
