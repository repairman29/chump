# Market evaluation, positioning, and success plan

**Purpose:** Single place for **ICP**, **competitive truth**, **north-star metrics**, **research materials**, and the **evaluation memo** (updated as evidence arrives). Complements [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) (launch gates + product lenses) and [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) (horizons).

**Last updated:** 2026-04-10 (Phase 2: §2b baseline scores, §4.2 tracker, `GET /api/pilot-summary`)

---

## 1. Positioning (90-day primary ICP)

**Primary ICP (2026 Q2–Q3):** **Solo builder or serious indie dev** who already uses **Git + Discord or a browser tab** daily, is comfortable **self-hosting** one Rust service, and wants **durable tasks + tool use + optional fleet** under their own keys—not a hosted multi-tenant SaaS.

| For this ICP | Not for (say no or defer) |
|----------------|---------------------------|
| Self-hosted, single-tenant, BYOK | Teams expecting zero-ops SaaS onboarding |
| Web PWA + optional Discord as control planes | Mass-market Discord moderation / economy bots |
| SQLite-backed tasks, episodes, autonomy, large tool surface | “Open ChatGPT” replacement for general chat |
| Optional Mac + Pixel fleet, hybrid inference (power user story) | Non-technical consumers who will not run Ollama or read `.env` |
| Open source, forkable Rust chassis for AI engineers evaluating agents | Buyers who need SOC2 / managed tenancy day one |

**External promise (one paragraph):** Chump is a **self-hosted** agent stack: OpenAI-compatible inference (local Ollama/vLLM or cascade), **durable state**, **tools** (repo, git, GitHub, search, approvals), optional **markdown brain** and **PWA**. You run it; your keys; your hardware tradeoff. “Special” = **reliability + intent→action + shipped artifacts** for one operator—not feature parity with consumer chat apps.

**Kill list (do not pitch as product until gated):** Frontier consciousness modules ([CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) §3) unless a **user-visible metric** (e.g. battle QA delta, speculative rollback clarity) is published for that slice.

---

## 2. Competitive matrix (living)

**How to use:** Score **Low / Med / High** or short notes per cell when comparing. Re-run after major releases or quarterly.

**Rows = evaluation dimensions · Columns = offerings**

| Dimension | Chump | OpenHands-style self-hosted agent | IDE-native (e.g. Cursor agent) | ChatGPT (+ manual glue) | MEE6-class Discord bot |
|-----------|-------|-------------------------------------|--------------------------------|-------------------------|-------------------------|
| **Setup time** | Med–High (Rust build, `.env`, inference) | Med (often Python/Docker) | Low (inside IDE) | Low | Low |
| **Time to first value** | Golden path: web health + chat ([EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md)) | Varies | Very low for code in-repo | High for “does my repo” | N/A (different job) |
| **Autonomy depth** | High: task DB, leases, `autonomy_once`, RPC/cron ([ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) Phase B) | High in category | Med–High (repo-scoped) | Low without custom automation | None |
| **Memory / brain** | SQLite + optional `chump-brain/`, memory graph path | Varies | Repo + chat context | Manual / GPT memory | None |
| **Fleet / hybrid inference** | **High** (Mac + Pixel, Mabel, hybrid model routing — [FLEET_ROLES.md](FLEET_ROLES.md), [OPERATIONS.md](OPERATIONS.md)) | Varies; rarely Discord+PWA+fleet | Low | None | N/A |
| **Security model** | Self-hosted, opt-in auto-push / executive mode ([PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md)) | Self-hosted | Vendor trust + local | Vendor | Discord token scope |
| **Monthly cost** | Local = electricity + hardware; APIs optional ([PROVIDER_CASCADE.md](PROVIDER_CASCADE.md)) | Similar | Subscription | Subscription + glue | Freemium |
| **Support burden** | On owner (inference stability, roles) | On owner | Lower | Lowest | Low |
| **Extensibility** | High (Rust monolith, tools, heartbeats) | High (plugins) | Med (IDE ecosystem) | Med (APIs only) | Low–Med |

**Strategic read:** Chump wins **fleet + hybrid + single-tenant depth** for one motivated operator; it loses **mass adoption** and **zero-setup** vs IDE and consumer apps. GTM should not claim “better Discord bot for everyone.”

### 2a. Deep comparative narrative (categories + research hooks)

Long-form pitch-aligned comparison (hosted vs IDE vs self-hosted UIs vs OpenHands-like vs iPaaS vs frameworks), plus interview scoring rubric, evidence map, and **§9 build vs copy** (what to ship vs steal vs defer): **[COMPETITIVE_DEEP_DIVE.md](COMPETITIVE_DEEP_DIVE.md)**. Update that doc when positioning or primary alternatives change; refresh §2b scores here after cohort evidence.

### 2b. Competitive position scores (baseline, pre-cohort)

**Date:** 2026-04-10. **Replace** this subsection after interviews with scored matrix notes. Scale: **Weak** / **Parity** / **Strong** vs your primary alternative (IDE-native agent + hosted chat).

| Dimension | Chump vs market (estimate) |
|-----------|----------------------------|
| Setup time | **Weak** (Rust + env + inference) |
| Time to first value | **Parity** on golden path vs self-host peers |
| Autonomy depth | **Strong** |
| Memory / brain | **Parity**–**Strong** when brain configured |
| Fleet / hybrid | **Strong** (niche; unused = N/A) |
| Security / BYOK | **Strong** |
| Monthly cost (local-first) | **Strong** for solo |
| Support burden on owner | **Weak**–**Parity** |
| Extensibility | **Strong** (monolith + tools) |

---

## 3. North-star metrics (N1–N4)

Define **targets** after first cohort (interviews + blind sessions); initial columns are **instrument**.

| # | Metric | Definition | How to measure (repo today) |
|---|--------|------------|------------------------------|
| **N1 — Activation** | % of cold clones reaching golden-path success | Same steps as [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) L2 / [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) | `./scripts/verify-external-golden-path.sh` + optional timed human run; log pass/fail in onboarding log |
| **N2 — Reliability / quality** | Regression confidence after change | Battle QA smoke pass rate + CI green | `BATTLE_QA_MAX=25 BATTLE_QA_ITERATIONS=1 … ./scripts/battle-qa.sh` ([ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md)); `cargo test` + CI `.github/workflows/ci.yml` |
| **N3 — Autonomy throughput** | Agent loop completes bounded tasks without manual rescue | Success count / wall time on fixture or real task | `./scripts/run-autonomy-tests.sh` ([CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md)); `cargo test` for `autonomy_loop` / `task_db`; pilot: count `done` tasks per week (SQL on `chump_tasks` or episode log) |
| **N4 — Pilot outcomes (aggregate)** | One JSON snapshot for weekly pilot check-in | `GET /api/pilot-summary` when web is up ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)); **`./scripts/export-pilot-summary.sh`**; see [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md) §API |

**Optional N4 detail:** PR URLs still manual or episode `notes` until GitHub linkage is adopted.

---

## 4. Market evaluation memo (publishable synthesis)

### 4.1 Problem statement

Technical operators want **repeatable agent behavior** on **their** repos and schedules without surrendering data to a generic SaaS. Existing options split into **thin chat**, **IDE-only**, or **heavy self-hosted** stacks that rarely combine **Discord + PWA + task DB + fleet** in one coherent OSS narrative.

### 4.2 Evidence to date (update as you run research)

| Source | Date | Summary |
|--------|------|---------|
| PRODUCT_CRITIQUE + README alignment | 2026-04 | Self-hosted / single-tenant / BYOK clarified; golden path exists |
| Maintainer dry run + cold clone table | 2026-04 | See [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) |
| Phase 2 research sprint tracker | 2026-04-10 | **0/12** interviews, **0/5** blinds—run §6 kit; log blinds in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) **Market research blind sessions**; paste one-line summaries here after each session |
| Phase 2 evidence templates | 2026-04-12 | Working tables in [MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md) (B1–B5 + interview scratch); §4.4 remains canonical synthesis rows |
| Semi-structured interviews | _Pending_ | Use §6 script; append rows to §4.4 |
| Blind golden-path sessions | _Pending_ | Use onboarding log **Market research blind sessions** |

### 4.3 Competitive conclusion (working)

Chump is **adjacent to** self-hosted dev agents and **orthogonal to** mass-market Discord bots. Differentiation is **depth for one tenant** + optional **fleet/hybrid** story, not raw LLM quality.

**Gap mitigation (market demands plan):** Pilot **N3/N4** instruments and H1 wedge docs ship in [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md), [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md), [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md), [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md), [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) (flap drill), [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md), and PWA Tasks hint in `web/index.html`. **N4:** `GET /api/pilot-summary` + export script ship for aggregate JSON; first-class CSV/dashboard export still optional.

### 4.4 Interview synthesis log

**Scratch / long-form notes:** Optional pre-table capture in [MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md); promote distilled rows here when ready.

**Progress:** 0 / 12 rows filled (update count as you go).

| # | Date | Segment (ICP?) | Pain cited | Chump fit (1–5) | Verbatim (optional) |
|---|------|----------------|------------|-----------------|---------------------|
| 1 | | | | | |
| 2 | | | | | |
| … | | | | | |
| 12 | | | | | |

---

## 5. Recommended wedge (next build cycle)

**Hypothesis H1 (default until interviews contradict):** Own the slice **“intent → durable task → autonomy / Cursor handoff → verifiable done”** on **web + optional Discord**, with **fleet** as a **power-user upsell** story—not the first-run requirement.

**Why:** Aligns with [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md) north star (intent, speed, quality) and with metrics **N1–N3** above.

**If interviews say otherwise:** Revise this section only after ≥5 interviews agree on a different primary job-to-be-done; link decision in [ROADMAP.md](ROADMAP.md) if roadmap shifts.

---

## 6. Primary research kit

### 6.1 Semi-structured interview (30–45 min)

**Intro:** “We’re evaluating a self-hosted agent that uses Discord/PWA and a local or API model. There are no wrong answers.”

1. Walk me through **yesterday’s** dev workflow—where did chat/IDE/automation fit?
2. What **failed or annoyed** you about agents or scripts in the last month?
3. **Self-host** a Rust service with Ollama: acceptable, never, or depends on payoff?
4. **Discord vs browser** as primary command surface—which do you actually use?
5. Would **Mac + phone/edge** split (heavy model at home, light on device) matter to you?
6. What **one outcome** would make you adopt something new for 2 weeks?

**Scoring rubric (post-call, internal):**

| Criterion | 1 | 3 | 5 |
|-----------|---|---|---|
| Pain acuity (agents/repos) | Vague | Clear | Urgent, repeated |
| Fit to self-hosted OSS | Rejects | Curious | Already runs similar |
| Willingness to pilot 2 weeks | No | Maybe | Yes, with calendar |

### 6.2 Blind onboarding protocol

See [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) **Market research blind sessions**. Facilitator may watch screen-share; no hints unless participant is stuck more than 10 minutes (note “rescue” in log).

---

## 7. Phased success plan (execution)

| Phase | Duration | Actions |
|-------|----------|---------|
| **0 — Positioning** | 1–2 weeks | Keep README + this doc aligned; avoid pitching fleet-first to cold externals |
| **1 — Evaluation sprint** | 3–4 weeks | Fill §4.4 and blind session table; update §4.2 |
| **2 — Wedge build** | 6–12 weeks | Ship one vertical slice validated by interviews; tie consciousness only to measurable wins |
| **3 — Scale** | After retention | Templates, video, community; hosted tier only if ICP demands it |

---

## 8. Market demands → product bets (implementation map)

Maps **market plan tiers** to shipped or planned **docs/scripts** in-repo (traceability for roadmap and pilots).

| Tier | Demand | Artifact / owner |
|------|--------|-------------------|
| **A** | Trust + proof (N3/N4) | [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md), `./scripts/wedge-h1-smoke.sh`, `./scripts/export-pilot-summary.sh`, `GET /api/pilot-summary`, [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md) |
| **A** | Intent quality | [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md) |
| **B** | Reliability under flap | [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) **Model flap drill** |
| **B** | Trust for speculative rollback | [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md), [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) |
| **C** | PWA-first wedge | [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md); PWA Tasks hint in `web/index.html`; README + [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) web-first copy |
| **D** | Hosted / consciousness GTM | Deferred until Tier A evidence ([CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) gates) |

**Roadmap:** See [ROADMAP.md](ROADMAP.md) **Market wedge and pilot metrics** for the living checkbox list.

---

## 9. Related docs

- [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) — Launch gates, product lenses  
- [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) — Horizons 1–4  
- [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) — Minimal first success  
- [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) — Timed friction + blind sessions  
- [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) — API economics  
- [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) / [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) — Hardware and reliability narrative  
- [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md), [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md), [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md), [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md), [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md)  

---

## Version

Introduced to operationalize the **Market critique, differentiation, and evaluation plan**. Update **Last updated** and §4.2 when new evidence lands.
