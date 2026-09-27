#!/bin/sh
# Captures the store screenshots for one device class and composes the store images.
#
#   store/screenshots/capture.sh ios-phone
#   store/screenshots/capture.sh play-10in --no-compose
#   store/screenshots/capture.sh ms-desktop --windows <ssh destination of a Windows 11 machine>
#
# The script owns everything it starts: the fake provider (unless one is already listening), the scripted
# turns, the simulator or emulator, the temporary Android AVDs of the tablet classes, and for ms-desktop the
# reverse tunnel, the copy of the checkout on the Windows machine and everything `windows/run.ps1` starts there.
# It needs the SSH demo host up (`harness/sshd/up.sh`: the `omp` user on 127.0.0.1:22221, the bastion on 22220),
# `flutter`, `bun`, `python3` with Pillow, and `docker` while the demo host is the container.
#
# Raw captures land in <raw>/<class>/; the composed images go straight into the fastlane directories of
# `--out`. The run's own log is <raw>/<class>/capture.log and the app's progress log is printed at the end.
#
#   --repo <dir>     the checkout to build in, e.g. a private copy (default: this script's checkout)
#   --out <dir>      the checkout whose fastlane directories and assets the images belong to (default: same)
#   --raw <dir>      where raw captures land (default /tmp/ompanion-store/StoreShots/raw)
#   --provider-port <n>  fake provider port (default 18991); --provider-url overrides what the host gets
#   --ssh-host/--ssh-port/--ssh-user/--ssh-key   the demo host as this Mac reaches it
#   --avd <name>     use this AVD instead of the class default
#   --windows <dest> the Windows machine of ms-desktop, as `ssh` reaches it (key auth, a user logged on at its console)
#   --no-container   do not install git/node/npm through docker exec
#   --no-compose     capture only; --keep leaves the simulator booted, or the Windows clone and its build in
#                    ~\ompanion-shots; --keep-avds keeps the temporary AVDs
set -eu

here=$(cd "$(dirname "$0")" && pwd)
class=
repo=$(cd "$here/../.." && pwd)
raw=/tmp/ompanion-store/StoreShots/raw
out=$(cd "$here/../.." && pwd)
provider_port=18991
provider_url=
ssh_host=localhost
ssh_port=22221
ssh_user=omp
ssh_key=
seed_container=omp-sshd-target
compose=yes
keep=no
keep_avds=no
avd_override=
windows=
while [ $# -gt 0 ]; do
  case "$1" in
    ios-phone | ios-ipad | play-phone | play-7in | play-10in | ms-desktop) class=$1; shift ;;
    --repo) repo=$(cd "$2" && pwd); shift 2 ;;
    --raw) raw=$2; shift 2 ;;
    --out) out=$(cd "$2" && pwd); shift 2 ;;
    --provider-port) provider_port=$2; shift 2 ;;
    --provider-url) provider_url=$2; shift 2 ;;
    --ssh-host) ssh_host=$2; shift 2 ;;
    --ssh-port) ssh_port=$2; shift 2 ;;
    --ssh-user) ssh_user=$2; shift 2 ;;
    --ssh-key) ssh_key=$2; shift 2 ;;
    --avd) avd_override=$2; shift 2 ;;
    --no-container) seed_container=; shift ;;
    --no-compose) compose=no; shift ;;
    --keep) keep=yes; shift ;;
    --keep-avds) keep_avds=yes; shift ;;
    --windows) windows=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$class" ]; then
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
[ "$class" != ms-desktop ] || [ -n "$windows" ] || { echo "ms-desktop needs --windows <ssh destination>" >&2; exit 2; }
[ -n "$ssh_key" ] || ssh_key="$out/.tools/ssh-test/id_ed25519"
[ -f "$ssh_key" ] || { echo "missing SSH key $ssh_key: run harness/sshd/up.sh first" >&2; exit 1; }
[ -n "$provider_url" ] || provider_url="http://host.docker.internal:$provider_port/v1"
ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export ANDROID_HOME

shots="$raw/$class"
mkdir -p "$shots"
log="$shots/capture.log"
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$log"; }

pids=
avds=
udid=
# ms-desktop: the Windows copy of the checkout, relative to the Windows user's home, once it is there.
windows_run=
cleanup() {
  if [ -n "$windows_run" ]; then
    if [ "$keep" = yes ]; then keep_clone=-KeepClone; else keep_clone=; fi
    say "cleaning up on $windows"
    # shellcheck disable=SC2086 # $keep_clone is one flag or none
    ssh "$windows" powershell -NoProfile -ExecutionPolicy Bypass -File "$windows_run" -Cleanup $keep_clone >>"$log" 2>&1 ||
      say "the cleanup on $windows failed; see $log"
  fi
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  if [ "$keep_avds" = no ]; then
    for avd in $avds; do
      say "deleting AVD $avd"
      "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" delete avd -n "$avd" >/dev/null 2>&1 || true
    done
  fi
  if [ "$keep" = no ] && [ -n "$udid" ]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

start_bg() {
  # start_bg <logfile> <command...>
  name=$1
  shift
  nohup "$@" >"$name" 2>&1 &
  pids="$pids $!"
  echo $!
}

# --- fake provider ------------------------------------------------------------------------------------
if curl -fsS "http://127.0.0.1:$provider_port/control/health" >/dev/null 2>&1; then
  say "fake provider already listening on $provider_port"
else
  say "starting the fake provider on $provider_port"
  start_bg "$shots/provider.log" bun "$repo/harness/fake-provider/server.ts" --port "$provider_port" --host 0.0.0.0 >/dev/null
  until curl -fsS "http://127.0.0.1:$provider_port/control/health" >/dev/null 2>&1; do sleep 1; done
fi

# --- demo host ----------------------------------------------------------------------------------------
if [ -n "$seed_container" ] && command -v docker >/dev/null 2>&1; then
  docker inspect "$seed_container" >/dev/null 2>&1 || { echo "$seed_container is not running: run harness/sshd/up.sh" >&2; exit 1; }
  missing=$(docker exec "$seed_container" sh -c 'for tool in git node npm; do command -v $tool >/dev/null || echo $tool; done' 2>/dev/null || true)
  if [ -n "$missing" ]; then
    say "installing$missing in $seed_container"
    docker exec "$seed_container" sh -c 'apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git nodejs npm >/dev/null 2>&1'
  fi
fi
say "seeding $ssh_user@$ssh_host:$ssh_port"
sh "$here/demo/seed-host.sh" --host "$ssh_host" --port "$ssh_port" --user "$ssh_user" --key "$ssh_key" \
  --provider-url "$provider_url" >>"$log" 2>&1

# --- scripted turns -----------------------------------------------------------------------------------
say "queueing the scripted turns"
start_bg "$shots/turns-hero.log" bun "$repo/store/screenshots/demo/turns.ts" --provider "http://127.0.0.1:$provider_port" --session hero >/dev/null
start_bg "$shots/turns-deploy.log" bun "$repo/store/screenshots/demo/turns.ts" --provider "http://127.0.0.1:$provider_port" --session deploy >/dev/null
sleep 3

# --- device -------------------------------------------------------------------------------------------
case "$class" in
  ios-phone | ios-ipad)
    if [ "$class" = ios-phone ]; then name="iPhone 17 Pro Max"; else name="iPad Pro 13-inch (M5)"; fi
    udid=$(python3 "$here/device.py" simulator-udid "$name")
    say "booting simulator $name ($udid)"
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
    xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
    # A fresh install gives the app an empty database; `flutter drive` installs it again.
    xcrun simctl uninstall "$udid" com.edde746.ompanion >/dev/null 2>&1 || true
    device=$udid
    target="ios:$udid"
    ;;
  play-*)
    avdmanager="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
    adb="$ANDROID_HOME/platform-tools/adb"
    case "$class" in
      play-phone) avd=${avd_override:-Pixel_9a} ;;
      play-7in) avd=${avd_override:-ompanion-store-7} ;;
      play-10in) avd=${avd_override:-ompanion-store-10} ;;
    esac
    if ! "$ANDROID_HOME/emulator/emulator" -list-avds | grep -qx "$avd"; then
      # A tablet needs a touch image: skip the TV, automotive and XR ones, and prefer the one the phone AVD uses.
      image=
      for candidate in "$ANDROID_HOME"/system-images/*/*/arm64-v8a/; do
        case "$candidate" in
          *android-tv* | *automotive* | *google-xr*) ;;
          *) [ -d "$candidate" ] && image=$candidate ;;
        esac
      done
      [ -n "$image" ] || { echo "no arm64 phone or tablet system image in $ANDROID_HOME/system-images" >&2; exit 1; }
      # avdmanager wants the package id with semicolons and the leading `system-images`.
      package="system-images;${image#"$ANDROID_HOME/system-images/"}"
      package=$(printf '%s' "$package" | sed 's:/$::' | tr '/' ';')
      case "$class" in
        play-7in) width=1200; height=1920 ;;
        play-10in) width=1600; height=2560 ;;
      esac
      say "creating AVD $avd from $package"
      echo no | "$avdmanager" create avd -n "$avd" -k "$package" -d medium_tablet --force >>"$log" 2>&1
      {
        printf 'hw.lcd.width=%s\nhw.lcd.height=%s\nhw.lcd.density=320\n' "$width" "$height"
        printf 'hw.initialOrientation=landscape\nhw.keyboard=yes\ndisk.dataPartition.size=3G\n'
      } >>"$HOME/.android/avd/$avd.avd/config.ini"
      avds="$avds $avd"
    fi
    say "starting $avd headless"
    start_bg "$shots/emulator.log" "$ANDROID_HOME/emulator/emulator" -avd "$avd" -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect >/dev/null
    # Another emulator (the phone of an earlier class) may still be up: take the one that runs this AVD.
    emulator_of() {
      for serial in $($adb devices | awk '/^emulator-/{print $1}'); do
        if [ "$($adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')" = "$avd" ]; then
          echo "$serial"
          return
        fi
      done
    }
    tries=0
    until device=$(emulator_of) && [ -n "$device" ] &&
      [ "$($adb -s "$device" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
      tries=$((tries + 1))
      [ "$tries" -lt 120 ] || { echo "$avd did not boot" >&2; exit 1; }
      sleep 3
    done
    say "booted $device"
    # The emulator boots to a lock screen and dims; the app has to be renderable before `flutter drive` starts it.
    $adb -s "$device" shell svc power stayon true >/dev/null 2>&1 || true
    $adb -s "$device" shell settings put system screen_off_timeout 1800000 >/dev/null 2>&1 || true
    $adb -s "$device" shell locksettings set-disabled true >/dev/null 2>&1 || true
    $adb -s "$device" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    $adb -s "$device" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    # System UI demo mode: a full battery, full signal and a fixed 9:41 clock without a real device's noise.
    $adb -s "$device" shell settings put global sysui_demo_allowed 1
    for demo in "command enter" "command clock -e hhmm 0941" "command battery -e level 100 -e plugged false" \
      "command network -e wifi show -e level 4" "command network -e mobile show -e datatype none -e level 4" \
      "command notifications -e visible false"; do
      # Each entry is several arguments to `am broadcast`: the split is the point.
      # shellcheck disable=SC2086
      $adb -s "$device" shell am broadcast -a com.android.systemui.demo -e $demo >/dev/null
    done
    for scale in window_animation_scale transition_animation_scale animator_duration_scale; do
      $adb -s "$device" shell settings put global "$scale" 0
    done
    $adb -s "$device" shell settings put system font_scale 1.0
    # Dark system UI: the app is dark, and the status and navigation bars follow the system.
    $adb -s "$device" shell cmd uimode night yes >/dev/null 2>&1 || true
    if [ "$class" != play-phone ]; then
      $adb -s "$device" shell settings put system accelerometer_rotation 0
      $adb -s "$device" shell settings put system user_rotation 1
      say "tablet rotated to landscape"
    fi
    $adb -s "$device" uninstall com.edde746.ompanion >/dev/null 2>&1 || true
    target="android:$device"
    ;;
  ms-desktop)
    companion="$repo/assets/companion/ompx.js"
    [ -f "$companion" ] || { echo "missing $companion: run scripts/build_companion.sh" >&2; exit 1; }
    # The Windows app dials the demo host as localhost, through this tunnel to the ports on this Mac.
    say "tunnelling the demo host's ports to $windows"
    start_bg "$shots/tunnel.log" ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
      -R "22221:$ssh_host:$ssh_port" -R "22220:$ssh_host:22220" "$windows" >/dev/null
    tunnel=$!
    sleep 3
    kill -0 "$tunnel" 2>/dev/null || { echo "the tunnel to $windows failed: $(cat "$shots/tunnel.log")" >&2; exit 1; }
    # What the Windows build needs: the app, its package, the test, the runner, the assets (the companion is not
    # tracked) and the Windows half of this harness. It lands in ~\ompanion-shots\repo on the Windows machine.
    say "copying the checkout to $windows"
    (cd "$repo" && {
      git ls-files -co --exclude-standard -- ':(glob)*' lib packages integration_test windows assets store/screenshots/windows
      echo assets/companion/ompx.js
    } | while IFS= read -r path; do [ -f "$path" ] && printf '%s\n' "$path"; done |
      tar -czf "$shots/checkout.tgz" -s ',^,ompanion-shots/repo/,' -T -)
    scp -q "$shots/checkout.tgz" "$windows:ompanion-shots.tgz"
    rm -f "$shots/checkout.tgz"
    windows_run=ompanion-shots/repo/store/screenshots/windows/run.ps1
    ssh "$windows" tar -xzf ompanion-shots.tgz >>"$log" 2>&1
    ssh "$windows" del ompanion-shots.tgz >>"$log" 2>&1
    device=$windows
    ;;
esac

# --- capture ------------------------------------------------------------------------------------------
key_b64=$(base64 -i "$ssh_key" | tr -d '\n')
# The iOS simulator shares this Mac's loopback, and Windows reaches it through the tunnel; an emulator reaches it as
# 10.0.2.2. The machines' *names* stay dev-box and build-server, so no screen shows an address.
case "$class" in
  ios-* | ms-desktop) ssh_define=localhost ;;
  *) ssh_define=10.0.2.2 ;;
esac
hostkeys=$(python3 "$here/device.py" hostkeys "$out/.tools/ssh-test/hostkeys" "$ssh_define")
# Stale captures from an earlier run would be composed as if they were this run's.
rm -f "$shots"/*.png "$shots/driver.log"
say "capturing $class on $device"
drive_status=0
if [ "$class" = ms-desktop ]; then
  # A define file, not arguments: the host keys hold `|` and `;`, which no Windows shell should see.
  python3 -c 'import json, sys; json.dump(dict(pair.split("=", 1) for pair in sys.argv[2:]), open(sys.argv[1], "w"))' \
    "$shots/defines.json" OMPANION_SHOT_CLASS="$class" OMPANION_SHOT_SSH_HOST="$ssh_define" \
    OMPANION_SHOT_KEY_B64="$key_b64" OMPANION_SHOT_HOSTKEYS="$hostkeys"
  scp -q "$shots/defines.json" "$windows:ompanion-shots/defines.json"
  rm -f "$shots/defines.json"
  ssh "$windows" powershell -NoProfile -ExecutionPolicy Bypass -File "$windows_run" -Launch >>"$log" 2>&1 || drive_status=$?
  scp -q "$windows:ompanion-shots/raw/*" "$shots/" >>"$log" 2>&1 || true
  scp -q "$windows:ompanion-shots/tmp/ompanion-shots.log" "$shots/app.log" >>"$log" 2>&1 || true
else
  (cd "$repo" && OMPANION_SHOT_TARGET="$target" OMPANION_SHOT_DIR="$shots" flutter drive -d "$device" \
    --driver=integration_test/driver/store_driver.dart \
    --target=integration_test/store_screenshots_test.dart \
    --dart-define=OMPANION_SHOT_CLASS="$class" \
    --dart-define=OMPANION_SHOT_SSH_HOST="$ssh_define" \
    --dart-define=OMPANION_SHOT_KEY_B64="$key_b64" \
    --dart-define=OMPANION_SHOT_HOSTKEYS="$hostkeys") >>"$log" 2>&1 || drive_status=$?
fi
say "raw captures in $shots (flutter drive exited $drive_status)"
[ "$drive_status" = 0 ] || say "the capture reported failures; see $log"

if [ "$compose" = yes ]; then
  say "composing the store images"
  python3 "$here/compose.py" --raw "$raw" --repo "$out" --only "$class"
fi

case "$class" in
  ios-*) say "app log: $(xcrun simctl get_app_container "$udid" com.edde746.ompanion data 2>/dev/null)/tmp/ompanion-shots.log" ;;
  ms-desktop) say "app log: $shots/app.log" ;;
  *) say "app log: $ANDROID_HOME/platform-tools/adb -s $device shell run-as com.edde746.ompanion cat cache/ompanion-shots.log" ;;
esac
say "done"
