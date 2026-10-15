#!/usr/bin/env bash
# Tests for get.sh, with test releases signed by a throwaway key. get.sh itself has no test
# switch: the tests run a copy whose built-in signer list holds the throwaway key. The
# download path runs against tests/stubs/curl, which plays the GitHub API.
# Needs root (get.sh insists), ssh-keygen, sha256sum, tar, perl JSON.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
[[ $(id -u) == 0 ]] || { echo "run as root" >&2; exit 2; }
# A stub without the execute bit is skipped by PATH lookup, and the real curl would run.
chmod +x "$REPO"/tests/stubs/*

T=$(mktemp -d /var/tmp/qsecret-get.XXXXXX)
VF=/usr/local/share/qsecret/VERSION
saved_version=$(cat "$VF" 2>/dev/null || true)
cleanup() {
  rm -rf "$T" /usr/local/src/qsecret-v9.9.*
  if [[ -n $saved_version ]]; then printf '%s\n' "$saved_version" >"$VF"; else rm -f "$VF"; fi
}
trap cleanup EXIT
v=v9.9.9
files=(README.md LICENSE get.sh install.sh qsecret qsecret-push.service qsecret-push.timer qsecret-check.service qsecret-check.timer)

ssh-keygen -q -t ed25519 -N "" -C test-release -f "$T/key"
ssh-keygen -q -t ed25519 -N "" -C other -f "$T/other"

# A copy of get.sh that trusts only the throwaway key.
perl -0pe "s/(  local signers=')[^']*'/\${1}qsecret-release namespaces=\"qsecret-release\" $(cut -d' ' -f1,2 "$T/key.pub" | sed 's/[\/&]/\\&/g')'/" \
  "$REPO/get.sh" >"$T/get-test.sh"
grep -q "$(cut -d' ' -f2 "$T/key.pub")" "$T/get-test.sh" || { echo "could not patch get.sh" >&2; exit 2; }

# release <dir> <sign key> <namespace> [version]
release() {
  local d=$1 ver=${4:-$v}
  mkdir -p "$d/stage/qsecret-$ver"
  (cd "$REPO" && cp "${files[@]}" "$d/stage/qsecret-$ver/")
  tar -czf "$d/qsecret-$ver.tar.gz" -C "$d/stage" "qsecret-$ver"
  rm -rf "$d/stage"
  (cd "$d" && sha256sum "qsecret-$ver.tar.gz" >SHA256SUMS)
  ssh-keygen -q -Y sign -f "$2" -n "$3" "$d/SHA256SUMS" 2>/dev/null
}

pass=0 failed=0
ok() { echo "ok   - $1"; pass=$(( pass + 1 )); }
bad() { echo "FAIL - $1"; sed 's/^/       /' "$T/out"; failed=$(( failed + 1 )); }
# expect <description> ok|<error text> <env...> -- <script>
expect() {
  local d=$1 want=$2; shift 2
  local envs=(); while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  if env QSECRET_NO_INSTALL=1 "${envs[@]}" bash "$1" >"$T/out" 2>&1; then got=ok; else got=fail; fi
  if [[ $want == ok ]]; then [[ $got == ok ]] && ok "$d" || bad "$d (failed)"
  else [[ $got == fail ]] && grep -q -- "$want" "$T/out" && ok "$d" || bad "$d (want failure: $want)"; fi
}

# --- verification -----------------------------------------------------------------------

release "$T/good" "$T/key" qsecret-release
expect "good release verifies and unpacks" ok QSECRET_FROM="$T/good" -- "$T/get-test.sh"
[[ -s /usr/local/src/qsecret-$v/qsecret ]] && ok "files unpacked" || bad "files unpacked"

release "$T/tampered" "$T/key" qsecret-release
printf x >>"$T/tampered/qsecret-$v.tar.gz"
expect "tampered tarball is refused" "does not match SHA256SUMS" QSECRET_FROM="$T/tampered" -- "$T/get-test.sh"

release "$T/otherkey" "$T/other" qsecret-release
expect "release signed by another key is refused" "signature does not verify" QSECRET_FROM="$T/otherkey" -- "$T/get-test.sh"

release "$T/gitns" "$T/key" git
expect "signature in the git namespace is refused" "signature does not verify" QSECRET_FROM="$T/gitns" -- "$T/get-test.sh"

release "$T/sums" "$T/key" qsecret-release
c=$(head -c1 "$T/sums/SHA256SUMS"); [[ $c == 0 ]] && n=1 || n=0
sed -i "1s/^./$n/" "$T/sums/SHA256SUMS"
expect "edited SHA256SUMS is refused" "signature does not verify" QSECRET_FROM="$T/sums" -- "$T/get-test.sh"

release "$T/nosig" "$T/key" qsecret-release
rm "$T/nosig/SHA256SUMS.sig"
expect "missing signature is refused" "has no SHA256SUMS.sig" QSECRET_FROM="$T/nosig" -- "$T/get-test.sh"

# A tarball with a path outside its folder, and one with a symlink, both properly signed.
mkdir -p "$T/trav/stage/qsecret-$v" "$T/link/stage/qsecret-$v"
echo x >"$T/trav/stage/evil"
tar -czf "$T/trav/qsecret-$v.tar.gz" -C "$T/trav/stage" "qsecret-$v" "qsecret-$v/../evil"
(cd "$T/trav" && sha256sum "qsecret-$v.tar.gz" >SHA256SUMS); ssh-keygen -q -Y sign -f "$T/key" -n qsecret-release "$T/trav/SHA256SUMS" 2>/dev/null
expect "tarball with .. is refused" "unexpected entries" QSECRET_FROM="$T/trav" -- "$T/get-test.sh"
ln -s /etc/passwd "$T/link/stage/qsecret-$v/qsecret"
tar -czf "$T/link/qsecret-$v.tar.gz" -C "$T/link/stage" "qsecret-$v"
(cd "$T/link" && sha256sum "qsecret-$v.tar.gz" >SHA256SUMS); ssh-keygen -q -Y sign -f "$T/key" -n qsecret-release "$T/link/SHA256SUMS" 2>/dev/null
expect "tarball with a symlink is refused" "unexpected entries" QSECRET_FROM="$T/link" -- "$T/get-test.sh"

expect "the real get.sh refuses the test key" "signature does not verify" QSECRET_FROM="$T/good" -- "$REPO/get.sh"

# --- downgrade --------------------------------------------------------------------------

mkdir -p "$(dirname "$VF")"; echo v9.9.10 >"$VF"
expect "older release than installed is refused" "older than the installed" QSECRET_FROM="$T/good" -- "$T/get-test.sh"
expect "QSECRET_ALLOW_DOWNGRADE allows it" ok QSECRET_FROM="$T/good" QSECRET_ALLOW_DOWNGRADE=1 -- "$T/get-test.sh"
echo v9.9.8 >"$VF"
expect "newer release than installed is fine" ok QSECRET_FROM="$T/good" -- "$T/get-test.sh"
rm -f "$VF"

# --- download path (stub curl plays GitHub) ---------------------------------------------

export QT_GET=$T
mkdir -p "$T/srv"
cp "$T/good/"* "$T/srv/"
cp "$T/srv/SHA256SUMS" "$T/srv/asset-1"; cp "$T/srv/SHA256SUMS.sig" "$T/srv/asset-2"; cp "$T/srv/qsecret-$v.tar.gz" "$T/srv/asset-3"
rel='{"draft": false, "tag_name": "'$v'", "assets": [{"id": 1, "name": "SHA256SUMS"}, {"id": 2, "name": "SHA256SUMS.sig"}, {"id": 3, "name": "qsecret-'$v'.tar.gz"}]}'
# A newer draft (no signature yet) is listed first; get.sh must skip it.
printf '[{"draft": true, "tag_name": "v9.9.10", "assets": []}, %s]\n' "$rel" >"$T/srv/list.json"
printf '%s\n' "$rel" >"$T/srv/tag-$v.json"
PATH=$REPO/tests/stubs:$PATH

: >"$T/curl.log"
expect "public download: skips the draft, takes the newest release" ok PATH="$PATH" QT_GET="$T" -- "$T/get-test.sh"
grep -q "release $v" "$T/out" && ok "picked $v, not the draft" || bad "picked $v, not the draft"

: >"$T/curl.log"
expect "private download with a token" ok PATH="$PATH" QT_GET="$T" GITHUB_TOKEN=test-token -- "$T/get-test.sh"
grep -q "releases/assets/3" "$T/curl.log" && ok "used the API asset URLs" || bad "used the API asset URLs"
! grep -q test-token "$T/curl.log" && ok "token never on curl's command line" || bad "token never on curl's command line"

expect "wrong token is refused" "" PATH="$PATH" QT_GET="$T" GITHUB_TOKEN=wrong -- "$T/get-test.sh"
expect "a pinned version is used" ok PATH="$PATH" QT_GET="$T" QSECRET_VERSION="$v" -- "$T/get-test.sh"
expect "a missing version fails" "not found" PATH="$PATH" QT_GET="$T" QSECRET_VERSION=v1.2.3 -- "$T/get-test.sh"

echo
echo "$pass passed, $failed failed"
# Explicit exit: at a normal end of script, the EXIT trap's status would replace ours.
exit $(( failed == 0 ? 0 : 1 ))
