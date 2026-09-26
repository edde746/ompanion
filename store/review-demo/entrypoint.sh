#!/bin/sh
# Review demo host: runs sshd as the unprivileged `review` user this image runs as.
#
# First start: generate the host keys into the /data volume (a rebuild keeps them, so the app never warns
# about a changed host key) and seed the reviewer's home from the image's template. Both happen in the
# volume, which is the container's only writable path beside the tmpfs mounts.
set -eu

keys=/data/ssh

if [ ! -w /data ]; then
  echo "review-demo: /data is not writable; delete the volume (down.sh --clean) and start again" >&2
  exit 1
fi

mkdir -p "$keys"
chmod 700 "$keys"
for type in ed25519 rsa; do
  key="$keys/ssh_host_${type}_key"
  if [ ! -f "$key" ]; then ssh-keygen -q -t "$type" -N '' -C ompanion-review-demo -f "$key"; fi
done

# The marker lives outside the home, so a reset (restore-home.sh, which the reset command calls) does not
# make the next start wipe the home again.
if [ ! -f /data/.seeded ]; then /usr/local/bin/restore-home.sh; fi

echo "review-demo: sshd on port 2222 as user review; host keys:"
ssh-keygen -lf "$keys/ssh_host_ed25519_key.pub"
ssh-keygen -lf "$keys/ssh_host_rsa_key.pub"
exec /usr/sbin/sshd -D -e
