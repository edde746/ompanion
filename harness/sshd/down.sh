#!/bin/sh
# Removes every container labelled omp-sshd=1 (including ones tests started) and the network.
# The omp-sshd:test image stays for fast restarts; `docker rmi omp-sshd:test` reclaims it.
set -eu

ids=$(docker ps -aq --filter label=omp-sshd=1)
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086 # one id per word
  docker rm -f $ids >/dev/null
fi
if docker network inspect omp-sshd >/dev/null 2>&1; then
  docker network rm omp-sshd >/dev/null
fi
