#!/usr/bin/env bash
# test-orphan-pr-closer.sh — INFRA-1139
#
# Static + behavioral checks for scripts/coord/orphan-pr-closer.sh.
# We don't hit the live GitHub API; we verify the script's surface and
# its safety defaults (dry-run by default, freshness gate, idempotency).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/orphan-pr-closer.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$SCRIPT" ]] || fail "script missing or not executable: $SCRIPT"
ok "orphan-pr-closer.sh exists and is executable"

# Safety defaults
grep -q '^APPLY=0' "$SCRIPT" || fail "APPLY does not default to 0 (dry-run)"
grep -q 'CHUMP_ORPHAN_PR_CLOSER:-1' "$SCRIPT" || fail "missing CHUMP_ORPHAN_PR_CLOSER bypass"
grep -q 'CHUMP_ORPHAN_PR_FRESHNESS_MIN:-30' "$SCRIPT" || fail "missing 30-min freshness default"
ok "dry-run default + bypass + freshness defaults wired"

# Freshness gate present
grep -q 'updated.*cutoff' "$SCRIPT" || fail "freshness comparison not present"
ok "freshness gate present"

# Seen-file idempotency
grep -q 'orphan-pr-seen.txt' "$SCRIPT" || fail "missing idempotency seen-file"
grep -q 'grep -qxF "closed:\$pr"' "$SCRIPT" || fail "seen-file lookup pattern missing"
ok "idempotency via seen-file"

# Gap status check is gated on status=done
grep -q '"\$status" != "done"' "$SCRIPT" || fail "does not gate on gap status=done"
ok "only acts on gaps with status=done"

# Closed-pr edge case: don't close a PR whose gap thinks IT is the closing PR
grep -q 'closed_pr.*pr' "$SCRIPT" || fail "missing closed_pr-self edge case"
ok "skips PRs whose own number is the gap's closed_pr (waiting-to-merge case)"

# Ambient events
grep -q 'orphan_pr_candidate' "$SCRIPT" || fail "missing orphan_pr_candidate event"
grep -q 'orphan_pr_closed' "$SCRIPT" || fail "missing orphan_pr_closed event"
grep -q 'orphan_pr_close_failed' "$SCRIPT" || fail "missing orphan_pr_close_failed event"
ok "emits all 3 ambient kinds"

# EVENT_REGISTRY registrations
ER="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q '^  - kind: orphan_pr_candidate' "$ER" || fail "EVENT_REGISTRY missing orphan_pr_candidate"
grep -q '^  - kind: orphan_pr_closed' "$ER" || fail "EVENT_REGISTRY missing orphan_pr_closed"
grep -q '^  - kind: orphan_pr_close_failed' "$ER" || fail "EVENT_REGISTRY missing orphan_pr_close_failed"
ok "EVENT_REGISTRY registers all 3 kinds"

# REST-only — should never call gh pr list / gh pr view (which use GraphQL)
# in normal flow. We allow it for fallback but the main path must be REST.
grep -q 'gh api .*pulls?state=open' "$SCRIPT" || fail "primary PR listing must use REST gh api"
if grep -E '^[^#]*gh pr (list|view)' "$SCRIPT" >/dev/null; then
    fail "uses GraphQL gh pr commands instead of REST — INFRA-1080 violation"
fi
ok "uses REST (gh api) — no GraphQL on primary path"

# Bypass via title token
grep -q 'orphan-pr-closer-skip' "$SCRIPT" || fail "missing operator escape hatch (title token)"
ok "operator escape hatch via PR title token"

# Dry-run smoke: --help prints usage from header without error
"$SCRIPT" --help >/dev/null 2>&1 || fail "--help exits non-zero"
ok "--help runs without error"

# Disabled via env var: exits 0 with skip message
out=$(CHUMP_ORPHAN_PR_CLOSER=0 "$SCRIPT" 2>&1 || true)
echo "$out" | grep -q "skipping" || fail "CHUMP_ORPHAN_PR_CLOSER=0 does not skip"
ok "CHUMP_ORPHAN_PR_CLOSER=0 disables the script"

echo
echo "All INFRA-1139 orphan-pr-closer tests passed."
