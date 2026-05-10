# scripts/coord/ — Coordination Entry Points

All gap lifecycle, fleet coordination, and PR management scripts live here.
See [`scripts/README.md`](../README.md) for the broader taxonomy.

---

## Quick decision guide

| Goal | Use this |
|---|---|
| Claim a gap | `chump claim <ID>` (preferred) or `gap-claim.sh <ID>` |
| Check a gap is pickable | `gap-preflight.sh <ID>` |
| Commit work | `chump-commit.sh <files> -m "msg"` |
| Ship a gap | `bot-merge.sh --gap <ID> --auto-merge` |
| Watch a PR recover from DIRTY | `pr-watch.sh <PR#>` (or pr-watch-shepherd.sh automatically) |
| Repair gap store drift | `gap-doctor.py` (detect + patch) |
| Refill the gap queue automatically | `gap-gardener.py` (hourly cron) |
| Propose new gaps from docs | `gap-architect.py` (LLM sprint planner) |
| Glance at ambient stream | `chump-ambient-glance.sh` |
| Inject ambient context (CI/hook) | `ambient-context-inject.sh` |
| End a session + release lease | `ambient-session-end.sh` |

---

## gap-doctor vs gap-gardener vs gap-architect

These three are often confused because all three touch the gap store:

| Tool | Who runs it | When | What it does |
|---|---|---|---|
| **`gap-doctor.py`** | Agent or operator | On demand, after merge conflicts or import bugs | Detects and repairs drift between `state.db` and `docs/gaps/*.yaml`. Fixes mismatched status, double-encoded `depends_on`, ghost entries. Run when `chump gap list` shows stale data. |
| **`gap-doctor-all.sh`** | Operator or CI | After large batch imports | Wrapper that runs `gap-doctor.py` across all gaps and summarizes the repair log. |
| **`gap-gardener.py`** | Launchd cron (hourly) | When queue depth is low | Seeds new gaps from strategic docs when `open count < MIN_QUEUE_DEPTH`. Not for interactive use — it's an autonomous refill loop. |
| **`gap-architect.py`** | Agent or operator | When sprint planning | LLM-driven: reads roadmap/docs, calls Claude, generates 20+ concrete gaps. Use to bootstrap a new domain or after a synthesis. |

**Rule of thumb**: drift problems → `gap-doctor.py`, empty queue → `gap-gardener.py`, new batch → `gap-architect.py`.

---

## Full script reference

### Gap lifecycle

| Script | Purpose |
|---|---|
| `gap-claim.sh` | Write a lease file for a gap; called by `chump claim` |
| `gap-preflight.sh` | Check gap is open, unclaimed, no stale PR; exits 1 if blocked |
| `gap-reserve.sh` | Reserve a new gap ID (wrapper around `chump gap reserve`) |
| `gap-doctor.py` | Detect and repair state.db ↔ YAML drift |
| `gap-doctor-all.sh` | Run gap-doctor.py across all gaps |
| `gap-doctor-backfill-closed-pr.sh` | Backfill `closed_pr` field for gaps closed without `chump gap ship` |
| `gap-normalize-domains.sh` | Normalize domain prefix casing in gap IDs |
| `gap-store-prototype.sh` | Prototype new gap store features; not for production |
| `gap-gardener.py` | Hourly auto-filler when queue is sparse |
| `gap-architect.py` | LLM sprint planner; generates batches of new gaps from docs |
| `gap-doctor-reconcile.py` | Reconcile state.db with state.sql after merge conflicts |
| `check-gaps-integrity.py` | Read-only integrity audit (no mutations); good for CI spot checks |
| `resolve-gaps-conflict.py` | 3-way merge driver for `.chump/state.sql` conflicts |
| `close-gaps-from-commit-subjects.sh` | Parse merged PR commit subjects; auto-close matching gaps |
| `backfill-ghost-gaps.sh` | Find gaps whose PR merged but status is still `open`; batch-close |
| `ghost-gap-reaper.sh` | Delete lease files for sessions that no longer exist |

### Shipping and PRs

| Script | Purpose |
|---|---|
| `bot-merge.sh` | **Canonical ship pipeline**: fmt + clippy + push + PR + auto-merge + gap-ship-fatal |
| `chump-commit.sh` | Commit with cadence tracking; use instead of bare `git commit` |
| `check-spec-on-spec.sh` | Guard against arming auto-merge when a competing speculative PR is already armed (INFRA-684) |
| `pr-watch.sh` | Watch a PR, rebase + re-arm when it goes DIRTY after auto-merge armed |
| `pr-watch-shepherd.sh` | → moved to `scripts/coord/` from `scripts/ops/`; launchd-managed shepherd for all DIRTY-after-arm PRs |
| `archive-superseded-branch.sh` | Delete branches for closed/superseded PRs |
| `worktree-prune.sh` | Remove stale linked worktrees |
| `check-gap-status-flip.sh` | Detect when a gap flips from open→done without going through `chump gap ship` |
| `bounced-pr-detector.sh` | Find PRs that merged but left the gap in status:open |
| `_bounced_pr_classifier.py` | Helper: classify why a PR bounced (conflict/stale/other) |
| `pr-title-drift-detector.sh` | Alert when PR title diverges from gap title |
| `bot-shipped-audit.sh` | Audit which shipped PRs went through bot-merge.sh vs manual path |
| `bot-merge-run-timed.py` | Helper: run bot-merge with a timeout; used by orchestrate.rs |

### Ambient stream and observability

| Script | Purpose |
|---|---|
| `ambient-context-inject.sh` | SessionStart/PreToolUse hook: inject ambient digest as system context (FLEET-022) |
| `ambient-session-end.sh` | Stop hook: emit `session_end` + release lease |
| `chump-ambient-glance.sh` | Quick human-readable tail of the last N ambient events |
| `ci-failure-digest.sh` | Summarize recent CI failures for triage |
| `harvest-synthesis-lessons.sh` | Extract lessons from synthesis docs → `chump_improvement_targets` |
| `recurring-gap-pattern-detector.sh` | Detect gap domains or error classes that keep recurring |
| `log-chump-cli.sh` | Structured logging wrapper for `chump` CLI calls |

### Utility

| Script | Purpose |
|---|---|
| `broadcast.sh` | Send a message to all active sessions via ambient stream |
| `claude-retry.sh` | Retry `claude -p` with backoff on transient failures |
| `code-reviewer-agent.sh` | Run the code-reviewer subagent against a PR |
| `chump-decomposition-propose.sh` | Propose a decomposition of a large gap into sub-gaps |
| `demo-pr-worktree.sh` | Demo script for showing the worktree + PR flow |
| `ensure-chump-repo.sh` | Assert we are inside the Chump repo; abort otherwise |
| `musher.sh` / `musher.py` | Batch-apply a set of gap updates; rarely used |
| `queue-driver.sh` | Drive the gap pick loop (used by worker.sh in dispatch/) |
| `check-worktree-config.sh` | Verify worktree config.worktree is healthy (INFRA-810) |
