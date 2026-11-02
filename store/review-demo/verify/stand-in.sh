#!/bin/sh
# Runs verify.ts against a stand-in for the review demo server, for when the server or its password is not at hand:
# a user-level OpenSSH server on studio.local (harness/studio-sshd.sh) whose home is the demo's home template, with the
# tested omp and no OpenRouter key, so no model can be called. Sign-in is the run's own key instead of root's password,
# the one step the real server checks that this one cannot.
#
#   scripts/studio.sh <stage> -- sh store/review-demo/verify/stand-in.sh [verify.ts flags]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
dir=$(mktemp -d "${TMPDIR:-/tmp}/review-demo-stand-in.XXXXXX")
# verify.ts leaves its run alive on the machine, as the app does; here it goes with the stand-in.
trap 'sh "$repo/harness/studio-sshd.sh" stop "$dir"; pkill -f "$dir/" || true; rm -rf "$dir"' EXIT

port=$(sh "$repo/harness/studio-sshd.sh" start "$dir" | sed 's/.*"target":{"host":"127.0.0.1","port":\([0-9]*\)}.*/\1/')
home="$dir/target/home"
cp -R "$here/../home-template/." "$home/"
sed -i '' 's|@OPENROUTER_API_KEY@|stand-in-without-a-key|' "$home/.omp/agent/models.yml"
# omp on a Mac also offers Apple's on-device model; the real server is Linux, where the demo's model is the only one.
printf 'disabledProviders: [apple]\n' >> "$home/.omp/agent/config.yml"
mkdir -p "$home/.local/bin"
cp "$repo/.tools/omp/$(tr -d '[:space:]' < "$repo/harness/omp-version")/omp-darwin-arm64" "$home/.local/bin/omp"

bun "$here/verify.ts" --host 127.0.0.1 --port "$port" --user "$(id -un)" --key "$dir/client_ed25519" "$@"
