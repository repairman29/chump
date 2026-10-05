#!/usr/bin/env bash
# scripts/ci/test-board-cycle-escalate.sh — RESILIENT-373.
#
# Proves board-cycle-escalate.sh's deterministic paging gate: a routine (clean)
# board cycle NEVER pages, a genuine SLA breach pages exactly once, and a
# persisting breach is deduped inside the window — using a synthetic ambient
# log and a stubbed notify_operator (no real Discord). This is the measurable
# proof that the 38-pages/24h firehose becomes breach-only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/board-cycle-escalate.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-board-cycle-escalate.sh (RESILIENT-373) ==="

[[ -f "$LIB" ]] || fail "escalate lib missing: $LIB"
bash -n "$LIB" || fail "escalate lib bash -n failed"
pass "lib present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_BOARD_ESCALATE_STATE_DIR="$TMP/state"
export CHUMP_BOARD_ESCALATE_WINDOW_S=7200
: > "$CHUMP_AMBIENT_LOG"

# Stub notify_operator BEFORE sourcing so the lib doesn't pull the real one.
# Mirror notify-operator's contract: emit operator_paged, then no-op delivery.
notify_operator() {
    printf '{"ts":"%s","kind":"operator_paged","signal":"%s","class":"registry-page"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CHUMP_NOTIFY_KIND:-none}" >> "$CHUMP_AMBIENT_LOG"
    return 0
}
export -f notify_operator

# shellcheck source=/dev/null
source "$LIB"

emit_report() {  # json-fields-fragment
    printf '{"ts":"%s","kind":"board_cycle_report_posted",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$CHUMP_AMBIENT_LOG"
}
pages() { grep -c '"kind":"operator_paged"' "$CHUMP_AMBIENT_LOG" 2>/dev/null || true; }

NOW="$(date -u +%s)"

# ── 1. Clean cycle (sla_breaches:0) → 0 pages ────────────────────────────────
emit_report '"sla_breaches":0,"stalls_classified":8'
board_cycle_escalate "$NOW"
[[ "$(pages)" == "0" ]] || fail "clean cycle paged (expected 0, got $(pages))"
grep -q '"board_cycle_page_suppressed_clean"' "$CHUMP_AMBIENT_LOG" \
    || fail "clean cycle did not emit suppression trail"
pass "clean cycle: 0 pages, suppression logged"

# ── 2. Breach cycle → exactly 1 page (kind=board_cycle_alert) ────────────────
NOW2="$(date -u +%s)"
emit_report '"sla_breaches":5,"oldest_breach_age_min":42,"stalls_classified":5,"root_cause":"bot_merge_daemon_not_installed"'
board_cycle_escalate "$NOW2"
[[ "$(pages)" == "1" ]] || fail "breach cycle should page once (got $(pages))"
grep -q '"signal":"board_cycle_alert"' "$CHUMP_AMBIENT_LOG" \
    || fail "breach page missing kind=board_cycle_alert"
pass "breach cycle: exactly 1 page, kind=board_cycle_alert"

# ── 3. Same breach signature within window → deduped (still 1 total) ─────────
NOW3="$(date -u +%s)"
emit_report '"sla_breaches":17,"oldest_breach_age_min":18189,"root_cause":"bot_merge_daemon_not_installed"'
board_cycle_escalate "$NOW3"
[[ "$(pages)" == "1" ]] || fail "persisting breach re-paged (expected still 1, got $(pages))"
grep -q '"board_cycle_page_deduped"' "$CHUMP_AMBIENT_LOG" \
    || fail "dedup trail not emitted for persisting breach"
pass "persisting breach: deduped, no new page"

# ── 4. NEW breach signature (different root_cause) → pages again (total 2) ────
NOW4="$(date -u +%s)"
emit_report '"sla_breaches":3,"root_cause":"ci_runners_blocked"'
board_cycle_escalate "$NOW4"
[[ "$(pages)" == "2" ]] || fail "new breach signature did not page (expected 2, got $(pages))"
pass "new breach signature: pages again"

# ── 5. Simulate the real 24h window: replay the actual posted lines ─────────
# The 21 structured cycles observed 2026-08-22 17:38–22:38. Old behaviour paged
# on ALL of them. New behaviour pages only on distinct breach signatures.
: > "$CHUMP_AMBIENT_LOG"; rm -rf "$CHUMP_BOARD_ESCALATE_STATE_DIR"; mkdir -p "$CHUMP_BOARD_ESCALATE_STATE_DIR"
export CHUMP_BOARD_ESCALATE_WINDOW_S=1800   # 30m window ~ matches 30m SLA cadence
declare -a OBSERVED=(
  '"sla_breaches":4,"stalls_classified":12'
  '"sla_breaches":0,"stalls_classified":12'
  '"sla_breaches":0,"stalls_classified":5'
  '"sla_breaches":17,"stalls_classified":5,"root_cause":"bot_merge_daemon_not_installed"'
  '"sla_breaches":1,"stalls_classified":7'
  '"sla_breaches":17,"stalls_classified":2'
  '"sla_breaches":0,"stalls_classified":15'
  '"sla_breaches":0,"stalls_classified":0'
  '"sla_breaches":0,"stalls_classified":11'
  '"sla_breaches":17,"stalls_classified":2'
  '"sla_breaches":17,"oldest_breach_age_min":18189,"stalls_classified":0'
  '"sla_breaches":0,"stalls_classified":8'
  '"sla_breaches":0,"stalls_classified":8'
  '"sla_breaches":0,"stalls_classified":7'
  '"sla_breaches":0,"stalls_classified":0'
  '"sla_breaches":2,"stalls_classified":2'
  '"sla_breaches":0,"stalls_classified":6'
  '"sla_breaches":5,"stalls_classified":5'
  '"sla_breaches":0,"stalls_classified":4'
  '"sla_breaches":0,"stalls_classified":4,"detail":"CI runners blocked on all auto-merge PRs"'
  '"sla_breaches":0,"stalls_classified":4'
)
for frag in "${OBSERVED[@]}"; do
    : > "$CHUMP_AMBIENT_LOG.one"
    S="$(date -u +%s)"
    printf '{"ts":"%s","kind":"board_cycle_report_posted",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$frag" >> "$CHUMP_AMBIENT_LOG"
    board_cycle_escalate "$S"
done
REPLAY_PAGES="$(pages)"
echo "  replay: 21 real cycles → $REPLAY_PAGES page(s) (old behaviour = 21)"
(( REPLAY_PAGES < 21 )) || fail "replay did not reduce pages"
(( REPLAY_PAGES <= 8 )) || fail "replay paged more than expected breach ceiling ($REPLAY_PAGES)"
pass "replay: firehose 21 → $REPLAY_PAGES (breach-only)"

echo "=== ALL PASS ==="
