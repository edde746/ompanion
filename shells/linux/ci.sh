#!/bin/sh
# Smoke-runs a build.sh build on this Linux host (a CI runner) with the checks that need a person driven
# (docs/contracts/bridge.md, Smoke runs): `paths` (a file manager's copy through xclip, the open panels through
# xdotool, a drag from another app), and with --seed `flutter-import` of the Flutter seed's data
# (harness/flutter-seed). With --flatpak it then checks the installed Flatpak and smoke-runs it in its sandbox
# (flatpak/check-flatpak.sh). Everything runs in a session of its own: a D-Bus session bus with an unlocked
# gnome-keyring, Xvfb, and XDG data, cache and config directories in a temporary folder that is removed afterwards.
#   shells/linux/ci.sh [--seed <seed bundle dir>] [--flatpak] <app dir> <out dir>
# <out dir> gets host/ and flatpak/ (smoke.log, app.log, screenshot.png each); for --flatpak it must be under $HOME,
# where the sandbox reaches it. Needs xvfb xauth dbus gnome-keyring libsecret-tools xdotool xclip python3-gi
# gir1.2-gtk-3.0 x11-apps netpbm, and the app's libraries (libgtk-4-1 libwebkitgtk-6.0-4 libsecret-1-0 bubblewrap
# xdg-dbus-proxy).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
usage() {
  echo "usage: ci.sh [--seed <seed bundle dir>] [--flatpak] <app dir> <out dir>" >&2
  exit 2
}

if [ -z "${OMPANION_CI_WORK:-}" ]; then
  work=$(mktemp -d)
  mkdir -p "$work/data" "$work/cache" "$work/config"
  # The user's Flatpak installation stays where it is.
  export FLATPAK_USER_DIR="${FLATPAK_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/flatpak}"
  export OMPANION_CI_WORK="$work" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache" XDG_CONFIG_HOME="$work/config"
  status=0
  dbus-run-session -- xvfb-run -a -s "-screen 0 1280x860x24" "$0" "$@" || status=$?
  rm -rf "$work"
  exit "$status"
fi

seed=
flatpak=false
while [ $# -gt 2 ]; do
  case $1 in
    --seed) [ $# -ge 4 ] || usage; seed=$(cd "$2" && pwd); shift 2 ;;
    --flatpak) flatpak=true; shift ;;
    *) usage ;;
  esac
done
[ $# -eq 2 ] || usage
app=$(cd "$1" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
work=$OMPANION_CI_WORK
printf ompanion | gnome-keyring-daemon --unlock --components=secrets >/dev/null
data=$XDG_DATA_HOME/com.edde746.ompanion
account=com.edde746.ompanion.secureStorage
# The Flutter app's one secure-storage item.
items() { secret-tool search --all account "$account" 2>&1 | grep -c '^label' || true; }

if [ -n "$seed" ]; then
  timeout 120 "$seed/ompanion" >"$out/seed.txt" 2>&1 || true
  grep '^SEEDED' "$out/seed.txt" || { cat "$out/seed.txt" >&2; exit 1; }
  echo "seed: $(items) secure-storage item(s), $(ls "$data")"
fi

# The paths check's files, the first two copied as a file manager copies them.
paths=$work/paths
mkdir -p "$paths/sub"
echo a >"$paths/a.txt"
echo b >"$paths/b.txt"
printf 'copy\nfile://%s/a.txt\nfile://%s/sub' "$paths" "$paths" | xclip -selection clipboard -t x-special/gnome-copied-files
# Files before folders in the open panels, whatever GTK's default, for the keys below.
mkdir -p "$XDG_CONFIG_HOME/glib-2.0/settings"
printf '[org/gtk/gtk4/settings/file-chooser]\nsort-directories-first=false\n' >"$XDG_CONFIG_HOME/glib-2.0/settings/keyfile"

# choose <keys>: types <keys> into the open panel once it is up, its list in focus.
choose() {
  panel=$(timeout 30 xdotool search --sync --onlyvisible --name '^(Pick|Select) ')
  xdotool windowfocus --sync "$panel"
  sleep 1.5
  # shellcheck disable=SC2086 # one key per word
  xdotool key --delay 300 $1
}
# A drag from another app: a GTK 3 window offering the files as a URI list, dragged from onto the app's window.
drag() {
  cat >"$work/drag.py" <<'EOF'
import sys
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gdk, Gtk

uris = [GLib.filename_to_uri(path) for path in sys.argv[1:]]
window = Gtk.Window(title="ompanion drag source")
window.set_default_size(200, 200)
window.move(0, 0)
source = Gtk.EventBox()
source.add(Gtk.Label(label="drag"))
source.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [], Gdk.DragAction.COPY)
source.drag_source_add_uri_targets()
source.connect("drag-data-get", lambda widget, context, data, info, time: data.set_uris(uris))
source.connect("drag-end", lambda *args: Gtk.main_quit())
window.add(source)
window.show_all()
Gtk.main()
EOF
  python3 "$work/drag.py" "$paths/a.txt" "$paths/sub" &
  timeout 30 xdotool search --sync --onlyvisible --name '^ompanion drag source$' >/dev/null
  sleep 0.5
  # The app reads the dragged list while it hovers: the later moves come after it has.
  xdotool mousemove 100 100 mousedown 1 sleep 0.3 mousemove 130 130 sleep 0.3 mousemove 600 400 sleep 1 \
    mousemove 620 420 sleep 0.5 mousemove 640 440 sleep 0.5 mouseup 1
}
# Acts on each SMOKE-STEP line of the paths check once.
steps() {
  done=" "
  while :; do
    for step in $(sed -n 's/^SMOKE-STEP //p' "$out/host/smoke.log" 2>/dev/null); do
      case $done in *" $step "*) continue ;; esac
      done="$done$step "
      echo "step $step"
      case $step in
        pick-files) choose 'Home shift+Down Return' ;;
        pick-folder) choose 'End alt+s' ;;
        drop) drag ;;
        *) echo "ci.sh: unknown step $step" >&2 ;;
      esac
    done
    sleep 0.2
  done
}

rm -rf "$out/host"
steps &
watcher=$!
status=0
GSETTINGS_BACKEND=keyfile OMPCORE_SMOKE_PATHS=$paths \
  OMPCORE_EXPECT_IMPORT=${seed:+$repo/harness/flutter-seed/expected.json} \
  "$here/smoke-run.sh" "$app" "$out/host" || status=$?
kill "$watcher"
grep -E '^(SMOKE|shell timing)' "$out/host/smoke.log"
grep -q '^SMOKE {"check":"paths","pass":true,"ms":[0-9]*,"clipboard"' "$out/host/smoke.log" ||
  { echo "ci.sh: the paths check did not run" >&2; status=1; }
if [ -n "$seed" ]; then
  echo "after the import: $(items) secure-storage item(s), $(ls "$data" | tr '\n' ' ')"
  grep -q '^SMOKE {"check":"flutter-import","pass":true,"ms":[0-9]*,"documents"' "$out/host/smoke.log" &&
    [ "$(items)" = 0 ] && [ -f "$data/ompanion.sqlite.imported" ] && [ ! -e "$data/ompanion.sqlite" ] ||
    { echo "ci.sh: the Flutter import did not leave what it should" >&2; status=1; }
fi

if [ "$flatpak" = true ]; then
  [ ! -e "$HOME/.var/app/com.edde746.ompanion" ] ||
    { echo "ci.sh: $HOME/.var/app/com.edde746.ompanion is there already; the Flatpak was not run" >&2; exit 1; }
  "$here/flatpak/check-flatpak.sh" --smoke "$out/flatpak" || status=$?
  rm -rf "$HOME/.var/app/com.edde746.ompanion"
fi
exit "$status"
