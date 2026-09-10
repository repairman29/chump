#!/usr/bin/env bash
# scripts/ci/test-durability-gauge.sh — behaviour test for the DURABILITY GAUGE
# (scripts/ops/durability-gauge.sh + its two timeline libs).
#
# Depth tier: HAPPY-PATH + EDGE + one ADVERSARIAL (stale-cache-would-lie is
# covered by design in merge-timeline.sh but not exercised here — see GAPS).
# Self-contained + offline: synthetic merge/human fixtures, injectable NOW,
# temp OUT/ambient/page-state, NO real gh/Discord/LLM. Runs in <2s, mutates no
# fleet state.
#
# GAPS (honest, per test-depth doctrine):
#   - Does NOT exercise the live gh/cache fallback in merge-timeline.sh (network)
#     nor the sqlite stale-cache guard — those need a real cache DB fixture.
#   - Does NOT exercise real Discord delivery (notify-operator SKIPs w/o token) —
#     it asserts the escalation EVENT (operator_paged) is emitted, not that a DM
#     landed.
set -uo pipefail   # NOT -e: assert exit codes / emissions explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GAUGE="$REPO_ROOT/scripts/ops/durability-gauge.sh"
MT_LIB="$REPO_ROOT/scripts/ops/lib/merge-timeline.sh"
HT_LIB="$REPO_ROOT/scripts/ops/lib/human-touch-timeline.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

for f in "$GAUGE" "$MT_LIB" "$HT_LIB"; do
  [[ -f "$f" ]] || { printf 'FATAL: %s not found\n' "$f" >&2; exit 1; }
done

# jq-free field reader over the gauge's JSON via python.
_field() { python3 -c "import json,sys; d=json.load(open('$1'))
for p in '$2'.split('.'):
    try: p=int(p)
    except ValueError: pass
    d=d[p]
print(d)"; }

# run the gauge in --dry-run and capture JSON to a file.
_run() { # NOW MERGES_FIXTURE HUMAN_FIXTURE STALL_HOURS OUTFILE
  CHUMP_DURABILITY_NOW="$1" \
  CHUMP_DURABILITY_MERGES_FIXTURE="$2" \
  CHUMP_DURABILITY_HUMAN_FIXTURE="$3" \
  CHUMP_DURABILITY_STALL_HOURS="$4" \
  CHUMP_DURABILITY_WINDOW_DAYS="30" \
  bash "$GAUGE" --dry-run > "$5" 2>/dev/null
}

# ── 0. libs source and define their contracts ────────────────────────────────
echo "[test-durability-gauge] libs define their functions"
( source "$MT_LIB" && declare -F merge_timeline >/dev/null ) \
  && _ok "merge-timeline.sh defines merge_timeline" || _fail "merge_timeline undefined"
( source "$HT_LIB" && declare -F human_touch_timeline >/dev/null && declare -F last_human_touch >/dev/null ) \
  && _ok "human-touch-timeline.sh defines its functions" || _fail "human-touch fns undefined"

# ── 1. healthy cadence → no stall ────────────────────────────────────────────
echo "[test-durability-gauge] healthy cadence (merge every 20m) → not stalled"
M="$TMP/healthy.txt"; : > "$M"
python3 - "$M" <<'PY'
import sys, datetime as dt
base=dt.datetime(2026,9,9,0,0,tzinfo=dt.timezone.utc)
with open(sys.argv[1],"w") as f:
    for i in range(40):   # 40 merges, 20 min apart
        f.write((base+dt.timedelta(minutes=20*i)).strftime("%Y-%m-%dT%H:%M:%SZ")+"\n")
PY
J="$TMP/healthy.json"
_run "2026-09-09T13:20:00Z" "$M" /dev/null 3.0 "$J"
[[ "$(_field "$J" is_stalled)" == "False" ]] && _ok "is_stalled False on healthy cadence" || _fail "is_stalled not False (got $(_field "$J" is_stalled))"
[[ "$(_field "$J" stats.stall_count)" == "0" ]] && _ok "stall_count 0 on healthy cadence" || _fail "stall_count != 0 (got $(_field "$J" stats.stall_count))"

# ── 2. RECEIPT: tonight's real signature (05:54:20Z -> 20:54:54Z ≈ 15h) ───────
echo "[test-durability-gauge] tonight's stall signature detected (~15h)"
M2="$TMP/tonight.txt"
cat > "$M2" <<'EOF'
2026-09-09T05:00:00Z
2026-09-09T05:30:00Z
2026-09-09T05:54:20Z
2026-09-09T20:54:54Z
EOF
J2="$TMP/tonight.json"
_run "2026-09-09T21:20:00Z" "$M2" /dev/null 3.0 "$J2"
onset="$(_field "$J2" headline.most_recent_stall.onset)"
dur="$(_field "$J2" headline.most_recent_stall.duration_hours)"
[[ "$onset" == "2026-09-09T05:54:20Z" ]] && _ok "most-recent stall onset = 05:54:20Z" || _fail "onset wrong (got $onset)"
# 15.01h — allow the exact computed value
awk "BEGIN{exit !($dur>14.9 && $dur<15.1)}" && _ok "stall duration ≈ 15.0h (got ${dur})" || _fail "duration not ~15h (got $dur)"
[[ "$(_field "$J2" is_stalled)" == "False" ]] && _ok "is_stalled False after recovery (last merge 20:54Z)" || _fail "is_stalled should be False post-recovery"

# ── 3. CURRENTLY stalled (NOW mid-gap = the 13:00Z discovery moment) ──────────
echo "[test-durability-gauge] mid-gap now → is_stalled True + ongoing"
J3="$TMP/midgap.json"
_run "2026-09-09T13:00:00Z" "$M2" /dev/null 3.0 "$J3"
[[ "$(_field "$J3" is_stalled)" == "True" ]] && _ok "is_stalled True mid-gap" || _fail "is_stalled not True mid-gap"
[[ "$(_field "$J3" stalls.-1.ongoing)" == "True" ]] && _ok "trailing stall marked ongoing" || _fail "trailing stall not ongoing"
sil="$(_field "$J3" current_silence_hours)"
awk "BEGIN{exit !($sil>7.0 && $sil<7.2)}" && _ok "current_silence ≈ 7.1h (got ${sil})" || _fail "silence not ~7.1h (got $sil)"

# ── 4. paging path: mid-gap real run pages once, then debounces ───────────────
echo "[test-durability-gauge] live stall pages once (operator_paged) then debounces"
AMB="$TMP/amb.jsonl"; : > "$AMB"           # pre-create so ambient-hardening uses it
OUTJ="$TMP/board.json"; PS="$TMP/lastpaged"
_page_run() {
  CHUMP_DURABILITY_NOW="2026-09-09T13:00:00Z" \
  CHUMP_DURABILITY_MERGES_FIXTURE="$M2" \
  CHUMP_DURABILITY_HUMAN_FIXTURE=/dev/null \
  CHUMP_DURABILITY_STALL_HOURS="3.0" CHUMP_DURABILITY_WINDOW_DAYS="30" \
  CHUMP_DURABILITY_OUT="$OUTJ" CHUMP_AMBIENT_LOG="$AMB" \
  CHUMP_DURABILITY_PAGE_STATE="$PS" \
  bash "$GAUGE" >/dev/null 2>&1
}
_page_run
hb="$(grep -c '"kind":"durability_gauge"' "$AMB" 2>/dev/null || echo 0)"
[[ "$hb" -ge 1 ]] && _ok "emits durability_gauge heartbeat" || _fail "no durability_gauge heartbeat"
paged="$(grep -c '"kind":"operator_paged".*durability_stall' "$AMB" 2>/dev/null || echo 0)"
[[ "$paged" -ge 1 ]] && _ok "pages operator (operator_paged signal=durability_stall)" || _fail "no operator_paged for durability_stall"
_page_run   # second tick, same onset
paged2="$(grep -c '"kind":"operator_paged".*durability_stall' "$AMB" 2>/dev/null || echo 0)"
[[ "$paged2" == "$paged" ]] && _ok "debounces: second tick does not re-page same onset" || _fail "re-paged same onset (was $paged now $paged2)"

# ── 5. human touch inside the gap shortens unattended-before-stall ────────────
echo "[test-durability-gauge] human touch in-gap measured into unattended-before"
H="$TMP/human.txt"; echo "2026-09-09T05:00:00Z" > "$H"   # touch just before onset
J5="$TMP/human.json"
_run "2026-09-09T21:20:00Z" "$M2" "$H" 3.0 "$J5"
ub="$(_field "$J5" headline.most_recent_stall.hours_unattended_before_stall)"
# onset 05:54:20Z - touch 05:00:00Z = ~0.905h (NOT the 15h duration)
awk "BEGIN{exit !($ub>0.8 && $ub<1.0)}" && _ok "unattended-before = onset−touch ≈ 0.9h (got ${ub})" || _fail "unattended-before not ~0.9h (got $ub)"

# ── 6. threshold is configurable (raise to 20h → tonight's 15h no longer a stall)
echo "[test-durability-gauge] threshold configurable"
J6="$TMP/thr.json"
_run "2026-09-09T21:20:00Z" "$M2" /dev/null 20.0 "$J6"
[[ "$(_field "$J6" stats.stall_count)" == "0" ]] && _ok "threshold 20h → 15h gap not counted" || _fail "threshold not honored (stall_count=$(_field "$J6" stats.stall_count))"

# ── summary ──────────────────────────────────────────────────────────────────
echo "[test-durability-gauge] PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
