#!/bin/sh
# Screenshots of build.sh's apps on studio.local through devpool: the iOS simulator app on an iPhone 17 (iOS 27.0), or
# with --macos the macOS app's window. For each <query> the shell shows index.html?<query> (OMPCORE_PAGE_QUERY: a
# gallery page of a dev build; a query the page does not know shows the app) and runs --script's JavaScript in it
# once it loaded (OMPCORE_PAGE_SCRIPT: a user's steps, such as a click). The picture is taken <seconds> after the
# launch (default 3): the simulator's screen, or on macOS the shell's own picture of its window (OMPCORE_SNAPSHOT:
# over SSH screencapture gets no picture), which the page asks for by requesting core.exit. Pictures go to
# build/apple/shots/<query>.png (macOS: macos-<query>.png), every character of the query outside
# [A-Za-z0-9] made `_`.
#   shot.sh [--macos] [--wait <seconds>] [--dark] [--script <javascript>] <query>...
# --dark sets the simulator's appearance; the macOS app follows the Mac's. Like smoke.sh, a run first checks that none
# of the app's data is on studio or the simulator and removes all it made afterwards (studio-app.sh).
# Inside the lease the script runs itself on studio, from a staging folder it removes afterwards:
# shot.sh --on-studio <ios|macos> <seconds> <light|dark> <javascript> <query>...
set -eu

name() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

if [ "${1:-}" = --on-studio ]; then
  . ./studio-app.sh
  platform=$2 wait=$3 appearance=$4 script=$5
  shift 5
  mkdir -p shots
  if [ "$platform" = macos ]; then
    claim_macos "$PWD/macos/ompanion.app"
    ms=$(awk -v s="$wait" 'BEGIN { printf "%d", s * 1000 }')
    # The page's own request: an id far above the ones it counts up from 1.
    exit_request="setTimeout(function () { window.webkit.messageHandlers.core.postMessage(JSON.stringify({ id: 2147483647, method: 'core.exit', params: { code: 0 } })); }, $ms);"
    for query; do
      file=$PWD/shots/macos-$(name "$query").png
      # Through LaunchServices, as a user's launch (smoke.sh); `open -W` returns when the app exited.
      open -n -W -F --env "OMPCORE_PAGE_QUERY=$query" --env "OMPCORE_PAGE_SCRIPT=$script;$exit_request" \
        --env "OMPCORE_SNAPSHOT=$file" macos/ompanion.app &
      app=$!
      deadline=$(($(date +%s) + 60))
      while kill -0 "$app" 2> /dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "shot: the app did not exit within 60 s" >&2
          pkill -f "$PWD/macos/ompanion.app/Contents/MacOS/ompanion" || true
          break
        fi
        sleep 0.2
      done
      wait "$app" || true
      [ -f "$file" ] || { echo "shot: no picture for $query" >&2; exit 1; }
    done
    exit
  fi
  udid=$DEVPOOL_SIM_UDID
  xcrun simctl bootstatus "$udid" -b > /dev/null
  claim_ios
  xcrun simctl ui "$udid" appearance "$appearance"
  xcrun simctl install "$udid" ios-simulator/ompanion.app
  [ -z "$script" ] || export SIMCTL_CHILD_OMPCORE_PAGE_SCRIPT="$script"
  for query; do
    SIMCTL_CHILD_OMPCORE_PAGE_QUERY=$query xcrun simctl launch --terminate-running-process "$udid" "$id" > /dev/null
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "shots/$(name "$query").png" > /dev/null 2>&1
    xcrun simctl terminate "$udid" "$id"
  done
  exit
fi

platform=ios wait=3 appearance=light script=
while [ $# -gt 0 ]; do
  case $1 in
    --macos) platform=macos; shift ;;
    --wait) wait=$2; shift 2 ;;
    --dark) appearance=dark; shift ;;
    --script) script=$2; shift 2 ;;
    -*) echo "usage: $0 [--macos] [--wait <seconds>] [--dark] [--script <javascript>] <query>..." >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: $0 [--macos] [--wait <seconds>] [--dark] [--script <javascript>] <query>..." >&2; exit 2; }
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
here=$(cd "$(dirname "$0")" && pwd)
out=$(cd "$here/../../build/apple" && pwd)
remote=studio.local
if [ "$platform" = macos ]; then
  app=macos needs="--need host:studio --need pool:studio-gui" prefix=macos-
else
  app=ios-simulator needs="--need host:studio --need 'ios-sim:iPhone-17 machine=studio runtime=27.0'" prefix=
fi
staging=$(ssh "$remote" 'mkdir -p ompanion-web && mktemp -d ompanion-web/apple-shot.XXXXXX')
trap 'ssh "$remote" rm -rf "$staging"' EXIT
rsync -a "$out/$app" "$here/shot.sh" "$here/studio-app.sh" "$remote:$staging/"
queries=
for query; do
  queries="$queries $(quote "$query")"
done
status=0
ssh "$remote" "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:\$PATH DEVPOOL_AGENT=ompanion-apple
  cd $staging && devpool run $needs --what 'ompanion: Apple shell screenshots ($platform)' \
    -- ./shot.sh --on-studio $platform $wait $appearance $(quote "$script") $queries" ||
  status=$?
mkdir -p "$out/shots"
rsync -a "$remote:$staging/shots/" "$out/shots/"
for query; do
  echo "$out/shots/$prefix$(name "$query").png"
done
exit $status
