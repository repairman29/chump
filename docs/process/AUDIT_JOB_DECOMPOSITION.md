# Audit-job (fast-checks) Preflight Decomposition Survey

> META-086: INFRA-1856 closed 2026-05-23 after scope discovery — the CI
> gate referred to as the "audit job" is not 2 sub-checks, it is the
> `fast-checks` job in `.github/workflows/ci.yml` (the literal `audit:`
> job name from filing time no longer exists — renamed/merged since).
> This doc surveys every `scripts/ci/*.sh` invocation in that job (116
> total) and its mirror status in `src/preflight.rs`.

## Method

```bash
sed -n '629,1172p' .github/workflows/ci.yml | grep -oE 'scripts/ci/[a-zA-Z0-9_-]+\.sh' | sort -u
```
Cross-referenced against `grep -n 'test-' src/preflight.rs` for mirror status.
Kept honest by `scripts/ci/test-audit-job-decomposition.sh` (AC #5).

## Full inventory

| Script | Mirrored in preflight.rs | Cluster | Purpose |
|---|---|---|---|
| `check-release-staleness.sh` | no | cli-product-acceptance | check-release-staleness.sh — INFRA-1373 |
| `coord-surfaces-smoke.sh` | no | cli-product-acceptance | INFRA-032: verify gap coordination + chump --briefing from repo root without API keys. |
| `test-ambient-schema.sh` | no | observability-fleet-signals | INFRA-101: regression test for the ambient-emit schema validator. |
| `test-attribution-portable.sh` | no | commit-content-guards | test-attribution-portable.sh — CREDIBLE-045: verify generic agent attribution |
| `test-auto-arm-sweeper.sh` | no | observability-fleet-signals | INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374). |
| `test-autoscale-decisions.sh` | no | observability-fleet-signals | scripts/ci/test-autoscale-decisions.sh — INFRA-1581 |
| `test-book-sync-guard.sh` | no | commit-content-guards | INFRA-170: tests for the book/src ↔ docs/process sync guard in |
| `test-bot-merge-auto-close.sh` | no | pr-lifecycle-bot-merge | INFRA-154 / INFRA-228 / INFRA-229: smoke-test the auto-close handshake |
| `test-bot-merge-conflict-wiring.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-bot-merge-conflict-wiring.sh — INFRA-1657 |
| `test-cargo-target-reaper.sh` | no | observability-fleet-signals | test-cargo-target-reaper.sh — INFRA-1250 |
| `test-changes-job-self-hosted.sh` | no | cli-product-acceptance | scripts/ci/test-changes-job-self-hosted.sh — INFRA-1537 |
| `test-chump-improve.sh` | no | cli-product-acceptance | EFFECTIVE-177: Integration test for `chump improve <owner/repo>`. |
| `test-chump-repos.sh` | yes | — | test-chump-repos.sh — MISSION-033 |
| `test-chump-subcommand-help.sh` | yes | — | scripts/ci/test-chump-subcommand-help.sh — INFRA-1238 (also referenced by INFRA-1246) |
| `test-ci-flake-rerun.sh` | no | cli-product-acceptance | test-ci-flake-rerun.sh — INFRA-375 smoke test. |
| `test-claim-fuzzy-match.sh` | no | cli-product-acceptance | scripts/ci/test-claim-fuzzy-match.sh — INFRA-1442 |
| `test-claude-reaper.sh` | no | observability-fleet-signals | test-claude-reaper.sh — INFRA-1662 |
| `test-cli-fleet-coord.sh` | no | cli-product-acceptance | test-cli-fleet-coord.sh — CREDIBLE-035 |
| `test-cli-help.sh` | no | cli-product-acceptance | CREDIBLE-015: CLI help system consistency gate. |
| `test-cli-integration.sh` | no | cli-product-acceptance | scripts/ci/test-cli-integration.sh |
| `test-cli-version-debug.sh` | no | cli-product-acceptance | scripts/ci/test-cli-version-debug.sh — CREDIBLE-019 |
| `test-conflict-resolver.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-conflict-resolver.sh — INFRA-1488 (Marcus M-C) |
| `test-credential-pattern-guard.sh` | no | commit-content-guards | INFRA-158: regression test for the credential-pattern pre-commit guard |
| `test-cross-judge-guard.sh` | no | commit-content-guards | INFRA-079: tests for the cross-judge audit guard. |
| `test-css-token-discipline.sh` | no | commit-content-guards | test-css-token-discipline.sh — CI smoke test for INFRA-1590 |
| `test-default-flip-guard.sh` | no | commit-content-guards | test-default-flip-guard.sh — INFRA-762 unit tests. |
| `test-deliberator-tick-emits.sh` | no | observability-fleet-signals | RESILIENT-061 AC #4: test-deliberator-tick-emits.sh |
| `test-doc-freshness.sh` | no | commit-content-guards | test-doc-freshness.sh — DOC-041 |
| `test-docs-delta-commit-msg.sh` | no | commit-content-guards | test-docs-delta-commit-msg.sh — INFRA-1969 regression test. |
| `test-docs-delta-guard.sh` | no | commit-content-guards | INFRA-158: regression test for the docs-delta pre-commit guard |
| `test-effective-010-completion.sh` | no | cli-product-acceptance | test-effective-010-completion.sh — EFFECTIVE-010 |
| `test-env-var-coverage.sh` | yes | — | Asserts that every env var read by Chump's Rust source is either: |
| `test-external-verify-merge.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-external-verify-merge.sh |
| `test-farmer.sh` | yes | — | test-farmer.sh — RESILIENT-068: unit tests for scripts/coord/farmer.sh |
| `test-flake-autorerun.sh` | no | cli-product-acceptance | test-flake-autorerun.sh — INFRA-764 unit tests for cargo-test-with-rerun.sh. |
| `test-fleet-brief.sh` | no | observability-fleet-signals | capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CRE |
| `test-fleet-fanout.sh` | no | observability-fleet-signals | scripts/ci/test-fleet-fanout.sh — INFRA-1484 (Marcus M-B continuation) |
| `test-fleet-kill-switch.sh` | no | observability-fleet-signals | scripts/ci/test-fleet-kill-switch.sh — RESILIENT-073 |
| `test-fleet-pause-autolift.sh` | yes | — | test-fleet-pause-autolift.sh — RESILIENT-066 |
| `test-fleet-spec.sh` | no | observability-fleet-signals | scripts/ci/test-fleet-spec.sh — INFRA-1483 (Marcus M-B) |
| `test-fleet-starve-auto-action.sh` | no | observability-fleet-signals | test-fleet-starve-auto-action.sh — INFRA-391 regression test. |
| `test-gap-divergence-guard.sh` | no | gap-state-consistency | test-gap-divergence-guard.sh — INFRA-783 fixture tests. |
| `test-gap-doctor-safe-sweep.sh` | no | gap-state-consistency | test-gap-doctor-safe-sweep.sh — INFRA-308 regression test. |
| `test-gap-id-cross-session.sh` | no | gap-state-consistency | test-gap-id-cross-session.sh — CREDIBLE-052 |
| `test-gap-id-lease-uniqueness.sh` | no | gap-state-consistency | test-gap-id-lease-uniqueness.sh — INFRA-1970 |
| `test-gap-preflight-ac-gate.sh` | yes | — | INFRA-1259: verify chump claim rejects gaps with empty/TODO-only acceptance_criteria |
| `test-gap-reserve-concurrency.sh` | no | gap-state-consistency | Spawns parallel gap-reserve.sh INFRA calls with distinct CHUMP_SESSION_ID values |
| `test-gap-reserve-padding.sh` | no | gap-state-consistency | INFRA-080: regression — gap-reserve.sh must zero-pad the new ID to the |
| `test-gap-status-flip.sh` | no | gap-state-consistency | INFRA-158: regression test for the gap-status-check workflow guard |
| `test-gate-promotion-no-regression.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-gate-promotion-no-regression.sh — INFRA-1869 |
| `test-git-identity-guard.sh` | no | commit-content-guards | test-git-identity-guard.sh — INFRA-787 fixture tests. |
| `test-hardcoded-date-guard.sh` | no | commit-content-guards | test-hardcoded-date-guard.sh — INFRA-971 |
| `test-infra-1025-atomic-claim.sh` | no | gap-state-consistency | test-infra-1025-atomic-claim.sh — INFRA-1025 |
| `test-infra-109-worktree-boundary.sh` | no | gap-state-consistency | test-infra-109-worktree-boundary.sh — INFRA-109 regression test. |
| `test-infra-115-lease-ttl-file.sh` | no | gap-state-consistency | INFRA-115: regression test for the file-based lease TTL reaper in |
| `test-infra-119-bot-merge-hang.sh` | no | pr-lifecycle-bot-merge | INFRA-119 — verify queue-health-monitor.sh detects stale bot-merge health files. |
| `test-infra-124-docs-delta-trailer.sh` | no | commit-content-guards | test-infra-124-docs-delta-trailer.sh — INFRA-124 regression test. |
| `test-infra-250-v1-retirement.sh` | no | cli-product-acceptance | CI acceptance test for INFRA-250: PWA v1 retirement. |
| `test-infra-254-pwa-root-redirect.sh` | no | cli-product-acceptance | INFRA-254: GET / on the PWA must 301-redirect to /v2/. |
| `test-infra-257-doc-only-guards.sh` | no | commit-content-guards | test-infra-257-doc-only-guards.sh — INFRA-257 regression test. |
| `test-infra-258-reaper-partial-delivery.sh` | no | pr-lifecycle-bot-merge | test-infra-258-reaper-partial-delivery.sh — INFRA-258 regression test. |
| `test-inspect-resume-scrap.sh` | no | cli-product-acceptance | scripts/ci/test-inspect-resume-scrap.sh — INFRA-1456 (eject-and-inspect) |
| `test-install-ambient-hooks.sh` | no | observability-fleet-signals | test-install-ambient-hooks.sh — FLEET-023 regression tests for the |
| `test-install-pr-auto-rebase.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-install-pr-auto-rebase.sh — INFRA-1779 |
| `test-keystone-cascade.sh` | no | cli-product-acceptance | scripts/ci/test-keystone-cascade.sh — INFRA-1420 |
| `test-markdown-intra-doc-links.sh` | yes | — | test-markdown-intra-doc-links.sh — DOC-039 |
| `test-mcp-coord-smoke.sh` | no | cli-product-acceptance | INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys. |
| `test-md-links-loop.sh` | no | observability-fleet-signals | test-md-links-loop.sh — INFRA-1925: smoke test for scripts/coord/md-links-loop.sh. |
| `test-merge-driver-ci-yml.sh` | no | pr-lifecycle-bot-merge | test-merge-driver-ci-yml.sh — INFRA-310 |
| `test-merge-driver-pre-commit.sh` | no | pr-lifecycle-bot-merge | test-merge-driver-pre-commit.sh — INFRA-310 |
| `test-merge-driver-state-sql.sh` | no | gap-state-consistency | test-merge-driver-state-sql.sh — INFRA-310 |
| `test-merged-check-guard.sh` | yes | — | test-merged-check-guard.sh — INFRA-306 regression test. |
| `test-meta-011-git-stomp.sh` | no | gap-state-consistency | META-011: regression test for concurrent chump-commit.sh calls on a shared |
| `test-migration-pipeline-gates.sh` | no | observability-fleet-signals | scripts/ci/test-migration-pipeline-gates.sh — INFRA-1581 (closes INFRA-1538) |
| `test-model-registry.sh` | no | observability-fleet-signals | test-model-registry.sh — INFRA-739 |
| `test-no-claude-leak.sh` | no | commit-content-guards | test-no-claude-leak.sh — INFRA-1051 |
| `test-no-verify-audit.sh` | no | commit-content-guards | scripts/ci/test-no-verify-audit.sh — INFRA-1834 |
| `test-obs-coverage-guard.sh` | no | observability-fleet-signals | test-obs-coverage-guard.sh — INFRA-757 |
| `test-observability-coverage.sh` | no | observability-fleet-signals | test-observability-coverage.sh — INFRA-757 |
| `test-open-pr-dup-detection.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-open-pr-dup-detection.sh — INFRA-1982 |
| `test-orchestrate-session-summary.sh` | no | cli-product-acceptance | scripts/ci/test-orchestrate-session-summary.sh — INFRA-1363 |
| `test-pick-and-claim-lockdir.sh` | no | gap-state-consistency | test-pick-and-claim-lockdir.sh — INFRA-467 |
| `test-pipefail-race-sweep.sh` | yes | — | scripts/ci/test-pipefail-race-sweep.sh — INFRA-1658 |
| `test-pr-auto-rebase.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-pr-auto-rebase.sh — INFRA-1777 |
| `test-pr-blocked-watch.sh` | no | pr-lifecycle-bot-merge | test-pr-blocked-watch.sh — INFRA-550 smoke test. |
| `test-pr-explain-block.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-pr-explain-block.sh — INFRA-1416 |
| `test-pr-terminal-state.sh` | no | pr-lifecycle-bot-merge | test-pr-terminal-state.sh — INFRA-1981 regression test (M3 critique fix). |
| `test-pr-triage-bot.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-pr-triage-bot.sh — INFRA-624 |
| `test-pr-watch-auto-resolve.sh` | no | pr-lifecycle-bot-merge | test-pr-watch-auto-resolve.sh — INFRA-387 unit test for the |
| `test-pr-watch-shepherd-smoke.sh` | no | pr-lifecycle-bot-merge | test-pr-watch-shepherd-smoke.sh — INFRA-354 smoke test. |
| `test-pre-push-force-lease-guard.sh` | no | gap-state-consistency | test-pre-push-force-lease-guard.sh — INFRA-345 regression test. |
| `test-pre-push-preflight-hook.sh` | no | commit-content-guards | scripts/ci/test-pre-push-preflight-hook.sh — INFRA-1671 regression test. |
| `test-pre-push-rebase-allow.sh` | no | pr-lifecycle-bot-merge | test-pre-push-rebase-allow.sh — INFRA-368 regression test. |
| `test-pre-push-test-gate.sh` | no | pr-lifecycle-bot-merge | test-pre-push-test-gate.sh — INFRA-761 regression tests. |
| `test-preflight-ci-parity.sh` | no | commit-content-guards | test-preflight-ci-parity.sh — INFRA-1867 (INFRA-1861 slice b) — widened META-268 |
| `test-prereg-content-guard.sh` | no | commit-content-guards | INFRA-113: tests for the preregistration content checker |
| `test-raw-yaml-guard.sh` | no | commit-content-guards | INFRA-499: raw-YAML-edit guard removed in PR #1148. |
| `test-rebase-coordination.sh` | no | pr-lifecycle-bot-merge | test-rebase-coordination.sh — INFRA-1974 (H5) regression test. |
| `test-research-026-preflight.sh` | no | cli-product-acceptance | CI-safe preflight for RESEARCH-026 harness + fixtures (no API calls). |
| `test-review-handoff-smoke.sh` | no | pr-lifecycle-bot-merge | test-review-handoff-smoke.sh — INFRA-774 |
| `test-rollup-semantic.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-rollup-semantic.sh — INFRA-1455 (Marcus M-B converge) |
| `test-run-fleet-cross-repo.sh` | no | cli-product-acceptance | test-run-fleet-cross-repo.sh — INFRA-634 cross-repo fleet flags |
| `test-sandbox-isolation.sh` | no | cli-product-acceptance | capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CRE |
| `test-schema-version-assert.sh` | no | observability-fleet-signals | scripts/ci/test-schema-version-assert.sh — INFRA-1978 |
| `test-self-hosted-runner-deps.sh` | no | cli-product-acceptance | test-self-hosted-runner-deps.sh — INFRA-1556 |
| `test-speculative-on-speculative-guard.sh` | no | pr-lifecycle-bot-merge | test-speculative-on-speculative-guard.sh — INFRA-684 CI gate. |
| `test-spike-isolation.sh` | no | cli-product-acceptance | test-spike-isolation.sh — INFRA-430 regression test. |
| `test-stale-branch-rebase.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-stale-branch-rebase.sh — INFRA-1429 |
| `test-stale-pr-rebase-bot.sh` | yes | — | scripts/ci/test-stale-pr-rebase-bot.sh — INFRA-2295 |
| `test-stale-process-watchdog.sh` | no | observability-fleet-signals | test-stale-process-watchdog.sh — INFRA-1663 |
| `test-status-flip-proof-of-merge.sh` | no | pr-lifecycle-bot-merge | scripts/ci/test-status-flip-proof-of-merge.sh — INFRA-1392 |
| `test-subagent-budget-kill.sh` | no | commit-content-guards | test-subagent-budget-kill.sh — INFRA-1972 (H3) structural regression test. |
| `test-subagent-epilogue-ref.sh` | no | commit-content-guards | test-subagent-epilogue-ref.sh — INFRA-332 |
| `test-submodule-guard.sh` | no | commit-content-guards | INFRA-158: regression test for the submodule-sanity pre-commit guard |
| `test-supervision-trees.sh` | no | observability-fleet-signals | test-supervision-trees.sh — RESILIENT-058 regression test |
| `test-worktree-reaper-safety.sh` | no | gap-state-consistency | test-worktree-reaper-safety.sh — INFRA-1074 |

## Clusters (unmirrored scripts grouped for follow-up sub-gaps)

### gap-state-consistency (INFRA-3374)

15 scripts. See INFRA-3374 for AC + ship target.

- `test-gap-divergence-guard.sh`
- `test-gap-doctor-safe-sweep.sh`
- `test-gap-id-cross-session.sh`
- `test-gap-id-lease-uniqueness.sh`
- `test-gap-reserve-concurrency.sh`
- `test-gap-reserve-padding.sh`
- `test-gap-status-flip.sh`
- `test-infra-1025-atomic-claim.sh`
- `test-infra-109-worktree-boundary.sh`
- `test-infra-115-lease-ttl-file.sh`
- `test-merge-driver-state-sql.sh`
- `test-meta-011-git-stomp.sh`
- `test-pick-and-claim-lockdir.sh`
- `test-pre-push-force-lease-guard.sh`
- `test-worktree-reaper-safety.sh`

### pr-lifecycle-bot-merge (INFRA-3375)

26 scripts. See INFRA-3375 for AC + ship target.

- `test-bot-merge-auto-close.sh`
- `test-bot-merge-conflict-wiring.sh`
- `test-conflict-resolver.sh`
- `test-external-verify-merge.sh`
- `test-gate-promotion-no-regression.sh`
- `test-infra-119-bot-merge-hang.sh`
- `test-infra-258-reaper-partial-delivery.sh`
- `test-install-pr-auto-rebase.sh`
- `test-merge-driver-ci-yml.sh`
- `test-merge-driver-pre-commit.sh`
- `test-open-pr-dup-detection.sh`
- `test-pr-auto-rebase.sh`
- `test-pr-blocked-watch.sh`
- `test-pr-explain-block.sh`
- `test-pr-terminal-state.sh`
- `test-pr-triage-bot.sh`
- `test-pr-watch-auto-resolve.sh`
- `test-pr-watch-shepherd-smoke.sh`
- `test-pre-push-rebase-allow.sh`
- `test-pre-push-test-gate.sh`
- `test-rebase-coordination.sh`
- `test-review-handoff-smoke.sh`
- `test-rollup-semantic.sh`
- `test-speculative-on-speculative-guard.sh`
- `test-stale-branch-rebase.sh`
- `test-status-flip-proof-of-merge.sh`

### observability-fleet-signals (INFRA-3376)

20 scripts. See INFRA-3376 for AC + ship target.

- `test-ambient-schema.sh`
- `test-auto-arm-sweeper.sh`
- `test-autoscale-decisions.sh`
- `test-cargo-target-reaper.sh`
- `test-claude-reaper.sh`
- `test-deliberator-tick-emits.sh`
- `test-fleet-brief.sh`
- `test-fleet-fanout.sh`
- `test-fleet-kill-switch.sh`
- `test-fleet-spec.sh`
- `test-fleet-starve-auto-action.sh`
- `test-install-ambient-hooks.sh`
- `test-md-links-loop.sh`
- `test-migration-pipeline-gates.sh`
- `test-model-registry.sh`
- `test-obs-coverage-guard.sh`
- `test-observability-coverage.sh`
- `test-schema-version-assert.sh`
- `test-stale-process-watchdog.sh`
- `test-supervision-trees.sh`

### commit-content-guards (INFRA-3377)

22 scripts. See INFRA-3377 for AC + ship target.

- `test-attribution-portable.sh`
- `test-book-sync-guard.sh`
- `test-credential-pattern-guard.sh`
- `test-cross-judge-guard.sh`
- `test-css-token-discipline.sh`
- `test-default-flip-guard.sh`
- `test-doc-freshness.sh`
- `test-docs-delta-commit-msg.sh`
- `test-docs-delta-guard.sh`
- `test-git-identity-guard.sh`
- `test-hardcoded-date-guard.sh`
- `test-infra-124-docs-delta-trailer.sh`
- `test-infra-257-doc-only-guards.sh`
- `test-no-claude-leak.sh`
- `test-no-verify-audit.sh`
- `test-pre-push-preflight-hook.sh`
- `test-preflight-ci-parity.sh`
- `test-prereg-content-guard.sh`
- `test-raw-yaml-guard.sh`
- `test-subagent-budget-kill.sh`
- `test-subagent-epilogue-ref.sh`
- `test-submodule-guard.sh`

### cli-product-acceptance (INFRA-3378)

23 scripts. See INFRA-3378 for AC + ship target.

- `check-release-staleness.sh`
- `coord-surfaces-smoke.sh`
- `test-changes-job-self-hosted.sh`
- `test-chump-improve.sh`
- `test-ci-flake-rerun.sh`
- `test-claim-fuzzy-match.sh`
- `test-cli-fleet-coord.sh`
- `test-cli-help.sh`
- `test-cli-integration.sh`
- `test-cli-version-debug.sh`
- `test-effective-010-completion.sh`
- `test-flake-autorerun.sh`
- `test-infra-250-v1-retirement.sh`
- `test-infra-254-pwa-root-redirect.sh`
- `test-inspect-resume-scrap.sh`
- `test-keystone-cascade.sh`
- `test-mcp-coord-smoke.sh`
- `test-orchestrate-session-summary.sh`
- `test-research-026-preflight.sh`
- `test-run-fleet-cross-repo.sh`
- `test-sandbox-isolation.sh`
- `test-self-hosted-runner-deps.sh`
- `test-spike-isolation.sh`

