# Productization Plan — 2026-05-22

**Status:** active. Sub-gaps filed. Sprint window: ~2 weeks.
**Tracking gap:** [META-068](../gaps/META-068.yaml).
**Provenance:** captured from operator real-talk exchange on 2026-05-22. The diagnosis below is the canonical record so future sessions surface it via `memory/MEMORY.md` and can pick up where this conversation left off.

---

## Why this doc exists

The operator has spent weeks trying to give chump agents real autonomy. The dream is agents that run forever, develop personality, work as a coordinated fleet. The current reality is high-precision *operator-with-agent* collaboration, not autonomous *agent-with-agent* ballet.

This doc captures the honest diagnosis of what's actually blocking the autonomy dream, the prioritized path forward, and the disambiguation between what chump-side engineering can fix and what is gated on model state.

---

## The diagnosis: three distinct problems

### Problem 1 — Quality vs. CI: a local-vs-remote gating gap

**Symptom (concrete from 2026-05-22 session):** Three of one operator's PRs hit the event-registry orphan-event audit *after push* (#2348, #2355, #2359). Plus the `grep --force-duplicate` flag-parsing bug on #2358. Plus the format-lint failure on #2351. Plus the env-var rename test failure on #2355's stitched fix.

Every one was deterministically catchable locally. Every one cost a 5-10 minute CI round-trip instead of a 5-second local failure. The autonomy loop bleeds on these.

**Diagnosis:** Every CI gate without a `chump preflight` mirror is a tax on the autonomy loop. We currently have ~15 CI gates and ~4 preflight gates. That delta IS the failure budget; every gate we leave un-mirrored compounds.

**This is the most fixable problem.** It is not a research problem. It is an audit-and-mirror exercise. INFRA-1731 (registry audit, in flight as PR #2377 at the time of this writing) is the first deliberate move. There are 6-8 more obvious follow-ups.

### Problem 2 — Harmony vs. don't-crash: a structural shift from defensive to proactive coordination

**The gap store + lease system solves *negative* coordination** — agents don't stomp on each other's files, two sessions can't claim the same gap, the hot-file overlap check prevents the obvious collisions. This is necessary but not sufficient.

What the operator called "ballet" or "music" is **positive coordination** — agents that help each other on purpose. The substrate exists:

- `ambient.jsonl` is a real-time bus (extracted as `chump-ambient-cli` via EFFECTIVE-023 this session)
- `state.db` has `routing_outcomes` with historical (task_class × backend × model × outcome) data
- The gap dependency graph is queryable

What's missing is anything that *uses* that substrate for forward-looking coordination:

- **Predictive collision** at claim time → INFRA-1763
- **Skill-aware routing** via `routing_outcomes` at picker time → INFRA-1764
- **Cross-agent lesson propagation** via `memory_db` → INFRA-1765

This is the productization layer under the hood. The two architectural blueprints the operator critiqued today (the Blackboard pipeline and the Pillar-Based Custodian) both gesture at this layer. Most of the substrate work is in the 16 gaps filed earlier in this session. The **router** — the conductor — is what the three Initiative 2 gaps build.

### Problem 3 — Consumer-quality output: CI green ≠ user-acceptable

Today PRs ship to main on auto-merge with CI green; nobody asks whether the change *demonstrates* the user-facing behavior it claims. A PR that adds `chump foo --bar` can land without anyone showing that `chump foo --bar` produces the expected output. This is a problem for any move toward consumer-grade output.

**This is the lowest-priority of the three (P2)** because chump is dogfood-first and the immediate damage is small. But it is the gate we'll need before shipping anything end-user-facing.

---

## The AGI-dream disambiguation (read this when frustrated)

The operator's real goal is agents that run forever with persistent personality — the AGI-dream.

**What's NOT blocked by chump-side engineering:**

- Continuous personality/taste/habits across sessions. Today every session, every subagent invocation, every gap pickup starts from the same system prompt + briefing. The model (Claude) doesn't have persistent self-state. Even infinite chump plumbing doesn't fix that.

**What IS blocked by chump-side engineering and worth doing:**

- **Persistent operator memory** (already exists via `memory/MEMORY.md` and feedback-file pattern) — the accumulated taste *is* the personality, written as instructions.
- **Per-bot persistent state slices** — each content bot has its own `docs/agents/content-bots/<name>.md`; further pillar-bots get their own.
- **`routing_outcomes` as taste-memory** — querying past outcomes at routing time is behavior shaped by past sessions; Initiative 2 makes this load-bearing instead of dormant.

**The hard part — fine-tuning a model on chump's own data** (4-8 week path per `memory/project_model_strategy.md`) — is the actual AGI-dream move. It happens *outside* the gap fleet because the gap fleet itself is constrained by the underlying model.

**Honest summary:** The agents you have are very competent journeymen with a great shared memory file. Make them sing in chorus and that's a lot.

---

## Initiative breakdown

### Initiative 1 — Quality firewall (every CI gate has a local preflight equivalent)

| Gap | Status | What it does |
|---|---|---|
| [INFRA-1731](../gaps/INFRA-1731.yaml) | **in flight** (PR #2377) | event-registry-audit gate in `chump preflight` |
| [INFRA-1762](../gaps/INFRA-1762.yaml) | open, P1 | umbrella: audit every CI gate, file per-gate gaps, ship `docs/process/CI_GATES_INVENTORY.md` |
| [INFRA-1730](../gaps/INFRA-1730.yaml) | open, P1 | `chump claim` auto-handles orphan branches from closed PRs |
| [INFRA-1732](../gaps/INFRA-1732.yaml) | open, P1 | `bot-merge.sh` emits phase-progress heartbeat events for stall detection |

**Plus** the per-gate follow-ups that fall out of INFRA-1762's audit (filed as that gap ships).

**Why this first:** mechanical, deterministic, high-ROI. Each merged Initiative-1 gap shaves real time off every future PR. Closes the rework loop that limits agent autonomy.

### Initiative 2 — Forward-looking fleet coordination (the conductor)

| Gap | Status | What it does |
|---|---|---|
| [INFRA-1763](../gaps/INFRA-1763.yaml) | open, P1 | lease-time predictive collision detection (git-diff intersection across active leases) |
| [INFRA-1764](../gaps/INFRA-1764.yaml) | open, P1 | skill-aware routing via `routing_outcomes` at claim time |
| [INFRA-1765](../gaps/INFRA-1765.yaml) | open, P1 | cross-agent lesson propagation (CI failure patterns → `memory_db` → next session briefing) |

**Why this second:** the substrate is already in place from earlier work this session. These three gaps wire the substrate into actual behavior. After they land, the fleet stops doing the same dumb thing twice; that's where harmony starts.

INFRA-1765 (lesson propagation) is the highest-leverage gap in Initiative 2 — it directly closes the rework loop that Initiative 1 also addresses but from a different angle.

### Initiative 3 — Consumer-quality gate

| Gap | Status | What it does |
|---|---|---|
| [INFRA-1766](../gaps/INFRA-1766.yaml) | open, P2 | `chump pr ux-review` step gates user-facing surface changes on brief-existence + demo block |

**Why this third:** chump is dogfood-first, so the immediate damage is small. But shipping anything end-user-facing requires this gate. Tracked for completeness; promote priority when first customer-facing surface enters scope.

---

## Related substrate (already filed earlier this session)

These 16 gaps from earlier in the 2026-05-22 session are the *substrate* on which Initiatives 1–3 build. They are filed but not blocking the Initiative 1 fast-path:

**Audit-driven critiques (Blackboard + Pillar):**
- [INFRA-1719](../gaps/INFRA-1719.yaml) — tree-sitter AST pre-step in `chump gap decompose`
- [INFRA-1720](../gaps/INFRA-1720.yaml) — typed HandoffContract for subagent dispatch
- [INFRA-1721](../gaps/INFRA-1721.yaml) — `CAPABILITIES_REGISTRY.json` per repo
- [INFRA-1722](../gaps/INFRA-1722.yaml) — auto-generate `ARCHITECTURE.md` per repo
- [INFRA-1723](../gaps/INFRA-1723.yaml) — empirical push-routing scale test past 30 workers
- [INFRA-1724](../gaps/INFRA-1724.yaml) — generalize Content Bots Suite pipeline
- [INFRA-1725](../gaps/INFRA-1725.yaml) — enforce index-only reads for subagents
- [INFRA-1734](../gaps/INFRA-1734.yaml) — `PILLARS.md` generator
- [INFRA-1735](../gaps/INFRA-1735.yaml) — `PRIMITIVES_REGISTRY.json`
- [INFRA-1736](../gaps/INFRA-1736.yaml) — voice-guardrail pre-commit lint

**Observed failure patterns:**
- [INFRA-1733](../gaps/INFRA-1733.yaml) — `chump claim` symlinks `github_cache.db` into worktree
- [INFRA-1737](../gaps/INFRA-1737.yaml) — loop-stop sentinel for clean operator-cancel

**Ordnance Engine backlog (P3):**
- [INFRA-1738](../gaps/INFRA-1738.yaml) — webhook mirror for Linear/Stripe/Notion/Slack
- [INFRA-1739](../gaps/INFRA-1739.yaml) — provider cascade re-aim for non-LLM resources
- [INFRA-1740](../gaps/INFRA-1740.yaml) — adversary as continuous resilience drill

---

## How to come back to this

When you re-enter this thread (days / weeks / months from now), the entry point is:

1. **Read this file top-to-bottom.** The diagnosis section is the operator's actual frustration captured verbatim. Don't lose that thread.
2. **`chump gap show META-068`** for the current status of the umbrella.
3. **`chump gap show INFRA-1762`** for the CI/preflight delta status (Initiative 1 progress).
4. **`chump gap list --status open --json | jq '.[] | select(.depends_on // [] | contains(["META-068"])) | .id'`** to find any sub-gap not yet listed here that was added later.
5. **Pillar coverage check at session start** still matters — if EFFECTIVE is over-served (it was at 89 at the start of this exchange), promote pillar-balance over Initiative-1 mechanical work.

**The single hardest-to-replicate fact:** the operator's autonomy dream is gated on model fine-tuning, not on more gaps. If you find yourself filing chump-side gap #50 in pursuit of "autonomy," re-read the AGI-dream-disambiguation section and ask whether the work is actually moving that needle, or just moving the substrate around.

---

## Operator-return-to notes (open questions)

- **Who claims INFRA-1762 (the umbrella audit)?** Likely the operator manually, since auditing CI workflow files is judgement-heavy. Could decompose to a sub-batch a Sonnet worker handles.
- **When do we flip `CHUMP_SKILL_ROUTER_ENABLED=1`?** INFRA-1764 ships with default 0; we need ~100 decisions logged before validation. Probably 1-2 weeks of normal fleet activity.
- **What's the threshold for promoting INFRA-1766 from P2 to P1?** Likely: first customer-facing demo PR (June 6 demo deliverable per current `docs/ROADMAP.md`).
- **Personality fine-tune scope:** not in this plan. Tracked separately per `memory/project_model_strategy.md`. Revisit after Initiatives 1–3 land.

---

## Provenance trail

- Real-talk exchange: 2026-05-22 session, Opus 4.7 instance, Claude Code harness.
- Operator: jeffadkins1@gmail.com.
- Earlier same-session: 4 PRs merged (#2355 EFFECTIVE-023 ambient-cli extract, #2357 INFRA-1428 gap reserve fix, #2359 CREDIBLE-068 merge queue health, #2366 INFRA-1705 auto-prune-on-merge), 22 gaps filed across two architectural critiques, 3 PR shepherd comments posted on sibling sessions' open PRs.
- Document author: same Opus session, written into a claimed worktree (`/tmp/chump-meta-068`), shipped via the standard bot-merge pipeline.
