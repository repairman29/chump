#!/usr/bin/env bash
# scripts/ci/test-post-rebase-verify.sh — INFRA-1526
#
# Unit tests for scripts/coord/post-rebase-verify.sh.
# Creates a synthetic git repo, manufactures a pre-rebase and post-rebase
# state, and verifies the detector correctly identifies hunk drops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/../coord/post-rebase-verify.sh"

PASS=0
FAIL=0

ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

_setup_repo() {
    local d="$1"
    git -C "$d" init -q -b base
    git -C "$d" config user.email "test@chump"
    git -C "$d" config user.name "Test"
    printf '# base\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "initial"
}

# ── Test 1: no drop — file retained after rebase ─────────────────────────────
T=$(mktemp -d)
_setup_repo "$T"
AMBIENT="$T/ambient.jsonl"

# Feature branch: add 60 lines to bigfile.rs
git -C "$T" checkout -q -b feature
printf '%s\n' $(seq 1 60 | sed 's/.*/line&/') > "$T/bigfile.rs"
git -C "$T" add bigfile.rs
git -C "$T" commit -q -m "add bigfile.rs"
ORIG_HEAD="$(git -C "$T" rev-parse HEAD)"

# Advance base branch, then rebase feature onto it (file still present)
git -C "$T" checkout -q base
printf 'extra\n' >> "$T/README.md"
git -C "$T" add README.md
git -C "$T" commit -q -m "base advance"
git -C "$T" checkout -q feature
git -C "$T" rebase base -q

# Verify: should exit 0 (no drop)
if bash "$VERIFY" --base base --orig-head "$ORIG_HEAD" \
        --repo "$T" --ambient "$AMBIENT" --threshold 50 >/dev/null 2>&1; then
    ok "no-drop scenario exits 0"
else
    fail "no-drop scenario exits 0"
fi

if [[ ! -s "$AMBIENT" ]] || ! grep -q "rebase_hunk_dropped" "$AMBIENT" 2>/dev/null; then
    ok "no-drop: no rebase_hunk_dropped event emitted"
else
    fail "no-drop: unexpected rebase_hunk_dropped event"
fi

rm -rf "$T"

# ── Test 2: drop detected — file present before, absent after ────────────────
T=$(mktemp -d)
_setup_repo "$T"
AMBIENT="$T/ambient.jsonl"

# Feature branch: add 60 lines to bigfile.rs
git -C "$T" checkout -q -b feature
printf '%s\n' $(seq 1 60 | sed 's/.*/line&/') > "$T/bigfile.rs"
git -C "$T" add bigfile.rs
git -C "$T" commit -q -m "add bigfile.rs"
ORIG_HEAD="$(git -C "$T" rev-parse HEAD)"

# Simulate a broken rebase: manually wipe bigfile.rs on HEAD
# (models what a bad merge driver does — content silently gone)
: > "$T/bigfile.rs"
git -C "$T" add bigfile.rs
git -C "$T" commit -q -m "simulated silent drop"

# Verify: should exit 1 and emit rebase_hunk_dropped
if bash "$VERIFY" --base base --orig-head "$ORIG_HEAD" \
        --repo "$T" --ambient "$AMBIENT" --threshold 50 >/dev/null 2>&1; then
    fail "drop scenario exits non-zero"
else
    ok "drop scenario exits non-zero"
fi

if grep -q "rebase_hunk_dropped" "$AMBIENT" 2>/dev/null; then
    ok "drop: rebase_hunk_dropped event emitted"
else
    fail "drop: rebase_hunk_dropped event not found in ambient log"
fi

if grep -q '"file":"bigfile.rs"' "$AMBIENT" 2>/dev/null; then
    ok "drop: event names the dropped file"
else
    fail "drop: event missing file field"
fi

rm -rf "$T"

# ── Test 3: file below threshold — no false positive ─────────────────────────
T=$(mktemp -d)
_setup_repo "$T"
AMBIENT="$T/ambient.jsonl"

# Feature branch: add only 10 lines (below threshold of 50)
git -C "$T" checkout -q -b feature
printf '%s\n' $(seq 1 10 | sed 's/.*/line&/') > "$T/small.rs"
git -C "$T" add small.rs
git -C "$T" commit -q -m "add small.rs"
ORIG_HEAD="$(git -C "$T" rev-parse HEAD)"

# Simulate a drop of the small file (below threshold → should not flag)
: > "$T/small.rs"
git -C "$T" add small.rs
git -C "$T" commit -q -m "simulated drop of small file"

if bash "$VERIFY" --base base --orig-head "$ORIG_HEAD" \
        --repo "$T" --ambient "$AMBIENT" --threshold 50 >/dev/null 2>&1; then
    ok "below-threshold file not flagged"
else
    fail "below-threshold file incorrectly flagged"
fi

rm -rf "$T"

# ── Test 4: no-rebase case (HEAD unchanged) ───────────────────────────────────
T=$(mktemp -d)
_setup_repo "$T"
AMBIENT="$T/ambient.jsonl"

ORIG_HEAD="$(git -C "$T" rev-parse HEAD)"
# Don't change HEAD — orig-head == HEAD → no rebase happened

if bash "$VERIFY" --base base --orig-head "$ORIG_HEAD" \
        --repo "$T" --ambient "$AMBIENT" >/dev/null 2>&1; then
    ok "no-rebase (HEAD==ORIG_HEAD) exits 0"
else
    fail "no-rebase (HEAD==ORIG_HEAD) exits 0"
fi

rm -rf "$T"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
