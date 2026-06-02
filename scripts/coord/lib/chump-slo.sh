#!/usr/bin/env bash
# chump-slo.sh — SLO-breach consumer registry (INFRA-2424)
#
# This file documents every place in the codebase that reads or acts on the
# slo_breach signal (the .chump/fleet-paused sentinel written by
# ci-health-gate.sh and waste-spike-detector.sh).
#
# ── Key invariant (INFRA-2424) ────────────────────────────────────────────────
#
#   BLOCKS       chump claim       — workers must not start new work when the
#                                    fleet is paused (waste-spike in progress).
#
#   DOES NOT     chump gap reserve — filing a gap is inert; it never starts
#   BLOCK                           work, burns budget, or causes a waste event.
#                                   Daemons that file follow-up gaps during an
#                                   slo_breach must be able to do so without any
#                                   bypass env var.
#
# ── Consumers that BLOCK on slo_breach ───────────────────────────────────────
#
#   scripts/dispatch/worker.sh
#     - Checks .chump/fleet-paused (CHUMP_FLEET_PAUSE_FILE) at top of each
#       claim cycle. Emits kind=worker_paused_waste_spike and sleeps when
#       sentinel is present. No bypass env var — pause is unconditional.
#
# ── Consumers that EMIT slo_breach ───────────────────────────────────────────
#
#   scripts/coord/ci-health-gate.sh
#     - Runs every 5 min via launchd (com.chump.ci-health-gate.plist).
#     - Calls `chump health --slo-check`; on exit 1 writes fleet-paused with
#       reason=slo_breach and emits kind=pipeline_health_throttle.
#     - Respects CHUMP_CI_HEALTH_GATE_DISABLE=1 (noop, no pause file written).
#
#   scripts/coord/waste-spike-detector.sh
#     - Runs every 15 min via launchd.
#     - Writes fleet-paused when waste rate > CHUMP_WASTE_SPIKE_THRESHOLD (30%).
#     - Removes fleet-paused after 2 consecutive below-threshold checks.
#     - No bypass env var (CHUMP_IGNORE_WASTE_PAUSE deleted by INFRA-2424).
#
#   scripts/coord/opus-curator.sh
#     - Emits kind=slo_breach to ambient.jsonl on EDGE (set change only).
#     - Tracks slo_breach_active in .chump/trunk-sentinel-state.json.
#
#   src/web_server.rs
#     - Computes per-pillar slo_breach field in /dashboard/fleet-health API.
#     - slo_breach = pickable_gaps < 2 || p0_count > 5 for a pillar.
#
#   src/health.rs
#     - Tracks SloBreachCount structs in WeeklyHealthSummary.
#     - Includes slo_breaches in JSON digest emitted by `chump health --digest`.
#
# ── Consumers that are informational (no gate) ───────────────────────────────
#
#   src/waste_tally.rs
#     - Tallies kind=slo_breach events from ambient.jsonl for cost estimation.
#     - Default token cost: 9000 tokens / incident (~$0.009 at Sonnet pricing).
#
#   src/fleet_health.rs
#     - Routes slo_breach events to ["slo","detail","current"] display buckets.
#
#   crates/chump-fleet-server/daemons.toml
#     - Lists slo_breach in emits_kinds for ci-health-gate and opus-curator
#       daemon metadata entries.
#
# ── Deleted (INFRA-2424) ──────────────────────────────────────────────────────
#
#   CHUMP_IGNORE_WASTE_PAUSE env var — removed from:
#     src/main.rs (reserve guard deleted entirely)
#     scripts/coord/waste-spike-detector.sh (bypass block deleted)
#     scripts/dispatch/worker.sh (bypass condition deleted)
#     scripts/coord/quartermaster-audit-loop.sh (prefix removed)
#     scripts/coord/trunk-sentinel-daemon.sh (prefix removed)
#     scripts/coord/main-preflight-watchdog-daemon.sh (prefix removed)
#     scripts/coord/daemon-exit-loop-watcher-daemon.sh (prefix removed)
#     scripts/coord/cluster-detector.sh (prefix removed)
#     scripts/coord/main-worktree-drift-detector.sh (prefix removed)
#     scripts/ci/env-vars-internal.txt (entry deleted)
#     scripts/ci/bypass-env-var-allowlist.txt (entry deleted)

# This file is sourced for its documentation value; it exports no functions.
# To check current slo_breach status:
#   cat .chump/fleet-paused 2>/dev/null || echo "fleet not paused"
# To check recent slo_breach events:
#   grep '"kind":"slo_breach"' .chump-locks/ambient.jsonl | tail -5
