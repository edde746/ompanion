#!/bin/bash
# Runs the desktop smoke checks (docs/contracts/bridge.md, Smoke runs) of build/windows-x64 (build.sh) on a devpool
# Windows desktop ("host:windows windows desktop": win11-dev, else the PC).
#
#   smoke.sh           on this Mac: stages the build and smoke.ps1 on studio.local (~/ompanion/WindowsShell) and
#                      runs `smoke.sh --lease` there under devpool; the run's files come back to
#                      build/windows-smoke/ (smoke.log with the SMOKE lines, the shell's stderr.txt and
#                      stdout.txt, exit.txt). Prints the SMOKE lines; exits 0 when the app exited 0 and every check passed.
#   smoke.sh --lease   on studio.local, inside the lease: copies the build to $DEVPOOL_HOST, runs smoke.ps1 there over
#                      SSH (it starts the app in the console session), fetches the run's files and cleans the host up.
set -euo pipefail
stage=ompanion/WindowsShell # on studio.local, under the home folder
remote=ompanion-smoke       # on the Windows host, under the user's home folder
ssh_opts=(-o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

if [[ ${1:-} == --lease ]]; then
  cd "$HOME/$stage"
  rm -rf out app.tar
  COPYFILE_DISABLE=1 tar -cf app.tar -C app .
  # OpenSSH's shell on devpool's Windows hosts is Windows PowerShell 5.1.
  ssh_() { ssh "${ssh_opts[@]}" "$DEVPOOL_HOST" "$@"; }
  cleanup() { ssh_ "powershell -NoProfile -ExecutionPolicy Bypass -File $remote/smoke.ps1 -Cleanup"; }
  ssh_ "if (Test-Path $remote) { Remove-Item -Recurse -Force $remote }; New-Item -ItemType Directory $remote | Out-Null"
  trap cleanup EXIT
  scp -q "${ssh_opts[@]}" app.tar smoke.ps1 "$DEVPOOL_HOST:$remote/"
  status=0
  ssh_ "powershell -NoProfile -ExecutionPolicy Bypass -File $remote/smoke.ps1" || status=$?
  scp -q -r "${ssh_opts[@]}" "$DEVPOOL_HOST:$remote/out" .
  exit "$status"
fi

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
build="$repo/build/windows-x64"
out="$repo/build/windows-smoke"
if [[ ! -f $build/ompanion.exe || ! -f $build/ui/index.html ]]; then
  echo "smoke.sh: no build in $build: run build.sh first" >&2
  exit 1
fi

ssh "${ssh_opts[@]}" studio.local "mkdir -p $stage/app && rm -rf $stage/out"
rsync -a --delete "$build/" "studio.local:$stage/app/"
rsync -a "$here/smoke.sh" "$here/smoke.ps1" "studio.local:$stage/"
rm -rf "$out"
mkdir -p "$out"
# The verdict comes from the run's files below; devpool's RESULT line says why there are none.
ssh "${ssh_opts[@]}" studio.local "export PATH=\$HOME/.local/bin:/opt/homebrew/bin:\$PATH DEVPOOL_AGENT=ompanion-WindowsShell;
  devpool run --need 'host:windows windows desktop' --max-wait 10m --what 'ompanion: Windows shell smoke' \
    -- bash $stage/smoke.sh --lease" | tee "$out/devpool.txt" || true
if ssh "${ssh_opts[@]}" studio.local "test -d $stage/out"; then
  rsync -a "studio.local:$stage/out/" "$out/"
fi

if [[ -s $out/stderr.txt ]]; then
  echo "--- the app's stderr ($out/stderr.txt):"
  cat "$out/stderr.txt"
  echo ---
fi
if [[ ! -f $out/smoke.log ]]; then
  echo "smoke.sh: no smoke.log came back: $(grep '^RESULT:' "$out/devpool.txt" || echo 'devpool printed no RESULT line')" >&2
  exit 1
fi
grep -E '^(SMOKE|shell timing)' "$out/smoke.log" || echo "smoke.sh: smoke.log has no SMOKE lines"
exit_code=$(tr -d ' \r\n' <"$out/exit.txt" 2>/dev/null || echo none)
done_line=$(grep -E '^SMOKE-DONE ' "$out/smoke.log" || true)
counts='"passed": *([0-9]+), *"total": *([0-9]+)'
if [[ $exit_code == 0 && $done_line =~ $counts && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" &&
  ${BASH_REMATCH[2]} -gt 0 ]]; then
  echo "smoke.sh: every check passed"
  exit 0
fi
echo "smoke.sh: failed (app exit: $exit_code; ${done_line:-no SMOKE-DONE line})" >&2
exit 1
