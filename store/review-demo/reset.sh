#!/bin/sh
# Puts the reviewer's home back the way the image ships it (restore-home.sh in the container): edits,
# extra files, sessions and the uploaded companion are removed, running omp processes stop, and the demo
# project returns with its git history. The host keys stay, so the machine does not look new to the app.
#
# The app's open session closes when its omp process is stopped; reconnect or open a new one afterwards.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if [ ! -f .env ]; then
  echo "no .env: run ./setup.sh first" >&2
  exit 1
fi

docker compose --env-file .env exec -T host /usr/local/bin/restore-home.sh
# Restart the provider too, so the demo's rotation starts at its first scenario again and a reviewer sees
# the same sequence the notes describe.
docker compose --env-file .env restart provider
docker compose --env-file .env up -d --wait provider
