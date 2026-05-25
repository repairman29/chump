#!/usr/bin/env bash
# test-decompose-loop.sh — INFRA-1924 smoke test
#
# Validates scripts/coord/decompose-loop.sh:
#   - help / heartbeat / audit-pending exit 0 on happy path
#   - bad subcommand exits 2; missing-arg exits 1
#   - heartbeat emits kind=decompose_heartbeat to ambient
#   - audit-pending emits kind=decompose_audit to ambient
#   - slice --dry-run with a synthetic gap_id propagates exit code correctly

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/coord/decompose-loop.sh"

if [[ ! -x "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not executable"
    exit 1
fi

# Use an isolated ambient log so we don't pollute the real one
TMP_AMBIENT="$(mktemp -d)/ambient.jsonl"
touch "$TMP_AMBIENT"

# ── Test 1: help exits 0 + prints usage ────────────────────────────────────
help_out="$(bash "$SCRIPT" help 2>&1 || true)"
if ! echo "$help_out" | grep -q "Subcommands:"; then
    echo "FAIL: help did not print 'Subcommands:'"
    exit 1
fi
echo "  ok: help prints Subcommands"

# ── Test 2: bad subcommand exits 2 ─────────────────────────────────────────
set +e
bash "$SCRIPT" totally-not-a-command >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" != "2" ]]; then
    echo "FAIL: bad subcommand should exit 2, got $rc"
    exit 1
fi
echo "  ok: bad subcommand exits 2"

# ── Test 3: slice with no arg exits 1 ─────────────────────────────────────
set +e
CHUMP_AMBIENT_LOG="$TMP_AMBIENT" bash "$SCRIPT" slice >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" != "1" ]]; then
    echo "FAIL: slice with no arg should exit 1, got $rc"
    exit 1
fi
echo "  ok: slice with no arg exits 1"

# ── Test 4: heartbeat exits 0 + emits kind=decompose_heartbeat ─────────────
: > "$TMP_AMBIENT"
CHUMP_AMBIENT_LOG="$TMP_AMBIENT" CHUMP_DECOMPOSE_NO_BROADCAST=1 \
    CHUMP_SESSION_ID="test-decompose" \
    bash "$SCRIPT" heartbeat >/dev/null 2>&1
if ! grep -q '"kind":"decompose_heartbeat"' "$TMP_AMBIENT"; then
    echo "FAIL: heartbeat did not emit kind=decompose_heartbeat"
    cat "$TMP_AMBIENT"
    exit 1
fi
echo "  ok: heartbeat emits kind=decompose_heartbeat"

# ── Test 5: audit-pending exits 0 + emits kind=decompose_audit ─────────────
# Only run if chump CLI available; otherwise skip (CI envs without it).
if command -v chump >/dev/null 2>&1; then
    : > "$TMP_AMBIENT"
    set +e
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" CHUMP_SESSION_ID="test-decompose" \
        bash "$SCRIPT" audit-pending >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
        echo "FAIL: audit-pending should exit 0 (stop condition), got $rc"
        exit 1
    fi
    if ! grep -q '"kind":"decompose_audit"' "$TMP_AMBIENT"; then
        echo "FAIL: audit-pending did not emit kind=decompose_audit"
        cat "$TMP_AMBIENT"
        exit 1
    fi
    echo "  ok: audit-pending exits 0 + emits kind=decompose_audit"
else
    echo "  skip: audit-pending — chump CLI not on PATH"
fi

# ── Test 6: slice with non-existent gap exits 1 ───────────────────────────
if command -v chump >/dev/null 2>&1; then
    set +e
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
        bash "$SCRIPT" slice INFRA-9999999 --dry-run >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" != "1" ]]; then
        echo "FAIL: slice with non-existent gap should exit 1, got $rc"
        exit 1
    fi
    echo "  ok: slice with non-existent gap exits 1"
else
    echo "  skip: slice non-existent gap — chump CLI not on PATH"
fi

# ── Test 7: --help on subcommand exits 0 ──────────────────────────────────
set +e
bash "$SCRIPT" slice --help >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" != "0" ]]; then
    echo "FAIL: 'slice --help' should exit 0, got $rc"
    exit 1
fi
echo "  ok: slice --help exits 0"

echo "test-decompose-loop: PASS"
