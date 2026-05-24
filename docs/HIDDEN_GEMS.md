# Chump — Hidden Gems

> Auto-generated curated showcase of valuable primitives that new users miss.
> Content source for Evangelist bot (META-066). Pair with docs/PITCH.md for the
> why-Chump narrative; this is the how-Chump payload.

> Build: `bash scripts/dev/build-hidden-gems.sh`. Operator overlay lives in
> `docs/HIDDEN_GEMS_CURATED.yaml`; curated entries land first in each section.

## CLI commands

### `chump-coord watch`

- **Where:** `crates/chump-coord/src/main.rs`
- **When to use:** Live cross-machine view of NATS-published fleet events (claims, ships, alerts) without polling
- **Example:**

  ```bash
  chump-coord watch
  ```

### `chump gap consolidate`

- **Where:** `src/main.rs`
- **When to use:** Detect near-duplicate gap titles before they pollute the registry — Jaccard-similarity ranked, dry-run by default
- **Example:**

  ```bash
  chump gap consolidate --threshold 0.7
  ```

### `chump fleet doctor`

- **Where:** `src/main.rs`
- **When to use:** Strict 7-invariant health check; non-zero exit on any failure (binary staleness, expired leases, low disk, dirty PRs, gap drift, P0 budget, pillar floor)
- **Example:**

  ```bash
  chump fleet doctor --slo-check
  ```

### `scripts/dev/api-cost-leaderboard.sh`

- **Where:** `scripts/dev/api-cost-leaderboard.sh`
- **When to use:** Find the biggest GitHub-API burner in the fleet over the last hour — first diagnostic when graphql_exhausted fires
- **Example:**

  ```bash
  bash scripts/dev/api-cost-leaderboard.sh --window 1h
  ```

### `scripts/dispatch/fleet-brief.sh`

- **Where:** `scripts/dispatch/fleet-brief.sh`
- **When to use:** 60-second operator briefing — 24h ship count, pillar mix, stalls, alerts, suggested next action
- **Example:**

  ```bash
  bash scripts/dispatch/fleet-brief.sh
  ```

### `scripts/dev/chump-dashboard-tui.sh`

- **Where:** `scripts/dev/chump-dashboard-tui.sh`
- **When to use:** One-shot terminal dashboard (ships + lightning + leases + inbox + pillars) — screenshot-ready in 80x40
- **Example:**

  ```bash
  bash scripts/dev/chump-dashboard-tui.sh
  ```

### `scripts/dev/chump-pitch.sh`

- **Where:** `scripts/dev/chump-pitch.sh`
- **When to use:** One-command operator pitch — runs dashboard + lightning timeline + cats DEMO_5MIN.md for a 5-minute walkthrough
- **Example:**

  ```bash
  bash scripts/dev/chump-pitch.sh
  ```

### `scripts/coord/chump-commit.sh`

- **Where:** `scripts/coord/chump-commit.sh`
- **When to use:** See scripts/README.md for details on chump-commit.sh
- **Example:**

  ```bash
  bash scripts/coord/chump-commit.sh --help 2>&1 | head -20
  ```

### `scripts/coord/bot-merge.sh`

- **Where:** `scripts/coord/bot-merge.sh`
- **When to use:** See scripts/README.md for details on bot-merge.sh
- **Example:**

  ```bash
  bash scripts/coord/bot-merge.sh --help 2>&1 | head -20
  ```

### `scripts/dispatch/fleet-status.sh`

- **Where:** `scripts/dispatch/fleet-status.sh`
- **When to use:** See scripts/README.md for details on fleet-status.sh
- **Example:**

  ```bash
  bash scripts/dispatch/fleet-status.sh --help 2>&1 | head -20
  ```

### `scripts/dispatch/run-fleet.sh`

- **Where:** `scripts/dispatch/run-fleet.sh`
- **When to use:** See scripts/README.md for details on run-fleet.sh
- **Example:**

  ```bash
  bash scripts/dispatch/run-fleet.sh --help 2>&1 | head -20
  ```

### `scripts/dispatch/fleet-restart.sh`

- **Where:** `scripts/dispatch/fleet-restart.sh`
- **When to use:** See scripts/README.md for details on fleet-restart.sh
- **Example:**

  ```bash
  bash scripts/dispatch/fleet-restart.sh --help 2>&1 | head -20
  ```

### `scripts/dev/ambient-watch.sh`

- **Where:** `scripts/dev/ambient-watch.sh`
- **When to use:** See scripts/README.md for details on ambient-watch.sh
- **Example:**

  ```bash
  bash scripts/dev/ambient-watch.sh --help 2>&1 | head -20
  ```

### `scripts/dev/build-capabilities-registry.sh`

- **Where:** `scripts/dev/build-capabilities-registry.sh`
- **When to use:** See scripts/README.md for details on build-capabilities-registry.sh
- **Example:**

  ```bash
  bash scripts/dev/build-capabilities-registry.sh --help 2>&1 | head -20
  ```

### `scripts/ops/generate-capabilities-registry.sh`

- **Where:** `scripts/ops/generate-capabilities-registry.sh`
- **When to use:** See scripts/README.md for details on generate-capabilities-registry.sh
- **Example:**

  ```bash
  bash scripts/ops/generate-capabilities-registry.sh --help 2>&1 | head -20
  ```

### `scripts/ops/stale-gap-lock-reaper.sh`

- **Where:** `scripts/ops/stale-gap-lock-reaper.sh`
- **When to use:** See scripts/README.md for details on stale-gap-lock-reaper.sh
- **Example:**

  ```bash
  bash scripts/ops/stale-gap-lock-reaper.sh --help 2>&1 | head -20
  ```

## Agent tools (MCP)

### `chump-mcp-gaps`

- **Where:** `chump-mcp.json`
- **When to use:** MCP server that exposes chump gap CLI surface to any MCP-aware agent — list, show, reserve, ship without spawning a shell
- **Example:**

  ```bash
  claude --mcp-servers chump-mcp.json
  ```

### `filesystem`

- **Where:** `chump-mcp.json`
- **When to use:** chump-mcp-filesystem
- **Example:**

  ```bash
  claude --mcp-config chump-mcp.json  # registers filesystem
  ```

### `git`

- **Where:** `chump-mcp.json`
- **When to use:** chump-mcp-git
- **Example:**

  ```bash
  claude --mcp-config chump-mcp.json  # registers git
  ```

### `github`

- **Where:** `chump-mcp.json`
- **When to use:** chump-mcp-github
- **Example:**

  ```bash
  claude --mcp-config chump-mcp.json  # registers github
  ```

### `gaps`

- **Where:** `chump-mcp.json`
- **When to use:** chump-mcp-gaps
- **Example:**

  ```bash
  claude --mcp-config chump-mcp.json  # registers gaps
  ```

### `memory`

- **Where:** `chump-mcp.json`
- **When to use:** chump-mcp-memory
- **Example:**

  ```bash
  claude --mcp-config chump-mcp.json  # registers memory
  ```

## Config knobs (env vars)

_No entries yet — add to `docs/HIDDEN_GEMS_CURATED.yaml`._

## Hidden features (workflow tricks)

### `CHUMP_GH_CALL_CRITICALITY=background`

- **Where:** `scripts/coord/lib/github_cache.sh`
- **When to use:** Tag a non-critical gh call as background so it yields the GraphQL bucket to ship-blocking critical-path callers under pressure
- **Example:**

  ```bash
  CHUMP_GH_CALL_CRITICALITY=background gh pr list --limit 100
  ```

### `cache_lookup_pr / cache_query_behind_prs`

- **Where:** `scripts/coord/lib/github_cache.sh`
- **When to use:** Cache-first PR-state lookup (webhook-populated SQLite at .chump/github_cache.db) — REST-only fallback on miss; avoids GraphQL exhaustion
- **Example:**

  ```bash
  source scripts/coord/lib/github_cache.sh && cache_lookup_pr 2467
  ```

### `ambient kind=commit`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by Claude Code PostToolUse hook (Bash git commit), not by scripts/; hooks are outside grep production paths
- **Example:**

  ```bash
  grep '"kind":"commit"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=redundancy_bypass_used`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-redundancy.sh (META-063); git hooks are outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"redundancy_bypass_used"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=rust_first_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-rust-first.sh on the block path (INFRA-1448); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"rust_first_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=rust_first_strict_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-rust-first.sh strict layer (INFRA-1580); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"rust_first_strict_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=rust_first_bypass_audit`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/dev/rust-first-bypass-audit.sh (INFRA-1580); scripts/dev/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"rust_first_bypass_audit"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=prepush_head_drift`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-push (INFRA-1372); git-hooks/ dir is outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"prepush_head_drift"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_regression_guard_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-push-ci-regression-guard.sh (INFRA-1421); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"ci_regression_guard_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_regression_guard_missing`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-push-ci-regression-guard.sh (INFRA-1421); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"ci_regression_guard_missing"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_regression_guard_suite_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-push-ci-regression-guard.sh (INFRA-1421); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"ci_regression_guard_suite_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=obs_coverage_test_fixture`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: synthetic test-fixture kind; emitter is scripts/ci/ (excluded from prod grep); status=test-fixture in registry
- **Example:**

  ```bash
  grep '"kind":"obs_coverage_test_fixture"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=autonomous_mode_entered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for chump fleet autonomous-mode command
- **Example:**

  ```bash
  grep '"kind":"autonomous_mode_entered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=autonomous_mode_exited`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for chump fleet autonomous-mode command
- **Example:**

  ```bash
  grep '"kind":"autonomous_mode_exited"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=autonomous_ship_rate_regression`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for fleet health regression detector
- **Example:**

  ```bash
  grep '"kind":"autonomous_ship_rate_regression"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_merge_arm_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge.sh auto-merge arm failure path
- **Example:**

  ```bash
  grep '"kind":"auto_merge_arm_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_merge_armed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge.sh --auto-merge success confirmation
- **Example:**

  ```bash
  grep '"kind":"auto_merge_armed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_autonomous_check_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge autonomous-mode pre-ship gate
- **Example:**

  ```bash
  grep '"kind":"bot_autonomous_check_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_autonomous_check_passed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge autonomous-mode pre-ship gate
- **Example:**

  ```bash
  grep '"kind":"bot_autonomous_check_passed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_aborted_no_worktree`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge when worktree missing mid-run
- **Example:**

  ```bash
  grep '"kind":"bot_merge_aborted_no_worktree"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_auto_armed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: duplicate of auto_merge_armed (harmonize on ship)
- **Example:**

  ```bash
  grep '"kind":"bot_merge_auto_armed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_watchdog_killed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge watchdog kill path
- **Example:**

  ```bash
  grep '"kind":"bot_merge_watchdog_killed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_watchdog_stuck`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge stuck-detection
- **Example:**

  ```bash
  grep '"kind":"bot_merge_watchdog_stuck"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=branch_protection_drift`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for CI gate that detects branch protection changes
- **Example:**

  ```bash
  grep '"kind":"branch_protection_drift"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cascade_near_cap`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for Anthropic cascade rate-limit approach warning
- **Example:**

  ```bash
  grep '"kind":"cascade_near_cap"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cascade_report`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for cascade routing summary event
- **Example:**

  ```bash
  grep '"kind":"cascade_report"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=change_approved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for operator change-approval workflow
- **Example:**

  ```bash
  grep '"kind":"change_approved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=change_rolled_back`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for automated rollback on regression
- **Example:**

  ```bash
  grep '"kind":"change_rolled_back"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_parity_drift`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/ci/test-preflight-ci-parity.sh (INFRA-1867); scripts/ci/ is outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"ci_parity_drift"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_yml_merge_driver_abort`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for merge-driver failure detection in CI
- **Example:**

  ```bash
  grep '"kind":"ci_yml_merge_driver_abort"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gate_check_result`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for chump gate --check result emission
- **Example:**

  ```bash
  grep '"kind":"gate_check_result"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gate_check_start`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for chump gate --check start emission
- **Example:**

  ```bash
  grep '"kind":"gate_check_start"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=claim_aborted_disk_full`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for claim guard: disk < threshold aborts claim
- **Example:**

  ```bash
  grep '"kind":"claim_aborted_disk_full"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cost_budget_breach`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1076 cost quota enforcement
- **Example:**

  ```bash
  grep '"kind":"cost_budget_breach"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cost_quota_exceeded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1076 hard quota enforcement
- **Example:**

  ```bash
  grep '"kind":"cost_quota_exceeded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cost_quota_warning`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1076 soft quota warning
- **Example:**

  ```bash
  grep '"kind":"cost_quota_warning"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cognition_ab_comparison`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for EVAL-102 LLM-judge comparison result
- **Example:**

  ```bash
  grep '"kind":"cognition_ab_comparison"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cognition_ab_run_start`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for EVAL-102 AB run start
- **Example:**

  ```bash
  grep '"kind":"cognition_ab_run_start"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_auto_decompose`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator auto-decompose arm
- **Example:**

  ```bash
  grep '"kind":"curator_auto_decompose"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_decision`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator gap-ranking decision emit
- **Example:**

  ```bash
  grep '"kind":"curator_decision"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=decomposition_hint`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for chump gap decompose hint injection
- **Example:**

  ```bash
  grep '"kind":"decomposition_hint"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=disk_critical`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitter scripts/ops/disk-watchdog.sh uses variable-mediated emit (disk_alert_kind); grep pattern misses it; will fix in follow-up
- **Example:**

  ```bash
  grep '"kind":"disk_critical"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_paused_disk_critical`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for fleet pause-on-disk-critical guard
- **Example:**

  ```bash
  grep '"kind":"fleet_paused_disk_critical"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=asks_clarification`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for eval harness behavior tracking
- **Example:**

  ```bash
  grep '"kind":"asks_clarification"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=avoids_tool`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for eval harness behavior tracking
- **Example:**

  ```bash
  grep '"kind":"avoids_tool"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=feature_silent_failure`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for feature smoke-test failure detector
- **Example:**

  ```bash
  grep '"kind":"feature_silent_failure"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=flake_autorerun_initiated`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for RESILIENT flake-rerun orchestrator
- **Example:**

  ```bash
  grep '"kind":"flake_autorerun_initiated"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=flake_autorerun_persisted`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for RESILIENT flake-rerun (still flaking after retry)
- **Example:**

  ```bash
  grep '"kind":"flake_autorerun_persisted"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=flake_autorerun_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for RESILIENT flake-rerun (recovered on retry)
- **Example:**

  ```bash
  grep '"kind":"flake_autorerun_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=flake_autorerun_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for RESILIENT flake-rerun (skipped: not a known flake)
- **Example:**

  ```bash
  grep '"kind":"flake_autorerun_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_version_skew`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for fleet version drift detector
- **Example:**

  ```bash
  grep '"kind":"fleet_version_skew"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ftue_init_smoke_passed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for FTUE first-run smoke test confirmation
- **Example:**

  ```bash
  grep '"kind":"ftue_init_smoke_passed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_check_false_positive`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for gap-preflight false-positive reporter
- **Example:**

  ```bash
  grep '"kind":"gap_check_false_positive"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_perf_sample`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for gap execution performance sampling
- **Example:**

  ```bash
  grep '"kind":"gap_perf_sample"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_shipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for chump gap ship emit (currently ship silently succeeds)
- **Example:**

  ```bash
  grep '"kind":"gap_shipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gh_shim_worktree_install_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for gh-shim install blocked by security policy
- **Example:**

  ```bash
  grep '"kind":"gh_shim_worktree_install_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gh_shim_worktree_path_resolved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-779 gitdir repair confirmation
- **Example:**

  ```bash
  grep '"kind":"gh_shim_worktree_path_resolved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=guard_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for pre-commit/pre-push --no-verify bypass tracker
- **Example:**

  ```bash
  grep '"kind":"guard_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=intent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1116 INTENT file registration
- **Example:**

  ```bash
  grep '"kind":"intent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=intent_overlap_detected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1116 overlap gate
- **Example:**

  ```bash
  grep '"kind":"intent_overlap_detected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=intent_overlap_overridden`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1116 operator override
- **Example:**

  ```bash
  grep '"kind":"intent_overlap_overridden"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=intent_parse_ok`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1117 intent parser success
- **Example:**

  ```bash
  grep '"kind":"intent_parse_ok"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=intent_parse_unknown`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1117 intent parser unknown field
- **Example:**

  ```bash
  grep '"kind":"intent_parse_unknown"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=invariant_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for invariant violation auto-recovery
- **Example:**

  ```bash
  grep '"kind":"invariant_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=invariant_violation`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for invariant violation detector
- **Example:**

  ```bash
  grep '"kind":"invariant_violation"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lesson_not_applied`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for lessons injection failure detector
- **Example:**

  ```bash
  grep '"kind":"lesson_not_applied"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lessons_audit_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for lessons audit cron emit
- **Example:**

  ```bash
  grep '"kind":"lessons_audit_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lessons_pruned`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for lessons pruner emit
- **Example:**

  ```bash
  grep '"kind":"lessons_pruned"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=network_restored`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for network watchdog: online after offline
- **Example:**

  ```bash
  grep '"kind":"network_restored"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=network_unavailable`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for network watchdog: offline detection
- **Example:**

  ```bash
  grep '"kind":"network_unavailable"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_roadmap_published`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator roadmap publication emit
- **Example:**

  ```bash
  grep '"kind":"opus_roadmap_published"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orchestrate_intent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for orchestration session intent emit
- **Example:**

  ```bash
  grep '"kind":"orchestrate_intent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orchestrate_session_end`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for orchestration session end emit
- **Example:**

  ```bash
  grep '"kind":"orchestrate_session_end"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orphan_pr_candidate`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for orphan-pr-detector candidate emit
- **Example:**

  ```bash
  grep '"kind":"orphan_pr_candidate"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orphan_pr_close_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for orphan-pr-detector close failure
- **Example:**

  ```bash
  grep '"kind":"orphan_pr_close_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orphan_pr_closed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for orphan-pr-detector close success
- **Example:**

  ```bash
  grep '"kind":"orphan_pr_closed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=picker_priority_stale`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1258 picker priority stale detection
- **Example:**

  ```bash
  grep '"kind":"picker_priority_stale"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=picker_used_priority`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1258 picker priority usage confirmation
- **Example:**

  ```bash
  grep '"kind":"picker_used_priority"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pillar_balance_block`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for pillar balance enforcer: block claim
- **Example:**

  ```bash
  grep '"kind":"pillar_balance_block"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pillar_balance_warn`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for pillar balance enforcer: warn
- **Example:**

  ```bash
  grep '"kind":"pillar_balance_warn"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=planner_rank_ran`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for gap planner ranking emit
- **Example:**

  ```bash
  grep '"kind":"planner_rank_ran"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_bounced_relanded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitter scripts/coord/ uses _emit function (confirmed in grep); adding to reserved while INFRA-1287 grep fixes land
- **Example:**

  ```bash
  grep '"kind":"pr_bounced_relanded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_bounced_unfinished`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitter scripts/coord/bounced-pr-detector.sh; _emit pattern may not cover all code paths
- **Example:**

  ```bash
  grep '"kind":"pr_bounced_unfinished"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_bundle_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR bundle gate: conflicting bundle blocked
- **Example:**

  ```bash
  grep '"kind":"pr_bundle_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_dedup_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR dedup gate: duplicate PR blocked
- **Example:**

  ```bash
  grep '"kind":"pr_dedup_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_dedup_bypass_rejected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR dedup bypass rejection
- **Example:**

  ```bash
  grep '"kind":"pr_dedup_bypass_rejected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_dedup_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR dedup bypass with reason
- **Example:**

  ```bash
  grep '"kind":"pr_dedup_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_fmt_auto_fixed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR format shepherd auto-fix emit
- **Example:**

  ```bash
  grep '"kind":"pr_fmt_auto_fixed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_fmt_shepherd_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR format shepherd run emit
- **Example:**

  ```bash
  grep '"kind":"pr_fmt_shepherd_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_scope_violation`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for PR scope gate: files-outside-intent
- **Example:**

  ```bash
  grep '"kind":"pr_scope_violation"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_dupe_pr`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for gap-preflight duplicate PR warning emit
- **Example:**

  ```bash
  grep '"kind":"preflight_dupe_pr"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_dupe_worktree`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for gap-preflight duplicate worktree warning emit
- **Example:**

  ```bash
  grep '"kind":"preflight_dupe_worktree"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=premature_closure_auto_fixed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for premature-closure auto-fix emit
- **Example:**

  ```bash
  grep '"kind":"premature_closure_auto_fixed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=reaper_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for reaper start/stop lifecycle emit
- **Example:**

  ```bash
  grep '"kind":"reaper_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=reaper_safety_gate_triggered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1786 — emitted by reap-orphan-claude-procs.sh when fg_pid=none on non-headless macOS; safety gate refuses reap-all
- **Example:**

  ```bash
  grep '"kind":"reaper_safety_gate_triggered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=review_handoff_escalated`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for review handoff escalation emit
- **Example:**

  ```bash
  grep '"kind":"review_handoff_escalated"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=review_handoff_timeout`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for review handoff timeout emit
- **Example:**

  ```bash
  grep '"kind":"review_handoff_timeout"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=roadmap_update_proposal_cost`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator roadmap update cost report
- **Example:**

  ```bash
  grep '"kind":"roadmap_update_proposal_cost"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=roadmap_update_proposal_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator roadmap update failure
- **Example:**

  ```bash
  grep '"kind":"roadmap_update_proposal_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=roadmap_update_proposal_opened`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator roadmap update PR opened
- **Example:**

  ```bash
  grep '"kind":"roadmap_update_proposal_opened"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=roadmap_update_proposal_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator roadmap update skipped
- **Example:**

  ```bash
  grep '"kind":"roadmap_update_proposal_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=rust_first_bypass_used`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for rust-first policy bypass tracker
- **Example:**

  ```bash
  grep '"kind":"rust_first_bypass_used"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=slo_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for SLO watchdog: recovered from breach
- **Example:**

  ```bash
  grep '"kind":"slo_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=speculative_race_loss`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for speculative-gap race loss emit
- **Example:**

  ```bash
  grep '"kind":"speculative_race_loss"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=stale_post_merge_gap`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for post-merge stale gap detector
- **Example:**

  ```bash
  grep '"kind":"stale_post_merge_gap"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=test_gate_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for test gate bypass emit (CHUMP_TEST_GATE=0)
- **Example:**

  ```bash
  grep '"kind":"test_gate_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=watchdog_silent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for watchdog heartbeat absence detector
- **Example:**

  ```bash
  grep '"kind":"watchdog_silent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_test_pass`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/ci/test-system-integration.sh which is excluded from PROD_PATHS (CI scripts legitimately mention events without s
- **Example:**

  ```bash
  grep '"kind":"integration_test_pass"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_test_fail`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/ci/test-system-integration.sh which is excluded from PROD_PATHS (CI scripts legitimately mention events without s
- **Example:**

  ```bash
  grep '"kind":"integration_test_fail"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=target_artifact_reaped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1349 target/ artifact reaper kind; emitted when build dirs are cleaned under disk pressure
- **Example:**

  ```bash
  grep '"kind":"target_artifact_reaped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=target_artifact_critical_reap`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1431 critical-mode variant; emitted via shell variable $_event_kind in target-dir-reaper.sh (not a grep-scannable literal); sa
- **Example:**

  ```bash
  grep '"kind":"target_artifact_critical_reap"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_rebase_daemon_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1406 pr-rebase-daemon heartbeat
- **Example:**

  ```bash
  grep '"kind":"pr_rebase_daemon_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_rebase_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1406 pr-rebase-daemon rebase failure
- **Example:**

  ```bash
  grep '"kind":"pr_rebase_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_rebased_auto`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1406 pr-rebase-daemon successful auto-rebase
- **Example:**

  ```bash
  grep '"kind":"pr_rebased_auto"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fixture_commit_dropped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned by INFRA-1408 #2179 pre-push fixture detector; allow orphan until that PR lands
- **Example:**

  ```bash
  grep '"kind":"fixture_commit_dropped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=synthesis_gap_filed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: declared kind awaiting emitter (INFRA-1684 synthesis-truth audit wip); allowlist orphan to unblock audit cluster (#2337, et al.)
- **Example:**

  ```bash
  grep '"kind":"synthesis_gap_filed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=stale_branch_auto_rebased`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1429 #2356 emitted from src/paramedic.rs action_rebase_dirty; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"stale_branch_auto_rebased"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=keystone_cascade_fired`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1420 #2361 emitted from src/paramedic.rs action_keystone_cascade; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"keystone_cascade_fired"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_resumed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1456 #2351 emitted from src/resume_cmd.rs; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"gap_resumed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_scrapped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1456 #2351 emitted from src/scrap_cmd.rs; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"gap_scrapped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=claim_duplicate_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1442 #2358 emitted from src/atomic_claim.rs emit_claim_duplicate_bypassed; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"claim_duplicate_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_registry_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1731 #2377 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_REGISTRY=1; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"preflight_registry_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_docsdelta_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1788 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1; struct-field emit (EmitArgs { kind: "..." }) not det
- **Example:**

  ```bash
  grep '"kind":"preflight_docsdelta_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_elected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1317 #2373 GitHub Liaison election event from scripts/ops/github-liaison.sh; printf emit not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"liaison_elected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_heartbeat`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1317 #2373 GitHub Liaison heartbeat from scripts/ops/github-liaison.sh
- **Example:**

  ```bash
  grep '"kind":"liaison_heartbeat"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_takeover`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1317 #2373 GitHub Liaison takeover event
- **Example:**

  ```bash
  grep '"kind":"liaison_takeover"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_yielded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1317 #2373 GitHub Liaison yield event
- **Example:**

  ```bash
  grep '"kind":"liaison_yielded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=merge_queue_health`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: CREDIBLE-068 #2359 emitted from scripts/coord/monitor-merge-queue.sh via printf to ambient.jsonl; grep scanner does not see the shel
- **Example:**

  ```bash
  grep '"kind":"merge_queue_health"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=queue_health_check_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: CREDIBLE-068 #2359 same emit pattern as merge_queue_health (printf in monitor-merge-queue.sh, not grep-scannable)
- **Example:**

  ```bash
  grep '"kind":"queue_health_check_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=merge_preview_dirty`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned kind (no emitter yet); allowlist until emitter ships to unblock audit cluster
- **Example:**

  ```bash
  grep '"kind":"merge_preview_dirty"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_dup_archived`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted but not registered; allowlist while EVENT_REGISTRY entry is drafted
- **Example:**

  ```bash
  grep '"kind":"gap_dup_archived"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=operator_pr_action`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted but not registered; allowlist while EVENT_REGISTRY entry is drafted
- **Example:**

  ```bash
  grep '"kind":"operator_pr_action"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/git-hooks/pre-push (shell); not in PROD_PATHS scanned by coverage check
- **Example:**

  ```bash
  grep '"kind":"bot_merge_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pwa_brief_loaded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from web/v2/daily-brief.js via sendBeacon (JS not in PROD_PATHS); emit added in PRODUCT-078
- **Example:**

  ```bash
  grep '"kind":"pwa_brief_loaded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orchestrate_session_summary`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by INFRA-1363 src/orchestrate.rs; used as test fixture here while that PR is in flight
- **Example:**

  ```bash
  grep '"kind":"orchestrate_session_summary"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=chump_claim_force_recover`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted via escaped Rust format string in src/atomic_claim.rs (INFRA-1439); regex pattern miss
- **Example:**

  ```bash
  grep '"kind":"chump_claim_force_recover"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_doctor_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1427 emitted via positional arg `bash "$AMBIENT_EMIT" fleet_doctor_run` in scripts/coord/fleet-doctor-strict.sh; grep scanner 
- **Example:**

  ```bash
  grep '"kind":"fleet_doctor_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pwa_impact_viewed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from web/v2/impact.js via sendBeacon (JS, not in PROD_PATHS)
- **Example:**

  ```bash
  grep '"kind":"pwa_impact_viewed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pwa_gap_list_filtered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from web/v2/gap-list.js via sendBeacon (JS not in PROD_PATHS); emit added in PRODUCT-102
- **Example:**

  ```bash
  grep '"kind":"pwa_gap_list_filtered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_yml_row_add_merged`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/git/merge-driver-ci-yml-add-row.sh (shell); not in PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ci_yml_row_add_merged"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pre_commit_ac_test_missing`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-ac-completeness.sh (INFRA-1401); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"pre_commit_ac_test_missing"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=github_app_fallback`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/lib/github.sh _chump_gh_lane_token (INFRA-1076); helper function emit not grep-scannable as literal kind st
- **Example:**

  ```bash
  grep '"kind":"github_app_fallback"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=runner_migration_step`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1535 migration pipeline state-transition emit
- **Example:**

  ```bash
  grep '"kind":"runner_migration_step"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=runner_scaled`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1535 autoscale daemon scale-up/down emit
- **Example:**

  ```bash
  grep '"kind":"runner_scaled"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_hosted_runner_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1534 per-run completion (planned)
- **Example:**

  ```bash
  grep '"kind":"self_hosted_runner_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=merge_preview_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/coord/ (shell); not in PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"merge_preview_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=circuit_breaker_opened`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-011 emitted via Rust match-arm literal in src/circuit_breaker.rs:emit_state_change_event; grep scanner pattern `kind = "..
- **Example:**

  ```bash
  grep '"kind":"circuit_breaker_opened"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=circuit_breaker_closed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-011 same emit site as circuit_breaker_opened; match-arm literal not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"circuit_breaker_closed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=circuit_breaker_state_change`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-011 same emit site; catch-all match-arm `_ => "circuit_breaker_state_change"` not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"circuit_breaker_state_change"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_triage_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/coord/chump-pr-triage.sh (shell); not in PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"pr_triage_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_miss`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 pre-merge AC coverage gate; emitter scripts/ci/test-pr-ac-coverage.sh runs only in pr-hygiene job, outside PROD_PATHS gre
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_miss"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_waived`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 waiver trailer audit emit from same gate; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_waived"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_disabled`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 operator-override audit emit from same gate; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_disabled"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_no_gap_ref`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 pass-through marker for hotfix PRs without gap ref; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_no_gap_ref"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_no_ac`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 pass-through marker when gap has no AC bullets; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_no_ac"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_stuck_cycle_1_rebase_attempted`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1410 emitted via respawn_emit() helper in stale-pr-reaper.sh; variable-kind printf not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"pr_stuck_cycle_1_rebase_attempted"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_closed_for_respawn`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1410 emitted via respawn_emit() helper in stale-pr-reaper.sh; variable-kind printf not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"pr_auto_closed_for_respawn"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_stuck_exempt`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1410 emitted via respawn_emit() helper in stale-pr-reaper.sh; variable-kind printf not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"pr_stuck_exempt"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_tick`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 emitted from src/fleet_self_doctor.rs via EmitArgs{kind: "..".to_string()} struct-init form; grep pattern `kind = "X"` do
- **Example:**

  ```bash
  grep '"kind":"self_doctor_tick"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_healed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 same struct-init pattern as self_doctor_tick; emit-site not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"self_doctor_healed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 only fires on action failure (install error / execute-gap spawn error); rare path not exercised in PROD_PATHS smoke
- **Example:**

  ```bash
  grep '"kind":"self_doctor_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_budget_exceeded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 only fires under stress (>3 dispatches/10min); rare path not exercised in PROD_PATHS smoke
- **Example:**

  ```bash
  grep '"kind":"self_doctor_budget_exceeded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=chump_bin_resolved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: registered for INFRA-1618 active-fix flow; emit pending
- **Example:**

  ```bash
  grep '"kind":"chump_bin_resolved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_rescue_invoked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: registered for INFRA-1600 pr-rescue MVP; emit pending
- **Example:**

  ```bash
  grep '"kind":"pr_auto_rescue_invoked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lease_reaper_deleted`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: stale-lease-reaper telemetry (scripts/coord/), pre-existing
- **Example:**

  ```bash
  grep '"kind":"lease_reaper_deleted"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lease_reaper_dry_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: stale-lease-reaper telemetry (scripts/coord/), pre-existing
- **Example:**

  ```bash
  grep '"kind":"lease_reaper_dry_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lease_reaper_error`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: stale-lease-reaper telemetry (scripts/coord/), pre-existing
- **Example:**

  ```bash
  grep '"kind":"lease_reaper_error"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lease_reaper_skipped_active`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: stale-lease-reaper telemetry (scripts/coord/), pre-existing
- **Example:**

  ```bash
  grep '"kind":"lease_reaper_skipped_active"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lease_reaper_skipped_in_progress`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: stale-lease-reaper telemetry (scripts/coord/), pre-existing
- **Example:**

  ```bash
  grep '"kind":"lease_reaper_skipped_in_progress"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=lease_reaper_skipped_invalid`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: stale-lease-reaper telemetry (scripts/coord/), pre-existing
- **Example:**

  ```bash
  grep '"kind":"lease_reaper_skipped_invalid"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=reaper_self_paused`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: reaper telemetry, pre-existing
- **Example:**

  ```bash
  grep '"kind":"reaper_self_paused"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=restart`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: daemon-restart telemetry, pre-existing — too generic to register without scope
- **Example:**

  ```bash
  grep '"kind":"restart"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=prepush_test_timeout`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1744 emitted from scripts/git-hooks/pre-push timeout branch; printf-formatted from bash, not via emit_event helper
- **Example:**

  ```bash
  grep '"kind":"prepush_test_timeout"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=tool_auto_approved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1340 PRODUCT-109; emission wiring in follow-up gap
- **Example:**

  ```bash
  grep '"kind":"tool_auto_approved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=tool_approval_escalated`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1340 PRODUCT-109; emission wiring in follow-up gap
- **Example:**

  ```bash
  grep '"kind":"tool_approval_escalated"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=tool_approval_policy_changed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1340 PRODUCT-109; emission wiring in follow-up gap
- **Example:**

  ```bash
  grep '"kind":"tool_approval_policy_changed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=x`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1456 test-fixture placeholder ("x" used as kind in synthetic ambient.jsonl test inputs); not a production emit
- **Example:**

  ```bash
  grep '"kind":"x"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_envvars_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1787 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_ENVVARS=1; allowlist while EVENT_REGISTRY entry catches up (mirro
- **Example:**

  ```bash
  grep '"kind":"preflight_envvars_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_subcmdhelp_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1789 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_SUBCMDHELP=1; allowlist while EVENT_REGISTRY entry catches up (mi
- **Example:**

  ```bash
  grep '"kind":"preflight_subcmdhelp_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_acgate_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1791 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_ACGATE=1; allowlist while EVENT_REGISTRY entry catches up (mirror
- **Example:**

  ```bash
  grep '"kind":"preflight_acgate_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ast_crawler_unsupported_language`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1719 emitted from crates/ast-crawler when an unsupported language is encountered; emit site uses struct-field syntax not grep-
- **Example:**

  ```bash
  grep '"kind":"ast_crawler_unsupported_language"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=a2a_subscribe_stub_invoked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1758 stub diagnostic emitted from crates/chump-coord/src/events.rs::subscribe_events while real impl (NATS push consumer) is u
- **Example:**

  ```bash
  grep '"kind":"a2a_subscribe_stub_invoked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=a2a_rpc_stub_called`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1759 stub diagnostic emitted from crates/chump-coord/src/rpc.rs::call_rpc + serve_rpc while real impl (NATS subject routing) i
- **Example:**

  ```bash
  grep '"kind":"a2a_rpc_stub_called"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_fmt_applied`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1833 emitted from scripts/coord/chump-commit.sh when cargo fmt --all was run pre-commit (default path)
- **Example:**

  ```bash
  grep '"kind":"auto_fmt_applied"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_fmt_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1833 emitted from scripts/coord/chump-commit.sh when CHUMP_AUTO_FMT=0 disables the auto-fmt block
- **Example:**

  ```bash
  grep '"kind":"auto_fmt_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=chump_gap_set_legacy_delim`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1799 emitted from src/main.rs `chump gap set --acceptance-criteria` legacy delimiter path; struct-init form `kind: "X".to_stri
- **Example:**

  ```bash
  grep '"kind":"chump_gap_set_legacy_delim"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_gapsint_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1831 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_GAPSINT=1; allowlist while EVENT_REGISTRY entry catches up (mirro
- **Example:**

  ```bash
  grep '"kind":"preflight_gapsint_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cli`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"cli"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=crate`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"crate"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=mcp_tool`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"mcp_tool"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=skill`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"skill"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=capabilities_registry_refreshed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 emit site is `ambient-emit.sh "<kind>"` positional arg, not grep-scannable as a JSON `"kind":"X"` literal
- **Example:**

  ```bash
  grep '"kind":"capabilities_registry_refreshed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_envvar_applied`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1853 emitted from scripts/coord/chump-commit.sh when new CHUMP_* env refs were auto-appended to env-vars-internal.txt (default
- **Example:**

  ```bash
  grep '"kind":"auto_envvar_applied"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_envvar_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1853 emitted from scripts/coord/chump-commit.sh when CHUMP_AUTO_ENVVAR=0 disables the auto-append block
- **Example:**

  ```bash
  grep '"kind":"auto_envvar_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_auto_poll_surfaced`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1860 emitted by scripts/coord/inbox-poll.sh PostToolUse hook helper, ambient-emit positional-arg form not grep-scannable as ki
- **Example:**

  ```bash
  grep '"kind":"inbox_auto_poll_surfaced"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=audit_no_verify`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1834 emitted from chump-commit.sh + bot-merge.sh when --no-verify bypass used; reason field is operator-supplied, kind name st
- **Example:**

  ```bash
  grep '"kind":"audit_no_verify"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_cache_stale`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1874 emitted from scripts/coord/lib/github_cache.sh::cache_lookup_pr when age_s > CHUMP_LIAISON_CACHE_STALE_S (default 600); o
- **Example:**

  ```bash
  grep '"kind":"liaison_cache_stale"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=INFRA-1866 — audit-flake-catalog.sh CHUMP_AUDIT_FLAKE_CATALOG=0 opt-out`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** Ambient event kind emitted by the fleet for observability
- **Example:**

  ```bash
  grep '"kind":"INFRA-1866 — audit-flake-catalog.sh CHUMP_AUDIT_FLAKE_CATALOG=0 opt-out"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=flake_catalog_orphan`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1866 — audit-flake-catalog.sh orphan catalog entry
- **Example:**

  ```bash
  grep '"kind":"flake_catalog_orphan"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_session_derived`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1879 — emitted by scripts/coord/inbox-poll.sh on session-id derivation; positional-arg form
- **Example:**

  ```bash
  grep '"kind":"inbox_session_derived"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_webhook_unhealthy`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1875 emit at scripts/ops/github-liaison.sh _refresh_cycle when probe fails CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS times; _emit
- **Example:**

  ```bash
  grep '"kind":"liaison_webhook_unhealthy"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_polling_fallback_active`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1875 emit at scripts/ops/github-liaison.sh _refresh_cycle alongside liaison_webhook_unhealthy; same helper-not-scannable issue
- **Example:**

  ```bash
  grep '"kind":"liaison_polling_fallback_active"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_webhook_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1875 emit at scripts/ops/github-liaison.sh _refresh_cycle on first successful probe after fallback; same helper-not-scannable 
- **Example:**

  ```bash
  grep '"kind":"liaison_webhook_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_message_sent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1800 — emitted by scripts/coord/broadcast.sh after addressed-async DM delivery (META-061 opus-message v0 retarget)
- **Example:**

  ```bash
  grep '"kind":"opus_message_sent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_offline_mode_gated`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1876 — emitted by scripts/ops/github-liaison.sh when CHUMP_GITHUB_MODE=offline blocks daemon start; _emit_ambient helper form
- **Example:**

  ```bash
  grep '"kind":"liaison_offline_mode_gated"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_cache_offline_read`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1876 — emitted by scripts/coord/lib/github_cache.sh::_emit_offline_read_event when cache helpers run with CHUMP_GITHUB_MODE=of
- **Example:**

  ```bash
  grep '"kind":"liaison_cache_offline_read"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_mdlinks_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1790 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_MDLINKS=1; allowlist while EVENT_REGISTRY entry catches up (mirro
- **Example:**

  ```bash
  grep '"kind":"preflight_mdlinks_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=allowlist_stale_entry`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1868 — audit-allowlist-staleness.sh daily staleness detector; emitted via python3 heredoc, not grep-scannable as kind=X litera
- **Example:**

  ```bash
  grep '"kind":"allowlist_stale_entry"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=audit_allowlist_staleness_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1868 — audit-allowlist-staleness.sh skip-emit when CHUMP_AUDIT_ALLOWLIST_STALENESS=0; printf form not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"audit_allowlist_staleness_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_rearmed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1907 emitted by scripts/coord/pr-auto-rearm.sh safety-net sweeper when a BLOCKED+disarmed PR gets re-armed; printf-direct JSON
- **Example:**

  ```bash
  grep '"kind":"pr_auto_rearmed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=hidden_gems_refreshed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1727 — emitted by scripts/dev/build-hidden-gems.sh after rebuild; python3 heredoc write to ambient.jsonl, not grep-scannable a
- **Example:**

  ```bash
  grep '"kind":"hidden_gems_refreshed"' .chump-locks/ambient.jsonl
  ```

