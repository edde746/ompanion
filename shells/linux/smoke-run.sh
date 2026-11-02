#!/bin/sh
# Runs <app-dir>/ompanion once in smoke mode (docs/contracts/bridge.md, Smoke runs) on the current display and leaves in
# <out-dir>: smoke.log (the SMOKE lines), app.log (the app's stdout and stderr) and, on an X11 display,
# screenshot.png. Exits with the app's status. Used by smoke.sh in Docker and on a devpool desktop.
#   smoke-run.sh <app-dir> <out-dir>
set -eu
app=$1
out=$2
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "smoke-run.sh: no DISPLAY or WAYLAND_DISPLAY" >&2; exit 1; }
mkdir -p "$out"
rm -f "$out/smoke.log" "$out/app.log" "$out/screenshot.png" "$out/screen.xwd" "$out/screen.xwd.new"
shoot=0
[ -n "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && command -v xwd >/dev/null && shoot=1

OMPCORE_SMOKE=1 OMPCORE_LOG="$out/smoke.log" "$app/ompanion" >"$out/app.log" 2>&1 &
pid=$!
# A process that exited lingers as a zombie until wait; once reaped, its /proc entry is gone.
running() { state=$(cut -d' ' -f3 "/proc/$pid/stat" 2>/dev/null) && [ "$state" != Z ]; }
# The display is captured after each new SMOKE line, and continually once SMOKE-DONE is in, until core.exit ends the
# app about 100 ms later; a capture counts only when the app still ran after it.
seen=0
deadline=$(($(date +%s) + 300))
while running; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "smoke-run.sh: no exit after 300 s; killing ompanion" >&2
    kill "$pid"
  fi
  lines=$(cat "$out/smoke.log" 2>/dev/null | wc -l)
  if [ "$shoot" = 1 ] && { [ "$lines" -gt "$seen" ] || grep -qs '^SMOKE-DONE' "$out/smoke.log"; }; then
    seen=$lines
    xwd -root -silent >"$out/screen.xwd.new" && running && mv "$out/screen.xwd.new" "$out/screen.xwd"
  fi
  sleep 0.02
done
status=0
wait "$pid" || status=$?
if [ -f "$out/screen.xwd" ]; then
  xwdtopnm -quiet "$out/screen.xwd" | pamdepth -quiet 255 | pnmtopng -quiet >"$out/screenshot.png"
  rm "$out/screen.xwd"
fi
rm -f "$out/screen.xwd.new"
echo "smoke-run: ompanion exited $status" >&2
exit "$status"
