#!/usr/bin/env bash
# test-gap-set-auto-regenerates-yaml.sh — INFRA-470
#
# Verifies `chump gap set <ID> --field VAL` auto-regenerates the per-file
# YAML at docs/gaps/<ID>.yaml AND stamps the .chump/.last-yaml-op
# freshness marker — closing the drift class where state.db gets the
# update but the YAML mirror stays stale (observed live 2026-05-04 with
# INFRA-465 notes that never made it to the YAML).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Use the locally-built binary (this branch's binary, not whatever's on
# $PATH). bot-merge.sh runs cargo build before tests, so target/release
# is fresh.
CHUMP="$REPO_ROOT/target/release/chump"
if [[ ! -x "$CHUMP" ]]; then
    echo "FATAL: $CHUMP not built; run 'cargo build --release --bin chump' first"
    exit 2
fi

echo "=== INFRA-470 chump gap set auto-regenerates YAML test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a fake repo with a gaps directory + state.db
FAKE="$TMPDIR_BASE/repo"
mkdir -p "$FAKE/docs/gaps" "$FAKE/.chump"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
git -C "$FAKE" commit --allow-empty -q -m seed

# Use chump gap reserve to seed a gap (this also creates state.db)
cd "$FAKE"
RESERVE_OUT=$(CHUMP_REPO="$FAKE" "$CHUMP" gap reserve --force --domain TEST --priority P2 --effort xs --title "test gap for INFRA-470 $(date +%s)" 2>&1)
GAP_ID=$(echo "$RESERVE_OUT" | grep -oE 'TEST-[0-9]+' | head -1)

if [[ -z "$GAP_ID" ]]; then
    cd "$REPO_ROOT"
    echo "FATAL: chump gap reserve did not produce a gap ID. Output: $RESERVE_OUT"
    exit 2
fi

YAML_PATH="$FAKE/docs/gaps/${GAP_ID}.yaml"

if [[ -f "$YAML_PATH" ]]; then
    ok "chump gap reserve wrote per-file YAML at $YAML_PATH"
else
    fail "reserve did not produce $YAML_PATH"
fi

# --- Test 1: chump gap set updates the YAML ---
TEST_NOTE="INFRA-470 test marker $(date +%s)"
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP_ID" --notes "$TEST_NOTE" >/dev/null 2>&1

if grep -qF "$TEST_NOTE" "$YAML_PATH"; then
    ok "chump gap set --notes auto-regenerates YAML with the new value"
else
    fail "YAML at $YAML_PATH does not contain the new notes (drift class still present)"
    echo "    YAML content:"
    sed 's/^/      /' "$YAML_PATH"
fi

# --- Test 2: .chump/.last-yaml-op marker is stamped ---
MARKER="$FAKE/.chump/.last-yaml-op"
if [[ -f "$MARKER" ]]; then
    MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || echo 0) ))
    if [[ "$MARKER_AGE" -lt 60 ]]; then
        ok "freshness marker .chump/.last-yaml-op stamped (age=${MARKER_AGE}s)"
    else
        fail "marker exists but stale (age=${MARKER_AGE}s)"
    fi
else
    fail "freshness marker .chump/.last-yaml-op not stamped"
fi

# --- Test 3: another set updates the marker again ---
sleep 1
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP_ID" --priority P1 >/dev/null 2>&1

if grep -qE '^  priority: P1$' "$YAML_PATH"; then
    ok "second set --priority updates YAML again"
else
    fail "second set did NOT update YAML (priority still $(grep -E '^  priority:' "$YAML_PATH" | head -1))"
fi

# --- Test 4: clearing a field also regenerates ---
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP_ID" --notes "" >/dev/null 2>&1
# After clearing, the YAML notes line should be gone or empty
if ! grep -qF "$TEST_NOTE" "$YAML_PATH"; then
    ok "clearing --notes regenerates YAML (old marker is gone)"
else
    fail "old notes marker still in YAML after clearing"
fi

cd "$REPO_ROOT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
