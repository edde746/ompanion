#!/bin/bash
# Signs a Flutter macOS app bundle inside-out, the way the notary service wants it. macOS only (codesign,
# BSD find, `sort -z`), and bash for `read -d ''`, which is how the NUL-separated paths are iterated:
#
#   scripts/sign_app.sh <identity> <app-bundle> <entitlements>
#
# <identity> is a Developer ID Application keychain identity, or `-` for an ad-hoc signature (a local
# release build: `scripts/sign_app.sh - build/macos/Build/Products/Release/ompanion.app macos/Runner/Release.entitlements`).
# The app bundle itself is signed last, with <entitlements>. Nested code gets none, except Sparkle's
# Downloader.xpc, which keeps whatever Sparkle signed it with.
set -eu

if [ $# -ne 3 ]; then
  echo "usage: $0 <identity|-> <app-bundle> <entitlements>" >&2
  exit 2
fi

identity=$1
app=$2
entitlements=$3
[ -d "$app" ] || { echo "no such app bundle: $app" >&2; exit 1; }
[ -f "$entitlements" ] || { echo "no such entitlements file: $entitlements" >&2; exit 1; }

# sign [codesign option...] <path>: hardened runtime and a secure timestamp on every piece of code, both of which
# the notary service requires.
sign() {
  echo "Signing ${!#}"
  codesign --force --sign "$identity" --options runtime --timestamp "$@"
}

# Sparkle's helpers, in the order its documentation signs them for distribution outside Xcode's archive and
# export (https://sparkle-project.org/documentation/sandboxing/#code-signing): Autoupdate is a bare executable
# inside the framework, which the loops below never reach, and Downloader.xpc keeps its entitlements. The
# framework is signed last, so its seal covers the re-signed helpers.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$sparkle" ]; then
  sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  sign "$sparkle/Versions/B/Autoupdate"
  sign "$sparkle/Versions/B/Updater.app"
  sign "$sparkle"
fi

# The other nested bundles and libraries first, so an enclosing bundle's signature seals a finished copy.
# Reverse path order puts a framework's dylibs before the framework that contains them. Never --deep: it
# would re-sign a bundle's contents with that bundle's options and leave the outer seal stale.
find "$app/Contents" -path "$sparkle" -prune -o \
  \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.dylib" \) -print0 \
  | sort -zr \
  | while IFS= read -r -d '' item; do
      sign "$item"
    done

# Loose executables outside any bundle (a helper a plugin ships). Pruning the bundles keeps their seals
# intact; `file` skips the shell scripts some bundles carry, which codesign refuses to sign.
find "$app/Contents" \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" \) -prune -o -type f -perm -111 ! -name "*.dylib" -print0 \
  | while IFS= read -r -d '' exe; do
      file "$exe" | grep -q "Mach-O" || continue
      sign "$exe"
    done

sign --entitlements "$entitlements" "$app"
