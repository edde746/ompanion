#!/bin/sh
# Builds the Apple shell into build/apple, with the version from VERSION: by default macos/ompanion.app (ad-hoc signed)
# and ios-simulator/ompanion.app, for arm64. The other products are built only when named:
#   --release    macos-release/ompanion.app: the direct channel's release app, for arm64 and x86_64, ad-hoc signed,
#                Sparkle inside; scripts/sign_app.sh signs it with shells/apple/Entitlements/macOS.entitlements
#   --device     ios-device/ompanion.app, for iPhone and iPad, unsigned (CODE_SIGNING_ALLOWED=NO)
#   --team <id>  with --device: sign it for that development team instead (automatic signing, profiles created or
#                updated by xcodebuild with the Xcode account), so it installs on the team's registered devices:
#                xcrun devicectl device install app --device <udid> build/apple/ios-device/ompanion.app
#   --for <udid> with --team: build for that connected device and register it on the team if it is not yet, so the
#                profile includes it
#   --ipa        ios-archive/ompanion.xcarchive and ipa/ompanion.ipa: the App Store channel's app, archived with
#                automatic signing for the project's team (or --team's; the Xcode account's certificates and profiles)
#                and exported for App Store Connect (ExportOptions.plist)
# The page is ui/dist, unless a channel is named: then build.sh builds it for that channel (VITE_OMPANION_CHANNEL)
# into build/apple/ui, which needs ui/node_modules and ui/companion/ompx.js.
#   --channel <name>  direct, appstore, …; --release implies direct, --ipa appstore. Every macOS build is a direct
#                     one: Sparkle ships in it, and no other macOS channel is built.
#   --core       rebuild Ompcore.xcframework (otherwise only when it is missing)
#   --debug      Debug configuration (the web inspector is on, Sparkle is off) instead of Release
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out="$repo/build/apple"
usage="usage: $0 [--core] [--debug] [--channel <name>] [--release] [--device [--team <id> [--for <udid>]]] [--ipa]"
config=Release
core=
products=
team=
udid=
channel=
implied=
while [ $# -gt 0 ]; do
  case $1 in
    --core) core=1 ;;
    --debug) config=Debug ;;
    --channel) [ $# -ge 2 ] || { echo "build.sh: --channel needs a name" >&2; exit 2; }; channel=$2; shift ;;
    --release) products="$products macos-release" implied="$implied direct" ;;
    --device) products="$products ios-device" ;;
    --ipa) products="$products ipa" implied="$implied appstore" ;;
    --team) [ $# -ge 2 ] || { echo "build.sh: --team needs a team id" >&2; exit 2; }; team=$2; shift ;;
    --for) [ $# -ge 2 ] || { echo "build.sh: --for needs a device id" >&2; exit 2; }; udid=$2; shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
products=${products:-macos ios-simulator}
case $implied in
  *direct*appstore* | *appstore*direct*) echo "build.sh: --release and --ipa are different channels; build them apart" >&2; exit 2 ;;
esac
channel=${channel:-$(echo $implied | cut -d' ' -f1)}
case " $products " in
  *" macos "* | *" macos-release "*)
    if [ -n "$channel" ] && [ "$channel" != direct ]; then
      echo "build.sh: macOS builds are direct builds (Sparkle ships in them), not $channel" >&2
      exit 2
    fi
    ;;
esac

if [ -n "$core" ] || [ ! -d "$repo/build/core/apple/Ompcore.xcframework" ]; then
  "$repo/core/scripts/bind-apple.sh"
fi
mkdir -p "$out"
rm -rf "$out/ui"
if [ -n "$channel" ]; then
  (cd "$repo/ui" && VITE_OMPANION_CHANNEL=$channel bun x vite build --logLevel warn --emptyOutDir --outDir "$out/ui")
else
  if [ ! -f "$repo/ui/dist/index.html" ]; then
    echo "build.sh: $repo/ui/dist/index.html is missing: build the UI first, or name a --channel" >&2
    exit 1
  fi
  cp -R "$repo/ui/dist" "$out/ui"
fi

# VERSION is <semver>+<build>: CFBundleShortVersionString and CFBundleVersion (project.yml).
version=$(cat "$repo/VERSION")
export OMPANION_VERSION="${version%+*}" OMPANION_BUILD="${version#*+}"
cd "$here"
xcodegen generate --quiet
# The licences page's Go and Swift package licences (core/cmd/licenses) go into the page before the builds copy it into
# the apps; the project's packages (every target's) resolve first, into the DerivedData the builds use.
xcodebuild -quiet -resolvePackageDependencies -project ompanion.xcodeproj -scheme ompanion-iOS \
  -derivedDataPath "$out/DerivedData"
(cd "$repo/core" && go run ./cmd/licenses -ui "$out/ui" -target macos -target ios \
  -swiftpm "$out/DerivedData/SourcePackages" -xcodegen "$here/project.yml")
# build <scheme> <destination> <products subdirectory> <output directory> <build setting>…
build() {
  scheme=$1 destination=$2 built=$3 dir=$4
  shift 4
  xcodebuild -quiet -project ompanion.xcodeproj -scheme "$scheme" -configuration "$config" \
    -destination "$destination" -derivedDataPath "$out/DerivedData" "$@" build
  rm -rf "${out:?}/$dir"
  mkdir -p "$out/$dir"
  ditto "$out/DerivedData/Build/Products/$built/ompanion.app" "$out/$dir/ompanion.app"
  echo "$out/$dir/ompanion.app"
}
for product in $products; do
  case $product in
    macos) build ompanion-macOS 'generic/platform=macOS' "$config" macos ARCHS=arm64 ;;
    ios-simulator) build ompanion-iOS 'generic/platform=iOS Simulator' "$config-iphonesimulator" ios-simulator ARCHS=arm64 ;;
    macos-release)
      build ompanion-macOS 'generic/platform=macOS' "$config" macos-release 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO
      ;;
    ios-device)
      if [ -n "$udid" ] && [ -n "$team" ]; then
        build ompanion-iOS "id=$udid" "$config-iphoneos" ios-device -allowProvisioningUpdates \
          -allowProvisioningDeviceRegistration ARCHS=arm64 CODE_SIGN_STYLE=Automatic \
          CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM="$team"
      elif [ -n "$team" ]; then
        build ompanion-iOS 'generic/platform=iOS' "$config-iphoneos" ios-device -allowProvisioningUpdates ARCHS=arm64 \
          CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM="$team"
      else
        build ompanion-iOS 'generic/platform=iOS' "$config-iphoneos" ios-device ARCHS=arm64 CODE_SIGNING_ALLOWED=NO
      fi
      ;;
    ipa)
      # Settings on the command line reach the Swift packages' resource bundles too, which have no team of their own.
      project_team=$(sed -n 's/^ *DEVELOPMENT_TEAM: //p' project.yml)
      rm -rf "$out/ios-archive" "$out/ipa"
      xcodebuild -quiet -project ompanion.xcodeproj -scheme ompanion-iOS -configuration "$config" \
        -destination 'generic/platform=iOS' -derivedDataPath "$out/DerivedData" \
        -archivePath "$out/ios-archive/ompanion.xcarchive" -allowProvisioningUpdates ARCHS=arm64 \
        CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM="${team:-$project_team}" archive
      # The export signs with the team's cloud-managed Apple Distribution certificate, through the Apple ID in Xcode's
      # accounts (an App Store Connect API key needs the cloud signing permission, which the team's key lacks). It
      # packages with /usr/bin/rsync, which starts the first `rsync` on PATH as its peer: Homebrew's fails.
      PATH=/usr/bin:$PATH xcodebuild -quiet -exportArchive -archivePath "$out/ios-archive/ompanion.xcarchive" \
        -exportOptionsPlist "$here/ExportOptions.plist" -exportPath "$out/ipa" -allowProvisioningUpdates
      echo "$out/ipa/ompanion.ipa"
      ;;
  esac
done
