#!/bin/sh
# Runs build.sh's linux or windows seed on this host (a CI runner, a Docker container), shows what it wrote and removes
# all of it (README.md):
#   run-host.sh linux <bundle dir> [--db <file>]      (build.sh linux prints the bundle dir)
#   run-host.sh windows <Release dir> [--db <file>]   (build.sh windows prints the Release dir; run from Git Bash)
# It first checks that no com.edde746.ompanion data is on the host and stops if there is. --db copies the database
# the seed wrote to <file> before the cleanup. Linux needs a secret service and a display: without a session bus the
# script starts one with gnome-keyring in it, and Xvfb when there is no display.
set -eu

fail() {
  echo "run-host.sh: $*" >&2
  exit 1
}
usage() { fail "usage: run-host.sh <linux|windows> <bundle dir> [--db <file>]"; }
[ $# -eq 2 ] || [ $# -eq 4 ] || usage
platform=$1
bundle=$(cd "$2" && pwd)
db=
if [ $# -eq 4 ]; then
  [ "$3" = --db ] || usage
  db=$4
fi

case $platform in
  linux)
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      exec dbus-run-session -- sh -c 'printf seed | gnome-keyring-daemon --unlock --components=secrets > /dev/null &&
        exec "$0" "$@"' "$0" "$@"
    fi
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then exec xvfb-run -a "$0" "$@"; fi
    data=${XDG_DATA_HOME:-$HOME/.local/share}/com.edde746.ompanion
    seed=$bundle/ompanion
    account=com.edde746.ompanion.secureStorage
    secrets() { secret-tool search --all account "$account" 2>&1 | grep -E '^(label|attribute\.account) = ' || true; }
    ;;
  windows)
    data=$(cygpath -u "$APPDATA")/com.edde746/ompanion
    seed=$bundle/ompanion.exe
    secrets() { [ ! -e "$data/flutter_secure_storage.dat" ] || echo "secrets file: $data/flutter_secure_storage.dat"; }
    ;;
  *) usage ;;
esac

# rows <db>: the row count of each table and the machines, with sqlite3 or else Python.
rows() {
  query=
  for table in machines machine_jumps ssh_keys known_hosts settings read_markers pinned_sessions; do
    query="${query:+$query union all }select 'rows $table: ' || count(*) from $table"
  done
  query="$query union all select id || ' | ' || kind || ' | ' || name || ' | ' || created_at from machines"
  if command -v sqlite3 > /dev/null; then
    sqlite3 "$1" "$query"
  else
    python=$(command -v python3 || command -v python)
    # Windows' Python writes the console code page otherwise, which lacks the data's non-ASCII names.
    PYTHONIOENCODING=utf-8 "$python" -c \
      'import sqlite3, sys; [print(row[0]) for row in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]' "$1" "$query"
  fi
}

# result <file>: the seed's result line in <file>; fails unless it is SEEDED or CLEANED.
result() {
  line=$(tr -d '\r' < "$1" | grep -E '^(SEEDED|CLEANED|SEED-FAILED) ' | tail -n 1)
  echo "${line:-no result line in $1}"
  case $line in SEEDED* | CLEANED*) ;; *) cat "$1" >&2; return 1 ;; esac
}

if [ -e "$data" ] || [ -n "$(secrets)" ]; then
  fail "com.edde746.ompanion data or secure-storage entries are already on this host; nothing was run"
fi
echo "before: no '$data', no secure-storage entries"
work=$(mktemp -d)
clean() {
  mkdir -p "$data"
  touch "$data/seed-clean"
  timeout 120 "$seed" > "$work/clean.txt" 2>&1 || true
  result "$work/clean.txt" || true
  # Linux keeps every entry in one item, which the plugin leaves behind holding `{}`.
  [ "$platform" = windows ] || secret-tool clear account "$account" || true
  rm -rf "$data" "$work"
  if [ -e "$data" ] || [ -n "$(secrets)" ]; then
    echo "after: '$data' or a secure-storage entry is left" >&2
  else
    echo "after: no '$data', no secure-storage entries"
  fi
}
trap clean EXIT
timeout 120 "$seed" > "$work/seed.txt" 2>&1 || true
result "$work/seed.txt"
rows "$data/ompanion.sqlite"
secrets
[ -z "$db" ] || cp "$data/ompanion.sqlite" "$db"
