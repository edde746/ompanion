#!/bin/sh
# Captures the store screenshots for one device class and composes the store images.
#
#   store/screenshots/capture.sh ios-phone
#   store/screenshots/capture.sh play-10in --no-compose
#
# The script owns everything it starts: the fake provider (unless one is already listening), the scripted
# turns, the simulator or emulator, and the temporary Android AVDs of the tablet classes. It needs the SSH
# demo host up (`testing/sshd/up.sh`: the `omp` user on 127.0.0.1:22221, the bastion on 22220), `flutter`,
# `bun`, `python3` with Pillow, and `docker` while the demo host is the container.
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
#   --no-container   do not install git/node/npm through docker exec
#   --no-compose     capture only; --keep leaves the simulator booted; --keep-avds keeps the temporary AVDs
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
while [ $# -gt 0 ]; do
  case "$1" in
    ios-phone | ios-ipad | play-phone | play-7in | play-10in) class=$1; shift ;;
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
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$class" ]; then
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
[ -n "$ssh_key" ] || ssh_key="$out/.tools/ssh-test/id_ed25519"
[ -f "$ssh_key" ] || { echo "missing SSH key $ssh_key: run testing/sshd/up.sh first" >&2; exit 1; }
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
cleanup() {
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
  start_bg "$shots/provider.log" bun "$repo/testing/fake-provider/server.ts" --port "$provider_port" --host 0.0.0.0 >/dev/null
  until curl -fsS "http://127.0.0.1:$provider_port/control/health" >/dev/null 2>&1; do sleep 1; done
fi

# --- demo host ----------------------------------------------------------------------------------------
if [ -n "$seed_container" ] && command -v docker >/dev/null 2>&1; then
  docker inspect "$seed_container" >/dev/null 2>&1 || { echo "$seed_container is not running: run testing/sshd/up.sh" >&2; exit 1; }
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
esac

# --- capture ------------------------------------------------------------------------------------------
key_b64=$(base64 -i "$ssh_key" | tr -d '\n')
# The iOS simulator shares this Mac's loopback; an emulator reaches it as 10.0.2.2. The machines' *names* stay
# dev-box and build-server, so no screen shows an address.
case "$class" in
  ios-*) ssh_define=localhost ;;
  *) ssh_define=10.0.2.2 ;;
esac
hostkeys=$(python3 "$here/device.py" hostkeys "$out/.tools/ssh-test/hostkeys" "$ssh_define")
# Stale captures from an earlier run would be composed as if they were this run's.
rm -f "$shots"/*.png "$shots/driver.log"
say "capturing $class on $device"
drive_status=0
(cd "$repo" && OMPANION_SHOT_TARGET="$target" OMPANION_SHOT_DIR="$shots" flutter drive -d "$device" \
  --driver=test_driver/store_driver.dart \
  --target=integration_test/store_screenshots_test.dart \
  --dart-define=OMPANION_SHOT_CLASS="$class" \
  --dart-define=OMPANION_SHOT_SSH_HOST="$ssh_define" \
  --dart-define=OMPANION_SHOT_KEY_B64="$key_b64" \
  --dart-define=OMPANION_SHOT_HOSTKEYS="$hostkeys") >>"$log" 2>&1 || drive_status=$?
say "raw captures in $shots (flutter drive exited $drive_status)"
[ "$drive_status" = 0 ] || say "the capture reported failures; see $log"

if [ "$compose" = yes ]; then
  say "composing the store images"
  python3 "$here/compose.py" --raw "$raw" --repo "$out" --only "$class"
fi

case "$class" in
  ios-*) say "app log: $(xcrun simctl get_app_container "$udid" com.edde746.ompanion data 2>/dev/null)/tmp/ompanion-shots.log" ;;
  *) say "app log: $ANDROID_HOME/platform-tools/adb -s $device shell run-as com.edde746.ompanion cat cache/ompanion-shots.log" ;;
esac
say "done"
