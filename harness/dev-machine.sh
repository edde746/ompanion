#!/bin/sh
# Prepares a local dev machine for the app: an isolated omp home wired to the fake provider on
# 127.0.0.1:<port> (omp-home.sh), `<home>/.local/bin/omp` linked to the repository's pinned omp, and
# `<home>/demo-project/README.md`, the file the fake provider's `--demo` rotation reads and edits.
#
#   harness/dev-machine.sh <home> <port>
#
# Prints `HOME=<home>` and `OMP=<home>/.local/bin/omp` with absolute paths. Safe to run again: it
# rewrites the config and the link and keeps an existing demo project.
set -eu

if [ $# -ne 2 ]; then
	echo "usage: $0 <home> <port>" >&2
	exit 2
fi
harness=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)-$(uname -m)" in
Darwin-arm64) platform=darwin-arm64 ;;
Linux-aarch64 | Linux-arm64) platform=linux-arm64 ;;
Linux-x86_64) platform=linux-x64 ;;
*)
	echo "no pinned omp binary for $(uname -s) $(uname -m)" >&2
	exit 1
	;;
esac
omp=$(dirname "$harness")/.tools/omp/18.3.1/omp-$platform
if [ ! -x "$omp" ]; then
	echo "omp binary missing: $omp" >&2
	exit 1
fi

sh "$harness/omp-home.sh" "$1" "$2"
home=$(cd "$1" && pwd)
# The app may start omp without --model; the default role keeps it on the fake provider.
printf 'modelRoles:\n  default: fake/fake-1\n' >>"$home/.omp/agent/config.yml"
mkdir -p "$home/.local/bin" "$home/demo-project"
ln -sfn "$omp" "$home/.local/bin/omp"
if [ ! -f "$home/demo-project/README.md" ]; then
	cat >"$home/demo-project/README.md" <<'EOF'
# Demo project

Scratch directory for ompanion's dev machine. The fake provider's `--demo` rotation reads this file and
toggles a marker on its first line.
EOF
fi
echo "HOME=$home"
echo "OMP=$home/.local/bin/omp"
