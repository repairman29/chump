#!/usr/bin/env bash
# test-reap-orphan-fg-detection.sh — INFRA-1786 unit tests for fg_pid detection
# and the safety gate in reap-orphan-claude-procs.sh.
#
# Tests:
#   1. fg_pid detected (not empty) when Claude.app is "running" (pgrep mock)
#   2. Safety gate exits 3 with the right message when fg_pid empty and
#      CHUMP_REAPER_HEADLESS is unset.
#   3. Old reap-everything behaviour restored when CHUMP_REAPER_HEADLESS=1
#      (reaper runs through even with fg_pid empty).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/reap-orphan-claude-procs.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

AMBIENT_LOG="$TMP/ambient.jsonl"

# ── Test 1: fg_pid detected when Claude.app is "running" via pgrep shim ──────
#
# We place a fake `pgrep` binary in a shim dir that returns a synthetic PID
# (99999) when queried for the Claude.app path, simulating a running Claude.app.
# The reaper must detect it (fg_pid != empty) and proceed without hitting the
# safety gate.

SHIM_DIR_1="$TMP/shim1"
mkdir -p "$SHIM_DIR_1"

# Fake pgrep: returns PID 99999 when the pattern contains Claude.app, else real
cat > "$SHIM_DIR_1/pgrep" <<'SHIMEOF'
#!/usr/bin/env bash
if [[ "$*" == *Claude.app* ]]; then
    echo "99999"
    exit 0
fi
exec /usr/bin/pgrep "$@"
SHIMEOF
chmod +x "$SHIM_DIR_1/pgrep"

# Fake ps: must NOT return the Claude.app line (pgrep already found it), but
# must return at least one row so ps-output is non-empty.
cat > "$SHIM_DIR_1/ps" <<'SHIMEOF'
#!/usr/bin/env bash
# Minimal fake ps output: one innocuous process so the reaper doesn't exit 2.
printf '  1     0 00:01  1024 /sbin/launchd\n'
SHIMEOF
chmod +x "$SHIM_DIR_1/ps"

OUT_1="$(
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_PGREP_BIN="$SHIM_DIR_1/pgrep" \
    CHUMP_REAPER_PS_BIN="$SHIM_DIR_1/ps" \
    bash "$REAPER" 2>&1 || true
)"

# Must not exit 3 (safety gate must NOT have fired).
GATE_EXIT="$(
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_PGREP_BIN="$SHIM_DIR_1/pgrep" \
    CHUMP_REAPER_PS_BIN="$SHIM_DIR_1/ps" \
    bash "$REAPER" 2>&1; echo "exit=$?"
)"
echo "$GATE_EXIT" | grep -q "exit=0" \
    || fail "Test 1: reaper should exit 0 when Claude.app detected. Got: $GATE_EXIT"

# The output line must show fg_pid=99999 (not fg_pid=none).
echo "$OUT_1" | grep -q "fg_pid=99999" \
    || fail "Test 1: expected fg_pid=99999 in output. Got: $OUT_1"

ok "Test 1: fg_pid detected via pgrep shim (not empty)"

# ── Test 2: Safety gate exits 3 when fg_pid empty + no CHUMP_REAPER_HEADLESS ──
#
# Both pgrep shim and ps shim return nothing matching Claude.app.
# CHUMP_REAPER_HEADLESS is unset (or 0). Reaper must exit 3 with the
# documented diagnostic message and emit kind=reaper_safety_gate_triggered.

SHIM_DIR_2="$TMP/shim2"
mkdir -p "$SHIM_DIR_2"

# Fake pgrep: always returns empty (Claude.app not found).
cat > "$SHIM_DIR_2/pgrep" <<'SHIMEOF'
#!/usr/bin/env bash
# Simulate pgrep finding nothing for Claude.app
exit 1
SHIMEOF
chmod +x "$SHIM_DIR_2/pgrep"

# Fake ps: no Claude.app in output.
cat > "$SHIM_DIR_2/ps" <<'SHIMEOF'
#!/usr/bin/env bash
printf '  1     0 00:01  1024 /sbin/launchd\n'
SHIMEOF
chmod +x "$SHIM_DIR_2/ps"

rm -f "$AMBIENT_LOG"

GATE_MSG="$(
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_REAPER_HEADLESS="" \
    CHUMP_REAPER_PGREP_BIN="$SHIM_DIR_2/pgrep" \
    CHUMP_REAPER_PS_BIN="$SHIM_DIR_2/ps" \
    bash "$REAPER" 2>&1 || true
)"

EXIT_CODE="$(
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_REAPER_HEADLESS="" \
    CHUMP_REAPER_PGREP_BIN="$SHIM_DIR_2/pgrep" \
    CHUMP_REAPER_PS_BIN="$SHIM_DIR_2/ps" \
    bash "$REAPER" 2>/dev/null; echo "$?"
)"

[[ "$EXIT_CODE" == "3" ]] \
    || fail "Test 2: expected exit code 3, got $EXIT_CODE. Output: $GATE_MSG"

echo "$GATE_MSG" | grep -q "fg_pid=none on macOS without CHUMP_REAPER_HEADLESS=1" \
    || fail "Test 2: expected safety gate diagnostic message. Got: $GATE_MSG"

# Ambient event must have been written.
[[ -f "$AMBIENT_LOG" ]] \
    || fail "Test 2: ambient log was not created"
grep -q '"kind":"reaper_safety_gate_triggered"' "$AMBIENT_LOG" \
    || fail "Test 2: expected reaper_safety_gate_triggered in ambient log. Got: $(cat "$AMBIENT_LOG")"

ok "Test 2: safety gate exits 3 with correct message when fg_pid empty + no HEADLESS"

# ── Test 3: Old behaviour restored with CHUMP_REAPER_HEADLESS=1 ──────────────
#
# Same shim as test 2 (pgrep + ps find nothing for Claude.app), but
# CHUMP_REAPER_HEADLESS=1. Reaper must NOT exit 3 — it should proceed normally
# in reap-all mode. We use DRY_RUN=1 so no real killing happens.

rm -f "$AMBIENT_LOG"

HEADLESS_OUT="$(
    CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    CHUMP_REAPER_HEADLESS=1 \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_PGREP_BIN="$SHIM_DIR_2/pgrep" \
    CHUMP_REAPER_PS_BIN="$SHIM_DIR_2/ps" \
    bash "$REAPER" 2>&1; echo "exit=$?"
)"

echo "$HEADLESS_OUT" | grep -q "exit=0" \
    || fail "Test 3: reaper should exit 0 with CHUMP_REAPER_HEADLESS=1. Got: $HEADLESS_OUT"

# Must not have emitted the safety gate event.
if [[ -f "$AMBIENT_LOG" ]]; then
    grep -qv '"kind":"reaper_safety_gate_triggered"' "$AMBIENT_LOG" \
        || fail "Test 3: safety gate event must not appear when CHUMP_REAPER_HEADLESS=1"
fi

# fg_pid should be empty (none) in the output line.
echo "$HEADLESS_OUT" | grep -q "fg_pid=none" \
    || fail "Test 3: expected fg_pid=none in output (headless mode). Got: $HEADLESS_OUT"

ok "Test 3: CHUMP_REAPER_HEADLESS=1 bypasses safety gate, reaper runs normally"

echo ""
printf '\033[0;32m=== all fg-detection + safety-gate tests passed ===\033[0m\n'
