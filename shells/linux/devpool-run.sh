#!/bin/sh
# Runs on studio.local inside the lease smoke.sh --devpool takes, from the folder it staged: copies the build for
# $DEVPOOL_HOST's architecture into the lease's work directory there, runs smoke-run.sh in the host's logged-in
# desktop session, and copies its logs back to ./devpool/. devpool stops what a run leaves in the work directory.
set -eu
# The PC's CachyOS boot keeps its host key in a known-hosts file of its own.
ssh_() { ssh -o BatchMode=yes -o GlobalKnownHostsFile="$HOME/.ssh/known_hosts.tortuga-linux" "$DEVPOOL_HOST" "$@"; }
scp_() { scp -q -r -o BatchMode=yes -o GlobalKnownHostsFile="$HOME/.ssh/known_hosts.tortuga-linux" "$@"; }
case $(ssh_ uname -m) in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "devpool-run.sh: $DEVPOOL_HOST has an architecture without a build" >&2; exit 1 ;;
esac
[ -d "linux-$arch" ] || { echo "devpool-run.sh: no linux-$arch build staged: run build.sh $arch" >&2; exit 1; }
work=$DEVPOOL_WORKDIR
# The desktop is a person's: run only where no ompanion keeps data, and keep the run's own in the work directory.
ssh_ "test ! -e \"\${XDG_DATA_HOME:-\$HOME/.local/share}/com.edde746.ompanion\" && test ! -e \"\$HOME/.var/app/com.edde746.ompanion\"" ||
  { echo "devpool-run.sh: $DEVPOOL_HOST holds com.edde746.ompanion data; nothing was run" >&2; exit 1; }
ssh_ "mkdir -p '$work'"
scp_ "linux-$arch" smoke-run.sh "$DEVPOOL_HOST:$work/"
status=0
# The session's environment (display, bus) from the user's systemd manager, where the desktop imports it at login.
ssh_ "cd '$work' && env \$(systemctl --user show-environment |
  grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP)=') \
  OMPCORE_DATA_DIR='$work/data' OMPCORE_CACHE_DIR='$work/cache' sh smoke-run.sh 'linux-$arch' out" || status=$?
rm -rf devpool
scp_ "$DEVPOOL_HOST:$work/out" devpool
exit "$status"
