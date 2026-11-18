#!/bin/sh
# ur-vifs.sh — attach one virtual interface per provider instance so each
# container has its own distinct DEVICE egress source IP.
#
# This is NOT about ISP-issued IPs. A host has one physical IP; these dummy
# links give each provider identity a separate local source address, and a
# provider's network identity is its egress source IP. So distinct source
# IPs = distinct identities.
#
# Usage:
#   sh ur-vifs.sh            # create N interfaces (N from $1 or 3)
#   sh ur-vifs.sh teardown   # remove them
#
# Needs root / CAP_NET_ADMIN.
set -eu

COUNT="${1:-3}"
BASE="10.0.0"

teardown() {
  for i in $(seq 0 $((COUNT - 1))); do
    ip link del dummy$i 2>/dev/null || true
  done
  exit 0
}

[ "${1:-}" = "teardown" ] && teardown

for i in $(seq 0 $((COUNT - 1))); do
  if [ ! -e "/sys/class/net/dummy$i" ]; then
    ip link add dummy$i type dummy
  fi
  ip addr replace "${BASE}.$((i+1))/32" dev dummy$i 2>/dev/null || \
    ip addr add "${BASE}.$((i+1))/32" dev dummy$i
  ip link set dummy$i up
done

echo "Virtual interfaces up:"
ip -4 -o addr show | awk '$2 ~ /^dummy/ {print $2, $4}'