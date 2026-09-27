#!/bin/sh
# The demo server's reset command, installed by provision.sh as /usr/local/sbin/ompanion-demo-reset. Puts
# root's home back the way provision.sh built it: omp's config (the model and its key), the demo project with
# its git history and the reviewer's README. Reviewer edits, sessions and the uploaded companion go, and the
# omp runs the app started are stopped. SSH keys, shell startup files and everything outside the demo's own
# paths are left alone, so the server does not look new to the app.
set -eu

template=/opt/ompanion-demo/home
[ -d "$template" ] || { echo "ompanion-demo-reset: no template at $template: run provision.sh" >&2; exit 1; }

# A run the app started is omp under a shell script in ~/.ompanion/run; stopping omp ends the run.
pkill -x omp 2>/dev/null || true
pkill -f /root/.ompanion 2>/dev/null || true
sleep 1

cd /root
rm -rf /root/.omp /root/.ompanion /root/work /root/README.md
cp -a "$template"/. /root/

echo "ompanion-demo-reset: root's home restored from $template"
