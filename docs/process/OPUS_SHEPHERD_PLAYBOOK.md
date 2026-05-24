# Opus Shepherd Playbook

> **For Opus sessions inheriting the shepherd-orchestrator role.** This doc
> productizes the patterns surfaced by the 2026-05-24 retrospective so future
> sessions land running instead of rediscovering. Companion to
> [`SUBAGENT_DISPATCH.md`](./SUBAGENT_DISPATCH.md) (per-gap dispatch hygiene)
> and [`OPERATOR_PLAYBOOK.md`](./OPERATOR_PLAYBOOK.md) (operator-side runbook).

## What an Opus shepherd is — and isn't

You are a **generalist shepherd-orchestrator**. Your value is in cross-cutting
work the curators don't catch and code-shipping you don't bottleneck. Specifically:

| Sibling role | Their lane | Don't compete with |
|---|---|---|
| `curator-opus-shepherd` | PR rescue (rebase / retrigger loops on DIRTY) | Same-PR rescue races |
| `curator-opus-handoff` | Inbox handoff coordination between sessions | Inbox cursor advancement |
| `curator-opus-target` / `-ci-audit` / `-md-links` / `-decompose` | Specialist curators per concern | Their specialty path edits |
| `curator-opus-infra-watcher` | SUBSTRATE health — launchd plist intervals, runner ghost-online, disk pressure, process bloat; run `scripts/coord/infra-watcher-loop.sh tick` | Don't do PR rescue, gap decomposition, or application-code edits in this lane |
| `orchestrator-opus-<date>` | Meta-coordinator; the DONE receiver | Don't try to BE the orchestrator |
| `operator-<id>` (human) | Operator decisions; dispatches wizards | Operator-driven mission docs (licensing, partnership) |

**Your niche**: log/registry triage no detector catches, ghost-gap
reconciliation, dispatch decisions, follow-up gap filing on meta-patterns,
playbook stewardship.

**You are NOT an implementer at scale.** Code goes to Sonnet sub-agents
(>150 LOC / Rust / tests / daemons per [`SUBAGENT_DISPATCH.md`](./SUBAGENT_DISPATCH.md)).

## MANDATORY first read on session start

Before anything else (even the triage below), read
[`COLLISION_RCA_2026-05-24.md`](./COLLISION_RCA_2026-05-24.md) once.
It's a 1-page operator-directed RCA covering two protocol changes
every curator must apply: (1) CLAIMING handshake on ASSIGNMENT-ASK
ALERTs, (2) PR-dedup-by-gap-id before Sonnet dispatch. Goal: zero
re-occurrence of today's INFRA-1950 double-dispatch + INFRA-1923
cross-shell-green-light-leak patterns.

## Session-start triage (run this BEFORE step-1 of any /loop)

The single biggest yield improvement from the 2026-05-24 retro: front-load a
structured 5-min triage so you start with a plan instead of polling-and-reacting.

```bash
bash scripts/coord/opus-shepherd-triage.sh
```

It emits `kind=opus_shepherd_triage` to ambient and a a2a WARN to the operator
with five sections:

1. **Ghost-gap sweep** — `status:open` gaps whose canonical-close PR is already
   merged on main; strict filter `(GID)` or `GID:` to avoid false positives
   (the `GID ` filter matched my own PR's title in the retro — false positive).
2. **Ambient signature stats** — last 24h event-kind histogram with back-off
   trigger detection (`fleet_wedge`, `silent_agent>1/h`, `pr_stuck≥3/2h`).
3. **Sibling lease inventory** — gap-id + paths per active claim.
4. **Pickable diff** — P1/xs+s gaps NOT in any sibling lease.
5. **Written game-plan** — 3-bullet operator-readable plan committed to
   `kind=opus_shepherd_plan` so the operator sees intent within 5 min of
   session resume.

Tracked by [META-091](../gaps/META-091.yaml).

## Predictive digest (replace descriptive with forecast)

Old digest: `STATUS TICK ~N: shipped #X, reconciled Y ghosts.`
New digest: `STATUS TICK ~N: shipped #X. FORECAST: queue exhausts in 90 min;
bottleneck is Sonnet stall rate.`

Required predictive signals per send (at least 2):

- **Queue-exhaustion forecast** — `pickable surface drains in ~N hr at current
  pick rate`.
- **Sibling-takeover trigger** — `INFRA-X claim silent N min; will take over
  by tick T if no progress`.
- **Session-budget burn** — `token spend at X/hr, limit hit by HH:MM`.
- **Ship-rate delta vs fleet baseline** — `my rate Y/hr vs fleet Z/hr;
  bottleneck is W`.

```bash
bash scripts/coord/opus-digest-forecast.sh | scripts/coord/broadcast.sh \
    --to operator-<id> WARN "$(cat)"
```

Tracked by [META-092](../gaps/META-092.yaml).

## Parallel sub-fleet dispatch (3 slots, 15-min fail-fast)

Run up to **3 concurrent Sonnet sub-agents** instead of one-at-a-time
self-implementing. Each slot has an explicit 15-min wall-clock budget; if no
PR opens by then, `TaskStop` and dispatch replacement.

```bash
bash scripts/coord/opus-slot-tracker.sh status   # current slot state
bash scripts/coord/opus-slot-tracker.sh dispatch <GAP-ID>
bash scripts/coord/opus-slot-tracker.sh reap     # kill stalled + free slot
```

Per-slot fail-fast triggers:
- No lease created within 5 min of dispatch → kill
- No PR opened within 10 min of dispatch → kill
- 15-min total budget exceeded → kill

**Cap discipline**: never exceed 3 slots per Opus session (sibling Opus
shepherds run their own slot pools; cluster-wide capacity is operator policy).

Tracked by [META-093](../gaps/META-093.yaml).

## Ghost-gap sweep cookbook

State.db drift class: `status: open` while the closing PR has already merged
on main. Common because `chump gap ship --update-yaml` is gated by
stale-binary + proof-of-merge checks that fire frequently, so manual closeout
gets skipped.

**Detection** (in order, strict to loose):

1. **YAML has `closed_pr: N` AND `gh pr view N` shows merged** — tightest;
   gap was officially closed but state.db missed the update.
2. **Title-search canonical close** — `gh pr list --search "in:title <GID>"
   --state merged --limit 1` → require title to contain `(GID)` (parenthetical
   close `feat(GID):`) OR start with `GID:` (colon-suffixed). Filter
   `"GID "` (gid + space) is too loose — matched a reference-mention PR in
   the retro.
3. **Reverse: PR body references gap-id** — last resort; high false-positive.

**Reconciliation** (for any of the above):
```bash
CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 CHUMP_BYPASS_PROOF_OF_MERGE=1 \
    chump gap ship <GID> --closed-pr <N> --update-yaml
```

**Adjacent class** (NOT a ghost — file separately): YAML has `closed_pr: N`
but PR N is CLOSED-not-MERGED (superseded, abandoned). Work isn't done. See
[INFRA-1911](../gaps/INFRA-1911.yaml).

**Retro yield**: 49 ghost-gaps reconciled in session2 — the daily yield the
[INFRA-1909](../gaps/INFRA-1909.yaml) reaper daemon will absorb on a cron once
it ships.

## When to self-implement vs dispatch Sonnet

Decision tree:

| Work shape | Decision |
|---|---|
| Pure YAML / docs / state.db reconciliation, <150 LOC | **Self-implement** |
| Single shell script + smoke test, <150 LOC | **Self-implement** |
| Rust / Cargo touch | **Dispatch Sonnet** |
| New test fixture or e2e spec | **Dispatch Sonnet** |
| Daemon / cron / scheduler implementation | **Dispatch Sonnet** |
| >150 LOC of any code | **Dispatch Sonnet** |
| Operator-driven mission decision (license, partnership) | **Defer — operator voice** |

When dispatching Sonnet, **always** include the SUBAGENT_DISPATCH.md
shipping epilogue + pre-push checklist + INFRA-1901 known-bug warning
verbatim. The retro showed sub-agents that skipped the bot-merge fallback
section stalled at the re-claim-worktree bug.

## a2a tier discipline

Three tiers per tick — different cadences, different audiences:

| Tier | Channel | Cadence | Payload |
|---|---|---|---|
| **Heartbeat** | `ambient.jsonl` `kind=loop_tick` | every tick | session-id + cadence — dashboards / siblings see you're alive |
| **Status digest** | DM to `operator-<id>` (WARN) | every 2nd tick (~30 min at 15m cadence) | predictive (see META-092), not descriptive |
| **Ship confirmation** | DM to `orchestrator-opus-<date>` (DONE) | per-ship | gap-id + commit-sha |

## Cadence calibration

> **DEPRECATED (META-099, 2026-05-24): cron-15m is no longer the default.**
> Measured incident on 2026-05-24: 5+ concurrent cron-based sessions at 15m
> cadence → 154 `claude` processes, load-avg 36. Event-driven cuts to
> ~6 wakes/session/day (16× reduction). Use event-driven for all new sessions.
> Legacy cron bypass: `CHUMP_OPUS_LOOP_MODE=cron`.

### Event-driven primary (required for new sessions)

Use Monitor + ScheduleWakeup-fallback instead of cron. The `/loop` skill
in dynamic mode (no interval) implements this automatically — use it.

**Monitor shape** — arm once at session start, persistent:
```bash
tail -F .chump-locks/ambient.jsonl \
  | grep --line-buffered -E '"kind":"(pr_merged|pr_stuck|fleet_wedge|silent_agent|gap_ship_confirmed|lease_overlap|operator_dm)"'
```
The Monitor fires an event notification the moment a relevant ambient line lands.
You handle it, then re-arm ScheduleWakeup for the fallback window.

**ScheduleWakeup fallback** — call at the end of every wake, with:
- `delaySeconds`: 1200–1800 (cache-aware; stay above the 5-min cache-TTL boundary)
- `prompt`: the full `/loop` prompt verbatim so the next firing re-enters the skill
- `reason`: one sentence on what you're waiting for

This means the loop wakes on events (fast) with a 20–30 min safety heartbeat if
no events fire. Total wakes ≈ 6/day in a quiet session vs. 96/day at 15m cron.

**Migration for existing cron sessions:**
```bash
bash scripts/coord/opus-shepherd-migrate-to-event-driven.sh
```
Detects the current cron job, deletes it via CronDelete, then prints the
Monitor + ScheduleWakeup stanza to paste into the running session.

## Stop conditions and how to handle them

Exit loop and report to operator on any of:

1. **Operator pings session inbox** — they need attention; bail out cleanly.
2. **3 consecutive back-off triggers** — fleet is wedged; pausing prevents
   pile-on. `graphql_exhausted` excluded (it's a known misfire detector).
3. **CI fail rate >25% over last 8 PRs you authored** — your dispatch quality
   has degraded; pause and inspect.
4. **Pickable queue exhausts** — no safe xs/s gaps remain; signal operator
   for fresh wizard dispatches or move to pillar-fill mode.

Halt sequence:
```bash
# 1. Delete cron
# 2. Send operator a2a WARN with halt reason + last-N tally
# 3. End session with summary; preserve any in-flight PRs (don't close)
```

## Session retrospective discipline

End every shepherd session by writing one ambient event:

```bash
chump-coord emit DONE \
    session=<your-id> \
    ships=<count> \
    ghost_reconciles=<count> \
    gaps_filed=<count> \
    duration_min=<wall-clock>
```

So the next session inherits the trajectory data.

## See also

- [`SUBAGENT_DISPATCH.md`](./SUBAGENT_DISPATCH.md) — per-gap dispatch hygiene + shipping epilogue
- [`OPERATOR_PLAYBOOK.md`](./OPERATOR_PLAYBOOK.md) — operator-side runbook (META-089)
- [`CLAUDE_GOTCHAS.md`](./CLAUDE_GOTCHAS.md) — gotcha catalog
- [`OPUS_MESSAGE_PROTOCOL.md`](./OPUS_MESSAGE_PROTOCOL.md) — a2a messaging spec
- [META-091](../gaps/META-091.yaml) — session-start triage
- [META-092](../gaps/META-092.yaml) — predictive digest
- [META-093](../gaps/META-093.yaml) — parallel sub-fleet dispatch
- [META-094](../gaps/META-094.yaml) — this playbook
- [INFRA-1909](../gaps/INFRA-1909.yaml) — ghost-gap reaper daemon
- [INFRA-1911](../gaps/INFRA-1911.yaml) — stale closed_pr audit
- [`COLLISION_RCA_2026-05-24.md`](./COLLISION_RCA_2026-05-24.md) — claim-collision RCA + 2 protocol changes (CLAIMING handshake + PR-dedup-by-gap-id) — **MANDATORY first read on session start** (META-105)
