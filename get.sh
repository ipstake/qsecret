#!/usr/bin/env bash
# Install qsecret on a Proxmox VE cluster from a signed GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/ipstake/qsecret/main/get.sh | sudo bash
#
# Run it on any one node: install.sh then installs on every node of the cluster.
# It verifies the release before running anything from it:
#   1. SHA256SUMS.sig is an SSH signature by a release key built into this script.
#   2. The tarball matches its line in SHA256SUMS.
#
# Options (environment):
#   QSECRET_VERSION=v1.0.0     a release tag; default: the latest release
#   GITHUB_TOKEN=...           for a private fork, or to avoid the API rate limit
#   QSECRET_FROM=/path/to/dir  use release files from a local folder, download nothing
#   QSECRET_NO_INSTALL=1       verify and unpack only, print where
#   QSECRET_ALLOW_DOWNGRADE=1  install a release older than the installed one
#
# A signed old release is still a valid release, so get.sh refuses to go below the version
# installed on this node (/usr/local/share/qsecret/VERSION) unless told to.
set -euo pipefail
umask 077

# Everything runs inside main, called on the last line, so a download that stops halfway
# runs nothing.
main() {
  local repo=ipstake/qsecret
  local version=${QSECRET_VERSION:-}
  local from=${QSECRET_FROM:-}
  local token=${GITHUB_TOKEN:-}

  # Keys allowed to sign releases. Namespace "qsecret-release" means a git commit signature
  # from the same key cannot pass as a release signature.
  local signers='qsecret-release namespaces="qsecret-release" sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBLQCHwmEYabSjhBCUqgWDUSlWkTgByN8JVtXRvbEw9pJCOKjmc7/Jacwcvie5P3e+sF4YcGNLcvimgTbFUrgOtsAAAAEc3NoOg== release-1
qsecret-release namespaces="qsecret-release" sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBH/+yA0ywoz6NQ6lCDIlu51P53PvkSwmXfpTgMDwvuQt4Yl6SaUOoSOTLAF4CBRyqTFwy6/5isyLrQvEPVfZq18AAAAEc3NoOg== release-2'

  say() { echo "qsecret-get: $*" >&2; }
  fail() { say "$*"; exit 1; }

  [[ $(id -u) == 0 ]] || fail "run as root (sudo)"
  if [[ -z ${QSECRET_NO_INSTALL:-} ]]; then
    command -v pveversion >/dev/null || fail "this is not a Proxmox VE node"
    [[ -e /etc/pve/.members ]] || fail "this node is not in a cluster"
  fi
  local t; for t in curl ssh-keygen sha256sum tar; do
    command -v "$t" >/dev/null || fail "missing $t"
  done

  # Global, not local: the EXIT trap runs after main returns.
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  # Fetch <release asset name> into $work. Public repos use the plain download URL; a private
  # repo needs the API asset URL and a token.
  local api=https://api.github.com/repos/$repo auth=()
  if [[ -n $token ]]; then
    # From a file, so the token never shows in ps.
    printf 'Authorization: Bearer %s\n' "$token" >"$work/auth"
    auth=(-H "@$work/auth")
  fi
  # Release JSON from the API; Perl and JSON.pm ship with Proxmox.
  local rel=""
  json() { printf '%s' "$rel" | perl -MJSON -e "my \$r = decode_json(join '', <STDIN>); $1" "${@:2}"; }
  fetch() {
    if [[ -n $from ]]; then
      [[ -f $from/$1 ]] || fail "release $version has no $1"
      cp "$from/$1" "$work/$1"; return
    fi
    if [[ -z $token ]]; then
      curl -fsSL -o "$work/$1" "https://github.com/$repo/releases/download/$version/$1"
      return
    fi
    local id
    id=$(json 'for (@{$r->{assets}}) { print $_->{id} if $_->{name} eq $ARGV[0] }' "$1")
    [[ -n $id ]] || fail "release $version has no asset $1"
    curl -fsSL "${auth[@]}" -H "Accept: application/octet-stream" -o "$work/$1" "$api/releases/assets/$id"
  }

  if [[ -n $from ]]; then
    [[ -n $version ]] || version=$(cd "$from" && ls qsecret-v*.tar.gz | sed 's/^qsecret-//; s/\.tar\.gz$//' | sort -V | tail -1)
  else
    if [[ -n $version ]]; then
      rel=$(curl -fsSL "${auth[@]}" "$api/releases/tags/$version") ||
        fail "release $version not found"
    else
      # "latest" skips pre-releases; fall back to the newest published release of any kind.
      # Drafts (not yet signed) show up in the list for maintainers; skip them.
      if ! rel=$(curl -fsSL "${auth[@]}" "$api/releases/latest" 2>/dev/null); then
        local list
        list=$(curl -fsSL "${auth[@]}" "$api/releases?per_page=20") ||
          fail "cannot list releases (network, or the API rate limit: set GITHUB_TOKEN)"
        rel=$(printf '%s' "$list" |
          perl -MJSON -e 'print encode_json((grep { !$_->{draft} } @{decode_json(join "", <STDIN>)})[0] // {})')
      fi
    fi
    version=$(json 'print $r->{tag_name} // ""')
  fi
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "no release found"
  local tarball=qsecret-$version.tar.gz
  say "release $version"

  local installed=""
  installed=$(cat /usr/local/share/qsecret/VERSION 2>/dev/null || true)
  if [[ $installed =~ ^v[0-9] && $installed != "$version" && -z ${QSECRET_ALLOW_DOWNGRADE:-} ]]; then
    [[ $(printf '%s\n%s\n' "$installed" "$version" | sort -V | tail -1) == "$version" ]] ||
      fail "release $version is older than the installed $installed. Set QSECRET_ALLOW_DOWNGRADE=1 if you mean it."
  fi

  fetch SHA256SUMS
  fetch SHA256SUMS.sig
  fetch "$tarball"

  printf '%s\n' "$signers" >"$work/allowed_signers"
  ssh-keygen -Y verify -f "$work/allowed_signers" -I qsecret-release -n qsecret-release \
    -s "$work/SHA256SUMS.sig" <"$work/SHA256SUMS" >/dev/null 2>&1 ||
    fail "SHA256SUMS signature does not verify against the release keys. Not installing."
  # Accept "hash  name" and "hash *name" (binary-mode marker).
  local want got
  want=$(grep -E "^[0-9a-f]{64} [ *]$tarball\$" "$work/SHA256SUMS" | cut -c1-64 || true)
  got=$(sha256sum <"$work/$tarball" | cut -c1-64)
  [[ -n $want && $want == "$got" ]] || fail "$tarball does not match SHA256SUMS. Not installing."
  say "signature and checksum ok"

  # Only plain files and folders under qsecret-<version>/, nothing outside it.
  tar -tvzf "$work/$tarball" | awk -v p="qsecret-$version/" '
    { type = substr($1, 1, 1); name = $NF }
    (type != "-" && type != "d") || index(name, p) != 1 || name ~ /(^|\/)\.\.(\/|$)/ { bad = 1; print "bad entry: " $0 > "/dev/stderr" }
    END { exit bad }' || fail "$tarball has unexpected entries. Not installing."

  local dest=/usr/local/src/qsecret-$version
  rm -rf "$dest"; mkdir -p "$dest"
  tar -xzf "$work/$tarball" -C "$dest" --strip-components=1 --no-same-owner
  if [[ -n ${QSECRET_NO_INSTALL:-} ]]; then
    say "verified and unpacked to $dest; not installing"
    return
  fi
  QSECRET_VERSION=$version bash "$dest/install.sh"
  say "installed $version on the cluster. Next: qsecret init (first time) or qsecret status"
}

main "$@"
