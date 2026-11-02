#!/bin/sh
# The SSH demo host of the store captures on studio.local: two user-level OpenSSH servers, a bastion and a target,
# as harness/studio-sshd.sh starts them, but listening where a phone on the LAN reaches them and with a home that
# looks like the Linux host the Flutter captures used (prompt `omp@target:~/code/api-server$`, the tested omp in
# ~/.local/bin, Homebrew's git, node and npm on PATH). The target is reached through the bastion as
# 127.0.0.1:<target port>.
#
#   store/screenshots/demo/host.sh start <dir> [--home <dir>] [--listen <address>] [--ports <bastion>,<target>]
#                                              [--omp <binary>]
#   store/screenshots/demo/host.sh stop <dir>
#
# start writes into <dir>: each server's host key, config, pid file and log (bastion/, target/), the client key
# (client_ed25519, unencrypted) and authorized_keys. Every session on the target (exec, shell, SFTP) runs with HOME set
# to --home (default <dir>/home), which start creates. --listen defaults to 127.0.0.1, --ports to two free ports, and
# --omp is copied to <home>/.local/bin/omp. It prints one JSON line:
#   {"bastion":{"port":N,"key":"<host key blob>"},"target":{"port":M,"key":"<host key blob>"},
#    "clientKey":"<dir>/client_ed25519","home":"<home>"}
set -eu

usage() {
  echo "usage: host.sh start <dir> [--home <dir>] [--listen <address>] [--ports <bastion>,<target>] [--omp <binary>] | stop <dir>" >&2
  exit 2
}
[ $# -ge 2 ] || usage
action=$1
mkdir -p "$2"
dir=$(cd "$2" && pwd)
shift 2
listen=127.0.0.1 ports= omp= home=$dir/home
while [ $# -gt 0 ]; do
  case $1 in
    --home) home=$2; shift 2 ;;
    --listen) listen=$2; shift 2 ;;
    --ports) ports=$2; shift 2 ;;
    --omp) omp=$2; shift 2 ;;
    *) usage ;;
  esac
done

stop() {
  for name in bastion target; do
    pidfile="$dir/$name/sshd.pid"
    if [ -f "$pidfile" ]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true # already gone is stopped
      rm -f "$pidfile"
    fi
  done
}

free_port() {
  perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1:0") or die "$!\n";
    print $s->sockport, "\n"'
}

sftp_server=/usr/libexec/sftp-server

# start_server <name> <port> <extra sshd_config lines>
start_server() {
  mkdir -p "$dir/$1"
  rm -f "$dir/$1/ssh_host_ed25519_key" "$dir/$1/ssh_host_ed25519_key.pub"
  ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$dir/$1/ssh_host_ed25519_key"
  cat > "$dir/$1/sshd_config" <<EOF
Port $2
ListenAddress $listen
HostKey $dir/$1/ssh_host_ed25519_key
PidFile $dir/$1/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
Subsystem sftp $sftp_server
$3
EOF
  /usr/sbin/sshd -f "$dir/$1/sshd_config" -E "$dir/$1/sshd.log"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$dir/$1/sshd.pid" ] && return 0
    sleep 0.2
  done
  echo "host.sh: $1 did not start; $dir/$1/sshd.log:" >&2
  cat "$dir/$1/sshd.log" >&2
  exit 1
}

case $action in
  stop)
    stop
    ;;
  start)
    stop
    rm -f "$dir/client_ed25519" "$dir/client_ed25519.pub"
    ssh-keygen -q -t ed25519 -N '' -C store-capture -f "$dir/client_ed25519"
    cp "$dir/client_ed25519.pub" "$dir/authorized_keys"
    if [ -n "$ports" ]; then
      bastion_port=${ports%,*} target_port=${ports#*,}
    else
      bastion_port=$(free_port)
      target_port=$(free_port)
      while [ "$target_port" = "$bastion_port" ]; do target_port=$(free_port); done
    fi
    mkdir -p "$home/.local/bin"
    [ -z "$omp" ] || cp "$omp" "$home/.local/bin/omp"
    # Every zsh reads .zshenv, the commands the app runs too; the interactive one (the terminal) also .zshrc.
    cat > "$home/.zshenv" <<'EOF'
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=en_US.UTF-8
EOF
    cat > "$home/.zshrc" <<'EOF'
PROMPT='%B%F{green}omp@target%f%b:%B%F{blue}%~%f%b$ '
EOF
    start_server bastion "$bastion_port" ""
    # sshd starts every session in the real home: the forced command moves it to this one, then runs what was asked
    # (a subsystem arrives as its program, so SFTP starts there too).
    mkdir -p "$dir/target"
    cat > "$dir/target/session.sh" <<'EOF'
#!/bin/sh
cd "$HOME" || exit 1
if [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then exec /bin/zsh -l; fi
exec /bin/zsh -c "$SSH_ORIGINAL_COMMAND"
EOF
    chmod +x "$dir/target/session.sh"
    start_server target "$target_port" "SetEnv HOME=$home SHELL=/bin/zsh
ForceCommand $dir/target/session.sh"
    printf '{"bastion":{"port":%s,"key":"%s"},"target":{"port":%s,"key":"%s"},"clientKey":"%s","home":"%s"}\n' \
      "$bastion_port" "$(cut -d' ' -f2 "$dir/bastion/ssh_host_ed25519_key.pub")" \
      "$target_port" "$(cut -d' ' -f2 "$dir/target/ssh_host_ed25519_key.pub")" "$dir/client_ed25519" "$home"
    ;;
  *)
    usage
    ;;
esac
