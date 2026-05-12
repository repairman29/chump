#!/usr/bin/env bash
# opus-curator.sh — INFRA-848: proactive health audit + curator decision logging
# Runs every 10-15 min; audits gaps, pillars, waste, PRs; makes curator decisions.
# This is the primary decision-maker for non-emergency fleet health.
#
# INFRA-848: each decision emits kind=curator_decision to ambient.jsonl with:
#   decision_type: p0_demotion | gap_ac_filled | gap_filed | pr_unstick |
#                  waste_investigation | balance_restock
#   reasoning: human-readable explanation of why this decision was made
#   action_taken: what was actually done (vs. just identified)

set -euo pipefail

FLEET_STATE="${CHUMP_FLEET_STATE:-.chump-locks/fleet-state.json}"
AMBIENT="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"

# Initialize fleet state
init_fleet_state() {
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
  # Returns: exit code 0 if healthy, non-zero if breach
  if command -v chump &> /dev/null; then
    if chump health --slo-check 2>/dev/null; then
      echo "SLO: healthy"
      return 0
    else
      echo "SLO: BREACH"
      log_ambient "slo_breach" '"severity":"high"'
      return 1
    fi
  fi
  return 0
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
      echo "Decision 1: P0 inflation ($p0 > 5) — demote lowest-priority P0 to P1"
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
main() {
  init_fleet_state

  echo "[$(date -u +%H:%M:%SZ)] OPUS CURATOR RUN"
  echo ""
  echo "=== AUDIT PHASE ==="

  # Run audits (continue even if some fail)
  audit_slo || true
  audit_waste || true
  audit_gaps || true
  audit_pr_stuck || true
  audit_pillar_balance || true

  # Update last curator run
  if command -v jq &> /dev/null && [[ -f "$FLEET_STATE" ]]; then
    jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.last_curator_run = $now' \
      "$FLEET_STATE" > "${FLEET_STATE}.tmp" 2>/dev/null && \
      mv "${FLEET_STATE}.tmp" "$FLEET_STATE" 2>/dev/null || true
  fi

  # Decision phase
  curator_decisions

  echo ""
  echo "=== CURATOR AUDIT COMPLETE ==="
}

main "$@"
