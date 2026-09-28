#!/usr/bin/env bash
# Packs the bundle of `flutter build linux --release` into build/linux/ompanion-linux-<arch>.flatpak, a single file
# that `flatpak install` takes. The architecture is this machine's, as it is for the Flutter build.
#
#   linux/build-flatpak.sh
#
# Needs flatpak, flatpak-builder and the Flathub remote in the user installation; the runtime and SDK the manifest
# (linux/flatpak/) names are installed from there:
#
#   flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app_id=com.edde746.ompanion
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "no Flutter Linux build for $(uname -m)" >&2; exit 1 ;;
esac
bundle=$root/build/linux/$arch/release/bundle
if [ ! -x "$bundle/ompanion" ] || [ ! -f "$bundle/lib/libapp.so" ]; then
  echo "no release bundle in $bundle: run flutter build linux --release first" >&2
  exit 1
fi
version=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "$root/pubspec.yaml")
output=$root/build/linux/ompanion-linux-$arch.flatpak

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$root/linux/flatpak/$app_id.yml" "$root/linux/flatpak/$app_id.desktop" "$root/linux/flatpak/release-tty.c" \
  "$root/linux/ompanion.png" "$stage/"
cp -a "$bundle" "$stage/bundle"
sed "s|</component>|  <releases>\n    <release version=\"$version\" date=\"$(date -u +%F)\"/>\n  </releases>\n</component>|" \
  "$root/linux/flatpak/$app_id.metainfo.xml" >"$stage/$app_id.metainfo.xml"

flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse --force-clean \
  --state-dir="$stage/state" --repo="$stage/repo" "$stage/build" "$stage/$app_id.yml"
# The file names Flathub as the runtime's source, so installing it fetches the runtime from there.
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo "$stage/repo" "$output" "$app_id"
echo "$output"
