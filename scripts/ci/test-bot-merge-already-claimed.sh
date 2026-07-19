#!/usr/bin/env bash
# scripts/ci/test-bot-merge-already-claimed.sh — INFRA-1901
#
# bot-merge.sh, invoked from inside a worktree that is already claimed by
# the calling session, used to unconditionally re-invoke `chump claim` and
# fall over on "worktree already exists" — forcing manual gh pr create / gh
# pr merge --auto recovery (2026-05-23: 3 of 4 sub-agents hit this).
#
# This test exercises the detection primitives bot-merge.sh now runs BEFORE
# calling `chump claim`: lease_worktree_from_statedb() resolving the lease
# row, and the pwd-vs-lease-worktree prefix comparison (including the
# /tmp -> /private/tmp symlink case on macOS). It does not invoke the full
# bot-merge.sh (which needs gh/network); it validates the building blocks
# the same way test-bot-merge-preflight.sh validates the exit-17 guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

echo "=== INFRA-1901 bot-merge already-claimed test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. lease_worktree_from_statedb resolves the worktree column ─────────────
echo "[1. lease_worktree_from_statedb reads the leases table]"

# shellcheck source=../lib/lease.sh
source "${REPO_ROOT}/scripts/lib/lease.sh"

FAKE_DB="${TMP}/state.db"
FAKE_WT="${TMP}/chump-INFRA-9999"
mkdir -p "$FAKE_WT"

command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not installed"; exit 0; }

sqlite3 "$FAKE_DB" "
CREATE TABLE leases (
    session_id  TEXT PRIMARY KEY,
    gap_id      TEXT NOT NULL,
    worktree    TEXT NOT NULL DEFAULT '',
    expires_at  INTEGER NOT NULL
);
INSERT INTO leases (session_id, gap_id, worktree, expires_at)
    VALUES ('fake-session-1', 'INFRA-9999', '${FAKE_WT}', 9999999999);
"

RESOLVED_WT="$(lease_worktree_from_statedb "INFRA-9999" "$FAKE_DB")"
if [[ "$RESOLVED_WT" == "$FAKE_WT" ]]; then
    ok "lease_worktree_from_statedb resolves the claimed worktree path"
else
    fail "expected '$FAKE_WT', got '$RESOLVED_WT'"
fi

EMPTY_WT="$(lease_worktree_from_statedb "INFRA-0000" "$FAKE_DB")"
if [[ -z "$EMPTY_WT" ]]; then
    ok "lease_worktree_from_statedb returns empty for an unknown gap"
else
    fail "expected empty result for unknown gap, got '$EMPTY_WT'"
fi

# ── 2. pwd-vs-lease prefix comparison (mirrors bot-merge.sh's inline logic) ──
echo
echo "[2. pwd inside the lease worktree is detected, outside is not]"

detect_already_in_lease_wt() {
    local pwd_path="$1" lease_wt="$2"
    local pwd_real lease_wt_real
    pwd_real="$(cd "$pwd_path" 2>/dev/null && pwd -P || printf '%s' "$pwd_path")"
    lease_wt_real="$(cd "$lease_wt" 2>/dev/null && pwd -P || printf '%s' "$lease_wt")"
    case "$pwd_real" in
        "$lease_wt_real"|"$lease_wt_real"/*) return 0 ;;
        *) return 1 ;;
    esac
}

SUBDIR="${FAKE_WT}/src"
mkdir -p "$SUBDIR"

if detect_already_in_lease_wt "$FAKE_WT" "$FAKE_WT"; then
    ok "exact worktree match detected"
else
    fail "exact worktree match not detected"
fi

if detect_already_in_lease_wt "$SUBDIR" "$FAKE_WT"; then
    ok "subdirectory-of-worktree match detected"
else
    fail "subdirectory-of-worktree match not detected"
fi

OUTSIDE_DIR="${TMP}/somewhere-else"
mkdir -p "$OUTSIDE_DIR"
if detect_already_in_lease_wt "$OUTSIDE_DIR" "$FAKE_WT"; then
    fail "unrelated directory was wrongly matched as inside the lease worktree"
else
    ok "unrelated directory is correctly NOT matched"
fi

# ── 3. AC#3: /tmp vs /private/tmp symlink resolution (macOS) ────────────────
echo
echo "[3. /tmp vs /private/tmp symlink resolves to the same real path]"

if [[ -L /tmp && "$(readlink /tmp)" =~ ^/?private/tmp$ ]]; then
    TMP_ALIAS="/tmp/$(basename "$FAKE_WT" | sed 's/.*chump-//')-symlink-check-$$"
    mkdir -p "/private${TMP_ALIAS}" 2>/dev/null || true
    if [[ -d "/private${TMP_ALIAS}" ]]; then
        if detect_already_in_lease_wt "$TMP_ALIAS" "/private${TMP_ALIAS}"; then
            ok "/tmp path matches its /private/tmp lease-recorded equivalent"
        else
            fail "/tmp vs /private/tmp symlink resolution failed"
        fi
        rm -rf "/private${TMP_ALIAS}"
    else
        echo "SKIP: could not create /private/tmp test dir (permissions)"
    fi
else
    echo "SKIP: not on a system with /tmp -> /private/tmp symlink"
fi

# ── 4. bot-merge.sh wires the skip-claim path + bypass flag ─────────────────
echo
echo "[4. bot-merge.sh source contains the INFRA-1901 skip-claim wiring]"

BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"

if grep -q 'lease_worktree_from_statedb' "$BOT_MERGE"; then
    ok "bot-merge.sh calls lease_worktree_from_statedb before chump claim"
else
    fail "bot-merge.sh does not reference lease_worktree_from_statedb"
fi

if grep -q '_already_in_lease_wt' "$BOT_MERGE"; then
    ok "bot-merge.sh tracks _already_in_lease_wt"
else
    fail "bot-merge.sh missing _already_in_lease_wt detection variable"
fi

if grep -q 'CHUMP_BOT_MERGE_CLAIM_LAX' "$BOT_MERGE"; then
    ok "bot-merge.sh honors CHUMP_BOT_MERGE_CLAIM_LAX bypass"
else
    fail "bot-merge.sh missing CHUMP_BOT_MERGE_CLAIM_LAX bypass"
fi

if grep -q 'bot_merge_skip_claim_lax' "$BOT_MERGE"; then
    ok "bot-merge.sh emits bot_merge_skip_claim_lax on bypass"
else
    fail "bot-merge.sh does not emit bot_merge_skip_claim_lax on bypass"
fi

REGISTRY="${REPO_ROOT}/docs/observability/EVENT_REGISTRY.yaml"
if grep -q 'bot_merge_skip_claim_lax' "$REGISTRY"; then
    ok "EVENT_REGISTRY.yaml registers bot_merge_skip_claim_lax"
else
    fail "EVENT_REGISTRY.yaml missing bot_merge_skip_claim_lax"
fi

echo
echo "=== INFRA-1901 tests complete ==="
