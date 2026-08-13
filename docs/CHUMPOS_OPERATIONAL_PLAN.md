---
doc_tag: canonical
owner_gap: RESILIENT-310
last_audited: 2026-08-13
supersedes_intent_of: [ROADMAP.md, ROADMAP_OPUS_SEQUENCING.md]
anchor: docs/FACTORY_VISION.md
---

# ChumpOS Operational Plan — Resilient · Scalable · Secure

**This is not a roadmap.** The vision anchor is [FACTORY_VISION.md](FACTORY_VISION.md).
This is the **operational readiness plan**: the crisp bar for "fully operational," a
*grounded* current-state assessment of every subsystem the autonomous loop depends on,
the critical path, and the proof gate that declares done. **Gaps implement this plan;
ATC executes them.** Authored by the board (Chair) from a live helsinki audit
2026-08-13.

---

## 0. Definition of "fully operational"

ChumpOS is fully operational when a person deploys it on a fresh Linux box and it
**sustains the full loop — need → prioritize → fix → prove → land → self-heal — across
every repo it owns (itself AND the products it ships), for days, paging the human ONLY
for genuine judgment calls**, and does so **Resiliently, Scalably, Securely**. Done is
three proofs, one per pillar (§4). Anything less is "an impressive machine," not a
factory you deploy and walk away from.

## 1. The loop — every link must hold

`Intake → Prioritize → Execute → Verify → Land → Self-heal → (Escalate when stuck)`.
One broken link breaks hands-off. Current state, grounded 2026-08-13:

| Link | Pillar | State | Evidence (this audit) | Closing gap |
|------|--------|-------|-----------------------|-------------|
| **Intake** need→gap | Scal | 🟡 PARTIAL | `onboard`/`improve` work for external repos; human-vision front door is doc-only | (COTG backlog) |
| **Prioritize** right work | Scal | 🟡 PARTIAL | picker steered 26h/449-entries stale (INFRA-3605, **fixed**); intake unmeasured (opened_date) | INFRA-1611 |
| **Execute** claim→fix→PR | Res | 🟡 PARTIAL | reliable on tractable gaps; **bounces on hard ones** | RESILIENT-309 |
| **Verify** AC gate | Cred | 🟡 PARTIAL | AC-judge landed; coverage unproven at scale | (judgment-organ) |
| **Land** green→merged | Res+Scal | 🔴 **RED** | chump PRs rot **conflicted** (#3740/#3679, rebaser not clearing) or blocked; **olive green PRs rot 25d** (#3/#4/#6/#9 — no lander at all) | **RESILIENT-311** |
| **Self-heal** flake/organ/jam | Res | 🟡 PARTIAL | easy classes covered (flake-rerun, organ-reconcile); **conflicts + shared-gate reds not** | RESILIENT-311 |
| **Escalate** honest-when-stuck | Res | 🔴 **RED** | INFRA-3605 claimed→retracted→**no PR, no retry, no page 22h** — found only by hand | RESILIENT-309 |
| **Deploy** reproducible | Res+Sec | 🟡 PARTIAL | organ-reconcile (P1) done; still a snowflake — 65 redundant Mac daemons shadow helsinki | RESILIENT-308 |
| **Observe** operator truth | Res | 🟡 PARTIAL | chairman-pulse + `kpi report` exist; convergence metric blind (opened_date) | INFRA-1611 |
| **Tend products** factory tends what it ships | Scal | 🔴 **RED** | fleet lands only chump; **products untended** — this is why olive rots | RESILIENT-311 |
| **Secure boundaries** | Sec | 🟡 PARTIAL | product-PR tap gate + revoke-before-publish exist; double-actor hazard (Mac); oauth/farmer freshness flaky | RESILIENT-308 / 056 |

**Headline:** the factory ships **volume of its own maintenance** (54 closes/24h, all
INFRA/CREDIBLE/RESILIENT — **zero product, zero user-facing**) while **green product PRs
rot and hard gaps drop silently.** It tends itself, not outcomes. Three RED links —
**Land, Escalate, Tend-products** — are what stand between here and "fully operational."

## 2. The three pillars — done-bar + current verdict

### 🛡 RESILIENT — self-heals, nothing rots, honest when stuck, no SPOF
**Done when:** every green PR on every owned repo lands (or is rebased) without a human;
a gap the fleet can't do **re-queues and escalates**, never vanishes; a killed organ
self-restores; no subsystem depends on a sleeping laptop.
**Verdict: NOT MET.** RED on Land + Escalate; PARTIAL on deploy/self-heal.
**Blockers:** RESILIENT-311 (reliable landing), RESILIENT-309 (escalate-don't-drop),
RESILIENT-308 (kill the snowflake/SPOF).

### 📈 SCALABLE — N repos + M gaps, no operator bottleneck, throughput measured + converging
**Done when:** onboarding a 2nd, 5th, 50th product repo needs no new operator work; the
factory tends every repo it owns (deps, hygiene, landing); throughput and backlog
convergence are one honest number.
**Verdict: NOT MET.** RED — tends only itself; products untended; convergence unmeasured.
**Blockers:** RESILIENT-311 (tend products), INFRA-1611 (measurable intake),
prioritization-at-scale.

### 🔒 SECURE — boundaries hold, gates enforce, no double-actors, secrets sound
**Done when:** product changes require the operator tap; no two nodes act on one repo;
a leaked-secret check gates every publish; autonomy-level gates hold; credential
freshness is real, not flaky.
**Verdict: PARTIAL.** Gates + revoke-before-publish exist; RED risk = Mac double-actor
node; oauth/farmer freshness flaky.
**Blockers:** RESILIENT-308 (decommission double-actor), RESILIENT-056 (auth freshness).

## 3. Critical path — the order to close (weakest link first)

1. **Land reliably across owned repos** [Res+Scal] — **RESILIENT-311**. Stop the rot:
   auto-rebase conflicted chump PRs, land green ones, and **tend product repos** (auto-
   merge green minor/patch deps, surface majors, fix-or-close red like olive #4). This is
   the loudest failure and the direct answer to "PRs sitting unmerged make no sense."
2. **Escalate-don't-drop** [Res] — **RESILIENT-309**. Hard work surfaces, never vanishes.
3. **Reproducible + secure deploy** [Res+Sec] — **RESILIENT-308**. Kill the snowflake and
   the double-actor node; helsinki = sole ops center, reproducible from repo.
4. **Trustworthy priority + measurable convergence** [Scal] — INFRA-3605 (done) + **INFRA-1611**.
5. **Front door: vision→gap for a non-technical person** [Scal] — the COTG on-ramp (last,
   because it only matters once 1–4 make the loop trustworthy).

## 4. Proof gate — how we PROVE fully-operational (not vibes)

One acceptance test per pillar, on a **fresh deploy**:
- **Resilient:** inject a gap the fleet can't solve → it re-queues + **escalates** (does
  not drop); inject a flake and a merge-conflict → both self-heal; kill an organ →
  reconcile restores it; **zero green PRs rotting on any owned repo over 7 days**.
- **Scalable:** onboard a 2nd product repo → both it and chump get green PRs landed and
  deps tended with **zero operator merges**; throughput + convergence show in one number.
- **Secure:** a product feature PR **requires** the operator tap; only one node acts per
  repo; a planted leaked key **blocks** publish; autonomy-level gate holds.

Fully operational = **all three proofs pass, sustained, unattended.**

## 5. Pass to ATC — the gaps (execution is the fleet's)

| Gap | Pillar | Status | Job |
|-----|--------|--------|-----|
| **RESILIENT-311** | Res+Scal | NEW | Landing subsystem: no green PR rots on any owned repo (chump rebase + product-repo tending) |
| RESILIENT-309 | Res | filed | Escalate-don't-drop |
| RESILIENT-308 | Res+Sec | filed | Decommission Mac double-actor; helsinki = sole ops center |
| INFRA-1611 | Scal | filed | opened_date / measurable intake + convergence |
| RESILIENT-056 | Sec | filed | Auth/oauth freshness safety net |
| INFRA-3612 | Scal | filed | Almanac index off the Mac |

**The board owns this plan; the fleet owns the gaps.** Review: the Chair re-audits each
board cycle (`scripts/chairman/chairman-pulse.sh`) and updates state above as links flip
GREEN. This doc is done being written when all three pillar proofs pass.
