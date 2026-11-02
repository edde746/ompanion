#!/bin/sh
# Builds the C binding (../capi) for Linux and Windows in a throwaway golang container, with real cross C compilers:
#   build/core/linux-arm64/libompcore.so, linux-amd64/libompcore.so, windows-amd64/libompcore.dll
# each next to its libompcore.h, with the root VERSION linked in as core.Version. With --test it also runs
# `go test ./...` on Linux (local exec and PTYs).
set -eu
core=$(cd "$(dirname "$0")/.." && pwd)
out=$(cd "$core/.." && pwd)/build/core
image=golang:1.26.2-bookworm
ldflags="-X ompanion.app/core.Version=$(tr -d '[:space:]' < "$core/../VERSION")"
mkdir -p "$out"
tests=false
[ "${1:-}" = "--test" ] && tests=true

docker run --rm --name "ompcore-capi-$$" \
  -v "$core:/src:ro" -v "$out:/out" -e TESTS="$tests" -e LDFLAGS="$ldflags" "$image" sh -euc '
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross gcc-mingw-w64-x86-64 >/dev/null
    cp -r /src /work && cd /work
    go build -ldflags="$LDFLAGS" -buildmode=c-shared -o /out/linux-$(go env GOARCH)/libompcore.so ./capi
    CGO_ENABLED=1 GOARCH=amd64 CC=x86_64-linux-gnu-gcc go build -ldflags="$LDFLAGS" -buildmode=c-shared \
      -o /out/linux-amd64/libompcore.so ./capi
    CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go build -ldflags="$LDFLAGS" -buildmode=c-shared \
      -o /out/windows-amd64/libompcore.dll ./capi
    CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC=x86_64-w64-mingw32-gcc go vet ./...
    if [ "$TESTS" = true ]; then go vet ./... && go test -count=1 ./...; fi
  '
ls -l "$out"/linux-*/libompcore.so "$out"/windows-*/libompcore.dll
