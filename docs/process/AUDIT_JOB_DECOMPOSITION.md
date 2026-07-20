# Audit-job (`fast-checks`) preflight-mirror decomposition survey

**Gap:** META-086. **Parent:** META-070 (quality firewall completion), continuation of INFRA-1856 after scope discovery (INFRA-1856 closed 2026-05-23 — original AC assumed 2 sub-checks, reality is ~114 distinct `scripts/ci/test-*.sh` invocations in the `fast-checks` job).

**Scope note (repeat scope-discovery, honestly documented):** by 2026-07-19 the historically-named `audit` job in `ci.yml` no longer exists as a separate job — its scripts were folded into the `fast-checks` job (see `docs/process/CI_PREFLIGHT_PARITY.md` for the point-in-time table referencing the old `audit` job name). This survey covers every `scripts/ci/test-*.sh` invocation inside the current `fast-checks` job block (`.github/workflows/ci.yml` lines ~629-1172), which is the direct successor of what INFRA-1856/META-086's filer meant by "the audit job."

**Method:** `sed -n '629,1172p' .github/workflows/ci.yml | grep -oE "test-[a-zA-Z0-9_-]+\.sh" | sort -u`, cross-referenced against `grep -oE 'test-[a-zA-Z0-9_-]+\.sh' src/preflight.rs` for mirror status. Purpose column pulled from each script's own header comment (first non-shebang `#` line).

## Gap registry & claim lifecycle  (`gap-registry-claim-lifecycle`)

11 scripts, 10 unmirrored (1 already mirrored).

| Script | Purpose | Mirrored in `src/preflight.rs`? |
|---|---|---|
| `test-claim-fuzzy-match.sh` | scripts/ci/test-claim-fuzzy-match.sh — INFRA-1442 | ❌ |
| `test-gap-divergence-guard.sh` | INFRA-783 fixture tests. | ❌ |
| `test-gap-doctor-safe-sweep.sh` | INFRA-308 regression test. | ❌ |
| `test-gap-id-cross-session.sh` | CREDIBLE-052 | ❌ |
| `test-gap-id-lease-uniqueness.sh` | INFRA-1970 | ❌ |
| `test-gap-preflight-ac-gate.sh` | INFRA-1259: verify chump claim rejects gaps with empty/TODO-only acceptance_criteria | ✅ |
| `test-gap-reserve-concurrency.sh` | Spawns parallel gap-reserve.sh INFRA calls with distinct CHUMP_SESSION_ID values | ❌ |
| `test-gap-reserve-padding.sh` | INFRA-080: regression — gap-reserve.sh must zero-pad the new ID to the | ❌ |
| `test-gap-status-flip.sh` | INFRA-158: regression test for the gap-status-check workflow guard | ❌ |
| `test-infra-1025-atomic-claim.sh` | INFRA-1025 | ❌ |
| `test-pick-and-claim-lockdir.sh` | INFRA-467 | ❌ |

## PR / merge lifecycle  (`pr-merge-lifecycle`)

20 scripts, 18 unmirrored (2 already mirrored).

| Script | Purpose | Mirrored in `src/preflight.rs`? |
|---|---|---|
| `test-bot-merge-auto-close.sh` | INFRA-154 / INFRA-228 / INFRA-229: smoke-test the auto-close handshake | ❌ |
| `test-bot-merge-conflict-wiring.sh` | scripts/ci/test-bot-merge-conflict-wiring.sh — INFRA-1657 | ❌ |
| `test-ci-flake-rerun.sh` | INFRA-375 smoke test. | ❌ |
| `test-conflict-resolver.sh` | scripts/ci/test-conflict-resolver.sh — INFRA-1488 (Marcus M-C) | ❌ |
| `test-flake-autorerun.sh` | INFRA-764 unit tests for cargo-test-with-rerun.sh. | ❌ |
| `test-install-pr-auto-rebase.sh` | scripts/ci/test-install-pr-auto-rebase.sh — INFRA-1779 | ❌ |
| `test-merged-check-guard.sh` | INFRA-306 regression test. | ✅ |
| `test-open-pr-dup-detection.sh` | scripts/ci/test-open-pr-dup-detection.sh — INFRA-1982 | ❌ |
| `test-pr-auto-rebase.sh` | scripts/ci/test-pr-auto-rebase.sh — INFRA-1777 | ❌ |
| `test-pr-blocked-watch.sh` | INFRA-550 smoke test. | ❌ |
| `test-pr-explain-block.sh` | scripts/ci/test-pr-explain-block.sh — INFRA-1416 | ❌ |
| `test-pr-terminal-state.sh` | INFRA-1981 regression test (M3 critique fix). | ❌ |
| `test-pr-triage-bot.sh` | scripts/ci/test-pr-triage-bot.sh — INFRA-624 | ❌ |
| `test-pr-watch-auto-resolve.sh` | INFRA-387 unit test for the | ❌ |
| `test-pr-watch-shepherd-smoke.sh` | INFRA-354 smoke test. | ❌ |
| `test-rebase-coordination.sh` | INFRA-1974 (H5) regression test. | ❌ |
| `test-speculative-on-speculative-guard.sh` | INFRA-684 CI gate. | ❌ |
| `test-stale-branch-rebase.sh` | scripts/ci/test-stale-branch-rebase.sh — INFRA-1429 | ❌ |
| `test-stale-pr-rebase-bot.sh` | scripts/ci/test-stale-pr-rebase-bot.sh — INFRA-2295 | ✅ |
| `test-status-flip-proof-of-merge.sh` | scripts/ci/test-status-flip-proof-of-merge.sh — INFRA-1392 | ❌ |

## Fleet daemon & reaper cadence  (`fleet-daemon-reaper`)

16 scripts, 14 unmirrored (2 already mirrored).

| Script | Purpose | Mirrored in `src/preflight.rs`? |
|---|---|---|
| `test-auto-arm-sweeper.sh` | INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374). | ❌ |
| `test-autoscale-decisions.sh` | scripts/ci/test-autoscale-decisions.sh — INFRA-1581 | ❌ |
| `test-cargo-target-reaper.sh` | INFRA-1250 | ❌ |
| `test-claude-reaper.sh` | INFRA-1662 | ❌ |
| `test-farmer.sh` | RESILIENT-068: unit tests for scripts/coord/farmer.sh | ✅ |
| `test-fleet-brief.sh` | capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077) | ❌ |
| `test-fleet-fanout.sh` | scripts/ci/test-fleet-fanout.sh — INFRA-1484 (Marcus M-B continuation) | ❌ |
| `test-fleet-kill-switch.sh` | scripts/ci/test-fleet-kill-switch.sh — RESILIENT-073 | ❌ |
| `test-fleet-pause-autolift.sh` | RESILIENT-066 | ✅ |
| `test-fleet-spec.sh` | scripts/ci/test-fleet-spec.sh — INFRA-1483 (Marcus M-B) | ❌ |
| `test-fleet-starve-auto-action.sh` | INFRA-391 regression test. | ❌ |
| `test-infra-258-reaper-partial-delivery.sh` | INFRA-258 regression test. | ❌ |
| `test-stale-process-watchdog.sh` | INFRA-1663 | ❌ |
| `test-subagent-budget-kill.sh` | INFRA-1972 (H3) structural regression test. | ❌ |
| `test-supervision-trees.sh` | RESILIENT-058 regression test | ❌ |
| `test-worktree-reaper-safety.sh` | INFRA-1074 | ❌ |

## Docs / hygiene / commit guards  (`docs-hygiene-guard`)

22 scripts, 21 unmirrored (1 already mirrored).

| Script | Purpose | Mirrored in `src/preflight.rs`? |
|---|---|---|
| `test-credential-pattern-guard.sh` | INFRA-158: regression test for the credential-pattern pre-commit guard | ❌ |
| `test-cross-judge-guard.sh` | INFRA-079: tests for the cross-judge audit guard. | ❌ |
| `test-css-token-discipline.sh` | CI smoke test for INFRA-1590 | ❌ |
| `test-default-flip-guard.sh` | INFRA-762 unit tests. | ❌ |
| `test-doc-freshness.sh` | DOC-041 | ❌ |
| `test-docs-delta-commit-msg.sh` | INFRA-1969 regression test. | ❌ |
| `test-docs-delta-guard.sh` | INFRA-158: regression test for the docs-delta pre-commit guard | ❌ |
| `test-gate-promotion-no-regression.sh` | scripts/ci/test-gate-promotion-no-regression.sh — INFRA-1869 | ❌ |
| `test-git-identity-guard.sh` | INFRA-787 fixture tests. | ❌ |
| `test-hardcoded-date-guard.sh` | INFRA-971 | ❌ |
| `test-markdown-intra-doc-links.sh` | DOC-039 | ✅ |
| `test-md-links-loop.sh` | INFRA-1925: smoke test for scripts/coord/md-links-loop.sh. | ❌ |
| `test-merge-driver-ci-yml.sh` | INFRA-310 | ❌ |
| `test-merge-driver-pre-commit.sh` | INFRA-310 | ❌ |
| `test-merge-driver-state-sql.sh` | INFRA-310 | ❌ |
| `test-no-claude-leak.sh` | INFRA-1051 | ❌ |
| `test-no-verify-audit.sh` | scripts/ci/test-no-verify-audit.sh — INFRA-1834 | ❌ |
| `test-preflight-ci-parity.sh` | INFRA-1867 (INFRA-1861 slice b) — widened META-268 | ❌ |
| `test-prereg-content-guard.sh` | INFRA-113: tests for the preregistration content checker | ❌ |
| `test-raw-yaml-guard.sh` | INFRA-499: raw-YAML-edit guard removed in PR #1148. | ❌ |
| `test-schema-version-assert.sh` | scripts/ci/test-schema-version-assert.sh — INFRA-1978 | ❌ |
| `test-submodule-guard.sh` | INFRA-158: regression test for the submodule-sanity pre-commit guard | ❌ |

## CLI / observability / pre-push / misc smoke  (`cli-observability-misc`)

45 scripts, 41 unmirrored (4 already mirrored).

| Script | Purpose | Mirrored in `src/preflight.rs`? |
|---|---|---|
| `test-ambient-schema.sh` | INFRA-101: regression test for the ambient-emit schema validator. | ❌ |
| `test-attribution-portable.sh` | CREDIBLE-045: verify generic agent attribution | ❌ |
| `test-book-sync-guard.sh` | INFRA-170: tests for the book/src ↔ docs/process sync guard in | ❌ |
| `test-changes-job-self-hosted.sh` | scripts/ci/test-changes-job-self-hosted.sh — INFRA-1537 | ❌ |
| `test-chump-improve.sh` | EFFECTIVE-177: Integration test for `chump improve <owner/repo>`. | ❌ |
| `test-chump-repos.sh` | MISSION-033 | ✅ |
| `test-chump-subcommand-help.sh` | scripts/ci/test-chump-subcommand-help.sh — INFRA-1238 (also referenced by INFRA-1246) | ✅ |
| `test-cli-fleet-coord.sh` | CREDIBLE-035 | ❌ |
| `test-cli-help.sh` | CREDIBLE-015: CLI help system consistency gate. | ❌ |
| `test-cli-integration.sh` | scripts/ci/test-cli-integration.sh | ❌ |
| `test-cli-version-debug.sh` | scripts/ci/test-cli-version-debug.sh — CREDIBLE-019 | ❌ |
| `test-deliberator-tick-emits.sh` | RESILIENT-061 AC #4: test-deliberator-tick-emits.sh | ❌ |
| `test-effective-010-completion.sh` | EFFECTIVE-010 | ❌ |
| `test-env-var-coverage.sh` | Asserts that every env var read by Chump's Rust source is either: | ✅ |
| `test-external-verify-merge.sh` | scripts/ci/test-external-verify-merge.sh | ❌ |
| `test-infra-109-worktree-boundary.sh` | INFRA-109 regression test. | ❌ |
| `test-infra-115-lease-ttl-file.sh` | INFRA-115: regression test for the file-based lease TTL reaper in | ❌ |
| `test-infra-119-bot-merge-hang.sh` | INFRA-119 — verify queue-health-monitor.sh detects stale bot-merge health files. | ❌ |
| `test-infra-124-docs-delta-trailer.sh` | INFRA-124 regression test. | ❌ |
| `test-infra-250-v1-retirement.sh` | CI acceptance test for INFRA-250: PWA v1 retirement. | ❌ |
| `test-infra-254-pwa-root-redirect.sh` | INFRA-254: GET / on the PWA must 301-redirect to /v2/. | ❌ |
| `test-infra-257-doc-only-guards.sh` | INFRA-257 regression test. | ❌ |
| `test-inspect-resume-scrap.sh` | scripts/ci/test-inspect-resume-scrap.sh — INFRA-1456 (eject-and-inspect) | ❌ |
| `test-install-ambient-hooks.sh` | FLEET-023 regression tests for the | ❌ |
| `test-keystone-cascade.sh` | scripts/ci/test-keystone-cascade.sh — INFRA-1420 | ❌ |
| `test-mcp-coord-smoke.sh` | INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys. | ❌ |
| `test-meta-011-git-stomp.sh` | META-011: regression test for concurrent chump-commit.sh calls on a shared | ❌ |
| `test-migration-pipeline-gates.sh` | scripts/ci/test-migration-pipeline-gates.sh — INFRA-1581 (closes INFRA-1538) | ❌ |
| `test-model-registry.sh` | INFRA-739 | ❌ |
| `test-obs-coverage-guard.sh` | INFRA-757 | ❌ |
| `test-observability-coverage.sh` | INFRA-757 | ❌ |
| `test-orchestrate-session-summary.sh` | scripts/ci/test-orchestrate-session-summary.sh — INFRA-1363 | ❌ |
| `test-pipefail-race-sweep.sh` | scripts/ci/test-pipefail-race-sweep.sh — INFRA-1658 | ✅ |
| `test-pre-push-force-lease-guard.sh` | INFRA-345 regression test. | ❌ |
| `test-pre-push-preflight-hook.sh` | scripts/ci/test-pre-push-preflight-hook.sh — INFRA-1671 regression test. | ❌ |
| `test-pre-push-rebase-allow.sh` | INFRA-368 regression test. | ❌ |
| `test-pre-push-test-gate.sh` | INFRA-761 regression tests. | ❌ |
| `test-research-026-preflight.sh` | CI-safe preflight for RESEARCH-026 harness + fixtures (no API calls). | ❌ |
| `test-review-handoff-smoke.sh` | INFRA-774 | ❌ |
| `test-rollup-semantic.sh` | scripts/ci/test-rollup-semantic.sh — INFRA-1455 (Marcus M-B converge) | ❌ |
| `test-run-fleet-cross-repo.sh` | INFRA-634 cross-repo fleet flags | ❌ |
| `test-sandbox-isolation.sh` | capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078) | ❌ |
| `test-self-hosted-runner-deps.sh` | INFRA-1556 | ❌ |
| `test-spike-isolation.sh` | INFRA-430 regression test. | ❌ |
| `test-subagent-epilogue-ref.sh` | INFRA-332 | ❌ |

## Totals

- **114** distinct `test-*.sh` scripts in the `fast-checks` job
- **10** already mirrored in `src/preflight.rs`
- **104** unmirrored — grouped above into 5 thematic clusters, each filed as its own META-070 sub-gap below

## Filed sub-gaps (one per cluster)

Each sub-gap: extend `src/preflight.rs` with a new gate function covering that cluster's unmirrored scripts, wired into `chump preflight`, skippable via a cluster-scoped env var (pattern: `CHUMP_PREFLIGHT_SKIP_<CLUSTER>`), plus a `scripts/ci/test-preflight-<cluster>.sh` smoke asserting the gate runs by default and is skippable.

| Sub-gap | Cluster | Unmirrored scripts covered |
|---|---|---|
| [`INFRA-3369`](./gaps/INFRA-3369.yaml) | gap-registry-claim-lifecycle | 10 scripts (claim-fuzzy-match, gap-divergence-guard, gap-doctor-safe-sweep, gap-id-cross-session, gap-id-lease-uniqueness, gap-reserve-concurrency, gap-reserve-padding, gap-status-flip, infra-1025-atomic-claim, pick-and-claim-lockdir) |
| [`INFRA-3370`](./gaps/INFRA-3370.yaml) | pr-merge-lifecycle | 18 scripts (bot-merge-auto-close, bot-merge-conflict-wiring, ci-flake-rerun, conflict-resolver, flake-autorerun, install-pr-auto-rebase, open-pr-dup-detection, pr-auto-rebase, pr-blocked-watch, pr-explain-block, pr-terminal-state, pr-triage-bot, pr-watch-auto-resolve, pr-watch-shepherd-smoke, rebase-coordination, speculative-on-speculative-guard, stale-branch-rebase, status-flip-proof-of-merge) |
| [`INFRA-3371`](./gaps/INFRA-3371.yaml) | fleet-daemon-reaper | 14 scripts (auto-arm-sweeper, autoscale-decisions, cargo-target-reaper, claude-reaper, fleet-brief, fleet-fanout, fleet-kill-switch, fleet-spec, fleet-starve-auto-action, infra-258-reaper-partial-delivery, stale-process-watchdog, subagent-budget-kill, supervision-trees, worktree-reaper-safety) |
| [`INFRA-3372`](./gaps/INFRA-3372.yaml) | docs-hygiene-guard | 21 scripts (credential-pattern-guard, cross-judge-guard, css-token-discipline, default-flip-guard, doc-freshness, docs-delta-commit-msg, docs-delta-guard, gate-promotion-no-regression, git-identity-guard, hardcoded-date-guard, md-links-loop, merge-driver-ci-yml, merge-driver-pre-commit, merge-driver-state-sql, no-claude-leak, no-verify-audit, preflight-ci-parity, prereg-content-guard, raw-yaml-guard, schema-version-assert, submodule-guard) |
| [`INFRA-3373`](./gaps/INFRA-3373.yaml) | cli-observability-misc | 41 scripts — full list in the cluster table above |

## Self-close condition

META-086 self-closes when INFRA-3373 (the last of the 5 sub-gaps) ships, per META-086 AC 4. Track sub-gap progress via `chump gap show INFRA-3369 INFRA-3370 INFRA-3371 INFRA-3372 INFRA-3373`.
