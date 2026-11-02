#!/bin/sh
# Captures the store screenshots on studio.local through devpool and composes the store images on this Mac.
#
#   store/screenshots/capture.sh [--out <dir>] [--raw <dir>] [--stage <name>] [--no-compose] <class>...
#
# Classes: ios-phone (iPhone 17 Pro Max simulator), ios-ipad (iPad Pro 13-inch (M5) simulator), play-phone (the
# Pixel 7 devpool lends), macos (the macOS app's window; raw captures only, no store takes them). ms-desktop has no
# machine to run on now (README.md, "The Windows capture").
#
# Needs the builds: build/apple/ios-simulator/ompanion.app and build/apple/macos/ompanion.app (shells/apple/build.sh),
# build/android/app-debug.apk (shells/android/build.sh, debuggable: the harness reaches its WebView over DevTools), the
# companion (scripts/build_companion.sh) and the tested omp (scripts/fetch_omp.sh darwin-arm64), and for composing
# `uv` and `rsvg-convert` (brew install uv librsvg). Each class runs in its own devpool lease
# (scripts/studio.sh <stage>, default store-shots), through capture.ts there; the raw captures come back to
# <raw>/<class>/ (default build/store-shots/raw), and compose.py writes the store images under <out> in the
# repository's layout (store/fastlane/…, store/microsoft/screenshots/; default: this checkout, over the committed
# ones). `scripts/studio.sh <stage> --clean` removes the studio copy afterwards.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=$repo raw=$repo/build/store-shots/raw stage=store-shots compose=yes classes=
while [ $# -gt 0 ]; do
  case $1 in
    --out) mkdir -p "$2"; out=$(cd "$2" && pwd); shift 2 ;;
    --raw) mkdir -p "$2"; raw=$(cd "$2" && pwd); shift 2 ;;
    --stage) stage=$2; shift 2 ;;
    --no-compose) compose=no; shift ;;
    ios-phone | ios-ipad | play-phone | macos) classes="$classes $1"; shift ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done
[ -n "$classes" ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# The apps go into the studio copy beside the repository's files, where studio.sh's rsync leaves them alone.
apps=build/store-shots/apps
ssh -o BatchMode=yes studio.local "mkdir -p ompanion-web/$stage/repo/$apps"
status=0
for class in $classes; do
  case $class in
    ios-*) app=build/apple/ios-simulator/ompanion.app needs="--need host:studio" ;;
    macos) app=build/apple/macos/ompanion.app needs="--need host:studio --need pool:studio-gui" ;;
    play-phone) app=build/android/app-debug.apk needs="--need host:studio --need device:pixel" ;;
  esac
  [ -e "$repo/$app" ] || { echo "capture.sh: $app is missing; build it first" >&2; exit 1; }
  rsync -a --delete "$repo/$app" "studio.local:ompanion-web/$stage/repo/$apps/$class/"
  staged=$apps/$class/$(basename "$app")
  if [ "$class" = macos ]; then
    # shells/apple/studio-app.sh: stops when the store app's data is on studio, and removes all the run made.
    command=". shells/apple/studio-app.sh && claim_macos \"\$PWD/$staged\" && bun store/screenshots/capture.ts macos --app $staged --out build/store-shots/raw"
  else
    command="bun store/screenshots/capture.ts $class --app $staged --out build/store-shots/raw"
  fi
  # The fetch adds to what is here; a run's raw captures are only its own.
  rm -rf "$repo/build/store-shots/raw/$class"
  # shellcheck disable=SC2086 # $needs is several flags
  "$repo/scripts/studio.sh" "$stage" $needs --what "ompanion: store screenshots ($class)" \
    --fetch "build/store-shots/raw/$class" -- sh -c "$command" || status=$?
  mkdir -p "$raw"
  [ "$raw" = "$repo/build/store-shots/raw" ] || rsync -a --delete "$repo/build/store-shots/raw/$class" "$raw/"
done

if [ "$compose" = yes ]; then
  only=
  for class in $classes; do [ "$class" = macos ] || only="$only --only $class"; done
  # shellcheck disable=SC2086 # $only is several flags
  [ -z "$only" ] || uv run --quiet --with pillow python3 "$here/compose.py" --raw "$raw" --out "$out" $only
fi
exit "$status"
