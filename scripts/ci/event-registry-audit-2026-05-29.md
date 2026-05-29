# Event Registry Audit — 2026-05-29

**INFRA-2180** | Auditor: opus-shepherd | Date: 2026-05-29

## Summary

| Metric | Count |
|---|---|
| Valid kind entries in reserved.txt (before) | 314 |
| Kinds pruned | 79 |
| Kinds remaining | 235 |
| INVESTIGATE (scanner anchor or open gap ref) | 14 |
| Headroom recovered | +79 slots |

Ambient coverage window: full `.chump-locks/ambient.jsonl` (~28k events, 2026-05-27 to 2026-05-29)

---

## Classification

| Verdict | Count | Criteria |
|---|---|---|
| KEEP — active emits | 33 | at least 1 emit in ambient.jsonl window |
| KEEP — emitter exists (not grep-scannable) | 158 | Documented emit site; printf/struct/heredoc form |
| KEEP — test fixture | 1 | Explicit test-only marker |
| KEEP — other (INFRA ref + existing emitter) | 29 | Specific gap ref + existing script |
| INVESTIGATE — scanner anchor (cold path) | 13 | Has scanner-anchor comment in src/ or scripts/ |
| INVESTIGATE — planned + open gap ref | 1 | Referenced gap not in DB |
| **PRUNE — applied** | **79** | **Zero emits + no anchor + planned with done/absent gap** |

---

## KEEP — active emits in ambient.jsonl (33 kinds)

| Kind | Emit Count |
|---|---|
| `post_push_integrity_watch_err` | 1724 |
| `autopilot_heartbeat` | 345 |
| `curator_decision` | 314 |
| `reaper_run` | 231 |
| `commit` | 70 |
| `wizard_daemon_action` | 54 |
| `bot_merge_watchdog_stuck` | 40 |
| `disk_critical` | 38 |
| `ci_audit_heartbeat` | 38 |
| `bot_merge_bypassed` | 22 |
| `liaison_cache_stale` | 21 |
| `md_links_scan_done` | 21 |
| `md_links_heartbeat` | 20 |
| `tool_approval_escalated` | 13 |
| `infra_watcher_finding` | 12 |
| `target_artifact_reaped` | 11 |
| `oracle_refresh_skipped` | 9 |
| `bot_merge_watchdog_killed` | 8 |
| `wizard_dispatch_executed` | 6 |
| `external_collab_finding` | 5 |
| `curator_session_launched` | 5 |
| `pr_stuck_cycle_1_rebase_attempted` | 4 |
| `chump_claim_force_recover` | 3 |
| `picker_priority_stale` | 3 |
| `admin_merge_forced` | 2 |
| *(+8 more)* | |

---

## INVESTIGATE (14 kinds)

These were not pruned. Each has either a scanner anchor (confirming the emit site exists but
has not fired in the 2-day window) or an open/unresolved gap reference.

### Scanner anchor present (13 kinds)

- `ci_cluster_detected` — reason: emitted by scripts/coord/ci-audit-loop.sh::audit w
- `freshness_critical_stale_bypassed` — reason: META-115 emitted by scripts/coord/freshness-gate.s
- `md_links_lane_override` — reason: emitted by scripts/coord/md-links-loop.sh (scanner
- `orphan_worktree_detected` — reason: RESILIENT-026 emitted by scripts/coord/orphan-work
- `post_push_auto_close_recovered` — reason: INFRA-2026 emitted by scripts/coord/post-push-inte
- `post_push_integrity_watch_ok` — reason: INFRA-2026 heartbeat from post-push-integrity-watc
- `wizard_cascade_rebase_triggered` — reason: META-107 emitted by scripts/coord/wizard-daemon.sh
- `wizard_classify_deferred` — reason: INFRA-2042 emitted by scripts/coord/wizard-daemon.
- `wizard_daemon_paused` — reason: META-109 emitted by scripts/coord/wizard-daemon.sh
- `wizard_daemon_safety_refusal` — reason: META-109 emitted by scripts/coord/wizard-daemon.sh
- `wizard_dispatch_cooldown` — reason: INFRA-2051 emitted by scripts/coord/wizard-daemon.
- `wizard_dispatch_giveup` — reason: INFRA-2051 emitted by scripts/coord/wizard-daemon.
- `wizard_gap_skipped` — reason: META-107 emitted by scripts/coord/wizard-daemon.sh

### Open or unresolved gap reference (1 kinds)

- `gh_shim_worktree_path_resolved` — reason: planned for INFRA-779 gitdir repair confirmation

---

## PRUNE — applied (79 kinds)

All pruned kinds met all three criteria:
1. Zero emits in the full ambient.jsonl window
2. No scanner anchor in `src/` or `scripts/`
3. Reason comment is `planned for X` with either no gap reference, or referenced gap is `done` or absent from DB

### Pruned by reason bucket

**planned-gap-done: ['EVAL-102']** (2 kinds):
- `cognition_ab_comparison`
- `cognition_ab_run_start`

**planned-gap-done: ['INFRA-1076']** (3 kinds):
- `cost_budget_breach`
- `cost_quota_exceeded`
- `cost_quota_warning`

**planned-gap-done: ['INFRA-1116']** (3 kinds):
- `intent`
- `intent_overlap_detected`
- `intent_overlap_overridden`

**planned-gap-done: ['INFRA-1117']** (2 kinds):
- `intent_parse_ok`
- `intent_parse_unknown`

**planned-gap-done: ['INFRA-1258']** (1 kinds):
- `picker_used_priority`

**planned-no-gap** (68 kinds):
- `asks_clarification`
- `auto_merge_arm_failed`
- `autonomous_mode_entered`
- `autonomous_mode_exited`
- `autonomous_ship_rate_regression`
- `avoids_tool`
- `bot_autonomous_check_failed`
- `bot_autonomous_check_passed`
- `bot_merge_aborted_no_worktree`
- `branch_protection_drift`
- `cascade_near_cap`
- `cascade_report`
- `change_approved`
- `change_rolled_back`
- `ci_yml_merge_driver_abort`
- `claim_aborted_disk_full`
- `curator_auto_decompose`
- `decomposition_hint`
- `feature_silent_failure`
- `flake_autorerun_initiated`
- `flake_autorerun_persisted`
- `flake_autorerun_recovered`
- `flake_autorerun_skipped`
- `fleet_paused_disk_critical`
- `ftue_init_smoke_passed`
- `gap_check_false_positive`
- `gap_perf_sample`
- `gate_check_result`
- `gate_check_start`
- `gh_shim_worktree_install_blocked`
- `guard_bypassed`
- `invariant_recovered`
- `invariant_violation`
- `lesson_not_applied`
- `lessons_audit_run`
- `lessons_pruned`
- `network_restored`
- `network_unavailable`
- `opus_roadmap_published`
- `orchestrate_intent`
- `orchestrate_session_end`
- `orphan_pr_candidate`
- `orphan_pr_close_failed`
- `orphan_pr_closed`
- `pillar_balance_block`
- `pillar_balance_warn`
- `planner_rank_ran`
- `pr_bundle_blocked`
- `pr_dedup_blocked`
- `pr_dedup_bypass_rejected`
- `pr_dedup_bypassed`
- `pr_fmt_auto_fixed`
- `pr_fmt_shepherd_run`
- `pr_scope_violation`
- `preflight_dupe_pr`
- `preflight_dupe_worktree`
- `premature_closure_auto_fixed`
- `review_handoff_escalated`
- `review_handoff_timeout`
- `roadmap_update_proposal_cost`
- `roadmap_update_proposal_failed`
- `roadmap_update_proposal_opened`
- `roadmap_update_proposal_skipped`
- `rust_first_bypass_used`
- `slo_recovered`
- `speculative_race_loss`
- `stale_post_merge_gap`
- `test_gate_bypassed`

---

## Malformed entries (not pruned — flag for follow-up cleanup)

Two non-comment lines do not match the `kind_name # reason:` format:

- `INFRA-1866 — audit-flake-catalog.sh CHUMP_AUDIT_FLAKE_CATALOG=0 opt-out` (missing `#` prefix)
- `INFRA-1872 — emitted by scripts/ops/ci-qa-score.sh daily; rollup telemetry kind` (missing `#` prefix)

---

*Generated by INFRA-2180. Prunes applied directly to `scripts/ci/event-registry-reserved.txt`.*
