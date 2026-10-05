#!/usr/bin/env bash
# test-target-reaper-cold-build-safety.sh — RESILIENT-116
#
# Simulates a freshly-provisioned worktree with a concurrent cargo build
# racing cargo-target-reaper.sh's orphaned-/tmp-worktree scan (class d) and
# lease+auto-merge scan (class g). Asserts the reaper:
#   1. Exits 0 without deleting the active target/ dir.
#   2. Emits kind=target_reap_skipped with reason=active_build (cargo-lock
#      present) and reason=no_reap_marker (.chump-no-reap sentinel present).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="${REPO_ROOT}/scripts/ops/cargo-target-reaper.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-target-reaper-cold-build-safety.sh ==="

if pgrep -x "cargo" > /dev/null 2>&1 || pgrep -f "rustc " > /dev/null 2>&1; then
    echo "  SKIP (active cargo process detected in this environment — cannot run reaper)"
    exit 0
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

mkdir -p "${TMPDIR_BASE}/.chump-locks"
PATCHED_REAPER="${TMPDIR_BASE}/cargo-target-reaper-test.sh"
sed "s|REPO_ROOT=\"\$(cd.*\"|REPO_ROOT=\"${TMPDIR_BASE}\"|" "$REAPER" > "$PATCHED_REAPER"
chmod +x "$PATCHED_REAPER"

# ── Scenario A: active .cargo-lock (simulated concurrent cargo build) ───────
FAKE_TMP_BASE="${TMPDIR_BASE}/tmp-scan"
WT_A="${FAKE_TMP_BASE}/chump-fresh-build-a"
mkdir -p "${WT_A}/target"
touch "${WT_A}/target/.cargo-lock"
mkdir -p "${WT_A}/target/deps"
echo "fake object" > "${WT_A}/target/deps/rustcFAKE"
# Age the target dir itself so the fresh-mtime guard isn't what saves it —
# we want to prove the .cargo-lock check specifically.
touch -d "1 hour ago" "${WT_A}/target" 2>/dev/null \
    || python3 -c "import os,time; os.utime('${WT_A}/target', (time.time()-3600, time.time()-3600))"

# ── Scenario B: .chump-no-reap sentinel, no active build markers ────────────
WT_B="${FAKE_TMP_BASE}/chump-fresh-build-b"
mkdir -p "${WT_B}/target"
touch "${WT_B}/.chump-no-reap"
touch -d "1 hour ago" "${WT_B}/target" 2>/dev/null \
    || python3 -c "import os,time; os.utime('${WT_B}/target', (time.time()-3600, time.time()-3600))"

echo "--- Test 1: reaper exits 0 with concurrent build present ---"
set +e
CHUMP_CARGO_REAPER_TMP_GLOB="${FAKE_TMP_BASE}/chump-*" \
    bash "$PATCHED_REAPER" --execute --fingerprint-age-d 14 --fleet-age-d 7 \
    > "${TMPDIR_BASE}/reaper.out" 2>&1
_rc=$?
set -e
[[ $_rc -eq 0 ]] || fail "reaper exited non-zero ($_rc): $(cat "${TMPDIR_BASE}/reaper.out")"
pass "reaper exits 0"

echo "--- Test 2: active-build target/ (cargo-lock) not deleted ---"
[[ -d "${WT_A}/target" ]] || fail "active-build target/ was deleted despite .cargo-lock"
[[ -f "${WT_A}/target/deps/rustcFAKE" ]] || fail "active-build artifact was deleted despite .cargo-lock"
pass "cargo-lock-protected target/ survives"

echo "--- Test 3: .chump-no-reap target/ not deleted ---"
[[ -d "${WT_B}/target" ]] || fail "no-reap-marked target/ was deleted"
pass ".chump-no-reap-protected target/ survives"

echo "--- Test 4: kind=target_reap_skipped emitted with reason field ---"
AMBIENT="${TMPDIR_BASE}/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not written"
grep -q '"kind":"target_reap_skipped".*"reason":"active_build"' "$AMBIENT" \
    || fail "no target_reap_skipped/active_build event emitted"
pass "target_reap_skipped reason=active_build emitted"
grep -q '"kind":"target_reap_skipped".*"reason":"no_reap_marker"' "$AMBIENT" \
    || fail "no target_reap_skipped/no_reap_marker event emitted"
pass "target_reap_skipped reason=no_reap_marker emitted"

echo ""
echo "=== test-target-reaper-cold-build-safety.sh: PASS ==="
