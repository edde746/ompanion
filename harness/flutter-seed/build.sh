#!/bin/sh
# Builds the Flutter seed (README.md) from the Flutter app at commit 359d920 with its store identity
# (com.edde746.ompanion), in a temporary copy outside the repo, and prints the built artifact's path.
#   build.sh <macos|ios-simulator|android|linux|windows> [--out <dir>]
# --out defaults to $TMPDIR/flutter-seed/<platform>. Flutter is /Users/edde/Documents/flutter/bin/flutter where it
# exists, else `flutter` on PATH (CI runners, Docker). macOS and iOS-simulator builds are signed with this Mac's
# 'Apple Development' identity (team G88U5B5783), as the web app that later reads their keychain items must be.
# macOS builds in debug mode, which leaves out Sparkle (AppDelegate.swift): a release seed would check the update feed.
# Android uses the debug build type and key: `run-as` needs a debuggable app, and the web APK built with the same key
# installs over it. linux and windows run on their own hosts (README.md lists the packages they need).
set -eu

commit=359d920
team=G88U5B5783
usage() {
  echo "usage: build.sh <macos|ios-simulator|android|linux|windows> [--out <dir>]" >&2
  exit 2
}

platform=${1:-}
case $platform in
  macos | ios-simulator | android | linux | windows) shift ;;
  *) usage ;;
esac
tmp=${TMPDIR:-/tmp}
tmp=${tmp%/}
out=$tmp/flutter-seed/$platform
while [ $# -gt 0 ]; do
  case $1 in
    --out) [ $# -ge 2 ] || usage; out=$2; shift 2 ;;
    *) usage ;;
  esac
done

here=$(cd "$(dirname "$0")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
flutter=/Users/edde/Documents/flutter/bin/flutter
[ -x "$flutter" ] || flutter=flutter

src=$tmp/flutter-seed-src/$platform
rm -rf "$src"
mkdir -p "$src"
git -C "$repo" archive "$commit" | tar -x -C "$src"
cp "$here/main_seed.dart" "$here/seed_data.dart" "$src/lib/"
# The app bundles the companion script (built by scripts/build_companion.sh, not committed); the seed never runs it.
mkdir -p "$src/assets/companion"
echo "// The Flutter seed does not use the companion." > "$src/assets/companion/ompx.js"
cd "$src"
"$flutter" pub get --enforce-lockfile

if [ "$platform" = macos ] || [ "$platform" = ios-simulator ]; then
  identity=$(security find-identity -v -p codesigning |
    sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p' | head -n 1)
  [ -n "$identity" ] || { echo "build.sh: no 'Apple Development' signing identity in this Mac's keychain" >&2; exit 1; }
  # flutter passes FLUTTER_XCODE_* to xcodebuild as build settings (they override the project's ad-hoc signing).
  export FLUTTER_XCODE_CODE_SIGN_IDENTITY="$identity" FLUTTER_XCODE_DEVELOPMENT_TEAM="$team" \
    FLUTTER_XCODE_CODE_SIGN_STYLE=Manual FLUTTER_XCODE_PROVISIONING_PROFILE_SPECIFIER=
fi

case $platform in
  macos)
    "$flutter" build macos --debug -t lib/main_seed.dart
    built=build/macos/Build/Products/Debug/ompanion.app
    ;;
  ios-simulator)
    "$flutter" build ios --simulator --debug -t lib/main_seed.dart
    built=build/ios/iphonesimulator/Runner.app
    # Xcode signs simulator apps ad hoc whatever the identity; the keychain groups come from the binary's simulated
    # entitlements (G88U5B5783.com.edde746.ompanion), which stay as they are.
    codesign --force --deep --timestamp=none --sign "$identity" "$built"
    ;;
  android)
    "$flutter" build apk --debug -t lib/main_seed.dart
    built=build/app/outputs/flutter-apk/app-debug.apk
    ;;
  linux)
    "$flutter" build linux --release -t lib/main_seed.dart
    built=$(ls -d build/linux/*/release/bundle)
    ;;
  windows)
    "$flutter" build windows --release -t lib/main_seed.dart
    built=build/windows/x64/runner/Release
    ;;
esac

rm -rf "$out"
mkdir -p "$out"
mv "$built" "$out/"
cd "$tmp"
rm -rf "$src"
echo "$out/$(basename "$built")"
