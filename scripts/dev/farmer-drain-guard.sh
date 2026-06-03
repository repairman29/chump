#!/usr/bin/env bash
# scripts/dev/farmer-drain-guard.sh — RESILIENT-076
#
# The farmer's drain-guardian module. Sourced/called each farmer-brown tick. Keeps
# the PR queue DRAINING by guarding the two things that silently wedge it:
#
#   (1) RULESET strict-policy reconcile. The real force behind the quadratic
#       rebase-reset cascade that serialized every merge was NOT classic branch
#       protection (strict=false) — it was the repository RULESET "Protect main"
#       (id 15133729) whose required_status_checks rule had
#       strict_required_status_checks_policy=TRUE. Rulesets evaluate IN ADDITION to
#       classic BP (most-restrictive wins), so the ruleset's strict=true forced
#       every PR up-to-date → the cascade. The conductor flipped it to false and
#       #3020 merged instantly. The existing drift detector (INFRA-121) only WARNED;
#       the farmer RECONCILES — it re-asserts the baseline each tick so the drain
#       cannot silently re-wedge.
#
#   (2) drain-daemon keep-alive. The daemons that keep the queue moving
#       (auto-merge-rearm, ci-flake-rerun, pr-shepherd, bot-merge-watchdog) are
#       re-bootstrapped if their launchd label has fallen out of the agent domain.
#
# FAIL-SAFE: gated on the kill switch. If .chump/fleet-paused exists (the fleet is
# stopped), the guard DETECTS + emits but performs NO mutation (no ruleset PUT, no
# daemon load). Powerful capability, off by default when the operator has paused.
set -uo pipefail

REPO="${CHUMP_REPO_SLUG:-repairman29/chump}"
RULESET_ID="${CHUMP_DRAIN_RULESET_ID:-15133729}"
_FDG_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "${CHUMP_REPO_ROOT:-$HOME/Projects/Chump}")"
BASELINE="$_FDG_ROOT/docs/baselines/branch-protection-main.json"
AMBIENT="${CHUMP_AMBIENT_LOG:-$_FDG_ROOT/.chump-locks/ambient.jsonl}"
PAUSED_MARKER="$_FDG_ROOT/.chump/fleet-paused"

# Drain daemons to keep loaded (label -> plist basename). Only acted on when the
# plist file actually exists under ~/Library/LaunchAgents (never fabricated).
_FDG_DRAIN_DAEMONS=(
  "dev.chump.auto-merge-rearm"
  "dev.chump.ci-flake-rerun"
  "com.chump.pr-shepherd"
  "com.chump.bot-merge-watchdog"
)

_fdg_audit() {  # status, extra-json
  # scanner-anchor: "kind":"farmer_drain_guard"  (RESILIENT-076; emitted only on
  # drift/reconcile/daemon-action — never on the in-sync common path, so volume
  # stays well under the obs-budget noisy-kind threshold).
  printf '{"ts":"%s","kind":"farmer_drain_guard","source":"farmer-drain-guard","status":"%s","ruleset":%s%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$RULESET_ID" "${2:-}" >> "$AMBIENT" 2>/dev/null || true
}
_fdg_log() { echo "[drain-guard $(date -u +%H:%M:%SZ)] $*"; }

_fdg_paused() { [ -f "$PAUSED_MARKER" ]; }

# Baseline expected strict value (default false; baseline file overrides).
_fdg_want_strict() {
  if [ -f "$BASELINE" ]; then
    python3 -c "import json;d=json.load(open('$BASELINE'));print(str(d.get('_ruleset_baseline',{}).get('strict_required_status_checks_policy',False)).lower())" 2>/dev/null || echo false
  else
    echo false
  fi
}

# (1) reconcile the ruleset strict policy to the baseline.
fdg_guard_ruleset() {
  command -v gh >/dev/null 2>&1 || { _fdg_log "gh missing; skip ruleset guard"; return 0; }
  local want live cur
  want="$(_fdg_want_strict)"
  live="$(gh api "repos/$REPO/rulesets/$RULESET_ID" 2>/dev/null)" || { _fdg_log "ruleset read failed; skip"; return 0; }
  cur="$(printf '%s' "$live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d.get('rules',[]):
    if r.get('type')=='required_status_checks':
        print(str(r.get('parameters',{}).get('strict_required_status_checks_policy',False)).lower()); break
else:
    print('absent')" 2>/dev/null)"
  if [ "$cur" = "$want" ]; then
    _fdg_log "ruleset strict=$cur (in sync with baseline=$want)"; return 0
  fi
  if [ "$cur" = "absent" ]; then
    _fdg_log "ruleset has no required_status_checks rule — nothing to reconcile"; return 0
  fi
  _fdg_log "DRIFT: ruleset strict=$cur, baseline=$want"
  if _fdg_paused; then
    _fdg_log "fleet PAUSED (.chump/fleet-paused) — detect-only, NOT reconciling"
    _fdg_audit "drift_paused" ",\"strict\":\"$cur\",\"baseline\":\"$want\""
    return 0
  fi
  local bk; bk="/tmp/ruleset_backup_${RULESET_ID}_$(date -u +%Y%m%dT%H%M%SZ).json"
  printf '%s' "$live" > "$bk"
  local body
  body="$(printf '%s' "$live" | python3 -c "
import json,sys
d=json.load(sys.stdin)
want = '$want' == 'true'
for r in d.get('rules',[]):
    if r.get('type')=='required_status_checks':
        r.setdefault('parameters',{})['strict_required_status_checks_policy']=want
# PUT accepts only the writable subset; drop server-managed fields (id, source,
# created_at, updated_at, node_id, _links, current_user_can_bypass, ...).
print(json.dumps({k:d[k] for k in ('name','target','enforcement','conditions','rules','bypass_actors') if k in d}))" 2>/dev/null)"
  if [ -z "$body" ]; then _fdg_log "PUT-body build failed; ruleset untouched (backup $bk)"; _fdg_audit "reconcile_failed" ",\"reason\":\"body_build\""; return 0; fi
  if printf '%s' "$body" | gh api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input - >/dev/null 2>&1; then
    _fdg_log "RECONCILED ruleset strict $cur -> $want (backup $bk)"
    _fdg_audit "reconciled" ",\"from\":\"$cur\",\"to\":\"$want\",\"backup\":\"$bk\""
  else
    _fdg_log "ruleset PUT failed; unchanged (backup $bk)"
    _fdg_audit "reconcile_failed" ",\"reason\":\"put\",\"strict\":\"$cur\""
  fi
}

# (2) keep the drain daemons loaded.
fdg_guard_daemons() {
  command -v launchctl >/dev/null 2>&1 || return 0
  local loaded label plist domain
  domain="gui/$(id -u)"
  loaded="$(launchctl list 2>/dev/null || true)"
  for label in "${_FDG_DRAIN_DAEMONS[@]}"; do
    printf '%s\n' "$loaded" | grep -q "[[:space:]]${label}$" && continue   # already loaded
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    [ -f "$plist" ] || continue                                            # never fabricate
    _fdg_log "drain daemon $label not loaded"
    if _fdg_paused; then _fdg_audit "daemon_down_paused" ",\"daemon\":\"$label\""; continue; fi
    if launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 || launchctl load "$plist" >/dev/null 2>&1; then
      _fdg_log "reloaded drain daemon $label"
      _fdg_audit "daemon_reloaded" ",\"daemon\":\"$label\""
    fi
  done
}

fdg_guard_drain() { fdg_guard_ruleset; fdg_guard_daemons; }

# Sourceable (farmer-brown calls fdg_guard_drain) OR runnable standalone (--once).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fdg_guard_drain
fi
