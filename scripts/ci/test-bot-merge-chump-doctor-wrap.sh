#!/usr/bin/env bash
# test-bot-merge-chump-doctor-wrap.sh — INFRA-458
#
# Verifies chump_with_doctor wraps timeouts → chump-doctor heal → retry,
# preserves stream separation, and respects the bypass env.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/bot-merge.sh"

[[ -f "$SCRIPT" ]] || { echo "FATAL: bot-merge.sh missing"; exit 2; }

echo "=== INFRA-458 chump_with_doctor wrap test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- Test 1: helper function exists and replaces the 2 known call sites ---
if grep -q '^chump_with_doctor()' "$SCRIPT"; then
    ok "chump_with_doctor function defined"
else
    fail "chump_with_doctor function missing"
fi

# Both known internal chump call sites use the wrapper
if grep -qE 'chump_with_doctor gap ship' "$SCRIPT" \
   && grep -qE 'chump_with_doctor gap list' "$SCRIPT"; then
    ok "internal call sites use chump_with_doctor (gap ship, gap list)"
else
    fail "expected chump_with_doctor wraps for 'gap ship' and 'gap list' not found"
fi

# Lingering raw `chump gap` invocations (excluding comments / docstrings) should
# go through the wrapper. We grep for non-comment lines that begin with chump.
LINGERING=$(grep -nE '^[[:space:]]+chump (gap|--briefing) ' "$SCRIPT" \
            | grep -v 'chump_with_doctor' || true)
if [[ -z "$LINGERING" ]]; then
    ok "no lingering raw 'chump gap' or 'chump --briefing' invocations"
else
    fail "raw chump invocations remain (must use chump_with_doctor):"
    echo "$LINGERING" | sed 's/^/    /'
fi

# --- Test 2: function honors CHUMP_INTERNAL_DOCTOR=0 bypass ---
# Sandbox: build a fake `chump` on PATH that exits 0 immediately, source
# bot-merge.sh's helper definitions, call chump_with_doctor with bypass set.
FAKE_BIN="$TMPDIR_BASE/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/chump" <<'BIN'
#!/usr/bin/env bash
echo "fake-chump-stdout"
echo "fake-chump-stderr" >&2
exit 0
BIN
chmod +x "$FAKE_BIN/chump"

# Extract just the helper function (and its dependency chain) into a sourceable
# file so we can call it standalone without running bot-merge.sh end-to-end.
HELPER_SCRIPT="$TMPDIR_BASE/helpers.sh"
cat >"$HELPER_SCRIPT" <<'SH'
#!/usr/bin/env bash
green()  { printf '%s\n' "[green] $*"; }
red()    { printf '%s\n' "[red] $*"; }
yellow() { printf '%s\n' "[yellow] $*"; }
info()   { printf '%s\n' "[info] $*"; }
SH
# Append the chump_with_doctor function from bot-merge.sh. Use sed to extract
# from its definition line through the matching closing `}`.
awk '/^chump_with_doctor\(\) \{/,/^\}/' "$SCRIPT" >> "$HELPER_SCRIPT"

OUTPUT="$(
    export PATH="$FAKE_BIN:$PATH"
    CHUMP_INTERNAL_DOCTOR=0
    # shellcheck disable=SC1090
    source "$HELPER_SCRIPT"
    chump_with_doctor --version 2>/dev/null
)"

if [[ "$OUTPUT" == "fake-chump-stdout" ]]; then
    ok "CHUMP_INTERNAL_DOCTOR=0 bypasses wrapper (raw chump call)"
else
    fail "bypass produced unexpected output: $OUTPUT"
fi

# --- Test 3: timeout triggers heal + retry ---
# Build a fake chump that hangs forever on the first invocation, but exits
# fine on the second (simulating "doctor healed the inode"). Use a counter
# file to track invocation number.
COUNTER="$TMPDIR_BASE/chump.calls"
echo 0 > "$COUNTER"

cat >"$FAKE_BIN/chump" <<BIN
#!/usr/bin/env bash
n=\$(cat "$COUNTER")
n=\$((n + 1))
echo "\$n" > "$COUNTER"
if [[ "\$n" -eq 1 ]]; then
    sleep 30  # hang past the 2s timeout below
fi
echo "recovered-on-attempt-\$n"
exit 0
BIN
chmod +x "$FAKE_BIN/chump"

# Fake chump-doctor: just records that it ran.
DOCTOR_LOG="$TMPDIR_BASE/doctor.calls"
mkdir -p "$TMPDIR_BASE/scripts/dev"
cat >"$TMPDIR_BASE/scripts/dev/chump-doctor.sh" <<DOCTOR
#!/usr/bin/env bash
echo "doctor-ran" >> "$DOCTOR_LOG"
exit 0
DOCTOR
chmod +x "$TMPDIR_BASE/scripts/dev/chump-doctor.sh"

# Need a `timeout` binary. macOS doesn't ship one; gtimeout (coreutils) does.
# Skip Test 3 cleanly if neither is available.
if ! command -v timeout >/dev/null && ! command -v gtimeout >/dev/null; then
    echo "  SKIP: no timeout/gtimeout binary on PATH — skipping heal-retry test"
else
    OUTPUT="$(
        export PATH="$FAKE_BIN:$PATH"
        export REPO_ROOT="$TMPDIR_BASE"
        export CHUMP_INTERNAL_TIMEOUT=2
        unset CHUMP_INTERNAL_DOCTOR
        # shellcheck disable=SC1090
        source "$HELPER_SCRIPT"
        chump_with_doctor --version 2>/dev/null
    )"

    CALLS=$(cat "$COUNTER")
    if [[ "$OUTPUT" == "recovered-on-attempt-2" ]] && [[ "$CALLS" -eq 2 ]]; then
        ok "timeout triggered retry (2 chump calls, recovered on second)"
    else
        fail "expected 'recovered-on-attempt-2' with 2 calls; got '$OUTPUT' / $CALLS calls"
    fi

    if [[ -f "$DOCTOR_LOG" ]] && grep -q "doctor-ran" "$DOCTOR_LOG"; then
        ok "chump-doctor.sh was invoked between attempts"
    else
        fail "chump-doctor.sh was not invoked"
    fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
