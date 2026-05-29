# Integration-Cycle Ship Pipeline

**Authored:** 2026-05-29 by curator-opus-orchestrator.
**Status:** Operator-reviewed. Shipped via INFRA-2129.
**Closes (when shipped):** META-NNN — Integration-cycle ship pipeline umbrella.
**Companion docs (existing):**
- [`docs/strategy/MARKET_POSITIONING_2026-05-27.md`](MARKET_POSITIONING_2026-05-27.md) — the 5-bet strategic compass
- [`docs/strategy/NATS_A2A_DEMO_2026-05-28.md`](NATS_A2A_DEMO_2026-05-28.md) — the substrate this builds on
- [`docs/strategy/CI_REVIEW_2026-05-29.md`](CI_REVIEW_2026-05-29.md) — the problem catalog

## The problem (the operator's friend was right)

For the last ~6 months, every Chump gap has shipped as its own GitHub PR. That model has run into a wall that's visible in today's numbers:

- **30-40 min P50 ship time** across the last 5 merges. Today's session: 5+ hours for 9 PRs to settle.
- **Cache-key collisions at concurrency > 4** (INFRA-2126 filed today). 5 of 6 concurrent PRs failed the ACP smoke test gate not because the code was wrong but because `rust-cache` keys collided on `Cargo.lock` hash. Sequential rerun cleared it.
- **20+ CI gates × N concurrent PRs ÷ 4 self-hosted runners** is the floor. With N=8 in flight (today's normal), each PR waits 20+ min just for a runner slot.
- **Operational surface to keep PRs moving:** `bot-merge.sh` (1500 LOC), `pr-rescue.sh`, fork-aware shepherd (INFRA-2114 just landed), 17 launchd daemons. Most of this exists to compensate for the per-PR model's friction, not to do useful work.
- **GraphQL exhaustion is multiple-times-per-day** during fleet peaks. Most of the burn is per-PR metadata fetches.
- **Flake-rerun loops** are the dominant operator interaction. Today: ACP cache-collision rerun, e2e-pwa flake rerun, cargo-test rerun. Each is 1-2 commands and 5-15 min of wait.

This isn't just slow — it's *self-inflicted slow*. The model we picked optimizes for a problem we don't have (distributed open-source contributors needing async code review). The problem we *do* have is an AI fleet that produces correct atomic changes faster than CI can verify them.

The friend's three questions, restated honestly:

1. **Why GitHub for dev cycles?** → For us today: audit trail + Marcus/Patrick demo surface. Nothing else load-bearing.
2. **Why not bigger ships fewer times a day?** → Because we didn't have the coordination substrate to do it. We do now (NATS A2A landed last night).
3. **Have you thought about doing it differently?** → No, but we should.

## What changed last night

The Bet 5 substrate — NATS-backed atomic CAS, work-board, ambient events — went live on M4-primary at 2026-05-28T01:17:35Z (INFRA-2102, PR #2696, merged). That substrate is *exactly* the coordination layer this new model needs. We could not have done this in March 2026; we can do it today.

## The four operating modes

The current model treats every gap the same: claim → branch → PR → CI → merge. The new model recognizes that **different work has different governance needs.**

### Mode A — Batched (DEFAULT)

The lane most fleet work goes through. Gaps queue on the work-board; an integrator daemon batches them, runs CI **once** on an integration branch, ships as a single PR to main.

**Trigger:** every 30 min OR when 5+ gaps queued OR cumulative LOC > 1500 (whichever first). 5-min time-floor after first gap arrives (catches siblings).

**Bound:** max 10 gaps per cycle. Above 10, two cycles. Bisect granularity stays manageable.

**Ship:** single PR titled `integration-YYYY-MM-DD-HHMM (N gaps): <comma-separated short titles>`. Body lists each child gap with link + commit SHA. ONE auto-merge.

### Mode B — Per-PR (REVIEW-REQUIRED)

The lane for changes that need atomic visibility: external-collab work (Marcus surface), partnership comms, strategic docs, anything where the operator wants the diff readable as a unit.

**Opt-in:** gap title starts with `REVIEW:` prefix, OR gap has `acceptance_criteria` mentioning "operator review", OR gap is filed by curator-opus-external-collab lane.

**Ships as today:** individual PR, individual CI run, individual auto-merge.

**Expected volume:** ~10-20% of fleet work. The rest goes Batched.

### Mode C — Hot-fix (URGENT)

The lane for P0 trunk-red, security, immediate-unblock. Skips the queue.

**Trigger:** gap priority = P0 AND title contains "TRUNK-RED" OR "HOTFIX" OR "SECURITY", OR operator manually flags `chump gap hot-fix INFRA-NNNN`.

**Ships as today:** individual PR, individual CI run, but with elevated runner priority (assigned to runner-1 explicitly if free).

**Expected volume:** <1% — rare by definition.

### Mode D — External-repo (META-123 lane)

The lane for work that ships to an external target repo (ehippy/derelict, etc.) rather than chump main. Uses the META-123 7-role flow (Scout → Decompose → External-collab → Target → Handoff → Shepherd → Context-Keeper).

**Ships to external target, not chump main:** PR opens in the customer's repo. Chump main never sees these changes.

**Audit lifecycle is separate** — the customer-arc memory in `~/.chump/external/<owner>/<repo>/` tracks what shipped and learned.

Already-defined in META-123. Out of scope for this strategy except for the inter-mode handoff.

## The integration cycle (Mode A) in detail

This is the core of the new model. Let's walk it.

### Trigger conditions

The `chump-integrator-daemon` runs continuously, polling the NATS work-board every 15 seconds for gaps with `status: ready_to_ship` AND `mode: batched` (default).

When ANY of the following holds, a cycle fires:

| Trigger | Default | Rationale |
|---|---|---|
| Cadence | 30 min since last cycle | Bounds operator wait time |
| Volume | 5+ gaps queued | Amortizes CI fixed cost |
| Time-floor | 5 min after first gap arrives | Catches siblings without making first-arrival wait |
| LOC budget | 1500 lines staged in queue | Bounds bisect difficulty |
| Operator | `chump integrate --now` | Manual override |

The first trigger to fire wins. Cycle starts.

### Cycle lifecycle

```
1. ATOMIC CLAIM
   - chump-coord claim integration-slot --ttl 30m
   - If another integrator wins: defer to next 15s poll
   - If we win: emit kind=integration_cycle_started

2. CANDIDATE SELECTION
   - Read NATS work-board: gaps with status=ready_to_ship AND mode=batched
   - Sort by priority (P0 first), then by queue time
   - Take up to 10 (or LOC budget cap)
   - Emit kind=integration_candidates_selected with manifest

3. INTEGRATION BRANCH
   - git fetch origin main
   - git checkout -b integration-{YYYY-MM-DD-HHMM} origin/main
   - For each candidate:
     - git fetch origin chump/<gap-branch>
     - git merge --no-ff origin/chump/<gap-branch> \
         -m "Batched: <gap-id> — <gap-title>"
         --no-edit
   - Per-merge: emit kind=integration_branch_merged

4. PREFLIGHT
   - bash scripts/dev/cross-build-linux.sh  (Linux build proof)
   - cargo fmt --check + clippy --all-targets -- -D warnings
   - scripts/ci/test-*.sh matching touched files (existing path-filter)
   - chump preflight  (existing tool, INFRA-1670)
   - All in one shell, no parallel
   - Time budget: 8 min. If exceeded, classify as bisect-candidate.

5. DECISION
   - If green: proceed to SHIP
   - If red: proceed to BISECT

6a. SHIP (green case)
   - git push origin integration-{date}
   - gh pr create --base main --head integration-{date}
       --title "integration-{date} (N gaps): <titles>"
       --body "<manifest with gap IDs, SHAs, links>"
   - gh pr merge <N> --auto --squash
   - On merge: emit kind=integration_cycle_shipped with full manifest
   - All child gaps: chump gap ship <ID> --integration <integration-id>
   - Each child gap status flips from ready_to_ship → shipped

6b. BISECT (red case)
   - git bisect start
   - git bisect bad HEAD
   - git bisect good origin/main
   - git bisect run scripts/dev/integration-bisect-step.sh
   - Identifies the FIRST bad commit (= the offending gap merge)
   - Emit kind=ship_bisect_root_cause with gap ID + failure class
   - Quarantine: remove that gap's merge, re-run preflight
   - If green after quarantine: SHIP (step 6a) the rest
   - Quarantined gap goes back to work-board with status=bisect_quarantined
   - Filed-but-quarantined gap appears in operator's morning brief

7. CLEANUP
   - chump-coord release integration-slot
   - Local integration branch: kept for 24h (audit + bisect replay), then pruned
   - Worktrees of shipped gaps: cargo-target-reaper handles (INFRA-2125 just landed)
```

### Failure handling deep-dive

The thing that scares people about batched ship is "what if one bad commit blocks 9 good ones." That's the bisect-on-red logic above. Concretely:

- **Median outcome:** all gaps pass. Ship as one PR. <5 min from cycle-start to main.
- **Single bad gap:** bisect identifies it in O(log N) merges = ~3-4 preflight runs at N=10. Total recovery: 25-30 min. Worse than a clean cycle, still better than today's per-PR runner contention.
- **Multiple bad gaps:** quarantine each, ship the rest. The bad gaps go back to their authors (or to a recovery queue).
- **Bisect inconclusive (rare):** the whole cycle aborts, all gaps go back to ready_to_ship status, each gets a `bisect_inconclusive` flag, operator reviews.

The bisect step (`scripts/dev/integration-bisect-step.sh`) is just `chump preflight` wrapped. No new logic; reuses what we have.

### Branch naming + retention

| Branch | Lifetime | Reason |
|---|---|---|
| `chump/infra-NNNN-claim` | Created at claim, deleted after gap ships in an integration | Per-gap audit + bisect anchor |
| `integration-YYYY-MM-DD-HHMM` | 24h after merge | Replay for bisect-quarantine review |
| `integration-quarantine-NNN` | Until operator review | Quarantined gap holding |

We do NOT delete per-gap branches immediately. The chump-pr-pulse-consumer daemon (INFRA-2098-class) can prune them after the integration PR is on main + 24h.

## Audit trail preservation (the friend's other concern)

The audit-trail value of GitHub PRs is real — Marcus, Patrick, regulators, future Anthropic reviewers all read PRs as the source of truth. We do NOT lose this; we restructure it.

### Per-commit attribution

Each child gap's commit on the integration branch carries trailers:

```
feat(INFRA-2108): chump onboard <repo-url> — first-touch repo scan

<original commit body>

Batched-Under: integration-2026-05-29-1430
Co-Authored-By: <original author>
```

The `Batched-Under` trailer lets `chump gap show INFRA-2108` resolve to "shipped in integration-2026-05-29-1430 (PR #NNNN)" instead of "shipped in PR #NNNN" directly.

### Integration PR body

Every integration PR's body has:

```markdown
## Integration cycle: integration-2026-05-29-1430

**Triggered by:** volume (5 gaps queued + LOC > 1500)
**Started:** 2026-05-29T14:30:00Z
**Preflight:** green in 6m 12s

### Gaps shipped (N)

| Gap | Commit | Author | LOC | Class |
|---|---|---|---|---|
| INFRA-2108 | abc123 | chump-worker-3 | +540 | rust |
| INFRA-2109 | def456 | chump-worker-1 | +120 | shell |
| ...

### Quarantined (if any)

| Gap | Reason |
|---|---|

🤖 Integration cycle shipped by chump-integrator-daemon
```

The PR is searchable, reviewable, revertible at the level of the entire cycle. Individual gap rollback uses `git revert <child-commit-sha>` on main.

### ambient events

New event kinds (registered per INFRA-754):

| Kind | Emitted by | Captures |
|---|---|---|
| `integration_cycle_started` | integrator daemon | cycle ID, trigger reason, candidate count |
| `integration_candidates_selected` | integrator daemon | full manifest of gap IDs |
| `integration_branch_merged` | integrator daemon | per-gap merge with parent SHA |
| `integration_preflight_started` | integrator daemon | branch name, expected duration |
| `integration_preflight_failed` | integrator daemon | failure class, log location |
| `ship_bisect_root_cause` | integrator daemon | offending gap ID, failure signature |
| `bisect_quarantine` | integrator daemon | quarantined gap ID, queue placement |
| `integration_cycle_shipped` | integrator daemon | final manifest, PR URL, merge SHA |

All registered in `EVENT_REGISTRY.yaml` with scanner anchors per CLAUDE.md discipline.

### `chump gap` query resolution

```bash
$ chump gap show INFRA-2108
- id: INFRA-2108
  status: shipped
  shipped_in:
    integration: integration-2026-05-29-1430
    integration_pr: https://github.com/repairman29/chump/pull/2789
    commit: abc1234...
    merge_sha: f8e9d2a...
  ...
```

The operator (or any agent) can resolve "what shipped" by gap ID exactly as today.

## Automation: the new daemon + existing-daemon updates

### chump-integrator-daemon (new)

A new launchd-managed binary `crates/chump-integrator/src/main.rs`. Polls NATS work-board, runs the cycle lifecycle above. Inspired by `chump-coord assign` (FLEET-034 dispatcher) which uses the same NATS substrate.

**Config (env-driven, sensible defaults):**

| Env var | Default | Purpose |
|---|---|---|
| `CHUMP_INTEGRATOR_CADENCE_MIN` | 30 | Cadence trigger threshold |
| `CHUMP_INTEGRATOR_VOLUME_THRESHOLD` | 5 | Volume trigger threshold |
| `CHUMP_INTEGRATOR_LOC_BUDGET` | 1500 | LOC budget per cycle |
| `CHUMP_INTEGRATOR_MAX_BATCH` | 10 | Max gaps per cycle |
| `CHUMP_INTEGRATOR_PREFLIGHT_TIMEOUT_S` | 480 | 8 min preflight bound |
| `CHUMP_INTEGRATOR_DRY_RUN` | 0 | Set to 1 for dry-run mode |
| `CHUMP_INTEGRATOR_SAMPLING_PCT` | 100 | Phase 2 ramp-up knob |

Lives at `~/Library/LaunchAgents/dev.chump.integrator.plist` with `RunAtLoad=true`, `KeepAlive=true`. Installed by `scripts/setup/install-chump-integrator-launchd.sh`.

### bot-merge.sh (modified)

Stays. Becomes the **Mode B + Mode C** dispatcher:
- If gap title starts with `REVIEW:` → bot-merge.sh runs as today (single PR)
- If gap is hot-fix → bot-merge.sh runs with priority + bypass-batched flag
- Else → bot-merge.sh recognizes `mode: batched` and instead of opening a PR, marks the gap `status: ready_to_ship` in NATS work-board

Same surface, smarter routing. Operator's existing muscle memory works.

### pr-rescue.sh (modified)

Add integration-branch awareness:
- If PR is `integration-*`, run the per-cycle bisect on rescue rather than per-PR rebase
- If PR is per-gap and integration-shipped, mark it `superseded` and close

### cargo-target-reaper (already covers this, INFRA-2125)

The reaper just shipped today covers `/tmp/chump-*/target/` in lease-active worktrees with PR-open + auto-merge-armed + HEAD-pushed. This logic extends naturally: an integration-shipped gap's worktree gets reaped at the next reaper tick.

### chump-pr-pulse-consumer (new follow-up)

After integration ship, prune the per-gap branches on origin. ~10-line bash daemon, fires off the `integration_cycle_shipped` ambient event.

## Migration: how we get from today to here without breaking

### Phase 1 — Dry-run (1 session)

Goals:
- Integrator daemon installed, runs every 15s, polls work-board
- On trigger: walks the cycle lifecycle but stops before `gh pr create`
- Reports "would have batched N gaps: <list>, preflight outcome: green/red, estimated time saved: X min"
- Logged to `~/.chump/integrator-dry-run.log` and ambient.jsonl

Operator observes for ~24h. Compares the dry-run log against actual PR queue. Calibrates thresholds (maybe cadence wants to be 20 min, not 30; maybe LOC budget wants to be 1000).

Effort: ~1 working session (3-4 hours). Mostly the integrator daemon scaffolding + the cycle-lifecycle walk in dry-run mode.

### Phase 2 — Sampling (1-2 weeks)

Once Phase 1's dry-run runs cleanly:
- `CHUMP_INTEGRATOR_SAMPLING_PCT=10` — every 10th eligible batch goes live
- Other 90% remain dry-run
- Operator monitors ship outcomes, latency, bisect rates

Calibrate down until bisect-quarantine rate < 5% of cycles. If rate is higher, tighten thresholds (smaller batches, more frequent cycles).

### Phase 3 — Default-on (after Phase 2 metrics look good)

- `CHUMP_INTEGRATOR_SAMPLING_PCT=100` — every eligible batch goes live
- Per-PR mode is opt-in only (via `REVIEW:` title prefix or hot-fix)
- bot-merge.sh defaults to batched routing
- DOC update: CLAUDE.md, AGENTS.md, OPERATOR_PLAYBOOK.md all describe Batched as default

### Phase 4 — Tuning (continuous)

- Thresholds drift based on observed flake rate, CI time, ship volume
- Eventually: per-gap-class thresholds (Rust gets larger batches; docs ship faster)

## Metrics: how we know this is working

Six measurable shifts from today's baseline to target:

| Metric | Today | Phase 3 target | How measured |
|---|---|---|---|
| P50 gap-to-main latency | 30-40 min | <20 min | `chump kpi report --pillar effective` |
| Mean CI runs per shipped gap | ~1.0 (each gap = 1 PR = 1 CI run) | ~0.15 (1 CI run amortizes ~7 gaps) | runner job count / shipped gap count |
| Runner peak utilization | ~80% (often pegged) | <50% | self-hosted-runner-cache metrics |
| Bisect-quarantine rate | N/A (doesn't exist) | <5% of cycles | new ambient event count |
| GraphQL exhaustion events / day | 2-4 typical | <0.5 | api-cost-leaderboard.sh |
| Operator flake-rerun interventions / day | 5-10 typical | <1 | manual_rescue count in fleet-brief |

Each is auto-tracked. The L2-SLO list gets a new entry: `L2-SLO-6: bisect-quarantine rate < 5%`.

## External-facing changes

### Marcus pitch update (curator-opus-external-collab lane)

The new sentence for `PITCH.md`:

> Chump ships **integration cycles** — batched fleet output through a single CI pass — landing 5-10 changes per cycle instead of 1 per PR. This is how multi-agent factories scale: one verification, many improvements.

This is genuinely a better story than "30+ tiny PRs/day clogging the queue." Marcus understands cycles; he'd push back on per-PR-per-tiny-change.

### DEMO_5MIN.md update

Minute 4 (currently "show recent merges to main") becomes:

> Here's last night's integration cycle: 7 gaps shipped through ONE CI pass + ONE auto-merge. Total CI cost: ~8 minutes wall, ~$0.32 in runner time. Equivalent per-PR cost: ~7 × 30 min = 3.5 hours wall, ~$2.20.

The cost comparison lands.

### OPERATOR_PLAYBOOK.md update

The `§4 Ship pipeline` section gets restructured:
- Default: `chump claim → work → push → mark ready` (no `gh pr create`)
- Override: `chump claim --review → bot-merge.sh --auto-merge`
- Hot-fix: `chump claim --hot-fix → bot-merge.sh --hot-fix --auto-merge`

The operator's keystrokes per-gap drop from ~6 commands to ~2.

## What this doc IS / IS NOT

**IS:** the strategy + architecture + migration plan + metrics to shift Chump's default ship discipline from per-PR to integration-cycle. Operator-reviewable. Tractable in 1-2 sessions to Phase 1 dry-run.

**IS NOT:** an abandonment of GitHub. PRs still happen — just as integration cycles rather than per-gap. Audit trail strengthens (richer PR bodies, ambient event manifest, gap-resolves-to-cycle). Per-PR mode remains available for review-required work.

**IS NOT:** an enterprise-tier vs single-user split. Same machinery serves both. The four operating modes give the operator a knob per-gap (or per-class); enterprises that need stricter governance pin everything to Mode B + signed commits.

## Open questions (the operator's call)

1. **Cadence default — 30 min vs 60 min vs hourly-on-the-hour?** I started with 30 min; operator may prefer slower to amortize more.
2. **Max-batch default — 10 vs 20?** Bigger means fewer cycles but worse bisect.
3. **Should hot-fix bypass the integrator entirely, or use a high-priority lane within it?** Currently I sketched bypass. Operator may want one path.
4. **Should `REVIEW:` be the only Mode B opt-in, or do we also automate it for certain gap classes (e.g. all `external-collab` gaps)?** I leaned automated; operator may want explicit.
5. **Phase 1 dry-run duration — 24h, 72h, week?** Lookback budget vs migration velocity.

## Cross-references

- **META-NNN** (this umbrella) — the integration-cycle ship pipeline
- **META-123** (external-repo flow) — Mode D defined there
- **DOC-063** (CI bottleneck review — [`docs/strategy/CI_REVIEW_2026-05-29.md`](CI_REVIEW_2026-05-29.md)) — quantified Lever 1 + 3 here
- **INFRA-2102** (NATS A2A substrate) — the foundation this builds on
- **INFRA-2125** (cargo-target-reaper fixes) — disk hygiene works with new model
- **INFRA-2126** (ACP cache-key collision) — symptom this strategy addresses structurally
- **INFRA-1670** (chump preflight) — reused as preflight step
- **INFRA-1670 / INFRA-1673** (local CI discipline) — gates remain mandatory pre-push for individual workers; integrator runs once at the integration

## Effort estimate

Roughly:
- **Strategy doc itself** (this): ~4 hours, done
- **chump-integrator-daemon (Phase 1 dry-run)** in Rust: ~2 working sessions (~8 hrs)
- **Ambient event kinds + registry** updates: ~1 hr
- **bot-merge.sh routing changes**: ~2 hrs
- **chump gap query + show resolution**: ~3 hrs
- **External-facing doc updates** (PITCH, DEMO_5MIN, OPERATOR_PLAYBOOK): ~2 hrs
- **Phase 2 sampling logic** (Phase 1+1 deliverable): ~3 hrs
- **Phase 3 default-on docs + flag flip**: ~2 hrs (after sampling validates)

**Total to Phase 1 dry-run: ~3 working sessions (~12 hrs).** Most slices ship as parallelizable Sonnet dispatches once the umbrella is decomposed.
