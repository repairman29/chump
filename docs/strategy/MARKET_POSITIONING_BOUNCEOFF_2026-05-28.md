# Market Positioning Bounce-off — Cross-Reference Results

**Authored:** 2026-05-28 by curator-opus-overnight.
**Closes:** [INFRA-2083](../gaps/INFRA-2083.yaml).
**Companion to:** [`MARKET_POSITIONING_2026-05-27.md`](MARKET_POSITIONING_2026-05-27.md) (PR #2679 merged 2026-05-28T00:12:19Z).

The 7 cross-reference questions from the Market Positioning doc, answered against the actual gap registry + crate substrate audit.

---

## Q1 + Q2 — Gap IDs per Bet: what exists, what's missing

### Bet 1 — SWE-Autonomy Wrapper (`chump swe <prompt>`)

**Existing gaps that contribute:**
- INFRA-1486 (DONE) — per-gap budgets (wallclock, files, deps, $ cost). M-A trust gate. This is the budget primitive `chump swe` would expose.
- INFRA-1972 (DONE today) — parent-enforced subagent budget kill (SIGTERM+grace+SIGKILL).
- INFRA-1970 (DONE today) — lease primary key by gap-ID.
- INFRA-1819 (open, P2/xs) — `chump ast-shape <repo>` CLI; sibling pattern (operator-facing wrapper over crawl-cli).

**Missing — needs new gap:**
- **NEW** — `chump swe <prompt>` CLI subcommand wrapping the per-gap claim → /tmp worktree → bounded subagent dispatch → auto-merge ARMED pipeline as a one-shot SWE-agent product surface. Estimated P1/m. **File this.**

### Bet 2 — Cost-as-Control-Plane completion (token + dollar budgets)

**Existing gaps that contribute:**
- INFRA-1486 (DONE) — wall-clock + file-touch + dep-add + $ cost dimensions (M-A trust gate). $ cost dim exists but enforcement may be wall-clock-only in practice.
- INFRA-1972 (DONE today) — parent-enforced wall-clock kill (the template).
- INFRA-790 (open, P2/s) — Gemini thinking-token budget (specific to Gemini; narrower scope).
- INFRA-1805 (open, P2/xs) — capability-v2 with `token_budget_remaining` + `compute_available` + `healthy` fields.
- INFRA-1481 (open, P3/l) — Growth-tier governance bundle: RBAC + spend caps + repo access control.

**Missing — needs new gap:**
- **NEW** — extend INFRA-1972's `subagent_killed_at_budget` to also emit at `CHUMP_SUBAGENT_TOKEN_BUDGET` exceed and `CHUMP_SUBAGENT_DOLLAR_BUDGET` exceed; distinct event kinds (`subagent_killed_at_token_budget`, `subagent_killed_at_dollar_budget`). Estimated P1/s. **File this.**

### Bet 3 — Ambient stream index + cross-framework schema publication

**Existing gaps that contribute:**
- **INFRA-1973 (open, P2/m)** — ambient.jsonl unindexed append-only (my critique H4). This IS the index step.
- INFRA-2017 (open, P1/s) — role-card schema published to ambient on session-start.
- META-075 (open, P1/xs) — predictive collision detection event schema.
- META-077 (open, P1/xs) — skill-aware routing event schema.
- META-084 (open, P1/s) — observability smoke test command.

**Missing — needs new gap:**
- **NEW** — publish `chump-agent-events-v1` spec as a public schema document (`docs/specs/CHUMP_AGENT_EVENTS_V1.md`) for cross-framework adoption. The moat play. Estimated P1/s. **File after INFRA-1973 lands.**

### Bet 4 — State.db Postgres backend (Opportunity 1)

**Existing gaps that contribute:**
- **INFRA-1967 (open, P1/m)** — state.db is single-node SQLite via r2d2; can't scale across machines (my critique C4). This IS the gap; just needs Postgres-flavor sub-slice.
- INFRA-2053 (open, P1/m) — `chump gap sync` bidirectional YAML <-> state.db reconciliation (different concern — local-only consistency).

**Missing — needs new gap (or sub-slice of INFRA-1967):**
- **NEW** — Postgres backend behind `chump-gap-store` crate interface; same schema, swap storage. Sub-slice of INFRA-1967. Estimated P1/m for the smallest credible slice. **File as INFRA-1967 sub-gap.**

### Bet 5 — Local-LLM mission close + Multi-machine routing

**Existing gaps that contribute (SUBSTANTIAL):**
- **INFRA-1964 (open, P1/m)** — mission-reality gap on local-LLM, no MLX wired (my critique C1).
- **INFRA-1118 (open, P1/m)** — A2A Layer 1a NATS-primary delivery, file fallback secondary. **THE foundation gap.**
- **INFRA-1119 (open, P1/m)** — A2A Layer 2b RPC + 5 use-case wrappers.
- **INFRA-1120 (open, P1/m)** — A2A Layer 2c capability manifest + session discovery.
- **INFRA-1267 (open, P2/m)** — cross-machine integration test for NATS push routing (FLEET-034 AC#8).
- **INFRA-1319 (open, P2/l)** — GitHub Liaison Phase 3 — mutation routing via NATS request/reply.
- **INFRA-1323 (open, P1/m)** — local merge queue, NATS KV serialized git merge (offline mode).
- INFRA-1545 (open, P2/m) — statistical-routing layer (bandit-replay regret reporter).
- INFRA-1551 (open, P1/s) — cull dead routing_outcomes schema OR populate it.
- INFRA-1828 (open, P2/s) — 5 A2A RPC wrappers as bash over broadcast.sh.
- INFRA-1760 (open, P1/xs) — CapabilityManifest schema chump-capability-v1.
- PRODUCT-087 (open, P2/m) — PWA local-only onboarding wizard.
- META-038 (open, P2/l) — coord-tax collapse umbrella.

**Bet 5 has the richest existing gap coverage — most of the substrate is FILED but UNSHIPPED.** The integrating META gap would be useful but most slices already exist.

**Missing — needs new gap:**
- **NEW** — integrating META for Bet 5: enumerate the 13 substrate gaps above, sequence them, identify the hardware-decision blocker, define the "Bet 5 done test" (a two-node mesh demo with local Llama + claude-p mixed routing). Estimated P1/s. **File this.**

### Net new gaps to file (5 total):
1. **NEW-1** — `chump swe` CLI wrapper (Bet 1) — P1/m
2. **NEW-2** — subagent token/dollar budget extension (Bet 2) — P1/s
3. **NEW-3** — `chump-agent-events-v1` spec publication (Bet 3 follow-on) — P1/s
4. **NEW-4** — Postgres backend slice of INFRA-1967 (Bet 4) — P1/m
5. **NEW-5** — Bet 5 META integration umbrella — P1/s

---

## Q3 — Shipped substrate the Positioning doc undercredited

I leaned on today's session work in the Positioning doc. The substrate audit surfaces material I should have credited:

| Substrate | LOC | What's there | Bet impact |
|---|---|---|---|
| **`crates/chump-coord/`** | **4,368** | mesh.rs (282), rpc.rs (255), scratchpad.rs (295), work_board.rs (469), assign.rs, capability.rs, consensus.rs, events.rs, help_request.rs, lib.rs, main.rs, bin/ | **Bet 5 is 60-70% pre-built.** The mesh + rpc + capability + work_board primitives ARE the multi-machine routing layer. They're not WIRED into production yet (CHUMP_NATS_URL unset) but they exist as code. |
| **`crates/chump-messaging/`** | 1,315 | broker.rs, adapter.rs, error.rs, lib.rs | Bet 5 message-passing layer, partially shipped |
| **`crates/chump-agent-lease/`** | (audit pending) | Lease primitives | Bet 1 SWE-wrapper sandbox enforcement, partially built |
| **INFRA-1486 (M-A trust gate)** | DONE | Per-gap wall-clock + files + deps + $ cost budgets | Bet 1 + Bet 2 substrate; Marcus M-A milestone COMPLETE |
| **Architectural critique cascade today** | 11 shipped fixes | M3 + H3 + H8 + C6 + C5 + H7 + H1 + H2 + H5 + md-links + ci-audit productize | The SWE-autonomy primitives Bet 1 needs are ALL on main after today's ships |

**Key realization:** Chump is substantively further along than the Positioning doc claimed for Bet 5. The NATS+mesh+rpc code is there. The constraint is OPERATIONAL (NATS not deployed cross-machine) not architectural.

---

## Q4 — Filed-but-stale gaps to re-scope

The A2A / NATS / multi-machine substrate has gaps that have been OPEN for weeks-to-months. Likely candidates for re-scoping under the new Bet 5 META:

| Gap | Status | Age signal | Re-scope target |
|---|---|---|---|
| INFRA-1118 | open, P1/m | A2A Layer 1a NATS-primary; META-061 era (likely April 2026) | Roll under Bet 5 META |
| INFRA-1119 | open, P1/m | A2A Layer 2b RPC; same era | Roll under Bet 5 META |
| INFRA-1120 | open, P1/m | A2A Layer 2c capability manifest; same era | Roll under Bet 5 META |
| INFRA-1267 | open, P2/m | FLEET-034 cross-machine test | Roll under Bet 5 META |
| INFRA-1323 | open, P1/m | Local merge queue NATS-KV | Roll under Bet 5 META OR Bet 4 (related but distinct) |
| INFRA-1545 | open, P2/m | Statistical routing layer | Defer — not Bet 5 critical path |
| INFRA-1551 | open, P1/s | Cull dead routing schema OR populate | Decision needed: prune or fill |
| META-038 | open, P2/l | Coord-tax collapse umbrella | Possibly the right Bet 5 META holder; re-scope rather than create a new one |

**Recommendation:** rather than file NEW-5 from scratch, **re-scope META-038 as the Bet 5 integrating umbrella**. It already exists, it's UMBRELLA-typed, and its title ("coord-tax collapse") IS the Bet 5 thesis in different framing.

---

## Q5 — Mission Yield per Bet (rule of X)

Per `MISSION_YIELD.md`: `Mission Yield = (marcus + fleet_quality + dev_tool - reverts_7d) / (tokens_spent / 1M)`.

| Bet | Tag | Estimated Yield contribution | Estimated tokens (M) | Yield/M | Rank by Yield/M |
|---|---|---|---|---|---|
| **Bet 1** SWE wrapper | `dev-tool` | +1 (operator-visible CLI used daily) | 0.5–1.5M (UX wrapper + docs + demo) | **0.67–2.0** | **#1** |
| **Bet 2** Cost completion | `marcus` | +1 (extends M-A trust gate; Marcus's stated disqualifying behavior) | 0.2–0.5M (small Rust delta, big policy win) | **2.0–5.0** | **#1** (tie / arguably higher) |
| **Bet 3** Ambient index + schema | `fleet-quality` + `dev-tool` (both) | +2 (operator observability + cross-framework moat) | 1–2M | **1.0–2.0** | #2 |
| **Bet 4** Postgres backend | `fleet-quality` | +1 (foundational; enables Bet 5 + multi-operator team-tier) | 2–4M (migration + tests + dual-write) | **0.25–0.5** | #3 |
| **Bet 5** Local-LLM + multi-machine | `marcus` (M-D team-tier) | +1 | 5–10M+ (multi-week, multi-slice) | **0.1–0.2** | #4 |

**Observation:** Bet 1 and Bet 2 are the highest Mission Yield per token spent. **Both ship in Wave 1.** Bet 5 has the highest ABSOLUTE Mission Yield but the lowest Yield-per-week. This validates the existing Wave-order sequencing.

---

## Q6 — Marcus arc alignment per Bet

Per `ROADMAP_MARCUS.md`:
- **M-A trust gate** — INFRA-1486 **DONE** (per-gap budgets)
- **M-B canonical demo** — INFRA-1483 + 1484 + 1487 (open)
- **M-C daily-tax killer** — INFRA-1488 merge-conflict-resolution agent (open)
- **M-D team-tier substrate** — Marcus's "shared team fleet running on someone's beefy local box"
- **M-E** — (not surveyed in detail)

| Bet | Marcus arc impact |
|---|---|
| Bet 1 SWE wrapper | **Accelerates M-B + M-C.** `chump swe` is the primitive M-B's chump.fleet.yaml dispatches; M-C's merge-resolver is one specific `chump swe` invocation type. |
| Bet 2 Cost completion | **Extends M-A.** M-A shipped wall-clock + files + deps + $ budgets; Bet 2 extends $ enforcement from advisory to hard-kill. Marcus's disqualifying behavior was "14 files, 3 deps, 2 hours" — file/dep dimensions already enforced; cost dim needs the kill primitive. |
| Bet 3 Ambient index + schema | **Orthogonal to Marcus arc.** Operator/fleet-internal observability play. Long-term: a published schema attracts framework integration → indirectly serves M-D team-tier when other teams' agents emit to the same schema. |
| Bet 4 Postgres state | **Unlocks M-D.** Marcus's "queue into shared team fleet" requires state coherence across operators. Postgres backend is the storage tier for that. |
| Bet 5 Local-LLM + multi-machine | **IS M-D.** Marcus's "shared team fleet running on someone's beefy local box" + the local-mesh routing IS what M-D is. Bet 5 = M-D delivery. |

**No conflicts identified.** The 5 Bets are coherent with the Marcus arc; each Bet advances or extends a specific milestone.

---

## Q7 — Hardware decision for Bet 5 (operator-only)

Bet 5 requires a second compute node for the multi-machine demo. Tradeoff space:

| Option | Cost | Local-LLM throughput | NATS coord fit | M-D Marcus story | Risk |
|---|---|---|---|---|---|
| **Pi 5 cluster (4-5 nodes)** | $500–800 | Slow (<10 tok/s for 8B; can't fit 70B) | Excellent (low power, always-on) | Weak — Marcus's "beefy local box" is not 5 Pis | Energy efficient + cheap; fits coord workload not inference workload |
| **Second M4 Mac mini (16-24GB)** | $700–1,500 | Strong (40+ tok/s for 8B with MLX) | Good | **Strong fit** — matches Marcus's M-series operator profile | Best $/perf for Apple Silicon; main option |
| **Mac Studio refurb (M2 Ultra 192GB)** | $3,000+ | Strongest (70B in unified memory) | Good | **Strongest fit** — Marcus's "192GB" was implicit in his framing | Highest cost; biggest local-LLM story |
| **Existing Linux box** (if available) | $0 | Depends on GPU | Good | Decent — operator-pragmatic | Flexible but no MLX path |
| **Pixel 8 Pro + iPhone 15 Pro Max as nodes** | $0 (owned) | Novel but thermal-limited | Marginal | Marketing-novel but operator hesitant to commit | Fun, low priority per operator's prior note |

**My read for operator decision:**
- **If Marcus arc is the priority (Mission Yield max):** second M4 Mac mini is the clear pick. Matches Marcus's persona profile, ships MLX cleanly, ~$1K decision.
- **If coord-substrate proving is the priority (Bet 5 substrate without LLM):** Pi cluster is the cheapest credible NATS-mesh demo.
- **If wow-factor at expense of $:** Mac Studio refurb is the 70B-context story.

Recommend: **second M4 Mac mini** as the smallest credible Marcus-arc-aligned bet. ~$1K, ~2-week setup. Unlocks Bet 5 substrate proving without operator overcommit.

**Operator should make this decision before any Bet 5 slice claims start.** Otherwise the work is unboundedly scoped on a question only the operator can answer.

---

## Recommended next moves (concrete, sequenced)

**Immediate (this week, file these 4 gaps — note re-scoping META-038 saves the 5th):**

1. File **`chump swe` CLI wrapper** gap (Bet 1) — P1/m, dev-tool tag, Wave 1
2. File **subagent token/dollar budget extension** gap (Bet 2) — P1/s, marcus tag, Wave 1
3. File **`chump-agent-events-v1` spec publication** gap (Bet 3, after INFRA-1973 lands) — P1/s, fleet-quality tag, Wave 2
4. File **Postgres backend slice of INFRA-1967** sub-gap (Bet 4) — P1/m, fleet-quality tag, Wave 3

**Re-scope (no new gap):**

5. **Re-scope META-038 as the Bet 5 integrating umbrella.** Add depends_on list pointing at INFRA-1118, 1119, 1120, 1267, 1323, 1964 + a "Bet 5 done test" defining a two-node mesh demo.

**Operator-decision (blocks Bet 5):**

6. **Hardware question** — second M4 mini recommended; operator picks budget tier.

**Stop-doing (defer or close):**

7. INFRA-1545 (statistical-routing) — not Bet 5 critical path; defer until Bet 5 substrate ships
8. INFRA-1551 (cull or populate routing_outcomes schema) — decide: prune now (saves cycles) OR mark depending-on-Bet-5

## Wave-order recap (post-bounce-off)

| Wave | Bets | Gaps |
|---|---|---|
| **Wave 1 (this week)** | Bet 1, Bet 2 | NEW chump swe + NEW subagent token/dollar |
| **Wave 2 (next 2-4 weeks)** | Bet 3 | INFRA-1973 (ambient index) + NEW schema publication |
| **Wave 3 (4-8 weeks)** | Bet 4 | NEW Postgres slice of INFRA-1967 |
| **Wave 4 (8-12+ weeks)** | Bet 5 | META-038 re-scoped umbrella + 13 substrate gaps + hardware decision |

## What this doc IS / IS NOT

**IS:** complete answers to the 7 Market Positioning bounce-off questions; an action list (4 new gaps + 1 re-scope + 1 operator decision) ready to execute.

**IS NOT:** final commitment — operator owns the final order. Not a substitute for the weekly digest. Not the roadmap.
