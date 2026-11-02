#!/bin/sh
# Builds the startup floor (docs/research/web-ui/startup.md): the shells as built now, each serving ../startup-floor/
# (a static page and the timing report, no app) instead of ui/dist, into build/bench/startup/floor/: macos/ompanion.app
# and ios/ompanion.app (ad-hoc signed again), web.apk (from app-release-arm64.apk, signed again with the debug key).
# startup-measure.sh macos then measures it as `web-floor`; ios and android take it as their app argument.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
build=$(cd "$here/../../build" && pwd)
page=$here/../startup-floor
out=$build/bench/startup/floor
tools=${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools/$(ls "${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools" | sort -V | tail -n 1)
rm -rf "$out"
mkdir -p "$out/macos" "$out/ios"

ditto "$build/apple/macos/ompanion.app" "$out/macos/ompanion.app"
rm -rf "$out/macos/ompanion.app/Contents/Resources/ui"
mkdir "$out/macos/ompanion.app/Contents/Resources/ui"
cp "$page/index.html" "$page/floor.js" "$out/macos/ompanion.app/Contents/Resources/ui/"
codesign --force --sign - "$out/macos/ompanion.app"

ditto "$build/apple/ios-simulator/ompanion.app" "$out/ios/ompanion.app"
rm -rf "$out/ios/ompanion.app/ui"
mkdir "$out/ios/ompanion.app/ui"
cp "$page/index.html" "$page/floor.js" "$out/ios/ompanion.app/ui/"
codesign --force --sign - "$out/ios/ompanion.app"

work=$(mktemp -d /tmp/ompanion-floor-apk.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp "$build/android/app-release-arm64.apk" "$work/unsigned.apk"
zip -q -d "$work/unsigned.apk" 'assets/ui/*' 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/MANIFEST.MF'
mkdir -p "$work/files/assets/ui"
cp "$page/index.html" "$page/floor.js" "$work/files/assets/ui/"
(cd "$work/files" && zip -q -0 -r "$work/unsigned.apk" assets)
"$tools/zipalign" -f -p 4 "$work/unsigned.apk" "$work/aligned.apk"
"$tools/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --ks-key-alias androiddebugkey \
  --key-pass pass:android --out "$out/web.apk" "$work/aligned.apk"
ls -d "$out/macos/ompanion.app" "$out/ios/ompanion.app" "$out/web.apk"
