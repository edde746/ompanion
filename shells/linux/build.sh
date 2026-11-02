#!/bin/sh
# Builds the Linux shell in Docker (Ubuntu 24.04, ./Dockerfile) for each architecture given, by default the Docker
# host's: build/linux-<arch>/ holds ompanion, libompcore.so (core/capi, cgo), ui/ (a copy of ui/dist, with the core's
# Go licences added by core/cmd/licenses) and icons/ (the app's icon, shells/linux/ompanion.png). The version is the
# repository's VERSION. Nothing else third-party is bundled: GTK, WebKitGTK, libsecret and the C and C++ runtimes come
# from the system (the Flatpak's from its runtime).
#   shells/linux/build.sh [arm64] [amd64]
# A foreign architecture builds under Docker's emulation. Intermediate files go to build/linux-work/<arch>/, the core
# with its header to build/linux-work/<arch>/core/ (flatpak/build-flatpak.sh builds the shell again against it).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
[ -f "$repo/ui/dist/index.html" ] || { echo "build.sh: $repo/ui/dist/index.html is missing: build the UI first" >&2; exit 1; }
version=$(tr -d '[:space:]' <"$repo/VERSION")
[ $# -gt 0 ] || set -- "$(docker version --format '{{.Server.Arch}}')"
for arch in "$@"; do
  image=ompanion-linux:$arch
  work=/repo/build/linux-work/$arch
  out=$repo/build/linux-$arch
  rm -rf "$out"
  mkdir -p "$out/icons"
  cp -R "$repo/ui/dist" "$out/ui"
  docker build --quiet --platform "linux/$arch" -t "$image" "$here" >/dev/null
  # As this user, so the build's files are theirs on a Linux host too.
  docker run --rm --platform "linux/$arch" --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$repo:/repo" \
    -e GOCACHE="$work/go-cache" -e GOMODCACHE="$work/go-mod" -e GOFLAGS=-modcacherw \
    "$image" sh -euc "
      cd /repo/core
      go build -trimpath -ldflags='-s -w -X ompanion.app/core.Version=$version' -buildmode=c-shared \
        -o '$work/core/libompcore.so' ./capi
      go run ./cmd/licenses -ui /repo/build/linux-$arch/ui -target linux
      cmake -S /repo/shells/linux -B '$work/cmake' -G Ninja -DCMAKE_BUILD_TYPE=Release -DOMPCORE_DIR='$work/core' \
        >/dev/null
      cmake --build '$work/cmake'
      strip '$work/cmake/ompanion'
    "
  cp "$repo/build/linux-work/$arch/cmake/ompanion" "$repo/build/linux-work/$arch/core/libompcore.so" "$out/"
  cp "$here/ompanion.png" "$out/icons/com.edde746.ompanion.png"
  echo "$out"
done
