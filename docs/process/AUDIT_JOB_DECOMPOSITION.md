# Audit-job (`fast-checks`) preflight mirror decomposition

_Survey for META-086 (INFRA-1856 follow-up). Generated 2026-07-19._


The CI job historically called "audit" in fleet doctrine is the `fast-checks`
job in `.github/workflows/ci.yml` (renamed from `audit`; see the "Shard 1: fast
checks" comment at that job's definition). It invokes **114** distinct
`scripts/ci/test-*.sh` scripts. Of those, **10** are already mirrored in
`src/preflight.rs` (run locally via `chump preflight`); **104** are not yet mirrored.

This doc enumerates every script, whether it is mirrored, and groups the
unmirrored ones into 5 thematic clusters — one per META-070 follow-up sub-gap.

## Already mirrored (10)

| Script | Purpose |
|---|---|
| `test-chump-repos.sh` | test-chump-repos.sh — MISSION-033 |
| `test-chump-subcommand-help.sh` | scripts/ci/test-chump-subcommand-help.sh — INFRA-1238 (also referenced by INFRA-1246) |
| `test-env-var-coverage.sh` | Asserts that every env var read by Chump's Rust source is either: |
| `test-farmer.sh` | test-farmer.sh — RESILIENT-068: unit tests for scripts/coord/farmer.sh |
| `test-fleet-pause-autolift.sh` | test-fleet-pause-autolift.sh — RESILIENT-066 |
| `test-gap-preflight-ac-gate.sh` | INFRA-1259: verify chump claim rejects gaps with empty/TODO-only acceptance_criteria |
| `test-markdown-intra-doc-links.sh` | test-markdown-intra-doc-links.sh — DOC-039 |
| `test-merged-check-guard.sh` | test-merged-check-guard.sh — INFRA-306 regression test. |
| `test-pipefail-race-sweep.sh` | scripts/ci/test-pipefail-race-sweep.sh — INFRA-1658 |
| `test-stale-pr-rebase-bot.sh` | scripts/ci/test-stale-pr-rebase-bot.sh — INFRA-2295 |

## Cluster: Gap-state & claim/lease consistency gates (14 scripts, unmirrored)

| Script | Purpose | Mirrored |
|---|---|---|
| `test-claim-fuzzy-match.sh` | scripts/ci/test-claim-fuzzy-match.sh — INFRA-1442 | no |
| `test-gap-divergence-guard.sh` | test-gap-divergence-guard.sh — INFRA-783 fixture tests. | no |
| `test-gap-doctor-safe-sweep.sh` | test-gap-doctor-safe-sweep.sh — INFRA-308 regression test. | no |
| `test-gap-id-cross-session.sh` | test-gap-id-cross-session.sh — CREDIBLE-052 | no |
| `test-gap-id-lease-uniqueness.sh` | test-gap-id-lease-uniqueness.sh — INFRA-1970 | no |
| `test-gap-reserve-concurrency.sh` | Spawns parallel gap-reserve.sh INFRA calls with distinct CHUMP_SESSION_ID values | no |
| `test-gap-reserve-padding.sh` | INFRA-080: regression — gap-reserve.sh must zero-pad the new ID to the | no |
| `test-gap-status-flip.sh` | INFRA-158: regression test for the gap-status-check workflow guard | no |
| `test-gate-promotion-no-regression.sh` | scripts/ci/test-gate-promotion-no-regression.sh — INFRA-1869 | no |
| `test-infra-1025-atomic-claim.sh` | test-infra-1025-atomic-claim.sh — INFRA-1025 | no |
| `test-infra-115-lease-ttl-file.sh` | INFRA-115: regression test for the file-based lease TTL reaper in | no |
| `test-merge-driver-state-sql.sh` | test-merge-driver-state-sql.sh — INFRA-310 | no |
| `test-pick-and-claim-lockdir.sh` | test-pick-and-claim-lockdir.sh — INFRA-467 | no |
| `test-schema-version-assert.sh` | scripts/ci/test-schema-version-assert.sh — INFRA-1978 | no |

## Cluster: PR / bot-merge lifecycle gates (23 scripts, unmirrored)

| Script | Purpose | Mirrored |
|---|---|---|
| `test-bot-merge-auto-close.sh` | INFRA-154 / INFRA-228 / INFRA-229: smoke-test the auto-close handshake | no |
| `test-bot-merge-conflict-wiring.sh` | scripts/ci/test-bot-merge-conflict-wiring.sh — INFRA-1657 | no |
| `test-conflict-resolver.sh` | scripts/ci/test-conflict-resolver.sh — INFRA-1488 (Marcus M-C) | no |
| `test-external-verify-merge.sh` | scripts/ci/test-external-verify-merge.sh | no |
| `test-infra-119-bot-merge-hang.sh` | INFRA-119 — verify queue-health-monitor.sh detects stale bot-merge health files. | no |
| `test-install-pr-auto-rebase.sh` | scripts/ci/test-install-pr-auto-rebase.sh — INFRA-1779 | no |
| `test-open-pr-dup-detection.sh` | scripts/ci/test-open-pr-dup-detection.sh — INFRA-1982 | no |
| `test-pr-auto-rebase.sh` | scripts/ci/test-pr-auto-rebase.sh — INFRA-1777 | no |
| `test-pr-blocked-watch.sh` | test-pr-blocked-watch.sh — INFRA-550 smoke test. | no |
| `test-pr-explain-block.sh` | scripts/ci/test-pr-explain-block.sh — INFRA-1416 | no |
| `test-pr-terminal-state.sh` | test-pr-terminal-state.sh — INFRA-1981 regression test (M3 critique fix). | no |
| `test-pr-triage-bot.sh` | scripts/ci/test-pr-triage-bot.sh — INFRA-624 | no |
| `test-pr-watch-auto-resolve.sh` | test-pr-watch-auto-resolve.sh — INFRA-387 unit test for the | no |
| `test-pr-watch-shepherd-smoke.sh` | test-pr-watch-shepherd-smoke.sh — INFRA-354 smoke test. | no |
| `test-pre-push-force-lease-guard.sh` | test-pre-push-force-lease-guard.sh — INFRA-345 regression test. | no |
| `test-pre-push-preflight-hook.sh` | scripts/ci/test-pre-push-preflight-hook.sh — INFRA-1671 regression test. | no |
| `test-pre-push-rebase-allow.sh` | test-pre-push-rebase-allow.sh — INFRA-368 regression test. | no |
| `test-pre-push-test-gate.sh` | test-pre-push-test-gate.sh — INFRA-761 regression tests. | no |
| `test-rebase-coordination.sh` | test-rebase-coordination.sh — INFRA-1974 (H5) regression test. | no |
| `test-review-handoff-smoke.sh` | test-review-handoff-smoke.sh — INFRA-774 | no |
| `test-speculative-on-speculative-guard.sh` | test-speculative-on-speculative-guard.sh — INFRA-684 CI gate. | no |
| `test-stale-branch-rebase.sh` | scripts/ci/test-stale-branch-rebase.sh — INFRA-1429 | no |
| `test-status-flip-proof-of-merge.sh` | scripts/ci/test-status-flip-proof-of-merge.sh — INFRA-1392 | no |

## Cluster: Observability, reaper & fleet-daemon gates (23 scripts, unmirrored)

| Script | Purpose | Mirrored |
|---|---|---|
| `test-ambient-schema.sh` | INFRA-101: regression test for the ambient-emit schema validator. | no |
| `test-auto-arm-sweeper.sh` | INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374). | no |
| `test-autoscale-decisions.sh` | scripts/ci/test-autoscale-decisions.sh — INFRA-1581 | no |
| `test-cargo-target-reaper.sh` | test-cargo-target-reaper.sh — INFRA-1250 | no |
| `test-claude-reaper.sh` | test-claude-reaper.sh — INFRA-1662 | no |
| `test-deliberator-tick-emits.sh` | RESILIENT-061 AC #4: test-deliberator-tick-emits.sh | no |
| `test-fleet-brief.sh` | capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077) | no |
| `test-fleet-fanout.sh` | scripts/ci/test-fleet-fanout.sh — INFRA-1484 (Marcus M-B continuation) | no |
| `test-fleet-kill-switch.sh` | scripts/ci/test-fleet-kill-switch.sh — RESILIENT-073 | no |
| `test-fleet-spec.sh` | scripts/ci/test-fleet-spec.sh — INFRA-1483 (Marcus M-B) | no |
| `test-fleet-starve-auto-action.sh` | test-fleet-starve-auto-action.sh — INFRA-391 regression test. | no |
| `test-infra-258-reaper-partial-delivery.sh` | test-infra-258-reaper-partial-delivery.sh — INFRA-258 regression test. | no |
| `test-mcp-coord-smoke.sh` | INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys. | no |
| `test-migration-pipeline-gates.sh` | scripts/ci/test-migration-pipeline-gates.sh — INFRA-1581 (closes INFRA-1538) | no |
| `test-model-registry.sh` | test-model-registry.sh — INFRA-739 | no |
| `test-obs-coverage-guard.sh` | test-obs-coverage-guard.sh — INFRA-757 | no |
| `test-observability-coverage.sh` | test-observability-coverage.sh — INFRA-757 | no |
| `test-orchestrate-session-summary.sh` | scripts/ci/test-orchestrate-session-summary.sh — INFRA-1363 | no |
| `test-run-fleet-cross-repo.sh` | test-run-fleet-cross-repo.sh — INFRA-634 cross-repo fleet flags | no |
| `test-stale-process-watchdog.sh` | test-stale-process-watchdog.sh — INFRA-1663 | no |
| `test-subagent-budget-kill.sh` | test-subagent-budget-kill.sh — INFRA-1972 (H3) structural regression test. | no |
| `test-supervision-trees.sh` | test-supervision-trees.sh — RESILIENT-058 regression test | no |
| `test-worktree-reaper-safety.sh` | test-worktree-reaper-safety.sh — INFRA-1074 | no |

## Cluster: Doc, content & security guard gates (30 scripts, unmirrored)

| Script | Purpose | Mirrored |
|---|---|---|
| `test-attribution-portable.sh` | test-attribution-portable.sh — CREDIBLE-045: verify generic agent attribution | no |
| `test-book-sync-guard.sh` | INFRA-170: tests for the book/src ↔ docs/process sync guard in | no |
| `test-credential-pattern-guard.sh` | INFRA-158: regression test for the credential-pattern pre-commit guard | no |
| `test-cross-judge-guard.sh` | INFRA-079: tests for the cross-judge audit guard. | no |
| `test-css-token-discipline.sh` | test-css-token-discipline.sh — CI smoke test for INFRA-1590 | no |
| `test-default-flip-guard.sh` | test-default-flip-guard.sh — INFRA-762 unit tests. | no |
| `test-doc-freshness.sh` | test-doc-freshness.sh — DOC-041 | no |
| `test-docs-delta-commit-msg.sh` | test-docs-delta-commit-msg.sh — INFRA-1969 regression test. | no |
| `test-docs-delta-guard.sh` | INFRA-158: regression test for the docs-delta pre-commit guard | no |
| `test-git-identity-guard.sh` | test-git-identity-guard.sh — INFRA-787 fixture tests. | no |
| `test-hardcoded-date-guard.sh` | test-hardcoded-date-guard.sh — INFRA-971 | no |
| `test-infra-109-worktree-boundary.sh` | test-infra-109-worktree-boundary.sh — INFRA-109 regression test. | no |
| `test-infra-124-docs-delta-trailer.sh` | test-infra-124-docs-delta-trailer.sh — INFRA-124 regression test. | no |
| `test-infra-250-v1-retirement.sh` | CI acceptance test for INFRA-250: PWA v1 retirement. | no |
| `test-infra-254-pwa-root-redirect.sh` | INFRA-254: GET / on the PWA must 301-redirect to /v2/. | no |
| `test-infra-257-doc-only-guards.sh` | test-infra-257-doc-only-guards.sh — INFRA-257 regression test. | no |
| `test-keystone-cascade.sh` | scripts/ci/test-keystone-cascade.sh — INFRA-1420 | no |
| `test-md-links-loop.sh` | test-md-links-loop.sh — INFRA-1925: smoke test for scripts/coord/md-links-loop.sh. | no |
| `test-merge-driver-ci-yml.sh` | test-merge-driver-ci-yml.sh — INFRA-310 | no |
| `test-merge-driver-pre-commit.sh` | test-merge-driver-pre-commit.sh — INFRA-310 | no |
| `test-meta-011-git-stomp.sh` | META-011: regression test for concurrent chump-commit.sh calls on a shared | no |
| `test-no-claude-leak.sh` | test-no-claude-leak.sh — INFRA-1051 | no |
| `test-no-verify-audit.sh` | scripts/ci/test-no-verify-audit.sh — INFRA-1834 | no |
| `test-preflight-ci-parity.sh` | test-preflight-ci-parity.sh — INFRA-1867 (INFRA-1861 slice b) — widened META-268 | no |
| `test-prereg-content-guard.sh` | INFRA-113: tests for the preregistration content checker | no |
| `test-raw-yaml-guard.sh` | INFRA-499: raw-YAML-edit guard removed in PR #1148. | no |
| `test-research-026-preflight.sh` | CI-safe preflight for RESEARCH-026 harness + fixtures (no API calls). | no |
| `test-rollup-semantic.sh` | scripts/ci/test-rollup-semantic.sh — INFRA-1455 (Marcus M-B converge) | no |
| `test-subagent-epilogue-ref.sh` | test-subagent-epilogue-ref.sh — INFRA-332 | no |
| `test-submodule-guard.sh` | INFRA-158: regression test for the submodule-sanity pre-commit guard | no |

## Cluster: Worker/CLI smoke tests (14 scripts, unmirrored)

| Script | Purpose | Mirrored |
|---|---|---|
| `test-changes-job-self-hosted.sh` | scripts/ci/test-changes-job-self-hosted.sh — INFRA-1537 | no |
| `test-chump-improve.sh` | EFFECTIVE-177: Integration test for `chump improve <owner/repo>`. | no |
| `test-ci-flake-rerun.sh` | test-ci-flake-rerun.sh — INFRA-375 smoke test. | no |
| `test-cli-fleet-coord.sh` | test-cli-fleet-coord.sh — CREDIBLE-035 | no |
| `test-cli-help.sh` | CREDIBLE-015: CLI help system consistency gate. | no |
| `test-cli-integration.sh` | scripts/ci/test-cli-integration.sh | no |
| `test-cli-version-debug.sh` | scripts/ci/test-cli-version-debug.sh — CREDIBLE-019 | no |
| `test-effective-010-completion.sh` | test-effective-010-completion.sh — EFFECTIVE-010 | no |
| `test-flake-autorerun.sh` | test-flake-autorerun.sh — INFRA-764 unit tests for cargo-test-with-rerun.sh. | no |
| `test-inspect-resume-scrap.sh` | scripts/ci/test-inspect-resume-scrap.sh — INFRA-1456 (eject-and-inspect) | no |
| `test-install-ambient-hooks.sh` | test-install-ambient-hooks.sh — FLEET-023 regression tests for the | no |
| `test-sandbox-isolation.sh` | capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078) | no |
| `test-self-hosted-runner-deps.sh` | test-self-hosted-runner-deps.sh — INFRA-1556 | no |
| `test-spike-isolation.sh` | test-spike-isolation.sh — INFRA-430 regression test. | no |

## Grouping rationale

Each cluster maps to its closest sibling subsystem so the resulting
`chump preflight` gate can share fixtures/helpers with related mirrored checks:

1. **Gap-state & claim/lease consistency** — `state.db` mutation paths: claim
   atomicity, lease TTL, gap-id uniqueness, reserve concurrency, divergence
   detection, gate promotion. Sibling of the already-mirrored `test-gap-preflight-ac-gate.sh`.
2. **PR / bot-merge lifecycle** — rebase automation, conflict resolution,
   pre-push hooks, PR watch/triage/terminal-state, merge-queue coordination.
   Sibling of already-mirrored `test-merged-check-guard.sh` / `test-stale-pr-rebase-bot.sh`.
3. **Observability, reaper & fleet-daemon** — ambient schema, reapers (cargo-target,
   claude, worktree), fleet autoscale/kill-switch/spec/starve, deliberator,
   MCP coord, model registry. Sibling of already-mirrored `test-farmer.sh` / `test-fleet-pause-autolift.sh`.
4. **Doc, content & security guards** — docs-delta, credential/hardcoded-date/raw-yaml
   patterns, git-identity, css-token-discipline, merge-driver sync, submodule/worktree
   boundary guards. Sibling of already-mirrored `test-markdown-intra-doc-links.sh`.
5. **Worker/CLI smoke** — `chump` CLI help/version/integration/fleet-coord, flake
   rerun, self-hosted-runner deps, sandbox/spike isolation. Sibling of
   already-mirrored `test-chump-subcommand-help.sh` / `test-chump-repos.sh`.

## Follow-up sub-gaps

Filed as META-070 Tier-C sub-gaps, one per cluster above (status may have
advanced since this doc was written — `chump gap show <ID>` for current state):

- **INFRA-3384** — Gap-state & claim/lease consistency mirror gate (14 scripts)
- **INFRA-3385** — PR / bot-merge lifecycle mirror gate (23 scripts)
- **INFRA-3386** — Observability, reaper & fleet-daemon mirror gate (23 scripts)
- **INFRA-3387** — Doc, content & security guard mirror gate (30 scripts)
- **INFRA-3388** — Worker/CLI smoke mirror gate (14 scripts)

META-086 tracks these via `depends_on`; it closes once the decomposition
itself (this survey + the 5 filed sub-gaps) ships — the sub-gaps are
independently pickable follow-up work, not blockers on META-086's own close.

