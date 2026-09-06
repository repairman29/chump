# Audit-job (`fast-checks`) preflight mirror decomposition — C3 slice

Recovered slice of the META-070/META-086 audit-job decomposition survey
(source: INFRA-3361, cluster C3). Prior full-survey doc attempts never
landed on `main` (see `docs/gaps/INFRA-3385.yaml` for the cluster-2/5
sibling sub-gap); this file captures the C3 table so `chump preflight`'s
discovery list has a durable, checked-in source of truth for this cluster.

## C3-pr-worker-lifecycle: PR/worker lifecycle & merge automation gates (25 total)

| Script | Purpose (ci.yml step name) | Mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-bot-merge-auto-close.sh` | bot-merge auto-close on gap ship | yes |
| `scripts/ci/test-bot-merge-conflict-wiring.sh` | bot-merge conflict-resolver wiring (INFRA-1657) | yes |
| `scripts/ci/test-conflict-resolver.sh` | conflict-resolver-agent (INFRA-1488 Marcus M-C) | yes |
| `scripts/ci/test-external-verify-merge.sh` | external verify-merge judge — 5-case synthetic matrix (CREDIBLE-096) | yes |
| `scripts/ci/test-gate-promotion-no-regression.sh` | CI gate promotion no-regression (INFRA-1869) | yes |
| `scripts/ci/test-infra-119-bot-merge-hang.sh` | bot-merge health monitoring + hung-process detection (INFRA-119) | yes |
| `scripts/ci/test-install-pr-auto-rebase.sh` | pr-auto-rebase plist installer (INFRA-1779) | yes |
| `scripts/ci/test-merged-check-guard.sh` | pre-push MERGED guard (INFRA-306) | yes |
| `scripts/ci/test-no-verify-audit.sh` | --no-verify audit guard (INFRA-1834) | yes |
| `scripts/ci/test-pr-auto-rebase.sh` | pr-auto-rebase daemon (INFRA-1777) | yes |
| `scripts/ci/test-pr-blocked-watch.sh` | pr-blocked-watch smoke (INFRA-550) | yes |
| `scripts/ci/test-pr-explain-block.sh` | chump pr explain-block (INFRA-1416 stuck-PR diagnostic) | yes |
| `scripts/ci/test-pr-terminal-state.sh` | pr-terminal-state helper — mergedAt-validated (INFRA-1981) | yes |
| `scripts/ci/test-pr-triage-bot.sh` | pr-triage-bot smoke + YAML parse (INFRA-624/648) | yes |
| `scripts/ci/test-pr-watch-auto-resolve.sh` | pr-watch auto-resolve recipe (INFRA-387) | yes |
| `scripts/ci/test-pr-watch-shepherd-smoke.sh` | pr-watch shepherd smoke (INFRA-354) | yes |
| `scripts/ci/test-pre-push-preflight-hook.sh` | pre-push preflight guard (INFRA-1671) | yes |
| `scripts/ci/test-pre-push-rebase-allow.sh` | pre-push rebase-detect auto-skip (INFRA-368) | yes |
| `scripts/ci/test-pre-push-test-gate.sh` | pre-push cargo-test full-suite gate (INFRA-761) | yes |
| `scripts/ci/test-preflight-ci-parity.sh` | preflight-vs-CI parity smoke (INFRA-1867) | yes |
| `scripts/ci/test-rebase-coordination.sh` | pr-auto-rebase per-branch lock — operator-race fix (INFRA-1974) | yes |
| `scripts/ci/test-review-handoff-smoke.sh` | Review-as-Handoff end-to-end smoke test (INFRA-774) | yes |
| `scripts/ci/test-stale-branch-rebase.sh` | paramedic stale-branch auto-rebase (INFRA-1429) | yes |
| `scripts/ci/test-stale-pr-rebase-bot.sh` | stale-pr-rebase-bot — 3-strike circuit-break (INFRA-2295) | yes |
| `scripts/ci/test-status-flip-proof-of-merge.sh` | gap-store proof-of-merge guard (INFRA-1392) | yes |

All 25 scripts in the C3 cluster are now wired into `chump preflight`
(`crates/chump-preflight/src/preflight.rs`, INFRA-4050). See
`docs/gaps/INFRA-3385.yaml` for the historical cluster-2/5 framing of this
same script set under the original META-086 survey numbering.

## cli-observability-misc: CLI/observability/cost/telemetry grab-bag (41 total)

Lowest-priority, highest-count cluster from the same META-070/META-086
survey (source: INFRA-3373, cluster 5/5). One-off smoke tests with the
lowest per-script cascade risk.

| Script | Mirrored in preflight.rs |
|---|---|
| `scripts/ci/test-acp-real-clients.sh` | yes |
| `scripts/ci/test-api-chat-cost-kill.sh` | yes |
| `scripts/ci/test-api-cost-leaderboard.sh` | yes |
| `scripts/ci/test-cascade-rebase-observability.sh` | yes |
| `scripts/ci/test-chump-fleet-cli.sh` | yes |
| `scripts/ci/test-chump-skill-cli.sh` | yes |
| `scripts/ci/test-cli-aliases.sh` | yes |
| `scripts/ci/test-cli-arg-validation.sh` | yes |
| `scripts/ci/test-cli-exit-codes.sh` | yes |
| `scripts/ci/test-cli-fleet-coord.sh` | yes |
| `scripts/ci/test-cli-help.sh` | yes |
| `scripts/ci/test-cli-integration.sh` | yes |
| `scripts/ci/test-cli-output-format.sh` | yes |
| `scripts/ci/test-cli-product-surface.sh` | yes |
| `scripts/ci/test-cog-043-action-telemetry.sh` | yes |
| `scripts/ci/test-cost-enforcement.sh` | yes |
| `scripts/ci/test-cost-per-model.sh` | yes |
| `scripts/ci/test-cost-watch.sh` | yes |
| `scripts/ci/test-coupling-cost.sh` | yes |
| `scripts/ci/test-cursor-cli-integration.sh` | yes |
| `scripts/ci/test-doc-only-clippy-skip.sh` | yes |
| `scripts/ci/test-event-registry-guard.sh` | yes |
| `scripts/ci/test-fleet-metrics-snapshot.sh` | yes |
| `scripts/ci/test-gap-closed-pr-cli.sh` | yes |
| `scripts/ci/test-gate-telemetry.sh` | yes |
| `scripts/ci/test-gen-cost-summary.sh` | yes |
| `scripts/ci/test-github-api-telemetry.sh` | yes |
| `scripts/ci/test-github-api-telemetry-shim.sh` | yes |
| `scripts/ci/test-harvester-cli.sh` | yes |
| `scripts/ci/test-infra-1062-clippy-timeout-silent-exit.sh` | yes |
| `scripts/ci/test-observability-coverage.sh` | yes |
| `scripts/ci/test-observability-loop.sh` | yes |
| `scripts/ci/test-pr-cost-telemetry.sh` | yes |
| `scripts/ci/test-pr-fix-clippy.sh` | yes |
| `scripts/ci/test-pr-stuck-cluster-observability.sh` | yes |
| `scripts/ci/test-pr-unstick-observability.sh` | yes |
| `scripts/ci/test-pwa-cost-ceiling.sh` | yes |
| `scripts/ci/test-pwa-version-compat.sh` | yes |
| `scripts/ci/test-pwa-workflow-observability.sh` | yes |
| `scripts/ci/test-telemetry-cost.sh` | yes |
| `scripts/ci/test-worker-preship-clippy.sh` | yes |

All 41 scripts in the cli-observability-misc cluster are wired into
`chump preflight`'s `cli_observability_misc` gate
(`crates/chump-preflight/src/preflight.rs`, INFRA-5000), skippable via
`CHUMP_PREFLIGHT_SKIP_CLI_MISC=1`.
