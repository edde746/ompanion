#!/bin/sh
# Builds the Android app into build/android/:
#   build.sh            app-debug.apk (every ABI) around a copy of ui/dist (build/android/ui-debug/), which must be
#                       built first
#   build.sh --release  app-release-universal.apk (every ABI) and app-release-arm64.apk (arm64-v8a) around a UI built
#                       with VITE_OMPANION_CHANNEL=direct, and app-release.aab (Google Play) around one built with
#                       `play` (build/android/ui-<channel>/). R8-minified, signed with the upload key of
#                       shells/android/key.properties (storeFile relative to shells/android/app), else the debug key.
#   --core              binds the core again (core/scripts/bind-android.sh); without it only when its aar is missing
# Every page gets the licences of the core's Go modules and of the Maven libraries (core/cmd/licenses; the libraries
# from app/build.gradle.kts's `licenseInputs`, the notices some lack from licenses/).
# Version: VERSION. Needs bun (ui/node_modules installed) for --release, JDK 21 ($JAVA_HOME, else macOS's
# `java_home -v 21`), the Android SDK ($ANDROID_HOME, default ~/Library/Android/sdk), Go, and for the core gomobile
# and an NDK.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out="$repo/build/android"
core=
release=
for arg; do
  case $arg in
    --core) core=1 ;;
    --release) release=1 ;;
    *) echo "usage: $0 [--core] [--release]" >&2; exit 2 ;;
  esac
done
if [ -n "$core" ] || [ ! -f "$repo/build/core/android/ompcore.aar" ]; then
  "$repo/core/scripts/bind-android.sh"
fi
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME=$(/usr/libexec/java_home -v 21)
  export JAVA_HOME
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$out"
apks="$here/app/build/outputs/apk"

(cd "$here" && ./gradlew --quiet licenseInputs)
licenses() {
  (cd "$repo/core" && go run ./cmd/licenses -ui "$1" -target android -maven "$out/maven-libraries.tsv" \
    -texts "$here/licenses")
}

if [ -z "$release" ]; then
  [ -f "$repo/ui/dist/index.html" ] || { echo "build.sh: $repo/ui/dist/index.html is missing: build the UI first" >&2; exit 1; }
  rm -rf "$out/ui-debug"
  cp -R "$repo/ui/dist" "$out/ui-debug"
  licenses "$out/ui-debug"
  (cd "$here" && ./gradlew --quiet assembleDebug "-Pui=$out/ui-debug")
  cp "$apks/debug/app-universal-debug.apk" "$out/app-debug.apk"
  ls -l "$out/app-debug.apk"
  exit 0
fi

# The page for one build channel (ui/src/app/build_channel.ts), in build/android/ui-<channel>/.
ui() {
  (cd "$repo/ui" && VITE_OMPANION_CHANNEL=$1 bun x vite build --logLevel warn --outDir "$out/ui-$1" --emptyOutDir)
  licenses "$out/ui-$1"
}
ui direct
(cd "$here" && ./gradlew --quiet assembleRelease "-Pui=$out/ui-direct")
cp "$apks/release/app-universal-release.apk" "$out/app-release-universal.apk"
cp "$apks/release/app-arm64-v8a-release.apk" "$out/app-release-arm64.apk"
ui play
(cd "$here" && ./gradlew --quiet bundleRelease "-Pui=$out/ui-play")
cp "$here/app/build/outputs/bundle/release/app-release.aab" "$out/app-release.aab"
ls -l "$out/app-release-universal.apk" "$out/app-release-arm64.apk" "$out/app-release.aab"
