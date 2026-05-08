# Operator-Agent (INFRA-737)

> A Sonnet-class agent running continuously on the operator's behalf:
> diagnoses fleet failures, sequences ships, balances the four pillars,
> posts handoff comments, files follow-up gaps, and escalates to Opus
> only when a human-judgment call is genuinely needed. Today's
> "operator session" pattern, productized.

## Provenance

This document captures the design after a full afternoon (2026-05-08)
in which an Opus operator-agent did exactly this work manually:

- Diagnosed PR #1349's CI failure, posted structured handoff comment.
- Sequenced 6 PRs in velocity-unlock order (flake-fix → alert
  rescope → push gate → commit advisory → flake harness → strict
  replay).
- Balanced pillar mix in 8 filed gaps (6 RESILIENT, 2 CREDIBLE, 1
  EFFECTIVE).
- Captured an end-of-day failure analysis and filed 4 follow-up
  gaps (INFRA-777/778/779/780) rather than paper over what didn't work.
- Wrote the State of the Union addendum and roadmap update.

The full session is a **runnable spec** for what the operator-agent
should do autonomously. This document codifies the contract so a
Sonnet (or stronger free-tier) can carry it without Opus in-loop.

## Mission alignment

| Pillar | Why this is on-mission |
|---|---|
| **EFFECTIVE** | Eliminates operator-interruption tax for everything except true human-judgment calls. Measurable in `% sessions where Opus had to decide` (target: <20% within a quarter of shipping). |
| **CREDIBLE** | Every operator-agent action is a structured ambient event; full audit trail. Replayable post-hoc; "what did the agent decide and why" is queryable. |
| **RESILIENT** | Cap on aggressive actions (cost cap, refused-tools list, escalation cap) prevents runaway. Watchdog timer — no decision in 24h surfaces "agent stalled." |
| **ZERO-WASTE** | Routes free-tier providers (Groq) for diagnostic work; routes Anthropic only for tasks that genuinely need it. Cost-per-shipped-PR drops sharply once routing is right. |

## What the operator-agent does

### Core loop (every 5 minutes when active)

1. **Pillar inventory.** Run `chump gap list --status open` and count
   pickable gaps per pillar (xs/s/m, no deps, P0/P1, INFRA domain).
   If any pillar < 2 pickable, file 1–2 gaps to refill from the
   roadmap-derived backlog.
2. **Queue health.** `gh pr list --state open` for stalls (DIRTY > 2h,
   FAILING with same error twice, etc). Classify each stall:
   - **Real bug** → diagnose, post handoff comment per
     [Review-as-Handoff](./REVIEW_AS_HANDOFF.md).
   - **Known flake** → if catalogued in `KNOWN_FLAKES.yaml`, trigger
     CI rerun via `gh run rerun --failed`. Emit
     `kind=flake_autorerun_initiated`.
   - **Unknown flake** → file a tracking gap (not yet INFRA-* gap;
     emit `kind=unclassified_failure_filed` with the test name).
3. **Stack maintenance.** When a base PR merges, auto-rebase any
   stacked dependents (per INFRA-765). Force-push with `--force-with-lease`.
4. **Brief surface.** If `fleet-brief` shows ship rate has dropped
   >30% in the last 4h, escalate `kind=ship_rate_drop` to operator
   (Slack ping or whatever paging is configured).
5. **Sleep 5 min, repeat.**

### Periodic responsibilities (every 4 hours)

- **Mission balance audit.** Re-run pillar count; if one pillar > 50%
  of pool, demote some to P2.
- **Gap registry health** (per META-046). Run `chump gap audit-priorities`
  and act on its diagnostics.
- **State drift sweep.** Run `gap-doctor safe-sweep` (per CREDIBLE-012's
  rescope, this is now low-noise). Investigate any new drift event
  before the alert is overwritten.

### End-of-day routine

- Write a short State-of-the-Cycle entry (1–2 paragraphs) appended to
  the day's `STATE_OF_UNION_*.md` file. Not a full report — a "what
  shipped, what's queued, what surfaced" summary.
- Post the entry as a comment on the most recent operator-thread issue
  if one exists.

## What the operator-agent does NOT do

- **Take irreversible actions on operator's behalf** without explicit
  approval: deletions, force-pushes to main, rate-limit-budget overrides
  on the cascade.
- **Generate roadmaps or strategy documents.** Strategic narrative is
  Opus + operator. The operator-agent updates structural docs (state
  of union addenda, fleet-brief snapshots) but does not author new
  strategic direction.
- **Pick gaps requiring research integrity** (EVAL-* / RESEARCH-*
  preregistration). These need human judgment per
  `docs/RESEARCH_INTEGRITY.md`.
- **Approve sensitive PRs.** Anything touching auth, security, payment
  flows, or `proprietary/` references requires human approval before
  merge.
- **Decide pillar mix at the strategic level.** It can refill within
  an existing thrust, but it does not redirect quarterly priorities.

## Safety knobs (mandatory before activation)

These are non-optional. Without them, INFRA-737 ships disabled.

### Cost cap

- `CHUMP_OPERATOR_COST_DAILY_USD` — hard cap on Anthropic spend per
  rolling 24h. Default $5. When breached, operator-agent halts new
  Anthropic-routed actions and emits
  `kind=operator_cost_cap_breached`. Free-tier (Groq, Cerebras) work
  continues uninterrupted.
- The cap is a **hard halt**, not a warning. Operator manually resets
  via `chump operator --reset-cost-cap`. This prevents runaway billing
  if a model loop misbehaves.

### Audit log

Every operator-agent action emits a structured ambient event with:

- `ts`, `session_id`, `agent=operator`
- `kind` from a closed set: `operator_pr_diagnosed`,
  `operator_handoff_posted`, `operator_gap_filed`, `operator_pr_rebased`,
  `operator_flake_rerun_triggered`, `operator_escalated`,
  `operator_cost_cap_breached`, `operator_session_idle`,
  `operator_action_refused`.
- A hash of the prompt and the model output (for forensics, not
  reproduction).
- The decision rationale in a `rationale` field (1 sentence).

The log is append-only and rotated weekly. Operator can `chump operator
--audit --since 24h` to see every action.

### Refused tools

The operator-agent has a **deny-list** of tools it cannot invoke:

- `git push --force` to `main` or any protected branch
- `gh pr merge` without `--auto` (must wait for CI gate)
- `chump gap delete` (deletion of any gap, ever — flips status to
  `superseded` instead, preserving audit trail)
- `rm -rf` of any path under `~/Projects/` or `/tmp/chump-*`
- Any HTTP POST to an external API not on a documented allowlist
- Any modification to `~/.env`, `~/.zshrc`, `~/.bashrc`, or `~/.config/`

Attempted use emits `kind=operator_action_refused` and the action is
silently no-op'd. Operator reviews these via the audit log.

### Escalation cap

- `CHUMP_OPERATOR_ESCALATIONS_DAILY` — max times the operator-agent
  can ping the human operator (Slack/email) per day. Default 3.
- Beyond the cap, the agent files a gap describing what would have been
  escalated and continues. This prevents notification spam during
  cascading failures.

### Watchdog timer

If the operator-agent goes 24h without any ambient event emit, an
external watchdog (running as a systemd / launchd service, NOT inside
the agent itself) emits `kind=operator_stalled` and pings the human.

## Architecture

### Run mode

`chump operator --serve` — long-running daemon, one instance per
operator. Same shell shape as `chump review --serve` (INFRA-772).

### Model routing

- **Diagnosis + simple-handoff** (most calls): cascade-routed to free-tier
  Groq Llama 3.3 70B by default. Cost ~ $0.
- **Complex sequencing / pillar-balance / gap drafting**: Sonnet 4.5.
  Operator's `CHUMP_OPERATOR_COST_DAILY_USD` cap governs.
- **Genuine human-judgment calls**: NEVER routed to a model.
  Surfaces to the human via the escalation channel.

The router uses a small classification prompt at the front of each
loop tick to decide which pool to draw from. Same pattern as the
existing `chump_bypass_*` switches — env-overridable, default
conservative.

### State

- **Read** from `.chump/state.db`, `.chump-locks/ambient.jsonl`, the
  gap registry, `gh pr list`, `git log`.
- **Write** to `.chump-locks/ambient.jsonl` (audit log), and to
  `.chump/state.db` via the existing `chump gap` CLI.
- **Never write directly to repos other than via documented commit/PR
  flow.** All code changes go through the same `gap-claim.sh →
  worktree → commit → bot-merge.sh` pipeline as any agent. The
  operator-agent is a coordinator, not a special privileged actor.

### Telemetry consumers

- `fleet-brief` surfaces "operator-agent: N actions today, $X spend,
  M escalations".
- `kpi-report` exposes `(operator_pr_diagnosed) / (PR_failures)` —
  diagnosis coverage rate.
- `waste-tally` exposes
  `(operator_action_refused + operator_cost_cap_breached) / (operator_*)` —
  the "tried-to-overstep" ratio. Target south of 5%.
- A new dashboard view: `chump operator --report` shows the audit log
  with grouping by kind.

## Build sequencing

INFRA-737 decomposes into:

1. **Operator session shell** (m): `chump operator --serve` boilerplate,
   PID file, systemd/launchd templates, audit-log writer, the cost-cap
   + refused-tools + escalation-cap implementation.
2. **Diagnose-and-handoff sub-loop** (m): consumes
   `kind=pr_check_fail` events, calls `chump review` (INFRA-772) for
   the handoff comment, watches for the next push.
3. **Pillar-balance sub-loop** (s): runs `chump gap audit-priorities`
   + counts; files 1–2 gaps per pillar from a roadmap-derived
   suggestion list.
4. **Stack-maintenance sub-loop** (s): consumes `gh pr merge`
   notifications; for stacked dependents, runs INFRA-765's
   auto-rebase.
5. **Watchdog daemon** (xs): the external agent-stall detector.
6. **Audit log + dashboard** (s): `chump operator --audit / --report`
   subcommands; the new ambient kinds registered per INFRA-754.
7. **End-to-end smoke test** (s): synthesize a CI failure + a PR
   stalling, verify the operator-agent diagnoses, posts handoff,
   re-runs a known flake, files a gap, and respects the cost cap.

Total: ~1 week of fleet shipping once the dependency chain is clear.

## Dependencies

This gap CANNOT ship before:

- **INFRA-768** (Review-as-Handoff design) — MERGED today.
- **INFRA-769–774** (Review-as-Handoff sub-gaps) — open, fleet pickup.
- **INFRA-754** (event registry) — MERGED today.
- **INFRA-761** (cargo-test gate) — auto-merge armed today.
- **INFRA-764** (flake-catalog auto-rerun) — auto-merge armed today.

It SHOULD ship before:

- Q4 2026 quarterly review.
- Any hiring round (the operator-agent should be running stably first
  so the team can scale around verified leverage rather than
  hand-wave).

## Open design questions

- **Voice / authority.** Should the operator-agent post comments under
  the operator's GitHub username (current convention) or under a
  distinct `chump-operator-agent[bot]` account? Bot accounts are
  cleaner for audit but require GitHub App setup. Defer to operator.
- **Multi-machine.** A single operator-agent per operator, or one per
  machine in the fleet? Single is simpler. Multi requires a leader-elect
  protocol — defer until a fleet member needs it.
- **Cost cap reset cadence.** Hard daily cap (UTC midnight)? Rolling
  24h? Operator preference; default rolling 24h.
- **Escalation channel.** Slack? Discord? Both already configured for
  the bot — defer specific routing to the operator.

## What this document does NOT cover

- The reviewer-role daemon (`chump review --serve`) — see INFRA-772 +
  REVIEW_AS_HANDOFF.md.
- The author-agent re-engagement loop — see INFRA-771 +
  REVIEW_AS_HANDOFF.md §5.
- The flake-catalog harness — see INFRA-764, shipped today.

These are independent components the operator-agent USES. The
operator-agent is the conductor; they're the instruments.

— Opus design pass, 2026-05-08 evening
