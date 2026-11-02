#!/bin/sh
# smoke.sh's device side. Runs on studio.local under smoke.sh's devpool lease of a phone on air.local ($ANDROID_SERIAL),
# next to app-debug.apk. Stops when the phone already has a com.edde746.ompanion app (it would be the owner's). Installs
# the app, starts it with `--ez smoke true`, prints its GoLog SMOKE lines and the shell's `shell timing` line (tag
# OmpanionShell) once SMOKE-DONE is among them, records the checks for devpool, saves smoke.png and uninstalls the app
# (the phone is shared). A smoke run's page exits the app when done, so the screenshot is of the app started again
# without smoke.
#   smoke-device.sh [import]
# import (next to seed.apk and expected.json): the Flutter seed runs first and the app is installed over it, started
# with `--es expectImport` naming expected.json in its cache; afterwards the Flutter app's database must be renamed to
# ompanion.sqlite.imported and its secure-storage preferences and Keystore key gone (one more devpool check).
set -eu
cd "$(dirname "$0")"
air=air.local
app=com.edde746.ompanion
tmp=/tmp/ompanion-smoke-$ANDROID_SERIAL
expected=/data/user/0/$app/cache/expected-import.json
mode=${1:-}
adb() {
  ssh "$air" "~/Library/Android/sdk/platform-tools/adb -s $ANDROID_SERIAL $*"
}
cleanup() {
  if adb shell pm path "$app" > /dev/null; then adb uninstall "$app"; fi
  adb shell rm -f /data/local/tmp/ompanion-expected.json
  ssh "$air" rm -rf "$tmp"
}

echo "device $ANDROID_SERIAL: $(adb shell getprop ro.product.model), Android $(adb shell getprop ro.build.version.release)," \
  "WebView $(adb shell dumpsys webviewupdate | sed -n 's/.*Current WebView package (name, version): (\(.*\))/\1/p')"
if adb shell pm path "$app" > /dev/null; then
  echo "the phone already has $app installed: stopping without touching it" >&2
  exit 1
fi
trap cleanup EXIT
ssh "$air" mkdir -p "$tmp"
scp -q app-debug.apk "$air:$tmp/app.apk"
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
extra=
if [ "$mode" = import ]; then
  scp -q seed.apk expected.json "$air:$tmp/"
  adb install "$tmp/seed.apk"
  adb logcat -c
  adb shell am start -W -n "$app/.MainActivity"
  started=$(date +%s)
  until adb logcat -d -v raw -s flutter | grep -q '^SEEDED'; do
    if [ $(($(date +%s) - started)) -ge 120 ]; then
      echo "the seed printed no SEEDED within 120 s; its log:" >&2
      adb logcat -d -v brief -s flutter | tail -n 40 >&2
      exit 1
    fi
    sleep 1
  done
  adb shell am force-stop "$app"
  echo "seeded: $(adb shell run-as "$app" ls files shared_prefs | tr '\n' ' ')"
  adb push "$tmp/expected.json" /data/local/tmp/ompanion-expected.json
fi
adb install -r "$tmp/app.apk"
if [ "$mode" = import ]; then
  adb shell run-as "$app" mkdir -p cache
  adb shell run-as "$app" cp /data/local/tmp/ompanion-expected.json cache/expected-import.json
  adb shell rm /data/local/tmp/ompanion-expected.json
  extra="--es expectImport $expected"
fi
adb logcat -c
started=$(date +%s)
adb shell am start -S -W -n "$app/.MainActivity" --ez smoke true $extra
while :; do
  lines=$(adb logcat -d -v raw -s GoLog OmpanionShell | sed -n '/^SMOKE/p; /^shell timing/p')
  case "$lines" in *SMOKE-DONE*) break ;; esac
  if [ $(($(date +%s) - started)) -ge 180 ]; then
    printf '%s\n' "$lines"
    echo "no SMOKE-DONE within 180 s; the app's log:" >&2
    adb logcat -d -v brief | grep -E "OmpanionShell|GoLog|AndroidRuntime|chromium|$app" | tail -n 80 >&2
    exit 1
  fi
  sleep 1
done
echo "SMOKE-DONE $(($(date +%s) - started)) s after am start"
printf '%s\n' "$lines"
done_line=$(printf '%s\n' "$lines" | sed -n 's/^SMOKE-DONE //p')
passed=$(printf '%s\n' "$done_line" | sed -E 's/.*"passed": *([0-9]+).*/\1/')
total=$(printf '%s\n' "$done_line" | sed -E 's/.*"total": *([0-9]+).*/\1/')
echo "$passed $total" >> "$DEVPOOL_CHECKS"

waited=0
while adb shell pidof "$app" > /dev/null; do
  if [ "$waited" -ge 10 ]; then
    echo "the app still runs 10 s after SMOKE-DONE: core.exit did not end it" >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

if [ "$mode" = import ]; then
  left=$(adb shell run-as "$app" ls files shared_prefs)
  echo "after the import: $(printf '%s\n' "$left" | tr '\n' ' ')"
  adb logcat -d -v raw -s OmpanionShell | grep "cleared the Flutter app's data" || true
  if printf '%s\n' "$left" | grep -qx 'ompanion.sqlite.imported' &&
    ! printf '%s\n' "$left" | grep -qx -e 'ompanion.sqlite' -e 'FlutterSecure.*' &&
    adb logcat -d -v raw -s OmpanionShell | grep -q "cleared the Flutter app's data"; then
    echo "1 1" >> "$DEVPOOL_CHECKS"
  else
    echo "the Flutter app's data is still there, or its database was not kept as ompanion.sqlite.imported" >&2
    echo "0 1" >> "$DEVPOOL_CHECKS"
  fi
fi

adb shell am start -W -n "$app/.MainActivity"
sleep 5
ssh "$air" "~/Library/Android/sdk/platform-tools/adb -s $ANDROID_SERIAL exec-out screencap -p" > smoke.png
[ "$total" -gt 0 ] && [ "$passed" -eq "$total" ]
