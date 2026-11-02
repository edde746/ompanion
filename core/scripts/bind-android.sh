#!/bin/sh
# Builds build/core/android/ompcore.aar (Java package `ompcore`, class `Ompcore`) from core/ompcore with
# gomobile, linking the root VERSION in as core.Version. Uses $ANDROID_HOME (default ~/Library/Android/sdk) and
# $ANDROID_NDK_HOME (default: its newest NDK).
set -eu
core=$(cd "$(dirname "$0")/.." && pwd)
out="$core/../build/core/android"
version=$(tr -d '[:space:]' < "$core/../VERSION")
export PATH="$(go env GOPATH)/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$(ls "$ANDROID_HOME/ndk" | sort -V | tail -n 1)"
fi
export ANDROID_NDK_HOME
mkdir -p "$out"
cd "$core"
gomobile bind -target=android -androidapi=24 -ldflags="-X ompanion.app/core.Version=$version" \
  -o "$out/ompcore.aar" ./ompcore
echo "$out/ompcore.aar"
