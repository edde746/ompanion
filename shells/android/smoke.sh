#!/bin/sh
# Smoke-tests build/android/app-debug.apk (build.sh) on the Pixel 7 on air.local through devpool, on the Galaxy Z
# Fold3 when devpool reports the Pixel out of reach (docs/contracts/bridge.md, Smoke runs). smoke-device.sh does the
# device work on studio.local under the lease. Prints the SMOKE lines and devpool's RESULT line (also in
# build/android/smoke.log), copies the screenshot to build/android/smoke.png, and exits 0 when every check passed.
#   smoke.sh [--import <seed apk>]
# --import: the Flutter import (smoke check `flutter-import`): the phone first runs the Flutter seed
# (harness/flutter-seed/build.sh android) until it prints SEEDED, then the app is installed over it and checks what
# it imported against harness/flutter-seed/expected.json, and that the Flutter app's files are gone or renamed.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out="$repo/build/android"
stage=ompanion-web/Android-smoke
pool='export PATH=$HOME/.local/bin:/opt/homebrew/bin:$PATH DEVPOOL_AGENT=ompanion-web-Android;'
seed=
case "${1:-}" in
  "") ;;
  --import) [ $# -eq 2 ] || { echo "usage: $0 [--import <seed apk>]" >&2; exit 2; }; seed=$2 ;;
  *) echo "usage: $0 [--import <seed apk>]" >&2; exit 2 ;;
esac

pixel=$(ssh studio.local "$pool devpool status device:pixel" | sed -n '/^  device:pixel@/p')
case "$pixel" in
  "" | *" — "*) device=fold ;;
  *) device=pixel ;;
esac
ssh studio.local "rm -rf $stage && mkdir -p $stage"
rsync -a "$out/app-debug.apk" "$here/smoke-device.sh" "studio.local:$stage/"
mode=
if [ -n "$seed" ]; then
  rsync -a "$seed" "studio.local:$stage/seed.apk"
  rsync -a "$repo/harness/flutter-seed/expected.json" "studio.local:$stage/"
  mode=import
fi
ssh studio.local "$pool cd $stage && devpool run --need device:$device --what 'ompanion web: Android smoke $mode' -- sh smoke-device.sh $mode" 2>&1 |
  tee "$out/smoke.log"
if ssh studio.local "test -f $stage/smoke.png"; then
  rsync -a "studio.local:$stage/smoke.png" "$out/smoke.png"
  echo "screenshot: $out/smoke.png"
fi
ssh studio.local "rm -rf $stage"
grep -q '^RESULT: PASS' "$out/smoke.log"
