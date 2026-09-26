#!/bin/sh
# Submits an artifact to Apple's notary service, waits, and staples the ticket, so a downloaded copy
# passes Gatekeeper offline:
#
#   scripts/notarize.sh <artifact.zip|artifact.dmg> <staple-target> [log-directory]
#
# The ticket goes on <staple-target>: the DMG itself, or for a zip, the .app it was made from, since
# stapler cannot write into a zip. Reads APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID from
# the environment. Prints the submission, and Apple's log on a rejection, then exits 1.
set -eu

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <artifact.zip|artifact.dmg> <staple-target> [log-directory]" >&2
  exit 2
fi

artifact=$1
target=$2
logdir=${3:-.}
[ -e "$artifact" ] || { echo "no such artifact: $artifact" >&2; exit 1; }
[ -e "$target" ] || { echo "no such staple target: $target" >&2; exit 1; }
: "${APPLE_ID:?APPLE_ID is not set}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is not set}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is not set}"

name=$(basename "$artifact")
mkdir -p "$logdir"
submission="$logdir/$name.submission.plist"
# PlistBuddy announces on stdout that it created a missing file, which the command substitutions below
# would read as a value; give it an empty file that already exists.
: >"$submission"

# `notarytool submit --wait` exits 1 when Apple rejects the artifact and says nothing about why, so keep
# going and read the reason from the response. The plist carries the submission id that `notarytool log`
# needs; the JSON and text formats print it, but not in a form these lines can rely on.
set +e
xcrun notarytool submit "$artifact" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait --output-format plist >"$submission"
status_code=$?
set -e

# Nothing at all means the submission never started: bad credentials, or no network.
status=unknown
id=
if [ -s "$submission" ]; then
  /usr/libexec/PlistBuddy -c Print "$submission" || true
  status=$(/usr/libexec/PlistBuddy -c "Print :status" "$submission" 2>/dev/null || echo unknown)
  id=$(/usr/libexec/PlistBuddy -c "Print :id" "$submission" 2>/dev/null || true)
fi

if [ "$status_code" -ne 0 ] || [ "$status" != Accepted ]; then
  if [ -n "$id" ]; then
    if xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" "$logdir/$name.log.json"; then
      echo "--- $name notarization log ---"
      cat "$logdir/$name.log.json"
      echo "--- end of log ---"
    fi
  fi
  echo "Notarization of $name failed (status $status)" >&2
  exit 1
fi

# The ticket travels inside the app or the DMG, which is what makes Gatekeeper accept it without the network.
xcrun stapler staple "$target"
xcrun stapler validate "$target"
