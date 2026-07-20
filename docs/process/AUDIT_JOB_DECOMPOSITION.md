# Audit-job decomposition survey (META-086)

Survey of every `scripts/ci/test-*.sh` invoked by the `fast-checks` job in
`.github/workflows/ci.yml` (the job referred to as "the audit job" in
INFRA-1856's closure note — it runs ~100+ guard/smoke scripts per PR, not
the 2-3 originally assumed when INFRA-1856 was filed). For each script:
purpose (from its ci.yml step name) + whether it is already mirrored in
`chump preflight` (`src/preflight.rs`).

Total scripts invoked by fast-checks: 114
Already mirrored in preflight.rs: 10
Unmirrored: 104

## Clusters (unmirrored scripts grouped for follow-up sub-gaps)

### C1-doc-commit-hygiene-guards: Doc/commit hygiene guards (21 unmirrored / 23 total)

| Script | Purpose (ci.yml step name) | Mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-ambient-schema.sh` | ambient-jsonl emit-time schema validation (INFRA-101) | no |
| `scripts/ci/test-book-sync-guard.sh` | book/src ↔ docs/process sync guard (INFRA-170) | no |
| `scripts/ci/test-credential-pattern-guard.sh` | credential-pattern guard (INFRA-158) | no |
| `scripts/ci/test-cross-judge-guard.sh` | cross-judge audit guard (INFRA-079) | no |
| `scripts/ci/test-css-token-discipline.sh` | CSS token-discipline smoke (INFRA-1590) | no |
| `scripts/ci/test-doc-freshness.sh` | doc-freshness audit (DOC-041, warn-only) | no |
| `scripts/ci/test-docs-delta-commit-msg.sh` | commit-msg docs-delta trailer check (INFRA-1969) | no |
| `scripts/ci/test-docs-delta-guard.sh` | docs-delta guard (INFRA-158) | no |
| `scripts/ci/test-env-var-coverage.sh` | env-var coverage — all src/ reads documented or allowlisted (DOC-026) | yes |
| `scripts/ci/test-git-identity-guard.sh` | git-identity sanity guard (INFRA-787) | no |
| `scripts/ci/test-hardcoded-date-guard.sh` | hardcoded-date guard (INFRA-971) | no |
| `scripts/ci/test-infra-124-docs-delta-trailer.sh` | docs-delta trailer validation (INFRA-124) | no |
| `scripts/ci/test-markdown-intra-doc-links.sh` | markdown intra-doc links (DOC-039) | yes |
| `scripts/ci/test-merge-driver-ci-yml.sh` | ci.yml merge driver smoke (INFRA-310) | no |
| `scripts/ci/test-merge-driver-pre-commit.sh` | pre-commit merge driver smoke (INFRA-310) | no |
| `scripts/ci/test-merge-driver-state-sql.sh` | state.sql merge driver smoke (INFRA-310) | no |
| `scripts/ci/test-no-claude-leak.sh` | no-claude-leak audit (INFRA-1051, warn-only, changed-only) | no |
| `scripts/ci/test-obs-coverage-guard.sh` | observability coverage — new src/dispatch.sh and src/main-reachable .rs need a tracing/ambient/lessons hook (INFRA-757) | no |
| `scripts/ci/test-observability-coverage.sh` | observability coverage — live PR diff against base ref (INFRA-757) | no |
| `scripts/ci/test-prereg-content-guard.sh` | preregistration content guard (INFRA-113) | no |
| `scripts/ci/test-raw-yaml-guard.sh` | raw-YAML-edit guard (INFRA-200, blocking since 2026-05-02) | no |
| `scripts/ci/test-schema-version-assert.sh` | schema_version assert helper — unit tests for assert-schema.sh (INFRA-1978) | no |
| `scripts/ci/test-submodule-guard.sh` | submodule-sanity guard (INFRA-158) | no |

### C2-gap-state-claim-consistency: Gap-state & claim/lease consistency gates (17 unmirrored / 18 total)

| Script | Purpose (ci.yml step name) | Mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-claim-fuzzy-match.sh` | claim-time fuzzy-match (INFRA-1442 duplicate-claim prevention) | no |
| `scripts/ci/test-gap-divergence-guard.sh` | gap-divergence guard (INFRA-783) | no |
| `scripts/ci/test-gap-doctor-safe-sweep.sh` | gap-doctor safe-sweep (INFRA-308) | no |
| `scripts/ci/test-gap-id-cross-session.sh` | gap-id cross-session uniqueness | no |
| `scripts/ci/test-gap-id-lease-uniqueness.sh` | gap-id lease uniqueness | no |
| `scripts/ci/test-gap-preflight-ac-gate.sh` | gap-preflight AC gate + picker AC filter (INFRA-1259) | yes |
| `scripts/ci/test-gap-reserve-concurrency.sh` | gap-reserve concurrency race guard | no |
| `scripts/ci/test-gap-reserve-padding.sh` | gap-reserve ID padding/format guard | no |
| `scripts/ci/test-gap-status-flip.sh` | gap-status-flip guard (INFRA-158) | no |
| `scripts/ci/test-infra-1025-atomic-claim.sh` | atomic claim no-shell-out + thin-wrapper assertions (INFRA-1025) | no |
| `scripts/ci/test-infra-109-worktree-boundary.sh` | worktree-boundary path resolution (INFRA-109) | no |
| `scripts/ci/test-infra-115-lease-ttl-file.sh` | lease TTL file-based reaper (INFRA-115) | no |
| `scripts/ci/test-meta-011-git-stomp.sh` | git index mutex — concurrent chump-commit.sh stomp guard (META-011) | no |
| `scripts/ci/test-open-pr-dup-detection.sh` | open-PR dedup gate at claim time (INFRA-1982) | no |
| `scripts/ci/test-pick-and-claim-lockdir.sh` | pick-and-claim lock-dir resolves to main repo from linked worktree (INFRA-466/467) | no |
| `scripts/ci/test-pre-push-force-lease-guard.sh` | pre-push --force-with-lease race guard (INFRA-345) | no |
| `scripts/ci/test-speculative-on-speculative-guard.sh` | speculative-on-speculative arm guard (INFRA-684) | no |
| `scripts/ci/test-spike-isolation.sh` | spike scripts isolated from production state.db (INFRA-430) | no |

### C3-pr-worker-lifecycle: PR/worker lifecycle & merge automation gates (23 unmirrored / 25 total)

| Script | Purpose (ci.yml step name) | Mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-bot-merge-auto-close.sh` | bot-merge auto-close on gap ship | no |
| `scripts/ci/test-bot-merge-conflict-wiring.sh` | bot-merge conflict-resolver wiring (INFRA-1657) | no |
| `scripts/ci/test-conflict-resolver.sh` | conflict-resolver-agent (INFRA-1488 Marcus M-C) | no |
| `scripts/ci/test-external-verify-merge.sh` | external verify-merge judge — 5-case synthetic matrix (CREDIBLE-096) | no |
| `scripts/ci/test-gate-promotion-no-regression.sh` | CI gate promotion no-regression (INFRA-1869) | no |
| `scripts/ci/test-infra-119-bot-merge-hang.sh` | bot-merge health monitoring + hung-process detection (INFRA-119) | no |
| `scripts/ci/test-install-pr-auto-rebase.sh` | pr-auto-rebase plist installer (INFRA-1779) | no |
| `scripts/ci/test-merged-check-guard.sh` | pre-push MERGED guard (INFRA-306) | yes |
| `scripts/ci/test-no-verify-audit.sh` | --no-verify audit guard (INFRA-1834) | no |
| `scripts/ci/test-pr-auto-rebase.sh` | pr-auto-rebase daemon (INFRA-1777) | no |
| `scripts/ci/test-pr-blocked-watch.sh` | pr-blocked-watch smoke (INFRA-550) | no |
| `scripts/ci/test-pr-explain-block.sh` | chump pr explain-block (INFRA-1416 stuck-PR diagnostic) | no |
| `scripts/ci/test-pr-terminal-state.sh` | pr-terminal-state helper — mergedAt-validated (INFRA-1981) | no |
| `scripts/ci/test-pr-triage-bot.sh` | pr-triage-bot smoke + YAML parse (INFRA-624/648) | no |
| `scripts/ci/test-pr-watch-auto-resolve.sh` | pr-watch auto-resolve recipe (INFRA-387) | no |
| `scripts/ci/test-pr-watch-shepherd-smoke.sh` | pr-watch shepherd smoke (INFRA-354) | no |
| `scripts/ci/test-pre-push-preflight-hook.sh` | pre-push preflight guard (INFRA-1671) | no |
| `scripts/ci/test-pre-push-rebase-allow.sh` | pre-push rebase-detect auto-skip (INFRA-368) | no |
| `scripts/ci/test-pre-push-test-gate.sh` | pre-push cargo-test full-suite gate (INFRA-761) | no |
| `scripts/ci/test-preflight-ci-parity.sh` | preflight-vs-CI parity smoke (INFRA-1867) | no |
| `scripts/ci/test-rebase-coordination.sh` | pr-auto-rebase per-branch lock — operator-race fix (INFRA-1974) | no |
| `scripts/ci/test-review-handoff-smoke.sh` | Review-as-Handoff end-to-end smoke test (INFRA-774) | no |
| `scripts/ci/test-stale-branch-rebase.sh` | paramedic stale-branch auto-rebase (INFRA-1429) | no |
| `scripts/ci/test-stale-pr-rebase-bot.sh` | stale-pr-rebase-bot — 3-strike circuit-break (INFRA-2295) | yes |
| `scripts/ci/test-status-flip-proof-of-merge.sh` | gap-store proof-of-merge guard (INFRA-1392) | no |

### C4-fleet-daemon-resilience-smoke: Fleet daemon & resilience smoke tests (43 unmirrored / 48 total)

| Script | Purpose (ci.yml step name) | Mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-attribution-portable.sh` | model-ship-rate generic attribution (CREDIBLE-045) | no |
| `scripts/ci/test-auto-arm-sweeper.sh` | auto-arm sweeper smoke + bypass (INFRA-382 / INFRA-374) | no |
| `scripts/ci/test-autoscale-decisions.sh` | autoscale decisions smoke (INFRA-1581) | no |
| `scripts/ci/test-cargo-target-reaper.sh` | cargo-target-reaper — dry-run, --execute, safety guards, ambient event (INFRA-1250) | no |
| `scripts/ci/test-changes-job-self-hosted.sh` | changes-job self-hosted routing (INFRA-1537) | no |
| `scripts/ci/test-chump-improve.sh` | chump self-improvement loop smoke | no |
| `scripts/ci/test-chump-repos.sh` | repos table migration + CLI + auto-import (MISSION-033) | yes |
| `scripts/ci/test-chump-subcommand-help.sh` | chump subcommand --help regression gate (INFRA-1246) | yes |
| `scripts/ci/test-ci-flake-rerun.sh` | CI-flake auto-rerun smoke — bypass + empty + flake match + cooldown (INFRA-375) | no |
| `scripts/ci/test-claude-reaper.sh` | claude orphan reaper (INFRA-1662) | no |
| `scripts/ci/test-cli-fleet-coord.sh` | CLI fleet-coord subcommand smoke | no |
| `scripts/ci/test-cli-help.sh` | CLI top-level --help regression gate | no |
| `scripts/ci/test-cli-integration.sh` | CLI integration smoke | no |
| `scripts/ci/test-cli-version-debug.sh` | CLI version/debug flags (CREDIBLE-019) | no |
| `scripts/ci/test-fleet-brief.sh` | fleet-brief operator briefing smoke | no |
| `scripts/ci/test-default-flip-guard.sh` | default-flip advisory guard (INFRA-762) | no |
| `scripts/ci/test-deliberator-tick-emits.sh` | deliberator tick emits consensus_result — numeric epoch guard + idempotency (RESILIENT-061) | no |
| `scripts/ci/test-effective-010-completion.sh` | shell completion subcommand source assertions (EFFECTIVE-010) | no |
| `scripts/ci/test-farmer.sh` | farmer un-killable control-plane tender (RESILIENT-068) | yes |
| `scripts/ci/test-flake-autorerun.sh` | flake-autorerun harness fixture (INFRA-764) | no |
| `scripts/ci/test-fleet-fanout.sh` | fleet-fanout primitive (INFRA-1484 Marcus M-B) | no |
| `scripts/ci/test-fleet-kill-switch.sh` | fleet kill switch — AUTONOMY_LEVEL fail-closed (RESILIENT-073) | no |
| `scripts/ci/test-fleet-pause-autolift.sh` | fleet-pause autolift + pause-immune recovery choir (RESILIENT-066) | yes |
| `scripts/ci/test-fleet-spec.sh` | fleet-spec primitive (INFRA-1483 Marcus M-B) | no |
| `scripts/ci/test-fleet-starve-auto-action.sh` | fleet starve auto-action (INFRA-391) | no |
| `scripts/ci/test-infra-250-v1-retirement.sh` | PWA v1 retirement — assets deleted, tauri.conf.json, v2 wizard (INFRA-250) | no |
| `scripts/ci/test-infra-254-pwa-root-redirect.sh` | PWA root redirect / -> /v2/ (INFRA-254) | no |
| `scripts/ci/test-infra-257-doc-only-guards.sh` | doc-only commits run all guards (INFRA-257) | no |
| `scripts/ci/test-infra-258-reaper-partial-delivery.sh` | stale-pr-reaper file-parity check (INFRA-258) | no |
| `scripts/ci/test-inspect-resume-scrap.sh` | inspect/resume/scrap surface (INFRA-1456) | no |
| `scripts/ci/test-install-ambient-hooks.sh` | install-ambient-hooks idempotence + bypass (FLEET-023) | no |
| `scripts/ci/test-keystone-cascade.sh` | paramedic keystone-cascade (INFRA-1420) | no |
| `scripts/ci/test-mcp-coord-smoke.sh` | chump-mcp-coord tools/list (INFRA-033) | no |
| `scripts/ci/test-md-links-loop.sh` | md-links-loop smoke (INFRA-1925) | no |
| `scripts/ci/test-migration-pipeline-gates.sh` | migration-pipeline gates smoke (INFRA-1581 / closes INFRA-1538) | no |
| `scripts/ci/test-model-registry.sh` | model-registry schema validation (INFRA-739) | no |
| `scripts/ci/test-orchestrate-session-summary.sh` | orchestrator session-summary emission smoke | no |
| `scripts/ci/test-pipefail-race-sweep.sh` | pipefail race sweep (INFRA-1658) | yes |
| `scripts/ci/test-research-026-preflight.sh` | RESEARCH-026 observer-effect harness preflight (no API) | no |
| `scripts/ci/test-rollup-semantic.sh` | fan-out rollup --semantic (INFRA-1455 Marcus M-B converge) | no |
| `scripts/ci/test-run-fleet-cross-repo.sh` | run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634) | no |
| `scripts/ci/test-sandbox-isolation.sh` | agent-bash sandbox pilot (INFRA-1454) | no |
| `scripts/ci/test-self-hosted-runner-deps.sh` | Self-hosted runner deps preflight (INFRA-1556) | no |
| `scripts/ci/test-stale-process-watchdog.sh` | stale-process watchdog (INFRA-1663) | no |
| `scripts/ci/test-subagent-budget-kill.sh` | subagent budget kill — parent-enforced SIGTERM+grace+SIGKILL (INFRA-1972) | no |
| `scripts/ci/test-subagent-epilogue-ref.sh` | subagent-shipping-epilogue reference guard (INFRA-332) | no |
| `scripts/ci/test-supervision-trees.sh` | supervision trees — per-gap + fleet restart-intensity (RESILIENT-058) | no |
| `scripts/ci/test-worktree-reaper-safety.sh` | worktree-reaper active-worktree safety guard (INFRA-1074) | no |

## Sub-gaps filed from this survey

Each cluster above ships as one META-070-Tier-C sub-gap: extend
`src/preflight.rs`'s audit-gate discovery list (`docs/preflight.rs` fn
around line 581-623) with that cluster's unmirrored scripts, gated behind
its own `CHUMP_PREFLIGHT_SKIP_<CLUSTER>` env var per the existing
`CHUMP_PREFLIGHT_SKIP_REGISTRY` pattern, with a
`scripts/ci/test-preflight-audit-<cluster>.sh` smoke test asserting the
scripts run by default and skip cleanly via the env var.

| Cluster | Sub-gap |
|---|---|
| C1 doc/commit hygiene guards | INFRA-3359 |
| C2 gap-state & claim/lease consistency | INFRA-3360 |
| C3 PR/worker lifecycle & merge automation | INFRA-3361 |
| C4 fleet daemon & resilience smoke | INFRA-3362 |

Note: C4 is large (42 scripts) — its sub-gap should further split at claim
time via `chump gap decompose` rather than mirroring all 42 in one PR.
