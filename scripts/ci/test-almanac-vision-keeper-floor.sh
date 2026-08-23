#!/usr/bin/env bash
# scripts/ci/test-almanac-vision-keeper-floor.sh — CREDIBLE-300
#
# Proves the almanac coverage floor is owned:
#   1. source contract: vision-keeper script present, syntax clean
#   2. FLOOR-BREACH: summary_pct below the floor -> vision-keeper pages via
#      operator-recall.sh --condition ALMANAC_VISION_ACUITY_FLOOR and emits
#      vision_acuity_floor_breach (this is the absolute-floor page that fires
#      even when coverage is merely STUCK below floor, not freshly dropping —
#      the exact blind spot the regression-only vision_acuity flag misses)
#   3. COVERAGE-OK: summary_pct at/above the floor -> no page, no
#      vision_acuity_floor_breach event
#   4. --dry-run does not page even when below floor
#   5. vital-signs.sh's almanac_coverage sign reads a fresh vision-acuity
#      state file and reports the real percentage (not "unknown")
#   6. vital-signs.sh's almanac_coverage sign reports "unknown" (not a
#      fabricated number) when the state file is missing or stale

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

KEEPER="$REPO_ROOT/scripts/ops/almanac-vision-keeper.sh"
VITAL_SIGNS="$REPO_ROOT/scripts/ops/vital-signs.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-almanac-vision-keeper-floor.sh (CREDIBLE-300) ==="

# ── 1. source contract ───────────────────────────────────────────────────────
echo "--- 1: source contract ---"
[[ -f "$KEEPER" ]] || fail "vision-keeper script missing: $KEEPER"
[[ -x "$KEEPER" ]] || fail "vision-keeper script not executable: $KEEPER"
bash -n "$KEEPER" || fail "vision-keeper bash -n failed"
[[ -f "$VITAL_SIGNS" ]] || fail "vital-signs script missing: $VITAL_SIGNS"
bash -n "$VITAL_SIGNS" || fail "vital-signs bash -n failed"
pass "vision-keeper + vital-signs present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Recall stub — records every invocation.
RECALL_CALL_LOG="$TMP/recall-calls.log"
RECALL_STUB="$TMP/recall-stub.sh"
cat > "$RECALL_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RECALL_CALL_LOG"
exit 0
EOF
chmod +x "$RECALL_STUB"

# Almanac binary stub — supports the subcommands vision-keeper drives.
mk_almanac_stub() {  # $1 = summary pct, $2 = summary count, $3 = summary total
    local bin="$TMP/almanac-stub-$1.sh"
    cat > "$bin" <<EOF
#!/usr/bin/env bash
case "\$1" in
  coverage)
    echo "summaries: $2/$3 summarizable files = $1%"
    echo "embeddings: 900/1000 symbols = 90%"
    ;;
  refresh|embed|summarize) exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$bin"
    printf '%s' "$bin"
}

INDEX_REPO="$TMP/index-repo"
mkdir -p "$INDEX_REPO"   # not a git checkout -> undrift_index_repo skips (RESET_STATUS=not_git)

# ── 2. FLOOR-BREACH: below floor -> pages + emits event ────────────────────
echo "--- 2: floor-breach path ---"
LOW_BIN="$(mk_almanac_stub 68 3220 4697)"
AMB1="$TMP/ambient1.jsonl"
: > "$AMB1"; : > "$RECALL_CALL_LOG"
out="$(CHUMP_ALMANAC_BIN="$LOW_BIN" \
    CHUMP_ALMANAC_INDEX_REPO="$INDEX_REPO" \
    CHUMP_VISION_KEEPER_MAX_SUMMARIZE_ROUNDS=0 \
    CHUMP_VISION_KEEPER_SUMMARY_FLOOR_PCT=95 \
    CHUMP_VISION_KEEPER_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_VISION_ACUITY_STATE="$TMP/state1" \
    CHUMP_AMBIENT_LOG="$AMB1" "$KEEPER" --once 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] || fail "vision-keeper exited $rc on floor-breach path; output: $out"
grep -q -- "--condition ALMANAC_VISION_ACUITY_FLOOR" "$RECALL_CALL_LOG" \
    || fail "expected operator-recall.sh --condition ALMANAC_VISION_ACUITY_FLOOR; calls: $(cat "$RECALL_CALL_LOG")"
grep -q '"kind":"vision_acuity_floor_breach"' "$AMB1" \
    || fail "expected vision_acuity_floor_breach emitted; ambient: $(cat "$AMB1")"
grep -q '"summary_pct":68' "$AMB1" \
    || fail "expected summary_pct:68 in floor_breach event; ambient: $(cat "$AMB1")"
pass "summary_pct below floor -> operator-recall paged + vision_acuity_floor_breach emitted"

# ── 3. COVERAGE-OK: at/above floor -> no page ───────────────────────────────
echo "--- 3: coverage-ok path ---"
OK_BIN="$(mk_almanac_stub 97 4557 4697)"
AMB2="$TMP/ambient2.jsonl"
: > "$AMB2"; : > "$RECALL_CALL_LOG"
CHUMP_ALMANAC_BIN="$OK_BIN" \
    CHUMP_ALMANAC_INDEX_REPO="$INDEX_REPO" \
    CHUMP_VISION_KEEPER_MAX_SUMMARIZE_ROUNDS=0 \
    CHUMP_VISION_KEEPER_SUMMARY_FLOOR_PCT=95 \
    CHUMP_VISION_KEEPER_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_VISION_ACUITY_STATE="$TMP/state2" \
    CHUMP_AMBIENT_LOG="$AMB2" "$KEEPER" --once >/dev/null 2>&1
[[ -s "$RECALL_CALL_LOG" ]] && fail "coverage OK must not page; calls: $(cat "$RECALL_CALL_LOG")"
grep -q '"kind":"vision_acuity_floor_breach"' "$AMB2" \
    && fail "coverage OK must not emit vision_acuity_floor_breach; ambient: $(cat "$AMB2")"
pass "summary_pct at/above floor -> no page, no floor_breach event"

# ── 4. --dry-run does not page even below floor ─────────────────────────────
echo "--- 4: dry-run path ---"
AMB3="$TMP/ambient3.jsonl"
: > "$AMB3"; : > "$RECALL_CALL_LOG"
CHUMP_ALMANAC_BIN="$LOW_BIN" \
    CHUMP_ALMANAC_INDEX_REPO="$INDEX_REPO" \
    CHUMP_VISION_KEEPER_MAX_SUMMARIZE_ROUNDS=0 \
    CHUMP_VISION_KEEPER_SUMMARY_FLOOR_PCT=95 \
    CHUMP_VISION_KEEPER_RECALL_SCRIPT="$RECALL_STUB" \
    CHUMP_VISION_ACUITY_STATE="$TMP/state3" \
    CHUMP_AMBIENT_LOG="$AMB3" "$KEEPER" --once --dry-run >/dev/null 2>&1
[[ -s "$RECALL_CALL_LOG" ]] && fail "--dry-run must not page operator-recall; calls: $(cat "$RECALL_CALL_LOG")"
pass "--dry-run: below floor but no page"

# ── 5. vital-signs almanac_coverage sign reads a fresh state file ──────────
echo "--- 5: vital-signs fresh state ---"
STATE_FRESH="$TMP/vision-acuity.state.fresh"
printf '90 68\n' > "$STATE_FRESH"
signs_json="$(CHUMP_VISION_ACUITY_STATE="$STATE_FRESH" \
    CHUMP_AMBIENT_LOG="$TMP/vs-ambient1.jsonl" \
    CHUMP_VITALS_OUT="$TMP/vitals1.json" \
    "$VITAL_SIGNS" --dry-run 2>/dev/null)"
almcov="$(printf '%s' "$signs_json" | jq -r '.signs[] | select(.key=="almanac_coverage")')"
[[ -n "$almcov" ]] || fail "almanac_coverage sign missing from vital-signs output"
val="$(printf '%s' "$almcov" | jq -r '.value')"
status="$(printf '%s' "$almcov" | jq -r '.status')"
[[ "$val" == "68" ]] || fail "expected almanac_coverage value=68, got: $val"
[[ "$status" == "red" ]] || fail "expected almanac_coverage status=red (68 < amber floor 80), got: $status"
pass "almanac_coverage sign reads fresh state file: value=68 status=red"

# ── 6. vital-signs almanac_coverage sign reports unknown when state absent ──
echo "--- 6: vital-signs missing state ---"
signs_json2="$(CHUMP_VISION_ACUITY_STATE="$TMP/does-not-exist.state" \
    CHUMP_AMBIENT_LOG="$TMP/vs-ambient2.jsonl" \
    CHUMP_VITALS_OUT="$TMP/vitals2.json" \
    "$VITAL_SIGNS" --dry-run 2>/dev/null)"
almcov2="$(printf '%s' "$signs_json2" | jq -r '.signs[] | select(.key=="almanac_coverage")')"
status2="$(printf '%s' "$almcov2" | jq -r '.status')"
value2="$(printf '%s' "$almcov2" | jq -r '.value')"
[[ "$status2" == "unknown" ]] || fail "expected almanac_coverage status=unknown when state file missing, got: $status2"
[[ "$value2" == "null" ]] || fail "expected almanac_coverage value=null when state file missing, got: $value2"
pass "almanac_coverage sign reports unknown/null (not fabricated) when state file is missing"

echo "=== all almanac-vision-keeper-floor tests passed ==="
