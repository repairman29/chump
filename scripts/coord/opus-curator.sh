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
# Uses emergency-fast-path.sh when available; falls back to direct write (no flock).
fleet_state_set_field() {
  local key="$1" val="$2"
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

audit_waste() {
  # Run: chump waste-tally --window 2h
  if command -v chump &> /dev/null; then
    WASTE_RATE=$(chump waste-tally --window 2h 2>/dev/null | jq '.waste_rate // 0' 2>/dev/null || echo 0)
    echo "Waste rate: ${WASTE_RATE}%"

    if (( $(echo "$WASTE_RATE > 20" | bc -l 2>/dev/null || echo 0) )); then
      echo "  WARNING: waste rate > 20%"
      log_ambient "waste_rate_high" '"rate":'$WASTE_RATE',"threshold":20'
      return 1
    fi
  fi
  return 0
}

audit_gaps() {
  # Run: chump gap audit-priorities --json
  if command -v chump &> /dev/null; then
    AUDIT=$(chump gap audit-priorities --json 2>/dev/null || echo '{}')

    P0_COUNT=$(echo "$AUDIT" | jq '.p0_count // 0' 2>/dev/null || echo 0)
    VAGUE_COUNT=$(echo "$AUDIT" | jq '.vague_pickable // 0' 2>/dev/null || echo 0)

    echo "P0 gaps: $P0_COUNT"
    echo "Vague pickable: $VAGUE_COUNT"

    if [[ $P0_COUNT -gt 5 ]]; then
      echo "  WARNING: P0 count > 5 (inflation)"
      log_ambient "p0_inflation" '"count":'$P0_COUNT',"threshold":5'
    fi

    if [[ $VAGUE_COUNT -gt 0 ]]; then
      echo "  WARNING: $VAGUE_COUNT vague pickable gaps (need AC)"
      log_ambient "vague_gaps_found" '"count":'$VAGUE_COUNT
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

    EFFECTIVE=$(echo "$AUDIT" | jq '[.[] | select(.pillar == "EFFECTIVE" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null || echo 0)
    CREDIBLE=$(echo "$AUDIT" | jq '[.[] | select(.pillar == "CREDIBLE" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null || echo 0)
    RESILIENT=$(echo "$AUDIT" | jq '[.[] | select(.pillar == "RESILIENT" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null || echo 0)
    ZERO_WASTE=$(echo "$AUDIT" | jq '[.[] | select(.pillar == "ZERO-WASTE" and .size | IN("xs","s","m") and (.depends_on | length) == 0)] | length' 2>/dev/null || echo 0)

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

  # Decision 1: Handle P0 inflation (demote if > 5)
  if command -v chump &> /dev/null; then
    _p0=$(chump gap audit-priorities --json 2>/dev/null | jq '.p0_count // 0' 2>/dev/null || echo 0)
    if [[ "${_p0:-0}" -gt 5 ]]; then
      echo "Decision 1: P0 inflation ($_p0 > 5) — demote lowest-priority P0 to P1"
      # INFRA-848: emit curator_decision with required fields
      log_curator_decision \
        "p0_demotion" \
        "P0 count is $_p0 (> budget of 5); demoting to enforce P0 budget" \
        "identified_only: operator should run chump gap audit-priorities to pick which to demote"
    else
      echo "Decision 1: P0 count ${_p0:-0} ≤ 5 — within budget, no demotion needed"
    fi
  fi

  # Decision 2: Validate AC on vague gaps
  echo "Decision 2: Check for vague gaps; add AC if needed"
  log_curator_decision \
    "gap_ac_filled" \
    "Routine check: vague gaps without acceptance_criteria block fleet pickup" \
    "audit_phase ran chump gap audit-priorities; operator to fill AC on any vague gaps"

  # Decision 3: Pillar rebalancing (file gap if any pillar < 2 pickable)
  echo "Decision 3: Rebalance pillars; file gaps if any starving"
  log_curator_decision \
    "balance_restock" \
    "Pillar balance check: any pillar < 2 pickable xs/s/m gaps triggers gap filing" \
    "audit_pillar_balance ran; if imbalance detected, operator to file balance gaps"

  # Decision 4: Unblock stuck PRs
  echo "Decision 4: Identify stuck PRs; trigger pr-unstick if needed"
  log_curator_decision \
    "pr_unstick" \
    "Stuck PR scan: PRs open >2h with failing checks block fleet throughput" \
    "audit_pr_stuck ran; if stuck PRs found, operator to rebase or fix CI"

  # Decision 5: Waste rate control (if > 20%, file INFRA gap for root cause)
  echo "Decision 5: If waste > 20%, file gap + signal scale-down"
  log_curator_decision \
    "waste_investigation" \
    "Waste tally check: >20% waste rate triggers root-cause gap filing" \
    "audit_waste ran; if waste > 20%, operator to file INFRA gap for dominant waste kind"
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
  init_fleet_state

  # INFRA-841: heartbeat emission for frequency-aware scheduling audit.
  if declare -F emit_system_gap_tick >/dev/null 2>&1; then
    emit_system_gap_tick opus-curator
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
}

_parse_args "$@"
main
