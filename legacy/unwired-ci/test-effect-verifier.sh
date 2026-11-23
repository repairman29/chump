#!/usr/bin/env bash
# scripts/ci/test-effect-verifier.sh — RESILIENT-1109 (umbrella RESILIENT-1103)
#
# Proves the effect verifier catches the class organ-success-verifier.sh
# (RESILIENT-1108) is structurally blind to: an organ that exits 0 and
# reports success every run, yet produces NO EFFECT — the farmer ticking
# against a non-empty pickable queue and claiming nothing. Also covers a
# legitimately-empty queue (no page — idle-doing-nothing-about-nothing is
# correct), a healthy organ that IS claiming (no page), a too-few-ticks
# sample (no false positive on a fresh boot), and the per-organ dedup window.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/ops/effect-verifier.sh"

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "=== test-effect-verifier.sh (RESILIENT-1109) ==="

# ── 1. Source contract ────────────────────────────────────────────────────────
[[ -f "$VERIFIER" ]] || fail "verifier script missing: $VERIFIER"
[[ -x "$VERIFIER" ]] || fail "verifier script not executable: $VERIFIER"
bash -n "$VERIFIER" || fail "verifier bash -n failed"
for u in service timer; do
    f="$REPO_ROOT/scripts/dispatch/chump-effect-verifier.$u"
    [[ -f "$f" ]] || fail "missing unit file $f"
done
if grep -q '^WorkingDirectory=' "$REPO_ROOT/scripts/dispatch/chump-effect-verifier.service"; then
    fail "unit sets WorkingDirectory= — the CHDIR trap this whole track exists to avoid"
fi
grep -q 'chump-effect-verifier.timer' "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    || fail "timer missing from organ-manifest.txt"
grep -q 'chump-effect-verifier.timer' "$REPO_ROOT/scripts/setup/install-helsinki-atc.sh" \
    || fail "timer missing from install-helsinki-atc.sh roster"
grep -qE '^organ_effect_noop[[:space:]]+page' "$REPO_ROOT/scripts/coord/operator-escalation-registry.txt" \
    || fail "organ_effect_noop not registered as page in escalation registry"
pass "script + units present, no WorkingDirectory trap, manifest/roster/escalation wired"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"
STATE_DB="$TMP/state.db"
STATE_DIR="$TMP/effect-verifier-state"
: > "$AMB"

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 required for this test"
sqlite3 "$STATE_DB" "CREATE TABLE gaps (id TEXT PRIMARY KEY, status TEXT);"

run_verifier() {
    CHUMP_EFFECT_VERIFIER_STATE_DB="$STATE_DB" \
    CHUMP_EFFECT_VERIFIER_STATE_DIR="$STATE_DIR" \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_EFFECT_VERIFIER_WINDOW_S=1800 \
    CHUMP_EFFECT_VERIFIER_MIN_TICKS=3 \
    CHUMP_EFFECT_VERIFIER_MIN_PICKABLE=1 \
    CHUMP_EFFECT_VERIFIER_DEDUP_WINDOW_S=3600 \
    "$VERIFIER" "$@" 2>&1
}

_recent_ts() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -j -f %s "$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# ── 2. THE NO-OP CASE: farmer heartbeats fine, queue non-empty, 0 claims ──────
sqlite3 "$STATE_DB" "DELETE FROM gaps;"
for i in $(seq 1 20); do sqlite3 "$STATE_DB" "INSERT INTO gaps VALUES ('G-$i','open');"; done
: > "$AMB"
for age in 60 300 600 900; do
    printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false,"counts":{"kicked":0,"silent_detected":0,"escalated":0}}\n' "$(_recent_ts "$age")" >> "$AMB"
done

out="$(run_verifier)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "verifier exited $rc; output: $out"
grep -q '"kind":"organ_effect_noop"' "$AMB" \
    || fail "expected organ_effect_noop emitted; ambient: $(cat "$AMB")"
grep -q '"organ":"chump-farmer.timer"' "$AMB" \
    || fail "farmer not named in the no-op event; ambient: $(cat "$AMB")"
grep -q '"pickable":20' "$AMB" \
    || fail "pickable count not recorded as 20; ambient: $(cat "$AMB")"
grep -q '"claimed":0' "$AMB" \
    || fail "claimed count not recorded as 0; ambient: $(cat "$AMB")"
grep -q '"kind":"operator_paged"' "$AMB" \
    || fail "expected operator_paged for the no-op organ; ambient: $(cat "$AMB")"
pass "exit-0-but-no-op DETECTED (heartbeats landing, queue non-empty, 0 claims) and PAGED"

# ── 3. Healthy organ: heartbeats + claims both landing -> no page ────────────
: > "$AMB"
for age in 60 300 600 900; do
    printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false}\n' "$(_recent_ts "$age")" >> "$AMB"
done
printf '{"ts":"%s","kind":"gap_claimed","gap_id":"G-1"}\n' "$(_recent_ts 120)" >> "$AMB"
rm -rf "$STATE_DIR"
out="$(run_verifier)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "verifier exited $rc on healthy case; output: $out"
grep -q '"kind":"organ_effect_noop"' "$AMB" \
    && fail "healthy organ (claiming) wrongly flagged as no-op; ambient: $(cat "$AMB")"
pass "healthy organ (claiming against a non-empty queue) NOT flagged"

# ── 4. Legitimately empty queue: heartbeats landing, 0 claims, pickable=0 ─────
sqlite3 "$STATE_DB" "DELETE FROM gaps;"
: > "$AMB"
for age in 60 300 600 900; do
    printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false}\n' "$(_recent_ts "$age")" >> "$AMB"
done
rm -rf "$STATE_DIR"
out="$(run_verifier)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "verifier exited $rc on empty-queue case; output: $out"
grep -q '"kind":"organ_effect_noop"' "$AMB" \
    && fail "empty-queue idle farmer wrongly flagged as no-op; ambient: $(cat "$AMB")"
pass "legitimately empty queue (pickable=0) NOT flagged — idle-about-nothing is correct"

# ── 5. Too few ticks to trust the sample -> no false positive ────────────────
sqlite3 "$STATE_DB" "DELETE FROM gaps;"
for i in $(seq 1 5); do sqlite3 "$STATE_DB" "INSERT INTO gaps VALUES ('H-$i','open');"; done
: > "$AMB"
printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false}\n' "$(_recent_ts 60)" >> "$AMB"
rm -rf "$STATE_DIR"
out="$(run_verifier)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "verifier exited $rc on too-few-ticks case; output: $out"
grep -q '"kind":"organ_effect_noop"' "$AMB" \
    && fail "single-heartbeat sample wrongly flagged (not enough ticks to trust); ambient: $(cat "$AMB")"
pass "too-few-ticks sample NOT flagged (avoids false positive on a fresh boot)"

# ── 6. Dedup: a still-stuck organ pages once per window, not every cycle ──────
sqlite3 "$STATE_DB" "DELETE FROM gaps;"
for i in $(seq 1 20); do sqlite3 "$STATE_DB" "INSERT INTO gaps VALUES ('D-$i','open');"; done
: > "$AMB"
for age in 60 300 600 900; do
    printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false}\n' "$(_recent_ts "$age")" >> "$AMB"
done
rm -rf "$STATE_DIR"
run_verifier >/dev/null 2>&1
: > "$AMB"
for age in 60 300 600 900; do
    printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false}\n' "$(_recent_ts "$age")" >> "$AMB"
done
out2="$(run_verifier)"; rc2=$?
[[ "$rc2" -eq 0 ]] || fail "second cycle exited $rc2; output: $out2"
grep -q '"kind":"organ_effect_noop_dedup_skip"' "$AMB" \
    || fail "expected organ_effect_noop_dedup_skip on the repeat cycle; ambient: $(cat "$AMB")"
if grep -q '"kind":"operator_paged"' "$AMB"; then
    fail "duty officer re-paged inside the dedup window (should be held); ambient: $(cat "$AMB")"
fi
pass "still-stuck no-op organ HELD (dedup) on the repeat cycle — one page per window"

# ── 7. --dry-run classifies but never pages ───────────────────────────────────
rm -rf "$STATE_DIR"
: > "$AMB"
for age in 60 300 600 900; do
    printf '{"ts":"%s","kind":"farmer_heartbeat","dry_run":false}\n' "$(_recent_ts "$age")" >> "$AMB"
done
run_verifier --dry-run >/dev/null 2>&1
grep -q '"kind":"organ_effect_noop"' "$AMB" || fail "--dry-run did not classify the no-op"
grep -q '"dry_run":true' "$AMB" || fail "--dry-run did not mark events dry_run:true"
if grep -q '"kind":"operator_paged"' "$AMB"; then
    fail "--dry-run paged the operator; ambient: $(cat "$AMB")"
fi
pass "--dry-run classifies without paging"

# ── 8. Summary receipt ────────────────────────────────────────────────────────
tick="$(grep '"kind":"effect_verify_tick"' "$AMB" | tail -1)"
[[ -n "$tick" ]] || fail "no effect_verify_tick summary emitted"
echo "$tick" | grep -q '"checked_total":1' || fail "summary checked_total != 1: $tick"
pass "per-cycle summary receipt present"

echo "=== ALL PASS (RESILIENT-1109) ==="
