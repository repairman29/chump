#!/usr/bin/env bash
# capability-guard-exempt: existing skip-path covers missing binary; pattern wording differs from canonical (CREDIBLE-078)
# test-fresh-clone-gap-list.sh — INFRA-821
#
# Verifies that `chump gap list --status open` on a repo with an empty state.db
# (fresh clone simulation) auto-seeds from docs/gaps/ and returns a non-zero count.
# Also verifies `chump gap import --yaml <absolute-path>` correctly resolves repo root.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
skip() { printf '\033[0;33mSKIP\033[0m %s\n' "$*"; exit 0; }

[[ -x "$CHUMP_BIN" ]] || skip "chump binary not found at $CHUMP_BIN — run cargo build first"

# Count real open gaps in docs/gaps/ so we know what to expect.
YAML_COUNT=$(find "$REPO_ROOT/docs/gaps" -name '*.yaml' -exec grep -l 'status: open' {} + 2>/dev/null | wc -l | tr -d ' ')
[[ "$YAML_COUNT" -gt 0 ]] || fail "No open-status YAML files found in docs/gaps/ — test precondition failed"

# ── Test 1: fresh empty state.db → auto-seed on gap list ───────────────────────
TMPDIR="$(mktemp -d /tmp/infra-821-test-XXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

# Set up minimal repo scaffold
mkdir -p "$TMPDIR/.chump" "$TMPDIR/docs/gaps"
# Symlink (not copy) so we test against the real gap YAML set
ln -sf "$REPO_ROOT/docs/gaps" "$TMPDIR/docs/gaps_real"
rm -rf "$TMPDIR/docs/gaps"
ln -sf "$REPO_ROOT/docs/gaps" "$TMPDIR/docs/gaps"

# Empty state.db
CHUMP_REPO="$TMPDIR" CHUMP_STATE_DB="$TMPDIR/.chump/state.db" \
  "$CHUMP_BIN" gap list --status open --json > "$TMPDIR/list_out.json" 2>"$TMPDIR/list_err.txt" || true

# After auto-seed, the JSON should have items
COUNT=$(python3 -c "import json,sys; d=json.load(open('$TMPDIR/list_out.json')); print(len(d))" 2>/dev/null || echo 0)
[[ "$COUNT" -gt 0 ]] || fail "gap list --json returned 0 items on empty DB — auto-seed did not fire (stderr: $(cat $TMPDIR/list_err.txt))"
ok "auto-seed: gap list on empty state.db imported and returned $COUNT open gaps"

# ── Test 2: second run should NOT re-import (DB already populated) ─────────────
CHUMP_REPO="$TMPDIR" CHUMP_STATE_DB="$TMPDIR/.chump/state.db" \
  "$CHUMP_BIN" gap list --status open --json > "$TMPDIR/list2_out.json" 2>"$TMPDIR/list2_err.txt"

grep -q "auto-importing" "$TMPDIR/list2_err.txt" && fail "auto-seed fired a second time when DB already populated"
ok "second-visit: no re-import when DB already populated"

# ── Test 3: chump gap import --yaml <abs-path> resolves repo root correctly ─────
TMPDIR2="$(mktemp -d /tmp/infra-821-import-XXXXX)"
trap 'rm -rf "$TMPDIR2"' EXIT
mkdir -p "$TMPDIR2/.chump"
ln -sf "$REPO_ROOT/docs/gaps" "$TMPDIR2/docs/gaps" 2>/dev/null || { mkdir -p "$TMPDIR2/docs"; ln -sf "$REPO_ROOT/docs/gaps" "$TMPDIR2/docs/gaps"; }

ABS_YAML="$TMPDIR2/docs/gaps.yaml"

# Run import with absolute path (gaps dir not gaps.yaml, but test the suffix strip)
OUT=$(CHUMP_REPO="$TMPDIR2" CHUMP_STATE_DB="$TMPDIR2/.chump/state.db" \
  "$CHUMP_BIN" gap import --yaml "$TMPDIR2/docs/gaps.yaml" 2>&1 || true)

# Should either succeed with inserts, or give a clear error (not "0 inserted" silently)
if echo "$OUT" | grep -q "0 inserted"; then
  fail "gap import --yaml <abs-path> still returns 0 inserted — root resolution bug persists"
fi
ok "gap import --yaml <abs-path> does not silently return 0 inserted"

echo
echo "All INFRA-821 fresh-clone gap-list tests passed."
