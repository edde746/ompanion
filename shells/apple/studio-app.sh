# Sourced by smoke.sh and shot.sh inside their leases on studio. The app is the store app's identity, so a run first
# checks that none of its data is on studio or the simulator (stops if there is, as AGENTS.md's machine rules ask) and
# removes all it made afterwards: claim_macos and claim_ios set the cleanup as the script's exit trap.

id=com.edde746.ompanion
flutter_service=flutter_secure_storage_service
data="$HOME/Library/Application Support/$id"
saved="$HOME/Library/Saved Application State/$id.savedState"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# keychain_items: whether the login keychain holds an item of the app's or the Flutter app's service.
keychain_items() {
  security find-generic-password -s "$id" > /dev/null 2>&1 ||
    security find-generic-password -s "$flutter_service" > /dev/null 2>&1
}

# claim_macos <app>…: the apps the run opens (their LaunchServices records go afterwards).
claim_macos() {
  if [ -e "$data" ] || [ -e "$saved" ] || keychain_items; then
    echo "$0: $id data or keychain items are already on this Mac; nothing was run" >&2
    exit 1
  fi
  opened="$*"
  # The app's defaults (Sparkle's, AppKit's, WebKit's) go back as they were.
  prefs_before=$PWD/prefs-before.plist
  rm -f "$prefs_before"
  [ ! -e "$HOME/Library/Preferences/$id.plist" ] || defaults export "$id" "$prefs_before"
  trap release_macos EXIT
}

release_macos() {
  # The app's secrets (an import leaves the imported ones), and the Flutter app's.
  for service in "$id" "$flutter_service"; do
    while security delete-generic-password -s "$service" > /dev/null 2>&1; do :; done
  done
  rm -rf "$data" "$saved" "$HOME/Library/Caches/$id" "$HOME/Library/WebKit/$id" "$HOME/Library/HTTPStorages/$id" \
    "$HOME/Library/HTTPStorages/$id.binarycookies"
  for app in $opened; do
    "$lsregister" -u "$app" || true
  done
  # `defaults import` merges into the domain: keys the run added would stay.
  defaults delete "$id" 2> /dev/null || true
  [ ! -e "$prefs_before" ] || defaults import "$id" "$prefs_before"
  if [ -e "$data" ] || keychain_items; then
    echo "$0: $id data or keychain items are left on this Mac" >&2
  else
    echo "cleaned: no $id data or keychain items on this Mac"
  fi
}

claim_ios() {
  if xcrun simctl get_app_container "$DEVPOOL_SIM_UDID" "$id" > /dev/null 2>&1; then
    echo "$0: $id is already installed on simulator $DEVPOOL_SIM_UDID; nothing was run" >&2
    exit 1
  fi
  trap release_ios EXIT
}

release_ios() {
  xcrun simctl uninstall "$DEVPOOL_SIM_UDID" "$id" || true
  # Keychain items outlive the app: the app's secrets and the Flutter app's are in the simulator's keychain.
  xcrun simctl keychain "$DEVPOOL_SIM_UDID" reset
  if xcrun simctl get_app_container "$DEVPOOL_SIM_UDID" "$id" > /dev/null 2>&1; then
    echo "$0: $id is still installed on simulator $DEVPOOL_SIM_UDID" >&2
  else
    echo "cleaned: $id is not installed on simulator $DEVPOOL_SIM_UDID, whose keychain is reset"
  fi
}
