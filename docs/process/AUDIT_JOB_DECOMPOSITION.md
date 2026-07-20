# Audit-job preflight mirror decomposition (META-086)

Survey of every `scripts/ci/test-*.sh` invoked by the `audit-shard` matrix + the
`audit-required` tail in `.github/workflows/audit.yml` — this is "the audit job"
(moved out of `ci.yml` by INFRA-2452 to fix a self-cancelling-required-check
deadlock; see the header comment in `audit.yml`) — cross-referenced against
`src/preflight.rs` to find what still only runs in CI.

## Scope-discovery note

INFRA-1856 (closed 2026-05-23) estimated "~2 sub-checks". The META-086 filing
re-estimated "~20+ distinct test scripts". Neither guess survives contact with
the workflow: **the audit job is 120 distinct `test-*.sh` invocations**
(7 of which run identically in two shards — counted once here, under their
first shard), already sharded 4-way by INFRA-2565 (`audit-shard` matrix) plus
12 scripts still bolted onto `audit-required` as an unsharded serial tail. Of
the 120, **7 are already mirrored** in `src/preflight.rs`; **113 are unmirrored**.

This document also supersedes an earlier draft of the same survey that was
scoped against `ci.yml`'s `fast-checks` job — that job runs a *different* set
of scripts (fmt/JS-self-test/bash-guards). The sharded audit gates surveyed
below never moved back to `ci.yml`; disregard any prior reference to `ci.yml`'s
audit job.

| Metric | Count |
|---|---|
| Audit-job test scripts (`audit-shard` ×4 + `audit-required` tail, deduped) | 120 |
| Already mirrored in `src/preflight.rs` | 7 |
| Unmirrored | 113 |

## Clusters (mirrors `audit.yml`'s own shard grouping — INFRA-2565)

`audit.yml`'s header comment already documents the intended shard themes; this
survey uses those same boundaries so the preflight mirror gates line up 1:1
with the CI shard a script actually runs in (no reason to invent a different
grouping when the workflow already groups them coherently).

### Cluster 1 — `audit-shard(1)`: cargo/CLI gates (29 scripts, 29 unmirrored)

| Script | Mirrored? |
|---|---|
| test-api-gap-queue-shape.sh | no |
| test-cli-output-format.sh | no |
| test-cli-version-debug.sh | no |
| test-cross-pr-contract.sh | no |
| test-gap-add-note.sh | no |
| test-gap-audit-ac-open.sh | no |
| test-gap-consolidate.sh | no |
| test-gap-lifecycle-manager.sh | no |
| test-gap-list-domain-summary.sh | no |
| test-gap-list-done-format.sh | no |
| test-gap-list-since-json-schema.sh | no |
| test-gap-list-since.sh | no |
| test-gap-profiling.sh | no |
| test-gap-quality-gate.sh | no |
| test-gap-rebalance.sh | no |
| test-gap-run-now.sh | no |
| test-gap-show-ac-render.sh | no |
| test-gap-templates.sh | no |
| test-pillar-balance.sh | no |
| test-pwa-e2e-gap-workflow.sh | no |
| test-pwa-security.sh | no |
| test-release-lease-flag.sh | no |
| test-rollback-gap.sh | no |
| test-run-consolidation.sh | no |
| test-run-fleet-cross-repo.sh | no |
| test-state-db-restore.sh | no |
| test-tool-normalize.sh | no |
| test-uuid-gap-id-compat.sh | no |
| test-waste-tally-domain.sh | no |

### Cluster 2 — `audit-shard(2)`: event-registry + observability + cache/webhook telemetry (29 scripts, 27 unmirrored)

| Script | Mirrored? |
|---|---|
| test-agent-throughput.sh | no |
| test-alert-classifier.sh | no |
| test-audit-workflow-not-cancellable.sh | no |
| test-autonomous-ship-rate.sh | no |
| test-cache-event-emission.sh | no |
| test-cache-mergestatestatus.sh | no |
| test-ci-audit-loop.sh | no |
| test-cockpit-wake-fleet.sh | no |
| test-cost-enforcement.sh | no |
| test-credential-lifecycle.sh | no |
| test-error-path-coverage.sh | no |
| test-event-registry-audit-regression.sh | yes |
| test-event-registry-coverage.sh | yes |
| test-fleet-brief-pillar-table.sh | no |
| test-fleet-metrics-snapshot.sh | no |
| test-fleet-race-loss.sh | no |
| test-fleet-status-rate-limit.sh | no |
| test-gap-closure-consistency-fixture.sh | no |
| test-gap-impact-rating.sh | no |
| test-gap-workflow-status.sh | no |
| test-gh-shim-script-attribution.sh | no |
| test-graphql-debounce.sh | no |
| test-inbox-prune.sh | no |
| test-liaison-webhook-cache.sh | no |
| test-no-inline-ambient-printf.sh | no |
| test-pwa-version-compat.sh | no |
| test-pwa-workflow-observability.sh | no |
| test-triage-test-failure.sh | no |
| test-velocity-trending.sh | no |

### Cluster 3 — `audit-shard(3)`: bash/script gates — coordinator, worker, bot-merge, PWA, precommit (36 scripts, 33 unmirrored)

| Script | Mirrored? |
|---|---|
| test-auth-status.sh | no |
| test-bot-merge-exit-codes.sh | no |
| test-bot-merge-exit-phases.sh | no |
| test-bot-merge-graphql-preflight.sh | no |
| test-bot-merge-stacked-rebase.sh | no |
| test-bot-merge-watchdog.sh | no |
| test-ci-heavy-jobs-cross-platform.sh | no |
| test-curator-auto-decompose.sh | no |
| test-curator-decision-logging.sh | no |
| test-curator-freshness.sh | no |
| test-curator-p0-demotion.sh | no |
| test-curator-pillar-no-overlap.sh | no |
| test-fleet-bootstrap.sh | no |
| test-inbox-watcher-pattern.sh | no |
| test-install-gh-shim-worktree-safe.sh | no |
| test-known-flakes-gate.sh | no |
| test-lint-handoff-comment.sh | no |
| test-mission-picker-worker.sh | yes |
| test-mission-picker.sh | yes |
| test-no-manual-ship-bypass.sh | no |
| test-orphan-worktree-prune.sh | no |
| test-picker-priority.sh | no |
| test-pr-failure-auto-rescue.sh | no |
| test-pr-rescue-audit-handler.sh | no |
| test-precommit-strict-replay.sh | no |
| test-prepush-worktree-cd.sh | no |
| test-pwa-flake-quarantine.sh | no |
| test-required-model.sh | no |
| test-review-handoff-reengage.sh | no |
| test-stale-worktree-reaper-tmp.sh | no |
| test-worker-circuit-breaker.sh | no |
| test-worker-first-output-watchdog.sh | no |
| test-worker-timeout-no-commit.sh | no |
| test-worker-timeout-scale.sh | yes |
| test-worktree-prune-protects-live-edits.sh | no |
| test-worktree-show-toplevel.sh | no |

### Cluster 4 — `audit-shard(4)`: cross-PR contract gate + security + remaining guards (14 scripts, 12 unmirrored)

| Script | Mirrored? |
|---|---|
| test-bounced-pr-detector.sh | no |
| test-change-approval.sh | no |
| test-fleet-state-mutex.sh | no |
| test-gap-ac-requirement.sh | no |
| test-gh-api-probe.sh | no |
| test-jit-binary-refresh.sh | no |
| test-no-new-bypass-env-vars.sh | yes |
| test-no-raw-gh-in-hot-paths.sh | yes |
| test-orphan-pr-closer.sh | no |
| test-per-worktree-target-guard.sh | no |
| test-precommit-guard-audit.sh | no |
| test-rollup-cascade-cancel.sh | no |
| test-stale-binary-ship-blocked.sh | no |
| test-worktree-contamination-check.sh | no |

### Cluster 5 — `audit-required` tail: unsharded serial add-ons (12 scripts, 12 unmirrored)

| Script | Mirrored? |
|---|---|
| test-bot-merge-arm-ship-order.sh | no |
| test-cargo-mutex-isolation.sh | no |
| test-edit-replay.sh | no |
| test-infra-779-gitdir-repair.sh | no |
| test-known-flake-skip.sh | no |
| test-merge-driver-ci-yml-add-row.sh | no |
| test-operator-recovery.sh | no |
| test-pillar-balance-guard.sh | no |
| test-pillar-dashboard.sh | no |
| test-pr-scope-title-fallback.sh | no |
| test-pwa-auth-toast-stream.sh | no |
| test-ruleset-doc-only-pr.sh | no |

## Sub-gaps filed

Five sub-gaps covering this decomposition were **already open** (filed by
concurrent sessions working the same INFRA-1856/META-070 follow-up before this
survey landed — the `chump gap reserve` similarity gate flagged the overlap
when this session attempted to re-file, score 0.77 against INFRA-3354). Rather
than file duplicates, this survey adopts them as the 5 sub-gaps satisfying
META-086 AC #3. Each references a script list frozen at its own filing time;
re-derive the current per-cluster list from the tables above (several already
say to do this in their own AC — count drift here is expected, not a bug, and
the smoke test below will now catch future drift):

| Gap | Closest-fit cluster | Notes |
|---|---|---|
| INFRA-3363 | Cluster 1 (cargo/CLI gates) | filed as "29 scripts, cluster 1/5" — matches Cluster 1s count exactly |
| INFRA-3354 | Cluster 1 (overlap) | "gap-state-consistency (cluster A)", 19 `test-gap-*` scripts — subset of Cluster 1; reconcile with INFRA-3363 at claim time to avoid double-shipping the same preflight gates |
| INFRA-3362 | Cluster 2 / Cluster 3 (fleet-daemon/resilience) | "C4 fleet-daemon/resilience", 42 scripts at filing — spans fleet-telemetry (cluster 2) and worker/bot-merge (cluster 3); its own AC already directs `chump gap decompose` to re-slice, which fits a cross-cluster span |
| INFRA-3359 | Cluster 3 (bash/script gates) | "C1 doc/commit-hygiene", 21 scripts — closest to the precommit/lint-handoff/curator-decision-logging entries in Cluster 3 |
| INFRA-3367 | Cluster 5 (audit-required tail) | "12 unsharded serial scripts" — matches this doc's Cluster 5 exactly (12 scripts) |

## Self-closing

META-086 self-closes when the last of the 5 sub-gaps above ships.
