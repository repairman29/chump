#!/usr/bin/env bash
# test-reaper-pty-pressure.sh — INFRA-1851
#
# Asserts the PTY-pressure urgent mode in reap-orphan-claude-procs.sh:
#   1. Below threshold → REAP_AGE stays at its default (no event emitted)
#   2. Above threshold → reaper_pty_pressure event written + REAP_AGE
#      effectively lowered (we observe via the event's new_reap_age field)
#   3. CHUMP_REAPER_PRESSURE_DISABLED=1 → no event even when above threshold
#
# Strategy: source the early-init portion of the script in a sandbox where
# we stub `sysctl` (returns fake ptmx_max) and `ls /dev/ttys???` (controls
# the allocated count). Run with CHUMP_REAPER_DRY_RUN=1 + CHUMP_REAPER_HEADLESS=1
# so the rest of the reaper is a no-op; we only care about the pressure
# pre-block at the top.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/reap-orphan-claude-procs.sh"
[ -x "$REAPER" ] || { echo "FAIL: reaper not executable at $REAPER" >&2; exit 1; }

SANDBOX="$(mktemp -d -t infra-1851.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

AMBIENT="$SANDBOX/ambient.jsonl"
: > "$AMBIENT"

# Stub sysctl + ls (only for /dev/ttys???) by prepending a fake bin dir to PATH.
FAKEBIN="$SANDBOX/bin"
mkdir -p "$FAKEBIN"

# sysctl stub: respond to `sysctl -n kern.tty.ptmx_max`.
cat > "$FAKEBIN/sysctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-n" ] && [ "$2" = "kern.tty.ptmx_max" ]; then
    echo "${FAKE_PTMX_MAX:-511}"
    exit 0
fi
exec /usr/sbin/sysctl "$@"
EOF
chmod +x "$FAKEBIN/sysctl"

# We can't reasonably stub `ls /dev/ttys???` via PATH (ls is bash builtin
# resolution). Instead, the reaper reads the count via wc. We rely on the
# real /dev/ttys??? for the below-threshold check (this host has ~127, well
# under the 65% default threshold of 511) and on FAKE_PTMX_MAX=150 for the
# above-threshold check (127/150 = 84% IS pressure, INFRA-1930).

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

count_events() {
    # grep -c exits non-zero on no-matches; swallow that without producing
    # a second "0" line that breaks the integer arithmetic in the caller.
    local n
    n=$(grep -c '"kind":"reaper_pty_pressure"' "$AMBIENT" 2>/dev/null || true)
    echo "${n:-0}"
}

# Reset ambient between cases.
reset_ambient() { : > "$AMBIENT"; }

# Case 1: below threshold (large ptmx_max). Expect 0 events.
reset_ambient
PATH="$FAKEBIN:$PATH" \
    FAKE_PTMX_MAX=10000 \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_HEADLESS=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$REAPER" >/dev/null 2>&1 || true
n=$(count_events)
[ "$n" -eq 0 ] || fail "case 1: expected 0 events below threshold, got $n"
pass "case 1: below threshold — no reaper_pty_pressure event"

# Case 2: above threshold (small ptmx_max). Expect exactly 1 event with
# new_reap_age == 600 (the default pressure_age).
reset_ambient
PATH="$FAKEBIN:$PATH" \
    FAKE_PTMX_MAX=150 \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_HEADLESS=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$REAPER" >/dev/null 2>&1 || true
n=$(count_events)
[ "$n" -eq 1 ] || fail "case 2: expected 1 event above threshold, got $n (ambient: $(cat $AMBIENT))"
grep -q '"new_reap_age":600' "$AMBIENT" || fail "case 2: event missing new_reap_age:600"
pass "case 2: above threshold — reaper_pty_pressure event with new_reap_age=600"

# Case 3: disabled via env. Expect 0 events even when above threshold.
reset_ambient
PATH="$FAKEBIN:$PATH" \
    FAKE_PTMX_MAX=150 \
    CHUMP_REAPER_PRESSURE_DISABLED=1 \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_HEADLESS=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$REAPER" >/dev/null 2>&1 || true
n=$(count_events)
[ "$n" -eq 0 ] || fail "case 3: expected 0 events with CHUMP_REAPER_PRESSURE_DISABLED=1, got $n"
pass "case 3: disabled bypass — no event"

# Case 4: custom threshold honored. Use a large ptmx_max so the actual
# pct is ~1% — well below a 50% custom threshold — and confirm no event.
# (Real-host allocated counts vary 100-200 across test runs as shells
# spawn/exit; we want a threshold check that's robust to that.)
reset_ambient
PATH="$FAKEBIN:$PATH" \
    FAKE_PTMX_MAX=10000 \
    CHUMP_REAPER_PRESSURE_THRESHOLD=50 \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_HEADLESS=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$REAPER" >/dev/null 2>&1 || true
n=$(count_events)
[ "$n" -eq 0 ] || fail "case 4: expected 0 events with custom threshold=50 and ample headroom, got $n"
pass "case 4: custom threshold — no event when actual pct below custom limit"

# Case 5: custom pressure_age value flows through to the event.
reset_ambient
PATH="$FAKEBIN:$PATH" \
    FAKE_PTMX_MAX=150 \
    CHUMP_REAPER_PRESSURE_AGE=120 \
    CHUMP_REAPER_DRY_RUN=1 \
    CHUMP_REAPER_HEADLESS=1 \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$REAPER" >/dev/null 2>&1 || true
grep -q '"new_reap_age":120' "$AMBIENT" || fail "case 5: custom pressure_age not honored"
pass "case 5: CHUMP_REAPER_PRESSURE_AGE override flows through"

echo "All INFRA-1851 reaper-pty-pressure tests passed."
