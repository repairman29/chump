---
# THE PATH — the 5‑track ranked program

**Author:** Oracle (orchestrator‑opus session)  
**Updated:** 2026‑11‑28 02:04Z  
**Refresh cadence:** every 3‑4 h by the Oracle role, or on major‑track shift.

This document is the **single ranked source‑of‑truth** for what the fleet should be shipping. Curators should claim gaps from the “Next actions” lists below; everything else lives in the raw firehose (`chump gap list --status open`).

---

## Track 1 — META‑070 firewall completion (≈95 % done)

**Theme:** every deterministic CI gate mirrors a local `chump preflight`. Goal: push‑then‑CI‑fail rate < 5 %.

**Why #1:** The firewall is the substrate. Without it PRs become CI roulette and the queue clogs. This track has shipped the most today and is one ship‑cluster from “done.” Close it out and it stops demanding attention.

**Next actions (claim from top down):**
1. **INFRA‑1790** – preflight markdown‑intra‑doc‑links gate (Tier C #4)  
2. **INFRA‑1792** – preflight pr‑scope sanity gate (Tier C #6)  
3. **INFRA‑1793** – preflight no‑claude‑leak gate (Tier C #7)  

*Done when:* all three ship. Track 1 then moves to maintenance mode.

---

## Track 2 — Oracle/JIT self‑improvement

**Theme:** retire Opus as the JIT scheduler; make the orchestration loop a daemon so the planet handles only architectural judgment.

**Why #2:** Each loop iteration now burns ~5 min of Opus context on pebble‑shaped JIT work. Shipping this frees Opus for road‑paving (this doc) and meta‑fixes.

**Next actions (ranked by impact ÷ effort):**
1. **CREDIBLE‑1459** – gap done‑checks (P1, m) – critical for fleet reliability.  
2. **INFRA‑1880** – auto‑export `CHUMP_SESSION_ID` at curator launch (P1, m).  
3. **CREDIBLE‑1496** – guard `set_fields()` against status = done (P1, xs).  

*Done when:* the orchestrator‑opus stops manually broadcasting next‑gap assignments; operators report “no dispatches in ≥ 2 h.”

---

## Track 3 — META‑073 Initiative #2 (forward‑looking coordination)

**Theme:** predict collision, route by skill, propagate lessons.

**Why #3:** The A2A coordination wiring that lets the fleet self‑organize beyond the cascade‑drain loop. Pairs with Track 2 – once JIT exists it needs collision‑prediction + skill‑routing to assign WELL, not just FAST.

**Next actions:**
1. **INFRA‑1892** – curator‑JIT‑scheduler daemon (in‑flight, awaiting main‑branch verification).  
2. **CREDIBLE‑004** – add tests for four critical untested files (`main.rs`, `web_server.rs`, `repo_tools.rs`, `discord.rs`) (P2, m).  
3. **INFRA‑1860** – preflight markdown‑intra‑doc‑links gate (Tier C #4) – duplicate of Track 1 but needed for cross‑track consistency.  

*Done when:* the daemon is merged to `main` and the test suite passes; forward‑coordination can safely route tasks.

---

## Track 4 — A2A (agent‑to‑agent) automation

**Theme:** enable the fleet to negotiate work hand‑off, load‑balance, and recover from failures without human intervention.

**Why #4:** After the firewall and self‑improvement tracks, the remaining bottleneck is the lack of robust peer‑negotiation. Shipping A2A primitives will let agents close gaps autonomously, dramatically increasing throughput.

**Next actions (open high‑leverage gaps):**
1. **CREDIBLE‑1493** – point eval harness inward; calibrate fleet self‑reports against ground‑truth (P2, m).  
2. **INFRA‑1901** – implement “gap‑hand‑off” RPC (placeholder for the first concrete A2A primitive; currently unclaimed, priority P1).  
3. **CREDIBLE‑1520** – add per‑agent health heartbeat to the coordination bus (P2, m).  

*Note:* Gaps 1901 and 1520 are newly identified from the firehose; they have not yet been entered into state.db, so they appear here as **drift** – the Oracle will create proper entries on the next sweep.

---

## Track 5 — Demo / showcase

**Theme:** produce visible, low‑risk artifacts that prove the system’s new capabilities to stakeholders.

**Why #5:** Demonstrations validate that the underlying tracks are delivering value and keep executive sponsorship strong.

**Next actions:**
1. **DEMO‑001** – live‑stream of the firewall preflight gate in action (P2, xs).  
2. **DEMO‑002** – “self‑improvement” dashboard showing Opus‑free JIT scheduling (P2, xs).  
3. **DEMO‑003** – A2A hand‑off demo with two agents negotiating a synthetic gap (P2, xs).  

*All demo gaps are newly created for the upcoming stakeholder review; they will be closed automatically once the corresponding production gap ships.*

---
