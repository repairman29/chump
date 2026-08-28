#!/usr/bin/env bash
# scripts/ci/test-board-vitals.sh — RESILIENT-371 smoke/behaviour test for
# scripts/coord/lib/board-vitals.sh, the resident board's non-merge vital-signs
# watch.
#
# Self-contained + offline: synthetic ambient logs, a temp dedup state dir, and
# DRY_RUN so nothing is DM'd and no LLM is called. Disk paging is exercised by
# forcing the threshold below the node's real usage (a deterministic way to make
# ONE real incident fire), which drives the real _bv_maybe_page dedup path. Runs
# in well under a second, mutates no fleet state.

set -uo pipefail   # NOT -e: we assert exit codes / emissions explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/board-vitals.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

_ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
_emitted()   { if grep -qE "$3" "$2" 2>/dev/null; then _ok "$1"; else _fail "$1 (no /$3/ in $2)"; fi; }
_notemitted(){ if grep -qE "$3" "$2" 2>/dev/null; then _fail "$1 (unexpected /$3/)"; else _ok "$1"; fi; }
_count()     { grep -cE "$2" "$1" 2>/dev/null || echo 0; }

[[ -f "$LIB" ]] || { printf 'FATAL: %s not found\n' "$LIB" >&2; exit 1; }

echo "[test-board-vitals] sourcing contract"
( source "$LIB" && declare -F board_vitals_check >/dev/null ) \
    && _ok "sourcing defines board_vitals_check" \
    || _fail "sourcing defines board_vitals_check"

# ── disk incident: force threshold below real usage, DRY_RUN, dedup ──────────
echo "[test-board-vitals] disk incident pages once then dedupes"
A="$TMP/disk.jsonl"; : > "$A"     # empty ambient → worker_ep=0 → worker checks inert
SD="$TMP/state-disk"
run_disk() {
    ( set -a
      CHUMP_AMBIENT_LOG="$A"; CHUMP_BOARD_VITALS_STATE_DIR="$SD"
      CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
      CHUMP_BOARD_VITALS_DISK_PCT=1          # real usage always exceeds 1%
      CHUMP_BOARD_VITALS_DROUGHT_MIN=999999  # never fire drought in the test
      set +a
      source "$LIB"; board_vitals_check )
}
rc=0; run_disk >/dev/null 2>&1 || rc=$?
_ok "first run exits 0 (rc=$rc)"
_emitted "first run would-page (dryrun) for disk_full" "$A" '"board_vitals_page_dryrun".*"disk_full"'
_emitted "first run emits board_vitals_tick with incidents>=1" "$A" '"board_vitals_tick","incidents":[1-9]'
run_disk >/dev/null 2>&1
dd_count="$(_count "$A" '"board_vitals_page_deduped".*"disk_full"')"
[[ "$dd_count" -ge 1 ]] && _ok "second run dedupes the disk page (anti-firehose)" \
    || _fail "second run did not dedupe (deduped count=$dd_count)"
dryrun_count="$(_count "$A" '"board_vitals_page_dryrun".*"disk_full"')"
[[ "$dryrun_count" -eq 1 ]] && _ok "disk paged exactly once across two runs" \
    || _fail "disk pages != 1 (got $dryrun_count)"

# ── clean cycle never pages ──────────────────────────────────────────────────
echo "[test-board-vitals] clean cycle is phone-quiet"
B="$TMP/clean.jsonl"; : > "$B"
( set -a
  CHUMP_AMBIENT_LOG="$B"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-clean"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100           # unreachable → no disk incident
  CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "clean cycle sends no page" "$B" '"board_vitals_page_(dryrun|sent)"'

# ── proof-of-life: unconditional stdout line (journal-visible, RESILIENT-410) ─
echo "[test-board-vitals] proof-of-life stdout line every run"
pol="$( ( set -a
  CHUMP_AMBIENT_LOG="$TMP/pol.jsonl"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-pol"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) 2>/dev/null )"
echo "$pol" | grep -qE '^\[board-vitals\] tick — incidents=0 ' \
    && _ok "healthy run prints proof-of-life tick to stdout (incidents=0)" \
    || _fail "no proof-of-life stdout line (got: $pol)"
_emitted "clean cycle still emits a tick heartbeat" "$B" '"board_vitals_tick","incidents":0'

# ── RESILIENT-411: worker-silence ALONE must NOT page (no transient-lull page) ─
echo "[test-board-vitals] worker silence alone never pages"
S="$TMP/silence.jsonl"
# a stale worker signal (2h old) → worker_silent=1, but no merge stall / disk
printf '{"ts":"%s","kind":"token_usage_partial"}\n' \
    "$(date -u -d '-120 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-120M +%Y-%m-%dT%H:%M:%SZ)" > "$S"
( set -a
  CHUMP_AMBIENT_LOG="$S"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-sil"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100
  CHUMP_BOARD_VITALS_DROUGHT_MIN=999999   # merge-stall can't fire → isolates silence
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_notemitted "silent worker + no stall/disk → NO page (recovering lull is not Jeff's problem)" \
    "$S" '"board_vitals_page_(dryrun|sent)"'
grep -qE '"board_vitals_tick","incidents":0' "$S" \
    && _ok "silence-alone still ticks incidents=0 (watched, not paged)" \
    || _fail "silence-alone tick missing/incidents!=0"

# ── RESILIENT-411: oauth GENUINELY expired pages; a recovery does not ────────
echo "[test-board-vitals] floor — oauth expired pages, recovery does not"
OA="$TMP/oauth.jsonl"
nowts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
{ printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(nowts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(nowts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(nowts)"; } > "$OA"
( set -a
  CHUMP_AMBIENT_LOG="$OA"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-oa"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "3 oauth failures (newest=failure) → pages oauth_expired" "$OA" '"board_vitals_page_dryrun".*"oauth_expired"'
# a success lands AFTER the failures → recovered → must NOT page. Build a FRESH
# log (not a copy of the paged one) so we measure only this run's pages.
OA2LOG="$TMP/oauth2.jsonl"
oldts() { date -u -d '-2 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2M +%Y-%m-%dT%H:%M:%SZ; }
{ printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(oldts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(oldts)"
  printf '{"ts":"%s","kind":"oauth_token_refresh_failed"}\n' "$(oldts)"
  printf '{"ts":"%s","kind":"oauth_token_refreshed"}\n'      "$(nowts)"; } > "$OA2LOG"
( set -a
  CHUMP_AMBIENT_LOG="$OA2LOG"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-oa2"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
# grep -c prints "0" on no match; do NOT append `|| echo 0` (that doubles it).
oa2_pages="$(grep -c '"board_vitals_page_dryrun".*"oauth_expired"' "$OA2LOG" 2>/dev/null)"
[[ "${oa2_pages:-0}" -eq 0 ]] && _ok "oauth recovered (success after failures) → NO page" \
    || _fail "oauth recovery still paged ($oa2_pages)"

# ── RESILIENT-411: cost/credit cap pages ─────────────────────────────────────
echo "[test-board-vitals] floor — cost_cap_exceeded pages"
CC="$TMP/cost.jsonl"
printf '{"ts":"%s","kind":"cost_cap_exceeded","daily_usd":9.9}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CC"
( set -a
  CHUMP_AMBIENT_LOG="$CC"; CHUMP_BOARD_VITALS_STATE_DIR="$TMP/state-cc"
  CHUMP_BOARD_VITALS_DRY_RUN=1; CHUMP_BOARD_VITALS_ESCALATE=0
  CHUMP_BOARD_VITALS_DISK_PCT=100; CHUMP_BOARD_VITALS_DROUGHT_MIN=999999
  set +a
  source "$LIB"; board_vitals_check ) >/dev/null 2>&1
_emitted "cost_cap_exceeded in-window → pages cost_cap" "$CC" '"board_vitals_page_dryrun".*"cost_cap"'

# ── helper: main-red span (consecutive real-red run) ─────────────────────────
echo "[test-board-vitals] _bv_main_red_span_min"
MR="$TMP/mainred.jsonl"
{
  echo '{"ts":"2026-08-27T10:00:00Z","kind":"main_red_detected","status":"red"}'
  echo '{"ts":"2026-08-27T10:40:00Z","kind":"main_red_detected","status":"red"}'
} > "$MR"
span="$( CHUMP_AMBIENT_LOG="$MR" bash -c 'source "'"$LIB"'"; _bv_main_red_span_min' 2>/dev/null )"
[[ "$span" == "40" ]] && _ok "two 40m-apart red lines → span 40" || _fail "main-red span wrong (got '$span', want 40)"
echo '{"ts":"2026-08-27T10:50:00Z","kind":"main_red_detected","status":"no_runs"}' >> "$MR"
span2="$( CHUMP_AMBIENT_LOG="$MR" bash -c 'source "'"$LIB"'"; _bv_main_red_span_min' 2>/dev/null )"
[[ "$span2" == "0" ]] && _ok "benign newest line → span 0 (not paged)" || _fail "benign newest not 0 (got '$span2')"

# ── helper: prs-in-flight from newest board_cycle_report_posted ──────────────
echo "[test-board-vitals] _bv_prs_in_flight"
PF="$TMP/prs.jsonl"
echo '{"ts":"2026-08-27T11:00:00Z","kind":"board_cycle_report_posted","sla_breaches":2,"stalls_classified":3}' > "$PF"
inflight="$( CHUMP_AMBIENT_LOG="$PF" bash -c 'source "'"$LIB"'"; _bv_prs_in_flight' 2>/dev/null )"
[[ "$inflight" == "5" ]] && _ok "sla_breaches(2)+stalls(3) → in_flight 5" || _fail "in_flight wrong (got '$inflight', want 5)"
empty_pf="$TMP/empty.jsonl"; : > "$empty_pf"
inflight2="$( CHUMP_AMBIENT_LOG="$empty_pf" bash -c 'source "'"$LIB"'"; _bv_prs_in_flight' 2>/dev/null )"
[[ "$inflight2" == "-1" ]] && _ok "no report → in_flight -1 (unknown, not zero)" || _fail "no-report in_flight not -1 (got '$inflight2')"

echo
echo "[test-board-vitals] PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
