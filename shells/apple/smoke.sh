#!/bin/sh
# Runs the smoke checks (docs/contracts/bridge.md, Smoke runs) of build.sh's products on studio.local through devpool:
# macOS in the GUI pool, iOS on an iPhone 17 simulator (iOS 27.0). Prints each run's SMOKE lines, the shell's timing
# line and the time from launch to the info line, copies its logs and pictures to build/apple/smoke/<platform>/, and
# exits 0 only when every check of every platform passed. Pictures: the shell's own when the page asks to exit
# (OMPCORE_SNAPSHOT: over SSH screencapture gets no picture), window.png on macOS (the page with the title bar's
# traffic lights drawn over it) and page.png on iOS; screen.png is the simulator's screen at SMOKE-DONE.
#   smoke.sh [--seed <dir>] [macos] [ios]   both platforms by default
# --seed runs the Flutter import (the check flutter-import): <dir> holds harness/flutter-seed/build.sh's builds,
# macos/ompanion.app and ios-simulator/Runner.app. The Flutter app seeds its data first, the app imports it with
# OMPCORE_EXPECT_IMPORT=harness/flutter-seed/expected.json, and the run lists what is left of the Flutter app's data.
# The macOS app must then be signed by the seed's identity, or the login keychain asks before it reads the Flutter
# app's items: scripts/sign_app.sh "Apple Development: …" build/apple/macos/ompanion.app
# shells/apple/Entitlements/macOS.entitlements.
# On macOS the check paths runs too: Harness/PathsHarness.swift, a UI test run next to the app, copies files, chooses
# them in the open panels and drags them from Finder onto the window as the check asks.
# The app is the store app's identity: each run first checks that none of its data is on studio or the simulator,
# stops if there is, and removes all it made afterwards (studio-app.sh).
# Inside the lease the script runs itself on studio, from its staging folder: smoke.sh --on-studio <platform> [seed].
set -eu

now() { date +%s.%N; }

# watch <log> <pid> <app pid>: polls <log> until <pid> ends, at most 3 minutes: notes when the info line shows up in
# info_at, and with <app pid> set, stops that process at SMOKE-DONE for the screenshot, which core.exit would beat.
watch() {
  info_at= done= deadline=$(($(date +%s) + 180))
  while kill -0 "$2" 2> /dev/null; do
    if [ -z "$info_at" ] && grep -q '"check":"info"' "$1" 2> /dev/null; then
      info_at=$(now)
    fi
    if [ -n "$3" ] && [ -z "$done" ] && grep -q 'SMOKE-DONE' "$1" 2> /dev/null; then
      done=1
      kill -STOP "$3"
      xcrun simctl io "$DEVPOOL_SIM_UDID" screenshot "$run/screen.png" > "$run/screenshot.log" 2>&1 ||
        echo "smoke: simctl io screenshot failed: $(cat "$run/screenshot.log")" >&2
      kill -CONT "$3"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "smoke: no exit after 3 minutes; killing $2" >&2
      kill "$2"
      return 1
    fi
    sleep 0.01
  done
}

# report <log> <exit status>: prints the SMOKE lines and the launch-to-info time; fails unless every check passed.
report() {
  lines=$(tr -d '\r' < "$1" | grep '^SMOKE\|^shell timing' || true)
  echo "$lines"
  # The page's own clock when it has the info answer (epochMs), else when the poll above saw the line.
  epoch=$(echo "$lines" | sed -n 's/^SMOKE .*"check": *"info".*"epochMs": *\([0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$epoch" ]; then
    awk -v a="$start" -v b="$epoch" 'BEGIN { printf "launch to info: %d ms (page clock)\n", b - a * 1000 }'
    if [ -n "${pid_at:-}" ]; then
      awk -v a="$pid_at" -v b="$epoch" 'BEGIN { printf "app process seen to info: %d ms\n", b - a * 1000 }'
    fi
  elif [ -n "$info_at" ]; then
    awk -v a="$start" -v b="$info_at" 'BEGIN { printf "launch to info: %d ms (log poll)\n", (b - a) * 1000 }'
  fi
  passed=$(echo "$lines" | sed -n 's/^SMOKE-DONE .*"passed": *\([0-9]*\).*/\1/p')
  total=$(echo "$lines" | sed -n 's/^SMOKE-DONE .*"total": *\([0-9]*\).*/\1/p')
  echo "exit status: $2"
  [ -n "$total" ] && [ "$passed" = "$total" ] && [ "$2" = 0 ]
}

# seeded <file>: the Flutter seed's result line in <file>; fails unless it is SEEDED.
seeded() {
  line=$(tr -d '\r' < "$1" | grep -E '^(SEEDED|SEED-FAILED) ' | tail -n 1 || true)
  echo "seed: ${line:-no result line in $1}"
  case $line in SEEDED*) ;; *) return 1 ;; esac
}

on_studio_macos() {
  claim_macos "$PWD/macos/ompanion.app" ${seed:+"$PWD/seed/macos/ompanion.app"}
  # Through LaunchServices, as a user's launch: the app joins the logged-in user's session, whose login keychain is
  # open to it (an app started from the SSH session gets errSecInteractionNotAllowed). `open -W` waits for the app but
  # does not pass its exit status on: SMOKE-DONE decides.
  expect=
  if [ -n "$seed" ]; then
    open -n -W -F --stdout "$run/seed.txt" --stderr "$run/seed-stderr.txt" seed/macos/ompanion.app
    seeded "$run/seed.txt"
    expect="--env OMPCORE_EXPECT_IMPORT=$PWD/expected.json"
  fi
  # The paths check's files, and its user (Harness/PathsHarness.swift: a UI test, so it acts in the logged-in user's
  # session), which copies two of them and then waits for the check's SMOKE-STEP lines. The drop's drag is this shell's
  # (Harness/drag.js): the test prints where it starts and ends.
  paths=$run/paths
  mkdir -p "$paths/sub"
  echo a > "$paths/a.txt"
  echo b > "$paths/b.txt"
  touch "$run/smoke.log"
  TEST_RUNNER_PATHS=$paths TEST_RUNNER_LOG=$run/smoke.log \
    xcodebuild test-without-building -xctestrun paths-harness/*.xctestrun -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$run/paths-harness" > "$run/paths-harness.txt" 2>&1 &
  harness=$!
  until grep -q '^HARNESS copied' "$run/paths-harness.txt" 2> /dev/null || ! kill -0 "$harness" 2> /dev/null; do
    sleep 0.1
  done
  (
    until line=$(grep -m 1 '^HARNESS drag ' "$run/paths-harness.txt" 2> /dev/null) || ! kill -0 "$harness" 2> /dev/null; do
      sleep 0.2
    done
    # $line is "HARNESS drag" and four numbers.
    [ -z "${line:-}" ] || osascript -l JavaScript drag.js ${line#HARNESS drag } < /dev/null
  ) &
  dragger=$!
  start=$(now)
  # $expect is two words or none.
  open -n -W -F --env OMPCORE_SMOKE=1 --env "OMPCORE_LOG=$run/smoke.log" --env "OMPCORE_SNAPSHOT=$run/window.png" \
    --env "OMPCORE_SMOKE_PATHS=$paths" $expect --stdout "$run/stdout.txt" --stderr "$run/stderr.txt" \
    macos/ompanion.app &
  app=$!
  watch "$run/smoke.log" "$app" "" || pkill -f "$PWD/macos/ompanion.app/Contents/MacOS/ompanion" || true
  code=0
  wait "$app" || code=$?
  wait "$harness" || echo "the paths harness failed: $(grep -E '^HARNESS|error' "$run/paths-harness.txt" | tr '\n' ' ')"
  wait "$dragger" || true
  if [ -n "$seed" ]; then
    echo "after the import: $(ls "$data" | tr '\n' ' ')"
    security find-generic-password -s "$flutter_service" > /dev/null 2>&1 &&
      echo "after the import: keychain items of service $flutter_service are left" ||
      echo "after the import: no keychain item of service $flutter_service"
  fi
  report "$run/smoke.log" "$code"
}

on_studio_ios() {
  udid=$DEVPOOL_SIM_UDID
  xcrun simctl bootstatus "$udid" -b > /dev/null
  claim_ios
  if [ -n "$seed" ]; then
    xcrun simctl install "$udid" seed/ios-simulator/Runner.app
    # The seed stays on its "seeded" screen: stopped once its line is there.
    xcrun simctl launch --console-pty "$udid" "$id" > "$run/seed.txt" 2>&1 &
    launch=$!
    waited=0
    until tr -d '\r' < "$run/seed.txt" | grep -qE '^(SEEDED|SEED-FAILED) ' || [ "$waited" -ge 120 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    xcrun simctl terminate "$udid" "$id" || true
    wait "$launch" || true
    seeded "$run/seed.txt"
    export SIMCTL_CHILD_OMPCORE_EXPECT_IMPORT="$PWD/expected.json"
  fi
  # Over the seed, as an update from the store would install it: same app, same container and keychain group.
  xcrun simctl install "$udid" ios-simulator/ompanion.app
  start=$(now)
  SIMCTL_CHILD_OMPCORE_SMOKE=1 SIMCTL_CHILD_OMPCORE_SNAPSHOT="$run/page.png" \
    xcrun simctl launch --console-pty --terminate-running-process "$udid" "$id" > "$run/console.txt" 2>&1 &
  launch=$!
  # simctl prints the app's pid only when it exits (its stdout is a file): the simulator's apps are host processes.
  pid=
  while [ -z "$pid" ] && kill -0 "$launch" 2> /dev/null; do
    sleep 0.01
    pid=$(pgrep -f "/Devices/$udid/data/Containers/Bundle/Application/.*/ompanion\.app/ompanion" || true)
  done
  pid_at=$(now)
  watch "$run/console.txt" "$launch" "$pid" || true
  code=0
  wait "$launch" || code=$?
  if [ -n "$seed" ]; then
    container=$(xcrun simctl get_app_container "$udid" "$id" data)
    echo "after the import: $(ls "$container/Library/Application Support" | tr '\n' ' ')"
  fi
  report "$run/console.txt" "$code"
}

if [ "${1:-}" = --on-studio ]; then
  . ./studio-app.sh
  run=$PWD/runs/$2
  seed=${3:-}
  rm -rf "$run"
  mkdir -p "$run"
  "on_studio_$2"
  exit
fi

here=$(cd "$(dirname "$0")" && pwd)
out=$(cd "$here/../../build/apple" && pwd)
seed=
if [ "${1:-}" = --seed ]; then
  [ $# -ge 2 ] || { echo "usage: $0 [--seed <dir>] [macos] [ios]" >&2; exit 2; }
  seed=$(cd "$2" && pwd)
  shift 2
fi
# The macOS run's paths harness, built for testing from a copy in build/apple/harness (XcodeGen resolves its one source
# file against the folder it writes the project to).
case " ${*:-macos} " in
  *" macos "*)
    rm -rf "$out/harness"
    mkdir -p "$out/harness"
    cp "$here/Harness/project.yml" "$here/Harness/PathsHarness.swift" "$out/harness/"
    (cd "$out/harness" && xcodegen generate --quiet &&
      xcodebuild -quiet -project PathsHarness.xcodeproj -scheme PathsHarness -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath DerivedData build-for-testing)
    ;;
esac
remote=studio.local
staging=ompanion-web/apple-smoke
ssh "$remote" "rm -rf $staging && mkdir -p $staging/seed"
rsync -a "$out/macos" "$out/ios-simulator" "$here/smoke.sh" "$here/studio-app.sh" "$here/Harness/drag.js" \
  "$remote:$staging/"
[ ! -d "$out/harness" ] || rsync -a "$out/harness/DerivedData/Build/Products/" "$remote:$staging/paths-harness/"
if [ -n "$seed" ]; then
  rsync -a "$seed/macos" "$seed/ios-simulator" "$remote:$staging/seed/"
  rsync -a "$here/../../harness/flutter-seed/expected.json" "$remote:$staging/"
fi
status=0
for platform in ${*:-macos ios}; do
  case $platform in
    macos) needs="--need host:studio --need pool:studio-gui" ;;
    ios) needs="--need host:studio --need 'ios-sim:iPhone-17 machine=studio runtime=27.0'" ;;
    *) echo "usage: $0 [--seed <dir>] [macos] [ios]" >&2; exit 2 ;;
  esac
  echo "== $platform"
  rm -rf "$out/smoke/$platform" "$out/smoke/$platform.txt"
  mkdir -p "$out/smoke"
  ssh "$remote" "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:\$PATH DEVPOOL_AGENT=ompanion-apple
    cd $staging && devpool run $needs --what 'ompanion: Apple shell smoke ($platform)' \
      -- ./smoke.sh --on-studio $platform ${seed:+seed}" > "$out/smoke/$platform.txt" 2>&1 || true
  grep -v '^devpool: ' "$out/smoke/$platform.txt" || true
  rsync -a "$remote:$staging/runs/$platform/" "$out/smoke/$platform/"
  grep -q '^RESULT: PASS' "$out/smoke/$platform.txt" || status=1
  ls "$out/smoke/$platform/"*.png 2> /dev/null || true
done
ssh "$remote" "rm -rf $staging"
exit $status
