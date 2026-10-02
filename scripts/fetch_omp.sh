#!/bin/sh
# Downloads omp release binaries into .tools/omp/<version>/, where the tests and harness/ scripts find
# them, and checks each against the release's SHA256SUMS.txt. The version is $OMP_VERSION, else the one the
# tests run by default (harness/omp-version):
#
#   scripts/fetch_omp.sh <platform-arch>...     e.g. darwin-arm64 linux-x64 linux-arm64 windows-x64
#   OMP_VERSION=18.3.1 scripts/fetch_omp.sh darwin-arm64
#
# A binary already present with the right checksum is kept. A download that does not match is deleted
# and the script exits 1.
set -eu

if [ $# -eq 0 ]; then
  echo "usage: $0 <platform-arch>...   e.g. darwin-arm64 linux-x64" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/.." && pwd)
version=${OMP_VERSION:-$(tr -d '[:space:]' <"$root/harness/omp-version")}
release="https://github.com/can1357/oh-my-pi/releases/download/v$version"
dir="$root/.tools/omp/$version"
mkdir -p "$dir"

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

sums="$dir/SHA256SUMS.txt"
if [ ! -s "$sums" ]; then
  curl -fsSL --retry 3 -o "$sums.part" "$release/SHA256SUMS.txt"
  mv "$sums.part" "$sums"
fi

for target in "$@"; do
  asset=omp-$target
  expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$sums")
  if [ -z "$expected" ]; then
    # Windows assets carry .exe.
    asset=$asset.exe
    expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$sums")
  fi
  if [ -z "$expected" ]; then
    echo "omp $version has no asset for $target (see $sums)" >&2
    exit 1
  fi
  file="$dir/$asset"
  if [ -f "$file" ] && [ "$(sha256 "$file")" = "$expected" ]; then
    echo "$asset: present"
    continue
  fi
  curl -fsSL --retry 3 -o "$file.part" "$release/$asset"
  actual=$(sha256 "$file.part")
  if [ "$actual" != "$expected" ]; then
    rm -f "$file.part"
    echo "$asset: SHA-256 mismatch, expected $expected, got $actual" >&2
    exit 1
  fi
  chmod 755 "$file.part"
  mv "$file.part" "$file"
  echo "$asset: downloaded"
done
