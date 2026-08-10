# Duty Officer — the standing owner of fleet health (RESILIENT-274)

> **Status:** Design v1 — pre-build review surface.
> **Filed:** 2026-08-09, from a session where every incident needed the operator to notice and route.
> **Outcome:** CHUMPOS (hands-off) + the RUN-the-business owner for customer-0, productized per-business for COTG.
> **Pairs with:** [RFC-ship-gate-consensus.md](../rfcs/RFC-ship-gate-consensus.md) (the ship-decision gate), [CI_VERIFIED_AGGREGATOR.md](CI_VERIFIED_AGGREGATOR.md) (the CI-technical gate), `.claude/agents/curator-opus-incident-commander.md` (the role, today inert).

## 1. Problem

ChumpOS already has the parts of an incident-response system and never wired them into a standing owner:

- **~7 playbook docs** (`docs/process/`: OPERATOR_PLAYBOOK, OPERATOR_RUNBOOK, OPUS_SHEPHERD_PLAYBOOK, SHEPHERD_LOOP_PLAYBOOK, SHIP_ASSIST_PLAYBOOK, REALITY_CHECK, ROLLBACK_RUNBOOK).
- **An incident-commander role** (`.claude/agents/curator-opus-incident-commander.md`).
- **A consensus/deliberation machine** (`crates/chump-coord/src/consensus.rs`, `.claude/agents/deliberator.md`).

All of it is **inert**: docs a human reads, a role definition, a machine never aimed at anything. Detectors fire into `ambient.jsonl` and then wait for the operator to notice. **The operator is the incident-response single point of failure.**

The evidence base is a single 2026-08-09 session where *every* incident needed the operator to notice and route:

| incident | what it needed | who did it |
|---|---|---|
| shared cargo-target bloated to ~150 GB → disk wedge | detect over-cap, quiesce builds, prune | operator noticed by looking |
| `run-fleet` gh-probe aborted the whole launch on one transient blip | retry + honor force-launch | operator |
| integrator aborted the whole batch on the first merge conflict | skip the conflict, ship the rest | operator |
| a CI parity break blocked **every** PR for hours | allowlist the unmirrored gate | operator, after PRs piled up |
| escalation "paged the operator" into a dead webhook | wire the send path | operator found out by looking |
| the disk GC ran every 30 min doing nothing while reporting "nothing to clean" | fix the PATH; make it honest | operator |

None was a hard fix. Each sat because **nobody was on duty.**

## 2. The three tiers

Response is a deliberate **mix, routed by how deterministic the fix is.** Not everything is code; not everything is judgment.

| Tier | What | Who acts | Latency | Coverage |
|---|---|---|---|---|
| **T1 — executable auto-heal** | deterministic, known fix fires automatically | code / a daemon (no agent, no operator) | seconds | narrow (anticipated failures) |
| **T2 — agent-run runbook** | known-shape incident that needs diagnosis | a duty-officer agent runs REALITY_CHECK first, then the matching playbook | minutes | medium |
| **T3 — escalate** | genuinely novel or halt-class | page the operator over Discord | human-speed | the rare tail |

- **T1** is the fastest and most reliable and covers the least. Examples that exist: the RESILIENT-273 disk self-heal, the ZERO-WASTE-053/054 cargo GC, the RESILIENT-264 launcher retry. Each is a durable fix that fires without anyone watching.
- **T2** is where the 7 playbook docs finally get *run* — by an agent, not read by a human. **REALITY_CHECK runs first, always** (`scripts/dev/reality-check.sh`): a detector firing is a SIGNAL, not an OUTCOME, and half of today's near-misses were confident false assertions. The agent verifies the outcome the belief would cause against ground truth before acting.
- **T3** is the last resort, not the first response. Today paging *was* the first (and only) response — that is the bug.

## 3. The playbook registry — signal → tier → action

The load-bearing artifact. A single machine-readable registry maps every known health **signal** to its **tier** and **action**. This is what turns "we have playbooks" into "the playbooks run."

**Shipped (slice 1 + slice 2 skeleton):** [`docs/process/PLAYBOOK_REGISTRY.yaml`](../process/PLAYBOOK_REGISTRY.yaml) is the real registry (13 signals across all 3 tiers, seeded from this session's evidence table in §1) and [`scripts/coord/duty-officer-loop.sh`](../../scripts/coord/duty-officer-loop.sh) is the standing-loop skeleton that reads it — `tick` scans recent ambient signals, `route <signal>` routes one signal T1→T2→T3, `heartbeat` proves liveness. T1 routes to the real auto-heal scripts (e.g. `disk-critical-reactor.sh`); T2 runs the reality-check gate before confirming a signal is real; T3 pages through the existing quiet gate (`scripts/coord/operator-escalation-registry.txt`) — never a second escalation path. Smoke-tested in `scripts/ci/test-duty-officer-loop.sh`.

```yaml
# docs/process/PLAYBOOK_REGISTRY.yaml (proposed)
- signal: disk_critical                      # ambient kind OR a derived metric
  detect: "free_gb < 20 AND shared_target_gb > cap"
  tier: 1
  action: scripts/coord/disk-critical-reactor.sh   # the RESILIENT-273 self-heal
  verify: "df shows free_gb recovered"             # the outcome, not the run
  false_positive_class: none

- signal: pr_pipeline_wedged
  detect: "0 merges in 2h AND >3 PRs armed-but-blocked"
  tier: 2
  runbook: docs/process/SHIP_ASSIST_PLAYBOOK.md
  reality_check: "git log origin/main --since=2h  # is anything merging?"
  action: "diagnose the blocking check; if a gate is unmirrored/phantom, fix at source"

- signal: farmer_auth_dead
  detect: "ambient kind=farmer_auth_dead"
  tier: 3? NO —
  false_positive_class: "known #1 false-positive (CREDIBLE-090); mis-called 4x"
  action: SUPPRESS — ship-check first (git log --since=1h); never escalate on this alone
```

Rules the registry encodes:
1. **Every signal declares its false-positive class.** A signal known to cry wolf (farmer_auth_dead) is suppressed or gated behind a ground-truth check, never escalated raw. This is the CREDIBLE-271 discipline: a gate that cries wolf is worse than none.
2. **Every T1/T2 action declares a `verify`** — the *outcome* to confirm, not the fact that the action ran. `exit 0 ≠ fixed`.
3. **New auto-heals register here** as they're built, so coverage is visible and the tail of un-owned signals is a queryable list, not a surprise.

## 4. The duty-officer contract — a standing loop, not a doc

```
loop every N seconds (or on ambient event):
  1. read health signals: ambient.jsonl kinds, ship-rate (git log --since=1h),
     disk free, auth validity (auth-status.sh), fleet_wedge/silent_agent/pr_stuck
  2. for each firing signal:
       look up registry entry
       if false_positive_class != none: run its ground-truth check; REFUTED -> drop
       route by tier:
         T1 -> run action; confirm `verify`; log outcome
         T2 -> spawn/act an agent-runbook (REALITY_CHECK first); confirm `verify`
         T3 -> escalate over Discord (section 5), ONLY if novel or halt-class
  3. emit a periodic heartbeat + a daily scoreboard (admin-merge count, incidents
     handled by tier, escalations to operator) — the FLEET-RADIO surface
```

Invariants:
- **Pages the operator only at T3.** If admin-merge count or operator-escalation count is not trending toward zero, the duty officer is failing its own SLO.
- **Never acts on an unverified belief** (REALITY_CHECK / ship-check-first is not optional).
- **No band-aids** (DURABLE_FIX_DOCTRINE): a T1/T2 action fixes the cause or files a gap for the real fix + emits an audit signal; it never hides breakage.
- **Its own liveness is a health check.** The reason today's escalation failed silently is nobody checked the notifier was alive. The duty officer verifies its notify channel on startup (section 5).

## 5. Delivery — over the same wiring that serves user-1

Escalation and the health radio ride the **one Discord substrate** a business customer also gets — never a bespoke internal path (dogfood: what serves customer-0 must be what serves user-1).

- **SEND: works today** — `src/discord_dm.rs` (`send_dm_if_configured`) + `scripts/coord/lib/notify-operator.sh` (bash+curl, no bot), keyed on `DISCORD_TOKEN` + `CHUMP_READY_DM_USER_ID` (present, proven by real delivery). T3 escalation POSTs here.
- **RECEIVE / approve-deny: RESILIENT-266** — the gateway (compiled out, being wired) → RESILIENT-265 (approve/deny buttons) → RESILIENT-262 (retry-vs-escalate triage). Until that lands, the duty officer can *tell* the operator but not yet take a *reply*; escalations are informational.
- **"Is my notify channel live?" is a startup health check** — a great router into a dead channel is still silence.

## 6. Composition with the ship gate

The duty officer and the ship gate are the same governance system at two moments:

- The **ship gate** (RFC-ship-gate-consensus + the `verified` aggregator) decides *before a PR merges*: is it technically green (verified aggregator) AND are its claims true (claim-verification consensus)?
- The **duty officer** watches *after*, in production: did an incident fire, and can it be auto-healed / runbook'd / must it escalate?

They share the registry format (signal → decision) and the REALITY_CHECK discipline (verify the outcome, never trust the receipt). Build them to share code, not to compete.

## 7. Per-business instantiation (the product)

For **customer-0** (ChumpOS itself) the duty officer runs continuously and owns fleet health. For **any business** (the COTG product) it is the same role instantiated per-customer: the business gets an always-on operations owner + its own registry (generic playbooks like disk/deploy/ship, plus business-specific ones). "Your business gets an ops owner that never sleeps" is the RUN half of the org chart — and it is the same artifact, parameterized by the registry.

## 8. Build slices

1. **[s] Registry format + the first entries** — `PLAYBOOK_REGISTRY.yaml` with the 6 incidents from §1 (the ones we already fixed become T1 entries with `verify`; the false-positives get their class). No behavior yet; just the machine-readable map.
2. **[m] The standing loop skeleton** — a daemon that reads the registry + ambient, routes T1 (run action, confirm verify), and emits a heartbeat. T2/T3 stubbed to "log + would-escalate."
3. **[m] Wire T3 over Discord** — escalation via notify-operator.sh + the startup notify-channel health check. (SEND only until RESILIENT-266 lands the receive half.)
4. **[m] T2 agent-runbooks** — REALITY_CHECK-first execution of the top recurring runbook (pipeline-wedged / ship-assist), one worked example end-to-end.
5. **[s] Scoreboard** — admin-merge count, incidents-by-tier, escalations; the FLEET-RADIO daily surface (ties to CREDIBLE-272 in SHIP-INFRA).

Do not build the whole thing at once. Slice 1 (the registry) is the keystone: it makes the un-owned tail visible and gives every future auto-heal a home.
