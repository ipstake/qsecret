#!/usr/bin/env bash
# End-to-end tests on a fake 4-node cluster. Needs root (tmpfs mounts, chown, bubblewrap),
# plus age, ssss, perl JSON, bwrap and script.
#
# Each node is a QSECRET_ROOT with its own etc/pve/.members, etc/qsecret and run; etc/pve/priv
# and etc/pve/nodes are shared, like pmxcfs. tests/stubs stand in for ssh, pct and
# systemd-creds. Containers are folders under $QT/ct.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 2; }

QT=$(mktemp -d /var/tmp/qsecret-test.XXXXXX)  # not /tmp: it may be tmpfs, which the "disk" CT must not be
export QT QSECRET_BIN=$REPO/qsecret PATH=$REPO/tests/stubs:$PATH
chmod +x "$REPO/qsecret" "$REPO"/tests/stubs/*
cleanup() {
  local m
  for m in "$QT"/ct/*/run; do mountpoint -q "$m" && umount "$m"; done
  rm -rf "$QT"
}
trap cleanup EXIT

NODES=(node1 node2 node3 node4)
mkdir -p "$QT"/{cluster/priv,ips,down,enrollfail,tpmbroken,ct}
i=0
for n in "${NODES[@]}"; do
  i=$(( i + 1 ))
  echo "$n" >"$QT/ips/10.0.0.$i"
  mkdir -p "$QT/node/$n"/{etc/pve,etc/qsecret,run} "$QT/cluster/nodes/$n/lxc"
  ln -s "$QT/cluster/priv" "$QT/node/$n/etc/pve/priv"
  ln -s "$QT/cluster/nodes" "$QT/node/$n/etc/pve/nodes"
done

# Write each node's .members: nodes in $QT/down are offline; quorum is a majority of 4.
members() {
  local n j=0 up=0 list="" sep=""
  for n in "${NODES[@]}"; do [[ -e $QT/down/$n ]] || up=$(( up + 1 )); done
  for n in "${NODES[@]}"; do
    j=$(( j + 1 ))
    list+="$sep\"$n\": {\"id\": $j, \"online\": $([[ -e $QT/down/$n ]] && echo 0 || echo 1), \"ip\": \"10.0.0.$j\"}"
    sep=", "
  done
  for n in "${NODES[@]}"; do
    printf '{"nodename": "%s", "cluster": {"name": "test", "nodes": 4, "quorate": %s}, "nodelist": {%s}}\n' \
      "$n" "$(( up >= 3 ? 1 : 0 ))" "$list" >"$QT/node/$n/etc/pve/.members"
  done
}
down() { touch "$QT/down/$1"; members; }
up() { rm -f "$QT/down/$1"; members; }
members

# mk_ct <vmid> <host node> <tmpfs|disk>
mk_ct() {
  mkdir -p "$QT/ct/$1/run"
  [[ $3 == tmpfs ]] && mount -t tmpfs -o size=1m tmpfs "$QT/ct/$1/run"
  touch "$QT/ct/$1/running" "$QT/cluster/nodes/$2/lxc/$1.conf"
}
ct_file() { echo "$QT/ct/$1/run/${2#/run/}"; }

qs() { local n=$1; shift; QSECRET_ROOT=$QT/node/$n "$QSECRET_BIN" "$@"; }

pass=0 failed=0
ok() { echo "ok   - $1"; pass=$(( pass + 1 )); }
bad() { echo "FAIL - $1"; failed=$(( failed + 1 )); }
expect_ok() { local d=$1; shift; if "$@" >"$QT/out" 2>&1; then ok "$d"; else bad "$d"; sed 's/^/       /' "$QT/out"; fi; }
expect_fail() {  # expect_fail <description> <text the error must contain> <command...>
  local d=$1 m=$2; shift 2
  if "$@" >"$QT/out" 2>&1; then bad "$d (should fail)"; sed 's/^/       /' "$QT/out"
  elif grep -q -- "$m" "$QT/out"; then ok "$d"
  else bad "$d (failed, but without \"$m\")"; sed 's/^/       /' "$QT/out"; fi
}
expect_eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }
expect_grep() { if grep -q -- "$2" "$QT/out"; then ok "$1"; else bad "$1: no \"$2\" in output"; sed 's/^/       /' "$QT/out"; fi; }

# --- init, add, push --------------------------------------------------------------------

expect_ok "init writes backup and enrolls 4 nodes" sh -c "QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN init --stdout >$QT/backup1"
rcpt=$(cat "$QT/cluster/priv/qsecret/recipient")
expect_eq "backup holds the identity for the recipient" \
  "$(sed -n 's/^identity[^:]*: //p' "$QT/backup1" | age-keygen -y 2>/dev/null)" "$rcpt"
expect_eq "every node has a share" "$(ls "$QT"/node/*/etc/qsecret/share.cred | wc -l)" 4
expect_fail "init twice is refused" "already initialized" qs node1 init --stdout
expect_ok "check passes on a healthy cluster" qs node1 check

mk_ct 100 node1 tmpfs
expect_ok "add a secret" sh -c "printf seal-v1 | QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN add bao-seal 100 /run/qsecret/bao-seal.key 100:1000 0400"
expect_ok "push delivers" qs node1 push
f=$(ct_file 100 /run/qsecret/bao-seal.key)
expect_eq "delivered content" "$(cat "$f" 2>/dev/null)" seal-v1
expect_eq "owner and mode" "$(stat -c '%u:%g %a' "$f" 2>/dev/null)" "100:1000 400"
expect_eq "folder mode" "$(stat -c %a "$(dirname "$f")")" 755
expect_ok "push again changes nothing" qs node1 push
expect_eq "no delivery on the second run" "$(grep -c delivered "$QT/out")" 0
expect_ok "push on a node that does not host the CT is a no-op" qs node2 push

# --- add refusals -----------------------------------------------------------------------

addq() { local v=$1; shift; printf '%s' "$v" | qs node1 add "$@"; }
expect_fail "overwrite without -f" "use -f" addq x bao-seal 100 /run/qsecret/bao-seal.key 100:1000 0400
expect_fail "empty secret" "empty secret" addq "" empty 100 /run/qsecret/e
expect_fail "path traversal" "bad vmid, dest" addq x trav 100 /run/../etc/x
expect_fail "dest outside /run" "bad vmid, dest" addq x out 100 /etc/x
expect_fail "owner as an option" "bad vmid, dest" addq x own 100 /run/qsecret/o -x 0400
expect_fail "bad mode" "bad vmid, dest" addq x mode 100 /run/qsecret/m 0:0 777

expect_ok "replace with -f" addq seal-v2 -f bao-seal 100 /run/qsecret/bao-seal.key 100:1000 0400
expect_ok "push after replace" qs node1 push
expect_eq "changed secret is delivered again" "$(cat "$f")" seal-v2

# --- nodes down, quorum, kill switch, TPM, stale share ----------------------------------

redeliver() { rm -f "$f" "$f.version"; qs node1 push >"$QT/out" 2>&1; cat "$f" 2>/dev/null; }

down node4
expect_eq "one node down: still delivers" "$(redeliver)" seal-v2
down node3
expect_eq "two nodes down (no quorum): nothing delivered" "$(redeliver)" ""
up node3; up node4

touch "$QT/cluster/priv/qsecret/disabled"
expect_eq "kill switch: nothing delivered" "$(redeliver)" ""
rm "$QT/cluster/priv/qsecret/disabled"
expect_eq "kill switch off: delivered" "$(redeliver)" seal-v2

touch "$QT/tpmbroken/node2"
expect_fail "check fails with a broken TPM" "no share" qs node1 check
expect_grep "check names the node" "node2: no share"
expect_eq "broken TPM on one node: still delivers" "$(redeliver)" seal-v2
rm "$QT/tpmbroken/node2"

good=$(qs node4 share 2>/dev/null | cut -d' ' -f2)
stale="${good%%-*}-$(rev <<<"${good#*-}")"
printf '%s\n' "$stale" | qs node4 enroll "$rcpt" >/dev/null 2>&1
expect_fail "check fails with a wrong share" "share does not work" qs node1 check
expect_grep "check names the bad share" "node4: share does not work"
expect_eq "wrong share on one node: still delivers" "$(redeliver)" seal-v2

# --- container side ---------------------------------------------------------------------

mk_ct 101 node3 disk
expect_ok "add a secret for a CT whose /run is not tmpfs" addq v x171 101 /run/qsecret/x
expect_fail "push refuses a non-tmpfs /run" "not tmpfs" qs node3 push
expect_eq "nothing written to disk" "$(ls "$QT/ct/101/run" 2>/dev/null)" ""
expect_ok "a failed secret backs off" qs node3 push
expect_eq "no second attempt right away" "$(grep -c 'failed to deliver' "$QT/out")" 0
qs node1 remove x171 >/dev/null 2>&1

mk_ct 102 node2 tmpfs
mkdir -p "$QT/evil"; ln -s "$QT/evil" "$QT/ct/102/run/qsecret"
expect_ok "add a secret behind a symlink" addq v x172 102 /run/qsecret/x
expect_fail "push refuses a symlinked folder" "has a symlink in its path" qs node2 push
expect_eq "nothing written through the symlink" "$(ls "$QT/evil")" ""
qs node1 remove x172 >/dev/null 2>&1

# --- export ----------------------------------------------------------------------------

expect_eq "export one secret" "$(qs node1 export bao-seal 2>/dev/null)" seal-v2
expect_eq "export public files" "$(qs node1 export 2>/dev/null | tar -tz | grep -c -e recipient -e bao-seal.age)" 2
expect_fail "export refuses a terminal" "redirect or pipe" script -qec "QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN export bao-seal" /dev/null

# --- reshare, rotate --------------------------------------------------------------------

expect_ok "reshare" sh -c "QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN reshare --stdout >$QT/backup2"
expect_ok "check after reshare (stale share replaced)" qs node1 check
expect_eq "reshare keeps the key pair" "$(cat "$QT/cluster/priv/qsecret/recipient")" "$rcpt"
expect_eq "deliver after reshare" "$(redeliver)" seal-v2

expect_ok "rotate" sh -c "QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN rotate --stdout >$QT/backup3"
rcpt2=$(cat "$QT/cluster/priv/qsecret/recipient")
[[ $rcpt2 != "$rcpt" ]] && ok "rotate makes a new key pair" || bad "rotate makes a new key pair"
expect_ok "check after rotate" qs node1 check
expect_eq "deliver after rotate (secret re-encrypted)" "$(redeliver)" seal-v2

touch "$QT/enrollfail/node3"
expect_fail "rotate stops when a node cannot enroll" "enroll failed on node3" sh -c "QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN rotate --stdout >$QT/backup4"
expect_eq "recipient unchanged after the failed rotate" "$(cat "$QT/cluster/priv/qsecret/recipient")" "$rcpt2"
expect_eq "new key is staged" "$(test -s "$QT/cluster/priv/qsecret/recipient.next" && echo yes)" yes
rm "$QT/enrollfail/node3"
new_id=$(sed -n 's/^identity[^:]*: //p' "$QT/backup4")
expect_fail "reshare refuses a wrong identity" "does not match the recipient" sh -c "age-keygen 2>/dev/null | grep '^AGE' | QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN reshare --identity-stdin --stdout >/dev/null"
expect_ok "finish the rotate from the backup" sh -c "printf '%s\n' '$new_id' | QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN reshare --identity-stdin --stdout >/dev/null"
expect_eq "recipient switched to the new key" "$(cat "$QT/cluster/priv/qsecret/recipient")" "$(printf '%s\n' "$new_id" | age-keygen -y)"
expect_ok "check after finishing the rotate" qs node1 check
expect_eq "deliver after finishing the rotate" "$(redeliver)" seal-v2

# --- more commands ----------------------------------------------------------------------

expect_fail "init --stdout refuses a terminal" "redirect or pipe" script -qec "QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN init --stdout" /dev/null
expect_ok "status runs" qs node1 status
expect_grep "status shows the recipient" "recipient:  age1"
expect_grep "status shows the share decrypts" "decrypts"
expect_eq "version without an install" "$(qs node1 version)" unknown
expect_ok "backup without --stdout goes to the node's /dev/shm" qs node1 reshare
expect_eq "backup file written" "$(ls "$QT/node/node1/dev/shm"/qsecret-offline-* 2>/dev/null | wc -l)" 1

rm -f "$f" "$f.version"
( qs node1 push & qs node1 push & wait ) >"$QT/out" 2>&1
expect_eq "two pushes at once deliver once" "$(grep -c delivered "$QT/out")" 1
expect_eq "and the file is there" "$(cat "$f")" seal-v2

expect_ok "add a secret, then remove it" sh -c "printf tmp | QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN add gone 100 /run/qsecret/gone && QSECRET_ROOT=$QT/node/node1 $QSECRET_BIN remove gone"
expect_ok "push after remove" qs node1 push
expect_eq "a removed secret is not delivered" "$(ls "$(ct_file 100 /run/qsecret/gone)" 2>/dev/null)" ""

mk_ct 103 node4 tmpfs
mkdir -p "$QT/evil2"; ln -s "$QT/evil2" "$QT/ct/103/run/a"
expect_ok "add a secret under a symlink higher up" addq v deep 103 /run/a/b/x
expect_fail "push refuses a symlink anywhere in the path" "has a symlink in its path" qs node4 push
expect_eq "nothing written through it" "$(ls -A "$QT/evil2")" ""
qs node1 remove deep >/dev/null 2>&1

# --- install.sh preflight ---------------------------------------------------------------

for n in "${NODES[@]}"; do
  mkdir -p "$QT/node/$n/dev"
  echo 'VERSION_ID="13"' >"$QT/node/$n/etc/os-release"
  touch "$QT/node/$n/dev/tpmrm0"
done
inst() { QSECRET_ROOT=$QT/node/node1 bash "$REPO/install.sh" --check; }
expect_ok "install --check passes on a good cluster" inst
expect_grep "it says so" "check ok"
echo 'VERSION_ID="12"' >"$QT/node/node3/etc/os-release"
expect_fail "install refuses Debian 12" "node3: Debian 12" inst
expect_grep "and installs nothing" "not installing"
echo 'VERSION_ID="13"' >"$QT/node/node3/etc/os-release"
echo "pve-manager/8.4.1/0000 (running kernel: 6.8)" >"$QT/node/node2/pveversion"
expect_fail "install refuses Proxmox VE 8" "node2: Proxmox VE 8" inst
rm "$QT/node/node2/pveversion"
rm "$QT/node/node4/dev/tpmrm0"
expect_fail "install refuses a node without a TPM" "node4: no TPM" inst
touch "$QT/node/node4/dev/tpmrm0"
mkdir -p "$QT/unreach"; touch "$QT/unreach/node3"
expect_fail "install refuses an unreachable node" "node3: not reachable" inst
rm "$QT/unreach/node3"
down node4
expect_fail "install refuses an offline node" "offline: node4" inst
up node4

# --- test hooks are refused on a real node ----------------------------------------------

if [[ ! -e /etc/pve ]]; then
  mkdir -p /etc/pve; touch /etc/pve/.members
  expect_fail "qsecret refuses QSECRET_ROOT on a real node" "tests only" qs node1 status
  expect_fail "install.sh refuses QSECRET_ROOT on a real node" "tests only" inst
  rm -rf /etc/pve
else
  echo "skip - /etc/pve exists here, not testing the real-node guard"
fi

echo
echo "$pass passed, $failed failed"
# Explicit exit: at a normal end of script, the EXIT trap's status would replace ours.
exit $(( failed == 0 ? 0 : 1 ))
