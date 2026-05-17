#!/usr/bin/env bash
# test-self-doctor-heal.sh — INFRA-1595
#
# Smoke test for `chump fleet doctor --heal` (Wave 0b autonomy loop).
#
# Strategy: drive the CLI in three scenarios and verify the right
# ambient event kinds appear. The heavy lifting (mocked launchctl,
# mocked execute-gap dispatch) is covered by the Rust unit tests in
# src/fleet_self_doctor.rs::tests; this script exercises the CLI
# binding and the env-gate behavior.
#
# Scenarios:
#   1  --heal without env opt-in exits 0 and emits NOTHING (refused).
#   2  --heal with env opt-in emits self_doctor_tick (idle on a healthy
#      machine where all daemons happen to be loaded and no PRs are stuck).
#   3  diagnose-only (no --heal) emits self_doctor_tick.
#
# We don't assert daemon-install behavior here — that requires root /
# launchctl mutation and would be flaky in CI. The unit tests cover it.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

echo "=== INFRA-1595 self-doctor heal smoke test ==="

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  SKIP: chump binary not found at $CHUMP_BIN (run cargo build first)"
    exit 0
fi
ok "chump binary present"

# Isolated env: own ambient file so we can inspect emissions deterministically.
TMP="$(mktemp -d -t self-doctor-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.chump-locks"

# The Rust ambient_emit module writes relative to repo_path::repo_root().
# We run chump from inside $TMP with a fake git repo so repo_root resolves there.
(
    cd "$TMP"
    git init -q . 2>/dev/null || true
    mkdir -p .chump-locks
)

ambient_file="$TMP/.chump-locks/ambient.jsonl"

# Helper: run chump from inside $TMP so it picks up the isolated repo root.
run_chump() {
    (cd "$TMP" && "$CHUMP_BIN" "$@" 2>&1)
}

# ── scenario 1: --heal without env opt-in ─────────────────────────────────────
echo
echo "[scenario 1] --heal without CHUMP_FLEET_SELF_DOCTOR_HEAL=true"
: > "$ambient_file"
out="$(run_chump fleet doctor --heal 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "scenario 1: exit code $rc (expected 0)"
elif grep -q "refusing to run" <<<"$out" || grep -q "Heal mode is opt-in" <<<"$out"; then
    ok "scenario 1: refused without env opt-in"
else
    fail "scenario 1: no refusal message in output: $out"
fi
# No ambient events should be emitted in refusal path.
if [[ -s "$ambient_file" ]] && grep -q "self_doctor" "$ambient_file"; then
    fail "scenario 1: ambient should NOT contain self_doctor_* events"
else
    ok "scenario 1: no ambient events emitted on refusal"
fi

# ── scenario 2: diagnose-only mode ────────────────────────────────────────────
echo
echo "[scenario 2] fleet doctor (no --heal) emits diagnose tick"
: > "$ambient_file"
run_chump fleet doctor >/dev/null
if grep -q '"event":"self_doctor_tick"' "$ambient_file"; then
    ok "scenario 2: self_doctor_tick emitted in diagnose-only mode"
else
    fail "scenario 2: self_doctor_tick missing from ambient — file contents: $(cat "$ambient_file" 2>/dev/null)"
fi

# ── scenario 3: --heal with env opt-in (idle case) ────────────────────────────
echo
echo "[scenario 3] --heal with env opt-in (likely idle in CI sandbox)"
: > "$ambient_file"
# In a sandboxed CI environment, gh pr list is likely empty / fails (no auth);
# stuck PR list will be empty. Daemon checks may run or not. Either way the
# heal cycle should complete without panicking and emit *something* recognizable.
CHUMP_FLEET_SELF_DOCTOR_HEAL=true CHUMP_GH_CALL_CRITICALITY=background \
    run_chump fleet doctor --heal --json >/dev/null
if grep -q '"event":"self_doctor_' "$ambient_file"; then
    ok "scenario 3: at least one self_doctor_* event emitted"
else
    fail "scenario 3: no self_doctor_* events emitted — file contents: $(cat "$ambient_file" 2>/dev/null)"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
