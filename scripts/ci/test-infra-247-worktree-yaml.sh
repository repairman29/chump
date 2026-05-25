#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-078)
# test-infra-247-worktree-yaml.sh — verify `chump gap reserve` writes the
# per-file YAML mirror to the LINKED WORKTREE's docs/gaps/, not the main
# checkout's, even when CHUMP_REPO points at the main checkout.
#
# Pre-INFRA-247 (observed multiple times 2026-05-02..03): an operator running
# `chump gap reserve` from a linked worktree saw the YAML land in
# `<main checkout>/docs/gaps/<ID>.yaml` instead of their own worktree.
# Root cause: `repo_root()` resolves CHUMP_REPO/CHUMP_HOME (set by the main
# checkout's .env, which dotenvy walks up to find from any linked worktree)
# and uses that for the per-file write. The fix introduces `worktree_root()`
# which uses `git rev-parse --show-toplevel` from CWD instead.
#
# This test reproduces the original repro: a fake "main" repo with a `.env`
# setting CHUMP_REPO to itself, plus a linked worktree, then runs
# `chump gap reserve` from the linked worktree and asserts the YAML landed
# in the worktree's docs/gaps/ — not the main's.
#
# Run:
#   ./scripts/ci/test-infra-247-worktree-yaml.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$(git rev-parse --show-toplevel)/target}/release/chump}"
if [ ! -x "$CHUMP_BIN" ]; then
    echo "FATAL: chump binary not found at $CHUMP_BIN"
    echo "  Build with: cargo build --release --bin chump"
    exit 2
fi

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-247 worktree-local YAML write test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

MAIN_REPO="$TMPDIR_BASE/main"
mkdir -p "$MAIN_REPO/docs/gaps" "$MAIN_REPO/.chump"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email "test@test.com"
git -C "$MAIN_REPO" config user.name "Test"

# This is the trap door: main checkout's .env sets CHUMP_REPO to itself.
# dotenvy walks up from CWD looking for .env, so a linked worktree under
# this main will load THIS file and inherit CHUMP_REPO=$MAIN_REPO.
cat >"$MAIN_REPO/.env" <<EOF
CHUMP_REPO=$MAIN_REPO
CHUMP_HOME=$MAIN_REPO
EOF

# Seed an empty registry so reserve has somewhere to write.
cat >"$MAIN_REPO/docs/gaps.yaml" <<'YAML'
gaps: []
YAML
git -C "$MAIN_REPO" add .env docs/gaps.yaml
git -C "$MAIN_REPO" commit -q -m "seed"

# Create the linked worktree.
WORKTREE="$TMPDIR_BASE/wt"
git -C "$MAIN_REPO" worktree add -q "$WORKTREE" -b feature

# ── Test 1: reserve from linked worktree writes to worktree's docs/gaps/ ──
echo "--- Test 1: reserve from linked worktree (canonical INFRA-247 repro) ---"
cd "$WORKTREE"
# Use unset to make sure no inherited env var skews the result;
# the fixture's .env should set CHUMP_REPO=$MAIN_REPO when chump loads it.
RESERVE_OUT="$(env -u CHUMP_REPO -u CHUMP_HOME -u CHUMP_WORKTREE_ROOT \
    CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" gap reserve --domain TEST --title "infra-247 repro" --priority P3 --effort xs 2>&1)"
NEW_ID="$(echo "$RESERVE_OUT" | tail -1 | tr -d '[:space:]')"

if [ -z "$NEW_ID" ] || ! [[ "$NEW_ID" =~ ^TEST- ]]; then
    fail "reserve did not return a TEST-* gap id"
    echo "      output: $RESERVE_OUT"
else
    if [ -f "$WORKTREE/docs/gaps/$NEW_ID.yaml" ]; then
        ok "YAML landed in linked worktree: $WORKTREE/docs/gaps/$NEW_ID.yaml"
    else
        fail "YAML NOT in linked worktree (expected $WORKTREE/docs/gaps/$NEW_ID.yaml)"
        echo "      where it actually went:"
        find "$TMPDIR_BASE" -name "$NEW_ID.yaml" 2>/dev/null | sed 's/^/        /'
    fi
    if [ ! -f "$MAIN_REPO/docs/gaps/$NEW_ID.yaml" ]; then
        ok "YAML did NOT leak into main checkout"
    else
        fail "YAML leaked into main checkout: $MAIN_REPO/docs/gaps/$NEW_ID.yaml — INFRA-247 regressed"
    fi
fi

# ── Test 2: CHUMP_WORKTREE_ROOT explicit override is honored ──
echo "--- Test 2: CHUMP_WORKTREE_ROOT override is honored ---"
OVERRIDE_DIR="$TMPDIR_BASE/explicit-override"
mkdir -p "$OVERRIDE_DIR/.chump"
# The override target needs to be a writable dir; gap_store needs the .chump
# dir for state.db lookups (resolved separately via repo_root).
RESERVE_OUT2="$(env -u CHUMP_REPO -u CHUMP_HOME \
    CHUMP_WORKTREE_ROOT="$OVERRIDE_DIR" \
    CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" gap reserve --domain TEST --title "override test" --priority P3 --effort xs 2>&1)"
NEW_ID2="$(echo "$RESERVE_OUT2" | tail -1 | tr -d '[:space:]')"

if [ -f "$OVERRIDE_DIR/docs/gaps/$NEW_ID2.yaml" ]; then
    ok "CHUMP_WORKTREE_ROOT override is honored"
else
    fail "CHUMP_WORKTREE_ROOT did NOT route the YAML to $OVERRIDE_DIR"
    echo "      output: $RESERVE_OUT2"
    find "$TMPDIR_BASE" -name "$NEW_ID2.yaml" 2>/dev/null | sed 's/^/        actually at: /'
fi

# ── Test 3: marker (.chump/.last-yaml-op) lands worktree-local too ──
echo "--- Test 3: .chump/.last-yaml-op marker lands in worktree, not main ---"
if [ -f "$WORKTREE/.chump/.last-yaml-op" ]; then
    ok "freshness marker landed in linked worktree's .chump/"
else
    fail "freshness marker NOT in linked worktree (.chump/.last-yaml-op)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
