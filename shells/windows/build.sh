#!/bin/sh
# Cross-builds the Windows app in Docker with llvm-mingw (Dockerfile): build/windows-<arch>/ gets ompanion.exe,
# libompcore.dll (core/capi, c-shared), WebView2Loader.dll, app_icon.ico (resources/, for toasts) and ui/ (a copy of
# ui/dist, which must be built first, with the licences of the core's Go modules, the WebView2 SDK and the toolchain's
# statically linked runtimes added by core/cmd/licenses). Arches: x64 (the default) and arm64, e.g.
# `build.sh x64 arm64`. Intermediates (the WebView2 NuGet package, Go caches, CMake builds) stay in build/windows/.
# msix/build-msix.ps1 packs the result.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd) # mounted whole: the build reads VERSION, core/ and shells/windows/ and writes build/
work="$repo/build/windows"
image=ompanion-windows-build
webview2_version=1.0.4314.35
webview2_sha256=90778deb1b77e36292828b4b5833c9255c27533f40e0ddd55891ae718944edc4
[ $# -gt 0 ] || set -- x64

if [ ! -f "$repo/ui/dist/index.html" ]; then
  echo "build.sh: $repo/ui/dist/index.html is missing: build the UI first" >&2
  exit 1
fi

package="$work/nuget/microsoft.web.webview2.$webview2_version.nupkg"
if [ ! -f "$package" ]; then
  mkdir -p "$work/nuget"
  curl -fsSL -o "$package.part" \
    "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$webview2_version/microsoft.web.webview2.$webview2_version.nupkg"
  mv "$package.part" "$package"
fi
echo "$webview2_sha256  $package" | shasum -a 256 -c - >/dev/null
rm -rf "$work/webview2"
unzip -q "$package" 'build/native/*' LICENSE.txt '*.nuspec' -d "$work/webview2"

docker build -q -t "$image" "$here" >/dev/null

for arch in "$@"; do
  case $arch in
    x64) goarch=amd64 cpu=x86_64 ;;
    arm64) goarch=arm64 cpu=aarch64 ;;
    *) echo "build.sh: unknown arch $arch (x64, arm64)" >&2; exit 2 ;;
  esac
  out="$repo/build/windows-$arch"
  rm -rf "$out"
  mkdir -p "$out"
  cp -R "$repo/ui/dist" "$out/ui"
  docker run --rm --user "$(id -u):$(id -g)" -v "$repo:/repo" -w /repo/core \
    -e HOME=/tmp -e GOTOOLCHAIN=local -e GOFLAGS=-trimpath \
    -e GOCACHE=/repo/build/windows/cache/go-build -e GOMODCACHE=/repo/build/windows/cache/go-mod \
    -e CGO_ENABLED=1 -e GOOS=windows -e GOARCH="$goarch" -e CC="$cpu-w64-mingw32-clang" \
    "$image" sh -euc '
      arch=$1 cpu=$2
      work=/repo/build/windows
      core=$work/core-$arch
      mkdir -p "$core"
      # core.info.version is VERSION as it is, linked in.
      version=$(tr -d "[:space:]" < /repo/VERSION)
      go build -buildmode=c-shared \
        -ldflags="-s -w -X ompanion.app/core.Version=$version -extldflags=-Wl,--out-implib,$core/libompcore.dll.a" \
        -o "$core/libompcore.dll" ./capi
      cmake -S /repo/shells/windows -B "$work/cmake-$arch" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR="$cpu" -DCMAKE_CXX_COMPILER="$cpu-w64-mingw32-clang++" \
        -DCMAKE_RC_COMPILER="$cpu-w64-mingw32-windres" \
        -DWEBVIEW2_DIR="$work/webview2" -DOMPCORE_DIR="$core" >/dev/null
      cmake --build "$work/cmake-$arch"
      # The generator runs for this machine, not for Windows. -static links the C++ runtime of LLVM (into the exe) and
      # the mingw-w64 runtime (into both); llvm-mingw installs their licences.
      GOOS= GOARCH= CGO_ENABLED=0 go run ./cmd/licenses -ui "/repo/build/windows-$arch/ui" -target windows \
        -nuget "$work/webview2" \
        -notice "LLVM libc++, libc++abi, libunwind and compiler-rt@$("$cpu-w64-mingw32-clang" -dumpversion)=/opt/llvm-mingw/LICENSE.TXT" \
        -notice "mingw-w64 runtime=/opt/llvm-mingw/$cpu-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt"
    ' sh "$arch" "$cpu"

  cp "$work/cmake-$arch/ompanion.exe" "$work/core-$arch/libompcore.dll" "$out/"
  cp "$work/webview2/build/native/$arch/WebView2Loader.dll" "$out/"
  cp "$here/resources/app_icon.ico" "$out/"
  echo "$out"
done
