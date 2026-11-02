#!/usr/bin/env bash
# Checks the installed com.edde746.ompanion inside its sandbox, against the runtime users get instead of this
# machine's libraries: every ELF file resolves all of its libraries, release-tty is in place, the page is there, and
# this computer's processes can start on the host (core/exec.go, flatpakStart). With --smoke it then smoke-runs the app
# in the sandbox (../smoke-run.sh; docs/contracts/bridge.md, Smoke runs), which needs a display and an unlocked secret
# service, and leaves smoke.log, app.log and screenshot.png in <out-dir>, a directory the sandbox reaches (under
# $HOME). Run it after
#
#   flatpak install --user build/ompanion-linux-<arch>.flatpak
#
# and without a desktop session under `dbus-run-session --`: flatpak-spawn reaches the host through the session bus.
#
#   shells/linux/flatpak/check-flatpak.sh [--smoke <out-dir>]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
app_id=com.edde746.ompanion
out=
case "$#:${1:-}" in
  0:) ;;
  2:--smoke) mkdir -p "$2" && out=$(cd "$2" && pwd) ;;
  *) echo "usage: check-flatpak.sh [--smoke <out-dir>]" >&2; exit 2 ;;
esac

# shellcheck disable=SC2016 # the script expands inside the sandbox
flatpak run --user --command=bash "$app_id" -c '
set -euo pipefail
count=0
while IFS= read -r -d "" file; do
  [[ $(od -An -tx1 -N4 "$file") == *"7f 45 4c 46"* ]] || continue
  libraries=$(ldd "$file" 2>&1) || { printf "%s:\n%s\n" "$file" "$libraries" >&2; exit 1; }
  if [[ $libraries == *"not found"* ]]; then
    printf "%s:\n%s\n" "$file" "$libraries" >&2
    exit 1
  fi
  count=$((count + 1))
done < <(find /app -type f -print0)
[ "$count" -gt 0 ]
echo "$count ELF files resolve every library in the runtime"

test -x /app/libexec/release-tty
test -f /app/ompanion/ui/index.html
[ "$(flatpak-spawn --host sh -c "test -e /.flatpak-info || echo host")" = host ]
echo "flatpak-spawn --host starts processes outside the sandbox"
'

[ -n "$out" ] || exit 0
launcher=$(mktemp -d)
trap 'rm -rf "$launcher"' EXIT
printf '#!/bin/sh\nexec flatpak run --user %s "$@"\n' "$app_id" >"$launcher/ompanion"
chmod +x "$launcher/ompanion"
status=0
"$here/../smoke-run.sh" "$launcher" "$out" || status=$?
grep -E '^(SMOKE|shell timing)' "$out/smoke.log"
exit "$status"
