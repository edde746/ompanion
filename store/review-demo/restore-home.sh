#!/bin/sh
# Puts the reviewer's home back the way the image ships it: omp's config (the fake provider, the model
# roles), the demo project with its git history and the shell startup files. Reviewer edits, extra files,
# sessions and the uploaded companion are removed, and omp processes started from the app are stopped.
#
# The host keys in /data/ssh are not touched, so the machine does not look new to the app. The image's
# template is read-only, so this needs no root and nothing is lost: it runs as `review`, from the
# entrypoint on first start and from reset.sh during the review.
set -eu

home=/data/review

cd /
for pattern in "$home/.local/bin/omp" "$home/.ompanion" "$home/.omp"; do
  # A run the app started is a child of an SSH session; killing it releases the session too.
  pkill -f "$pattern" 2>/dev/null || true
done
sleep 1

rm -rf "$home"
mkdir -p "$home"
cp -a /opt/review-demo/home/. "$home"/
# The home's README tells the reviewer the port their server publishes, which may not be 2222.
sed -i "s/@PORT@/${REVIEW_SSH_PORT:-2222}/g" "$home/README.md"
touch /data/.seeded

echo "review-demo: home restored from the template ($home)"
