#!/usr/bin/env bash
# test-gap-reserve-no-reuse.sh — INFRA-1954 regression test.
#
# During the 2026-05-25 Cold Water cycle, `chump gap reserve` handed out four
# IDs (META-103, INFRA-1953, INFRA-1955, INFRA-1957) that had already shipped
# and been removed from the live registry — state.db's counter never saw
# those old rows again, so the naive "MAX(id)+1" logic happily reused them.
# Git commit history never forgets, so `reserve()` now runs a git-history
# check per candidate ID (see `git_id_referenced` in
# crates/chump-gap-store/src/lib.rs) and skips any ID that already appears
# in a past commit message on any ref.
#
# This is a thin wrapper over the Rust unit tests that exercise that logic
# directly (a real reserve → ship → re-reserve cycle isn't cheap to
# reproduce in bash since the per-file YAML mirror system that used to back
# "ship moves the file" was retired in ZERO-WASTE-020 — state.db + git
# history are the only two sources of truth left). The two tests:
#
#   reserve_skips_id_already_referenced_in_git_history — plants a commit
#     mentioning "COLDWATER-001" in a fresh git repo, then calls reserve()
#     on a domain with an EMPTY state.db counter (the exact Cold Water
#     shape: naive next-ID would be COLDWATER-001) and asserts the result
#     is COLDWATER-002, i.e. the reused ID was skipped.
#
#   reserve_does_not_skip_id_absent_from_git_history — sanity check that an
#     ID with no git-history hit is NOT skipped (guards against the fix
#     being overzealous and blocking every reserve).
#
# Exit: 0 = both checks pass, 1 = failure.
#
# Usage:
#   bash scripts/ci/test-gap-reserve-no-reuse.sh [--skip-cargo]

set -euo pipefail

# shellcheck source=lib/gate-emit.sh
source "$(dirname "$0")/lib/gate-emit.sh" 2>/dev/null || true
gate_emit_start "INFRA-1954" "$*"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; gate_emit_result "INFRA-1954" "fail" "gap-reserve-reuse-guard-broken" "$*"; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

SKIP_CARGO=0
for arg in "$@"; do
    [[ "$arg" == "--skip-cargo" ]] && SKIP_CARGO=1
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

if [[ "$SKIP_CARGO" -eq 1 ]]; then
    info "skipped (--skip-cargo)"
    gate_emit_result "INFRA-1954" "pass" "skip-cargo" ""
    exit 0
fi

info "Running gap_store::tests::reserve_skips_id_already_referenced_in_git_history …"
if cd "$REPO_ROOT" && cargo test -p chump-gap-store --lib --quiet \
    -- tests::reserve_skips_id_already_referenced_in_git_history 2>&1 | tail -10; then
    pass "Check 1: reserve() skips a candidate ID already referenced in git history"
else
    fail "Check 1: reserve_skips_id_already_referenced_in_git_history failed — a shipped-and-forgotten ID would be reused"
fi

info "Running gap_store::tests::reserve_does_not_skip_id_absent_from_git_history …"
if cd "$REPO_ROOT" && cargo test -p chump-gap-store --lib --quiet \
    -- tests::reserve_does_not_skip_id_absent_from_git_history 2>&1 | tail -10; then
    pass "Check 2: reserve() does not skip IDs with no git-history hit"
else
    fail "Check 2: reserve_does_not_skip_id_absent_from_git_history failed — the guard is overzealous"
fi

echo ""
echo "INFRA-1954: gap-reserve git-history reuse guard checks passed."
gate_emit_result "INFRA-1954" "pass" "" ""
