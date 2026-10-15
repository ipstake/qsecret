#!/usr/bin/env bash
# Run every test: lint, get.sh checks, release.sh draft check, fake-cluster end to end
# (qsecret commands and install.sh's preflight). Needs root.
#   sudo tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
rc=0

echo "== lint"
scripts=(qsecret get.sh install.sh scripts/release.sh tests/*.sh tests/stubs/*)
for s in "${scripts[@]}"; do bash -n "$s" || rc=1; done
shellcheck -S warning "${scripts[@]}" || rc=1

echo "== get.sh"
bash tests/test_get.sh || rc=1

echo "== release.sh draft check"
bash tests/test_release.sh || rc=1

echo "== fake cluster"
bash tests/test_cluster.sh || rc=1

exit $rc
