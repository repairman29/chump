#!/usr/bin/env bash
# scripts/ci/test-organ-reconcile.sh — RESILIENT-347
#
# Proves the per-node-applicable organ reconcile: an `enabled` organ whose
# manifest `requires=` spec is unmet on this node is SKIPPED (never even
# attempted), and an applicable organ that fails to enable/verify is backed
# off (disabled + cooldown-recorded) instead of being re-attempted — and
# therefore re-failed — on every single reconcile cycle. Without RESILIENT-347
# the reconcile called `systemctl enable --now` unconditionally on every
# `enabled` manifest line and re-tried a permanently-broken unit forever
# (the pre-347 churn on integrator/sla-scorecard/backlog-sync-writer/farmer).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-organ-reconcile.sh (RESILIENT-347) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
[[ -f "$RECONCILE" ]] || fail "reconcile script missing: $RECONCILE"
[[ -x "$RECONCILE" ]] || fail "reconcile script not executable: $RECONCILE"
bash -n "$RECONCILE" || fail "reconcile bash -n failed"
pass "script present, syntax clean"

# ── 2. Real manifest declares role= / requires= on the previously-churning
#       organs (integrator/backlog-sync-writer/farmer/rot-reaper) ───────────
REAL_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
for unit in chump-integrator.timer chump-farmer.timer chump-backlog-sync-writer.timer; do
    line="$(grep -E "^enabled +${unit//./\\.}" "$REAL_MANIFEST")"
    [[ -n "$line" ]] || fail "real manifest missing enabled line for $unit"
    echo "$line" | grep -q 'role=' || fail "real manifest line for $unit has no role="
    echo "$line" | grep -q 'requires=' || fail "real manifest line for $unit has no requires="
done
pass "real organ-manifest.txt declares role+requires on the previously-churning organs"

# ── 2b. RESILIENT-356: the healer itself is a peer-supervised organ ────────
# chump-organ-watchdog.timer heals every OTHER organ; without a manifest line
# for it, chump-organ-reconcile.timer (an independent peer on its own cadence)
# never notices if the watchdog's own timer goes inactive/disabled, so nothing
# restarts the healer. This line is what makes the watchdog "supervised by a
# peer heartbeat" (RESILIENT-356 AC2) — same mechanism as every other organ.
watchdog_line="$(grep -E '^enabled +chump-organ-watchdog\.timer' "$REAL_MANIFEST")"
[[ -n "$watchdog_line" ]] || fail "real manifest missing 'enabled chump-organ-watchdog.timer' — the healer itself is unsupervised"
pass "real organ-manifest.txt declares chump-organ-watchdog.timer as a peer-supervised organ (RESILIENT-356)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
CALL_LOG="$TMP/calls.log"
ACTIVE_FILE="$STATE_DIR/active.txt"
ENABLE_FAIL_FILE="$STATE_DIR/enable_fail.txt"
VERIFY_FAIL_FILE="$STATE_DIR/verify_fail.txt"
touch "$ACTIVE_FILE" "$ENABLE_FAIL_FILE" "$VERIFY_FAIL_FILE"

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    enable)
        # enable --now UNIT
        unit="${@: -1}"
        if grep -qxF "$unit" "$ENABLE_FAIL_FILE" 2>/dev/null; then
            exit 1
        fi
        if grep -qxF "$unit" "$VERIFY_FAIL_FILE" 2>/dev/null; then
            # enable itself "succeeds" but the unit never shows active — the
            # oneshot-fails-inside-ExecStart case organ-reconcile must verify.
            exit 0
        fi
        echo "$unit" >> "$ACTIVE_FILE"
        exit 0
        ;;
    disable)
        unit="${@: -1}"
        grep -vxF "$unit" "$ACTIVE_FILE" > "$ACTIVE_FILE.tmp" 2>/dev/null
        mv "$ACTIVE_FILE.tmp" "$ACTIVE_FILE" 2>/dev/null || true
        exit 0
        ;;
    stop|daemon-reload)
        exit 0
        ;;
    show)
        echo "ExecStart=/bin/true"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB"

BACKOFF_DIR="$TMP/organ-backoff"
AMBIENT="$TMP/ambient.jsonl"

run_reconcile() {  # mode
    : > "$CALL_LOG"
    STATE_DIR="$STATE_DIR" CALL_LOG="$CALL_LOG" \
    ACTIVE_FILE="$ACTIVE_FILE" ENABLE_FAIL_FILE="$ENABLE_FAIL_FILE" VERIFY_FAIL_FILE="$VERIFY_FAIL_FILE" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S=3600 \
    CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
    CHUMP_ORGAN_MANIFEST="$MANIFEST" \
    NODE_AMBIENT="$AMBIENT" \
    PATH="$TMP/bins:$PATH" \
    bash "$RECONCILE" "$1"
}

mkdir -p "$TMP/bins"

# ── 3. requires=bin:<missing> → SKIP, never attempted, --check treats it as
#       applicability-N/A rather than DRIFT ─────────────────────────────────
MANIFEST="$TMP/manifest-notapplicable.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-fake-organ.service  role=muscle requires=bin:chump-fake-binary-that-does-not-exist
EOF
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"

out="$(run_reconcile --check)"
echo "$out" | grep -q "SKIP.*chump-fake-organ.service.*not applicable" \
    || fail "--check must report an unmet requires= as SKIP not-applicable; got: $out"
echo "$out" | grep -q "DRIFT" && fail "--check must NOT flag a not-applicable organ as DRIFT; got: $out"

: > "$AMBIENT"
run_reconcile --apply >/dev/null
grep -q "enable --now chump-fake-organ.service" "$CALL_LOG" \
    && fail "reconcile must NEVER attempt enable on an organ whose requires= is unmet; calls: $(cat "$CALL_LOG")"
grep -q '"kind":"organ_reconcile_not_applicable"' "$AMBIENT" \
    || fail "expected organ_reconcile_not_applicable in ambient; got: $(cat "$AMBIENT")"
pass "3: unmet requires= → organ is SKIPPED, never attempted (curated per-node, not blast-all)"

# ── 4. applicable + enable succeeds + verifies active → started, no backoff ──
MANIFEST="$TMP/manifest-ok.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-good-organ.service  role=brain requires=bin:chump-good-binary
EOF
cat > "$TMP/bins/chump-good-binary" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bins/chump-good-binary"
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
grep -q "enable --now chump-good-organ.service" "$CALL_LOG" \
    || fail "expected an enable --now attempt for the applicable+healthy organ"
grep -qxF "chump-good-organ.service" "$ACTIVE_FILE" \
    || fail "organ should have been started (present in stub's active set)"
[[ -f "$BACKOFF_DIR/chump-good-organ.service.json" ]] \
    && fail "a successfully-started organ must not have a backoff record"
pass "4: applicable + healthy organ starts normally, no backoff recorded"

# ── 5. applicable but enable fails → backed off (disabled, cooldown-recorded)
#       AND the second reconcile cycle does NOT re-attempt it (churn proof) ─
MANIFEST="$TMP/manifest-fail.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-broken-organ.service  role=muscle requires=bin:chump-good-binary
EOF
: > "$ACTIVE_FILE"
echo "chump-broken-organ.service" > "$ENABLE_FAIL_FILE"
: > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
[[ -f "$BACKOFF_DIR/chump-broken-organ.service.json" ]] \
    || fail "a failed-to-enable organ must be recorded in backoff"
grep -q '"kind":"organ_reconcile_backoff"' "$AMBIENT" \
    || fail "expected organ_reconcile_backoff in ambient; got: $(cat "$AMBIENT")"
first_call_count="$(grep -c "enable --now chump-broken-organ.service" "$CALL_LOG")"
[[ "$first_call_count" -ge 1 ]] || fail "expected at least one enable attempt on the first cycle"

# Second cycle, same cooldown window: must skip re-attempting the enable —
# this is the exact churn (re-install-every-cycle) RESILIENT-347 kills.
run_reconcile --apply >/dev/null
grep -q "enable --now chump-broken-organ.service" "$CALL_LOG" \
    && fail "second reconcile cycle within backoff cooldown must NOT re-attempt enable; calls: $(cat "$CALL_LOG")"
grep -q '"kind":"organ_reconcile_backoff_skip"' "$AMBIENT" \
    || fail "expected organ_reconcile_backoff_skip on the cooled-down cycle; got: $(cat "$AMBIENT")"
pass "5: enable failure -> backoff recorded; SECOND cycle skips re-attempt entirely (no per-cycle churn)"

# ── 6. applicable + enable succeeds but never verifies active → backoff too ─
MANIFEST="$TMP/manifest-verifyfail.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-flaky-organ.service  role=data requires=bin:chump-good-binary
EOF
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"
echo "chump-flaky-organ.service" > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
[[ -f "$BACKOFF_DIR/chump-flaky-organ.service.json" ]] \
    || fail "an enable-ok-but-never-active organ must be backed off after verify fails"
grep -q "disable --now chump-flaky-organ.service" "$CALL_LOG" \
    || fail "verify-failed organ must be disabled (stop churning), not left half-enabled"
pass "6: enable succeeds but unit never verifies active -> disabled + backed off (not left churning)"

# ── 7. backoff cooldown expiry retries the organ ─────────────────────────────
MANIFEST="$TMP/manifest-retry.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-recovered-organ.service  role=muscle requires=bin:chump-good-binary
EOF
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"; mkdir -p "$BACKOFF_DIR"
old_since=$(( $(date +%s) - 999999 ))
printf '{"unit":"chump-recovered-organ.service","since":%d,"reason":"enable_failed"}\n' "$old_since" \
    > "$BACKOFF_DIR/chump-recovered-organ.service.json"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
grep -q "enable --now chump-recovered-organ.service" "$CALL_LOG" \
    || fail "an EXPIRED backoff must allow the organ to be retried"
grep -qxF "chump-recovered-organ.service" "$ACTIVE_FILE" \
    || fail "the retried organ should have started successfully this time"
pass "7: expired backoff cooldown retries the organ (not a permanent disable)"

echo "ALL PASS"
