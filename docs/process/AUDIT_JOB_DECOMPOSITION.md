# Audit Job Decomposition Survey (META-086)

Survey of every `bash scripts/ci/test-*.sh` invoked by the audit job
(`.github/workflows/audit.yml`, formerly the monolithic `audit` job in
ci.yml, split into a 4-way shard matrix (`audit-shard`) + an `audit-required`
aggregate by INFRA-2565). Regenerate this survey with the same grep pattern
whenever the audit job gains/loses steps -- `scripts/ci/test-audit-job-decomposition.sh`
(AC5) fails CI if this doc drifts out of sync.

**Total distinct test scripts invoked: 120**
**Already mirrored in `src/preflight.rs`: 7**
**Unmirrored: 113**

Discovery note: INFRA-1856 (closed 2026-05-23) estimated ~2 sub-checks; META-086's
own filing re-estimated ~20. This survey found the real number is **120** distinct
scripts -- the audit job grew via 4-way sharding (INFRA-2565) plus a 12-script
unsharded tail bolted onto the `audit-required` aggregate job (itself worth a
follow-up: those 12 run serially, un-sharded, defeating the INFRA-2565 parallelism
win -- see the audit-required-tail cluster below). Confirms the gap's own premise:
scope discovery keeps under-estimating this job's true size.

## Sub-gaps filed (META-086 AC3)

| gap | cluster | scripts | unmirrored |
|---|---|---|---|
| INFRA-3363 | cargo-gates (shard 1) | 29 | 29 |
| INFRA-3364 | event-registry-observability (shard 2) | 29 | 27 |
| INFRA-3365 | bash-script-gates (shard 3) | 36 | 33 |
| INFRA-3366 | cross-pr-security (shard 4) | 14 | 12 |
| INFRA-3367 | audit-required-tail | 12 | 12 |

META-086 self-closes when the last of these five ships (AC4).

## Cluster: cargo-gates (shard 1, 29 scripts, 29 unmirrored)

| script | purpose | mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-gap-list-domain-summary.sh` | chump gap list domain summary + test-filter (INFRA-431) | no |
| `scripts/ci/test-gap-list-done-format.sh` | chump gap list done-format — closed-pr + closed-date (EFFECTIVE-024) | no |
| `scripts/ci/test-state-db-restore.sh` | state.db corruption recovery — restore from state.sql (INFRA-538) | no |
| `scripts/ci/test-pwa-e2e-gap-workflow.sh` | PWA gap workflow e2e — 4-phase stub + status transition (CREDIBLE-020) | no |
| `scripts/ci/test-waste-tally-domain.sh` | waste-tally --domain — token budget by domain, breach exit code (INFRA-934) | no |
| `scripts/ci/test-gap-audit-ac-open.sh` | gap audit-ac --open — warn on vague open gaps before claim (INFRA-936) | no |
| `scripts/ci/test-uuid-gap-id-compat.sh` | UUID gap-ID compatibility audit — preflight+show+auto-derive (INFRA-630) | no |
| `scripts/ci/test-gap-show-ac-render.sh` | gap show AC rendering — numbered list + json ac_count/ac_has_todos (CREDIBLE-033) | no |
| `scripts/ci/test-gap-add-note.sh` | chump gap set --add-note timestamped append (EFFECTIVE-020) | no |
| `scripts/ci/test-cli-output-format.sh` | CLI output format consistency — --quiet/--format/--json (EFFECTIVE-008) | no |
| `scripts/ci/test-gap-consolidate.sh` | gap consolidate — near-duplicate title detection (INFRA-935) | no |
| `scripts/ci/test-pwa-security.sh` | PWA gap endpoint security — rate limit, CSRF, headers, timeout (CREDIBLE-023) | no |
| `scripts/ci/test-release-lease-flag.sh` | release --lease <ID> flag — named session release (INFRA-1026) | no |
| `scripts/ci/test-gap-list-since.sh` | chump gap list --since filter (EFFECTIVE-018) | no |
| `scripts/ci/test-api-gap-queue-shape.sh` | /api/gap-queue fat shape — 15 fields, filters, sort, pillar derivation, ambient signal (INFRA-1197) | no |
| `scripts/ci/test-cross-pr-contract.sh` | cross-PR contract gate — refuse merge on cross-PR IPC schema mismatch (INFRA-2406) | no |
| `scripts/ci/test-gap-list-since-json-schema.sh` | gap list --json schema audit — required fields present in every gap object (CREDIBLE-061) | no |
| `scripts/ci/test-cli-version-debug.sh` | CLI version/debug flags (CREDIBLE-019) | no |
| `scripts/ci/test-run-fleet-cross-repo.sh` | run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634) | no |
| `scripts/ci/test-run-consolidation.sh` | run.sh consolidation — dispatcher + deprecation shims + README refs (INFRA-691) | no |
| `scripts/ci/test-tool-normalize.sh` | tool-call normalizer for weak LLMs (INFRA-740) | no |
| `scripts/ci/test-rollback-gap.sh` | gap rollback — runbook, rollback-gap.sh, ambient event (INFRA-899) | no |
| `scripts/ci/test-gap-rebalance.sh` | gap rebalance — P0 budget + pillar floor (INFRA-635) | no |
| `scripts/ci/test-pillar-balance.sh` | gap pillar-balance — pickable inventory per pillar (INFRA-604) | no |
| `scripts/ci/test-gap-quality-gate.sh` | gap quality gate — TODO/TBD ACs, invalid priority/effort (INFRA-904) | no |
| `scripts/ci/test-gap-templates.sh` | gap templates — pillar starter templates, gap-template.sh dispatcher (INFRA-905) | no |
| `scripts/ci/test-gap-profiling.sh` | per-gap performance profiling — timing wrapper, perf report, flame chart (INFRA-906) | no |
| `scripts/ci/test-gap-run-now.sh` | gap run-now — manual dispatch trigger, event schema, validation (INFRA-895) | no |
| `scripts/ci/test-gap-lifecycle-manager.sh` | gap lifecycle manager — abandoned gap detection (INFRA-870) | no |

## Cluster: event-registry-observability (shard 2, 29 scripts, 27 unmirrored)

| script | purpose | mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-event-registry-coverage.sh` | EVENT_REGISTRY coverage — no drift in either direction (INFRA-1237/INFRA-1287) | yes |
| `scripts/ci/test-event-registry-audit-regression.sh` | EVENT_REGISTRY audit regression — parser correctness (INFRA-2496) | yes |
| `scripts/ci/test-no-inline-ambient-printf.sh` | no-inline-ambient-printf — Phase-1 dry-up (INFRA-1307) | no |
| `scripts/ci/test-cache-event-emission.sh` | cache hit/miss event emission — github_cache.sh telemetry (CREDIBLE-064) | no |
| `scripts/ci/test-gh-shim-script-attribution.sh` | gh-shim script attribution deep walk (CREDIBLE-065) | no |
| `scripts/ci/test-graphql-debounce.sh` | graphql_exhausted debounce when resets_at unknown (INFRA-1968) | no |
| `scripts/ci/test-cache-mergestatestatus.sh` | merge_state_status column — webhook write + shim read + migration (INFRA-1368) | no |
| `scripts/ci/test-liaison-webhook-cache.sh` | INFRA-1318 Phase 2 end-to-end smoke — webhook cache + liaison slice signals (INFRA-1877) | no |
| `scripts/ci/test-ci-audit-loop.sh` | ci-audit-loop subcommands — tick/audit/heartbeat/help + scanner-anchor discipline (INFRA-1923) | no |
| `scripts/ci/test-fleet-metrics-snapshot.sh` | fleet metrics snapshot — ship_rate, waste_rate, cycle_time_p50 (INFRA-900) | no |
| `scripts/ci/test-velocity-trending.sh` | velocity trending — ship_rate/waste_rate 7d trend, improving/stable/degrading (INFRA-901) | no |
| `scripts/ci/test-fleet-brief-pillar-table.sh` | fleet-brief pillar table — per-pillar pickable counts (CREDIBLE-034) | no |
| `scripts/ci/test-alert-classifier.sh` | alert classifier false-positive suppression — operator silent_agent + closed pr_stuck (INFRA-1247) | no |
| `scripts/ci/test-autonomous-ship-rate.sh` | autonomous ship-rate metric fixture (CREDIBLE-047) | no |
| `scripts/ci/test-agent-throughput.sh` | per-agent throughput tracker — tracker script + kpi report --agents (FLEET-044) | no |
| `scripts/ci/test-fleet-race-loss.sh` | speculative race-loss event tracking (FLEET-035) | no |
| `scripts/ci/test-gap-impact-rating.sh` | gap impact rating — rate CLI, ambient event, kpi --impact (FLEET-048) | no |
| `scripts/ci/test-triage-test-failure.sh` | CI failure triage classification (CREDIBLE-013) | no |
| `scripts/ci/test-error-path-coverage.sh` | error-path test coverage ≥60 assertions across gap_store (CREDIBLE-005) | no |
| `scripts/ci/test-audit-workflow-not-cancellable.sh` | audit workflow not cancellable — audit job isolated from ci.yml cancel-in-progress (INFRA-2452) | no |
| `scripts/ci/test-inbox-prune.sh` | inbox-prune — size + age rotation caps for inbox jsonl files (INFRA-1979) | no |
| `scripts/ci/test-pwa-workflow-observability.sh` | PWA workflow observability — request_id tracing (CREDIBLE-024) | no |
| `scripts/ci/test-pwa-version-compat.sh` | PWA version compatibility check (CREDIBLE-022) | no |
| `scripts/ci/test-gap-workflow-status.sh` | PWA gap workflow status endpoint (EFFECTIVE-014) | no |
| `scripts/ci/test-cockpit-wake-fleet.sh` | cockpit Today's-arc Wake-fleet action (PRODUCT-128) | no |
| `scripts/ci/test-fleet-status-rate-limit.sh` | fleet-status rate-limit line format + WARN threshold (EFFECTIVE-025) | no |
| `scripts/ci/test-cost-enforcement.sh` | cost quota enforcement — warning at 80%, hard-cap at 100% (INFRA-877) | no |
| `scripts/ci/test-credential-lifecycle.sh` | credential lifecycle — rotation_due alert, age threshold, dry-run (INFRA-879) | no |
| `scripts/ci/test-gap-closure-consistency-fixture.sh` | gap-closure-consistency fail-closed + fixture-aware DB (CREDIBLE-051) | no |

## Cluster: bash-script-gates (shard 3, 36 scripts, 33 unmirrored)

| script | purpose | mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-precommit-strict-replay.sh` | precommit strict replay fixture (INFRA-767) | no |
| `scripts/ci/test-no-manual-ship-bypass.sh` | no-manual-ship-bypass guard (INFRA-719) | no |
| `scripts/ci/test-worktree-show-toplevel.sh` | worktree show-toplevel fix (INFRA-810) | no |
| `scripts/ci/test-lint-handoff-comment.sh` | handoff comment template lint (INFRA-769) | no |
| `scripts/ci/test-review-handoff-reengage.sh` | review-as-handoff author re-engagement loop (INFRA-771) | no |
| `scripts/ci/test-worker-circuit-breaker.sh` | worker circuit-breaker — threshold=3 pause=5min kill-switch (INFRA-826) | no |
| `scripts/ci/test-worker-first-output-watchdog.sh` | worker first-output watchdog — kill switch, event emission, retry (INFRA-828) | no |
| `scripts/ci/test-worker-timeout-no-commit.sh` | worker timeout-no-commit rescue — kill switch, event emission, SHA diff (INFRA-831) | no |
| `scripts/ci/test-bot-merge-stacked-rebase.sh` | bot-merge stacked PR auto-rebase — kill switch, event emission, gated trigger (INFRA-765) | no |
| `scripts/ci/test-curator-decision-logging.sh` | curator decision logging — kind, required fields, enum, phases (INFRA-848) | no |
| `scripts/ci/test-curator-p0-demotion.sh` | curator p0 demotion — real mutation, oldest P0 selected, max 1/run (INFRA-978) | no |
| `scripts/ci/test-curator-freshness.sh` | curator freshness gate — skip close within active rebase window, event schema (INFRA-1195) | no |
| `scripts/ci/test-curator-auto-decompose.sh` | curator auto-decompose — starved pillar decomposes l/xl gap, guard, dry-run (INFRA-943) | no |
| `scripts/ci/test-curator-pillar-no-overlap.sh` | curator pillar no-overlap — every agent declares unique primary_pillar (MISSION-003) | no |
| `scripts/ci/test-inbox-watcher-pattern.sh` | inbox-watcher pattern — every checked-in agent arms event-driven wake (INFRA-1936 / MISSION-003) | no |
| `scripts/ci/test-required-model.sh` | required_model plumbing — model_selected event, picker filter, execute-gap override (INFRA-843) | no |
| `scripts/ci/test-picker-priority.sh` | picker consumes planner priority (INFRA-1258) | no |
| `scripts/ci/test-mission-picker.sh` | picker surfaces mission-linked gaps before equal-priority substrate (MISSION-011) | yes |
| `scripts/ci/test-mission-picker-worker.sh` | worker picker mission-rank — P0-MISSION beats P0-substrate, substrate P0 beats mission P1 (MISSION-028) | yes |
| `scripts/ci/test-worker-timeout-scale.sh` | worker timeout scaler — no death-spiral, derives from immutable base (RESILIENT-135) | yes |
| `scripts/ci/test-auth-status.sh` | auth-status validity probe — catches depleted-credential-wins-precedence trap (RESILIENT-086) | no |
| `scripts/ci/test-fleet-bootstrap.sh` | chump fleet bootstrap orchestrator (META-066) | no |
| `scripts/ci/test-pwa-flake-quarantine.sh` | PWA flake quarantine wiring (INFRA-1332) | no |
| `scripts/ci/test-worktree-prune-protects-live-edits.sh` | worktree-prune protects live edits (INFRA-1347) | no |
| `scripts/ci/test-pr-failure-auto-rescue.sh` | PR auto-rescue daemon smoke (INFRA-1600) | no |
| `scripts/ci/test-pr-rescue-audit-handler.sh` | PR auto-rescue active audit-handler (INFRA-1618) | no |
| `scripts/ci/test-ci-heavy-jobs-cross-platform.sh` | heavy CI jobs cross-platform — apt-get gated + lane-flippable (INFRA-1542) | no |
| `scripts/ci/test-bot-merge-exit-codes.sh` | bot-merge.sh step-specific exit codes (RESILIENT-010) | no |
| `scripts/ci/test-bot-merge-exit-phases.sh` | bot-merge.sh per-phase exit codes + ambient event (RESILIENT-011) | no |
| `scripts/ci/test-prepush-worktree-cd.sh` | pre-push hook cd to GIT_WORK_TREE for cargo test (RESILIENT-009) | no |
| `scripts/ci/test-known-flakes-gate.sh` | KNOWN_FLAKES auto-bypass gate — 11 pre-push flakes catalogued (RESILIENT-012) | no |
| `scripts/ci/test-orphan-worktree-prune.sh` | orphaned worktree reaper — prune-worktrees.sh orphan mode (RESILIENT-013) | no |
| `scripts/ci/test-stale-worktree-reaper-tmp.sh` | stale-worktree-reaper extends to /tmp/chump-* (INFRA-2020) | no |
| `scripts/ci/test-bot-merge-watchdog.sh` | bot-merge watchdog — kills done-gap procs, spares open-gap, exempt bypass (INFRA-1006) | no |
| `scripts/ci/test-bot-merge-graphql-preflight.sh` | bot-merge GraphQL preflight + REST fallback — fails fast, emits graphql_exhausted (INFRA-1031) | no |
| `scripts/ci/test-install-gh-shim-worktree-safe.sh` | install-gh-shim worktree-safety guard (INFRA-1186) | no |

## Cluster: cross-pr-security (shard 4, 14 scripts, 12 unmirrored)

| script | purpose | mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-rollup-cascade-cancel.sh` | cascade-cancel rollup classification fixture (INFRA-1002) | no |
| `scripts/ci/test-bounced-pr-detector.sh` | bounced-PR detector fixture (INFRA-781) | no |
| `scripts/ci/test-orphan-pr-closer.sh` | orphan-PR closer fixture (INFRA-1139) | no |
| `scripts/ci/test-stale-binary-ship-blocked.sh` | stale-binary destructive-op guard (INFRA-825) | no |
| `scripts/ci/test-jit-binary-refresh.sh` | JIT binary refresh wired (INFRA-1977 — H8 critique fix) | no |
| `scripts/ci/test-fleet-state-mutex.sh` | fleet-state.json mutex — flock, kill switch, timeout event (INFRA-847) | no |
| `scripts/ci/test-gh-api-probe.sh` | gh-api-probe wired in bot-merge + run-fleet (INFRA-539) | no |
| `scripts/ci/test-change-approval.sh` | change approval workflow — gate, approve, rollback, ambient events (INFRA-912) | no |
| `scripts/ci/test-gap-ac-requirement.sh` | gap AC enforcement — pre-commit rejects gaps without acceptance_criteria (CREDIBLE-054) | no |
| `scripts/ci/test-no-raw-gh-in-hot-paths.sh` | raw-gh lint gate — no new direct gh calls in hot-path scripts outside lib/ (INFRA-1274) | yes |
| `scripts/ci/test-no-new-bypass-env-vars.sh` | no-new-bypass-env-vars — forbid new CHUMP_*_BYPASS/SKIP/IGNORE_* (INFRA-2429) | yes |
| `scripts/ci/test-precommit-guard-audit.sh` | pre-commit vacuous-guard audit (INFRA-508) | no |
| `scripts/ci/test-worktree-contamination-check.sh` | worktree contamination check — detect foreign gap files (INFRA-931) | no |
| `scripts/ci/test-per-worktree-target-guard.sh` | per-worktree stale binary guard — detect, emit ambient event (RESILIENT-001) | no |

## Cluster: audit-required-tail (shard required-tail, 12 scripts, 12 unmirrored)

| script | purpose | mirrored in preflight.rs |
|---|---|---|
| `scripts/ci/test-infra-779-gitdir-repair.sh` | INFRA-779 gitdir auto-repair — corrupt + verify repair + ambient event (INFRA-1033) | no |
| `scripts/ci/test-known-flake-skip.sh` | pre-push known-flake skip integration (INFRA-1167) | no |
| `scripts/ci/test-pr-scope-title-fallback.sh` | pr-scope PR_TITLE fallback chain (INFRA-976) | no |
| `scripts/ci/test-bot-merge-arm-ship-order.sh` | bot-merge arm-before-ship ordering fix (INFRA-1030) | no |
| `scripts/ci/test-operator-recovery.sh` | operator-recovery umbrella — CHUMP_OPERATOR_RECOVERY=1 bypass set + audit event (INFRA-1028) | no |
| `scripts/ci/test-pillar-dashboard.sh` | pillar health dashboard endpoint + web component (PRODUCT-090) | no |
| `scripts/ci/test-merge-driver-ci-yml-add-row.sh` | ci-yml merge-driver orphan-step rejection (INFRA-1199) | no |
| `scripts/ci/test-ruleset-doc-only-pr.sh` | ruleset doc-only-PR wedge guard (INFRA-2191) | no |
| `scripts/ci/test-edit-replay.sh` | write-ahead log recovery — wrap/replay round-trip (INFRA-1200) | no |
| `scripts/ci/test-pwa-auth-toast-stream.sh` | PWA auth-toast dedup — fleet_auth_fallback stream + unit (INFRA-991) | no |
| `scripts/ci/test-pillar-balance-guard.sh` | pillar-balance guard at reserve time (INFRA-1152) | no |
| `scripts/ci/test-cargo-mutex-isolation.sh` | cargo build mutex isolation — per-worktree CARGO_TARGET_DIR (INFRA-1374) | no |

