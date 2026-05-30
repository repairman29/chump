#!/usr/bin/env bash
# test-cargo-target-reaper-runner-scope.sh — INFRA-2188
# Smoke-tests section (h) — ~/.cache/chump-runner/cargo-target/{debug,release}
# pruning + disk-critical aggressive-mode escalation.
#
# Uses CHUMP_CARGO_REAPER_RUNNER_CACHE to point the reaper at a synthetic
# fixture tree under TMPBASE, so the test never touches the real cache.
# CHUMP_DISK_CRITICAL_GB is set very high to force aggressive-mode in the
# escalation test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }
skip() { echo "  SKIP $*"; }

echo "=== test-cargo-target-reaper-runner-scope.sh (INFRA-2188) ==="

# NOTE: this test uses CHUMP_CARGO_REAPER_RUNNER_CACHE to point at a synthetic
# fixture, so it is safe to run while cargo is active on the real cache. We
# strip the "abort on active cargo" guard from the PATCHED reaper instead of
# blanket-skipping (the prior test-cargo-target-reaper-scope.sh skips because
# it touches /tmp/chump-* globs that real builds may be using).

# ── Fixture workspace ────────────────────────────────────────────────────────
TMPBASE=$(mktemp -d)
trap 'rm -rf "$TMPBASE"' EXIT
mkdir -p "${TMPBASE}/.chump-locks"

FAKE_CACHE="${TMPBASE}/runner-cargo-target"
mkdir -p "${FAKE_CACHE}/debug/.fingerprint" \
         "${FAKE_CACHE}/debug/deps" \
         "${FAKE_CACHE}/release/.fingerprint" \
         "${FAKE_CACHE}/release/deps"

# Old fingerprints (15 days old → > default FLEET_AGE_D=7)
mkdir -p "${FAKE_CACHE}/debug/.fingerprint/old-pkg-12345"
touch "${FAKE_CACHE}/debug/.fingerprint/old-pkg-12345/invoked.timestamp"
touch -t 202604010000 "${FAKE_CACHE}/debug/.fingerprint/old-pkg-12345" \
                     "${FAKE_CACHE}/debug/.fingerprint/old-pkg-12345/invoked.timestamp" 2>/dev/null || true
# Old rlib in deps/
touch "${FAKE_CACHE}/debug/deps/libold_dep-abc.rlib"
touch -t 202604010000 "${FAKE_CACHE}/debug/deps/libold_dep-abc.rlib" 2>/dev/null || true

# Patch reaper:
#  - REPO_ROOT → TMPBASE (so ambient log goes to fixture, not real repo)
#  - replace the "abort on active cargo/rustc" block with a no-op, since this
#    test only touches a synthetic cache under TMPBASE.
PATCHED="${TMPBASE}/reaper-runner-scope-test.sh"
python3 - "$REAPER" "$PATCHED" "$TMPBASE" <<'PY'
import re, sys
src_path, dst_path, tmpbase = sys.argv[1:]
with open(src_path) as f:
    s = f.read()
# 1. REPO_ROOT override
s = re.sub(r'REPO_ROOT="\$\(cd.*?\)"', f'REPO_ROOT="{tmpbase}"', s, count=1)
# 2. Defang the active-cargo abort: replace the entire if-block with a no-op.
s = re.sub(
    r'if pgrep -x "cargo".*?\nfi\n',
    ': # active-cargo guard stripped by test-cargo-target-reaper-runner-scope.sh\n',
    s, count=1, flags=re.DOTALL,
)
with open(dst_path, 'w') as f:
    f.write(s)
PY
chmod +x "$PATCHED"

# Quick sanity: confirm the guard really was stripped.
if grep -q 'ABORT: active cargo/rustc' "$PATCHED"; then
    fail "test setup: failed to strip cargo-active guard from PATCHED reaper"
fi

# ── Test 1: pattern presence — section (h) attribution in reaper ────────────
echo "--- Test 1: INFRA-2188 attribution + RUNNER_CACHE_BASE present ---"
grep -q 'INFRA-2188' "$REAPER" \
    || fail "INFRA-2188 attribution missing from reaper"
grep -q 'RUNNER_CACHE_BASE' "$REAPER" \
    || fail "RUNNER_CACHE_BASE env not in reaper"
grep -q 'CHUMP_CARGO_REAPER_RUNNER_CACHE' "$REAPER" \
    || fail "CHUMP_CARGO_REAPER_RUNNER_CACHE override not in reaper"
grep -q 'runner_cache' "$REAPER" \
    || fail "class=runner_cache not in ambient emit"
pass "INFRA-2188: attribution + env + class present"

# ── Test 2: cold path — old fingerprint reaped ──────────────────────────────
echo "--- Test 2: cold path — old fingerprint reaped ---"

dry_out=$(CHUMP_CARGO_REAPER_RUNNER_CACHE="$FAKE_CACHE" \
    CHUMP_CARGO_REAPER_TMP_GLOB="${TMPBASE}/no-such-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    CHUMP_DISK_CRITICAL_GB=0 \
    bash "$PATCHED" 2>&1 || true)

if echo "$dry_out" | grep -q 'runner-scope reap.*old-pkg-12345'; then
    pass "old fingerprint identified in dry-run"
else
    echo "$dry_out" | tail -40
    fail "old fingerprint not identified in dry-run output"
fi

CHUMP_CARGO_REAPER_RUNNER_CACHE="$FAKE_CACHE" \
    CHUMP_CARGO_REAPER_TMP_GLOB="${TMPBASE}/no-such-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    CHUMP_DISK_CRITICAL_GB=0 \
    bash "$PATCHED" --execute 2>&1 >/dev/null || true

[[ ! -d "${FAKE_CACHE}/debug/.fingerprint/old-pkg-12345" ]] \
    || fail "old fingerprint NOT removed by --execute"
pass "old fingerprint removed by --execute"

[[ ! -f "${FAKE_CACHE}/debug/deps/libold_dep-abc.rlib" ]] \
    || fail "old rlib NOT removed by --execute"
pass "old rlib removed by --execute"

# ── Test 3: hot-touch guard — touched binary blocks reap ────────────────────
echo "--- Test 3: hot-touch guard — recent chump-* binary blocks profile reap ---"
mkdir -p "${FAKE_CACHE}/debug/.fingerprint/cold-pkg-67890"
touch "${FAKE_CACHE}/debug/.fingerprint/cold-pkg-67890/invoked.timestamp"
touch -t 202604010000 "${FAKE_CACHE}/debug/.fingerprint/cold-pkg-67890" \
                     "${FAKE_CACHE}/debug/.fingerprint/cold-pkg-67890/invoked.timestamp" 2>/dev/null || true

# Fresh chump-* binary at top of debug/
touch "${FAKE_CACHE}/debug/chump"  # current mtime → hot

hot_dry_out=$(CHUMP_CARGO_REAPER_RUNNER_CACHE="$FAKE_CACHE" \
    CHUMP_CARGO_REAPER_TMP_GLOB="${TMPBASE}/no-such-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    CHUMP_DISK_CRITICAL_GB=0 \
    bash "$PATCHED" 2>&1 || true)

if echo "$hot_dry_out" | grep -q 'skip (debug: hot binary chump'; then
    pass "hot-touch guard skips debug/ profile when chump binary is fresh"
else
    echo "$hot_dry_out" | tail -40
    fail "hot-touch guard did NOT skip debug/ profile (chump binary fresh)"
fi

# Cold profile (release/) was not seeded with a hot binary — should still be examined.
# Removing the fresh binary, the cold fingerprint should reap on the next run.
rm -f "${FAKE_CACHE}/debug/chump"

CHUMP_CARGO_REAPER_RUNNER_CACHE="$FAKE_CACHE" \
    CHUMP_CARGO_REAPER_TMP_GLOB="${TMPBASE}/no-such-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    CHUMP_DISK_CRITICAL_GB=0 \
    bash "$PATCHED" --execute 2>&1 >/dev/null || true

[[ ! -d "${FAKE_CACHE}/debug/.fingerprint/cold-pkg-67890" ]] \
    || fail "cold fingerprint NOT reaped after hot binary removed"
pass "cold fingerprint reaped once hot guard cleared"

# ── Test 4: aggressive-mode — disk-critical drops thresholds ────────────────
echo "--- Test 4: aggressive-mode escalation ---"
# Seed a 5-day-old fingerprint (not reaped at FLEET_AGE_D=7 default,
# but reaped at FLEET_AGE_D=2 under aggressive mode).
mkdir -p "${FAKE_CACHE}/release/.fingerprint/mid-age-pkg-22222"
touch "${FAKE_CACHE}/release/.fingerprint/mid-age-pkg-22222/invoked.timestamp"
# 5 days old:
_5d_ago=$(date -v-5d +"%Y%m%d%H%M" 2>/dev/null \
    || date -d "5 days ago" +"%Y%m%d%H%M" 2>/dev/null \
    || echo "")
if [[ -n "$_5d_ago" ]]; then
    touch -t "$_5d_ago" "${FAKE_CACHE}/release/.fingerprint/mid-age-pkg-22222" \
                       "${FAKE_CACHE}/release/.fingerprint/mid-age-pkg-22222/invoked.timestamp" 2>/dev/null || true
else
    skip "could not compute 5d-ago timestamp on this date(1) variant — skipping aggressive-mode test"
    echo "All applicable INFRA-2188 runner-scope tests passed."
    exit 0
fi

# CHUMP_DISK_CRITICAL_GB=99999999 forces aggressive mode unconditionally.
agg_dry_out=$(CHUMP_CARGO_REAPER_RUNNER_CACHE="$FAKE_CACHE" \
    CHUMP_CARGO_REAPER_TMP_GLOB="${TMPBASE}/no-such-glob-*" \
    CHUMP_CARGO_REAPER_GIT_DIR="$REPO_ROOT" \
    CHUMP_DISK_CRITICAL_GB=99999999 \
    bash "$PATCHED" 2>&1 || true)

if echo "$agg_dry_out" | grep -q 'disk-critical:.*escalating.*FINGERPRINT_AGE_D=1 FLEET_AGE_D=2'; then
    pass "aggressive-mode banner emitted when free < CHUMP_DISK_CRITICAL_GB"
else
    echo "$agg_dry_out" | tail -40
    fail "aggressive-mode banner missing"
fi

if echo "$agg_dry_out" | grep -q 'runner-scope reap.*mid-age-pkg-22222'; then
    pass "aggressive-mode reaps 5d-old fingerprint (FLEET_AGE_D dropped to 2)"
else
    echo "$agg_dry_out" | tail -40
    fail "5d-old fingerprint not identified under aggressive mode"
fi

# ── Test 5: summary event includes new counters ─────────────────────────────
echo "--- Test 5: summary event includes runner_scope_count + aggressive_mode ---"
grep -q '"runner_scope_count"' "$REAPER" \
    || fail "runner_scope_count not in summary emit format"
grep -q '"aggressive_mode"' "$REAPER" \
    || fail "aggressive_mode not in summary emit format"
pass "summary event format includes both new fields"

# Verify ambient.jsonl received the summary event
if [[ -f "${TMPBASE}/.chump-locks/ambient.jsonl" ]]; then
    if grep -q '"kind":"cargo_target_reaper_summary"' "${TMPBASE}/.chump-locks/ambient.jsonl"; then
        if grep -q '"runner_scope_count":[0-9]' "${TMPBASE}/.chump-locks/ambient.jsonl"; then
            pass "ambient summary event includes runner_scope_count value"
        else
            fail "ambient summary event missing runner_scope_count value"
        fi
    else
        fail "ambient log written but missing cargo_target_reaper_summary kind"
    fi
else
    fail "ambient log not written under TMPBASE/.chump-locks/"
fi

# ── Test 6: bash -n syntax check ─────────────────────────────────────────────
echo "--- Test 6: bash -n syntax check ---"
bash -n "$REAPER" || fail "reaper script has syntax errors"
pass "syntax OK"

echo ""
echo "All INFRA-2188 runner-scope tests passed."
