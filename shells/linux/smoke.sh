#!/bin/sh
# Smoke-runs a build.sh build (docs/contracts/bridge.md, Smoke runs) and prints its SMOKE lines and the shell's timing
# line; exits with the app's status.
#   shells/linux/smoke.sh [arch]   in Docker under Xvfb, by default the Docker host's architecture; smoke.log,
#                                  app.log and screenshot.png go to build/linux-<arch>/smoke/
#   shells/linux/smoke.sh --devpool
#                                  on a devpool Linux desktop (--need "host:linux linux desktop") through studio.local,
#                                  in its logged-in session; smoke.log and app.log go to build/linux-devpool/
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "${1:-}" = --devpool ]; then
  stage=ompanion-web/linux-smoke
  ssh studio.local "mkdir -p $stage"
  for arch in arm64 amd64; do
    [ ! -x "$repo/build/linux-$arch/ompanion" ] ||
      rsync -a --delete --exclude smoke/ "$repo/build/linux-$arch/" "studio.local:$stage/linux-$arch/"
  done
  rsync -a "$here/smoke-run.sh" "$here/devpool-run.sh" "studio.local:$stage/"
  status=0
  ssh studio.local "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:\$PATH DEVPOOL_AGENT=${DEVPOOL_AGENT:-ompanion-Linux}
    cd $stage && devpool run --need 'host:linux linux desktop' --what 'ompanion: Linux shell smoke' -- sh devpool-run.sh" ||
    status=$?
  out=$repo/build/linux-devpool
  rm -rf "$out"
  rsync -a "studio.local:$stage/devpool/" "$out/"
  grep -E '^(SMOKE|shell timing)' "$out/smoke.log"
  exit "$status"
fi

arch=${1:-$(docker version --format '{{.Server.Arch}}')}
app=$repo/build/linux-$arch
[ -x "$app/ompanion" ] || { echo "smoke.sh: no build in $app: run build.sh $arch first" >&2; exit 1; }
out=$app/smoke
mkdir -p "$out"
name=ompanion-linux-smoke-$$
trap 'docker rm -f "$name" >/dev/null' EXIT
trap 'exit 130' INT TERM
status=0
# WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS only in this container: WebKit's bubblewrap sandbox cannot nest inside
# Docker's. The app never runs unsandboxed outside it. --init: xvfb-run as PID 1 never sees Xvfb's ready signal. The
# secret check needs an unlocked secret service: gnome-keyring with a login keyring (the default collection) that the
# password on stdin creates and unlocks. dbus-daemon needs a user the container knows, so the run is root's and hands
# the logs to this user afterwards.
docker run --init --name "$name" --platform "linux/$arch" -e OWNER="$(id -u):$(id -g)" \
  -v "$app:/app:ro" -v "$out:/out" -v "$here/smoke-run.sh:/smoke-run.sh:ro" \
  -e WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 -e GTK_A11Y=none -e XDG_RUNTIME_DIR=/tmp/runtime \
  "ompanion-linux:$arch" dbus-run-session -- sh -euc '
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    echo smoke | gnome-keyring-daemon --unlock --components=secrets >/dev/null
    status=0
    xvfb-run -a -s "-screen 0 1280x860x24" /smoke-run.sh /app /out || status=$?
    chown -R "$OWNER" /out
    exit "$status"' ||
  status=$?
grep -E '^(SMOKE|shell timing)' "$out/smoke.log"
[ ! -f "$out/screenshot.png" ] || echo "screenshot: $out/screenshot.png"
exit "$status"
