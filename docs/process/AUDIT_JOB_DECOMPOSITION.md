# Audit-job (`fast-checks`) preflight-mirror decomposition

> Survey for META-086 (INFRA-1856 follow-up after scope discovery). Enumerates every
> `scripts/ci/test-*.sh` invoked by the `fast-checks` job in `.github/workflows/ci.yml`
> (the job informally called "the audit job"), whether it's already mirrored in
> `chump preflight` (`src/preflight.rs`), and which cluster of unmirrored scripts a
> follow-up sub-gap should target. Pairs with
> [`docs/process/PREFLIGHT_COVERAGE_AUDIT.md`](./PREFLIGHT_COVERAGE_AUDIT.md), which
> tracks the mirrored side; this doc is the full enumeration including the unmirrored side.

Totals at time of survey: **114** distinct `test-*.sh` scripts invoked by
the `fast-checks` job, **10** already mirrored in `chump preflight`,
**104** unmirrored — grouped into 5 clusters below.

## Already mirrored

| Script | Purpose |
|---|---|
| `scripts/ci/test-chump-repos.sh` | test-chump-repos.sh — MISSION-033 |
| `scripts/ci/test-chump-subcommand-help.sh` | scripts/ci/test-chump-subcommand-help.sh — INFRA-1238 (also referenced by INFRA-1246) |
| `scripts/ci/test-env-var-coverage.sh` | Asserts that every env var read by Chump's Rust source is either: |
| `scripts/ci/test-farmer.sh` | test-farmer.sh — RESILIENT-068: unit tests for scripts/coord/farmer.sh |
| `scripts/ci/test-fleet-pause-autolift.sh` | test-fleet-pause-autolift.sh — RESILIENT-066 |
| `scripts/ci/test-gap-preflight-ac-gate.sh` | INFRA-1259: verify chump claim rejects gaps with empty/TODO-only acceptance_criteria |
| `scripts/ci/test-markdown-intra-doc-links.sh` | test-markdown-intra-doc-links.sh — DOC-039 |
| `scripts/ci/test-merged-check-guard.sh` | test-merged-check-guard.sh — INFRA-306 regression test. |
| `scripts/ci/test-pipefail-race-sweep.sh` | scripts/ci/test-pipefail-race-sweep.sh — INFRA-1658 |
| `scripts/ci/test-stale-pr-rebase-bot.sh` | scripts/ci/test-stale-pr-rebase-bot.sh — INFRA-2295 |

## Fleet claim/lease/gap-registry gates (`cluster-1-claim-lease`)

| Script | Purpose | Mirrored? |
|---|---|---|
| `scripts/ci/test-claim-fuzzy-match.sh` | scripts/ci/test-claim-fuzzy-match.sh — INFRA-1442 | no |
| `scripts/ci/test-gap-id-cross-session.sh` | test-gap-id-cross-session.sh — CREDIBLE-052 | no |
| `scripts/ci/test-gap-id-lease-uniqueness.sh` | test-gap-id-lease-uniqueness.sh — INFRA-1970 | no |
| `scripts/ci/test-gap-reserve-concurrency.sh` | Spawns parallel gap-reserve.sh INFRA calls with distinct CHUMP_SESSION_ID values | no |
| `scripts/ci/test-gap-reserve-padding.sh` | INFRA-080: regression — gap-reserve.sh must zero-pad the new ID to the | no |
| `scripts/ci/test-gap-status-flip.sh` | INFRA-158: regression test for the gap-status-check workflow guard | no |
| `scripts/ci/test-gap-divergence-guard.sh` | test-gap-divergence-guard.sh — INFRA-783 fixture tests. | no |
| `scripts/ci/test-pick-and-claim-lockdir.sh` | test-pick-and-claim-lockdir.sh — INFRA-467 | no |
| `scripts/ci/test-infra-1025-atomic-claim.sh` | test-infra-1025-atomic-claim.sh — INFRA-1025 | no |
| `scripts/ci/test-infra-115-lease-ttl-file.sh` | INFRA-115: regression test for the file-based lease TTL reaper in | no |
| `scripts/ci/test-infra-109-worktree-boundary.sh` | test-infra-109-worktree-boundary.sh — INFRA-109 regression test. | no |
| `scripts/ci/test-git-identity-guard.sh` | test-git-identity-guard.sh — INFRA-787 fixture tests. | no |
| `scripts/ci/test-meta-011-git-stomp.sh` | META-011: regression test for concurrent chump-commit.sh calls on a shared | no |
| `scripts/ci/test-submodule-guard.sh` | INFRA-158: regression test for the submodule-sanity pre-commit guard | no |
| `scripts/ci/test-gap-doctor-safe-sweep.sh` | test-gap-doctor-safe-sweep.sh — INFRA-308 regression test. | no |

## PR / merge-queue lifecycle gates (`cluster-2-pr-lifecycle`)

| Script | Purpose | Mirrored? |
|---|---|---|
| `scripts/ci/test-bot-merge-auto-close.sh` | INFRA-154 / INFRA-228 / INFRA-229: smoke-test the auto-close handshake | no |
| `scripts/ci/test-bot-merge-conflict-wiring.sh` | scripts/ci/test-bot-merge-conflict-wiring.sh — INFRA-1657 | no |
| `scripts/ci/test-pr-auto-rebase.sh` | scripts/ci/test-pr-auto-rebase.sh — INFRA-1777 | no |
| `scripts/ci/test-pr-blocked-watch.sh` | test-pr-blocked-watch.sh — INFRA-550 smoke test. | no |
| `scripts/ci/test-pr-explain-block.sh` | scripts/ci/test-pr-explain-block.sh — INFRA-1416 | no |
| `scripts/ci/test-pr-terminal-state.sh` | test-pr-terminal-state.sh — INFRA-1981 regression test (M3 critique fix). | no |
| `scripts/ci/test-pr-triage-bot.sh` | scripts/ci/test-pr-triage-bot.sh — INFRA-624 | no |
| `scripts/ci/test-pr-watch-auto-resolve.sh` | test-pr-watch-auto-resolve.sh — INFRA-387 unit test for the | no |
| `scripts/ci/test-pr-watch-shepherd-smoke.sh` | test-pr-watch-shepherd-smoke.sh — INFRA-354 smoke test. | no |
| `scripts/ci/test-stale-branch-rebase.sh` | scripts/ci/test-stale-branch-rebase.sh — INFRA-1429 | no |
| `scripts/ci/test-rebase-coordination.sh` | test-rebase-coordination.sh — INFRA-1974 (H5) regression test. | no |
| `scripts/ci/test-install-pr-auto-rebase.sh` | scripts/ci/test-install-pr-auto-rebase.sh — INFRA-1779 | no |
| `scripts/ci/test-open-pr-dup-detection.sh` | scripts/ci/test-open-pr-dup-detection.sh — INFRA-1982 | no |
| `scripts/ci/test-status-flip-proof-of-merge.sh` | scripts/ci/test-status-flip-proof-of-merge.sh — INFRA-1392 | no |
| `scripts/ci/test-rollup-semantic.sh` | scripts/ci/test-rollup-semantic.sh — INFRA-1455 (Marcus M-B converge) | no |
| `scripts/ci/test-external-verify-merge.sh` | scripts/ci/test-external-verify-merge.sh | no |
| `scripts/ci/test-speculative-on-speculative-guard.sh` | test-speculative-on-speculative-guard.sh — INFRA-684 CI gate. | no |
| `scripts/ci/test-gate-promotion-no-regression.sh` | scripts/ci/test-gate-promotion-no-regression.sh — INFRA-1869 | no |
| `scripts/ci/test-ci-flake-rerun.sh` | test-ci-flake-rerun.sh — INFRA-375 smoke test. | no |
| `scripts/ci/test-flake-autorerun.sh` | test-flake-autorerun.sh — INFRA-764 unit tests for cargo-test-with-rerun.sh. | no |
| `scripts/ci/test-pre-push-force-lease-guard.sh` | test-pre-push-force-lease-guard.sh — INFRA-345 regression test. | no |
| `scripts/ci/test-pre-push-rebase-allow.sh` | test-pre-push-rebase-allow.sh — INFRA-368 regression test. | no |
| `scripts/ci/test-pre-push-test-gate.sh` | test-pre-push-test-gate.sh — INFRA-761 regression tests. | no |
| `scripts/ci/test-pre-push-preflight-hook.sh` | scripts/ci/test-pre-push-preflight-hook.sh — INFRA-1671 regression test. | no |
| `scripts/ci/test-preflight-ci-parity.sh` | test-preflight-ci-parity.sh — INFRA-1867 (INFRA-1861 slice b) — widened META-268 | no |
| `scripts/ci/test-no-verify-audit.sh` | scripts/ci/test-no-verify-audit.sh — INFRA-1834 | no |
| `scripts/ci/test-docs-delta-guard.sh` | INFRA-158: regression test for the docs-delta pre-commit guard | no |
| `scripts/ci/test-docs-delta-commit-msg.sh` | test-docs-delta-commit-msg.sh — INFRA-1969 regression test. | no |
| `scripts/ci/test-infra-124-docs-delta-trailer.sh` | test-infra-124-docs-delta-trailer.sh — INFRA-124 regression test. | no |
| `scripts/ci/test-infra-119-bot-merge-hang.sh` | INFRA-119 — verify queue-health-monitor.sh detects stale bot-merge health files. | no |

## Fleet daemon / observability / substrate gates (`cluster-3-daemon-observability`)

| Script | Purpose | Mirrored? |
|---|---|---|
| `scripts/ci/test-cargo-target-reaper.sh` | test-cargo-target-reaper.sh — INFRA-1250 | no |
| `scripts/ci/test-claude-reaper.sh` | test-claude-reaper.sh — INFRA-1662 | no |
| `scripts/ci/test-worktree-reaper-safety.sh` | test-worktree-reaper-safety.sh — INFRA-1074 | no |
| `scripts/ci/test-stale-process-watchdog.sh` | test-stale-process-watchdog.sh — INFRA-1663 | no |
| `scripts/ci/test-auto-arm-sweeper.sh` | INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374). | no |
| `scripts/ci/test-autoscale-decisions.sh` | scripts/ci/test-autoscale-decisions.sh — INFRA-1581 | no |
| `scripts/ci/test-fleet-brief.sh` | capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CRE | no |
| `scripts/ci/test-fleet-fanout.sh` | scripts/ci/test-fleet-fanout.sh — INFRA-1484 (Marcus M-B continuation) | no |
| `scripts/ci/test-fleet-kill-switch.sh` | scripts/ci/test-fleet-kill-switch.sh — RESILIENT-073 | no |
| `scripts/ci/test-fleet-spec.sh` | scripts/ci/test-fleet-spec.sh — INFRA-1483 (Marcus M-B) | no |
| `scripts/ci/test-fleet-starve-auto-action.sh` | test-fleet-starve-auto-action.sh — INFRA-391 regression test. | no |
| `scripts/ci/test-supervision-trees.sh` | test-supervision-trees.sh — RESILIENT-058 regression test | no |
| `scripts/ci/test-obs-coverage-guard.sh` | test-obs-coverage-guard.sh — INFRA-757 | no |
| `scripts/ci/test-observability-coverage.sh` | test-observability-coverage.sh — INFRA-757 | no |
| `scripts/ci/test-ambient-schema.sh` | INFRA-101: regression test for the ambient-emit schema validator. | no |
| `scripts/ci/test-deliberator-tick-emits.sh` | RESILIENT-061 AC #4: test-deliberator-tick-emits.sh | no |
| `scripts/ci/test-md-links-loop.sh` | test-md-links-loop.sh — INFRA-1925: smoke test for scripts/coord/md-links-loop.sh. | no |
| `scripts/ci/test-mcp-coord-smoke.sh` | INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys. | no |
| `scripts/ci/test-model-registry.sh` | test-model-registry.sh — INFRA-739 | no |
| `scripts/ci/test-schema-version-assert.sh` | scripts/ci/test-schema-version-assert.sh — INFRA-1978 | no |
| `scripts/ci/test-migration-pipeline-gates.sh` | scripts/ci/test-migration-pipeline-gates.sh — INFRA-1581 (closes INFRA-1538) | no |
| `scripts/ci/test-infra-258-reaper-partial-delivery.sh` | test-infra-258-reaper-partial-delivery.sh — INFRA-258 regression test. | no |
| `scripts/ci/test-changes-job-self-hosted.sh` | scripts/ci/test-changes-job-self-hosted.sh — INFRA-1537 | no |
| `scripts/ci/test-self-hosted-runner-deps.sh` | test-self-hosted-runner-deps.sh — INFRA-1556 | no |
| `scripts/ci/test-install-ambient-hooks.sh` | test-install-ambient-hooks.sh — FLEET-023 regression tests for the | no |

## CLI / doc-quality / content-integrity gates (`cluster-4-cli-doc-quality`)

| Script | Purpose | Mirrored? |
|---|---|---|
| `scripts/ci/test-cli-fleet-coord.sh` | test-cli-fleet-coord.sh — CREDIBLE-035 | no |
| `scripts/ci/test-cli-help.sh` | CREDIBLE-015: CLI help system consistency gate. | no |
| `scripts/ci/test-cli-integration.sh` | scripts/ci/test-cli-integration.sh | no |
| `scripts/ci/test-cli-version-debug.sh` | scripts/ci/test-cli-version-debug.sh — CREDIBLE-019 | no |
| `scripts/ci/test-chump-improve.sh` | EFFECTIVE-177: Integration test for `chump improve <owner/repo>`. | no |
| `scripts/ci/test-inspect-resume-scrap.sh` | scripts/ci/test-inspect-resume-scrap.sh — INFRA-1456 (eject-and-inspect) | no |
| `scripts/ci/test-orchestrate-session-summary.sh` | scripts/ci/test-orchestrate-session-summary.sh — INFRA-1363 | no |
| `scripts/ci/test-review-handoff-smoke.sh` | test-review-handoff-smoke.sh — INFRA-774 | no |
| `scripts/ci/test-run-fleet-cross-repo.sh` | test-run-fleet-cross-repo.sh — INFRA-634 cross-repo fleet flags | no |
| `scripts/ci/test-conflict-resolver.sh` | scripts/ci/test-conflict-resolver.sh — INFRA-1488 (Marcus M-C) | no |
| `scripts/ci/test-effective-010-completion.sh` | test-effective-010-completion.sh — EFFECTIVE-010 | no |
| `scripts/ci/test-book-sync-guard.sh` | INFRA-170: tests for the book/src ↔ docs/process sync guard in | no |
| `scripts/ci/test-cross-judge-guard.sh` | INFRA-079: tests for the cross-judge audit guard. | no |
| `scripts/ci/test-prereg-content-guard.sh` | INFRA-113: tests for the preregistration content checker | no |
| `scripts/ci/test-doc-freshness.sh` | test-doc-freshness.sh — DOC-041 | no |
| `scripts/ci/test-no-claude-leak.sh` | test-no-claude-leak.sh — INFRA-1051 | no |
| `scripts/ci/test-hardcoded-date-guard.sh` | test-hardcoded-date-guard.sh — INFRA-971 | no |
| `scripts/ci/test-credential-pattern-guard.sh` | INFRA-158: regression test for the credential-pattern pre-commit guard | no |
| `scripts/ci/test-css-token-discipline.sh` | test-css-token-discipline.sh — CI smoke test for INFRA-1590 | no |
| `scripts/ci/test-raw-yaml-guard.sh` | INFRA-499: raw-YAML-edit guard removed in PR #1148. | no |
| `scripts/ci/test-attribution-portable.sh` | test-attribution-portable.sh — CREDIBLE-045: verify generic agent attribution | no |
| `scripts/ci/test-research-026-preflight.sh` | CI-safe preflight for RESEARCH-026 harness + fixtures (no API calls). | no |

## Merge-driver / safety / bypass-scope gates (`cluster-5-merge-driver-safety`)

| Script | Purpose | Mirrored? |
|---|---|---|
| `scripts/ci/test-keystone-cascade.sh` | scripts/ci/test-keystone-cascade.sh — INFRA-1420 | no |
| `scripts/ci/test-sandbox-isolation.sh` | capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CRE | no |
| `scripts/ci/test-spike-isolation.sh` | test-spike-isolation.sh — INFRA-430 regression test. | no |
| `scripts/ci/test-subagent-budget-kill.sh` | test-subagent-budget-kill.sh — INFRA-1972 (H3) structural regression test. | no |
| `scripts/ci/test-subagent-epilogue-ref.sh` | test-subagent-epilogue-ref.sh — INFRA-332 | no |
| `scripts/ci/test-default-flip-guard.sh` | test-default-flip-guard.sh — INFRA-762 unit tests. | no |
| `scripts/ci/test-infra-250-v1-retirement.sh` | CI acceptance test for INFRA-250: PWA v1 retirement. | no |
| `scripts/ci/test-infra-254-pwa-root-redirect.sh` | INFRA-254: GET / on the PWA must 301-redirect to /v2/. | no |
| `scripts/ci/test-infra-257-doc-only-guards.sh` | test-infra-257-doc-only-guards.sh — INFRA-257 regression test. | no |
| `scripts/ci/test-merge-driver-ci-yml.sh` | test-merge-driver-ci-yml.sh — INFRA-310 | no |
| `scripts/ci/test-merge-driver-pre-commit.sh` | test-merge-driver-pre-commit.sh — INFRA-310 | no |
| `scripts/ci/test-merge-driver-state-sql.sh` | test-merge-driver-state-sql.sh — INFRA-310 | no |

