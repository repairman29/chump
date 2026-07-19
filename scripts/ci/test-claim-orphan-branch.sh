#!/usr/bin/env bash
# capability-guard-exempt: source-shape checks only; no binary build required
# scripts/ci/test-claim-orphan-branch.sh — INFRA-1730
#
# Verifies that `chump claim` auto-detects orphan branches left behind by a
# closed-without-merging PR and offers --rename (archive + start fresh) as a
# distinct path from --resume (continue the abandoned work).
#
# Coverage: SOURCE-level shape checks only (new flag, new detection helper,
# new emit functions, canonical event kinds, both bail-message hints).
# Smoke command to run manually against a live repo with an orphan branch:
#   chump claim <GAP-ID>            # should print the orphan hint + both options
#   chump claim <GAP-ID> --rename   # should archive the branch and proceed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

hdr "Round 1: source-level shape"

# 1. rename field on ClaimArgs
grep -q "pub rename: bool" "$SRC" \
    || fail "missing rename field on ClaimArgs"
ok "rename field present on ClaimArgs"

# 2. --rename flag parsed
grep -q '"--rename"' "$SRC" \
    || fail "missing --rename flag parsing in from_argv"
ok "--rename flag parsed in from_argv"

# 3. closed_pr_info detection helper present
grep -q "fn closed_pr_info" "$SRC" \
    || fail "missing fn closed_pr_info"
grep -q "state=closed" "$SRC" \
    || fail "closed_pr_info does not query gh with state=closed"
ok "closed_pr_info present and queries state=closed PRs"

# 4. emit_claim_orphan_branch_detected present + canonical kind
grep -q "fn emit_claim_orphan_branch_detected" "$SRC" \
    || fail "missing fn emit_claim_orphan_branch_detected"
grep -qE 'kind\\?":\\?"claim_orphan_branch_detected\\?"' "$SRC" \
    || fail "missing canonical kind string claim_orphan_branch_detected"
ok "emit_claim_orphan_branch_detected present + uses canonical kind"

# 5. emit_claim_orphan_branch_renamed present + canonical kind
grep -q "fn emit_claim_orphan_branch_renamed" "$SRC" \
    || fail "missing fn emit_claim_orphan_branch_renamed"
grep -qE 'kind\\?":\\?"claim_orphan_branch_renamed\\?"' "$SRC" \
    || fail "missing canonical kind string claim_orphan_branch_renamed"
ok "emit_claim_orphan_branch_renamed present + uses canonical kind"

# 6. bail message offers both --resume and --rename when branch already exists
grep -q "Pass --rename to archive the old branch and start fresh" "$SRC" \
    || fail "missing --rename hint in the existing-remote-branch bail message"
ok "--rename hint present alongside --resume in bail message"

# 7. --rename path archives via a timestamped branch name, then deletes the old ref
grep -q -- "-orphaned-" "$SRC" \
    || fail "missing orphaned-branch archive naming convention"
ok "--rename archives to a timestamped <branch>-orphaned-<epoch> name"

hdr "Round 2: registry hygiene"

REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: claim_orphan_branch_detected" "$REG" \
    || fail "claim_orphan_branch_detected not registered in EVENT_REGISTRY.yaml"
grep -q "kind: claim_orphan_branch_renamed" "$REG" \
    || fail "claim_orphan_branch_renamed not registered in EVENT_REGISTRY.yaml"
ok "both new event kinds registered in EVENT_REGISTRY.yaml"

RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
grep -q "claim_orphan_branch_detected" "$RESERVED" \
    || fail "claim_orphan_branch_detected missing from event-registry-reserved.txt"
grep -q "claim_orphan_branch_renamed" "$RESERVED" \
    || fail "claim_orphan_branch_renamed missing from event-registry-reserved.txt"
ok "both new kinds in event-registry-reserved.txt"

hdr "All checks passed"
exit 0
