#!/bin/sh
# One image of every store image that was composed, for a quick review.
#
#   store/screenshots/contact-sheet.sh [out.png] [class]
#
# [class] is a suffix to keep, e.g. iphone69, ipad13, or a directory name (phoneScreenshots, sevenInch, tenInch).
#
# Needs ImageMagick (`brew install imagemagick`). Tiles the composed files from the fastlane directories and
# `store/app-icon-1024.png`, top-left to bottom-right, with each file's name under it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-/tmp/ompanion-store/StoreShots/contact-sheet.png}
only=${2:-}

files=$(find \
  "$repo/ios/fastlane/screenshots" \
  "$repo/android/fastlane/metadata/android/en-US/images" \
  "$repo/store/app-icon-1024.png" \
  -name '*.png' 2>/dev/null | sort)
if [ -n "$only" ]; then
  files=$(printf '%s\n' "$files" | grep -E "$only" || true)
  [ -n "$files" ] || { echo "nothing matches $only" >&2; exit 1; }
fi

[ -n "$files" ] || { echo "nothing composed yet: run store/screenshots/capture.sh or compose.py first" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
# shellcheck disable=SC2086
magick montage $files -label '%f' -tile 4x -geometry 420x420+12+12 -background '#121214' -fill '#f6f6f8' \
  -font /System/Library/Fonts/SFNSMono.ttf -pointsize 14 "$out"
echo "$out"
