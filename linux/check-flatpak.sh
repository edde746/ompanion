#!/usr/bin/env bash
# Checks the installed com.edde746.ompanion inside its sandbox, against the runtime users get instead of this
# machine's libraries: every ELF file resolves all of its libraries, and this computer's processes can start on the
# host (hostStart in packages/omp_core). Run it after
#
#   flatpak install --user build/linux/ompanion-linux-<arch>.flatpak
#
# and without a desktop session under `dbus-run-session --`: flatpak-spawn reaches the host through the session bus.
set -euo pipefail

# shellcheck disable=SC2016 # the script expands inside the sandbox
flatpak run --user --command=bash com.edde746.ompanion -c '
set -euo pipefail
# The runner finds its libraries through its RUNPATH; plugin libraries need their directory named.
export LD_LIBRARY_PATH=/app/ompanion/lib
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
[ "$(flatpak-spawn --host sh -c "test -e /.flatpak-info || echo host")" = host ]
echo "flatpak-spawn --host starts processes outside the sandbox"
'
