#!/bin/sh
# Egress rules for the network namespace the `host` container joins (docker-compose.yml). The reviewer has
# a shell there, so these rules are what keeps it off the internet, the VPS's own services and the cloud's
# metadata address: new connections go to the compose network (the provider) and nowhere else. Replies to
# SSH clients belong to established connections and pass.
set -eu

gateway=$(ip -4 route show default | awk '{ print $3; exit }')
subnet=$(ip -4 route show scope link | awk '{ print $1; exit }')
if [ -z "$gateway" ] || [ -z "$subnet" ]; then
  echo "firewall: no default route or no link subnet" >&2
  exit 1
fi

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# The gateway is the VPS itself.
iptables -A OUTPUT -d "$gateway" -j REJECT
iptables -A OUTPUT -d "$subnet" -j ACCEPT
iptables -A OUTPUT -j REJECT

# The compose network has no IPv6, but link-local addresses still reach the VPS's own listeners. A kernel
# booted without IPv6 has no /proc/net/if_inet6 and nothing to close.
if [ -e /proc/net/if_inet6 ]; then
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A OUTPUT -j REJECT
fi

touch /run/egress-closed
echo "firewall: new connections leave only for $subnet, not its gateway $gateway"
exec sleep infinity
