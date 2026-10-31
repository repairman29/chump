#!/usr/bin/env bash
# ZERO-WASTE-150: fixture-leak guards. Hermetic, no build.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
chk() { if ! "$@"; then echo "FAIL: $*"; fail=1; fi; }

# AC4: the 21 leaked NOTES files are gone and no new ones land.
n=$(find docs -maxdepth 1 \( -name 'RESILIENT-*-NOTES.md' -o -name 'INFRA-*-NOTES.md' \) | wc -l)
[ "$n" -eq 0 ] || { echo "FAIL: $n docs/{RESILIENT,INFRA}-NNNN-NOTES.md present"; fail=1; }
base="$(git merge-base HEAD origin/main 2>/dev/null || true)"
if [ -n "$base" ]; then
  added=$(git diff --name-only --diff-filter=A "$base" HEAD -- 'docs/*-NOTES.md' | wc -l)
  [ "$added" -eq 0 ] || { echo "FAIL: new docs/<ID>-NOTES.md added"; fail=1; }
fi

# AC2: --not-a-bug exists in the CLI, store, registry, and worker prompt.
chk grep -q -- '--not-a-bug' src/main.rs
chk grep -q 'fn close_not_a_bug' crates/chump-gap-store/src/lib.rs
chk grep -q 'kind: gap_closed_not_a_bug' docs/observability/EVENT_REGISTRY.yaml
chk grep -q -- "--not-a-bug --reason" scripts/dispatch/worker.sh

# Guards: fixture-title refusal + hollow-gap preflight.
chk grep -q 'fn is_fixture_title' crates/chump-gap-store/src/lib.rs
chk grep -q 'store.is_hollow' src/main.rs

[ "$fail" -eq 0 ] && echo "ok: ZERO-WASTE-150 guards present"
exit "$fail"
