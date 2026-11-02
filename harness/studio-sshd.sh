#!/bin/sh
# Two user-level OpenSSH servers on this computer (studio.local through devpool, or a CI runner) for e2e tests of
# real-OpenSSH paths: a bastion and a target, both on 127.0.0.1 at free high ports, key auth only, for the current
# user. The target is reached as a jump host's next hop the usual way: the bastion opens direct-tcpip to
# 127.0.0.1:<target port>.
#
#   harness/studio-sshd.sh start <dir>   # prints one JSON line, see below
#   harness/studio-sshd.sh stop <dir>    # kills both servers
#
# start writes into <dir>: each server's host key, config, pid file and log (bastion/, target/), the client key
# (client_ed25519, unencrypted, and .pub), authorized_keys, known_hosts with both servers as [127.0.0.1]:<port>, and
# ssh_config, whose `Host *` makes `ssh -F <dir>/ssh_config -J <user>@127.0.0.1:N -p M <user>@127.0.0.1` work (ssh
# passes -F on to the jump). Every session on the target (exec, shell, SFTP) runs with HOME=<dir>/target/home and
# starts there, so tests never touch the real home. Its stdout is one line:
#   {"bastion":{"host":"127.0.0.1","port":N},"target":{"host":"127.0.0.1","port":M},"user":"<user>",
#    "privateKeyPath":"<dir>/client_ed25519","knownHosts":"<dir>/known_hosts","sshConfig":"<dir>/ssh_config",
#    "home":"<dir>/target/home"}
set -eu

usage() { echo "usage: studio-sshd.sh start|stop <dir>" >&2; exit 2; }
[ $# -eq 2 ] || usage
action=$1
mkdir -p "$2"
dir=$(cd "$2" && pwd)

stop() {
  for name in bastion target; do
    pidfile="$dir/$name/sshd.pid"
    if [ -f "$pidfile" ]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true # already gone is stopped
      rm -f "$pidfile"
    fi
  done
}

# OpenSSH's SFTP server: macOS's, else Debian's and Ubuntu's (the CI runner).
sftp_server=/usr/libexec/sftp-server
[ -x "$sftp_server" ] || sftp_server=/usr/lib/openssh/sftp-server

# free_port asks the kernel for a free loopback port.
free_port() {
  perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1:0") or die "$!\n";
    print $s->sockport, "\n"'
}

# start_server starts sshd as name on port; extra lines go into its sshd_config.
start_server() {
  name=$1
  port=$2
  extra=$3
  mkdir -p "$dir/$name"
  rm -f "$dir/$name/ssh_host_ed25519_key" "$dir/$name/ssh_host_ed25519_key.pub"
  ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$dir/$name/ssh_host_ed25519_key"
  cat > "$dir/$name/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/$name/ssh_host_ed25519_key
PidFile $dir/$name/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
Subsystem sftp $sftp_server
$extra
EOF
  # sshd forks into the background once it listens, and writes its pid file.
  /usr/sbin/sshd -f "$dir/$name/sshd_config" -E "$dir/$name/sshd.log"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$dir/$name/sshd.pid" ] && return 0
    sleep 0.2
  done
  echo "studio-sshd.sh: $name did not start; $dir/$name/sshd.log:" >&2
  cat "$dir/$name/sshd.log" >&2
  exit 1
}

case $action in
  stop)
    stop
    ;;
  start)
    stop
    rm -f "$dir/client_ed25519" "$dir/client_ed25519.pub"
    ssh-keygen -q -t ed25519 -N '' -C studio-sshd-client -f "$dir/client_ed25519"
    cp "$dir/client_ed25519.pub" "$dir/authorized_keys"
    bastion_port=$(free_port)
    target_port=$(free_port)
    while [ "$target_port" = "$bastion_port" ]; do target_port=$(free_port); done
    start_server bastion "$bastion_port" ""
    home="$dir/target/home"
    mkdir -p "$home"
    # sshd starts every session in the real home: the forced command moves it to the isolated one, then runs what was
    # asked (a subsystem arrives as its program, so SFTP starts there too).
    cat > "$dir/target/session.sh" <<'EOF'
#!/bin/sh
cd "$HOME" || exit 1
if [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then exec "$SHELL" -l; fi
exec "$SHELL" -c "$SSH_ORIGINAL_COMMAND"
EOF
    chmod +x "$dir/target/session.sh"
    start_server target "$target_port" "SetEnv HOME=$home
ForceCommand $dir/target/session.sh"
    : > "$dir/known_hosts"
    for name in bastion target; do
      eval "port=\$${name}_port"
      printf '[127.0.0.1]:%s %s\n' "$port" "$(cut -d' ' -f1-2 "$dir/$name/ssh_host_ed25519_key.pub")" >> "$dir/known_hosts"
    done
    cat > "$dir/ssh_config" <<EOF
Host *
  IdentityFile $dir/client_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $dir/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
EOF
    printf '{"bastion":{"host":"127.0.0.1","port":%s},"target":{"host":"127.0.0.1","port":%s},"user":"%s","privateKeyPath":"%s","knownHosts":"%s","sshConfig":"%s","home":"%s"}\n' \
      "$bastion_port" "$target_port" "$(id -un)" "$dir/client_ed25519" "$dir/known_hosts" "$dir/ssh_config" "$home"
    ;;
  *)
    usage
    ;;
esac
