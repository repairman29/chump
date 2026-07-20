# Audit-job preflight-mirror decomposition survey (META-086)

Canonical survey of every `bash scripts/ci/test-*.sh` invoked by the
`audit`/`audit-shard` job in `.github/workflows/audit.yml` — the CI job
originally in `ci.yml` (moved to its own workflow file by INFRA-2452 to fix
a cancel-in-progress deadlock, then split into a 4-way shard matrix by
INFRA-2565; still referred to as "the audit job" per INFRA-1856/META-070
doctrine). For each script: 1-line purpose (from its CI step name) and
whether it is already mirrored in `src/preflight.rs` (i.e. runs locally via
`chump preflight`, not just in CI).

Total scripts invoked by the audit job: **118**
Already mirrored in preflight: **7**
Unmirrored (need a preflight gate): **111**

## Full inventory

| Script | Purpose | Mirrored in preflight.rs |
|---|---|---|
| `test-agent-throughput.sh` | per-agent throughput tracker — tracker script + kpi report --agents (FLEET-044) | no |
| `test-alert-classifier.sh` | alert classifier false-positive suppression — operator silent_agent + closed pr_stuck (INFRA-1247) | no |
| `test-api-gap-queue-shape.sh` | /api/gap-queue fat shape — 15 fields, filters, sort, pillar derivation, ambient signal (INFRA-1197) | no |
| `test-audit-workflow-not-cancellable.sh` | audit workflow not cancellable — audit job isolated from ci.yml cancel-in-progress (INFRA-2452) | no |
| `test-auth-status.sh` | auth-status validity probe — catches depleted-credential-wins-precedence trap (RESILIENT-086) | no |
| `test-autonomous-ship-rate.sh` | autonomous ship-rate metric fixture (CREDIBLE-047) | no |
| `test-bot-merge-arm-ship-order.sh` | bot-merge arm-before-ship ordering fix (INFRA-1030) | no |
| `test-bot-merge-exit-codes.sh` | bot-merge.sh step-specific exit codes (RESILIENT-010) | no |
| `test-bot-merge-exit-phases.sh` | bot-merge.sh per-phase exit codes + ambient event (RESILIENT-011) | no |
| `test-bot-merge-graphql-preflight.sh` | bot-merge GraphQL preflight + REST fallback — fails fast, emits graphql_exhausted (INFRA-1031) | no |
| `test-bot-merge-stacked-rebase.sh` | bot-merge stacked PR auto-rebase — kill switch, event emission, gated trigger (INFRA-765) | no |
| `test-bot-merge-watchdog.sh` | bot-merge watchdog — kills done-gap procs, spares open-gap, exempt bypass (INFRA-1006) | no |
| `test-bounced-pr-detector.sh` | bounced-PR detector fixture (INFRA-781) | no |
| `test-cache-event-emission.sh` | cache hit/miss event emission — github_cache.sh telemetry (CREDIBLE-064) | no |
| `test-cache-mergestatestatus.sh` | merge_state_status column — webhook write + shim read + migration (INFRA-1368) | no |
| `test-cargo-mutex-isolation.sh` | cargo build mutex isolation — per-worktree CARGO_TARGET_DIR (INFRA-1374) | no |
| `test-change-approval.sh` | change approval workflow — gate, approve, rollback, ambient events (INFRA-912) | no |
| `test-ci-audit-loop.sh` | ci-audit-loop subcommands — tick/audit/heartbeat/help + scanner-anchor discipline (INFRA-1923) | no |
| `test-ci-heavy-jobs-cross-platform.sh` | heavy CI jobs cross-platform — apt-get gated + lane-flippable (INFRA-1542) | no |
| `test-cli-output-format.sh` | CLI output format consistency — --quiet/--format/--json (EFFECTIVE-008) | no |
| `test-cli-version-debug.sh` | CLI version/debug flags (CREDIBLE-019) | no |
| `test-cockpit-wake-fleet.sh` | cockpit Today's-arc Wake-fleet action (PRODUCT-128) | no |
| `test-cost-enforcement.sh` | cost quota enforcement — warning at 80%, hard-cap at 100% (INFRA-877) | no |
| `test-credential-lifecycle.sh` | credential lifecycle — rotation_due alert, age threshold, dry-run (INFRA-879) | no |
| `test-cross-pr-contract.sh` | cross-PR contract gate — refuse merge on cross-PR IPC schema mismatch (INFRA-2406) | no |
| `test-curator-auto-decompose.sh` | curator auto-decompose — starved pillar decomposes l/xl gap, guard, dry-run (INFRA-943) | no |
| `test-curator-decision-logging.sh` | curator decision logging — kind, required fields, enum, phases (INFRA-848) | no |
| `test-curator-freshness.sh` | curator freshness gate — skip close within active rebase window, event schema (INFRA-1195) | no |
| `test-curator-p0-demotion.sh` | curator p0 demotion — real mutation, oldest P0 selected, max 1/run (INFRA-978) | no |
| `test-edit-replay.sh` | write-ahead log recovery — wrap/replay round-trip (INFRA-1200) | no |
| `test-error-path-coverage.sh` | error-path test coverage ≥60 assertions across gap_store (CREDIBLE-005) | no |
| `test-event-registry-audit-regression.sh` | EVENT_REGISTRY audit regression — parser correctness (INFRA-2496) | yes |
| `test-event-registry-coverage.sh` | EVENT_REGISTRY coverage — no drift in either direction (INFRA-1237/INFRA-1287) | yes |
| `test-fleet-bootstrap.sh` | chump fleet bootstrap orchestrator (META-066) | no |
| `test-fleet-brief-pillar-table.sh` | fleet-brief pillar table — per-pillar pickable counts (CREDIBLE-034) | no |
| `test-fleet-metrics-snapshot.sh` | fleet metrics snapshot — ship_rate, waste_rate, cycle_time_p50 (INFRA-900) | no |
| `test-fleet-race-loss.sh` | speculative race-loss event tracking (FLEET-035) | no |
| `test-fleet-state-mutex.sh` | fleet-state.json mutex — flock, kill switch, timeout event (INFRA-847) | no |
| `test-fleet-status-rate-limit.sh` | fleet-status rate-limit line format + WARN threshold (EFFECTIVE-025) | no |
| `test-gap-ac-requirement.sh` | gap AC enforcement — pre-commit rejects gaps without acceptance_criteria (CREDIBLE-054) | no |
| `test-gap-add-note.sh` | chump gap set --add-note timestamped append (EFFECTIVE-020) | no |
| `test-gap-audit-ac-open.sh` | gap audit-ac --open — warn on vague open gaps before claim (INFRA-936) | no |
| `test-gap-closure-consistency-fixture.sh` | gap-closure-consistency fail-closed + fixture-aware DB (CREDIBLE-051) | no |
| `test-gap-consolidate.sh` | gap consolidate — near-duplicate title detection (INFRA-935) | no |
| `test-gap-impact-rating.sh` | gap impact rating — rate CLI, ambient event, kpi --impact (FLEET-048) | no |
| `test-gap-lifecycle-manager.sh` | gap lifecycle manager — abandoned gap detection (INFRA-870) | no |
| `test-gap-list-domain-summary.sh` | chump gap list domain summary + test-filter (INFRA-431) | no |
| `test-gap-list-done-format.sh` | chump gap list done-format — closed-pr + closed-date (EFFECTIVE-024) | no |
| `test-gap-list-since-json-schema.sh` | gap list --json schema audit — required fields present in every gap object (CREDIBLE-061) | no |
| `test-gap-list-since.sh` | chump gap list --since filter (EFFECTIVE-018) | no |
| `test-gap-profiling.sh` | per-gap performance profiling — timing wrapper, perf report, flame chart (INFRA-906) | no |
| `test-gap-quality-gate.sh` | gap quality gate — TODO/TBD ACs, invalid priority/effort (INFRA-904) | no |
| `test-gap-rebalance.sh` | gap rebalance — P0 budget + pillar floor (INFRA-635) | no |
| `test-gap-run-now.sh` | gap run-now — manual dispatch trigger, event schema, validation (INFRA-895) | no |
| `test-gap-show-ac-render.sh` | gap show AC rendering — numbered list + json ac_count/ac_has_todos (CREDIBLE-033) | no |
| `test-gap-templates.sh` | gap templates — pillar starter templates, gap-template.sh dispatcher (INFRA-905) | no |
| `test-gap-workflow-status.sh` | PWA gap workflow status endpoint (EFFECTIVE-014) | no |
| `test-gh-api-probe.sh` | gh-api-probe wired in bot-merge + run-fleet (INFRA-539) | no |
| `test-gh-shim-script-attribution.sh` | gh-shim script attribution deep walk (CREDIBLE-065) | no |
| `test-graphql-debounce.sh` | graphql_exhausted debounce when resets_at unknown (INFRA-1968) | no |
| `test-inbox-prune.sh` | inbox-prune — size + age rotation caps for inbox jsonl files (INFRA-1979) | no |
| `test-infra-779-gitdir-repair.sh` | INFRA-779 gitdir auto-repair — corrupt + verify repair + ambient event (INFRA-1033) | no |
| `test-install-gh-shim-worktree-safe.sh` | install-gh-shim worktree-safety guard (INFRA-1186) | no |
| `test-jit-binary-refresh.sh` | JIT binary refresh wired (INFRA-1977 — H8 critique fix) | no |
| `test-known-flake-skip.sh` | pre-push known-flake skip integration (INFRA-1167) | no |
| `test-known-flakes-gate.sh` | KNOWN_FLAKES auto-bypass gate — 11 pre-push flakes catalogued (RESILIENT-012) | no |
| `test-liaison-webhook-cache.sh` | INFRA-1318 Phase 2 end-to-end smoke — webhook cache + liaison slice signals (INFRA-1877) | no |
| `test-lint-handoff-comment.sh` | handoff comment template lint (INFRA-769) | no |
| `test-merge-driver-ci-yml-add-row.sh` | ci-yml merge-driver orphan-step rejection (INFRA-1199) | no |
| `test-mission-picker-worker.sh` | worker picker mission-rank — P0-MISSION beats P0-substrate, substrate P0 beats mission P1 (MISSION-028) | yes |
| `test-mission-picker.sh` | picker surfaces mission-linked gaps before equal-priority substrate (MISSION-011) | yes |
| `test-no-inline-ambient-printf.sh` | no-inline-ambient-printf — Phase-1 dry-up (INFRA-1307) | no |
| `test-no-manual-ship-bypass.sh` | no-manual-ship-bypass guard (INFRA-719) | no |
| `test-no-new-bypass-env-vars.sh` | no-new-bypass-env-vars — forbid new CHUMP_*_BYPASS/SKIP/IGNORE_* (INFRA-2429) | yes |
| `test-no-raw-gh-in-hot-paths.sh` | raw-gh lint gate — no new direct gh calls in hot-path scripts outside lib/ (INFRA-1274) | yes |
| `test-operator-recovery.sh` | operator-recovery umbrella — CHUMP_OPERATOR_RECOVERY=1 bypass set + audit event (INFRA-1028) | no |
| `test-orphan-pr-closer.sh` | orphan-PR closer fixture (INFRA-1139) | no |
| `test-orphan-worktree-prune.sh` | orphaned worktree reaper — prune-worktrees.sh orphan mode (RESILIENT-013) | no |
| `test-per-worktree-target-guard.sh` | per-worktree stale binary guard — detect, emit ambient event (RESILIENT-001) | no |
| `test-picker-priority.sh` | picker consumes planner priority (INFRA-1258) | no |
| `test-pillar-balance-guard.sh` | pillar-balance guard at reserve time (INFRA-1152) | no |
| `test-pillar-balance.sh` | gap pillar-balance — pickable inventory per pillar (INFRA-604) | no |
| `test-pillar-dashboard.sh` | pillar health dashboard endpoint + web component (PRODUCT-090) | no |
| `test-pr-failure-auto-rescue.sh` | PR auto-rescue daemon smoke (INFRA-1600) | no |
| `test-pr-rescue-audit-handler.sh` | PR auto-rescue active audit-handler (INFRA-1618) | no |
| `test-pr-scope-title-fallback.sh` | pr-scope PR_TITLE fallback chain (INFRA-976) | no |
| `test-precommit-guard-audit.sh` | pre-commit vacuous-guard audit (INFRA-508) | no |
| `test-precommit-strict-replay.sh` | precommit strict replay fixture (INFRA-767) | no |
| `test-prepush-worktree-cd.sh` | pre-push hook cd to GIT_WORK_TREE for cargo test (RESILIENT-009) | no |
| `test-pwa-auth-toast-stream.sh` | PWA auth-toast dedup — fleet_auth_fallback stream + unit (INFRA-991) | no |
| `test-pwa-e2e-gap-workflow.sh` | PWA gap workflow e2e — 4-phase stub + status transition (CREDIBLE-020) | no |
| `test-pwa-flake-quarantine.sh` | PWA flake quarantine wiring (INFRA-1332) | no |
| `test-pwa-security.sh` | PWA gap endpoint security — rate limit, CSRF, headers, timeout (CREDIBLE-023) | no |
| `test-pwa-version-compat.sh` | PWA version compatibility check (CREDIBLE-022) | no |
| `test-pwa-workflow-observability.sh` | PWA workflow observability — request_id tracing (CREDIBLE-024) | no |
| `test-release-lease-flag.sh` | release --lease <ID> flag — named session release (INFRA-1026) | no |
| `test-required-model.sh` | required_model plumbing — model_selected event, picker filter, execute-gap override (INFRA-843) | no |
| `test-review-handoff-reengage.sh` | review-as-handoff author re-engagement loop (INFRA-771) | no |
| `test-rollback-gap.sh` | gap rollback — runbook, rollback-gap.sh, ambient event (INFRA-899) | no |
| `test-rollup-cascade-cancel.sh` | cascade-cancel rollup classification fixture (INFRA-1002) | no |
| `test-ruleset-doc-only-pr.sh` | ruleset doc-only-PR wedge guard (INFRA-2191) | no |
| `test-run-consolidation.sh` | run.sh consolidation — dispatcher + deprecation shims + README refs (INFRA-691) | no |
| `test-run-fleet-cross-repo.sh` | run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634) | no |
| `test-stale-binary-ship-blocked.sh` | stale-binary destructive-op guard (INFRA-825) | no |
| `test-stale-worktree-reaper-tmp.sh` | stale-worktree-reaper extends to /tmp/chump-* (INFRA-2020) | no |
| `test-state-db-restore.sh` | state.db corruption recovery — restore from state.sql (INFRA-538) | no |
| `test-tool-normalize.sh` | tool-call normalizer for weak LLMs (INFRA-740) | no |
| `test-triage-test-failure.sh` | CI failure triage classification (CREDIBLE-013) | no |
| `test-uuid-gap-id-compat.sh` | UUID gap-ID compatibility audit — preflight+show+auto-derive (INFRA-630) | no |
| `test-velocity-trending.sh` | velocity trending — ship_rate/waste_rate 7d trend, improving/stable/degrading (INFRA-901) | no |
| `test-waste-tally-domain.sh` | waste-tally --domain — token budget by domain, breach exit code (INFRA-934) | no |
| `test-worker-circuit-breaker.sh` | worker circuit-breaker — threshold=3 pause=5min kill-switch (INFRA-826) | no |
| `test-worker-first-output-watchdog.sh` | worker first-output watchdog — kill switch, event emission, retry (INFRA-828) | no |
| `test-worker-timeout-no-commit.sh` | worker timeout-no-commit rescue — kill switch, event emission, SHA diff (INFRA-831) | no |
| `test-worker-timeout-scale.sh` | worker timeout scaler — no death-spiral, derives from immutable base (RESILIENT-135) | yes |
| `test-worktree-contamination-check.sh` | worktree contamination check — detect foreign gap files (INFRA-931) | no |
| `test-worktree-prune-protects-live-edits.sh` | worktree-prune protects live edits (INFRA-1347) | no |
| `test-worktree-show-toplevel.sh` | worktree show-toplevel fix (INFRA-810) | no |

## Unmirrored scripts grouped into thematic clusters

Each cluster below is sized as one ship-target sub-gap (own preflight gate,
own `chump preflight` wiring).

### A — Gap-state consistency gates (gap CLI subcommand behavior: AC, lifecycle, list/show formats)

19 scripts. Sub-gap: filed below.

- `test-gap-ac-requirement.sh` — gap AC enforcement — pre-commit rejects gaps without acceptance_criteria (CREDIBLE-054)
- `test-gap-add-note.sh` — chump gap set --add-note timestamped append (EFFECTIVE-020)
- `test-gap-audit-ac-open.sh` — gap audit-ac --open — warn on vague open gaps before claim (INFRA-936)
- `test-gap-closure-consistency-fixture.sh` — gap-closure-consistency fail-closed + fixture-aware DB (CREDIBLE-051)
- `test-gap-consolidate.sh` — gap consolidate — near-duplicate title detection (INFRA-935)
- `test-gap-impact-rating.sh` — gap impact rating — rate CLI, ambient event, kpi --impact (FLEET-048)
- `test-gap-lifecycle-manager.sh` — gap lifecycle manager — abandoned gap detection (INFRA-870)
- `test-gap-list-domain-summary.sh` — chump gap list domain summary + test-filter (INFRA-431)
- `test-gap-list-done-format.sh` — chump gap list done-format — closed-pr + closed-date (EFFECTIVE-024)
- `test-gap-list-since-json-schema.sh` — gap list --json schema audit — required fields present in every gap object (CREDIBLE-061)
- `test-gap-list-since.sh` — chump gap list --since filter (EFFECTIVE-018)
- `test-gap-profiling.sh` — per-gap performance profiling — timing wrapper, perf report, flame chart (INFRA-906)
- `test-gap-quality-gate.sh` — gap quality gate — TODO/TBD ACs, invalid priority/effort (INFRA-904)
- `test-gap-rebalance.sh` — gap rebalance — P0 budget + pillar floor (INFRA-635)
- `test-gap-run-now.sh` — gap run-now — manual dispatch trigger, event schema, validation (INFRA-895)
- `test-gap-show-ac-render.sh` — gap show AC rendering — numbered list + json ac_count/ac_has_todos (CREDIBLE-033)
- `test-gap-templates.sh` — gap templates — pillar starter templates, gap-template.sh dispatcher (INFRA-905)
- `test-gap-workflow-status.sh` — PWA gap workflow status endpoint (EFFECTIVE-014)
- `test-release-lease-flag.sh` — release --lease <ID> flag — named session release (INFRA-1026)

### B — PR/worker-lifecycle gates (bot-merge phases, rescue, rebase, rollup, scope)

16 scripts. Sub-gap: filed below.

- `test-bot-merge-arm-ship-order.sh` — bot-merge arm-before-ship ordering fix (INFRA-1030)
- `test-bot-merge-exit-codes.sh` — bot-merge.sh step-specific exit codes (RESILIENT-010)
- `test-bot-merge-exit-phases.sh` — bot-merge.sh per-phase exit codes + ambient event (RESILIENT-011)
- `test-bot-merge-graphql-preflight.sh` — bot-merge GraphQL preflight + REST fallback — fails fast, emits graphql_exhausted (INFRA-1031)
- `test-bot-merge-stacked-rebase.sh` — bot-merge stacked PR auto-rebase — kill switch, event emission, gated trigger (INFRA-765)
- `test-bot-merge-watchdog.sh` — bot-merge watchdog — kills done-gap procs, spares open-gap, exempt bypass (INFRA-1006)
- `test-bounced-pr-detector.sh` — bounced-PR detector fixture (INFRA-781)
- `test-cache-mergestatestatus.sh` — merge_state_status column — webhook write + shim read + migration (INFRA-1368)
- `test-merge-driver-ci-yml-add-row.sh` — ci-yml merge-driver orphan-step rejection (INFRA-1199)
- `test-pr-failure-auto-rescue.sh` — PR auto-rescue daemon smoke (INFRA-1600)
- `test-pr-rescue-audit-handler.sh` — PR auto-rescue active audit-handler (INFRA-1618)
- `test-pr-scope-title-fallback.sh` — pr-scope PR_TITLE fallback chain (INFRA-976)
- `test-review-handoff-reengage.sh` — review-as-handoff author re-engagement loop (INFRA-771)
- `test-rollup-cascade-cancel.sh` — cascade-cancel rollup classification fixture (INFRA-1002)
- `test-stale-binary-ship-blocked.sh` — stale-binary destructive-op guard (INFRA-825)
- `test-stale-worktree-reaper-tmp.sh` — stale-worktree-reaper extends to /tmp/chump-* (INFRA-2020)

### C — Fleet coordination & observability gates (curators, pillar balance, fleet metrics, GH API, cost/credential)

41 scripts. Sub-gap: filed below.

- `test-agent-throughput.sh` — per-agent throughput tracker — tracker script + kpi report --agents (FLEET-044)
- `test-alert-classifier.sh` — alert classifier false-positive suppression — operator silent_agent + closed pr_stuck (INFRA-1247)
- `test-api-gap-queue-shape.sh` — /api/gap-queue fat shape — 15 fields, filters, sort, pillar derivation, ambient signal (INFRA-1197)
- `test-autonomous-ship-rate.sh` — autonomous ship-rate metric fixture (CREDIBLE-047)
- `test-cache-event-emission.sh` — cache hit/miss event emission — github_cache.sh telemetry (CREDIBLE-064)
- `test-cockpit-wake-fleet.sh` — cockpit Today's-arc Wake-fleet action (PRODUCT-128)
- `test-cost-enforcement.sh` — cost quota enforcement — warning at 80%, hard-cap at 100% (INFRA-877)
- `test-credential-lifecycle.sh` — credential lifecycle — rotation_due alert, age threshold, dry-run (INFRA-879)
- `test-curator-auto-decompose.sh` — curator auto-decompose — starved pillar decomposes l/xl gap, guard, dry-run (INFRA-943)
- `test-curator-decision-logging.sh` — curator decision logging — kind, required fields, enum, phases (INFRA-848)
- `test-curator-freshness.sh` — curator freshness gate — skip close within active rebase window, event schema (INFRA-1195)
- `test-curator-p0-demotion.sh` — curator p0 demotion — real mutation, oldest P0 selected, max 1/run (INFRA-978)
- `test-fleet-bootstrap.sh` — chump fleet bootstrap orchestrator (META-066)
- `test-fleet-brief-pillar-table.sh` — fleet-brief pillar table — per-pillar pickable counts (CREDIBLE-034)
- `test-fleet-metrics-snapshot.sh` — fleet metrics snapshot — ship_rate, waste_rate, cycle_time_p50 (INFRA-900)
- `test-fleet-race-loss.sh` — speculative race-loss event tracking (FLEET-035)
- `test-fleet-state-mutex.sh` — fleet-state.json mutex — flock, kill switch, timeout event (INFRA-847)
- `test-fleet-status-rate-limit.sh` — fleet-status rate-limit line format + WARN threshold (EFFECTIVE-025)
- `test-gh-api-probe.sh` — gh-api-probe wired in bot-merge + run-fleet (INFRA-539)
- `test-gh-shim-script-attribution.sh` — gh-shim script attribution deep walk (CREDIBLE-065)
- `test-graphql-debounce.sh` — graphql_exhausted debounce when resets_at unknown (INFRA-1968)
- `test-inbox-prune.sh` — inbox-prune — size + age rotation caps for inbox jsonl files (INFRA-1979)
- `test-known-flake-skip.sh` — pre-push known-flake skip integration (INFRA-1167)
- `test-known-flakes-gate.sh` — KNOWN_FLAKES auto-bypass gate — 11 pre-push flakes catalogued (RESILIENT-012)
- `test-operator-recovery.sh` — operator-recovery umbrella — CHUMP_OPERATOR_RECOVERY=1 bypass set + audit event (INFRA-1028)
- `test-orphan-pr-closer.sh` — orphan-PR closer fixture (INFRA-1139)
- `test-picker-priority.sh` — picker consumes planner priority (INFRA-1258)
- `test-pillar-balance-guard.sh` — pillar-balance guard at reserve time (INFRA-1152)
- `test-pillar-balance.sh` — gap pillar-balance — pickable inventory per pillar (INFRA-604)
- `test-pillar-dashboard.sh` — pillar health dashboard endpoint + web component (PRODUCT-090)
- `test-pwa-workflow-observability.sh` — PWA workflow observability — request_id tracing (CREDIBLE-024)
- `test-required-model.sh` — required_model plumbing — model_selected event, picker filter, execute-gap override (INFRA-843)
- `test-rollback-gap.sh` — gap rollback — runbook, rollback-gap.sh, ambient event (INFRA-899)
- `test-run-consolidation.sh` — run.sh consolidation — dispatcher + deprecation shims + README refs (INFRA-691)
- `test-run-fleet-cross-repo.sh` — run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634)
- `test-state-db-restore.sh` — state.db corruption recovery — restore from state.sql (INFRA-538)
- `test-triage-test-failure.sh` — CI failure triage classification (CREDIBLE-013)
- `test-velocity-trending.sh` — velocity trending — ship_rate/waste_rate 7d trend, improving/stable/degrading (INFRA-901)
- `test-waste-tally-domain.sh` — waste-tally --domain — token budget by domain, breach exit code (INFRA-934)
- `test-worker-circuit-breaker.sh` — worker circuit-breaker — threshold=3 pause=5min kill-switch (INFRA-826)
- `test-worker-timeout-no-commit.sh` — worker timeout-no-commit rescue — kill switch, event emission, SHA diff (INFRA-831)

### D — Worker substrate, worktree & PWA gates (git worktree safety, precommit/prepush, PWA e2e/security, CLI smoke)

35 scripts. Sub-gap: filed below.

- `test-audit-workflow-not-cancellable.sh` — audit workflow not cancellable — audit job isolated from ci.yml cancel-in-progress (INFRA-2452)
- `test-auth-status.sh` — auth-status validity probe — catches depleted-credential-wins-precedence trap (RESILIENT-086)
- `test-cargo-mutex-isolation.sh` — cargo build mutex isolation — per-worktree CARGO_TARGET_DIR (INFRA-1374)
- `test-change-approval.sh` — change approval workflow — gate, approve, rollback, ambient events (INFRA-912)
- `test-ci-audit-loop.sh` — ci-audit-loop subcommands — tick/audit/heartbeat/help + scanner-anchor discipline (INFRA-1923)
- `test-ci-heavy-jobs-cross-platform.sh` — heavy CI jobs cross-platform — apt-get gated + lane-flippable (INFRA-1542)
- `test-cli-output-format.sh` — CLI output format consistency — --quiet/--format/--json (EFFECTIVE-008)
- `test-cli-version-debug.sh` — CLI version/debug flags (CREDIBLE-019)
- `test-cross-pr-contract.sh` — cross-PR contract gate — refuse merge on cross-PR IPC schema mismatch (INFRA-2406)
- `test-edit-replay.sh` — write-ahead log recovery — wrap/replay round-trip (INFRA-1200)
- `test-error-path-coverage.sh` — error-path test coverage ≥60 assertions across gap_store (CREDIBLE-005)
- `test-infra-779-gitdir-repair.sh` — INFRA-779 gitdir auto-repair — corrupt + verify repair + ambient event (INFRA-1033)
- `test-install-gh-shim-worktree-safe.sh` — install-gh-shim worktree-safety guard (INFRA-1186)
- `test-jit-binary-refresh.sh` — JIT binary refresh wired (INFRA-1977 — H8 critique fix)
- `test-liaison-webhook-cache.sh` — INFRA-1318 Phase 2 end-to-end smoke — webhook cache + liaison slice signals (INFRA-1877)
- `test-lint-handoff-comment.sh` — handoff comment template lint (INFRA-769)
- `test-no-inline-ambient-printf.sh` — no-inline-ambient-printf — Phase-1 dry-up (INFRA-1307)
- `test-no-manual-ship-bypass.sh` — no-manual-ship-bypass guard (INFRA-719)
- `test-orphan-worktree-prune.sh` — orphaned worktree reaper — prune-worktrees.sh orphan mode (RESILIENT-013)
- `test-per-worktree-target-guard.sh` — per-worktree stale binary guard — detect, emit ambient event (RESILIENT-001)
- `test-precommit-guard-audit.sh` — pre-commit vacuous-guard audit (INFRA-508)
- `test-precommit-strict-replay.sh` — precommit strict replay fixture (INFRA-767)
- `test-prepush-worktree-cd.sh` — pre-push hook cd to GIT_WORK_TREE for cargo test (RESILIENT-009)
- `test-pwa-auth-toast-stream.sh` — PWA auth-toast dedup — fleet_auth_fallback stream + unit (INFRA-991)
- `test-pwa-e2e-gap-workflow.sh` — PWA gap workflow e2e — 4-phase stub + status transition (CREDIBLE-020)
- `test-pwa-flake-quarantine.sh` — PWA flake quarantine wiring (INFRA-1332)
- `test-pwa-security.sh` — PWA gap endpoint security — rate limit, CSRF, headers, timeout (CREDIBLE-023)
- `test-pwa-version-compat.sh` — PWA version compatibility check (CREDIBLE-022)
- `test-ruleset-doc-only-pr.sh` — ruleset doc-only-PR wedge guard (INFRA-2191)
- `test-tool-normalize.sh` — tool-call normalizer for weak LLMs (INFRA-740)
- `test-uuid-gap-id-compat.sh` — UUID gap-ID compatibility audit — preflight+show+auto-derive (INFRA-630)
- `test-worker-first-output-watchdog.sh` — worker first-output watchdog — kill switch, event emission, retry (INFRA-828)
- `test-worktree-contamination-check.sh` — worktree contamination check — detect foreign gap files (INFRA-931)
- `test-worktree-prune-protects-live-edits.sh` — worktree-prune protects live edits (INFRA-1347)
- `test-worktree-show-toplevel.sh` — worktree show-toplevel fix (INFRA-810)

## Filed sub-gaps

| Cluster | Gap ID | Title |
|---|---|---|
| A — gap-state consistency | INFRA-3354 | Mirror gap-state-consistency audit-job gates into chump preflight |
| B — PR/worker lifecycle | INFRA-3355 | Mirror PR/worker-lifecycle audit-job gates into chump preflight |
| C — fleet coordination & observability | INFRA-3356 | Mirror fleet-coordination/observability audit-job gates into chump preflight |
| D — worker substrate/worktree/PWA | INFRA-3357 | Mirror worker-substrate/worktree/PWA audit-job gates into chump preflight |

META-086 self-closes when INFRA-3357 (the last of the four) ships.
