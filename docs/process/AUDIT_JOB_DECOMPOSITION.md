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
