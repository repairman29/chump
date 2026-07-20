# Audit-job (fast-checks) preflight-mirror decomposition survey

META-086 survey. `.github/workflows/ci.yml` job `fast-checks` (L629-1171) invokes
114 distinct `scripts/ci/test-*.sh` scripts. 28 are already
mirrored in `src/preflight.rs`; 86 are not — those are
grouped below into 5 thematic clusters, each shippable as one META-070 sub-gap.

## Full script inventory

| script | purpose (from CI step name) | mirrored in preflight.rs? | cluster |
|---|---|---|---|
| `test-ambient-schema.sh` | ambient-jsonl emit-time schema validation (INFRA-101) | no | gap-state |
| `test-attribution-portable.sh` | model-ship-rate generic attribution (CREDIBLE-045) | no | misc-hygiene |
| `test-auto-arm-sweeper.sh` | auto-arm sweeper smoke + bypass (INFRA-382 / INFRA-374) | no | fleet-daemon |
| `test-autoscale-decisions.sh` | autoscale decisions smoke (INFRA-1581) | no | fleet-daemon |
| `test-book-sync-guard.sh` | book/src ↔ docs/process sync guard (INFRA-170) | no | misc-hygiene |
| `test-bot-merge-auto-close.sh` | bot-merge auto-close handshake (INFRA-154) | no | pr-lifecycle |
| `test-bot-merge-conflict-wiring.sh` | bot-merge conflict-resolver wiring (INFRA-1657) | no | pr-lifecycle |
| `test-cargo-target-reaper.sh` | cargo-target-reaper — dry-run, --execute, safety guards, ambient event (INFRA-1250) | no | fleet-daemon |
| `test-changes-job-self-hosted.sh` | changes-job self-hosted routing (INFRA-1537) | no | ci-observability |
| `test-chump-improve.sh` | chump improve orchestrator — 4-stage mock chain (EFFECTIVE-177) | no | fleet-daemon |
| `test-chump-repos.sh` | repos table migration + CLI + auto-import (MISSION-033) | yes | - |
| `test-chump-subcommand-help.sh` | chump subcommand --help regression gate (INFRA-1246) | yes | - |
| `test-ci-flake-rerun.sh` | CI-flake auto-rerun smoke — bypass + empty + flake match + cooldown (INFRA-375) | no | ci-observability |
| `test-claim-fuzzy-match.sh` | claim-time fuzzy-match (INFRA-1442 duplicate-claim prevention) | no | gap-state |
| `test-claude-reaper.sh` | claude orphan reaper (INFRA-1662) | no | fleet-daemon |
| `test-cli-fleet-coord.sh` | CLI fleet + health + coord commands (CREDIBLE-035) | no | fleet-daemon |
| `test-cli-help.sh` | CLI help system consistency — all 31 commands have Usage strings (CREDIBLE-015) | no | misc-hygiene |
| `test-cli-integration.sh` | CLI integration tests by command category — 31 commands (CREDIBLE-018) | no | misc-hygiene |
| `test-cli-version-debug.sh` | CLI version/debug flags (CREDIBLE-019) | no | misc-hygiene |
| `test-conflict-resolver.sh` | conflict-resolver-agent (INFRA-1488 Marcus M-C) | no | pr-lifecycle |
| `test-credential-pattern-guard.sh` | credential-pattern guard (INFRA-158) | no | gap-state |
| `test-cross-judge-guard.sh` | cross-judge audit guard (INFRA-079) | no | misc-hygiene |
| `test-css-token-discipline.sh` | CSS token-discipline smoke (INFRA-1590) | no | misc-hygiene |
| `test-default-flip-guard.sh` | default-flip advisory guard (INFRA-762) | no | misc-hygiene |
| `test-deliberator-tick-emits.sh` | deliberator tick emits consensus_result — numeric epoch guard + idempotency (RESILIENT-061) | no | fleet-daemon |
| `test-doc-freshness.sh` | doc-freshness audit (DOC-041, warn-only) | no | misc-hygiene |
| `test-docs-delta-commit-msg.sh` | commit-msg docs-delta trailer check (INFRA-1969) | no | gap-state |
| `test-docs-delta-guard.sh` | docs-delta guard (INFRA-158) | no | gap-state |
| `test-effective-010-completion.sh` | shell completion subcommand source assertions (EFFECTIVE-010) | no | misc-hygiene |
| `test-env-var-coverage.sh` | env-var coverage — all src/ reads documented or allowlisted (DOC-026) | yes | - |
| `test-external-verify-merge.sh` | external verify-merge judge — 5-case synthetic matrix (CREDIBLE-096) | no | pr-lifecycle |
| `test-farmer.sh` | farmer un-killable control-plane tender (RESILIENT-068) | yes | - |
| `test-flake-autorerun.sh` | flake-autorerun harness fixture (INFRA-764) | no | ci-observability |
| `test-fleet-brief.sh` | fleet brief subcommand (INFRA-721) | no | ci-observability |
| `test-fleet-fanout.sh` | fleet-fanout primitive (INFRA-1484 Marcus M-B) | no | fleet-daemon |
| `test-fleet-kill-switch.sh` | fleet kill switch — AUTONOMY_LEVEL fail-closed (RESILIENT-073) | no | fleet-daemon |
| `test-fleet-pause-autolift.sh` | fleet-pause autolift + pause-immune recovery choir (RESILIENT-066) | yes | - |
| `test-fleet-spec.sh` | fleet-spec primitive (INFRA-1483 Marcus M-B) | no | fleet-daemon |
| `test-fleet-starve-auto-action.sh` | fleet starve auto-action (INFRA-391) | no | fleet-daemon |
| `test-gap-divergence-guard.sh` | gap-divergence guard (INFRA-783) | no | gap-state |
| `test-gap-doctor-safe-sweep.sh` | gap-doctor safe-sweep (INFRA-308) | no | gap-state |
| `test-gap-id-cross-session.sh` | gap-ID cross-session collision prevention (CREDIBLE-052) | no | gap-state |
| `test-gap-id-lease-uniqueness.sh` | gap-ID lease uniqueness gate — duplicate-PR race prevention (INFRA-1970) | no | gap-state |
| `test-gap-preflight-ac-gate.sh` | gap-preflight AC gate + picker AC filter (INFRA-1259) | yes | - |
| `test-gap-reserve-concurrency.sh` | gap-reserve concurrency (INFRA-021) | no | gap-state |
| `test-gap-reserve-padding.sh` | gap-reserve ID zero-padding (INFRA-080) | no | gap-state |
| `test-gap-status-flip.sh` | gap-status-flip guard (INFRA-158) | no | gap-state |
| `test-gate-promotion-no-regression.sh` | CI gate promotion no-regression (INFRA-1869) | no | pr-lifecycle |
| `test-git-identity-guard.sh` | git-identity sanity guard (INFRA-787) | no | gap-state |
| `test-hardcoded-date-guard.sh` | hardcoded-date guard (INFRA-971) | no | gap-state |
| `test-infra-1025-atomic-claim.sh` | atomic claim no-shell-out + thin-wrapper assertions (INFRA-1025) | no | misc-hygiene |
| `test-infra-109-worktree-boundary.sh` | worktree-boundary path resolution (INFRA-109) | no | fleet-daemon |
| `test-infra-115-lease-ttl-file.sh` | lease TTL file-based reaper (INFRA-115) | no | fleet-daemon |
| `test-infra-119-bot-merge-hang.sh` | bot-merge health monitoring + hung-process detection (INFRA-119) | no | pr-lifecycle |
| `test-infra-124-docs-delta-trailer.sh` | docs-delta trailer validation (INFRA-124) | no | gap-state |
| `test-infra-250-v1-retirement.sh` | PWA v1 retirement — assets deleted, tauri.conf.json, v2 wizard (INFRA-250) | no | misc-hygiene |
| `test-infra-254-pwa-root-redirect.sh` | PWA root redirect / -> /v2/ (INFRA-254) | no | misc-hygiene |
| `test-infra-257-doc-only-guards.sh` | doc-only commits run all guards (INFRA-257) | no | misc-hygiene |
| `test-infra-258-reaper-partial-delivery.sh` | stale-pr-reaper file-parity check (INFRA-258) | no | misc-hygiene |
| `test-inspect-resume-scrap.sh` | inspect/resume/scrap surface (INFRA-1456) | no | ci-observability |
| `test-install-ambient-hooks.sh` | install-ambient-hooks idempotence + bypass (FLEET-023) | no | misc-hygiene |
| `test-install-pr-auto-rebase.sh` | pr-auto-rebase plist installer (INFRA-1779) | no | pr-lifecycle |
| `test-keystone-cascade.sh` | paramedic keystone-cascade (INFRA-1420) | no | fleet-daemon |
| `test-markdown-intra-doc-links.sh` | markdown intra-doc links (DOC-039) | yes | - |
| `test-mcp-coord-smoke.sh` | chump-mcp-coord tools/list (INFRA-033) | no | fleet-daemon |
| `test-md-links-loop.sh` | md-links-loop smoke (INFRA-1925) | no | misc-hygiene |
| `test-merge-driver-ci-yml.sh` | ci.yml merge driver smoke (INFRA-310) | no | misc-hygiene |
| `test-merge-driver-pre-commit.sh` | pre-commit merge driver smoke (INFRA-310) | no | misc-hygiene |
| `test-merge-driver-state-sql.sh` | state.sql merge driver smoke (INFRA-310) | no | misc-hygiene |
| `test-merged-check-guard.sh` | pre-push MERGED guard (INFRA-306) | yes | - |
| `test-meta-011-git-stomp.sh` | git index mutex — concurrent chump-commit.sh stomp guard (META-011) | no | misc-hygiene |
| `test-migration-pipeline-gates.sh` | migration-pipeline gates smoke (INFRA-1581 / closes INFRA-1538) | no | gap-state |
| `test-model-registry.sh` | model-registry schema validation (INFRA-739) | no | gap-state |
| `test-no-claude-leak.sh` | no-claude-leak audit (INFRA-1051, warn-only, changed-only) | no | misc-hygiene |
| `test-no-verify-audit.sh` | --no-verify audit guard (INFRA-1834) | no | misc-hygiene |
| `test-obs-coverage-guard.sh` | observability coverage — new src/dispatch.sh and src/main-reachable .rs need a tracing/ambient/lessons hook (INFRA-757) | no | ci-observability |
| `test-observability-coverage.sh` | observability coverage — live PR diff against base ref (INFRA-757) | no | ci-observability |
| `test-open-pr-dup-detection.sh` | open-PR dedup gate at claim time (INFRA-1982) | no | pr-lifecycle |
| `test-orchestrate-session-summary.sh` | orchestrate session-summary ambient emit (INFRA-1363) | no | ci-observability |
| `test-pick-and-claim-lockdir.sh` | pick-and-claim lock-dir resolves to main repo from linked worktree (INFRA-466/467) | no | misc-hygiene |
| `test-pipefail-race-sweep.sh` | pipefail race sweep (INFRA-1658) | yes | - |
| `test-pr-auto-rebase.sh` | pr-auto-rebase daemon (INFRA-1777) | no | pr-lifecycle |
| `test-pr-blocked-watch.sh` | pr-blocked-watch smoke (INFRA-550) | no | pr-lifecycle |
| `test-pr-explain-block.sh` | chump pr explain-block (INFRA-1416 stuck-PR diagnostic) | no | pr-lifecycle |
| `test-pr-terminal-state.sh` | pr-terminal-state helper — mergedAt-validated (INFRA-1981) | no | pr-lifecycle |
| `test-pr-triage-bot.sh` | pr-triage-bot smoke + YAML parse (INFRA-624/648) | no | pr-lifecycle |
| `test-pr-watch-auto-resolve.sh` | pr-watch auto-resolve recipe (INFRA-387) | no | pr-lifecycle |
| `test-pr-watch-shepherd-smoke.sh` | pr-watch shepherd smoke (INFRA-354) | no | pr-lifecycle |
| `test-pre-push-force-lease-guard.sh` | pre-push --force-with-lease race guard (INFRA-345) | no | pr-lifecycle |
| `test-pre-push-preflight-hook.sh` | pre-push preflight guard (INFRA-1671) | no | pr-lifecycle |
| `test-pre-push-rebase-allow.sh` | pre-push rebase-detect auto-skip (INFRA-368) | no | pr-lifecycle |
| `test-pre-push-test-gate.sh` | pre-push cargo-test full-suite gate (INFRA-761) | no | pr-lifecycle |
| `test-preflight-ci-parity.sh` | preflight-vs-CI parity smoke (INFRA-1867) | no | ci-observability |
| `test-prereg-content-guard.sh` | preregistration content guard (INFRA-113) | no | misc-hygiene |
| `test-raw-yaml-guard.sh` | raw-YAML-edit guard (INFRA-200, blocking since 2026-05-02) | no | gap-state |
| `test-rebase-coordination.sh` | pr-auto-rebase per-branch lock — operator-race fix (INFRA-1974) | no | pr-lifecycle |
| `test-research-026-preflight.sh` | RESEARCH-026 observer-effect harness preflight (no API) | no | misc-hygiene |
| `test-review-handoff-smoke.sh` | Review-as-Handoff end-to-end smoke test (INFRA-774) | no | misc-hygiene |
| `test-rollup-semantic.sh` | fan-out rollup --semantic (INFRA-1455 Marcus M-B converge) | no | misc-hygiene |
| `test-run-fleet-cross-repo.sh` | run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634) | no | fleet-daemon |
| `test-sandbox-isolation.sh` | agent-bash sandbox pilot (INFRA-1454) | no | fleet-daemon |
| `test-schema-version-assert.sh` | schema_version assert helper — unit tests for assert-schema.sh (INFRA-1978) | no | gap-state |
| `test-self-hosted-runner-deps.sh` | Self-hosted runner deps preflight (INFRA-1556) | no | ci-observability |
| `test-speculative-on-speculative-guard.sh` | speculative-on-speculative arm guard (INFRA-684) | no | pr-lifecycle |
| `test-spike-isolation.sh` | spike scripts isolated from production state.db (INFRA-430) | no | fleet-daemon |
| `test-stale-branch-rebase.sh` | paramedic stale-branch auto-rebase (INFRA-1429) | no | pr-lifecycle |
| `test-stale-pr-rebase-bot.sh` | stale-pr-rebase-bot — 3-strike circuit-break (INFRA-2295) | yes | - |
| `test-stale-process-watchdog.sh` | stale-process watchdog (INFRA-1663) | no | fleet-daemon |
| `test-status-flip-proof-of-merge.sh` | gap-store proof-of-merge guard (INFRA-1392) | no | pr-lifecycle |
| `test-subagent-budget-kill.sh` | subagent budget kill — parent-enforced SIGTERM+grace+SIGKILL (INFRA-1972) | no | misc-hygiene |
| `test-subagent-epilogue-ref.sh` | subagent-shipping-epilogue reference guard (INFRA-332) | no | misc-hygiene |
| `test-submodule-guard.sh` | submodule-sanity guard (INFRA-158) | no | gap-state |
| `test-supervision-trees.sh` | supervision trees — per-gap + fleet restart-intensity (RESILIENT-058) | no | fleet-daemon |
| `test-worktree-reaper-safety.sh` | worktree-reaper active-worktree safety guard (INFRA-1074) | no | fleet-daemon |

## Clusters (unmirrored scripts, grouped for META-070 sub-gaps)

### gap/state-registry consistency gates (20 scripts)

- `test-ambient-schema.sh` — ambient-jsonl emit-time schema validation (INFRA-101)
- `test-claim-fuzzy-match.sh` — claim-time fuzzy-match (INFRA-1442 duplicate-claim prevention)
- `test-credential-pattern-guard.sh` — credential-pattern guard (INFRA-158)
- `test-docs-delta-commit-msg.sh` — commit-msg docs-delta trailer check (INFRA-1969)
- `test-docs-delta-guard.sh` — docs-delta guard (INFRA-158)
- `test-gap-divergence-guard.sh` — gap-divergence guard (INFRA-783)
- `test-gap-doctor-safe-sweep.sh` — gap-doctor safe-sweep (INFRA-308)
- `test-gap-id-cross-session.sh` — gap-ID cross-session collision prevention (CREDIBLE-052)
- `test-gap-id-lease-uniqueness.sh` — gap-ID lease uniqueness gate — duplicate-PR race prevention (INFRA-1970)
- `test-gap-reserve-concurrency.sh` — gap-reserve concurrency (INFRA-021)
- `test-gap-reserve-padding.sh` — gap-reserve ID zero-padding (INFRA-080)
- `test-gap-status-flip.sh` — gap-status-flip guard (INFRA-158)
- `test-git-identity-guard.sh` — git-identity sanity guard (INFRA-787)
- `test-hardcoded-date-guard.sh` — hardcoded-date guard (INFRA-971)
- `test-infra-124-docs-delta-trailer.sh` — docs-delta trailer validation (INFRA-124)
- `test-migration-pipeline-gates.sh` — migration-pipeline gates smoke (INFRA-1581 / closes INFRA-1538)
- `test-model-registry.sh` — model-registry schema validation (INFRA-739)
- `test-raw-yaml-guard.sh` — raw-YAML-edit guard (INFRA-200, blocking since 2026-05-02)
- `test-schema-version-assert.sh` — schema_version assert helper — unit tests for assert-schema.sh (INFRA-1978)
- `test-submodule-guard.sh` — submodule-sanity guard (INFRA-158)

### worker/PR-lifecycle + merge-safety gates (23 scripts)

- `test-bot-merge-auto-close.sh` — bot-merge auto-close handshake (INFRA-154)
- `test-bot-merge-conflict-wiring.sh` — bot-merge conflict-resolver wiring (INFRA-1657)
- `test-conflict-resolver.sh` — conflict-resolver-agent (INFRA-1488 Marcus M-C)
- `test-external-verify-merge.sh` — external verify-merge judge — 5-case synthetic matrix (CREDIBLE-096)
- `test-gate-promotion-no-regression.sh` — CI gate promotion no-regression (INFRA-1869)
- `test-infra-119-bot-merge-hang.sh` — bot-merge health monitoring + hung-process detection (INFRA-119)
- `test-install-pr-auto-rebase.sh` — pr-auto-rebase plist installer (INFRA-1779)
- `test-open-pr-dup-detection.sh` — open-PR dedup gate at claim time (INFRA-1982)
- `test-pr-auto-rebase.sh` — pr-auto-rebase daemon (INFRA-1777)
- `test-pr-blocked-watch.sh` — pr-blocked-watch smoke (INFRA-550)
- `test-pr-explain-block.sh` — chump pr explain-block (INFRA-1416 stuck-PR diagnostic)
- `test-pr-terminal-state.sh` — pr-terminal-state helper — mergedAt-validated (INFRA-1981)
- `test-pr-triage-bot.sh` — pr-triage-bot smoke + YAML parse (INFRA-624/648)
- `test-pr-watch-auto-resolve.sh` — pr-watch auto-resolve recipe (INFRA-387)
- `test-pr-watch-shepherd-smoke.sh` — pr-watch shepherd smoke (INFRA-354)
- `test-pre-push-force-lease-guard.sh` — pre-push --force-with-lease race guard (INFRA-345)
- `test-pre-push-preflight-hook.sh` — pre-push preflight guard (INFRA-1671)
- `test-pre-push-rebase-allow.sh` — pre-push rebase-detect auto-skip (INFRA-368)
- `test-pre-push-test-gate.sh` — pre-push cargo-test full-suite gate (INFRA-761)
- `test-rebase-coordination.sh` — pr-auto-rebase per-branch lock — operator-race fix (INFRA-1974)
- `test-speculative-on-speculative-guard.sh` — speculative-on-speculative arm guard (INFRA-684)
- `test-stale-branch-rebase.sh` — paramedic stale-branch auto-rebase (INFRA-1429)
- `test-status-flip-proof-of-merge.sh` — gap-store proof-of-merge guard (INFRA-1392)

### fleet daemon/reaper/isolation gates (21 scripts)

- `test-auto-arm-sweeper.sh` — auto-arm sweeper smoke + bypass (INFRA-382 / INFRA-374)
- `test-autoscale-decisions.sh` — autoscale decisions smoke (INFRA-1581)
- `test-cargo-target-reaper.sh` — cargo-target-reaper — dry-run, --execute, safety guards, ambient event (INFRA-1250)
- `test-chump-improve.sh` — chump improve orchestrator — 4-stage mock chain (EFFECTIVE-177)
- `test-claude-reaper.sh` — claude orphan reaper (INFRA-1662)
- `test-cli-fleet-coord.sh` — CLI fleet + health + coord commands (CREDIBLE-035)
- `test-deliberator-tick-emits.sh` — deliberator tick emits consensus_result — numeric epoch guard + idempotency (RESILIENT-061)
- `test-fleet-fanout.sh` — fleet-fanout primitive (INFRA-1484 Marcus M-B)
- `test-fleet-kill-switch.sh` — fleet kill switch — AUTONOMY_LEVEL fail-closed (RESILIENT-073)
- `test-fleet-spec.sh` — fleet-spec primitive (INFRA-1483 Marcus M-B)
- `test-fleet-starve-auto-action.sh` — fleet starve auto-action (INFRA-391)
- `test-infra-109-worktree-boundary.sh` — worktree-boundary path resolution (INFRA-109)
- `test-infra-115-lease-ttl-file.sh` — lease TTL file-based reaper (INFRA-115)
- `test-keystone-cascade.sh` — paramedic keystone-cascade (INFRA-1420)
- `test-mcp-coord-smoke.sh` — chump-mcp-coord tools/list (INFRA-033)
- `test-run-fleet-cross-repo.sh` — run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634)
- `test-sandbox-isolation.sh` — agent-bash sandbox pilot (INFRA-1454)
- `test-spike-isolation.sh` — spike scripts isolated from production state.db (INFRA-430)
- `test-stale-process-watchdog.sh` — stale-process watchdog (INFRA-1663)
- `test-supervision-trees.sh` — supervision trees — per-gap + fleet restart-intensity (RESILIENT-058)
- `test-worktree-reaper-safety.sh` — worktree-reaper active-worktree safety guard (INFRA-1074)

### CI infra + observability-coverage gates (10 scripts)

- `test-changes-job-self-hosted.sh` — changes-job self-hosted routing (INFRA-1537)
- `test-ci-flake-rerun.sh` — CI-flake auto-rerun smoke — bypass + empty + flake match + cooldown (INFRA-375)
- `test-flake-autorerun.sh` — flake-autorerun harness fixture (INFRA-764)
- `test-fleet-brief.sh` — fleet brief subcommand (INFRA-721)
- `test-inspect-resume-scrap.sh` — inspect/resume/scrap surface (INFRA-1456)
- `test-obs-coverage-guard.sh` — observability coverage — new src/dispatch.sh and src/main-reachable .rs need a tracing/ambient/lessons hook (INFRA-757)
- `test-observability-coverage.sh` — observability coverage — live PR diff against base ref (INFRA-757)
- `test-orchestrate-session-summary.sh` — orchestrate session-summary ambient emit (INFRA-1363)
- `test-preflight-ci-parity.sh` — preflight-vs-CI parity smoke (INFRA-1867)
- `test-self-hosted-runner-deps.sh` — Self-hosted runner deps preflight (INFRA-1556)

### docs/CLI/git-hooks hygiene guards (30 scripts)

- `test-attribution-portable.sh` — model-ship-rate generic attribution (CREDIBLE-045)
- `test-book-sync-guard.sh` — book/src ↔ docs/process sync guard (INFRA-170)
- `test-cli-help.sh` — CLI help system consistency — all 31 commands have Usage strings (CREDIBLE-015)
- `test-cli-integration.sh` — CLI integration tests by command category — 31 commands (CREDIBLE-018)
- `test-cli-version-debug.sh` — CLI version/debug flags (CREDIBLE-019)
- `test-cross-judge-guard.sh` — cross-judge audit guard (INFRA-079)
- `test-css-token-discipline.sh` — CSS token-discipline smoke (INFRA-1590)
- `test-default-flip-guard.sh` — default-flip advisory guard (INFRA-762)
- `test-doc-freshness.sh` — doc-freshness audit (DOC-041, warn-only)
- `test-effective-010-completion.sh` — shell completion subcommand source assertions (EFFECTIVE-010)
- `test-infra-1025-atomic-claim.sh` — atomic claim no-shell-out + thin-wrapper assertions (INFRA-1025)
- `test-infra-250-v1-retirement.sh` — PWA v1 retirement — assets deleted, tauri.conf.json, v2 wizard (INFRA-250)
- `test-infra-254-pwa-root-redirect.sh` — PWA root redirect / -> /v2/ (INFRA-254)
- `test-infra-257-doc-only-guards.sh` — doc-only commits run all guards (INFRA-257)
- `test-infra-258-reaper-partial-delivery.sh` — stale-pr-reaper file-parity check (INFRA-258)
- `test-install-ambient-hooks.sh` — install-ambient-hooks idempotence + bypass (FLEET-023)
- `test-md-links-loop.sh` — md-links-loop smoke (INFRA-1925)
- `test-merge-driver-ci-yml.sh` — ci.yml merge driver smoke (INFRA-310)
- `test-merge-driver-pre-commit.sh` — pre-commit merge driver smoke (INFRA-310)
- `test-merge-driver-state-sql.sh` — state.sql merge driver smoke (INFRA-310)
- `test-meta-011-git-stomp.sh` — git index mutex — concurrent chump-commit.sh stomp guard (META-011)
- `test-no-claude-leak.sh` — no-claude-leak audit (INFRA-1051, warn-only, changed-only)
- `test-no-verify-audit.sh` — --no-verify audit guard (INFRA-1834)
- `test-pick-and-claim-lockdir.sh` — pick-and-claim lock-dir resolves to main repo from linked worktree (INFRA-466/467)
- `test-prereg-content-guard.sh` — preregistration content guard (INFRA-113)
- `test-research-026-preflight.sh` — RESEARCH-026 observer-effect harness preflight (no API)
- `test-review-handoff-smoke.sh` — Review-as-Handoff end-to-end smoke test (INFRA-774)
- `test-rollup-semantic.sh` — fan-out rollup --semantic (INFRA-1455 Marcus M-B converge)
- `test-subagent-budget-kill.sh` — subagent budget kill — parent-enforced SIGTERM+grace+SIGKILL (INFRA-1972)
- `test-subagent-epilogue-ref.sh` — subagent-shipping-epilogue reference guard (INFRA-332)

