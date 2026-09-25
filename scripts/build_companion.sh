#!/bin/sh
# Builds the companion extension and copies the bundle into the app's assets, where `flutter build`,
# `flutter run` and `flutter test` pick it up. assets/companion/ompx.js is a gitignored build artifact:
# without it pubspec.yaml names a missing asset and every Flutter build fails.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/companion"
if [ ! -d node_modules ]; then
  bun install --frozen-lockfile
fi
bun run build
mkdir -p "$root/assets/companion"
cp dist/ompx.js "$root/assets/companion/ompx.js"
printf 'assets/companion/ompx.js: %s bytes\n' "$(wc -c <"$root/assets/companion/ompx.js" | tr -d ' ')"
