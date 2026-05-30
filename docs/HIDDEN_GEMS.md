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

### `ambient kind=INFRA-1866 — audit-flake-catalog.sh CHUMP_AUDIT_FLAKE_CATALOG=0 opt-out`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** Ambient event kind emitted by the fleet for observability
- **Example:**

  ```bash
  grep '"kind":"INFRA-1866 — audit-flake-catalog.sh CHUMP_AUDIT_FLAKE_CATALOG=0 opt-out"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=INFRA-1872 — emitted by scripts/ops/ci-qa-score.sh daily; rollup telemetry kind`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** Ambient event kind emitted by the fleet for observability
- **Example:**

  ```bash
  grep '"kind":"INFRA-1872 — emitted by scripts/ops/ci-qa-score.sh daily; rollup telemetry kind"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=a2a_rpc_stub_called`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1759 stub diagnostic emitted from crates/chump-coord/src/rpc.rs::call_rpc + serve_rpc while real impl (NATS subject routing) i
- **Example:**

  ```bash
  grep '"kind":"a2a_rpc_stub_called"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=a2a_subscribe_stub_invoked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1758 stub diagnostic emitted from crates/chump-coord/src/events.rs::subscribe_events while real impl (NATS push consumer) is u
- **Example:**

  ```bash
  grep '"kind":"a2a_subscribe_stub_invoked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_disabled`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 operator-override audit emit from same gate; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_disabled"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_miss`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 pre-merge AC coverage gate; emitter scripts/ci/test-pr-ac-coverage.sh runs only in pr-hygiene job, outside PROD_PATHS gre
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_miss"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_no_ac`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 pass-through marker when gap has no AC bullets; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_no_ac"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_no_gap_ref`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 pass-through marker for hotfix PRs without gap ref; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_no_gap_ref"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ac_coverage_waived`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1541 waiver trailer audit emit from same gate; outside PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ac_coverage_waived"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=allowlist_stale_entry`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1868 — audit-allowlist-staleness.sh daily staleness detector; emitted via python3 heredoc, not grep-scannable as kind=X litera
- **Example:**

  ```bash
  grep '"kind":"allowlist_stale_entry"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ast_crawler_unsupported_language`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1719 emitted from crates/ast-crawler when an unsupported language is encountered; emit site uses struct-field syntax not grep-
- **Example:**

  ```bash
  grep '"kind":"ast_crawler_unsupported_language"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=audit_allowlist_staleness_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1868 — audit-allowlist-staleness.sh skip-emit when CHUMP_AUDIT_ALLOWLIST_STALENESS=0; printf form not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"audit_allowlist_staleness_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=audit_no_verify`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1834 emitted from chump-commit.sh + bot-merge.sh when --no-verify bypass used; reason field is operator-supplied, kind name st
- **Example:**

  ```bash
  grep '"kind":"audit_no_verify"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=auto_capability_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1825 — capability-publish.sh CHUMP_AUTO_CAPABILITY=0 opt-out; printf-direct JSON not grep-scannable as kind=X literal
- **Example:**

  ```bash
  grep '"kind":"auto_capability_bypassed"' .chump-locks/ambient.jsonl
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

### `ambient kind=auto_merge_armed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for bot-merge.sh --auto-merge success confirmation
- **Example:**

  ```bash
  grep '"kind":"auto_merge_armed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_auto_armed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: duplicate of auto_merge_armed (harmonize on ship)
- **Example:**

  ```bash
  grep '"kind":"bot_merge_auto_armed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bot_merge_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/git-hooks/pre-push (shell); not in PROD_PATHS scanned by coverage check
- **Example:**

  ```bash
  grep '"kind":"bot_merge_bypassed"' .chump-locks/ambient.jsonl
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

### `ambient kind=bypass_threshold_breach`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1837 — emitted by scripts/ops/audit-bypass-frequency.sh from inside a python3 heredoc dict (per breaching session); kind liter
- **Example:**

  ```bash
  grep '"kind":"bypass_threshold_breach"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=capabilities_registry_refreshed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 emit site is `ambient-emit.sh "<kind>"` positional arg, not grep-scannable as a JSON `"kind":"X"` literal
- **Example:**

  ```bash
  grep '"kind":"capabilities_registry_refreshed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=capability_published`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1825 — capability-publish.sh after successful NATS KV publish
- **Example:**

  ```bash
  grep '"kind":"capability_published"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=chump_bin_resolved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: registered for INFRA-1618 active-fix flow; emit pending
- **Example:**

  ```bash
  grep '"kind":"chump_bin_resolved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=chump_claim_force_recover`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted via escaped Rust format string in src/atomic_claim.rs (INFRA-1439); regex pattern miss
- **Example:**

  ```bash
  grep '"kind":"chump_claim_force_recover"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=chump_gap_set_legacy_delim`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1799 emitted from src/main.rs `chump gap set --acceptance-criteria` legacy delimiter path; struct-init form `kind: "X".to_stri
- **Example:**

  ```bash
  grep '"kind":"chump_gap_set_legacy_delim"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_cascade_cancelled`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1870 emitted via _emit_ambient dict-payload in github-webhook-receiver.py workflow_run handler; dict-construction emit pattern
- **Example:**

  ```bash
  grep '"kind":"ci_cascade_cancelled"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_parity_drift`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/ci/test-preflight-ci-parity.sh (INFRA-1867); scripts/ci/ is outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"ci_parity_drift"' .chump-locks/ambient.jsonl
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

### `ambient kind=ci_yml_row_add_merged`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/git/merge-driver-ci-yml-add-row.sh (shell); not in PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"ci_yml_row_add_merged"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=circuit_breaker_closed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-011 same emit site as circuit_breaker_opened; match-arm literal not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"circuit_breaker_closed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=circuit_breaker_opened`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-011 emitted via Rust match-arm literal in src/circuit_breaker.rs:emit_state_change_event; grep scanner pattern `kind = "..
- **Example:**

  ```bash
  grep '"kind":"circuit_breaker_opened"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=circuit_breaker_state_change`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-011 same emit site; catch-all match-arm `_ => "circuit_breaker_state_change"` not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"circuit_breaker_state_change"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=claim_duplicate_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1442 #2358 emitted from src/atomic_claim.rs emit_claim_duplicate_bypassed; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"claim_duplicate_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=claim_duplicate_gap_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1970 emitted from src/atomic_claim.rs emit_claim_duplicate_gap_event when same gap_id claimed by two sessions; scanner-anchor 
- **Example:**

  ```bash
  grep '"kind":"claim_duplicate_gap_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=claim_duplicate_gap_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1970 bypass variant (CHUMP_CLAIM_ALLOW_DUPLICATE_GAP=1); same emit site as claim_duplicate_gap_blocked
- **Example:**

  ```bash
  grep '"kind":"claim_duplicate_gap_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cli`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"cli"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=commit`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by Claude Code PostToolUse hook (Bash git commit), not by scripts/; hooks are outside grep production paths
- **Example:**

  ```bash
  grep '"kind":"commit"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=crate`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"crate"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_decision`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for opus-curator gap-ranking decision emit
- **Example:**

  ```bash
  grep '"kind":"curator_decision"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=infra_watcher_finding`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-102 — emitted from scripts/coord/infra-watcher-loop.sh via direct printf JSON; emit uses dynamic {category,severity,detail} fie
- **Example:**

  ```bash
  grep '"kind":"infra_watcher_finding"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=disk_critical`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitter scripts/ops/disk-watchdog.sh uses variable-mediated emit (disk_alert_kind); grep pattern misses it; will fix in follow-up
- **Example:**

  ```bash
  grep '"kind":"disk_critical"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=external_collab_finding`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-104 emitted by scripts/coord/external-collab-loop.sh; categories: voice_drift | surface_stale | marcus_at_risk | partnership_st
- **Example:**

  ```bash
  grep '"kind":"external_collab_finding"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=external_collab_scope_override`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-104 emitted when CHUMP_EXTERNAL_COLLAB_SCOPE_OVERRIDE=1 bypasses lane guard
- **Example:**

  ```bash
  grep '"kind":"external_collab_scope_override"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fixture_commit_dropped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned by INFRA-1408 #2179 pre-push fixture detector; allow orphan until that PR lands
- **Example:**

  ```bash
  grep '"kind":"fixture_commit_dropped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=flake_catalog_orphan`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1866 — audit-flake-catalog.sh orphan catalog entry
- **Example:**

  ```bash
  grep '"kind":"flake_catalog_orphan"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_doctor_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1427 emitted via positional arg `bash "$AMBIENT_EMIT" fleet_doctor_run` in scripts/coord/fleet-doctor-strict.sh; grep scanner 
- **Example:**

  ```bash
  grep '"kind":"fleet_doctor_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_version_skew`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for fleet version drift detector
- **Example:**

  ```bash
  grep '"kind":"fleet_version_skew"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_dup_archived`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted but not registered; allowlist while EVENT_REGISTRY entry is drafted
- **Example:**

  ```bash
  grep '"kind":"gap_dup_archived"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_reserve_open_pr_scan_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1893 emitted from crates/chump-gap-store/src/lib.rs when scan fails AND gh smoke also fails — genuine auth failure telemetry; 
- **Example:**

  ```bash
  grep '"kind":"gap_reserve_open_pr_scan_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_reserve_open_pr_scan_inconsistent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1893 emitted from crates/chump-gap-store/src/lib.rs when scan fails but gh smoke (gh api user) returns 200 — spurious-401 fore
- **Example:**

  ```bash
  grep '"kind":"gap_reserve_open_pr_scan_inconsistent"' .chump-locks/ambient.jsonl
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

### `ambient kind=gap_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2055 — emitted by src/main.rs --execute-gap on every non-clean exit; scanner-anchor in execute_gap.rs
- **Example:**

  ```bash
  grep '"kind":"gap_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gap_deferred`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2055 — emitted by src/main.rs --execute-gap when agent explicitly defers; scanner-anchor in execute_gap.rs
- **Example:**

  ```bash
  grep '"kind":"gap_deferred"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=gh_shim_worktree_path_resolved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-779 gitdir repair confirmation
- **Example:**

  ```bash
  grep '"kind":"gh_shim_worktree_path_resolved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=github_app_fallback`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/lib/github.sh _chump_gh_lane_token (INFRA-1076); helper function emit not grep-scannable as literal kind st
- **Example:**

  ```bash
  grep '"kind":"github_app_fallback"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=handoff_lane_override`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1922 — emitted by scripts/coord/handoff-loop.sh only when operator sets CHUMP_HANDOFF_LANE_OVERRIDE=1 (rare cross-lane work pa
- **Example:**

  ```bash
  grep '"kind":"handoff_lane_override"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=hidden_gems_refreshed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1727 — emitted by scripts/dev/build-hidden-gems.sh after rebuild; python3 heredoc write to ambient.jsonl, not grep-scannable a
- **Example:**

  ```bash
  grep '"kind":"hidden_gems_refreshed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_auto_poll_surfaced`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1860 emitted by scripts/coord/inbox-poll.sh PostToolUse hook helper, ambient-emit positional-arg form not grep-scannable as ki
- **Example:**

  ```bash
  grep '"kind":"inbox_auto_poll_surfaced"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_session_derived`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1879 — emitted by scripts/coord/inbox-poll.sh on session-id derivation; positional-arg form
- **Example:**

  ```bash
  grep '"kind":"inbox_session_derived"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_test_fail`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/ci/test-system-integration.sh which is excluded from PROD_PATHS (CI scripts legitimately mention events without s
- **Example:**

  ```bash
  grep '"kind":"integration_test_fail"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_test_pass`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/ci/test-system-integration.sh which is excluded from PROD_PATHS (CI scripts legitimately mention events without s
- **Example:**

  ```bash
  grep '"kind":"integration_test_pass"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=keystone_cascade_fired`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1420 #2361 emitted from src/paramedic.rs action_keystone_cascade; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"keystone_cascade_fired"' .chump-locks/ambient.jsonl
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

### `ambient kind=liaison_cache_offline_read`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1876 — emitted by scripts/coord/lib/github_cache.sh::_emit_offline_read_event when cache helpers run with CHUMP_GITHUB_MODE=of
- **Example:**

  ```bash
  grep '"kind":"liaison_cache_offline_read"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_cache_stale`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1874 emitted from scripts/coord/lib/github_cache.sh::cache_lookup_pr when age_s > CHUMP_LIAISON_CACHE_STALE_S (default 600); o
- **Example:**

  ```bash
  grep '"kind":"liaison_cache_stale"' .chump-locks/ambient.jsonl
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

### `ambient kind=liaison_offline_mode_gated`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1876 — emitted by scripts/ops/github-liaison.sh when CHUMP_GITHUB_MODE=offline blocks daemon start; _emit_ambient helper form
- **Example:**

  ```bash
  grep '"kind":"liaison_offline_mode_gated"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_polling_fallback_active`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1875 emit at scripts/ops/github-liaison.sh _refresh_cycle alongside liaison_webhook_unhealthy; same helper-not-scannable issue
- **Example:**

  ```bash
  grep '"kind":"liaison_polling_fallback_active"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_takeover`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1317 #2373 GitHub Liaison takeover event
- **Example:**

  ```bash
  grep '"kind":"liaison_takeover"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_webhook_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1875 emit at scripts/ops/github-liaison.sh _refresh_cycle on first successful probe after fallback; same helper-not-scannable 
- **Example:**

  ```bash
  grep '"kind":"liaison_webhook_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_webhook_unhealthy`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1875 emit at scripts/ops/github-liaison.sh _refresh_cycle when probe fails CHUMP_LIAISON_WEBHOOK_HEALTH_MAX_FAILS times; _emit
- **Example:**

  ```bash
  grep '"kind":"liaison_webhook_unhealthy"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=liaison_yielded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1317 #2373 GitHub Liaison yield event
- **Example:**

  ```bash
  grep '"kind":"liaison_yielded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=mcp_tool`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"mcp_tool"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=merge_preview_dirty`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned kind (no emitter yet); allowlist until emitter ships to unblock audit cluster
- **Example:**

  ```bash
  grep '"kind":"merge_preview_dirty"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=merge_preview_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/coord/ (shell); not in PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"merge_preview_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=merge_queue_health`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: CREDIBLE-068 #2359 emitted from scripts/coord/monitor-merge-queue.sh via printf to ambient.jsonl; grep scanner does not see the shel
- **Example:**

  ```bash
  grep '"kind":"merge_queue_health"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=obs_coverage_test_fixture`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: synthetic test-fixture kind; emitter is scripts/ci/ (excluded from prod grep); status=test-fixture in registry
- **Example:**

  ```bash
  grep '"kind":"obs_coverage_test_fixture"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=operator_pr_action`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted but not registered; allowlist while EVENT_REGISTRY entry is drafted
- **Example:**

  ```bash
  grep '"kind":"operator_pr_action"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_message_sent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1800 — emitted by scripts/coord/broadcast.sh after addressed-async DM delivery (META-061 opus-message v0 retarget)
- **Example:**

  ```bash
  grep '"kind":"opus_message_sent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_shepherd_plan`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-091 — emitted by scripts/coord/opus-shepherd-triage.sh via python3 heredoc, not grep-scannable as kind=X literal
- **Example:**

  ```bash
  grep '"kind":"opus_shepherd_plan"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_shepherd_triage`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-091 — emitted by scripts/coord/opus-shepherd-triage.sh via python3 heredoc, not grep-scannable as kind=X literal
- **Example:**

  ```bash
  grep '"kind":"opus_shepherd_triage"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_shepherd_triage_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-091 — emitted by scripts/coord/opus-shepherd-triage.sh via python3 heredoc, not grep-scannable as kind=X literal
- **Example:**

  ```bash
  grep '"kind":"opus_shepherd_triage_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orchestrate_session_summary`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by INFRA-1363 src/orchestrate.rs; used as test fixture here while that PR is in flight
- **Example:**

  ```bash
  grep '"kind":"orchestrate_session_summary"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=picker_priority_stale`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for INFRA-1258 picker priority stale detection
- **Example:**

  ```bash
  grep '"kind":"picker_priority_stale"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_closed_for_respawn`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1410 emitted via respawn_emit() helper in stale-pr-reaper.sh; variable-kind printf not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"pr_auto_closed_for_respawn"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_rearmed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1907 emitted by scripts/coord/pr-auto-rearm.sh safety-net sweeper when a BLOCKED+disarmed PR gets re-armed; printf-direct JSON
- **Example:**

  ```bash
  grep '"kind":"pr_auto_rearmed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_rebase_fallback`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1958 emitted by scripts/coord/pr-auto-rebase.sh when gh pr update-branch returned false-positive but local git rebase succeede
- **Example:**

  ```bash
  grep '"kind":"pr_auto_rebase_fallback"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_auto_rescue_invoked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: registered for INFRA-1600 pr-rescue MVP; emit pending
- **Example:**

  ```bash
  grep '"kind":"pr_auto_rescue_invoked"' .chump-locks/ambient.jsonl
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

### `ambient kind=pr_stuck_cycle_1_rebase_attempted`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1410 emitted via respawn_emit() helper in stale-pr-reaper.sh; variable-kind printf not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"pr_stuck_cycle_1_rebase_attempted"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_stuck_exempt`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1410 emitted via respawn_emit() helper in stale-pr-reaper.sh; variable-kind printf not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"pr_stuck_exempt"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_triage_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from scripts/coord/chump-pr-triage.sh (shell); not in PROD_PATHS
- **Example:**

  ```bash
  grep '"kind":"pr_triage_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pre_commit_ac_test_missing`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-ac-completeness.sh (INFRA-1401); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"pre_commit_ac_test_missing"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_acgate_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1791 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_ACGATE=1; allowlist while EVENT_REGISTRY entry catches up (mirror
- **Example:**

  ```bash
  grep '"kind":"preflight_acgate_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_docsdelta_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1788 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_DOCSDELTA=1; struct-field emit (EmitArgs { kind: "..." }) not det
- **Example:**

  ```bash
  grep '"kind":"preflight_docsdelta_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_envvars_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1787 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_ENVVARS=1; allowlist while EVENT_REGISTRY entry catches up (mirro
- **Example:**

  ```bash
  grep '"kind":"preflight_envvars_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_gapsint_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1831 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_GAPSINT=1; allowlist while EVENT_REGISTRY entry catches up (mirro
- **Example:**

  ```bash
  grep '"kind":"preflight_gapsint_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_mdlinks_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1790 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_MDLINKS=1; allowlist while EVENT_REGISTRY entry catches up (mirro
- **Example:**

  ```bash
  grep '"kind":"preflight_mdlinks_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_registry_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1731 #2377 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_REGISTRY=1; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"preflight_registry_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_subcmdhelp_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1789 emitted from src/preflight.rs when CHUMP_PREFLIGHT_SKIP_SUBCMDHELP=1; allowlist while EVENT_REGISTRY entry catches up (mi
- **Example:**

  ```bash
  grep '"kind":"preflight_subcmdhelp_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=prepush_head_drift`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-push (INFRA-1372); git-hooks/ dir is outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"prepush_head_drift"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=prepush_test_timeout`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1744 emitted from scripts/git-hooks/pre-push timeout branch; printf-formatted from bash, not via emit_event helper
- **Example:**

  ```bash
  grep '"kind":"prepush_test_timeout"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pwa_brief_loaded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from web/v2/daily-brief.js via sendBeacon (JS not in PROD_PATHS); emit added in PRODUCT-078
- **Example:**

  ```bash
  grep '"kind":"pwa_brief_loaded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pwa_gap_list_filtered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from web/v2/gap-list.js via sendBeacon (JS not in PROD_PATHS); emit added in PRODUCT-102
- **Example:**

  ```bash
  grep '"kind":"pwa_gap_list_filtered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pwa_impact_viewed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted from web/v2/impact.js via sendBeacon (JS, not in PROD_PATHS)
- **Example:**

  ```bash
  grep '"kind":"pwa_impact_viewed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=queue_health_check_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: CREDIBLE-068 #2359 same emit pattern as merge_queue_health (printf in monitor-merge-queue.sh, not grep-scannable)
- **Example:**

  ```bash
  grep '"kind":"queue_health_check_failed"' .chump-locks/ambient.jsonl
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

### `ambient kind=reaper_self_paused`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: reaper telemetry, pre-existing
- **Example:**

  ```bash
  grep '"kind":"reaper_self_paused"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=redundancy_bypass_used`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-redundancy.sh (META-063); git hooks are outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"redundancy_bypass_used"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=restart`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: daemon-restart telemetry, pre-existing — too generic to register without scope
- **Example:**

  ```bash
  grep '"kind":"restart"' .chump-locks/ambient.jsonl
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

### `ambient kind=rust_first_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-rust-first.sh on the block path (INFRA-1448); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"rust_first_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=rust_first_bypass_audit`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/dev/rust-first-bypass-audit.sh (INFRA-1580); scripts/dev/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"rust_first_bypass_audit"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=rust_first_strict_blocked`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/git-hooks/pre-commit-rust-first.sh strict layer (INFRA-1580); git-hooks/ outside PROD_PATHS grep scan
- **Example:**

  ```bash
  grep '"kind":"rust_first_strict_blocked"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_budget_exceeded`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 only fires under stress (>3 dispatches/10min); rare path not exercised in PROD_PATHS smoke
- **Example:**

  ```bash
  grep '"kind":"self_doctor_budget_exceeded"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 only fires on action failure (install error / execute-gap spawn error); rare path not exercised in PROD_PATHS smoke
- **Example:**

  ```bash
  grep '"kind":"self_doctor_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_healed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 same struct-init pattern as self_doctor_tick; emit-site not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"self_doctor_healed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_doctor_tick`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1595 emitted from src/fleet_self_doctor.rs via EmitArgs{kind: "..".to_string()} struct-init form; grep pattern `kind = "X"` do
- **Example:**

  ```bash
  grep '"kind":"self_doctor_tick"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=self_hosted_runner_run`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1534 per-run completion (planned)
- **Example:**

  ```bash
  grep '"kind":"self_hosted_runner_run"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=skill`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1729 — JSON enum value for primitive.kind in build-capabilities-registry.sh, not an ambient kind
- **Example:**

  ```bash
  grep '"kind":"skill"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=stale_branch_auto_rebased`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1429 #2356 emitted from src/paramedic.rs action_rebase_dirty; allowlist while EVENT_REGISTRY entry catches up
- **Example:**

  ```bash
  grep '"kind":"stale_branch_auto_rebased"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=synthesis_gap_filed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: declared kind awaiting emitter (INFRA-1684 synthesis-truth audit wip); allowlist orphan to unblock audit cluster (#2337, et al.)
- **Example:**

  ```bash
  grep '"kind":"synthesis_gap_filed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=target_artifact_critical_reap`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1431 critical-mode variant; emitted via shell variable $_event_kind in target-dir-reaper.sh (not a grep-scannable literal); sa
- **Example:**

  ```bash
  grep '"kind":"target_artifact_critical_reap"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=target_artifact_reaped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1349 target/ artifact reaper kind; emitted when build dirs are cleaned under disk pressure
- **Example:**

  ```bash
  grep '"kind":"target_artifact_reaped"' .chump-locks/ambient.jsonl
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

### `ambient kind=tool_auto_approved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1340 PRODUCT-109; emission wiring in follow-up gap
- **Example:**

  ```bash
  grep '"kind":"tool_auto_approved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=watchdog_silent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: planned for watchdog heartbeat absence detector
- **Example:**

  ```bash
  grep '"kind":"watchdog_silent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=webhook_cache_write`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1873 emitted via _emit_ambient dict-payload in github-webhook-receiver.py (_upsert_pr + _upsert_check_runs call sites); dict-p
- **Example:**

  ```bash
  grep '"kind":"webhook_cache_write"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=observability_finding`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-103 emitted by scripts/coord/observability-loop.sh via printf in _emit_finding helper; structured payload {category,severity,ki
- **Example:**

  ```bash
  grep '"kind":"observability_finding"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=kind_that_fires`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-103 test-fixture synthetic kind used in scripts/ci/test-observability-loop.sh Test 1; not a production emit
- **Example:**

  ```bash
  grep '"kind":"kind_that_fires"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=kind_that_never_fires`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-103 test-fixture synthetic kind used in scripts/ci/test-observability-loop.sh Test 1; not a production emit
- **Example:**

  ```bash
  grep '"kind":"kind_that_never_fires"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=loud_detector`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-103 test-fixture synthetic kind used in scripts/ci/test-observability-loop.sh Test 5; not a production emit
- **Example:**

  ```bash
  grep '"kind":"loud_detector"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=noisy_kind`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-103 test-fixture synthetic kind used in scripts/ci/test-observability-loop.sh Test 2; not a production emit
- **Example:**

  ```bash
  grep '"kind":"noisy_kind"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=normal_kind`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-103 test-fixture synthetic kind used in scripts/ci/test-observability-loop.sh Test 4; not a production emit
- **Example:**

  ```bash
  grep '"kind":"normal_kind"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=x`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1456 test-fixture placeholder ("x" used as kind in synthetic ambient.jsonl test inputs); not a production emit
- **Example:**

  ```bash
  grep '"kind":"x"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_refresh_drift`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-088 — scripts/coord/oracle-refresh.sh emits on THE_PATH.md hash change; printf-direct JSON not grep-scannable as kind=X literal
- **Example:**

  ```bash
  grep '"kind":"oracle_refresh_drift"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_refresh_noop`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-088 — scripts/coord/oracle-refresh.sh emits on idempotent no-op (same hash); printf-direct JSON not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"oracle_refresh_noop"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_refresh_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-088 — scripts/coord/oracle-refresh.sh emits when claude CLI missing or burst empty; printf-direct JSON not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"oracle_refresh_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_refresh_pr_opened`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-088 — scripts/coord/oracle-refresh.sh emits after auto-PR opens; printf-direct JSON not grep-scannable
- **Example:**

  ```bash
  grep '"kind":"oracle_refresh_pr_opened"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_slot_dispatched`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-093 emitted by scripts/coord/opus-slot-tracker.sh dispatch subcommand via python3 heredoc; not grep-scannable as kind=X literal
- **Example:**

  ```bash
  grep '"kind":"opus_slot_dispatched"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=opus_slot_reaped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-093 emitted by scripts/coord/opus-slot-tracker.sh reap subcommand via python3 heredoc; not grep-scannable as kind=X literal in 
- **Example:**

  ```bash
  grep '"kind":"opus_slot_reaped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=required_check_health_warn`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1522 emitted by src/required_check_health.rs::emit_warn_for_unhealthy when chump fleet up/doctor finds flake>20% or skipped st
- **Example:**

  ```bash
  grep '"kind":"required_check_health_warn"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=required_check_health_bypass`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1522 emitted by src/required_check_health.rs::emit_bypass when operator passes --force to fleet up; audit trail for intentiona
- **Example:**

  ```bash
  grep '"kind":"required_check_health_bypass"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_failure_cluster`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1987 emitted by scripts/coord/cluster-detector.sh when ≥3 OPEN PRs share IDENTICAL failing-check set; printf-direct JSON not g
- **Example:**

  ```bash
  grep '"kind":"ci_failure_cluster"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_failure_cluster_resolved`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1987 emitted by scripts/coord/cluster-detector.sh when a previously-detected cluster_id disappears from BLOCKED PRs (resolutio
- **Example:**

  ```bash
  grep '"kind":"ci_failure_cluster_resolved"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=floor_temp`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1992 emitted by src/floor_temp.rs::emit_floor_temp on every chump health --temp invocation; carries COLD/WARM/HOT classificati
- **Example:**

  ```bash
  grep '"kind":"floor_temp"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=regression_attributed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1989 emitted by scripts/coord/blame-bot.sh when green→red CI transition is mapped to suspect commits via git log green..HEAD; 
- **Example:**

  ```bash
  grep '"kind":"regression_attributed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=regression_inattributable`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1989 emitted by scripts/coord/blame-bot.sh when no green baseline OR no commits in window OR mapped paths empty; printf-direct
- **Example:**

  ```bash
  grep '"kind":"regression_inattributable"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=hook_silent_passthrough`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1988 emitted by scripts/git-hooks/pre-push EXIT trap when main Guard 1/2/3 loop never entered on non-trivial push (the exact I
- **Example:**

  ```bash
  grep '"kind":"hook_silent_passthrough"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=admin_merge_forced`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-031 emitted by scripts/ops/admin-merge-cycle.sh _emit() via printf — emit site uses a # scanner-anchor comment (INFRA-1237
- **Example:**

  ```bash
  grep '"kind":"admin_merge_forced"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=operator_recovery_requested`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1993 emitted by scripts/coord/recovery-queue-emit.sh (worker-facing CLI) when a worker requests an admin-merge cycle for a PR 
- **Example:**

  ```bash
  grep '"kind":"operator_recovery_requested"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=operator_recovery_executed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1993 emitted by scripts/coord/recovery-queue-service.sh after each successful drop+merge+re-arm cycle with merged/failed PR li
- **Example:**

  ```bash
  grep '"kind":"operator_recovery_executed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=operator_recovery_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1993 emitted by scripts/coord/recovery-queue-service.sh on snapshot/drop/restore failure (CRITICAL when ruleset restore fails 
- **Example:**

  ```bash
  grep '"kind":"operator_recovery_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=recovery_queue_rate_limited`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1993 emitted by scripts/coord/recovery-queue-service.sh when 3-per-hour rate budget exhausted; deferred request waits for wind
- **Example:**

  ```bash
  grep '"kind":"recovery_queue_rate_limited"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=recovery_queue_paused`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1993 emitted when CHUMP_RECOVERY_QUEUE_PAUSE=1 disables the daemon
- **Example:**

  ```bash
  grep '"kind":"recovery_queue_paused"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wedge_remediation_requested`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1994 emitted by scripts/coord/wedge-state-machine.sh per-class remediation router; carries action + detail for operator/audit
- **Example:**

  ```bash
  grep '"kind":"wedge_remediation_requested"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wedge_remediation_rate_limited`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1994 emitted when same wedge_class fires within rate window (default 30min); deferred
- **Example:**

  ```bash
  grep '"kind":"wedge_remediation_rate_limited"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wedge_chronic`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-1994 emitted when same wedge_class fires ≥3x in 24h (default); escalation signal to file META gap for permanent fix
- **Example:**

  ```bash
  grep '"kind":"wedge_chronic"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=pr_oversight_snapshot`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emit-without-register surfaced 2026-05-25; emit site not yet wired into the audit scanner's PROD_PATHS; reserved while a follow-up g
- **Example:**

  ```bash
  grep '"kind":"pr_oversight_snapshot"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=subagent_idle_without_pr`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emit-without-register surfaced 2026-05-25 by INFRA-1987 strict-mode flip; emit logic exists in subagent watchdog but not in scanner'
- **Example:**

  ```bash
  grep '"kind":"subagent_idle_without_pr"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=preflight_ci_agreement`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: register-without-emit orphan from INFRA-1927 (#2537 area); emit site is gated by CHUMP_PREFLIGHT_CI_AGREEMENT env var so scanner rep
- **Example:**

  ```bash
  grep '"kind":"preflight_ci_agreement"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=voice_lint_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: register-without-emit orphan; voice-lint half-state class (critique H6 / INFRA-1975); kind is registered for the eventual policy dec
- **Example:**

  ```bash
  grep '"kind":"voice_lint_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=voice_lint_violation`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: register-without-emit orphan; same class as voice_lint_bypassed; reserved until INFRA-1975 voice-lint policy decision lands
- **Example:**

  ```bash
  grep '"kind":"voice_lint_violation"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_audit_heartbeat`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/ci-audit-loop.sh::heartbeat (per INFRA-1923 productization); printf-direct JSON not grep-scannable by PROD_
- **Example:**

  ```bash
  grep '"kind":"ci_audit_heartbeat"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ci_cluster_detected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/ci-audit-loop.sh::audit when ≥N PRs share failing-check set; same scanner-scope class as ci_audit_heartbeat
- **Example:**

  ```bash
  grep '"kind":"ci_cluster_detected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_injection_executed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2014 emitted by scripts/coord/inbox-injector.sh after tmux send-keys interrupt delivered to a recipient pane; carries urgency 
- **Example:**

  ```bash
  grep '"kind":"inbox_injection_executed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_injector_paused`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2014 emitted when CHUMP_INBOX_INJECTOR_PAUSE=1 disables daemon
- **Example:**

  ```bash
  grep '"kind":"inbox_injector_paused"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=md_links_heartbeat`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/md-links-loop.sh (scanner-anchor present); registered via RESILIENT-033
- **Example:**

  ```bash
  grep '"kind":"md_links_heartbeat"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=md_links_lane_override`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/md-links-loop.sh (scanner-anchor present); registered via RESILIENT-033
- **Example:**

  ```bash
  grep '"kind":"md_links_lane_override"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=md_links_scan_done`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: emitted by scripts/coord/md-links-loop.sh (scanner-anchor present); registered via RESILIENT-033
- **Example:**

  ```bash
  grep '"kind":"md_links_scan_done"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=urgent_broadcast`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2015 emitted by scripts/coord/broadcast.sh route_by_urgency() for WARN/CRIT/EMERGENCY tier; secondary ambient marker for 5-min
- **Example:**

  ```bash
  grep '"kind":"urgent_broadcast"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=urgent_broadcast_sent`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2016 emitted by scripts/coord/broadcast-urgent.sh when CRIT/EMERGENCY message written to .chump-locks/URGENT-INBOX.jsonl globa
- **Example:**

  ```bash
  grep '"kind":"urgent_broadcast_sent"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=inbox_urgent_surfaced`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2016 emitted by scripts/coord/inbox-check-urgent.sh after surfacing global-urgent messages as <system-reminder> via PostToolUs
- **Example:**

  ```bash
  grep '"kind":"inbox_urgent_surfaced"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=post_push_auto_close_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2026 emitted by scripts/coord/post-push-integrity-watch.sh when a chump/* PR is detected as auto-closed within 120s of a push 
- **Example:**

  ```bash
  grep '"kind":"post_push_auto_close_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=post_push_integrity_watch_ok`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2026 heartbeat from post-push-integrity-watch.sh when scan completes with no incidents
- **Example:**

  ```bash
  grep '"kind":"post_push_integrity_watch_ok"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=post_push_integrity_watch_err`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2026 emitted when daemon encounters a gh API or config error (gh_not_found, remote_parse_failed, gh_pr_list_failed)
- **Example:**

  ```bash
  grep '"kind":"post_push_integrity_watch_err"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=operator_recovery_aborted_recovered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2027 emitted by recovery-queue-service.sh when startup detects an orphaned in-flight checkpoint (age > 2× cycle interval) and 
- **Example:**

  ```bash
  grep '"kind":"operator_recovery_aborted_recovered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_stalled`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2013 emitted by scripts/dispatch/fleet-brief.sh when ships_1h==0 AND open BLOCKED PRs>=2; printf-direct JSON not grep-scannabl
- **Example:**

  ```bash
  grep '"kind":"fleet_stalled"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=worker_floor_signal_read`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2008 emitted by scripts/dispatch/worker.sh prelude before each claim cycle; carries signal=(fleet_hold|floor_temp), hold=0|1 o
- **Example:**

  ```bash
  grep '"kind":"worker_floor_signal_read"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=worker_stuck`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2029 emitted by scripts/dispatch/worker.sh _emit_worker_stuck helper in every exit-without-ship code path (stand_down, preflig
- **Example:**

  ```bash
  grep '"kind":"worker_stuck"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=daemon_silent_noop`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2009 emitted by scripts/coord/lib/silent-noop-guard.sh EXIT trap when a floor daemon (cluster_detector, wedge_state_machine, r
- **Example:**

  ```bash
  grep '"kind":"daemon_silent_noop"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cluster_detection_deferred_for_recovery`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2025 emitted by scripts/coord/cluster-detector.sh when recovery-cycle-in-flight.flag is present; prevents mis-classification o
- **Example:**

  ```bash
  grep '"kind":"cluster_detection_deferred_for_recovery"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wedge_remediated_real`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2030 emitted by scripts/coord/wedge-state-machine.sh _remediate_w002/_remediate_w007/_remediate_wagg after invoking a REAL rem
- **Example:**

  ```bash
  grep '"kind":"wedge_remediated_real"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cluster_detection_requested`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2030 emitted by scripts/coord/wedge-state-machine.sh _remediate_wagg when W-AGG fires; signals cluster-detector.sh to run its 
- **Example:**

  ```bash
  grep '"kind":"cluster_detection_requested"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=binary_main_updated`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2007 emitted by scripts/coord/bot-merge.sh after successful gap ship + merge; triggers binary-refresh-event-watcher.sh to rebu
- **Example:**

  ```bash
  grep '"kind":"binary_main_updated"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=binary_refresh_triggered_event`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2007 emitted by scripts/coord/binary-refresh-event-watcher.sh when binary_main_updated event triggers an immediate rebuild (ev
- **Example:**

  ```bash
  grep '"kind":"binary_refresh_triggered_event"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=binary_event_watcher_rate_limited`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2007 emitted by binary-refresh-event-watcher.sh when rebuild skipped because last rebuild was within CHUMP_BINARY_EVENT_RATE_L
- **Example:**

  ```bash
  grep '"kind":"binary_event_watcher_rate_limited"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=binary_event_watcher_no_tool`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2007 emitted by binary-refresh-event-watcher.sh when fswatch is absent; signals that polling fallback (tail -F) is active inst
- **Example:**

  ```bash
  grep '"kind":"binary_event_watcher_no_tool"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_daemon_action`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-109 emitted by scripts/coord/wizard-daemon.sh on every classification and decision; carries step, target, decision, rate_limit_
- **Example:**

  ```bash
  grep '"kind":"wizard_daemon_action"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_daemon_paused`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-109 emitted by scripts/coord/wizard-daemon.sh at startup when CHUMP_WIZARD_DAEMON_PAUSE=1 kill-switch is active; carries reason
- **Example:**

  ```bash
  grep '"kind":"wizard_daemon_paused"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_daemon_safety_refusal`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-109 emitted by scripts/coord/wizard-daemon.sh when a mandatory safety guard fires (floor_temp_HOT or pr_conflicting); carries r
- **Example:**

  ```bash
  grep '"kind":"wizard_daemon_safety_refusal"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=silent_fleet_death`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2040 emitted by scripts/coord/fleet-doctor-strict.sh and scripts/dispatch/fleet-brief.sh when last merge into origin/main is >
- **Example:**

  ```bash
  grep '"kind":"silent_fleet_death"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=silent_fleet_death_autohealed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2040 emitted by scripts/coord/fleet-doctor-strict.sh when CHUMP_DOCTOR_AUTOHEAL=1 and a daemon with exit=127 (command not foun
- **Example:**

  ```bash
  grep '"kind":"silent_fleet_death_autohealed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_dispatch_executed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-107 emitted by scripts/coord/wizard-daemon.sh step4 when chump --execute-gap <ID> is spawned in background; carries gap_id, pid
- **Example:**

  ```bash
  grep '"kind":"wizard_dispatch_executed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_dispatch_rate_limited`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-107 emitted by scripts/coord/wizard-daemon.sh step4 when active dispatch count >= CHUMP_WIZARD_MAX_PARALLEL; carries active_cou
- **Example:**

  ```bash
  grep '"kind":"wizard_dispatch_rate_limited"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_gap_skipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-107 emitted by scripts/coord/wizard-daemon.sh step4 when a gap has wizard_skip:true in its notes field; carries gap_id, reason;
- **Example:**

  ```bash
  grep '"kind":"wizard_gap_skipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_cascade_rebase_triggered`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-107 emitted by scripts/coord/wizard-daemon.sh step5 when gh pr update-branch succeeds for a BEHIND sibling PR after a gap_shipp
- **Example:**

  ```bash
  grep '"kind":"wizard_cascade_rebase_triggered"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_classify_deferred`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2042 emitted by scripts/coord/wizard-daemon.sh step1 when a PR's mergeStateStatus=UNKNOWN (GitHub hasn't computed mergeability
- **Example:**

  ```bash
  grep '"kind":"wizard_classify_deferred"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_dispatch_cooldown`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2051 emitted by scripts/coord/wizard-daemon.sh step4 when a gap is skipped because it had a FAILED dispatch within CHUMP_WIZAR
- **Example:**

  ```bash
  grep '"kind":"wizard_dispatch_cooldown"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=wizard_dispatch_giveup`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2051 emitted by scripts/coord/wizard-daemon.sh step4 when a gap hits >= CHUMP_WIZARD_MAX_DISPATCH_ATTEMPTS (default 3) FAILEDs
- **Example:**

  ```bash
  grep '"kind":"wizard_dispatch_giveup"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=off_rails_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-025 emitted by scripts/git-hooks/pre-commit when a commit bypasses the off-rails gap-ID check via 'Off-Rails-Bypass: <reas
- **Example:**

  ```bash
  grep '"kind":"off_rails_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=orphan_worktree_detected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: RESILIENT-026 emitted by scripts/coord/orphan-worktree-watchdog.sh when a /tmp/chump-* worktree has uncommitted/unpushed work + dead
- **Example:**

  ```bash
  grep '"kind":"orphan_worktree_detected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=freshness_critical_stale_bypassed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-115 emitted by scripts/coord/freshness-gate.sh when a CRITICAL_STALE classification (commits-behind > CHUMP_FRESHNESS_COMMITS_T
- **Example:**

  ```bash
  grep '"kind":"freshness_critical_stale_bypassed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=dispatch_hung_hook_detected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-116 emitted by scripts/coord/dispatch-health-check.sh when a git-commit or pre-commit child process exceeds CHUMP_DISPATCH_HUNG
- **Example:**

  ```bash
  grep '"kind":"dispatch_hung_hook_detected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=trunk_red_skip`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2096 emitted by scripts/ci/test-mcp-coord-smoke.sh (and future similar SKIP guards in scripts/ci/test-*.sh) when a CI smoke te
- **Example:**

  ```bash
  grep '"kind":"trunk_red_skip"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=autopilot_heartbeat`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-122 / META-090; emitted by scripts/coord/fleet-autopilot.sh cmd_heartbeat every 5 min via launchd cron; carries loaded/total da
- **Example:**

  ```bash
  grep '"kind":"autopilot_heartbeat"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_session_launched`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-122; emitted by fleet-autopilot.sh curator_spawn_one when a curator tmux window is newly created; carries role, session_id, loo
- **Example:**

  ```bash
  grep '"kind":"curator_session_launched"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_session_respawned`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-122; emitted by fleet-autopilot.sh curator_check_and_respawn (called from heartbeat) when a curator tmux window is found dead a
- **Example:**

  ```bash
  grep '"kind":"curator_session_respawned"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_sessions_stopped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-122; emitted by fleet-autopilot.sh cmd_stop_curators when the chump-curators tmux session is killed; carries tmux_session name.
- **Example:**

  ```bash
  grep '"kind":"curator_sessions_stopped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=curator_heartbeat`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: META-122; emitted by stub curator loop (for shepherd/target roles that lack a productized *-loop.sh yet) on each cadence tick; carri
- **Example:**

  ```bash
  grep '"kind":"curator_heartbeat"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=dispatch_flatline`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2101; emitted by scripts/ops/dispatch-flatline-detector.sh when sub_agent_dispatched count is 0 for a rolling window (default 
- **Example:**

  ```bash
  grep '"kind":"dispatch_flatline"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_refresh_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2122 emitted by scripts/coord/oracle-refresh.sh when claude -p exits non-zero (auth failures like "Not logged in" / OAuth chai
- **Example:**

  ```bash
  grep '"kind":"oracle_refresh_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_refresh_empty`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2122 emitted by scripts/coord/oracle-refresh.sh when claude -p exits 0 but returns empty/too-short output (distinguishes "mode
- **Example:**

  ```bash
  grep '"kind":"oracle_refresh_empty"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oracle_stale_despite_heartbeat`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2122 META-alarm — detector-for-the-detector. Emitted by scripts/coord/oracle-refresh.sh when THE_PATH.md mtime > CHUMP_ORACLE_
- **Example:**

  ```bash
  grep '"kind":"oracle_stale_despite_heartbeat"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oauth_token_refreshed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2124 emitted by scripts/coord/oauth-token-refresh.sh refresh-once on successful extraction of claudeAiOauth.accessToken from m
- **Example:**

  ```bash
  grep '"kind":"oauth_token_refreshed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oauth_token_refresh_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2124 emitted by scripts/coord/oauth-token-refresh.sh refresh-once on keychain miss, JSON parse fail, missing claudeAiOauth.acc
- **Example:**

  ```bash
  grep '"kind":"oauth_token_refresh_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=oauth_token_stale_despite_daemon`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2124 emitted by scripts/coord/infra-watcher-loop.sh cmd_check_oauth_freshness when ~/.chump/oauth-token.json is older than CHU
- **Example:**

  ```bash
  grep '"kind":"oauth_token_stale_despite_daemon"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=fleet_recorder_ttl_pruned`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2174 emitted by chump-fleet-recorder in-process TTL pruner task (fires every 60min) when it deletes events older than CHUMP_FL
- **Example:**

  ```bash
  grep '"kind":"fleet_recorder_ttl_pruned"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_cycle_started`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped — reserved so coverage gate stays green
- **Example:**

  ```bash
  grep '"kind":"integration_cycle_started"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_candidates_selected`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped.
- **Example:**

  ```bash
  grep '"kind":"integration_candidates_selected"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_cycle_merges`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; per-cycle AGGREGATE kind (observability-curator amendment replacing per-merge fanout); registered in EVENT_RE
- **Example:**

  ```bash
  grep '"kind":"integration_cycle_merges"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_preflight_started`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped.
- **Example:**

  ```bash
  grep '"kind":"integration_preflight_started"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_preflight_failed`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped.
- **Example:**

  ```bash
  grep '"kind":"integration_preflight_failed"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=ship_bisect_root_cause`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped.
- **Example:**

  ```bash
  grep '"kind":"ship_bisect_root_cause"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=bisect_quarantine`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped.
- **Example:**

  ```bash
  grep '"kind":"bisect_quarantine"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=integration_cycle_shipped`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped; related_kinds: [pr_merged] cross-ref s
- **Example:**

  ```bash
  grep '"kind":"integration_cycle_shipped"' .chump-locks/ambient.jsonl
  ```

### `ambient kind=cycle_sampling_decision`

- **Where:** `scripts/ci/event-registry-reserved.txt`
- **When to use:** reason: INFRA-2132 / META-124 Phase 2 marker; registered in EVENT_REGISTRY.yaml; emitter INFRA-2130 not yet shipped.
- **Example:**

  ```bash
  grep '"kind":"cycle_sampling_decision"' .chump-locks/ambient.jsonl
  ```

---

_Last refreshed: 2026-05-29_

