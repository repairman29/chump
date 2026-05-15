#!/usr/bin/env bash
# opus-curator.sh — INFRA-848: proactive health audit + curator decision logging
#                   INFRA-847: fleet-state.json mutual exclusion via flock(1)
# Runs every 10-15 min; audits gaps, pillars, waste, PRs; makes curator decisions.
# This is the primary decision-maker for non-emergency fleet health.
#
# INFRA-848: each decision emits kind=curator_decision to ambient.jsonl with:
#   decision_type: p0_demotion | gap_ac_filled | gap_filed | pr_unstick |
#                  waste_investigation | balance_restock
#   reasoning: human-readable explanation of why this decision was made
#   action_taken: what was actually done (vs. just identified)
#
# INFRA-847: all fleet-state.json reads/writes go through emergency-fast-path.sh
#   which wraps them in flock(1).
# Env:
#   CHUMP_FLEET_STATE_MUTEX=0       bypass locking (debug only; passed through)
#   CHUMP_FLEET_STATE_LOCK_TIMEOUT_S lock wait timeout in seconds (default 5)
#   CHUMP_CURATOR_DRY_RUN=1        skip fleet-state write (read-only audit)

set -euo pipefail

FLEET_STATE="${CHUMP_FLEET_STATE:-.chump-locks/fleet-state.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
# Resolve REPO_ROOT from this script's location to avoid INFRA-779
# (git rev-parse --show-toplevel returns wrong path in linked worktrees on macOS).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"
_FAST_PATH="$REPO_ROOT/scripts/coord/emergency-fast-path.sh"

# INFRA-1068: batch write library (queue+flush).
_WRITER_LIB="$REPO_ROOT/scripts/coord/lib/fleet-state-writer.sh"
if [[ -r "$_WRITER_LIB" ]]; then
  # shellcheck source=./lib/fleet-state-writer.sh
  # shellcheck disable=SC1091
  source "$_WRITER_LIB"
fi

# INFRA-841: frequency-aware scheduling — emit kind=system_gap_tick on each run.
_TICK_HELPER="$REPO_ROOT/scripts/coord/system-gap-tick.sh"
if [[ -r "$_TICK_HELPER" ]]; then
  # shellcheck source=./system-gap-tick.sh
  source "$_TICK_HELPER"
fi

# Initialize fleet state (via emergency-fast-path.sh if available, else direct)
init_fleet_state() {
  if [[ -x "$_FAST_PATH" ]]; then
    # emergency-fast-path.sh handles missing file + flock
    return 0
  fi
  if [[ ! -f "$FLEET_STATE" ]]; then
    mkdir -p "$(dirname "$FLEET_STATE")" 2>/dev/null || true
    cat > "$FLEET_STATE" <<'EOF'
{
  "fleet_size": 2,
  "wedged": false,
  "wedge_start": null,
  "wedge_escalated": false,
  "last_curator_run": null,
  "last_emergency_invoke": null,
  "last_fast_path_run": null
}
EOF
  fi
}

# INFRA-847: fleet_state_set_field — update a top-level field via flock accessor.
# INFRA-1068: when CHUMP_FLEET_STATE_BATCH_WRITES=1 (default), enqueues the
# write via fleet_state_queue_write instead of grabbing the flock immediately.
# The caller is responsible for calling fleet_state_flush at the end of the
# logical unit (e.g. main loop iteration). Set CHUMP_FLEET_STATE_BATCH_WRITES=0
# to restore the original immediate-write behavior.
# Uses emergency-fast-path.sh when available; falls back to direct write (no flock).
fleet_state_set_field() {
  local key="$1" val="$2"
  local _batch="${CHUMP_FLEET_STATE_BATCH_WRITES:-1}"
  if [[ "$_batch" == "1" ]] && declare -F fleet_state_queue_write >/dev/null 2>&1; then
    fleet_state_queue_write "$key" "$val"
    return 0
  fi
  # Immediate write (batch disabled or library not loaded).
  if [[ -x "$_FAST_PATH" ]]; then
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    REPO_ROOT="$REPO_ROOT" \
    bash "$_FAST_PATH" set-field "$key" "$val" 2>/dev/null || true
  else
    # Fallback: direct jq update (no flock — emergency-fast-path.sh missing)
    if command -v jq &>/dev/null && [[ -f "$FLEET_STATE" ]]; then
      jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$FLEET_STATE" \
        > "${FLEET_STATE}.tmp" 2>/dev/null && \
        mv "${FLEET_STATE}.tmp" "$FLEET_STATE" 2>/dev/null || true
    fi
  fi
}

# log_ambient KIND DATA — emit a structured ambient event.
log_ambient() {
  local kind="$1"
  local data="$2"
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$data" \
    >> "$AMBIENT" 2>/dev/null || true
}

# INFRA-848: log_curator_decision — structured curator decision event.
# Fields:
#   decision_type: one of p0_demotion | gap_ac_filled | gap_filed | pr_unstick |
#                          waste_investigation | balance_restock
#   reasoning: why this decision was made (human-readable)
#   action_taken: what was done (or "identified_only" if just flagged)
log_curator_decision() {
  local decision_type="$1"
  local reasoning="$2"
  local action_taken="${3:-identified_only}"
  log_ambient "curator_decision" \
    '"decision_type":"'"$decision_type"'","reasoning":"'"$reasoning"'","action_taken":"'"$action_taken"'"'
}

# ============================================================================
# INFRA-979: helpers for filing curator tracking gaps with daily dedup.
# Each decision that DETECTS an issue (pr_unstick, balance_restock,
# waste_investigation) files ONE INFRA gap per day, then records the
# new gap ID in action_taken. The dedup file at
# .chump-locks/curator-filed-<decision>-YYYY-MM-DD.json prevents
# flooding when the same condition persists across multiple 10-min
# audit ticks.
# ============================================================================

_curator_lock_dir() {
  printf '%s' "${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}"
}

# Returns 0 if today's dedup file exists for this decision_type, 1 otherwise.
_curator_already_filed_today() {
  local decision_type="$1"
  local today; today="$(date -u +%Y-%m-%d)"
  local marker; marker="$(_curator_lock_dir)/curator-filed-${decision_type}-${today}.json"
  [[ -f "$marker" ]]
}

_curator_mark_filed_today() {
  local decision_type="$1" gap_id="$2"
  local today; today="$(date -u +%Y-%m-%d)"
  local marker; marker="$(_curator_lock_dir)/curator-filed-${decision_type}-${today}.json"
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  printf '{"decision":"%s","gap_id":"%s","ts":"%s"}\n' \
    "$decision_type" "$gap_id" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
}

# Reserve a new gap via chump CLI. Returns the gap ID on stdout, or
# empty string on failure. Sets AC + caller-provided body via stdin.
_curator_file_gap() {
  local title="$1" effort="${2:-s}"
  local out gap_id
  out="$(chump gap reserve --domain INFRA --title "$title" --priority P1 --effort "$effort" 2>&1)"
  gap_id="$(printf '%s' "$out" | grep -oE 'INFRA-[0-9]+' | head -1)"
  printf '%s' "$gap_id"
}

# ============================================================================
# AUDIT PHASE: Gather health metrics
# ============================================================================
audit_slo() {
  # Run: chump health --slo-check
  # INFRA-955 (META-055 #3, 7.7%): emit kind=slo_breach only on the EDGE
  # (transition from healthy → breach), not on every audit tick while in
  # continuous breach. Carries which SLO breached + parsed value + threshold,
  # rather than just severity. Also emits kind=slo_recovered on the
  # opposite edge so consumers can pair the two.
  command -v chump &>/dev/null || return 0

  local slo_output rc
  slo_output="$(chump health --slo-check 2>&1)"
  rc=$?

  # Parse breach lines: "  ✗ BREACH  L2-SLO-4  [4 under target]  pillar balance …"
  # Build a sorted, comma-joined name list as the change-detection key.
  local breached_names breached_detail
  breached_names="$(echo "$slo_output" \
    | awk '/^[[:space:]]*✗[[:space:]]+BREACH/ {
        for (i=1;i<=NF;i++) if ($i ~ /^L[0-9]+-SLO-[0-9]+$/) print $i
      }' | sort -u | paste -sd, -)"
  breached_detail="$(echo "$slo_output" \
    | awk '/^[[:space:]]*✗[[:space:]]+BREACH/ {
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        printf "%s\\n", $0
      }')"

  # Previous active set tracked in fleet-state.json.
  local prev_active=""
  if command -v jq &>/dev/null && [[ -f "$FLEET_STATE" ]]; then
    prev_active="$(jq -r '.slo_breach_active // ""' "$FLEET_STATE" 2>/dev/null || echo "")"
  fi

  if [[ -z "$breached_names" ]]; then
    echo "SLO: healthy"
    # Recovery edge: previously breaching, now clean.
    if [[ -n "$prev_active" ]]; then
      log_ambient "slo_recovered" \
        '"previously_breached":"'"$prev_active"'","handler":"opus-curator"'
      fleet_state_set_field "slo_breach_active" ""
    fi
    return 0
  fi

  echo "SLO: BREACH ($breached_names)"
  # Edge: emit slo_breach only if the active set CHANGED. Suppress identical
  # continuous-breach re-emissions, which were the dominant token drain
  # for this kind per META-055 audit.
  if [[ "$breached_names" != "$prev_active" ]]; then
    log_ambient "slo_breach" \
      '"severity":"high","slo_name":"'"$breached_names"'","detail":"'"$breached_detail"'","threshold":"see-detail"'
    fleet_state_set_field "slo_breach_active" "$breached_names"
  fi
  return 1
}

# INFRA-963: coerce an arbitrarily-shaped value to a single non-negative
# integer. jq output can be "1\n0" when `... // 0` partially succeeds before
# a parse error triggers `|| echo 0`. The multi-line value then breaks
# `[[ $X -gt N ]]` with "syntax error in expression". head -1 + tr fix that.
_to_int() {
  # shellcheck disable=SC2155
  local v="$(printf '%s' "${1:-0}" | head -1 | tr -dc '0-9')"
  printf '%s' "${v:-0}"
}

audit_waste() {
  # Run: chump waste-tally --window 2h
  if command -v chump &> /dev/null; then
    WASTE_RATE=$(chump waste-tally --window 2h 2>/dev/null | jq -r '.waste_rate // 0' 2>/dev/null | head -1)
    WASTE_RATE="${WASTE_RATE:-0}"
    echo "Waste rate: ${WASTE_RATE}%"

    if (( $(echo "$WASTE_RATE > 20" | bc -l 2>/dev/null || echo 0) )); then
      echo "  WARNING: waste rate > 20%"
      log_ambient "waste_rate_high" '"rate":'"$WASTE_RATE"',"threshold":20'
      return 1
    fi
  fi
  return 0
}

audit_gaps() {
  # Run: chump gap audit-priorities --json
  if command -v chump &> /dev/null; then
    AUDIT=$(chump gap audit-priorities --json 2>/dev/null || echo '{}')

    # INFRA-963: chump gap audit-priorities --json can emit trailing
    # non-JSON text (warning lines). jq parses the first object then
    # errors; `|| echo 0` then appends "0" to the partial output. The
    # resulting multi-line value breaks integer comparisons. _to_int
    # coerces to the first numeric line.
    P0_COUNT=$(_to_int "$(echo "$AUDIT" | jq '.p0_count // 0' 2>/dev/null)")
    VAGUE_COUNT=$(_to_int "$(echo "$AUDIT" | jq '.vague_pickable // 0' 2>/dev/null)")

    echo "P0 gaps: $P0_COUNT"
    echo "Vague pickable: $VAGUE_COUNT"

    if [[ "$P0_COUNT" -gt 5 ]]; then
      echo "  WARNING: P0 count > 5 (inflation)"
      log_ambient "p0_inflation" '"count":'"$P0_COUNT"',"threshold":5'
    fi

    if [[ "$VAGUE_COUNT" -gt 0 ]]; then
      echo "  WARNING: $VAGUE_COUNT vague pickable gaps (need AC)"
      log_ambient "vague_gaps_found" '"count":'"$VAGUE_COUNT"
    fi

    echo "$AUDIT"
  fi
}

audit_pr_stuck() {
  # Scan open PRs for stalls (>2h, failing checks)
  if command -v gh &> /dev/null; then
    STUCK_COUNT=$(gh pr list --state open --json number,updatedAt,statusCheckRollup \
      --jq '.[] | select(
        (now - (.updatedAt | fromdateiso8601)) > 7200 and
        (.statusCheckRollup != "SUCCESS" or .statusCheckRollup == null)
      ) | .number' 2>/dev/null | wc -l | tr -d ' ' || echo 0)

    if [[ "${STUCK_COUNT:-0}" -gt 0 ]]; then
      echo "  WARNING: $STUCK_COUNT PR(s) stuck (>2h, failing checks)"
      log_ambient "pr_stuck_cluster" '"count":'$STUCK_COUNT',"threshold":1'
      return 1
    fi
  fi
  return 0
}

audit_pillar_balance() {
  # Count pickable gaps per pillar (xs + s + m size, no deps)
  # Alert if any pillar < 2 pickable
  if command -v chump &> /dev/null; then
    AUDIT=$(chump gap list --status open --json 2>/dev/null || echo '[]')

    EFFECTIVE=$(_to_int "$(echo "$AUDIT" | jq '[.[] | select(.pillar == "EFFECTIVE" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null)")
    CREDIBLE=$(_to_int "$(echo "$AUDIT" | jq '[.[] | select(.pillar == "CREDIBLE" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null)")
    RESILIENT=$(_to_int "$(echo "$AUDIT" | jq '[.[] | select(.pillar == "RESILIENT" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null)")
    ZERO_WASTE=$(_to_int "$(echo "$AUDIT" | jq '[.[] | select(.pillar == "ZERO-WASTE" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null)")

    echo "Pickable by pillar: EFFECTIVE=$EFFECTIVE CREDIBLE=$CREDIBLE RESILIENT=$RESILIENT ZERO-WASTE=$ZERO_WASTE"

    if [[ "${EFFECTIVE:-0}" -lt 2 ]] || [[ "${CREDIBLE:-0}" -lt 2 ]] || [[ "${RESILIENT:-0}" -lt 2 ]] || [[ "${ZERO_WASTE:-0}" -lt 2 ]]; then
      echo "  WARNING: some pillar has < 2 pickable gaps"
      log_ambient "pillar_imbalance" '{"effective":'${EFFECTIVE:-0}',"credible":'${CREDIBLE:-0}',"resilient":'${RESILIENT:-0}',"zero_waste":'${ZERO_WASTE:-0}'}'
      return 1
    fi
  fi
  return 0
}

# ============================================================================
# CURATOR DECISION PHASE — INFRA-848: structured decision logging
# ============================================================================
curator_decisions() {
  echo ""
  echo "=== CURATOR DECISIONS ==="

  # Decision 1: Handle P0 inflation. INFRA-978 makes this REAL: when
  # P0_COUNT > 5, find the oldest open P0 by created_at and demote it
  # to P1 via `chump gap set --priority P1`. Single-shot per curator
  # run (max 1 demotion per 10 min). Reversible: P0→P1, not deleted.
  # CHUMP_CURATOR_DRY_RUN=1 suppresses the mutation.
  if command -v chump &> /dev/null; then
    _p0=$(_to_int "$(chump gap audit-priorities --json 2>/dev/null | jq '.p0_count // 0' 2>/dev/null)")
    if [[ "${_p0:-0}" -gt 5 ]]; then
      # Pick the oldest open P0 by created_at (deterministic, mechanical).
      _oldest=$(chump gap list --status open --json 2>/dev/null | python3 -c "
import json, sys
try:
    gaps = json.load(sys.stdin)
    p0s = [g for g in gaps if g.get('priority') == 'P0']
    p0s.sort(key=lambda g: g.get('created_at') or 0)
    if p0s:
        oldest = p0s[0]
        # age in days from created_at unix timestamp
        import time
        age_days = (int(time.time()) - int(oldest.get('created_at') or 0)) // 86400
        print(f\"{oldest['id']}|{age_days}\")
except Exception:
    pass
")
      _gap_id="${_oldest%|*}"
      _age_days="${_oldest#*|}"

      if [[ -n "$_gap_id" && "$_gap_id" != "$_oldest" ]]; then
        if [[ "${_DRY_RUN:-0}" == "1" ]]; then
          echo "Decision 1: P0 inflation ($_p0 > 5) — [dry-run] would demote $_gap_id (age=${_age_days}d)"
          log_curator_decision \
            "p0_demotion" \
            "P0 count is $_p0 (> budget of 5); dry-run skipped mutation" \
            "dry_run: would demote $_gap_id (age=${_age_days}d, P0→P1)"
        else
          if chump gap set "$_gap_id" --priority P1 >/dev/null 2>&1; then
            echo "Decision 1: P0 inflation ($_p0 > 5) — demoted $_gap_id (age=${_age_days}d) to P1"
            log_curator_decision \
              "p0_demotion" \
              "P0 count was $_p0 (> budget of 5); demoted oldest open P0" \
              "demoted $_gap_id (P0→P1, age=${_age_days}d)"
          else
            echo "Decision 1: demotion of $_gap_id FAILED — chump gap set exited non-zero" >&2
            log_curator_decision \
              "p0_demotion" \
              "P0 count is $_p0 (> budget of 5); attempted demotion failed" \
              "error: chump gap set $_gap_id --priority P1 failed"
          fi
        fi
      else
        echo "Decision 1: P0 inflation ($_p0 > 5) but could not identify oldest P0 — skipped"
        log_curator_decision \
          "p0_demotion" \
          "P0 count is $_p0 but JSON parse / sort failed" \
          "identified_only: could not pick demotion target"
      fi
    else
      echo "Decision 1: P0 count ${_p0:-0} ≤ 5 — within budget, no demotion needed"
    fi
  fi

  # Decision 2 (INFRA-983): gap_ac_filled — when audit_gaps shows
  # vague_pickable > 0, find the oldest vague pickable gap and use
  # `claude -p` to draft a concrete AC, then apply it via
  # `chump gap set --acceptance-criteria`. The highest-leverage
  # curator action because vague gaps block fleet pickup.
  #
  # Safety rails:
  #   - Daily cap of 3 AC fills (sentinel file in .chump-locks/).
  #   - CHUMP_CURATOR_AC_FILL_DISABLE=1 escape hatch.
  #   - CHUMP_CURATOR_DRY_RUN=1 suppresses the LLM call.
  #   - LLM errors fall back to identified_only with error: prefix.
  #   - Generated AC must contain `|` separators and be >100 chars.
  if command -v chump &>/dev/null; then
    _vague=$(_to_int "$(chump gap audit-priorities --json 2>/dev/null | jq '.vague_pickable // 0' 2>/dev/null)")
    _today="$(date -u +%Y-%m-%d)"
    _marker="$(_curator_lock_dir)/curator-filled-gap_ac-${_today}.json"
    _filled_count=0
    if [[ -f "$_marker" ]]; then
      _filled_count=$(python3 -c "
import json
try: print(json.load(open('$_marker')).get('count', 0))
except Exception: print(0)
" 2>/dev/null || echo 0)
    fi

    if [[ "$_vague" -le 0 ]]; then
      echo "Decision 2: 0 vague pickable — no AC fill needed"
    elif [[ "${CHUMP_CURATOR_AC_FILL_DISABLE:-0}" == "1" ]]; then
      echo "Decision 2: $_vague vague pickable, but AC fill DISABLED"
      log_curator_decision "gap_ac_filled" \
        "$_vague vague pickable gaps" \
        "disabled: CHUMP_CURATOR_AC_FILL_DISABLE=1"
    elif [[ "$_filled_count" -ge 3 ]]; then
      echo "Decision 2: $_vague vague pickable, but daily cap (3) reached"
      log_curator_decision "gap_ac_filled" \
        "$_vague vague but already filled $_filled_count today" \
        "skipped: daily cap of 3 fills reached"
    elif [[ "${_DRY_RUN:-0}" == "1" ]]; then
      echo "Decision 2: $_vague vague pickable — [dry-run] would draft AC"
      log_curator_decision "gap_ac_filled" \
        "$_vague vague pickable; $_filled_count/3 filled today" \
        "dry_run: would draft AC for oldest vague pickable"
    else
      # Find oldest vague pickable gap (P0/P1, xs/s/m, no deps, blank or TODO AC).
      _target_id=$(chump gap list --status open --json 2>/dev/null | python3 -c "
import json, sys
try:
    gaps = json.load(sys.stdin)
    candidates = []
    for g in gaps:
        if g.get('priority') not in ('P0','P1'): continue
        if g.get('effort') not in ('xs','s','m'): continue
        if g.get('depends_on'): continue
        ac = str(g.get('acceptance_criteria') or '').strip()
        if not ac or any(p in ac for p in ('TODO','TBD','<fill in>','<placeholder>')):
            candidates.append(g)
    candidates.sort(key=lambda g: g.get('created_at') or 0)
    if candidates:
        print(candidates[0]['id'])
except Exception:
    pass
" 2>/dev/null)

      if [[ -z "$_target_id" ]]; then
        echo "Decision 2: vague count > 0 but no candidate matched (P0/P1, xs/s/m, no deps)"
        log_curator_decision "gap_ac_filled" \
          "$_vague vague but no fillable candidate" \
          "skipped: no P0/P1 xs/s/m vague gap without deps"
      else
        _target_title=$(chump gap show "$_target_id" 2>/dev/null | awk '/^[[:space:]]+title:/ {sub(/^[[:space:]]+title:[[:space:]]*/, ""); print; exit}')
        _target_desc=$(chump gap show "$_target_id" 2>/dev/null | awk '/^[[:space:]]+description:/ {sub(/^[[:space:]]+description:[[:space:]]*/, ""); print; exit}')
        _prompt=$(printf '%s' "You are drafting concrete acceptance criteria for a software-engineering gap.

Title: ${_target_title}
Description: ${_target_desc:-(none provided)}

Output exactly 3-5 acceptance criteria separated by | (pipe character).
Each criterion must be ONE concrete deliverable:
 - reference a specific file path OR function name OR command
 - be verifiable pass/fail (someone can check it)
 - use action verbs (add, modify, assert, test, emit, document)

Output ONLY the pipe-separated criteria. No 'Acceptance Criteria:' header,
no bullets, no quotes, no preamble. ≤ 600 characters total.")

        _ac=$(printf '%s\n' "$_prompt" | claude -p --bare 2>/dev/null | head -c 1500 | tr -d '\n' | tr -s ' ')

        if [[ -n "$_ac" && "${#_ac}" -gt 100 && "$_ac" == *"|"* ]]; then
          if chump gap set "$_target_id" --acceptance-criteria "$_ac" >/dev/null 2>&1; then
            _new_count=$((_filled_count + 1))
            printf '{"date":"%s","count":%d,"last_gap":"%s","ts":"%s"}\n' \
              "$_today" "$_new_count" "$_target_id" \
              "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_marker"
            echo "Decision 2: filled AC for $_target_id ($_new_count/3 today)"
            log_curator_decision "gap_ac_filled" \
              "$_vague vague pickable; drafted AC for oldest ($_target_id)" \
              "filled $_target_id (count $_new_count/3 today)"
          else
            log_curator_decision "gap_ac_filled" \
              "$_vague vague pickable" \
              "error: chump gap set failed for $_target_id"
          fi
        else
          log_curator_decision "gap_ac_filled" \
            "$_vague vague pickable; LLM call did not produce usable AC" \
            "error: LLM returned empty/short/malformed AC for $_target_id"
        fi
      fi
    fi
  fi

  # Decision 3 (INFRA-979): Pillar rebalancing — file ONE tracking gap when
  # any pillar has < 2 pickable xs/s/m gaps. Dedup: max 1 per day per pillar.
  # Decision 3b (INFRA-943): Auto-decompose — when a pillar has 0 pickable
  # xs/s/m gaps AND an l/xl gap with no depends_on exists, call
  # 'chump gap decompose <smallest> --apply' to generate sub-gaps instead of
  # only filing a new tracking gap. Guard: at most 1 decompose per curator run.
  if command -v chump &>/dev/null; then
    _pillars_data="$(chump gap list --status open --json 2>/dev/null || echo '[]')"
    _decompose_used=0  # INFRA-943: guard — at most 1 auto-decompose per run
    for _pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
      _count=$(_to_int "$(echo "$_pillars_data" | jq --arg p "$_pillar" \
        '[.[] | select(.pillar == $p and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null)")
      if [[ "$_count" -lt 2 ]]; then
        # Decision 3b (INFRA-943): if fully empty AND l/xl candidate available,
        # decompose instead of just filing a tracking gap.
        if [[ "$_count" -eq 0 ]] && [[ "$_decompose_used" -eq 0 ]]; then
          _xl_candidate="$(echo "$_pillars_data" | jq -r --arg p "$_pillar" \
            '[.[] | select(.pillar == $p and (.size | IN("l","xl")) and (.depends_on | length) == 0)] | sort_by(.id) | .[0].id // empty' 2>/dev/null)"
          if [[ -n "$_xl_candidate" ]]; then
            if [[ "${_DRY_RUN:-0}" == "1" ]]; then
              echo "Decision 3b: ${_pillar} empty, candidate=${_xl_candidate} — [dry-run] would decompose"
              log_curator_decision \
                "auto_decompose" \
                "${_pillar} has 0 pickable xs/s/m; l/xl candidate=${_xl_candidate}" \
                "dry_run: would call chump gap decompose ${_xl_candidate} --apply"
            else
              local _decomp_out _decomp_rc
              _decomp_out="$(chump gap decompose "$_xl_candidate" --apply 2>&1)"
              _decomp_rc=$?
              if [[ $_decomp_rc -eq 0 ]]; then
                _decompose_used=1
                log_ambient "curator_auto_decompose" \
                  '"pillar":"'"$_pillar"'","gap_id":"'"$_xl_candidate"'","sub_gaps_filed":"'"$(printf '%s' "$_decomp_out" | grep -oE 'INFRA-[0-9]+' | tr '\n' ',' | sed 's/,$//')"'"'
                log_curator_decision \
                  "auto_decompose" \
                  "${_pillar} has 0 pickable xs/s/m; decomposed ${_xl_candidate}" \
                  "decomposed ${_xl_candidate} → sub-gaps filed"
                echo "Decision 3b: ${_pillar} empty → decomposed ${_xl_candidate}"
              else
                log_curator_decision \
                  "auto_decompose" \
                  "${_pillar} has 0 pickable xs/s/m; decompose ${_xl_candidate} failed" \
                  "error: chump gap decompose exited ${_decomp_rc}"
              fi
            fi
          fi
        fi

        if _curator_already_filed_today "balance_restock_${_pillar}"; then
          echo "Decision 3: ${_pillar} pillar starved ($_count < 2) — already filed today, skipping"
          continue
        fi
        if [[ "${_DRY_RUN:-0}" == "1" ]]; then
          echo "Decision 3: ${_pillar} pillar starved ($_count < 2) — [dry-run] would file gap"
          log_curator_decision \
            "balance_restock" \
            "${_pillar} pillar has $_count pickable; target ≥2" \
            "dry_run: would file balance gap for ${_pillar}"
        else
          _today="$(date -u +%Y-%m-%d)"
          _gap_id="$(_curator_file_gap "MISSION-${_pillar}: pillar starved — only $_count pickable xs/s/m gaps as of ${_today}" "s")"
          if [[ -n "$_gap_id" ]]; then
            _curator_mark_filed_today "balance_restock_${_pillar}" "$_gap_id"
            echo "Decision 3: ${_pillar} starved → filed $_gap_id"
            log_curator_decision \
              "balance_restock" \
              "${_pillar} pillar has $_count pickable; below target of 2" \
              "filed $_gap_id (${_pillar}=$_count pickable, target ≥2)"
          else
            log_curator_decision "balance_restock" \
              "${_pillar} starved at $_count" "error: chump gap reserve failed"
          fi
        fi
      fi
    done
  fi

  # Decision 4 (INFRA-979): Stuck-PR scan — file ONE tracking gap when ≥1
  # PR has been open >2h with failing checks. Dedup: max 1 per day.
  if command -v gh &>/dev/null; then
    _stuck_count=$(_to_int "$(gh pr list --state open --json number,updatedAt,statusCheckRollup \
      --jq '[.[] | select(
        (now - (.updatedAt | fromdateiso8601)) > 7200 and
        (.statusCheckRollup != "SUCCESS" or .statusCheckRollup == null)
      )] | length' 2>/dev/null)")
    if [[ "$_stuck_count" -gt 0 ]]; then
      if _curator_already_filed_today "pr_unstick"; then
        echo "Decision 4: $_stuck_count stuck PR(s) — already filed today, skipping"
      elif [[ "${_DRY_RUN:-0}" == "1" ]]; then
        echo "Decision 4: $_stuck_count stuck PR(s) — [dry-run] would file gap"
        log_curator_decision "pr_unstick" \
          "$_stuck_count PR(s) open >2h with failing checks" \
          "dry_run: would file pr_stuck_cluster gap"
      else
        _today="$(date -u +%Y-%m-%d)"
        _gap_id="$(_curator_file_gap "RESILIENT: pr-stuck-cluster — ${_stuck_count} PRs blocked >2h as of ${_today}" "s")"
        if [[ -n "$_gap_id" ]]; then
          _curator_mark_filed_today "pr_unstick" "$_gap_id"
          echo "Decision 4: $_stuck_count stuck PR(s) → filed $_gap_id"
          log_curator_decision "pr_unstick" \
            "$_stuck_count PR(s) open >2h with failing checks block fleet throughput" \
            "filed $_gap_id ($_stuck_count stuck PRs)"
        else
          log_curator_decision "pr_unstick" \
            "$_stuck_count stuck PRs" "error: chump gap reserve failed"
        fi
      fi
    else
      echo "Decision 4: 0 stuck PRs — no action needed"
    fi
  fi

  # Decision 5 (INFRA-979): Waste rate spike — file ONE tracking gap when
  # rate > 20%. Dedup: max 1 per day.
  if command -v chump &>/dev/null; then
    _waste_rate=$(chump waste-tally --window 2h 2>/dev/null | jq -r '.waste_rate // 0' 2>/dev/null | head -1)
    _waste_rate="${_waste_rate:-0}"
    if (( $(echo "$_waste_rate > 20" | bc -l 2>/dev/null || echo 0) )); then
      if _curator_already_filed_today "waste_investigation"; then
        echo "Decision 5: waste rate ${_waste_rate}% — already filed today, skipping"
      elif [[ "${_DRY_RUN:-0}" == "1" ]]; then
        echo "Decision 5: waste rate ${_waste_rate}% — [dry-run] would file gap"
        log_curator_decision "waste_investigation" \
          "Waste rate ${_waste_rate}% exceeds 20% threshold" \
          "dry_run: would file waste-spike gap"
      else
        _today="$(date -u +%Y-%m-%d)"
        _gap_id="$(_curator_file_gap "ZERO-WASTE: waste-spike — ${_waste_rate}% in 2h window as of ${_today}" "s")"
        if [[ -n "$_gap_id" ]]; then
          _curator_mark_filed_today "waste_investigation" "$_gap_id"
          echo "Decision 5: waste rate ${_waste_rate}% → filed $_gap_id"
          log_curator_decision "waste_investigation" \
            "Waste rate ${_waste_rate}% exceeds 20% threshold" \
            "filed $_gap_id (rate=${_waste_rate}%)"
        else
          log_curator_decision "waste_investigation" \
            "Waste rate ${_waste_rate}%" "error: chump gap reserve failed"
        fi
      fi
    else
      echo "Decision 5: waste rate ${_waste_rate}% ≤ 20% — no action"
    fi
  fi
}

# ============================================================================
# MAIN
# ============================================================================
_DRY_RUN="${CHUMP_CURATOR_DRY_RUN:-0}"
_ONCE=0

_parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) _DRY_RUN=1 ;;
      --once)    _ONCE=1 ;;
    esac
  done
}

main() {
  # META-065: operator panic-button. CHUMP_CURATOR_PAUSE=1 short-circuits
  # the whole run with a single ambient emit so the operator can disable
  # the curator instantly when the fleet is on fire — no need to launchctl
  # bootout the plist.
  if [[ "${CHUMP_CURATOR_PAUSE:-0}" == "1" ]]; then
    echo "[$(date -u +%H:%M:%SZ)] OPUS CURATOR PAUSED (CHUMP_CURATOR_PAUSE=1) — skipping run"
    local _ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    if [[ -d "$(dirname "$_ambient")" ]]; then
      printf '{"ts":"%s","kind":"curator_paused","reason":"CHUMP_CURATOR_PAUSE=1"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_ambient" 2>/dev/null || true
    fi
    exit 0
  fi

  init_fleet_state

  # INFRA-841: heartbeat emission for frequency-aware scheduling audit.
  if declare -F emit_system_gap_tick >/dev/null 2>&1; then
    emit_system_gap_tick opus-curator
  fi

  # META-065: first-time-armed sentinel. When the curator runs for the
  # first time after install (sentinel absent), emit
  # kind=curator_auto_exec_armed so the operator's audit trail records
  # the moment automated mutations went live.
  local _sentinel="${REPO_ROOT:-.}/.chump-locks/curator-armed.sentinel"
  if [[ ! -f "$_sentinel" ]]; then
    local _ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    if [[ -d "$(dirname "$_ambient")" ]]; then
      printf '{"ts":"%s","kind":"curator_auto_exec_armed","note":"first run after launchd install"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_ambient" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$_sentinel")" 2>/dev/null || true
    date -u +%Y-%m-%dT%H:%M:%SZ > "$_sentinel" 2>/dev/null || true
  fi

  echo "[$(date -u +%H:%M:%SZ)] OPUS CURATOR RUN${_DRY_RUN:+' (dry-run)'}"
  echo ""
  echo "=== AUDIT PHASE ==="

  # Run audits (continue even if some fail)
  audit_slo || true
  audit_waste || true
  audit_gaps || true
  audit_pr_stuck || true
  audit_pillar_balance || true

  # INFRA-847: update last_curator_run via fleet_state_set_field (flock-protected)
  # Skip in dry-run mode to avoid side effects during testing.
  if [[ "${_DRY_RUN}" != "1" ]]; then
    fleet_state_set_field "last_curator_run" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  else
    echo "[dry-run] would update last_curator_run via fleet_state_set_field"
  fi

  # Decision phase
  curator_decisions

  echo ""
  echo "=== CURATOR AUDIT COMPLETE ==="

  # INFRA-1068: flush all queued fleet-state.json writes in ONE flock acquisition.
  # This covers last_curator_run + any slo_breach_active changes accumulated
  # during the audit and decision phases above. No-op if batching is disabled
  # (CHUMP_FLEET_STATE_BATCH_WRITES=0) because set_field would have written
  # immediately. Safe to call even when the library is not loaded.
  if declare -F fleet_state_flush >/dev/null 2>&1; then
    fleet_state_flush || true
  fi
}

_parse_args "$@"
main
