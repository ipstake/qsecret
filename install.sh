#!/usr/bin/env bash
# Install qsecret on every cluster node. Runs as root on one node, from this folder.
# Safe to run again. Does not touch shares or secrets.
#
#   install.sh           check every node, then install on every node
#   install.sh --check   check only, change nothing
#
# The check: Debian 13 / Proxmox VE 9+, a TPM 2.0, reachable, at least 3 nodes, all online.
# If any node fails, nothing is installed anywhere.
set -euo pipefail
cd "$(dirname "$0")"
check_only=0; [[ ${1:-} == --check ]] && check_only=1
files=(qsecret qsecret-push.service qsecret-push.timer qsecret-check.service qsecret-check.timer)
version=${QSECRET_VERSION:-dev}

# QSECRET_ROOT is for the test suite's fake cluster only; refused on a real node.
if [[ -n ${QSECRET_ROOT:-} && -e /etc/pve/.members ]]; then
  echo "QSECRET_ROOT is for tests only; unset it" >&2; exit 1
fi
R=${QSECRET_ROOT:-}
members=$R/etc/pve/.members
[[ -e $members ]] || { echo "this node is not in a Proxmox VE cluster" >&2; exit 1; }
nodes=$(perl -MJSON -e 'my $m = decode_json(join "", <STDIN>);
  my $n = $m->{nodelist}; for (sort keys %$n) { print "$_ $n->{$_}{ip} $n->{$_}{online}\n" }' <"$members")
self=$(perl -MJSON -e 'print decode_json(join "", <STDIN>)->{nodename}' <"$members")

count=$(wc -l <<<"$nodes")
(( count >= 3 )) || { echo "qsecret needs at least 3 cluster nodes; this cluster has $count" >&2; exit 1; }
offline=$(awk '$3 != 1 { print $1 }' <<<"$nodes" | tr '\n' ' ')
[[ -z $offline ]] || { echo "every node must be online to install; offline: $offline" >&2; exit 1; }

on() {  # on <name> <ip> <script>: run a script on a node; stdin passes through
  if [[ $1 == "$self" ]]; then bash -c "$3"
  else ssh -T -o BatchMode=yes -o ConnectTimeout=5 "root@$2" "$3"; fi
}

# Checks only; changes nothing. QSECRET_ROOT is empty on real nodes (ssh passes no env).
preflight='
  r=${QSECRET_ROOT:-}
  . "$r/etc/os-release"
  [ "${VERSION_ID:-}" = 13 ] || { echo "Debian ${VERSION_ID:-unknown}, qsecret needs Debian 13 (Proxmox VE 9)"; exit 1; }
  v=$(pveversion 2>/dev/null | sed -n "s#^pve-manager/\([0-9]*\)\..*#\1#p")
  [ "${v:-0}" -ge 9 ] 2>/dev/null || { echo "Proxmox VE ${v:-unknown}, qsecret needs 9 or newer"; exit 1; }
  [ -e "$r/dev/tpmrm0" ] || { echo "no TPM 2.0 (/dev/tpmrm0 missing)"; exit 1; }
  echo ok'

failed=0
while read -r name ip _; do
  r=0; out=$(on "$name" "$ip" "$preflight" </dev/null 2>&1) || r=$?
  if (( r == 255 )); then out="not reachable over SSH"; fi
  echo "$name: ${out:-failed}"
  (( r == 0 )) || failed=1
done <<<"$nodes"
(( ! failed )) || { echo "not installing: fix the nodes above first" >&2; exit 1; }
(( ! check_only )) || { echo "check ok"; exit 0; }

# Runs on each node. The tar comes on stdin, so extract it before apt can read stdin.
install="set -e
  version=$(printf '%q' "$version")"'
  tmp=$(mktemp -d); tar -xz -C "$tmp"
  export DEBIAN_FRONTEND=noninteractive
  need=""
  for p in age ssss libtss2-esys-3.0.2-0t64 libtss2-mu-4.0.1-0t64 libtss2-rc0t64; do
    dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
  done
  [ -z "$need" ] || { apt-get update -qq </dev/null; apt-get install -y -qq $need </dev/null >/dev/null; }
  install -m 0755 "$tmp/qsecret" /usr/local/sbin/qsecret
  install -m 0644 "$tmp"/*.service "$tmp"/*.timer /etc/systemd/system/
  install -d /usr/local/share/qsecret
  printf "%s\n" "$version" >/usr/local/share/qsecret/VERSION
  rm -rf "$tmp"
  systemctl daemon-reload
  systemctl enable --now qsecret-push.timer qsecret-check.timer >/dev/null 2>&1
  tpm=$(systemd-analyze has-tpm2 2>/dev/null | head -1)
  [ "$tpm" = yes ] || { echo "TPM support is \"$tpm\", not yes"; exit 1; }
  echo "installed $version, TPM yes"'

rc=0
while read -r name ip _; do
  if out=$(tar -cz "${files[@]}" | on "$name" "$ip" "$install" 2>&1); then echo "$name: $out"
  else echo "$name: FAILED: $out"; rc=1; fi
done <<<"$nodes"
exit $rc
