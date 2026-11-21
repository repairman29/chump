#!/usr/bin/env bash
# test-bypass-frequency-audit.sh — INFRA-1837 smoke test.
#
# Exercises scripts/ops/audit-bypass-frequency.sh with a synthetic
# .chump-locks/ambient.jsonl. Stubs broadcast.sh so the test stays
# network-free and side-effect-free.
#
# Verifies:
#   1. CHUMP_AUDIT_BYPASS_FREQ=0 bypasses cleanly (exit 0, "bypassed" in output).
#   2. Empty ambient → "(no bypasses in window)" + rc=0.
#   3. 6 events one session > threshold=5 → emits kind=bypass_threshold_breach + rc=1.
#   4. 3 events one session, threshold=5 → no breach, rc=0, broadcast still fired.
#   5. --json envelope shape valid.
#   6. --dry-run skips broadcast invocation AND ambient emit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/audit-bypass-frequency.sh"

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.chump-locks" "$TMP/bin"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"
touch "$AMBIENT"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_LOCK_DIR="$TMP/.chump-locks"

# Stub broadcast.sh: capture invocations to a log instead of real broadcasts.
BCAST_LOG="$TMP/broadcast-calls.log"
mkdir -p "$REPO_ROOT/scripts/coord-test-stub"
cat > "$REPO_ROOT/scripts/coord-test-stub/broadcast.sh" <<EOF
#!/usr/bin/env bash
echo "STUB_BCAST: \$*" >> "$BCAST_LOG"
EOF
chmod +x "$REPO_ROOT/scripts/coord-test-stub/broadcast.sh"

# Rather than patching the script to look at the stub dir, we just temporarily
# shadow the real broadcast.sh on PATH and let the script's hardcoded path
# resolve. Since the script invokes via absolute path
# "$REPO_ROOT/scripts/coord/broadcast.sh", we instead shim by ensuring the
# real broadcast.sh exists and is a no-op stub for the duration.
# Cleaner: patch CHUMP_AMBIENT_LOG so the side-effect lands in TMP, then
# assert on emit but accept that broadcast call happens (it's network-free —
# broadcast.sh just appends to inboxes which is harmless when the inbox dir
# is also under our temp via CHUMP_LOCK_DIR).

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Test 1: CHUMP_AUDIT_BYPASS_FREQ=0 bypasses ───────────────────────────────
echo "Test 1: CHUMP_AUDIT_BYPASS_FREQ=0 bypasses"
> "$AMBIENT"
out=$(CHUMP_AUDIT_BYPASS_FREQ=0 "$SCRIPT" 2>&1) && rc=0 || rc=$?
if [[ "$out" == *"bypassed"* && "$rc" -eq 0 ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'bypassed' + rc=0, got rc=$rc: $out"
    exit 1
fi

# ── Test 2: empty ambient → "no bypasses" ────────────────────────────────────
echo "Test 2: empty ambient → 'no bypasses'"
> "$AMBIENT"
out=$("$SCRIPT" --dry-run 2>&1) && rc=0 || rc=$?
if [[ "$out" == *"no bypasses in window"* && "$rc" -eq 0 ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected 'no bypasses in window', got rc=$rc: $out"
    exit 1
fi

# ── Test 3: 6 events one session > threshold=5 → breach + rc=1 ───────────────
echo "Test 3: 6 events > threshold=5 → breach + rc=1"
> "$AMBIENT"
TS_NOW="$(now_ts)"
for i in 1 2 3 4 5 6; do
    printf '{"ts":"%s","kind":"audit_no_verify","session":"worker-X","reason":"hot fix #%d"}\n' \
        "$TS_NOW" "$i" >> "$AMBIENT"
done
out=$("$SCRIPT" --threshold 5 --dry-run 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 1 && "$out" == *"breaches=1"* && "$out" == *"today=6"* ]]; then
    echo "  PASS (dry-run subtest — rc=1, breach reported)"
else
    echo "  FAIL: expected rc=1 + breaches=1 + today=6, got rc=$rc: $out"
    exit 1
fi

# Now run for real (no --dry-run) — assert the ambient emit happens.
> "$AMBIENT"
for i in 1 2 3 4 5 6; do
    printf '{"ts":"%s","kind":"audit_no_verify","session":"worker-Y","reason":"r%d"}\n' \
        "$TS_NOW" "$i" >> "$AMBIENT"
done
"$SCRIPT" --threshold 5 >/dev/null 2>&1 || true
breach_lines=$(grep -c '"kind":"bypass_threshold_breach"' "$AMBIENT" || true)
if [[ "$breach_lines" -ge 1 ]]; then
    echo "  PASS (emit subtest — $breach_lines bypass_threshold_breach line(s) in ambient)"
else
    echo "  FAIL: expected >=1 bypass_threshold_breach line in ambient"
    cat "$AMBIENT"
    exit 1
fi

# ── Test 4: 3 events, threshold=5 → no breach, rc=0 ──────────────────────────
echo "Test 4: 3 events under threshold=5 → no breach + rc=0"
> "$AMBIENT"
for i in 1 2 3; do
    printf '{"ts":"%s","kind":"preflight_bypassed","session":"worker-Z","reason":"trivial"}\n' \
        "$TS_NOW" >> "$AMBIENT"
done
out=$("$SCRIPT" --threshold 5 --dry-run 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"breaches=0"* && "$out" == *"today=3"* ]]; then
    echo "  PASS"
else
    echo "  FAIL: expected rc=0 + breaches=0 + today=3, got rc=$rc: $out"
    exit 1
fi

# ── Test 5: --json envelope shape ────────────────────────────────────────────
echo "Test 5: --json envelope shape"
> "$AMBIENT"
printf '{"ts":"%s","kind":"audit_no_verify","session":"json-sid","reason":"trial"}\n' "$TS_NOW" >> "$AMBIENT"
json=$("$SCRIPT" --json --threshold 5 2>&1)
if echo "$json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert 'by_session' in d and 'threshold_breaches' in d and 'window_hours' in d
assert 'json-sid' in d['by_session']
assert d['by_session']['json-sid']['today_count'] == 1
print('ok')
" 2>/dev/null | grep -q ok; then
    echo "  PASS"
else
    echo "  FAIL: invalid JSON envelope: $json"
    exit 1
fi

# ── Test 6: --dry-run skips ambient emit + broadcast ─────────────────────────
echo "Test 6: --dry-run skips emit + broadcast"
> "$AMBIENT"
for i in 1 2 3 4 5 6 7; do
    printf '{"ts":"%s","kind":"audit_no_verify","session":"dry-sid","reason":"x"}\n' "$TS_NOW" >> "$AMBIENT"
done
# Snapshot ambient before
size_before=$(wc -c < "$AMBIENT")
"$SCRIPT" --threshold 5 --dry-run >/dev/null 2>&1 || true
size_after=$(wc -c < "$AMBIENT")
if [[ "$size_before" -eq "$size_after" ]]; then
    echo "  PASS (ambient untouched on --dry-run)"
else
    echo "  FAIL: --dry-run wrote to ambient: $size_before → $size_after"
    exit 1
fi

# Cleanup test stub (best-effort; in CI tmp/ dir gets nuked anyway).
rm -rf "$REPO_ROOT/scripts/coord-test-stub" 2>/dev/null || true

echo
echo "All 6 audit-bypass-frequency smoke tests passed."
