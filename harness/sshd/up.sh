#!/bin/sh
# Starts the SSH test machines on docker network omp-sshd, recreating them if present:
#   bastion  127.0.0.1:22220
#   target   127.0.0.1:22221, and target:22 from the bastion; omp 18.3.1 at /home/omp/.local/bin/omp
# Users: omp (key), pw (password), kbd (password as a keyboard-interactive prompt), nopw (`none` auth).
# Password for pw and kbd: omp-test-password.
# Both resolve host.docker.internal to Docker's host gateway: this computer's loopback under colima, the
# default bridge's address on Linux.
#
# Everything a test needs is in .tools/ssh-test/ (gitignored), created once and reused:
#   id_ed25519, id_rsa        client keys, authorized for omp on both machines
#   hostkeys/<machine>/       host keys, copied into the containers so they survive re-runs
#   known_hosts               entries for [localhost]:22220, [localhost]:22221 and target
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
keys="$root/.tools/ssh-test"
image=omp-sshd:test
network=omp-sshd

case "$(docker version --format '{{.Server.Arch}}')" in
  arm64 | aarch64) omp="$root/.tools/omp/18.3.1/omp-linux-arm64" ;;
  amd64 | x86_64) omp="$root/.tools/omp/18.3.1/omp-linux-x64" ;;
  *) echo "unsupported docker architecture" >&2; exit 1 ;;
esac
[ -x "$omp" ] || { echo "missing $omp" >&2; exit 1; }

mkdir -p "$keys"
[ -f "$keys/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C ompanion-test -f "$keys/id_ed25519"
[ -f "$keys/id_rsa" ] || ssh-keygen -q -t rsa -b 3072 -N '' -C ompanion-test-rsa -f "$keys/id_rsa"
for machine in bastion target; do
  dir="$keys/hostkeys/$machine"
  mkdir -p "$dir"
  for type in ed25519 ecdsa rsa; do
    [ -f "$dir/ssh_host_${type}_key" ] || ssh-keygen -q -t "$type" -N '' -C "$machine" -f "$dir/ssh_host_${type}_key"
  done
done

docker build -q -t "$image" "$here" >/dev/null
"$here/down.sh"
docker network create "$network" >/dev/null

authorized=$(cat "$keys/id_ed25519.pub" "$keys/id_rsa.pub")
for spec in bastion:22220 target:22221; do
  name=${spec%%:*}
  port=${spec##*:}
  docker create --name "omp-sshd-$name" --label omp-sshd=1 --hostname "$name" \
    --network "$network" --network-alias "$name" -p "127.0.0.1:$port:22" \
    --add-host host.docker.internal:host-gateway \
    -e AUTHORIZED_KEYS="$authorized" "$image" >/dev/null
  docker cp "$keys/hostkeys/$name/." "omp-sshd-$name:/etc/ssh/"
  docker start "omp-sshd-$name" >/dev/null
done

docker cp "$omp" omp-sshd-target:/home/omp/.local/bin/omp
docker exec omp-sshd-target chown omp:omp /home/omp/.local/bin/omp
for name in bastion target; do docker exec "omp-sshd-$name" sh -c 'chown root:root /etc/ssh/ssh_host_*'; done

# The published port accepts connections before sshd answers, so wait for its banner.
for spec in bastion:22220 target:22221; do
  name=${spec%%:*}
  port=${spec##*:}
  tries=0
  until ssh-keyscan -T 2 -p "$port" 127.0.0.1 >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || { docker logs "omp-sshd-$name" >&2; echo "$name did not come up" >&2; exit 1; }
    sleep 1
  done
done

{
  awk '{ print "[localhost]:22220,[127.0.0.1]:22220", $1, $2 }' "$keys"/hostkeys/bastion/*.pub
  awk '{ print "[localhost]:22221,[127.0.0.1]:22221,target", $1, $2 }' "$keys"/hostkeys/target/*.pub
} >"$keys/known_hosts"

echo "bastion 127.0.0.1:22220, target 127.0.0.1:22221 (target:22 via bastion); keys and known_hosts in $keys"
