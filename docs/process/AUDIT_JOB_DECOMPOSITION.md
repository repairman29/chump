# Audit-job (`fast-checks`) decomposition survey (META-086)

> INFRA-1856 was closed 2026-05-23 after scope discovery: the ci.yml audit
> job is not "2 sub-checks" — it is **116 distinct `scripts/ci/*.sh`
> invocations** in the `fast-checks` job alone (an earlier undercount of 20+
> was itself revised up during this survey once multi-line `run: |` blocks
> and env-var-prefixed invocations were included, not just single-line
> `run: bash X.sh` steps). This doc is the honest survey that replaces the
> wrong initial estimate, per META-070 Tier-C decomposition discipline: when
> AC at filing turns out wrong on inspection, document the discovery and
> file a properly-scoped follow-up rather than ship a slim slice that misses
> the actual scope.

## Scope

Job: `fast-checks` in `.github/workflows/ci.yml` (the job colloquially
called "the audit job" — see `docs/process/SHIP_ASSIST_PLAYBOOK.md`,
`docs/process/CLAUDE_GOTCHAS.md`). This is distinct from
`docs/process/PREFLIGHT_COVERAGE_AUDIT.md` (INFRA-2350/META-269), which
tracks a curated subset of preflight-mirrorable gates; this survey is
exhaustive over every `scripts/ci/*.sh` invocation in the job, including
multi-line `run: |` blocks and env-var-prefixed invocations.

- Total scripts invoked: **116** (deduplicated; `test-stale-branch-rebase.sh`
  is invoked twice at two different CI steps and counted once)
- Already mirrored in `chump preflight` (`src/preflight.rs`): **10**
- Unmirrored: **106**, grouped below into 5 thematic clusters, each a
  ship-sized META-070 sub-gap.

## Clusters (unmirrored scripts only)

| Cluster | Count | Sub-gap |
|---|---|---|
| Observability & schema gates | 12 | META-317 |
| Gap-state & docs-delta consistency gates | 22 | META-318 |
| PR / claim / worker lifecycle gates | 25 | META-319 |
| Reaper / daemon / resilience gates | 30 | META-320 |
| Docs / content / product-surface gates | 17 | META-321 |

Each sub-gap's AC: for every script in its cluster, either (a) add a
`GateKind::Scripts` mirror in `src/preflight.rs` following the pattern in
`docs/process/PREFLIGHT_COVERAGE_AUDIT.md` §Verification, or (b) if the
script cannot run locally (talks to GitHub API, merge queue, self-hosted
runner state), classify it Tier-D in `docs/process/CI_GATES_INVENTORY.md`
instead of mirroring.

## Full survey table

Total audit-job (`fast-checks`) test scripts surveyed: **116**
Already mirrored in `chump preflight`: **10**
Unmirrored: **106**

| Script | Purpose | Mirrored? | Cluster |
|---|---|---|---|
| `scripts/ci/check-release-staleness.sh` | (no step name) | no | Docs / content / product-surface gates |
| `scripts/ci/coord-surfaces-smoke.sh` | Dual-surface coordination smoke (INFRA-032) | no | Observability & schema gates |
| `scripts/ci/test-ambient-schema.sh` | ambient-jsonl emit-time schema validation (INFRA-101) | no | Observability & schema gates |
| `scripts/ci/test-attribution-portable.sh` | model-ship-rate generic attribution (CREDIBLE-045) | no | Observability & schema gates |
| `scripts/ci/test-auto-arm-sweeper.sh` | auto-arm sweeper smoke + bypass (INFRA-382 / INFRA-374) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-autoscale-decisions.sh` | autoscale decisions smoke (INFRA-1581) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-book-sync-guard.sh` | book/src ↔ docs/process sync guard (INFRA-170) | no | Docs / content / product-surface gates |
| `scripts/ci/test-bot-merge-auto-close.sh` | bot-merge auto-close handshake (INFRA-154) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-bot-merge-conflict-wiring.sh` | bot-merge conflict-resolver wiring (INFRA-1657) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-cargo-target-reaper.sh` | cargo-target-reaper — dry-run, --execute, safety guards, ambient event (INFRA-1250) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-changes-job-self-hosted.sh` | changes-job self-hosted routing (INFRA-1537) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-chump-improve.sh` | chump improve orchestrator — 4-stage mock chain (EFFECTIVE-177) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-chump-repos.sh` | repos table migration + CLI + auto-import (MISSION-033) | yes | — |
| `scripts/ci/test-chump-subcommand-help.sh` | chump subcommand --help regression gate (INFRA-1246) | yes | — |
| `scripts/ci/test-ci-flake-rerun.sh` | CI-flake auto-rerun smoke — bypass + empty + flake match + cooldown (INFRA-375) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-claim-fuzzy-match.sh` | claim-time fuzzy-match (INFRA-1442 duplicate-claim prevention) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-claude-reaper.sh` | claude orphan reaper (INFRA-1662) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-cli-fleet-coord.sh` | CLI fleet + health + coord commands (CREDIBLE-035) | no | Docs / content / product-surface gates |
| `scripts/ci/test-cli-help.sh` | CLI help system consistency — all 31 commands have Usage strings (CREDIBLE-015) | no | Docs / content / product-surface gates |
| `scripts/ci/test-cli-integration.sh` | CLI integration tests by command category — 31 commands (CREDIBLE-018) | no | Docs / content / product-surface gates |
| `scripts/ci/test-cli-version-debug.sh` | CLI version/debug flags (CREDIBLE-019) | no | Observability & schema gates |
| `scripts/ci/test-conflict-resolver.sh` | conflict-resolver-agent (INFRA-1488 Marcus M-C) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-credential-pattern-guard.sh` | credential-pattern guard (INFRA-158) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-cross-judge-guard.sh` | cross-judge audit guard (INFRA-079) | no | Docs / content / product-surface gates |
| `scripts/ci/test-css-token-discipline.sh` | CSS token-discipline smoke (INFRA-1590) | no | Docs / content / product-surface gates |
| `scripts/ci/test-default-flip-guard.sh` | default-flip advisory guard (INFRA-762) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-deliberator-tick-emits.sh` | deliberator tick emits consensus_result — numeric epoch guard + idempotency (RESILIENT-061) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-doc-freshness.sh` | doc-freshness audit (DOC-041, warn-only) | no | Docs / content / product-surface gates |
| `scripts/ci/test-docs-delta-commit-msg.sh` | commit-msg docs-delta trailer check (INFRA-1969) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-docs-delta-guard.sh` | docs-delta guard (INFRA-158) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-effective-010-completion.sh` | shell completion subcommand source assertions (EFFECTIVE-010) | no | Docs / content / product-surface gates |
| `scripts/ci/test-env-var-coverage.sh` | env-var coverage — all src/ reads documented or allowlisted (DOC-026) | yes | — |
| `scripts/ci/test-external-verify-merge.sh` | external verify-merge judge — 5-case synthetic matrix (CREDIBLE-096) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-farmer.sh` | farmer un-killable control-plane tender (RESILIENT-068) | yes | — |
| `scripts/ci/test-flake-autorerun.sh` | flake-autorerun harness fixture (INFRA-764) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-fleet-brief.sh` | fleet brief subcommand (INFRA-721) | no | Observability & schema gates |
| `scripts/ci/test-fleet-fanout.sh` | fleet-fanout primitive (INFRA-1484 Marcus M-B) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-fleet-kill-switch.sh` | fleet kill switch — AUTONOMY_LEVEL fail-closed (RESILIENT-073) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-fleet-pause-autolift.sh` | fleet-pause autolift + pause-immune recovery choir (RESILIENT-066) | yes | — |
| `scripts/ci/test-fleet-spec.sh` | fleet-spec primitive (INFRA-1483 Marcus M-B) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-fleet-starve-auto-action.sh` | fleet starve auto-action (INFRA-391) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-gap-divergence-guard.sh` | gap-divergence guard (INFRA-783) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gap-doctor-safe-sweep.sh` | gap-doctor safe-sweep (INFRA-308) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gap-id-cross-session.sh` | gap-ID cross-session collision prevention (CREDIBLE-052) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gap-id-lease-uniqueness.sh` | gap-ID lease uniqueness gate — duplicate-PR race prevention (INFRA-1970) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gap-preflight-ac-gate.sh` | gap-preflight AC gate + picker AC filter (INFRA-1259) | yes | — |
| `scripts/ci/test-gap-reserve-concurrency.sh` | (no step name) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gap-reserve-padding.sh` | gap-reserve ID zero-padding (INFRA-080) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gap-status-flip.sh` | gap-status-flip guard (INFRA-158) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-gate-promotion-no-regression.sh` | CI gate promotion no-regression (INFRA-1869) | no | Observability & schema gates |
| `scripts/ci/test-git-identity-guard.sh` | git-identity sanity guard (INFRA-787) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-hardcoded-date-guard.sh` | hardcoded-date guard (INFRA-971) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-infra-1025-atomic-claim.sh` | atomic claim no-shell-out + thin-wrapper assertions (INFRA-1025) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-infra-109-worktree-boundary.sh` | worktree-boundary path resolution (INFRA-109) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-infra-115-lease-ttl-file.sh` | lease TTL file-based reaper (INFRA-115) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-infra-119-bot-merge-hang.sh` | bot-merge health monitoring + hung-process detection (INFRA-119) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-infra-124-docs-delta-trailer.sh` | docs-delta trailer validation (INFRA-124) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-infra-250-v1-retirement.sh` | PWA v1 retirement — assets deleted, tauri.conf.json, v2 wizard (INFRA-250) | no | Docs / content / product-surface gates |
| `scripts/ci/test-infra-254-pwa-root-redirect.sh` | PWA root redirect / -> /v2/ (INFRA-254) | no | Docs / content / product-surface gates |
| `scripts/ci/test-infra-257-doc-only-guards.sh` | doc-only commits run all guards (INFRA-257) | no | Docs / content / product-surface gates |
| `scripts/ci/test-infra-258-reaper-partial-delivery.sh` | stale-pr-reaper file-parity check (INFRA-258) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-inspect-resume-scrap.sh` | inspect/resume/scrap surface (INFRA-1456) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-install-ambient-hooks.sh` | install-ambient-hooks idempotence + bypass (FLEET-023) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-install-pr-auto-rebase.sh` | pr-auto-rebase plist installer (INFRA-1779) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-keystone-cascade.sh` | paramedic keystone-cascade (INFRA-1420) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-markdown-intra-doc-links.sh` | markdown intra-doc links (DOC-039) | yes | — |
| `scripts/ci/test-mcp-coord-smoke.sh` | chump-mcp-coord tools/list (INFRA-033) | no | Observability & schema gates |
| `scripts/ci/test-md-links-loop.sh` | md-links-loop smoke (INFRA-1925) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-merge-driver-ci-yml.sh` | ci.yml merge driver smoke (INFRA-310) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-merge-driver-pre-commit.sh` | pre-commit merge driver smoke (INFRA-310) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-merge-driver-state-sql.sh` | state.sql merge driver smoke (INFRA-310) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-merged-check-guard.sh` | pre-push MERGED guard (INFRA-306) | yes | — |
| `scripts/ci/test-meta-011-git-stomp.sh` | git index mutex — concurrent chump-commit.sh stomp guard (META-011) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-migration-pipeline-gates.sh` | migration-pipeline gates smoke (INFRA-1581 / closes INFRA-1538) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-model-registry.sh` | model-registry schema validation (INFRA-739) | no | Observability & schema gates |
| `scripts/ci/test-no-claude-leak.sh` | no-claude-leak audit (INFRA-1051, warn-only, changed-only) | no | Docs / content / product-surface gates |
| `scripts/ci/test-no-verify-audit.sh` | --no-verify audit guard (INFRA-1834) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-obs-coverage-guard.sh` | observability coverage — new src/dispatch.sh and src/main-reachable .rs need a tracing/ambient/lessons hook (INFRA-757) | no | Observability & schema gates |
| `scripts/ci/test-observability-coverage.sh` | observability coverage — live PR diff against base ref (INFRA-757) | no | Observability & schema gates |
| `scripts/ci/test-open-pr-dup-detection.sh` | open-PR dedup gate at claim time (INFRA-1982) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-orchestrate-session-summary.sh` | orchestrate session-summary ambient emit (INFRA-1363) | no | Observability & schema gates |
| `scripts/ci/test-pick-and-claim-lockdir.sh` | pick-and-claim lock-dir resolves to main repo from linked worktree (INFRA-466/467) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pipefail-race-sweep.sh` | pipefail race sweep (INFRA-1658) | yes | — |
| `scripts/ci/test-pr-auto-rebase.sh` | pr-auto-rebase daemon (INFRA-1777) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pr-blocked-watch.sh` | pr-blocked-watch smoke (INFRA-550) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pr-explain-block.sh` | chump pr explain-block (INFRA-1416 stuck-PR diagnostic) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pr-terminal-state.sh` | pr-terminal-state helper — mergedAt-validated (INFRA-1981) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pr-triage-bot.sh` | pr-triage-bot smoke + YAML parse (INFRA-624/648) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pr-watch-auto-resolve.sh` | pr-watch auto-resolve recipe (INFRA-387) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pr-watch-shepherd-smoke.sh` | pr-watch shepherd smoke (INFRA-354) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pre-push-force-lease-guard.sh` | pre-push --force-with-lease race guard (INFRA-345) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pre-push-preflight-hook.sh` | pre-push preflight guard (INFRA-1671) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pre-push-rebase-allow.sh` | pre-push rebase-detect auto-skip (INFRA-368) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-pre-push-test-gate.sh` | pre-push cargo-test full-suite gate (INFRA-761) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-preflight-ci-parity.sh` | preflight-vs-CI parity smoke (INFRA-1867) | no | Docs / content / product-surface gates |
| `scripts/ci/test-prereg-content-guard.sh` | preregistration content guard (INFRA-113) | no | Docs / content / product-surface gates |
| `scripts/ci/test-raw-yaml-guard.sh` | raw-YAML-edit guard (INFRA-200, blocking since 2026-05-02) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-rebase-coordination.sh` | pr-auto-rebase per-branch lock — operator-race fix (INFRA-1974) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-research-026-preflight.sh` | RESEARCH-026 observer-effect harness preflight (no API) | no | Docs / content / product-surface gates |
| `scripts/ci/test-review-handoff-smoke.sh` | Review-as-Handoff end-to-end smoke test (INFRA-774) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-rollup-semantic.sh` | fan-out rollup --semantic (INFRA-1455 Marcus M-B converge) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-run-fleet-cross-repo.sh` | run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-sandbox-isolation.sh` | agent-bash sandbox pilot (INFRA-1454) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-schema-version-assert.sh` | schema_version assert helper — unit tests for assert-schema.sh (INFRA-1978) | no | Observability & schema gates |
| `scripts/ci/test-self-hosted-runner-deps.sh` | Self-hosted runner deps preflight (INFRA-1556) | no | Docs / content / product-surface gates |
| `scripts/ci/test-speculative-on-speculative-guard.sh` | speculative-on-speculative arm guard (INFRA-684) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-spike-isolation.sh` | spike scripts isolated from production state.db (INFRA-430) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-stale-branch-rebase.sh` | paramedic stale-branch auto-rebase (INFRA-1429) | no | PR / claim / worker lifecycle gates |
| `scripts/ci/test-stale-pr-rebase-bot.sh` | stale-pr-rebase-bot — 3-strike circuit-break (INFRA-2295) | yes | — |
| `scripts/ci/test-stale-process-watchdog.sh` | stale-process watchdog (INFRA-1663) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-status-flip-proof-of-merge.sh` | gap-store proof-of-merge guard (INFRA-1392) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-subagent-budget-kill.sh` | subagent budget kill — parent-enforced SIGTERM+grace+SIGKILL (INFRA-1972) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-subagent-epilogue-ref.sh` | subagent-shipping-epilogue reference guard (INFRA-332) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-submodule-guard.sh` | submodule-sanity guard (INFRA-158) | no | Gap-state & docs-delta consistency gates |
| `scripts/ci/test-supervision-trees.sh` | supervision trees — per-gap + fleet restart-intensity (RESILIENT-058) | no | Reaper / daemon / resilience gates |
| `scripts/ci/test-worktree-reaper-safety.sh` | worktree-reaper active-worktree safety guard (INFRA-1074) | no | Reaper / daemon / resilience gates |

## Follow-up sub-gaps (META-070 continuation)

Filed against the clusters above, each with the AC template from
"Clusters" §:

- META-317 — Mirror **Observability & schema gates** cluster (12 scripts)
- META-318 — Mirror **Gap-state & docs-delta consistency gates** cluster (22 scripts)
- META-319 — Mirror **PR / claim / worker lifecycle gates** cluster (25 scripts)
- META-320 — Mirror **Reaper / daemon / resilience gates** cluster (30 scripts)
- META-321 — Mirror **Docs / content / product-surface gates** cluster (17 scripts)

META-086 self-closes when the last of META-317/318/319/320/321 ships (AC4).

## Verification

`scripts/ci/test-audit-job-decomposition.sh` asserts every `scripts/ci/*.sh`
that `.github/workflows/ci.yml`'s `fast-checks` job invokes appears
(by basename) in this doc's survey table — catches silent script-list
drift after this doc is written.

