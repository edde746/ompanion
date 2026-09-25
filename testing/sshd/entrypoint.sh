#!/bin/sh
# Host keys are generated per container, so bastion and target present different keys.
set -eu
ssh-keygen -A >/dev/null
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
  printf '%s\n' "$AUTHORIZED_KEYS" >/home/omp/.ssh/authorized_keys
  chown omp:omp /home/omp/.ssh/authorized_keys
  chmod 600 /home/omp/.ssh/authorized_keys
fi
exec /usr/sbin/sshd -D -e
