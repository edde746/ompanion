#!/bin/sh
# Builds the companion extension and copies the bundle to ui/companion/ompx.js, which the UI build bundles
# (ui/src/app/sessions/companion_asset.ts) and the e2e tests load. It is a gitignored build artifact the UI build needs.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root/companion"
if [ ! -d node_modules ]; then
  bun install --frozen-lockfile
fi
bun run build
mkdir -p "$root/ui/companion"
cp dist/ompx.js "$root/ui/companion/ompx.js"
printf 'ui/companion/ompx.js: %s bytes\n' "$(wc -c <"$root/ui/companion/ompx.js" | tr -d ' ')"
