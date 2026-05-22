#!/usr/bin/env bash
# test-stale-process-watchdog.sh — INFRA-1663
# Validates the generalized stale-process watchdog:
#   - script exists + executable + bash syntax clean
#   - plist exists + references the script
#   - CHUMP_STALE_PROC_WATCHDOG=0 bypass is honored
#   - per-class lifetime thresholds respected (rustc, cargo, chump health,
#     worker.sh, bot-merge.sh, run-fleet.sh)
#   - fresh processes left alone, stale ones flagged
#   - emits kind=stale_process_reaped events with comm/etime/expected/pid
#   - idempotent (running twice on same fixture doesn't double-count kills)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WATCHDOG="$REPO_ROOT/scripts/ops/stale-process-watchdog.sh"
PLIST="$REPO_ROOT/launchd/com.chump.stale-process-watchdog.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-stale-process-watchdog.sh"

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "=== test-stale-process-watchdog.sh (INFRA-1663) ==="

# ── 1. Script presence + executable ──────────────────────────────────────────
echo "--- 1: script exists + executable ---"
[[ -f "$WATCHDOG" ]] || fail "watchdog script missing: $WATCHDOG"
[[ -x "$WATCHDOG" ]] || fail "watchdog script not executable: $WATCHDOG"
pass "watchdog script present + executable"

# ── 2. bash syntax ───────────────────────────────────────────────────────────
echo "--- 2: bash syntax clean ---"
bash -n "$WATCHDOG" || fail "watchdog bash -n failed"
bash -n "$INSTALL"  || fail "install bash -n failed"
pass "bash -n clean (watchdog + installer)"

# ── 3. plist present + references the script ────────────────────────────────
echo "--- 3: plist references script ---"
[[ -f "$PLIST" ]] || fail "plist missing: $PLIST"
grep -q "stale-process-watchdog.sh" "$PLIST" \
    || fail "plist does not reference stale-process-watchdog.sh"
grep -q "com.chump.stale-process-watchdog" "$PLIST" \
    || fail "plist missing expected Label com.chump.stale-process-watchdog"
pass "plist present + references watchdog script"

# ── 4. CHUMP_STALE_PROC_WATCHDOG=0 bypass ────────────────────────────────────
echo "--- 4: CHUMP_STALE_PROC_WATCHDOG=0 bypass ---"
TMP_AMB="$(mktemp)"
FAKE_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_AMB" "$FAKE_DIR"' EXIT
: > "$TMP_AMB"
out="$(CHUMP_STALE_PROC_WATCHDOG=0 CHUMP_AMBIENT_LOG="$TMP_AMB" "$WATCHDOG" 2>&1)"
echo "$out" | grep -q "CHUMP_STALE_PROC_WATCHDOG=0" \
    || fail "bypass did not log expected message; got: $out"
[[ ! -s "$TMP_AMB" ]] \
    || fail "bypass should not write to ambient.jsonl; got: $(cat "$TMP_AMB")"
pass "CHUMP_STALE_PROC_WATCHDOG=0 short-circuits cleanly"

# ── 5. Lifetime table referenced in source ───────────────────────────────────
echo "--- 5: lifetime table present in source ---"
for class in "chump health" "bot-merge.sh" "worker.sh" "run-fleet.sh" "rustc" "cargo"; do
    grep -q "$class" "$WATCHDOG" || fail "lifetime table missing class: $class"
done
# Numeric thresholds (the canonical ones from the gap AC).
for sec in 120 1200 14400 86400 600 900; do
    grep -q "\\b$sec\\b" "$WATCHDOG" || fail "lifetime table missing threshold: ${sec}s"
done
pass "lifetime table covers all 6 classes with canonical thresholds"

# ── 6. Synthetic ps fixture ──────────────────────────────────────────────────
# Format the watchdog requests: ps -A -o pid=,etime=,comm=,args=
#
# Columns:  PID  ETIME       COMM         ARGS
#
# Fixture rows (etime intentionally crossing each class's threshold):
#   3001  02-00:00:00  rustc       /usr/local/bin/rustc --edition=2021 src/lib.rs   <- STALE (2d > 10min)
#   3002  05:00        rustc       /usr/local/bin/rustc src/main.rs                  <- fresh (5m < 10min)
#   3003  20:00        cargo       /usr/local/bin/cargo build --release              <- STALE (20m > 15min)
#   3004  10:00        cargo       /usr/local/bin/cargo check                        <- fresh (10m < 15min)
#   3005  11:00:00     chump       /usr/local/bin/chump health --slo-check           <- STALE (11h > 2min)
#   3006  01:00        chump       /usr/local/bin/chump health --slo-check           <- fresh (1m < 2min)
#   3007  05:00:00     worker.sh   /bin/bash scripts/dispatch/worker.sh              <- fresh (5h > 4h → STALE)
#   3008  02:00:00     worker.sh   /bin/bash scripts/dispatch/worker.sh              <- fresh (2h < 4h)
#   3009  30:00        bot-merge.  /bin/bash scripts/coord/bot-merge.sh --gap X      <- STALE (30m > 20min)
#   3010  10:00        bot-merge.  /bin/bash scripts/coord/bot-merge.sh --gap Y      <- fresh (10m < 20min)
#   3011  02-00:00:00  run-fleet.  /bin/bash scripts/dispatch/run-fleet.sh --size 3  <- STALE (2d > 24h)
#   3012  10:00:00     run-fleet.  /bin/bash scripts/dispatch/run-fleet.sh --size 3  <- fresh (10h < 24h)
#
# Expected: 6 stale (3001, 3003, 3005, 3007, 3009, 3011); 6 left alone.

echo "--- 6: synthetic ps fixture (per-class thresholds) ---"

cat > "$FAKE_DIR/ps" <<'FAKE_PS'
#!/usr/bin/env bash
# Stub ps for INFRA-1663 watchdog test.
# Honors ps -A -o pid=,etime=,comm=,args= (the exact call the watchdog makes).
cat <<'TBL'
 3001 02-00:00:00 rustc /usr/local/bin/rustc --edition=2021 src/lib.rs
 3002 05:00 rustc /usr/local/bin/rustc src/main.rs
 3003 20:00 cargo /usr/local/bin/cargo build --release
 3004 10:00 cargo /usr/local/bin/cargo check
 3005 11:00:00 chump /usr/local/bin/chump health --slo-check
 3006 01:00 chump /usr/local/bin/chump health --slo-check
 3007 05:00:00 worker.sh /bin/bash scripts/dispatch/worker.sh
 3008 02:00:00 worker.sh /bin/bash scripts/dispatch/worker.sh
 3009 30:00 bot-merge. /bin/bash scripts/coord/bot-merge.sh --gap X
 3010 10:00 bot-merge. /bin/bash scripts/coord/bot-merge.sh --gap Y
 3011 02-00:00:00 run-fleet. /bin/bash scripts/dispatch/run-fleet.sh --size 3
 3012 10:00:00 run-fleet. /bin/bash scripts/dispatch/run-fleet.sh --size 3
TBL
FAKE_PS
chmod +x "$FAKE_DIR/ps"

: > "$TMP_AMB"
out="$(
    CHUMP_STALE_PROC_PS_BIN="$FAKE_DIR/ps" \
    CHUMP_STALE_PROC_DRY_RUN=1 \
    CHUMP_AMBIENT_LOG="$TMP_AMB" \
    "$WATCHDOG" 2>&1
)"
echo "$out" | sed 's/^/    /'

# Expect candidates=6 killed=6 under DRY_RUN.
echo "$out" | grep -qE "candidates=6 killed=6" \
    || fail "expected candidates=6 killed=6; got: $out"
pass "fixture: 12 rows → 6 stale flagged → 6 fresh skipped"

# Per-class stale assertions.
for pid in 3001 3003 3005 3007 3009 3011; do
    echo "$out" | grep -q "DRY-RUN would SIGTERM pid=$pid" \
        || fail "expected stale pid $pid to be flagged"
done
# Per-class fresh assertions (must NOT be flagged).
for pid in 3002 3004 3006 3008 3010 3012; do
    if echo "$out" | grep -q "DRY-RUN would SIGTERM pid=$pid"; then
        fail "fresh pid $pid should not be flagged"
    fi
done
pass "per-class thresholds respected (rustc/cargo/chump-health/worker.sh/bot-merge.sh/run-fleet.sh)"

# ── 7. Ambient events ────────────────────────────────────────────────────────
echo "--- 7: ambient events emitted with full fields ---"
grep -q '"kind":"stale_process_reaped"' "$TMP_AMB" \
    || fail "ambient.jsonl missing stale_process_reaped event"
# Each stale PID should appear in a per-kill emission.
for pid in 3001 3003 3005 3007 3009 3011; do
    grep -q "\"pid\":$pid," "$TMP_AMB" \
        || fail "missing per-kill event for pid $pid"
done
# Required fields per the EVENT_REGISTRY entry.
for field in '"comm":' '"class":' '"etime_secs":' '"expected_secs":' '"action":'; do
    grep -q "$field" "$TMP_AMB" \
        || fail "ambient event missing required field: $field"
done
# Heartbeat sweep record present.
grep -q '"sweep":true' "$TMP_AMB" \
    || fail "missing heartbeat sweep record (count=N proof-of-life)"
pass "ambient events have comm/class/etime_secs/expected_secs/action + sweep heartbeat"

# ── 8. Idempotency ───────────────────────────────────────────────────────────
echo "--- 8: idempotent (running twice produces consistent classifications) ---"
BEFORE_LINES="$(wc -l < "$TMP_AMB" | tr -d ' ')"
# Re-run with the same fixture. Each invocation appends its own batch of
# per-kill events + heartbeat, but the classification should be identical.
out2="$(
    CHUMP_STALE_PROC_PS_BIN="$FAKE_DIR/ps" \
    CHUMP_STALE_PROC_DRY_RUN=1 \
    CHUMP_AMBIENT_LOG="$TMP_AMB" \
    "$WATCHDOG" 2>&1
)"
echo "$out2" | grep -qE "candidates=6 killed=6" \
    || fail "second invocation diverged; expected candidates=6 killed=6; got: $out2"
AFTER_LINES="$(wc -l < "$TMP_AMB" | tr -d ' ')"
# Should grow by exactly (6 per-kill events + 1 heartbeat) = 7 lines.
DELTA=$((AFTER_LINES - BEFORE_LINES))
[[ "$DELTA" == "7" ]] || fail "second run delta=$DELTA, expected 7 (6 kills + 1 heartbeat)"
pass "idempotent: same fixture → same classification → +7 lines/run"

echo
echo "=== test-stale-process-watchdog.sh PASS ==="
