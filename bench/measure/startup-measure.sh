#!/bin/sh
# Launch to first frame of the web app (docs/research/web-ui/startup.md), on studio.local through devpool: nothing
# runs on this machine. Each session stages the apps in studio.local:~/ompanion-bench/Startup/ and copies its raw
# data back to build/bench/results/startup/<platform>-<name>/.
#   startup-measure.sh macos <name> [rounds]          GUI pool: startup.py macos (default 7 rounds) of the web app as
#                                                     built now and every saved web build
#                                                     (build/bench/startup/<variant>/macos/ompanion.app)
#   startup-measure.sh ios <name> [rounds] [app]      an iPhone 17 simulator: startup.py ios of the web app (default:
#                                                     as built now)
#   startup-measure.sh android <name> [rounds] [apk]  the Pixel 7 (the Fold3 when the Pixel is out of reach):
#                                                     android-device.py startup of the web app (default: as built now)
#   startup-measure.sh report <session>…              startup.py report over those sessions (<platform>-<name>)
#   startup-measure.sh clean                          removes the stage on studio.local
# Apps: shells/apple/build.sh (macOS, iOS simulator) and shells/android/build.sh --release (app-release-arm64.apk).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
build=$(cd "$here/../../build" && pwd)
results=$build/bench/results/startup
stage=ompanion-bench/Startup
pool='export PATH=$HOME/.local/bin:/opt/homebrew/bin:$PATH DEVPOOL_AGENT=ompanion-measure-Startup;'
mkdir -p "$results"

# run <session> <devpool needs> <what> <command>: runs <command> in the session's stage under one lease, then copies
# the session back.
run() {
  session=$1 needs=$2 what=$3 command=$4
  status=0
  ssh studio.local "$pool cd $stage/$session && devpool run $needs --what 'ompanion measure: startup, $what' \
    -- $command" 2>&1 | tee "$results/$session.txt" || status=$?
  rsync -a "studio.local:$stage/$session/out/" "$results/$session/"
  grep -q '^RESULT: PASS' "$results/$session.txt" || status=1
  return $status
}

platform=${1:-}
case $platform in
  macos | ios | android)
    [ $# -ge 2 ] || { sed -n '2,14p' "$0" >&2; exit 2; }
    session=$platform-$2
    rounds=${3:-7}
    ssh studio.local "rm -rf $stage/$session && mkdir -p $stage/$session/apps/web $stage/$session/apps/ios \
      $stage/$session/apk"
    rsync -a "$here/startup.py" "$here/android-device.py" "studio.local:$stage/$session/"
    case $platform in
      macos)
        rsync -a "$build/apple/macos/ompanion.app" "studio.local:$stage/$session/apps/web/"
        for saved in "$build"/bench/startup/*/macos/ompanion.app; do
          [ -d "$saved" ] || continue
          variant=$(basename "$(dirname "$(dirname "$saved")")")
          ssh studio.local "mkdir -p $stage/$session/apps/web-$variant"
          rsync -a "$saved" "studio.local:$stage/$session/apps/web-$variant/"
        done
        run "$session" "--need host:studio --need pool:studio-gui" "macOS $2" "python3 -u startup.py macos $rounds out"
        ;;
      ios)
        rsync -a "${4:-$build/apple/ios-simulator/ompanion.app}" "studio.local:$stage/$session/apps/ios/"
        run "$session" "--need host:studio --need 'ios-sim:iPhone-17 machine=studio runtime=27.0'" "iOS simulator $2" \
          "python3 -u startup.py ios $rounds out"
        ;;
      android)
        rsync -a "${4:-$build/android/app-release-arm64.apk}" "studio.local:$stage/$session/apk/web.apk"
        pixel=$(ssh studio.local "$pool devpool status device:pixel" | sed -n '/^  device:pixel@/p')
        case "$pixel" in
          "" | *" — "*) device=fold ;;
          *) device=pixel ;;
        esac
        run "$session" "--need device:$device" "Android $2 on the $device" \
          "python3 -u android-device.py startup $rounds out"
        ;;
    esac
    ;;
  report)
    shift
    ssh studio.local "mkdir -p $stage/report"
    rsync -a "$here/startup.py" "studio.local:$stage/report/"
    for session; do rsync -a --delete "$results/$session/" "studio.local:$stage/report/$session/"; done
    ssh studio.local "cd $stage/report && python3 startup.py report $*"
    ;;
  clean)
    ssh studio.local "rm -rf $stage"
    ;;
  *)
    sed -n '2,14p' "$0" >&2
    exit 2
    ;;
esac
