#!/usr/bin/env bash
# Tests for scripts/release.sh --verify-draft: the check that a CI-built draft holds exactly
# the tag's files before the maintainer signs. Runs in a throwaway git repo.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /var/tmp/qsecret-rel.XXXXXX)
trap 'rm -rf "$T"' EXIT
v=v9.9.9
files=(README.md LICENSE get.sh install.sh qsecret qsecret-push.service qsecret-push.timer qsecret-check.service qsecret-check.timer)

mkdir -p "$T/repo/scripts"
(cd "$REPO" && cp "${files[@]}" "$T/repo/") && cp "$REPO/scripts/release.sh" "$T/repo/scripts/"
chmod 755 "$T/repo/qsecret"
(cd "$T/repo" && git init -q && git -c user.email=t@t -c user.name=t add -A &&
  git -c user.email=t@t -c user.name=t commit -q -m test && git tag "$v") || exit 2

# draft <dir>: a CI-like draft (tarball and SHA256SUMS) built from the tag.
draft() {
  mkdir -p "$1"
  (cd "$T/repo" && git archive --format=tar.gz --prefix="qsecret-$v/" -o "$1/qsecret-$v.tar.gz" "$v" -- "${files[@]}")
  (cd "$1" && sha256sum "qsecret-$v.tar.gz" >SHA256SUMS)
}
# rebuild <dir>: after changing $1/x/, pack it again with a matching SHA256SUMS.
rebuild() {
  tar -czf "$1/qsecret-$v.tar.gz" -C "$1/x" "qsecret-$v"
  (cd "$1" && sha256sum "qsecret-$v.tar.gz" >SHA256SUMS)
}
unpack() { mkdir -p "$1/x"; tar -xzf "$1/qsecret-$v.tar.gz" -C "$1/x"; }

pass=0 failed=0
expect() {  # expect <description> ok|<error text> <dir>
  if (cd "$T/repo" && bash scripts/release.sh --verify-draft "$3" "$v") >"$T/out" 2>&1; then got=ok; else got=fail; fi
  if [[ $2 == ok && $got == ok ]] || [[ $2 != ok && $got == fail ]] && grep -q -- "${2#ok}" "$T/out"; then
    echo "ok   - $1"; pass=$(( pass + 1 ))
  else echo "FAIL - $1"; sed 's/^/       /' "$T/out"; failed=$(( failed + 1 )); fi
}

draft "$T/good"
expect "draft built from the tag is accepted" ok "$T/good"

draft "$T/content"; unpack "$T/content"; echo "# changed" >>"$T/content/x/qsecret-$v/qsecret"; rebuild "$T/content"
expect "changed file content is refused" "contents differ" "$T/content"

draft "$T/extra"; unpack "$T/extra"; echo x >"$T/extra/x/qsecret-$v/extra"; rebuild "$T/extra"
expect "extra file is refused" "entries differ" "$T/extra"

draft "$T/mode"; unpack "$T/mode"; chmod 755 "$T/mode/x/qsecret-$v/README.md"; rebuild "$T/mode"
expect "changed file mode is refused" "entries differ" "$T/mode"

draft "$T/link"; unpack "$T/link"; rm "$T/link/x/qsecret-$v/get.sh"; ln -s README.md "$T/link/x/qsecret-$v/get.sh"; rebuild "$T/link"
expect "file replaced by a symlink is refused" "entries differ" "$T/link"

draft "$T/sum"; c=$(head -c1 "$T/sum/SHA256SUMS"); [[ $c == 0 ]] && n=1 || n=0; sed -i "1s/^./$n/" "$T/sum/SHA256SUMS"
expect "SHA256SUMS that does not match is refused" "does not match" "$T/sum"

draft "$T/lines"; echo "0000000000000000000000000000000000000000000000000000000000000000  other" >>"$T/lines/SHA256SUMS"
expect "SHA256SUMS with extra lines is refused" "extra lines" "$T/lines"

echo
echo "$pass passed, $failed failed"
# Explicit exit: at a normal end of script, the EXIT trap's status would replace ours.
exit $(( failed == 0 ? 0 : 1 ))
