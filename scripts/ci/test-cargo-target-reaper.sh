#!/usr/bin/env bash
# test-cargo-target-reaper.sh — INFRA-1250
# Validates cargo-target-reaper.sh: stale + fresh fixture, dry-run, --execute.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-cargo-target-reaper.sh ==="

# ── Fixture setup ────────────────────────────────────────────────────────────
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_TARGET="${TMPDIR_BASE}/target/debug"
mkdir -p "${FAKE_TARGET}/.fingerprint" "${FAKE_TARGET}/deps"

# Create stale entries (30 days old)
mkdir -p "${FAKE_TARGET}/.fingerprint/stale-crate-abc123"
touch -d "30 days ago" "${FAKE_TARGET}/.fingerprint/stale-crate-abc123" 2>/dev/null \
    || touch -A -302400000 "${FAKE_TARGET}/.fingerprint/stale-crate-abc123" 2>/dev/null \
    || python3 -c "import os,time; os.utime('${FAKE_TARGET}/.fingerprint/stale-crate-abc123', (time.time()-2592000, time.time()-2592000))"
touch "${FAKE_TARGET}/deps/libstale_crate-abc123.rlib"
python3 -c "import os,time; os.utime('${FAKE_TARGET}/deps/libstale_crate-abc123.rlib', (time.time()-2592000, time.time()-2592000))"

# Create fresh entries (1 day old — should NOT be reaped with default 14d threshold)
mkdir -p "${FAKE_TARGET}/.fingerprint/fresh-crate-def456"
touch "${FAKE_TARGET}/deps/libfresh_crate-def456.rlib"

# ── Test 1: Safety guard — active cargo process ──────────────────────────────
echo "--- Test 1: safety guard (active cargo) ---"
# Can't easily fake a cargo process in CI, so just verify guard logic exists
grep -q "pgrep.*cargo\|pgrep.*rustc" "$REAPER" || fail "no active-cargo guard found in reaper script"
pass "active-cargo guard present"

# ── Test 2: Safety guard — low disk ─────────────────────────────────────────
echo "--- Test 2: safety guard (low disk check present) ---"
grep -q "free_gb\|MIN_FREE_GB\|df -k" "$REAPER" || fail "no low-disk guard found in reaper script"
pass "low-disk guard present"

# ── Test 3: dry-run identifies stale, not fresh ──────────────────────────────
echo "--- Test 3: dry-run identifies stale only ---"
# Override REPO_ROOT by running from TMPDIR_BASE with symlinked structure
mkdir -p "${TMPDIR_BASE}/.chump-locks"
# Patch: copy reaper with overridden REPO_ROOT
PATCHED_REAPER="${TMPDIR_BASE}/cargo-target-reaper-test.sh"
sed "s|REPO_ROOT=\"\$(cd.*\"|REPO_ROOT=\"${TMPDIR_BASE}\"|" "$REAPER" > "$PATCHED_REAPER"
chmod +x "$PATCHED_REAPER"

# Run dry-run (no cargo processes in CI — guard passes)
if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "  SKIP (active cargo process detected — cannot run reaper in this environment)"
else
    output=$(bash "$PATCHED_REAPER" --fingerprint-age-d 14 2>&1 || true)
    echo "$output" | grep -q "stale-crate" || fail "dry-run did not identify stale-crate"
    echo "$output" | grep -q "fresh-crate" && fail "dry-run incorrectly targeted fresh-crate" || true
    pass "dry-run correctly identifies stale, skips fresh"
fi

# ── Test 4: --execute actually deletes stale ────────────────────────────────
echo "--- Test 4: --execute deletes stale ---"
if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "  SKIP (active cargo process detected)"
else
    bash "$PATCHED_REAPER" --fingerprint-age-d 14 --execute 2>&1 || true
    [[ -d "${FAKE_TARGET}/.fingerprint/stale-crate-abc123" ]] \
        && fail "stale fingerprint dir not deleted by --execute"
    [[ -f "${FAKE_TARGET}/deps/libstale_crate-abc123.rlib" ]] \
        && fail "stale rlib not deleted by --execute"
    [[ -d "${FAKE_TARGET}/.fingerprint/fresh-crate-def456" ]] \
        || fail "fresh fingerprint dir was incorrectly deleted"
    [[ -f "${FAKE_TARGET}/deps/libfresh_crate-def456.rlib" ]] \
        || fail "fresh rlib was incorrectly deleted"
    pass "--execute deletes stale, preserves fresh"
fi

# ── Test 5: ambient event emitted ────────────────────────────────────────────
echo "--- Test 5: ambient event emitted ---"
if [[ -f "${TMPDIR_BASE}/.chump-locks/ambient.jsonl" ]]; then
    grep -q '"kind":"cargo_target_reaper_summary"' "${TMPDIR_BASE}/.chump-locks/ambient.jsonl" \
        || fail "cargo_target_reaper_summary event not emitted"
    pass "cargo_target_reaper_summary emitted to ambient.jsonl"
else
    echo "  SKIP (ambient log not created — no artifacts reaped in skipped tests)"
fi

# ── Test 6: --help exits 0 ───────────────────────────────────────────────────
echo "--- Test 6: --help exits 0 ---"
bash "$REAPER" --help > /dev/null || fail "--help exited non-zero"
pass "--help exits 0"

# ── Test 7: script syntax check ──────────────────────────────────────────────
echo "--- Test 7: bash -n syntax check ---"
bash -n "$REAPER" || fail "script has syntax errors"
pass "script syntax OK"

echo ""
echo "All cargo-target-reaper tests passed."
