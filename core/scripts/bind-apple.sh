#!/bin/sh
# Builds build/core/apple/Ompcore.xcframework (iOS, iOS simulator, macOS) from core/ompcore with gomobile
# (`go install golang.org/x/mobile/cmd/gomobile@latest golang.org/x/mobile/cmd/gobind@latest`), linking the root
# VERSION in as core.Version.
set -eu
core=$(cd "$(dirname "$0")/.." && pwd)
out="$core/../build/core/apple"
version=$(tr -d '[:space:]' < "$core/../VERSION")
export PATH="$(go env GOPATH)/bin:$PATH"
# gomobile has no macOS version flag; without this the macOS slice requires the SDK's macOS (iOS uses -iosversion).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
mkdir -p "$out"
cd "$core"
gomobile bind -target=ios,iossimulator,macos -iosversion=16 -ldflags="-X ompanion.app/core.Version=$version" \
  -o "$out/Ompcore.xcframework" ./ompcore
echo "$out/Ompcore.xcframework"
