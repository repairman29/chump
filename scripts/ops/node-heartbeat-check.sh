#!/usr/bin/env bash
# node-heartbeat-check.sh — RESILIENT-290. Answer "does this node have everything
# it needs to be the always-on heartbeat?" by MACHINE, not by memory.
#
# The operation's core loop is: workers grind gaps -> ship PRs -> PRs land on main.
# For an always-on node (helsinki) to carry that while ATC runs from a laptop that
# sleeps, a specific critical set must be alive HERE and not depend on the Mac.
# This check enumerates that set and reports CRIT/WARN per item. Exit non-zero if
# any CRITICAL item is down.
#
# CRITICAL = the operation stops or loses work without it.
# WARN     = degraded but functional (a fallback exists).
set -uo pipefail
crit_fail=0; warn_fail=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
crit(){ printf '  \033[31m✗ CRIT\033[0m %s\n' "$1"; crit_fail=$((crit_fail+1)); }
warn(){ printf '  \033[33m! WARN\033[0m %s\n' "$1"; warn_fail=$((warn_fail+1)); }

active(){ systemctl is-active "$1" >/dev/null 2>&1; }

echo "=== node heartbeat: $(hostname -s) $(date -u +%FT%TZ) ==="

# 1. WORKER — grinds gaps
if pgrep -f 'scripts/dispatch/worker.sh' >/dev/null 2>&1 || active 'chump-worker@1.service'; then
  ok "worker alive (grind)"; else crit "no worker running — nothing is grinding gaps"; fi

# 2. PR-LANDER — arms green PRs so they merge (RESILIENT-288)
if active 'chump-pr-lander.timer'; then ok "pr-lander timer active (land)"; else crit "pr-lander timer down — green PRs will orphan"; fi

# 3. AUTH — a valid, FRESH Claude token; workers die without it
tok="$(grep -oE 'CLAUDE_CODE_OAUTH_TOKEN=[^ ]+' /root/.chump/providers.env 2>/dev/null | head -1)"
tok_age_h=$(( ( $(date -u +%s) - $(stat -c %Y /root/.chump/providers.env 2>/dev/null || echo 0) ) / 3600 ))
if [[ -z "$tok" ]]; then crit "no CLAUDE_CODE_OAUTH_TOKEN in providers.env"
elif (( tok_age_h > 168 )); then warn "auth token present but providers.env not refreshed in ${tok_age_h}h (self-refresh?)"
else ok "auth token present, providers.env fresh (${tok_age_h}h)"; fi

# 4. GH AUTH — can the node transact with GitHub (push/merge)?
if GH_TOKEN="$(grep -oE 'GH_TOKEN=[^ ]+' /root/.chump/providers.env 2>/dev/null | cut -d= -f2)" \
   gh api user --jq .login >/dev/null 2>&1; then ok "gh auth works (push/merge/arm)"; else crit "gh auth broken — cannot push/merge/arm"; fi

# 5. CI RUNNER — self-hosted actions runner (CI must run for PRs to go green)
if active 'actions.runner.repairman29-chump.chumpd-eu-runner.service'; then ok "CI runner active"; else warn "self-hosted CI runner down (GH-hosted may still run)"; fi

# 6. DISK — headroom for builds
free_g=$(df -BG / | awk 'NR==2{gsub(/G/,"",$4);print $4}')
if (( free_g < 3 )); then crit "disk critical: ${free_g}G free"; elif (( free_g < 8 )); then warn "disk tight: ${free_g}G free"; else ok "disk ok: ${free_g}G free"; fi

# 7. DISK GUARD — the reactor that keeps #6 from wedging
if crontab -l 2>/dev/null | grep -q 'disk-guard\|cargo-sweep' || active 'chump-disk-guard.timer'; then ok "disk hygiene scheduled"; else warn "no disk-hygiene timer (VOA-008)"; fi

# 8. NATS — coordination broker (shared claims / cross-node)
if active 'nats.service'; then ok "nats broker running"; else warn "nats down (workers fall back to pull loop)"; fi

# 9. OPERATOR REACH — Discord gateway (so the fleet can reach Jeff)
if active 'chump-discord-gateway.service'; then ok "discord gateway (operator reach)"; else warn "discord gateway down — no two-way operator channel"; fi

# 10. PR-RESCUE — reap/rebase truly-stuck PRs (RESILIENT-289, still Mac-only)
if active 'chump-pr-rescue.timer' || active 'chump-reaper.timer' && systemctl show -p LastTriggerUSec chump-reaper.timer 2>/dev/null | grep -qv 'LastTriggerUSec=$'; then
  ok "pr-rescue/reaper scheduled"; else warn "no live PR-rescue/reaper on node (RESILIENT-289 — Mac-only today)"; fi

status=$( ((crit_fail==0)) && echo HEARTBEAT-COMPLETE || echo HEARTBEAT-INCOMPLETE )
echo "=== ${status}: crit=$crit_fail warn=$warn_fail ==="

# --monitor: emit an observable event, and PAGE only when a CRITICAL item is down
# (a dead heartbeat item is novel/no-playbook → the escalation gate pages). This
# is what makes helsinki watch its OWN heartbeat instead of ATC remembering to.
if [[ "${1:-}" == "--monitor" ]]; then
  printf '{"ts":"%s","kind":"node_heartbeat","status":"%s","crit":%d,"warn":%d,"node":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$status" "$crit_fail" "$warn_fail" "$(hostname -s)" \
    >> /root/Projects/chump/.chump-locks/ambient.jsonl 2>/dev/null || true
  if (( crit_fail > 0 )); then
    # notify-operator.sh is a sourced lib; call its function via a subshell. The
    # escalation gate decides page-vs-suppress (node_heartbeat_incomplete is novel
    # → pages the operator's phone).
    ( cd /root/Projects/chump && source scripts/coord/lib/notify-operator.sh && \
      CHUMP_NOTIFY_KIND=node_heartbeat_incomplete notify_operator \
      "🫀 **$(hostname -s) heartbeat INCOMPLETE** — crit=$crit_fail. A critical always-on service is down; the fleet may stop or lose work. Run node-heartbeat-check.sh on the node." ) 2>/dev/null || true
  fi
fi
exit $(( crit_fail > 0 ? 1 : 0 ))
