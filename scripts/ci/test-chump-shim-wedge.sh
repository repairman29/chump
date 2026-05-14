#!/usr/bin/env bash
# test-chump-shim-wedge.sh — INFRA-469
#
# Tests the bin/chump shim's transparent wedge-detect-heal-retry loop:
#  1. Bypass (CHUMP_INTERNAL_DOCTOR=0) passes through to real binary
#  2. Healthy binary: shim passes through exit code and stdout intact
#  3. Wedged binary (times out on first call): shim heals via chump-doctor,
#     retries, and succeeds — verifying the INFRA-469 inode-swap loop.
#  4. Recursion guard: CHUMP_SHIM_ACTIVE=1 skips the wrap entirely.
#
# "Simulate wedge via slow-fork preload" in the acceptance criteria is
# approximated on macOS (no LD_PRELOAD) by a fake binary that sleeps past
# the shim's timeout, then exits 0 on the second call.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SHIM="$REPO_ROOT/bin/chump"

[[ -x "$SHIM" ]] || { echo "FATAL: $SHIM missing or not executable"; exit 2; }

echo "=== INFRA-469 bin/chump shim wedge-heal test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_BIN="$TMPDIR_BASE/bin"
mkdir -p "$FAKE_BIN"

# ── Helpers ───────────────────────────────────────────────────────────────────

make_healthy_chump() {
    cat >"$FAKE_BIN/chump" <<'BIN'
#!/usr/bin/env bash
echo "chump-ok"
exit 0
BIN
    chmod +x "$FAKE_BIN/chump"
}

make_fake_doctor() {
    local log="$1"
    mkdir -p "$TMPDIR_BASE/scripts/dev"
    cat >"$TMPDIR_BASE/scripts/dev/chump-binary-unwedge.sh" <<DOC
#!/usr/bin/env bash
echo "doctor-ran" >> "$log"
exit 0
DOC
    chmod +x "$TMPDIR_BASE/scripts/dev/chump-binary-unwedge.sh"
}

# ── Test 1: bypass (CHUMP_INTERNAL_DOCTOR=0) ─────────────────────────────────
make_healthy_chump
OUT=$(CHUMP_INTERNAL_DOCTOR=0 CHUMP_REAL_BINARY="$FAKE_BIN/chump" "$SHIM" --version 2>/dev/null || true)
if [[ "$OUT" == "chump-ok" ]]; then
    ok "CHUMP_INTERNAL_DOCTOR=0 bypasses shim, passes through to real binary"
else
    fail "bypass produced unexpected output: '$OUT'"
fi

# ── Test 2: healthy binary passes through cleanly ─────────────────────────────
make_healthy_chump
OUT=$(CHUMP_REAL_BINARY="$FAKE_BIN/chump" \
      CHUMP_INTERNAL_TIMEOUT=5 \
      CHUMP_DOCTOR_PATH="$TMPDIR_BASE/scripts/dev/chump-binary-unwedge.sh" \
      "$SHIM" --version 2>/dev/null)
if [[ "$OUT" == "chump-ok" ]]; then
    ok "healthy binary: stdout passes through intact"
else
    fail "healthy binary: unexpected output: '$OUT'"
fi

# ── Test 3: wedge simulation — slow binary heals and recovers ─────────────────
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    skip "no timeout/gtimeout on PATH — skipping wedge-simulation test"
else
    COUNTER="$TMPDIR_BASE/chump.calls"
    echo 0 >"$COUNTER"
    DOCTOR_LOG="$TMPDIR_BASE/doctor.log"

    # Fake binary: sleeps past the short timeout on call #1, succeeds on call #2.
    cat >"$FAKE_BIN/chump" <<BIN
#!/usr/bin/env bash
n=\$(cat "$COUNTER" 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s\n' "\$n" >"$COUNTER"
if [[ "\$n" -eq 1 ]]; then
    sleep 60   # simulate wedge: never returns within shim timeout
fi
printf 'recovered-on-attempt-%s\n' "\$n"
exit 0
BIN
    chmod +x "$FAKE_BIN/chump"

    make_fake_doctor "$DOCTOR_LOG"

    # Run shim with a 2-second timeout so the test finishes quickly.
    OUT=$(CHUMP_REAL_BINARY="$FAKE_BIN/chump" \
          CHUMP_INTERNAL_TIMEOUT=2 \
          CHUMP_DOCTOR_PATH="$TMPDIR_BASE/scripts/dev/chump-binary-unwedge.sh" \
          "$SHIM" --version 2>/dev/null || true)

    CALLS=$(cat "$COUNTER" 2>/dev/null || echo 0)

    if [[ "$OUT" == "recovered-on-attempt-2" ]] && [[ "$CALLS" -eq 2 ]]; then
        ok "wedge: shim timed out, healed, retried, recovered (2 calls)"
    else
        fail "wedge: expected 'recovered-on-attempt-2' with 2 calls; got '$OUT' / $CALLS call(s)"
    fi

    if [[ -f "$DOCTOR_LOG" ]] && grep -q "doctor-ran" "$DOCTOR_LOG"; then
        ok "wedge: chump-binary-unwedge.sh invoked between attempts"
    else
        fail "wedge: chump-binary-unwedge.sh was NOT invoked"
    fi
fi

# ── Test 4: recursion guard (CHUMP_SHIM_ACTIVE=1) ─────────────────────────────
make_healthy_chump
OUT=$(CHUMP_SHIM_ACTIVE=1 \
      CHUMP_REAL_BINARY="$FAKE_BIN/chump" \
      "$SHIM" --version 2>/dev/null || true)
if [[ "$OUT" == "chump-ok" ]]; then
    ok "recursion guard: CHUMP_SHIM_ACTIVE=1 exec's real binary directly"
else
    fail "recursion guard: unexpected output: '$OUT'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
