#!/usr/bin/env bash
# Packs the build.sh build for this machine's architecture into the two Linux release files:
#   build/ompanion-linux-<x64|arm64>.flatpak   a single file `flatpak install` takes: the shell built again against the
#                                              GNOME runtime (com.edde746.ompanion.yml) with the build's core and page,
#                                              and release-tty
#   build/ompanion-linux-<x64|arm64>.zip       the build itself (build/linux-<arch>/), for Ubuntu 24.04 or a newer
#                                              system with GTK 4, WebKitGTK 6 and libsecret
#
#   shells/linux/flatpak/build-flatpak.sh
#
# Needs flatpak, flatpak-builder and zip, and the Flathub remote in the user installation, from which the runtime and
# SDK the manifest names are installed:
#
#   flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
app_id=com.edde746.ompanion
case "$(uname -m)" in
  x86_64) arch=amd64 name=x64 ;;
  aarch64) arch=arm64 name=arm64 ;;
  *) echo "build-flatpak.sh: no Linux build for $(uname -m)" >&2; exit 1 ;;
esac
build=$repo/build/linux-$arch
core=$repo/build/linux-work/$arch/core
if [ ! -x "$build/ompanion" ] || [ ! -f "$core/libompcore.h" ]; then
  echo "build-flatpak.sh: no build in $build: run shells/linux/build.sh $arch first" >&2
  exit 1
fi
version=$(cut -d+ -f1 "$repo/VERSION")
flatpak_file=$repo/build/ompanion-linux-$name.flatpak
zip_file=$repo/build/ompanion-linux-$name.zip

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/src/shells/linux" "$stage/core"
cp "$repo/VERSION" "$stage/src/"
cp "$repo/shells/linux/"{CMakeLists.txt,main.cpp,services.cpp,shell.h,ompanion.png} "$stage/src/shells/linux/"
cp "$build/libompcore.so" "$core/libompcore.h" "$stage/core/"
cp -R "$build/ui" "$stage/ui"
cp "$here/$app_id.yml" "$here/$app_id.desktop" "$here/release-tty.c" "$stage/"
sed "s|</component>|  <releases>\n    <release version=\"$version\" date=\"$(date -u +%F)\"/>\n  </releases>\n</component>|" \
  "$here/$app_id.metainfo.xml" >"$stage/$app_id.metainfo.xml"

flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse --force-clean \
  --state-dir="$stage/state" --repo="$stage/repo" "$stage/build" "$stage/$app_id.yml"
# The file names Flathub as the runtime's source, so installing it fetches the runtime from there.
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo "$stage/repo" "$flatpak_file" "$app_id"
# zip keeps the executable bits. smoke.sh leaves its logs in the build.
rm -f "$zip_file"
(cd "$build" && zip -qr "$zip_file" . -x 'smoke/*')
echo "$flatpak_file"
echo "$zip_file"
