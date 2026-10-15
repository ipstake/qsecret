# qsecret

Deliver boot secrets to Proxmox VE containers when a quorum of cluster nodes agrees. No cloud
KMS, no human at boot.

The first use is an OpenBao static seal key: OpenBao unseals itself after a reboot or a power
outage, because 3 Proxmox nodes hand its key over. Any container can get secrets the same way.

## How it works

- One [age](https://github.com/FiloSottile/age) key pair per cluster.
  - The public key (recipient) is in `/etc/pve/priv/qsecret/recipient`. Any node can encrypt
    a secret for a container.
  - The private key (identity) is split with Shamir secret sharing (`ssss`), threshold 3.
    Each node holds one share, encrypted by its own TPM 2.0 with `systemd-creds`. One more
    share goes to offline storage.
- Secrets live in `/etc/pve/priv/qsecret/secrets/` as ciphertext plus a small config: target
  container, path under `/run`, owner, mode. pmxcfs copies them to every node. Only root can read.
- The node list and quorum come from `/etc/pve/.members`. qsecret keeps no list of its own.

`qsecret push` runs every 20 s on each node. For each secret whose container runs there:

1. It does nothing if the kill switch is set (`/etc/pve/priv/qsecret/disabled`), the cluster
   has no quorum, or fewer than 3 nodes are online.
2. It skips the secret if the container already has it at the current version.
3. It asks every online node for its share over root SSH, in parallel. A node gives its share
   only if it also sees quorum, and logs who asked.
4. It tries each set of 3 shares. A wrong share still combines into garbage, so it keeps the
   set whose public key matches the recipient. A stale share cannot block delivery.
5. It decrypts the secret and pipes it into `pct exec`. Inside the container the secret is
   written only if `/run` is a tmpfs, the path has no symlinks and the input is not empty.

The identity exists only in shell variables and pipes for one run, in a unit with no core
dumps and no swap. It never touches argv, env or disk.

`qsecret check` runs daily. It proves every node's share is part of a working set, so a bad
share shows up before an outage instead of during one.

## Security model

- A copied disk, Ceph snapshot or node backup cannot decrypt a share: that needs the TPM.
- Root on any one node can collect every share (Proxmox nodes trust each other's root over
  SSH) and decrypt every secret. Root on one node already controls every container, Ceph and
  `/etc/pve`, so qsecret adds no new weak point.
- Shares are not bound to PCRs, so kernel and firmware updates do not lock them. Booting the
  same machine into another OS with its own disk can decrypt that node's share.
- The quorum check stops a node that boots alone from releasing its share. It is a safety
  check, not a wall: root on that node can skip it.

## Supported

| | |
|---|---|
| Proxmox VE | 9 or newer (Debian 13). Proxmox VE 8 is not supported: its TPM library packages have other names. |
| Nodes | at least 3, every one with a TPM 2.0 (`/dev/tpmrm0`), all online during install |
| Guests | LXC containers only, not VMs (`pct exec`) |
| Containers | `sh`, `stat`, `mktemp` and a tmpfs `/run`, which any systemd-based image has |
| Cluster | standard Proxmox root SSH between nodes |

`install.sh` checks every node first and installs nothing if one fails. It installs `age`,
`ssss` and the `libtss2` libraries that `systemd-creds` loads for TPM support.

Tested on a 4-node Proxmox VE 9.1 cluster with Ceph: install, delivery after a container
reboot and after a node reboot, reshare, rotate, export, and the share check. The commands
also run in CI on a fake cluster (see Tests). The real TPM, pmxcfs and `pct exec` are only
covered by the real cluster.

## Install

On any one node of the cluster:

```
curl -fsSL https://raw.githubusercontent.com/ipstake/qsecret/main/get.sh | sudo bash
```

`get.sh` downloads the latest release and checks it before it runs anything from it:
`SHA256SUMS.sig` must be an SSH signature (namespace `qsecret-release`) by one of the release
keys written into `get.sh`, and the tarball must match `SHA256SUMS`. Then it runs
`install.sh`, which installs on every node over the cluster's root SSH. Run it again to update.

| Variable | Use |
|---|---|
| `QSECRET_VERSION=v1.0.0` | a specific release instead of the latest |
| `GITHUB_TOKEN=...` | for a private fork, or to avoid the API rate limit |
| `QSECRET_FROM=/dir` | release files from a local folder, no download (offline install) |
| `QSECRET_NO_INSTALL=1` | verify and unpack to `/usr/local/src/qsecret-<v>` only |
| `QSECRET_ALLOW_DOWNGRADE=1` | install a release older than the installed one |

To read it first: `curl -fsSLO .../get.sh`, read it, then `sudo bash get.sh`. Pass variables
through sudo, e.g. `curl ... | sudo QSECRET_VERSION=v1.0.0 bash`.

`get.sh` refuses to install a release older than the one installed (a validly signed old
release served as "latest" would otherwise pass). It also refuses a tarball with anything but
plain files and folders under `qsecret-<version>/`. To check the nodes without installing:
`sudo bash /usr/local/src/qsecret-<v>/install.sh --check`.

The root of trust is `get.sh` itself, fetched from `main`: it carries the release keys. Read
it before you pipe it into a shell, or pin it to a tag
(`.../qsecret/v1.0.0/get.sh` instead of `.../main/get.sh`).

### Tests

`sudo tests/run.sh` runs shellcheck, the `get.sh` checks and an end-to-end test on a fake
4-node cluster. Stubs in `tests/stubs` stand in for `ssh`, `pct` and `systemd-creds`. Each
fake container is a bubblewrap sandbox with its own `/run`. The fake cluster covers delivery,
re-delivery, quorum loss, a node down, the kill switch, a broken TPM, a wrong share, a non-tmpfs
`/run`, symlinks, export, reshare, rotate, and a rotate that stops halfway. CI runs it on every
push and before every release. It needs root, `age`, `ssss`, `bubblewrap`, `shellcheck`, `git`,
`script`, `rev` and Perl's JSON module.

Also covered: `get.sh` against a fake GitHub API (draft skipping, the token path, downgrade
refusal, bad tarballs), `install.sh --check` (Debian 12, Proxmox VE 8, no TPM, unreachable
or offline nodes), and `scripts/release.sh --verify-draft` (a draft that differs from its tag
in content, files, modes or links is never signed).

### How releases are made

CI never signs. `scripts/release.sh vX.Y.Z` (maintainer):

1. Makes a signed tag and pushes it. CI (`.github/workflows/release.yml`) runs the tests,
   checks the tag signature against the same release keys, builds the tarball and
   `SHA256SUMS`, and makes a draft release.
2. Downloads the draft and checks that the tarball holds exactly the tag's files and matches
   `SHA256SUMS`. A bad or tampered CI build is never signed.
3. Signs `SHA256SUMS` with the maintainer's hardware-backed SSH key, uploads the signature and
   publishes. `get.sh` ignores drafts, so nothing is installable before step 3.

## Use

```
sudo qsecret init                                 # once: key pair, shares, offline backup
printf %s "$value" | sudo qsecret add <name> <vmid> /run/qsecret/<file> <uid:gid> 0400
sudo qsecret status
```

`init`, `reshare` and `rotate` write the offline backup (offline share and identity) to
`/dev/shm` (memory) on the node. With `--stdout` they write it to stdout instead, so you can
send it anywhere. Put it in your password manager. The backup is written before any node gets
a share, so a failure halfway never loses the key.

Commands that output secrets refuse to write to a terminal. Redirect or pipe them. For
example, from your workstation over SSH:

```
ssh root@node1 qsecret export bao-seal > bao-seal.key       # one secret, plain
ssh root@node1 qsecret export > qsecret-public.tar.gz       # recipient, ciphertexts, configs
ssh root@node1 qsecret reshare --stdout > qsecret-offline.txt
```

With `--stdout`, qsecret logs the start of the backup's SHA-256. Compare it with
`sha256sum qsecret-offline.txt` before you rely on your copy: a pipe can accept the data while
the far end (SSH, a full disk) loses it.

Or, on the node, with Tailscale's Taildrop to another of your devices:

```
qsecret export bao-seal | tailscale file cp --name bao-seal.key - my-laptop:
```

In the container, bind-mount `/run/qsecret` into the service and make it wait for the file.
Example for OpenBao:

```yaml
entrypoint: ["/bin/sh", "-c", "until [ -s /openbao/seal/bao-seal.key ]; do sleep 5; done; exec docker-entrypoint.sh server"]
volumes:
  - /run/qsecret:/openbao/seal:ro
```

```hcl
seal "static" {
  current_key_id = "qsecret-1"
  current_key    = "file:///openbao/seal/bao-seal.key"
}
```

## Commands

| Command | Does |
|---|---|
| `init [--stdout]` | Make the key pair, enroll every node, write the offline backup |
| `reshare [--stdout] [--identity-stdin]` | New shares for the current nodes, same key pair |
| `rotate [--stdout]` | New key pair, re-encrypt every secret, new shares |
| `add [-f] <name> <vmid> <dest> [owner] [mode]` | Encrypt stdin as a secret; `-f` replaces |
| `remove <name>` | Forget a secret (the container keeps its copy until reboot) |
| `export [<name>]` | Public files as tar.gz, or one secret in plain text, to stdout |
| `push` | Deliver missing or changed secrets (timer) |
| `check` | Prove every node's share works (daily timer) |
| `status` | Show the setup, nothing secret |
| `enroll <recipient>` | Store this node's share from stdin (used by init and reshare) |
| `share` | Print this node's share (called by push over SSH) |
| `version` | The installed release |

## Node changes

- **Node added, replaced or reinstalled:** join it to the cluster, run `install.sh`, then
  `qsecret reshare`. Every node gets a new share, and a new offline backup is sent.
- **TPM cleared or motherboard swapped:** `qsecret reshare`.
- **Disk or node lost or stolen:** `qsecret rotate`, then delete the old offline backup.
- **Fewer than 3 nodes left:** `qsecret reshare --identity-stdin` with the identity from the
  offline backup. The same command finishes a `reshare` or `rotate` that stopped halfway.

With 4 nodes and threshold 3, one node can be down, the same as corosync quorum.

## License

Apache License 2.0. See [LICENSE](LICENSE).
