#!/bin/sh
# Runs build.sh's seed on studio.local through devpool, shows what it wrote and removes all of it (README.md):
#   run.sh <macos|ios-simulator|android> [--build <dir>] [--db <file>]
# macos in studio's GUI session (pool:studio-gui), ios-simulator on an iPhone 17 simulator there, android on the Pixel
# (adb on air.local). The run first checks that no com.edde746.ompanion app or data is on the Mac or device and stops
# if there is. --build is build.sh's --out (default $TMPDIR/flutter-seed/<platform>); --db copies the database the
# seed wrote to <file> before the cleanup. Inside the lease this script runs itself: run.sh --on-studio <platform>.
set -eu

app=com.edde746.ompanion
service=flutter_secure_storage_service
team=G88U5B5783

fail() {
  echo "run.sh: $*" >&2
  exit 1
}

# rows <db>: the row count of each table and the machines.
rows() {
  for table in machines machine_jumps ssh_keys known_hosts settings read_markers pinned_sessions; do
    echo "rows $table: $(sqlite3 "$1" "select count(*) from $table")"
  done
  sqlite3 -separator ' | ' "$1" 'select id, kind, name, created_at from machines'
}

# result <file>: the seed's result line in <file>; fails unless it is SEEDED or CLEANED.
result() {
  line=$(tr -d '\r' < "$1" | grep -E '^(SEEDED|CLEANED|SEED-FAILED) ' | tail -n 1)
  echo "${line:-no result line in $1}"
  case $line in SEEDED* | CLEANED*) ;; *) cat "$1" >&2; return 1 ;; esac
}

on_macos() {
  data="$HOME/Library/Application Support/$app"
  if [ -e "$data" ] || security find-generic-password -s "$service" > /dev/null 2>&1 ||
    security find-generic-password -s "$app" > /dev/null 2>&1; then
    fail "$app data or keychain items are already on this Mac; nothing was run"
  fi
  echo "before: no '$data', no keychain item of service $service or $app"
  # AppKit keeps window state in the app's defaults; whatever was there before is put back.
  prefs="$HOME/Library/Preferences/$app.plist"
  saved="$HOME/Library/Saved Application State/$app.savedState"
  rm -f prefs-before.plist
  [ ! -e "$prefs" ] || defaults export "$app" prefs-before.plist
  [ ! -e "$saved" ] || fail "'$saved' exists; nothing was run"
  trap clean_macos EXIT
  # Through LaunchServices, as a user's launch: the app joins the GUI session, whose login keychain is open to it.
  open -n -W -F --stdout "$PWD/seed.txt" --stderr "$PWD/seed-stderr.txt" macos/ompanion.app
  result seed.txt
  rows "$data/ompanion.sqlite"
  cp "$data/ompanion.sqlite" ompanion.sqlite
  while read -r key; do
    security find-generic-password -s "$service" -a "$key" > /dev/null && echo "keychain item: $service $key"
  done < secret-keys.txt
}

clean_macos() {
  mkdir -p "$data"
  touch "$data/seed-clean"
  open -n -W -F --stdout "$PWD/clean.txt" --stderr "$PWD/clean-stderr.txt" macos/ompanion.app || true
  result clean.txt || true
  rm -rf "$data" "$saved"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u macos/ompanion.app || true
  if [ -e prefs-before.plist ]; then
    defaults import "$app" prefs-before.plist
  else
    defaults delete "$app" 2> /dev/null || true
  fi
  if [ -e "$data" ] || security find-generic-password -s "$service" > /dev/null 2>&1; then
    echo "after: '$data' or a keychain item of service $service is left" >&2
  else
    echo "after: no '$data', no keychain item of service $service"
  fi
}

# launch_simulator <output file>: runs the app until it prints its result line, then stops it.
launch_simulator() {
  xcrun simctl launch --console-pty --terminate-running-process "$udid" "$app" > "$1" 2>&1 &
  launch=$!
  waited=0
  until tr -d '\r' < "$1" | grep -qE '^(SEEDED|CLEANED|SEED-FAILED) ' || [ "$waited" -ge 120 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  sleep 2
  xcrun simctl terminate "$udid" "$app" || true
  wait "$launch" || true
  result "$1"
}

on_ios_simulator() {
  udid=$DEVPOOL_SIM_UDID
  xcrun simctl bootstatus "$udid" -b > /dev/null
  ! xcrun simctl get_app_container "$udid" "$app" > /dev/null 2>&1 ||
    fail "$app is already installed on simulator $udid; nothing was run"
  echo "before: $app is not installed on simulator $udid"
  trap clean_ios_simulator EXIT
  xcrun simctl install "$udid" ios-simulator/Runner.app
  container=$(xcrun simctl get_app_container "$udid" "$app" data)
  launch_simulator seed.txt
  ls "$container/Library/Application Support"
  rows "$container/Library/Application Support/ompanion.sqlite"
  cp "$container/Library/Application Support/ompanion.sqlite" ompanion.sqlite
  keychain_items
}

# The simulator's keychain items of the app's group.
keychain_items() {
  echo "keychain items in group $team.$app: $(sqlite3 \
    "$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Keychains/keychain-2-debug.db" \
    "select count(*) from genp where agrp = '$team.$app'")"
}

clean_ios_simulator() {
  if [ -n "${container:-}" ]; then
    touch "$container/Library/Application Support/seed-clean"
    launch_simulator clean.txt || true
    keychain_items
  fi
  xcrun simctl uninstall "$udid" "$app" || true
  xcrun simctl get_app_container "$udid" "$app" > /dev/null 2>&1 && echo "after: $app is still installed" >&2 ||
    echo "after: $app is not installed on simulator $udid"
}

android_adb() {
  ssh air.local "~/Library/Android/sdk/platform-tools/adb -s $ANDROID_SERIAL $*"
}

on_android() {
  [ -z "$(android_adb shell pm list packages "$app")" ] ||
    fail "$app is already installed on $ANDROID_SERIAL; nothing was run"
  echo "before: pm list packages $app is empty on $ANDROID_SERIAL"
  apk=/tmp/flutter-seed-$ANDROID_SERIAL.apk
  trap clean_android EXIT
  scp -q android/app-debug.apk "air.local:$apk"
  android_adb install "$apk" > /dev/null
  android_adb shell input keyevent KEYCODE_WAKEUP
  android_adb shell wm dismiss-keyguard
  android_adb logcat -c
  android_adb shell am start -W -n "$app/.MainActivity" > /dev/null
  waited=0
  until android_adb logcat -d -v raw -s flutter > seed.txt && grep -qE '^(SEEDED|SEED-FAILED) ' seed.txt ||
    [ "$waited" -ge 120 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  # The secure storage writes its preferences asynchronously; give them a moment before the app stops.
  sleep 3
  android_adb shell am force-stop "$app"
  result seed.txt
  echo "run-as $app ls files: $(android_adb shell run-as "$app" ls files | tr '\n' ' ')"
  android_adb exec-out run-as "$app" cat files/ompanion.sqlite > ompanion.sqlite
  rows ompanion.sqlite
  android_adb shell run-as "$app" cat shared_prefs/FlutterSecureStorage.xml |
    sed -n 's/.*name="VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_\([^"]*\)".*/secure storage entry: \1/p'
}

clean_android() {
  android_adb uninstall "$app" > /dev/null || true
  ssh air.local rm -f "$apk"
  [ -z "$(android_adb shell pm list packages "$app")" ] && echo "after: pm list packages $app is empty" ||
    echo "after: $app is still installed on $ANDROID_SERIAL" >&2
}

if [ "${1:-}" = --on-studio ]; then
  cd "$(dirname "$0")"
  case $2 in
    macos) on_macos ;;
    ios-simulator) on_ios_simulator ;;
    android) on_android ;;
  esac
  exit
fi

usage() {
  echo "usage: run.sh <macos|ios-simulator|android> [--build <dir>] [--db <file>]" >&2
  exit 2
}
platform=${1:-}
case $platform in
  macos) needs="--need host:studio --need pool:studio-gui" artifact=ompanion.app ;;
  ios-simulator)
    needs="--need host:studio --need 'ios-sim:iPhone-17 machine=studio runtime=27.0'" artifact=Runner.app
    ;;
  android) needs="--need device:pixel" artifact=app-debug.apk ;;
  *) usage ;;
esac
shift
tmp=${TMPDIR:-/tmp}
build=${tmp%/}/flutter-seed/$platform
db=
while [ $# -gt 0 ]; do
  case $1 in
    --build) [ $# -ge 2 ] || usage; build=$2; shift 2 ;;
    --db) [ $# -ge 2 ] || usage; db=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -e "$build/$artifact" ] || fail "no $build/$artifact: run build.sh $platform first"

here=$(cd "$(dirname "$0")" && pwd)
stage=ompanion-web/flutter-seed
ssh -o BatchMode=yes studio.local "rm -rf $stage && mkdir -p $stage/$platform"
jq -r '.secrets | keys[]' "$here/expected.json" > "$tmp/flutter-seed-secret-keys.txt"
rsync -a "$build/$artifact" "studio.local:$stage/$platform/"
rsync -a "$here/run.sh" "studio.local:$stage/"
rsync -a "$tmp/flutter-seed-secret-keys.txt" "studio.local:$stage/secret-keys.txt"
status=0
ssh -o BatchMode=yes studio.local "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:\$PATH
  export DEVPOOL_AGENT=ompanion-web-flutter-seed
  cd $stage && devpool run $needs --what 'ompanion: Flutter seed ($platform)' -- sh run.sh --on-studio $platform" ||
  status=$?
if [ -n "$db" ]; then
  rsync -a "studio.local:$stage/ompanion.sqlite" "$db" || echo "run.sh: no database to copy" >&2
fi
ssh -o BatchMode=yes studio.local "rm -rf $stage"
exit "$status"
