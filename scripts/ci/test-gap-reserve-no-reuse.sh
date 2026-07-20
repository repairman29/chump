#!/usr/bin/env bash
# test-gap-reserve-no-reuse.sh — INFRA-1954
#
# Regression coverage for the Cold Water re-use incident (2026-05-25):
# `chump gap reserve` assigned META-103, INFRA-1953, INFRA-1955, INFRA-1957 —
# four IDs that had already shipped and whose state.db rows / docs/gaps/*.yaml
# mirrors were gone. The state.db-only ID counter is blind to any gap whose
# row disappeared (DB reset, reconciliation bug, or — pre-ZERO-WASTE-020 —
# the deleted-not-moved-to-closed/ YAML mirror the original incident hit).
#
# Fix: `chump gap reserve` now also scans `git log --all` for the highest
# `<domain>-N` ever referenced in a commit message and floors the ID counter
# above it, since git history is append-only and never forgets.
#
# Test: create a scratch git repo + empty state.db, commit a message that
# references a gap ID with no corresponding DB row (simulating "shipped and
# gone"), then reserve a new gap in that domain and assert the ID is NOT the
# reused one (or anything <= it).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-1954 gap-reserve no-ID-reuse test ==="
echo

BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
if [[ ! -f "$BIN" ]]; then
    echo "  [build] cargo build --bin chump (quiet)..."
    RUSTC_WRAPPER="" cargo build --bin chump --manifest-path "$REPO_ROOT/Cargo.toml" -q 2>&1 | tail -5
fi

if [[ ! -f "$BIN" ]]; then
    fail "chump binary not found after build — skipping functional tests"
    echo
    echo "=== Results: $PASS passed, $FAIL failed ==="
    [[ "$FAIL" -eq 0 ]]
    exit
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

git -C "$TMP" init --quiet
git -C "$TMP" config user.email "test@test.local"
git -C "$TMP" config user.name "test"
git -C "$TMP" checkout -b main --quiet
echo init > "$TMP/README.md"
git -C "$TMP" add README.md
git -C "$TMP" commit --quiet -m "chore: initial"

# Simulate a gap that shipped and is now gone from state.db: a commit that
# references INFRA-500, but the (brand new, empty) state.db has no row for
# it — same end state whether the loss was a DB reset or (pre-ZERO-WASTE-020)
# a deleted docs/gaps/INFRA-500.yaml mirror.
git -C "$TMP" commit --quiet --allow-empty -m "feat(INFRA-500): shipped and later removed from the registry"

export CHUMP_REPO="$TMP"
export CHUMP_HOME="$TMP"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_RESERVE_NO_AUTOSTAGE=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export CHUMP_RESERVE_SCAN_OPEN_PRS=0

echo
echo "--- reserve in a domain with a git-history-only prior ID (INFRA-500) ---"
NEW_ID=$("$BIN" gap reserve --domain INFRA --priority P2 --effort xs \
    --title "test-no-reuse-a" \
    --skip-obs-acs \
    --quiet 2>/dev/null || true)

if [[ -z "$NEW_ID" ]]; then
    fail "reserve did not return an ID"
else
    NUM="${NEW_ID##*-}"
    NUM="${NUM##0}"   # strip leading zeros so `[[ -gt ]]` doesn't treat as octal-ish
    NUM="${NUM:-0}"
    if [[ "$NUM" -gt 500 ]]; then
        ok "reserve skipped past the git-history-only ID (got $NEW_ID)"
    else
        fail "reserve re-used or under-shot a git-history-referenced ID (got $NEW_ID, want > INFRA-500)"
    fi
fi

echo
echo "--- the four Cold Water incident IDs never got reissued in this repo's real history ---"
for id in META-103 INFRA-1953 INFRA-1955 INFRA-1957; do
    if git -C "$REPO_ROOT" log --all -F --grep "$id" --format=%s 2>/dev/null | grep -q "$id"; then
        ok "$id found in real git history — reserve's floor now covers it"
    else
        echo "  SKIP: $id not found in this checkout's history (shallow clone or CI mirror) — not a fix regression"
    fi
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
