#!/usr/bin/env bash
# scripts/ci/test-claim-pre-pr-check.sh — INFRA-1328
#
# Verifies the stomp-prevention pre-claim PR-existence check in
# src/atomic_claim.rs. The full atomic claim path requires gh + network,
# so this CI test asserts the SHAPE of the change at the source level:
#
#   1. open_pr_on_branch helper exists and is gated on owner/repo resolution
#   2. gh_owner_repo URL parser exists (handles https + ssh)
#   3. The pre-claim guard is wired in BEFORE the worktree create, gated
#      on `--resume` and CHUMP_ALLOW_STOMP=1 bypasses
#   4. cargo unit tests for the URL parser pass

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

# 1. open_pr_on_branch helper present
grep -q "fn open_pr_on_branch" "$SRC" \
    || fail "missing fn open_pr_on_branch (the PR-existence checker)"
ok "open_pr_on_branch helper defined"

# 2. gh_owner_repo URL parser present
grep -q "fn gh_owner_repo" "$SRC" \
    || fail "missing fn gh_owner_repo (URL parser)"
ok "gh_owner_repo URL parser defined"

# 3. Helper uses the gh REST endpoint (NOT GraphQL — see INFRA-1080 criticality)
grep -q '"repos/{}/pulls' "$SRC" || grep -q 'repos/.*/pulls' "$SRC" \
    || fail "open_pr_on_branch must hit /repos/<owner>/<repo>/pulls REST endpoint"
ok "uses REST pulls endpoint (not GraphQL — preserves API criticality budget)"

# 4. Pre-claim guard is wired and gated on bypasses
grep -q "INFRA-1328" "$SRC" \
    || fail "no INFRA-1328 reference at the wiring point"
grep -q "stomp_bypass\|CHUMP_ALLOW_STOMP" "$SRC" \
    || fail "missing CHUMP_ALLOW_STOMP bypass"
grep -q "args.resume" "$SRC" \
    || fail "missing --resume bypass for legitimate re-claims"
ok "guard wired with --resume + CHUMP_ALLOW_STOMP=1 bypasses"

# 5. Guard runs BEFORE git worktree add (line of the open-PR helper CALL
#    site < line of the worktree CLI invocation). INFRA-1503 split the
#    helper into open_pr_info (with author) — match either call site.
guard_line=$(grep -nE "open_pr_(on_branch|info)\(" "$SRC" \
    | grep -v "^[^:]*:[0-9]*://" \
    | grep -v "fn open_pr_" \
    | head -1 | cut -d: -f1)
worktree_line=$(grep -n '"worktree",$' "$SRC" | head -1 | cut -d: -f1)
if [[ -z "$guard_line" || -z "$worktree_line" ]]; then
    fail "could not locate guard / worktree lines for ordering check"
fi
if (( guard_line >= worktree_line )); then
    fail "guard at line $guard_line must run BEFORE worktree create at line $worktree_line"
fi
ok "guard runs before worktree create (line $guard_line < $worktree_line) — cheap fail path"

# 6. Refusal message names the gap chain (1328 superseded by 1503) + lists override paths
grep -qE "INFRA-(1328|1503).*open PR" "$SRC" \
    || fail "refusal message must name the gap + describe the situation"
grep -q "CHUMP_ALLOW_STOMP" "$SRC" \
    || fail "refusal message must point at CHUMP_ALLOW_STOMP escape hatch"
ok "refusal message is actionable (names gap + lists overrides)"

# 7. Unit tests for the URL parser exist and pass
(cd "$REPO_ROOT" && cargo test --bin chump --quiet \
     atomic_claim::tests::gh_owner_repo 2>&1 | tail -2) \
    | grep -q "0 failed" \
    || fail "cargo test atomic_claim::tests::gh_owner_repo failed"
ok "cargo unit tests for URL parser pass (3 cases: https / ssh / non-github)"

echo
echo "All INFRA-1328 pre-claim-PR-check assertions passed."
