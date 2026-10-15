#!/usr/bin/env bash
# Cut a signed release. Run by the maintainer from a clean, pushed main.
#
#   scripts/release.sh v0.4.0
#   scripts/release.sh --verify-draft <dir> <tag>   only step 2, on files in <dir> (tests)
#
# 1. Make a signed tag on HEAD (or reuse one that is on HEAD and signed by a release key) and
#    push it. CI (.github/workflows/release.yml) runs the tests, checks the tag, builds
#    qsecret-<v>.tar.gz and SHA256SUMS, and makes a draft release.
# 2. Download the draft and check that the tarball holds exactly the tag's files (names,
#    types, modes, contents) and matches SHA256SUMS. CI is not trusted: a bad build is never
#    signed.
# 3. Sign SHA256SUMS (namespace qsecret-release) with git's SSH signer, check the signature
#    against the keys built into get.sh, upload it and publish the release.
#
# If step 2 or 3 fails, the draft stays a draft; get.sh never sees drafts.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
say() { echo "release: $*" >&2; }
fail() { say "$*"; exit 1; }

files=(README.md LICENSE get.sh install.sh qsecret qsecret-push.service qsecret-push.timer qsecret-check.service qsecret-check.timer)
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-64; }

# allowed_signers lines for the release keys in get.sh: <principal> <namespace> for each.
signers() {
  awk -v who="$1" -v ns="$2" '
    /^  local signers=/ { on = 1; sub(/^  local signers=\x27/, "") }
    on { line = $0; done = sub(/\x27$/, "", line); n = split(line, f, " ")
         printf "%s namespaces=\"%s\"", who, ns; for (i = 3; i <= n; i++) printf " %s", f[i]; print ""
         if (done) exit }' get.sh
}

# Step 2: <dir> holds qsecret-<tag>.tar.gz and SHA256SUMS from the draft.
verify_draft() {
  local dir=$1 v=$2 tmp want got
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  [[ -s $dir/qsecret-$v.tar.gz && -s $dir/SHA256SUMS ]] || fail "draft files missing in $dir"
  (( $(wc -l <"$dir/SHA256SUMS") == 1 )) || fail "SHA256SUMS has extra lines; not signing"
  want=$(grep -E "^[0-9a-f]{64} [ *]qsecret-$v.tar.gz\$" "$dir/SHA256SUMS" | cut -c1-64 || true)
  got=$(sha256 <"$dir/qsecret-$v.tar.gz")
  [[ -n $want && $want == "$got" ]] || fail "SHA256SUMS does not match the draft tarball; not signing"
  # Same names, types and modes, then same contents (symlinks compared as links).
  git archive --format=tar --prefix="qsecret-$v/" "$v" -- "${files[@]}" >"$tmp/tag.tar"
  listing() { tar -tvf "$1" | awk '{ print $1, $NF }' | sort; }
  gzip -dc "$dir/qsecret-$v.tar.gz" >"$tmp/ci.tar"
  [[ $(listing "$tmp/ci.tar") == "$(listing "$tmp/tag.tar")" ]] || fail "draft tarball entries differ from tag $v; not signing"
  mkdir -p "$tmp/ci" "$tmp/tag"
  tar -xf "$tmp/ci.tar" -C "$tmp/ci"; tar -xf "$tmp/tag.tar" -C "$tmp/tag"
  diff -r --no-dereference "$tmp/ci" "$tmp/tag" >/dev/null || fail "draft tarball contents differ from tag $v; not signing"
  say "draft matches tag $v"
}

if [[ ${1:-} == --verify-draft ]]; then
  verify_draft "${2:?dir}" "${3:?tag}"
  exit 0
fi

v=${1:?usage: scripts/release.sh vX.Y.Z}
[[ $v =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "bad version $v"
[[ $(git branch --show-current) == main ]] || fail "not on main"
[[ -z $(git status --porcelain) ]] || fail "working tree not clean"
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main is not pushed"

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# Step 1: the tag must be on HEAD and signed by a release key, new or reused.
git rev-parse -q --verify "refs/tags/$v" >/dev/null || git tag -s "$v" -m "qsecret $v"
[[ $(git rev-parse "$v^{commit}") == $(git rev-parse HEAD) ]] || fail "tag $v is not on HEAD; delete it or pick another version"
signers "$(git config user.email)" git >"$out/git_signers"
git -c gpg.ssh.allowedSignersFile="$out/git_signers" verify-tag "$v" >/dev/null 2>&1 ||
  fail "tag $v is not signed by a release key"
git push -q origin "refs/tags/$v"

say "waiting for CI to build the draft"
# Match the run by tag and commit: an earlier run for a re-made tag has the same name.
sha=$(git rev-parse "$v^{commit}")
run=""
for _ in $(seq 30); do
  run=$(gh run list --workflow release.yml --limit 20 --json databaseId,headBranch,headSha \
    --jq "first(.[] | select(.headBranch == \"$v\" and .headSha == \"$sha\") | .databaseId) // empty")
  [[ -n $run ]] && break
  sleep 5
done
[[ -n $run ]] || fail "no CI run for $v"
gh run watch "$run" --exit-status >/dev/null || fail "CI run $run failed: gh run view $run --log-failed"

gh release download "$v" -D "$out/draft" -p "qsecret-$v.tar.gz" -p SHA256SUMS
verify_draft "$out/draft" "$v"

# Step 3: sign, check against get.sh's keys, publish with the final notes.
key=$(git config user.signingkey)
signer=$(git config gpg.ssh.program || echo ssh-keygen)
"$signer" -Y sign -f "$key" -n qsecret-release "$out/draft/SHA256SUMS"
signers qsecret-release qsecret-release >"$out/release_signers"
ssh-keygen -Y verify -f "$out/release_signers" -I qsecret-release -n qsecret-release \
  -s "$out/draft/SHA256SUMS.sig" <"$out/draft/SHA256SUMS" >/dev/null ||
  fail "signature does not verify against get.sh keys; draft left unpublished"
gh release upload "$v" "$out/draft/SHA256SUMS.sig" --clobber
gh release edit "$v" --draft=false \
  --notes "Install on any one Proxmox VE node: \`curl -fsSL https://raw.githubusercontent.com/ipstake/qsecret/main/get.sh | sudo bash\`. get.sh checks SHA256SUMS.sig against the release keys built into it before it runs anything." >/dev/null
say "published $v"
