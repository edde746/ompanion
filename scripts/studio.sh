#!/bin/sh
# Runs a command in a copy of the repo on studio.local inside a devpool lease. Nothing runs on the developer's Mac:
# every test suite, app run, smoke run and bench goes through here or through a shell's own smoke script.
#
#   scripts/studio.sh <stage> [--need <need>]... [--what <text>] [--fetch <path>]... -- <command...>
#
# <stage> names the staging folder, ~/ompanion-web/<stage>/repo on studio; use your agent name so parallel runs do
# not share one. The copy holds ui/ (with the app's strings and the companion bundle, ui/companion/ompx.js), core/,
# shells/, harness/, bench/, assets/, scripts/, store/screenshots/, store/review-demo/ (without its .env) and VERSION,
# without build outputs, node_modules and Gradle caches, plus the tested omp's darwin-arm64 binary
# (.tools/omp/<harness/omp-version>/), at the same paths as in this checkout; rsync updates it on
# every run. <command> runs from the copy's root, after `bun install` in ui/, with bun (~/ompanion-web/tools), go and
# Homebrew on PATH. Without --need the lease is `host:studio`. Each --fetch <path> (relative to the root, e.g.
# build/shots/) is copied back into this checkout after the command, whether it passed or not. Exits with the
# command's status.
#
# After the run: `scripts/studio.sh <stage> --clean` removes the staging folder.
set -eu

[ $# -ge 1 ] || { echo "usage: studio.sh <stage> [--need <need>]... [--what <text>] -- <command...>" >&2; exit 2; }
stage=$1
shift
remote=studio.local
base="ompanion-web/$stage"

if [ "${1:-}" = "--clean" ]; then
  ssh -o BatchMode=yes "$remote" "rm -rf \"\$HOME/$base\""
  exit 0
fi

needs=
fetch=
what="ompanion web: $stage"
while [ $# -gt 0 ]; do
  case $1 in
    --need) needs="$needs --need '$2'"; shift 2 ;;
    --what) what=$2; shift 2 ;;
    --fetch) fetch="$fetch $2"; shift 2 ;;
    --) shift; break ;;
    *) echo "studio.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "studio.sh: no command after --" >&2; exit 2; }
[ -n "$needs" ] || needs="--need host:studio"

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
version=${OMP_VERSION:-$(tr -d '[:space:]' < "$repo/harness/omp-version")}
omp="$repo/.tools/omp/$version/omp-darwin-arm64"
[ -x "$omp" ] || { echo "studio.sh: $omp is missing; run scripts/fetch_omp.sh darwin-arm64" >&2; exit 1; }
[ -f "$repo/ui/companion/ompx.js" ] ||
  { echo "studio.sh: ui/companion/ompx.js is missing; run scripts/build_companion.sh" >&2; exit 1; }

ssh -o BatchMode=yes "$remote" "mkdir -p \"\$HOME/$base/repo/.tools/omp/$version\""
rsync -a --delete \
  --exclude /ui/dist/ --exclude node_modules/ --exclude /shells/android/.gradle/ --exclude /shells/android/.kotlin/ \
  --exclude '/shells/android/**/build/' --exclude /shells/apple/DerivedData/ --exclude '/shells/apple/*.xcodeproj/' \
  --exclude /store/review-demo/.env \
  --include /ui/ --include /core/ --include /shells/ --include /harness/ --include /bench/ --include /assets/ \
  --include /scripts/ \
  --include /VERSION --include /store/ --include '/store/screenshots/***' --include '/store/review-demo/***' \
  --exclude '/store/*' --exclude '/*' \
  "$repo/" "$remote:$base/repo/"
rsync -a "$omp" "$remote:$base/repo/.tools/omp/$version/"

# The command is quoted for the remote shell once, here.
cmd=
for arg in "$@"; do
  cmd="$cmd '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'"
done

status=0
ssh -o BatchMode=yes "$remote" "export PATH=\$HOME/ompanion-web/tools:\$HOME/.local/bin:\$HOME/go/bin:/opt/homebrew/bin:\$PATH
  export DEVPOOL_AGENT='ompanion-web-$stage' OMP_VERSION='$version'
  cd \"\$HOME/$base/repo\" && devpool run $needs --what '$what' -- sh -c 'cd ui && bun install --silent && cd .. && exec \"\$@\"' sh $cmd" ||
  status=$?
for path in $fetch; do
  path=${path%/}
  mkdir -p "$repo/$(dirname "$path")"
  rsync -a "$remote:$base/repo/$path" "$repo/$(dirname "$path")/" ||
    echo "studio.sh: could not fetch $path" >&2
done
exit "$status"
