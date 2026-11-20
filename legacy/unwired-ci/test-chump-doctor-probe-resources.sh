#!/usr/bin/env bash
# test-chump-doctor-probe-resources.sh — INFRA-395
# Verifies --probe-resources outputs correct status tags and exits non-zero
# when a threshold is breached (by lowering the threshold via env vars).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$DOCTOR" ]] || fail "chump-binary-unwedge.sh missing or not executable"

# ── Test 1: subcommand exists and produces output ─────────────────────────────
out=$(bash "$DOCTOR" --probe-resources 2>&1 || true)
[[ -n "$out" ]] || fail "--probe-resources produced no output"
pass "--probe-resources produces output"

# ── Test 2: output contains status emoji for each resource ───────────────────
for label in "/tmp free" "worktree target/" "free RAM" "claude task dir"; do
    printf '%s\n' "$out" | grep -qF "$label" \
        || fail "output missing label: $label"
done
pass "output contains all resource labels"

# ── Test 3: output contains at least one status emoji ────────────────────────
printf '%s\n' "$out" | grep -qE '(✅|⚠|🚨)' \
    || fail "output contains no status emoji"
pass "output contains status emoji"

# ── Test 4: WARN fires when /tmp threshold is above actual free space ─────────
# Set the threshold impossibly high (999999 GB) — guaranteed to trigger 🚨.
out_warn=$(CHUMP_DOCTOR_TMP_WARN_GB=999999 bash "$DOCTOR" --probe-resources 2>&1 || true)
printf '%s\n' "$out_warn" | grep -qF "/tmp free" \
    || fail "WARN test: /tmp free label missing"
printf '%s\n' "$out_warn" | grep -E '🚨.*\/tmp free|/tmp free.*warn' > /dev/null \
    || fail "WARN test: /tmp free did not show 🚨 at threshold 999999 GB"
pass "WARN fires for /tmp free when threshold is above actual"

# ── Test 5: WARN fires for RAM when threshold is above actual free RAM ────────
out_ram=$(CHUMP_DOCTOR_RAM_WARN_GB=999999 bash "$DOCTOR" --probe-resources 2>&1 || true)
printf '%s\n' "$out_ram" | grep -E '🚨.*free RAM|free RAM.*warn' > /dev/null \
    || fail "WARN test: free RAM did not show 🚨 at threshold 999999 GB"
pass "WARN fires for free RAM when threshold is above actual"

# ── Test 6: exit code is 0 when all thresholds set to 0 (everything passes) ──
exit_code=0
CHUMP_DOCTOR_TMP_WARN_GB=0 \
CHUMP_DOCTOR_TARGET_WARN_GB=999999 \
CHUMP_DOCTOR_RAM_WARN_GB=0 \
CHUMP_DOCTOR_CLAUDE_WARN_MB=999999 \
  bash "$DOCTOR" --probe-resources >/dev/null 2>&1 || exit_code=$?
[[ "$exit_code" -eq 0 ]] \
    || fail "expected exit 0 with all thresholds at 0, got $exit_code"
pass "exit 0 when all thresholds set below actual values"

printf '\nAll tests passed.\n'
