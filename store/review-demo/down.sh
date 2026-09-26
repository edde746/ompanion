#!/bin/sh
# Stops the review demo. The reviewer's home, their sessions and the host keys stay in the `review-data`
# volume; `--clean` deletes that volume, and with it the home and the host keys (run it after the review,
# before you destroy the VPS).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

compose() {
  if [ -f .env ]; then
    docker compose --env-file .env "$@"
  else
    docker compose "$@"
  fi
}

case "${1:-}" in
'')
  compose down
  echo "stopped; the reviewer's home stays in the review-data volume (./down.sh --clean deletes it)"
  ;;
--clean)
  compose down --volumes
  echo "stopped and the review-data volume (reviewer's home, host keys) is deleted"
  ;;
*)
  echo "usage: $0 [--clean]" >&2
  exit 2
  ;;
esac
