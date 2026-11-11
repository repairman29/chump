#!/usr/bin/env bash
# RESILIENT-1480: registry-conflict-heal heals registry-only conflicts, flags others.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/w" 2>/dev/null
cd "$T/w"; git config user.email t@t; git config user.name t
mkdir -p scripts/ci scripts/git scripts/ops docs/observability .chump-locks
cp "$HERE/scripts/git/merge-driver-union.sh" scripts/git/
printf 'A\nB\n' > scripts/ci/env-vars-internal.txt; echo code > code.txt
git add -A; git commit -qm base; git branch -M main; git push -q origin main
mk() { git checkout -q -b "$1" main; shift; "$@"; git add -A; git commit -qm x; git push -q origin HEAD; git checkout -q main; }
mk pr1 bash -c 'echo X1 >> scripts/ci/env-vars-internal.txt'
mk pr2 bash -c 'echo X2 >> scripts/ci/env-vars-internal.txt'
mk pr3 bash -c 'echo X3 >> scripts/ci/env-vars-internal.txt; echo changed > code.txt'
git checkout -q main; echo X0 >> scripts/ci/env-vars-internal.txt; echo other > code.txt; git commit -qam main-moves; git push -q origin main
mkdir bin; printf '#!/bin/sh\necho MERGEABLE\n' > bin/gh; chmod +x bin/gh
cat > prs.json <<J
[{"number":1,"headRefName":"pr1","mergeable":"CONFLICTING"},{"number":2,"headRefName":"pr2","mergeable":"CONFLICTING"},{"number":3,"headRefName":"pr3","mergeable":"CONFLICTING"}]
J
mkdir -p scripts/ops; cp "$HERE/scripts/ops/registry-conflict-heal.sh" scripts/ops/
out="$(PATH="$PWD/bin:$PATH" REGISTRY_HEAL_PR_JSON=prs.json REGISTRY_HEAL_STATE_DIR="$T/st" REGISTRY_HEAL_WT_ROOT="$T/wt" bash scripts/ops/registry-conflict-heal.sh 2>&1)"
echo "$out"
echo "$out" | grep -q "healed=2 flagged=1" || { echo FAIL summary; exit 1; }
git fetch -q origin
for b in pr1 pr2; do
  git show "origin/$b:scripts/ci/env-vars-internal.txt" | grep -q X0 || { echo "FAIL $b missing main line"; exit 1; }
  git show "origin/$b:scripts/ci/env-vars-internal.txt" | grep -q "X${b#pr}" || { echo "FAIL $b lost own line"; exit 1; }
  git merge-base --is-ancestor origin/main "origin/$b" || { echo "FAIL $b not on main"; exit 1; }
done
git merge-base --is-ancestor origin/main origin/pr3 && { echo "FAIL pr3 touched"; exit 1; }
echo PASS
