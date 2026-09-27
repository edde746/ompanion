#!/bin/sh
# Sets up a dedicated server as the ompanion review demo, or brings one up to date. Run it from this Mac with
# SSH access as root (a key, or root's password when asked):
#
#   store/review-demo/provision.sh root@<server>
#
# It reads store/review-demo/.env (REVIEW_PASSWORD, OPENROUTER_API_KEY), copies server.sh, the home template
# and scripts/fetch_omp.sh to /opt/ompanion-demo/src on the server, and runs server.sh there: omp 18.3.1,
# root's password, the model's key, the demo home, and the reset command. The secrets travel inside the
# same stream as the files, never on a command line. It can run again at any time.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ $# -ne 1 ]; then
  echo "usage: $0 root@<server>" >&2
  exit 2
fi
target=$1

if [ ! -f "$here/.env" ]; then
  echo "no store/review-demo/.env: write REVIEW_PASSWORD and OPENROUTER_API_KEY into it (README.md)" >&2
  exit 1
fi
# shellcheck source=/dev/null  # gitignored, written by hand
. "$here/.env"
[ -n "${REVIEW_PASSWORD:-}" ] || { echo "REVIEW_PASSWORD is empty in store/review-demo/.env" >&2; exit 1; }
[ -n "${OPENROUTER_API_KEY:-}" ] || { echo "OPENROUTER_API_KEY is empty in store/review-demo/.env" >&2; exit 1; }

bundle=$(mktemp -d)
trap 'rm -rf "$bundle"' EXIT
mkdir -p "$bundle/scripts" "$bundle/store/review-demo"
cp "$repo/scripts/fetch_omp.sh" "$bundle/scripts/"
cp "$here/server.sh" "$here/restore-home.sh" "$bundle/store/review-demo/"
cp -R "$here/home-template" "$bundle/store/review-demo/"
(
  umask 077
  printf 'REVIEW_PASSWORD=%s\nOPENROUTER_API_KEY=%s\n' "$REVIEW_PASSWORD" "$OPENROUTER_API_KEY" >"$bundle/secrets.env"
)

# COPYFILE_DISABLE and --no-xattrs keep macOS's tar from adding ._ files and extended attributes. On the
# server, --no-same-owner makes root own the files: git refuses a repository another user owns.
COPYFILE_DISABLE=1 tar --no-xattrs -C "$bundle" -czf - . |
  ssh "$target" 'set -e; umask 077; rm -rf /opt/ompanion-demo/src; mkdir -p /opt/ompanion-demo/src;
    tar --no-same-owner -xzf - -C /opt/ompanion-demo/src; sh /opt/ompanion-demo/src/store/review-demo/server.sh'

host=${target#*@}
echo
echo "The review demo is up. The values for the store consoles (store/review-demo/README.md, Console answers):"
echo "  host:     $host"
echo "  port:     22"
echo "  user:     root"
echo "  password: REVIEW_PASSWORD in store/review-demo/.env"
echo "Reset it between reviews with: ssh $target ompanion-demo-reset"
