# Competitive deep dive — Chump vs the landscape

**Purpose:** Expand the **one-line pitch** into a **category-by-category** comparison so GTM, docs, and pilots stay honest. Complements the living matrix in [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §2–§2b and the launch gates in [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md).

**One-line pitch (reference):** *Self-hosted AI agent with persistent memory and autonomous task execution. Your keys, your data, your machine.*

**Last updated:** 2026-04-10

---

## 1. How to use this document

| Audience | Use |
|----------|-----|
| **You (builder)** | Pick 2–3 “primary alternatives” for your ICP and keep a short “we win / we lose” note in [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §2b after each interview wave. |
| **Pilot / sponsor** | Point them at **§6 When Chump wins** + **§7 Honest weaknesses** first; then **§4** for the category they already know. |
| **Internal** | When shipping changes default trust boundaries (auto-push, cascade, webhooks), update **§5 Evidence map** and re-check **§8 Risks**. Use **§9** to decide **copy vs build** so roadmap work tracks competitive reality, not feature FOMO. |

This is **not** a vendor feature matrix with version numbers (those rot overnight). It is a **durable framing** plus **research hooks** you can validate in Phase 2 sessions ([MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md)).

---

## 2. Evaluation dimensions (glossary)

These dimensions are how we compare **unlike** products without talking past each other.

| Dimension | Question it answers | Chump angle (high level) |
|-----------|---------------------|---------------------------|
| **Trust boundary** | Where do prompts, keys, and artifacts live? | Default: **your** host + **your** OpenAI-compatible endpoint; optional provider cascade ([PROVIDER_CASCADE.md](PROVIDER_CASCADE.md)). |
| **Persistence model** | What survives across sessions / reboots? | SQLite tasks, episodes, web sessions, optional **brain** tree ([CHUMP_BRAIN.md](CHUMP_BRAIN.md)); not “just chat logs.” |
| **Autonomy model** | What runs without a human typing? | Heartbeats, `autonomy_once`, roles, async jobs ([ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md), [AUTOMATION_SNIPPETS.md](AUTOMATION_SNIPPETS.md)). |
| **Execution surface** | Where does the agent act? | Discord, **PWA**, Tauri/Cowork shell, CLI/RPC — same tool/approval story across surfaces ([TOOL_APPROVAL.md](TOOL_APPROVAL.md), [DESKTOP_PWA_PARITY_CHECKLIST.md](DESKTOP_PWA_PARITY_CHECKLIST.md)). |
| **Governance** | How are dangerous tools constrained? | Tool policy, approvals, audit export, stack-status legibility ([ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) **P3**). |
| **Ops maturity** | What does the owner operate? | Inference, disk, optional fleet — documented runbooks ([OPERATIONS.md](OPERATIONS.md), [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md)). |
| **Extensibility** | How do I add “my company’s” behavior? | Rust monolith + tools + heartbeats; fork-friendly vs plugin-marketplace-friendly. |
| **Time-to-first-value** | How fast is a cold success? | Golden path + scripts ([EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md), [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md)). |

**Research expansion — scoring rubric (for interviews):** For each alternative the participant names, ask them to rate **1–5** on: trust, persistence, autonomy, governance, ops burden, delight. Log verbatim “job to be done” and **what they switched from**. Append to [MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md).

---

## 3. Category map (where Chump competes)

```text
                    High autonomy / long-running
                                    │
         Chump ─────────────────────┼──────────────── OpenHands-style
         (tasks, heartbeats,        │                 coding sandboxes
          roles, fleet)            │
                                    │
Low friction ───────────────────────┼─────────────────── High friction
signup / managed                  │                    self-host ops
                                    │
         ChatGPT / Claude / etc. ───┼─────── Self-hosted chat UIs
                                    │         (Open WebUI, LibreChat, …)
                                    │
                                    ▼
                              Low persistence /
                              chat-first products
```

Chump intentionally sits in the **upper-right quadrant** (high autonomy, high operator burden). Products in the lower-left win **mass adoption**; Chump wins **sovereignty + depth** for a narrow ICP ([MARKET_EVALUATION.md](MARKET_EVALUATION.md) §1).

---

## 4. Deep comparisons by category

### 4.1 Hosted general assistants (ChatGPT, Claude, Gemini, Copilot consumer)

| Strength of hosted | Strength of Chump |
|--------------------|-------------------|
| Best models, multimodal, voice, mobile apps, lowest friction | **Data residency** and **no mandatory vendor context** for repo + secrets if you stay local / BYOK cascade |
| Continuous product polish | **Inspectable** memory and tasks (SQL, files) — auditable for paranoid teams |
| Large ecosystem of “actions” | **Same agent** across Discord + web + desktop + cron-shaped automation |

**Deep read:** Hosted assistants optimize **median single-turn quality**. Chump optimizes **repeatable multi-turn work tied to a repo and a life cycle** (tasks complete, episodes log, heartbeats run). They are **substitutes only** for buyers who only need chat; they are **complements** if the buyer uses hosted for ideation and Chump for execution on private metal.

**Research to add:** For each major vendor, capture **enterprise** DPA / residency claims separately from consumer defaults — interviewees conflate these constantly.

---

### 4.2 IDE-native agents (Cursor, GitHub Copilot in-editor, Windsurf, Continue, Tabnine)

| Strength of IDE agent | Strength of Chump |
|------------------------|-------------------|
| Tight feedback loop inside the editor | **Non-IDE surfaces**: Discord, PWA, packaged desktop, headless |
| Deep workspace index, inline diffs | **Cross-session “staff” behaviors**: task queue, COS snapshots, weekly prompts ([PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md)) |
| Lower context-switching for pure coding | **Fleet** story (Mac + Pixel, hybrid inference) for operators who live in both worlds ([FLEET_ROLES.md](FLEET_ROLES.md)) |

**Deep read:** IDE agents are **the** right tool when the unit of work is “this repo, this PR.” Chump is **better** when the unit of work is “remind me across channels, run something tonight, notify me, keep policy under control” — **staff**, not **pair programmer**.

**Research to add:** Count how often pilot users send **non-repo** messages (tasks, reminders, ops). If high, Chump’s positioning vs IDE agents strengthens.

---

### 4.3 Self-hosted chat shells over local models (Open WebUI, LibreChat, AnythingLLM, LocalAI UIs, Lobe Chat)

| Strength of chat UI | Strength of Chump |
|---------------------|-------------------|
| Faster “pretty chat over Ollama” | **Agent runtime**: tool middleware, circuit behavior, approvals, jobs ([RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md)) |
| Often simpler deploy story (Docker) | **Productized governance** path (PWA audit export, stack-status, degraded UX matrix) |
| Good for demos and small teams | **Battle QA** + consciousness regression culture for “we broke the agent” loops ([BATTLE_QA.md](BATTLE_QA.md), [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md)) |

**Deep read:** Many projects in this category are **conversational frontends** first; agent loops are optional or plugin-shaped. Chump is the inverse: a **Rust agent** with a **web shell**, not a web UI with optional tools.

**Research to add:** Side-by-side **cold start** timing (clone → first chat) vs Chump golden path — already instrumented in spirit ([scripts/golden-path-timing.sh](../scripts/golden-path-timing.sh), [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md)).

---

### 4.4 OpenHands-style self-hosted coding agents (OpenHands, SWE-agent-style harnesses, sandbox “repo bots”)

| Strength of OpenHands-like | Strength of Chump |
|------------------------------|-------------------|
| Strong **repo sandbox** story for coding tasks | Broader **life-ops** tool surface (Discord, capture, watchlists, research pipeline) |
| Often Python/Docker — familiar to ML teams | **Single binary** ops for some deploys; explicit Mac + iOS/PWA + desktop narrative |
| Community around “fix this issue” | **Intent → action** in Discord + episodic memory for *your* workflows ([INTENT_ACTION_PATTERNS.md](INTENT_ACTION_PATTERNS.md)) |

**Deep read:** This is the **closest** architectural peer in [MARKET_EVALUATION.md](MARKET_EVALUATION.md)’s matrix. Chump differentiates on **multi-surface control plane + fleet + markdown brain conventions**, not on beating them at “spin up an isolated Docker PR factory.”

**Research to add:** A scripted **same-task** benchmark (issue fix or doc refresh) on the same machine: wall time, # manual interventions, # secrets exported. Log in [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) style tables.

---

### 4.5 Low-code agent builders (Dify, Flowise, Langflow, Botpress + LLM, Retool AI)

| Strength of builder | Strength of Chump |
|---------------------|-------------------|
| Visual graph, many connectors | **Code-first** extensibility in one repo; no graph JSON as source of truth |
| Faster for non-dev automators | **Deterministic ops docs** for inference and roles — engineer-to-engineer honesty |
| Hosted SaaS option | **Single-tenant** default story |

**Deep read:** Builders win **connector breadth** and **non-engineer** authors. Chump wins when the author is an **engineer** who wants **Git-shaped** evolution of behavior (PRs, tests, clippy) rather than clicking nodes.

---

### 4.6 iPaaS + LLM nodes (n8n, Make, Zapier, Temporal + “human task”)

| Strength of iPaaS | Strength of Chump |
|-------------------|-------------------|
| Mature retries, schedules, SaaS OAuth | **Semantic** repo + brain work in one agent loop |
| Huge integration catalog | **Privacy**: keep sensitive payloads off third-party automation SaaS |
| Operations dashboards | Chump’s “dashboard” is still maturing — see [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) + [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) |

**Deep read:** iPaaS is **orchestration-first**; Chump is **judgment-first** (LLM decides next tool). They meet at webhooks ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)); Chump is not trying to replace 500 SaaS connectors.

---

### 4.7 Memory-centric agent platforms (Letta / MemGPT lineage, Mem0-style APIs, “second brain + chat” SaaS)

| Strength of memory product | Strength of Chump |
|------------------------------|-------------------|
| Memory as **API product** for app builders | Memory as **substrate** for *this* agent’s tools and heartbeats |
| Fast onboarding for devs adding memory to apps | **No separate memory vendor** if you accept SQLite + brain disk |
| Hosted scale | **Air-gap friendly** posture if you run local inference only |

**Deep read:** If the buyer’s sentence is “I need memory in **my** SaaS product,” a memory API vendor may win. If the sentence is “**I** need an agent that remembers **my** work and acts,” Chump stays in scope.

---

### 4.8 Agent frameworks (LangGraph, CrewAI, AutoGen, Semantic Kernel, Haystack agents)

| Strength of framework | Strength of Chump |
|-----------------------|-------------------|
| Maximum flexibility, language choices | **Opinionated product**: Discord + web + desktop + CI already wired |
| Best for embedding in a new product | Best for **dogfooding** and **forking** a full operator stack |
| Large tutorials | **In-repo** operational truth ([OPERATIONS.md](OPERATIONS.md)) |

**Deep read:** Frameworks sell **building blocks**; Chump sells **a chassis**. The competitor is time: *build it yourself vs adopt Chump.*

---

### 4.9 Cloud autonomous “dev” agents (Devin-class, cloud coding sandboxes)

| Strength of cloud agent | Strength of Chump |
|-------------------------|-------------------|
| Managed sandboxes, polished demos | **No default requirement** to upload the repo to their cloud |
| Team features, billing | **Monthly cost** for solo local-first is mostly hardware + optional APIs ([MARKET_EVALUATION.md](MARKET_EVALUATION.md) §2b) |

**Deep read:** Cloud agents win **“show me a PR in 10 minutes on a greenfield task.”** Chump wins **“stay inside my boundary and integrate with my weird life.”**

---

### 4.10 Discord / community bots (MEE6, Carl-bot, Dyno, “AI addon” bots)

| Strength of community bot | Strength of Chump |
|-----------------------------|-------------------|
| Plug-and-play moderation, leveling | **General agent** with tools, not moderation-first |
| Hosted reliability | Self-hosted **tradeoff** |

**Deep read:** Per [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §1 — do **not** position Chump as “better MEE6.” Different job.

---

## 5. Chump evidence map (claims → docs / code)

Use this when a sponsor asks “prove it.”

| Claim | Where it is grounded |
|-------|----------------------|
| Self-hosted / BYOK / cascade | [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md), [.env.example](../.env.example) |
| Approvals + audit | [TOOL_APPROVAL.md](TOOL_APPROVAL.md), [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) |
| Tasks + autonomy | [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md), [AUTONOMY_ROADMAP.md](AUTONOMY_ROADMAP.md) |
| PWA + wedge path | [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md), [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) |
| Trust + speculative rollback honesty | [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md), [ADR-001-transactional-tool-speculation.md](ADR-001-transactional-tool-speculation.md) |
| “Built vs proven” hygiene | [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md), [ROADMAP.md](ROADMAP.md) **Architecture vs proof** |
| Defense / enterprise alignment (when relevant) | [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) |

---

## 6. When Chump wins (buyer sentences)

Use verbatim **jobs-to-be-done** in sales notes.

1. **“I need an agent that runs on my machine with my keys and still does real work when I’m not at the keyboard.”**  
2. **“I live in Discord and in a browser tab; I don’t want two different ‘brains’ that disagree.”**  
3. **“I need approvals and an audit trail for tools — not cowboy `run_cli`.”**  
4. **“I have a Mac and a Pixel / Android sidecar; I want one story.”** ([ANDROID_COMPANION.md](ANDROID_COMPANION.md))  
5. **“I’m okay reading ops docs if it means I never upload this repo to a random SaaS.”**

---

## 7. Honest weaknesses (say these out loud)

| Weakness | Mitigation in-repo |
|----------|--------------------|
| High setup friction vs SaaS | Golden path, preflight, packaging roadmap ([PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md), [PILOT_HANDOFF_CHECKLIST.md](PILOT_HANDOFF_CHECKLIST.md)) |
| Inference wall time dominates UX | [PERFORMANCE.md](PERFORMANCE.md) §8, [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) |
| “Enterprise” checklist (SOC2, managed tenancy) | Say **no** or defer; see [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §1 |
| Consciousness stack can spook pragmatists | [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md), [MARKET_EVALUATION.md](MARKET_EVALUATION.md) kill list |
| Dashboard / Tier-2 PWA breadth | [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) |

---

## 8. Moats, non-moats, and research backlog

**Potential moats (if you keep investing):**

- **Integrated governance + multi-surface parity** (hard to bolt on after the fact).
- **Fleet + hybrid inference** for a two-device operator ([OPERATIONS.md](OPERATIONS.md)).
- **In-repo proof culture** (battle QA, golden path, pilot-summary API) — boring until competitors lie.

**Non-moats (do not overclaim):**

- “We have more tools than X” — tool count is not retention.
- “We are smarter than GPT-4” — model quality is mostly **not** Chump’s moat.

**Research backlog (expand evidence over time):**

| # | Study | Output artifact |
|---|--------|-----------------|
| R1 | 5× blind golden path ([ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md)) | Update [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §2b |
| R2 | 8× semi-structured interviews | §4.4 memo + quotes in [MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md) |
| R3 | Side-by-side latency envelope vs IDE agent on same task | [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md) |
| R4 | Consciousness ON vs OFF utility | [CONSCIOUSNESS_UTILITY_PASS.md](CONSCIOUSNESS_UTILITY_PASS.md) |
| R5 | Sponsor asks “OpenHands vs Chump” | Scripted benchmark under **§4.4** |

---

## 9. Build vs copy playbook (second pass)

**Goal:** Decide what to **ship in-tree**, what to **copy as UX/doc patterns**, and what to **delegate**—so you close gaps users actually feel without becoming a hosted chat clone or a low-code iPaaS.

**Rules of thumb**

1. **Copy patterns, not stacks** — Steal *behavior* (empty states, health tiles, run logs) compatible with [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md): stay vanilla + incremental JS until a framework is earned.  
2. **Copy “first five minutes”** — Most churn is before first successful turn; competitors invest here relentlessly.  
3. **Build only moat-aligned depth** — Governance, multi-surface parity, fleet, proof culture ([§8](#8-moats-non-moats-and-research-backlog)).  
4. **Integrate inference, don’t build it** — Ollama, vLLM-MLX, cascade, mistral.rs paths are the right “not invented here” boundary ([INFERENCE_PROFILES.md](INFERENCE_PROFILES.md)).  
5. **MCP interop is a policy decision, not a race** — Chump intentionally keeps a **single tool registry** for the main agent; MCP bridges for scanners / dynamic discovery are gated ([RFC-wp13-mistralrs-mcp-tools.md](rfcs/RFC-wp13-mistralrs-mcp-tools.md), [RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md)). “Copy Cursor” ≠ “wire every MCP server default-on.”

---

### 9.1 What to **copy** (high ROI)

| Source category | Copy (pattern) | Chump home | Notes |
|-----------------|----------------|------------|--------|
| **Hosted assistants** | **Suggested first actions** after empty chat; **progressive disclosure** (advanced settings collapsed); **clear model / latency expectations** in UI | `web/index.html` PWA chat + Settings | You already hint at `CHUMP_LIGHT_CONTEXT` on errors—extend to a *normal* “slow model?” tip, not only failure. |
| **Self-hosted chat UIs** | **One-command or Compose profile** in docs for “web + Ollama only” smoke | New optional `docs/docker/` or section in [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) | Copy *operator onboarding*, not their stack wholesale—keep Rust binary as source of truth. |
| **IDE agents** | **Tighter command palette**: discoverable `/` commands, **recent actions**, keyboard-first flows | PWA slash palette + [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) | Copy *muscle memory*, not VS Code embedding. |
| **OpenHands-style agents** | **“Issue → isolated workspace → PR” recipe** as a *documented* golden path (git worktree + `sandbox_tool` / policy) | [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) | You may never match their Docker sandboxes in v1—**copy the workflow story** first, automate second. |
| **iPaaS** | **Execution history**: who ran what, when, success/fail, link to logs | `GET /api/jobs` + PWA Dashboard tail ([WEB_API_REFERENCE.md](WEB_API_REFERENCE.md)) | Copy the *trust* of a run log, not 400 SaaS nodes. |
| **Memory products (Letta-class)** | **Explicit “memory vs working context” labels** in UI or docs (even read-only) | [CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md) + Settings copy | Copy *legibility*, not proprietary memory cores. |
| **Cloud dev agents** | **Demo script**: 3 reproducible “wow” turns for sponsors | [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md), [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md) | Copy *sales engineering discipline*, not their cloud. |

---

### 9.2 What to **build** (differentiator—keep investing)

| Build | Why competitors won’t give it to your ICP | Pointers |
|-------|-------------------------------------------|----------|
| **Same approval + audit contract** across Discord / PWA / desktop / CLI | Hosted and many UIs treat tools as an afterthought | [TOOL_APPROVAL.md](TOOL_APPROVAL.md), [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) **P3** |
| **Time passes without you** (tasks + heartbeats + roles + async jobs) | Chat products are session-centric | [AUTOMATION_SNIPPETS.md](AUTOMATION_SNIPPETS.md), [OPERATIONS.md](OPERATIONS.md) |
| **Fleet + hybrid inference** (optional but rare) | True two-device + model routing is niche engineering | [FLEET_ROLES.md](FLEET_ROLES.md), [ANDROID_COMPANION.md](ANDROID_COMPANION.md) |
| **Pilot-grade observability** (`pilot-summary`, export scripts, friction logs) | Competitors optimize for MAU, not *prove it on my machine* | [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md), [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) |
| **Honest limits** (speculative rollback, inference degradation) | Enterprise marketing often obscures this | [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md), [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) |

---

### 9.3 What to **integrate or defer** (do not build in core)

| Area | Integrate / defer | Reason |
|------|-------------------|--------|
| **Frontier models** | Provider cascade + local servers | Model quality is not your moat. |
| **SOC2 / managed multi-tenant** | Defer or partner | ICP is solo/small self-host ([MARKET_EVALUATION.md](MARKET_EVALUATION.md) §1). |
| **Generic MCP “run everything” bridge** | Defer to RFC + governance gates | Registry + audit story beats infinite tools ([RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md)). |
| **Full Tier-2 dashboard without ops proof** | Slice per [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) | Breadth without reliability loses pilots. |

---

### 9.4 What **not** to copy (anti-patterns)

| Anti-pattern | Why |
|--------------|-----|
| **Black-box “trust our memory”** | Your pitch is *inspectable* state—copying opaque memory UX undercuts it. |
| **Engagement-max dark patterns** | Infinite nudges, streaks, notification spam—wrong ICP. |
| **“Upload repo to our cloud by default”** | Violates sovereign positioning even if demos are faster. |
| **Second internal agent framework** | You already have a rich Rust loop; copying LangGraph-in-Rust duplicates cost. |
| **Discord moderation bot feature parity** | Wrong category ([MARKET_EVALUATION.md](MARKET_EVALUATION.md) §1 kill positioning). |

---

### 9.5 Prioritized backlog (suggested sequencing)

Map to existing roadmap where possible—this is **product judgment**, not a commitment file.

| Priority | Deliverable | Mostly **copy** from | Roadmap / doc anchor |
|----------|-------------|----------------------|----------------------|
| **P0** | Finish **first-run survival** (signed desktop when serious; until then, perfect PWA + OOTB wizard path) | macOS consumer apps, Open WebUI “it ran” moment | [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md), [PWA_ONBOARDING_WIZARD.md](PWA_ONBOARDING_WIZARD.md), [ROADMAP.md](ROADMAP.md) novice OOTB + **P5** |
| **P0** | **Suggested prompts / templates** on empty chat + Tasks tab | ChatGPT, Notion AI | Small `web/index.html` + copy in [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md) |
| **P1** | **Jobs / autonomy run log** in PWA (filter, status, deep link to episode or task) | n8n run history, GitHub Actions UI | Extend Dashboard; APIs exist (`/api/jobs`, pilot-summary) |
| **P1** | **Optional Docker Compose** “sidecar profile” (Ollama + Chump web only) for evaluators | LibreChat, LocalAI docs | Docs-only unless you want CI matrix cost |
| **P2** | **Documented “PR in a worktree” sponsor path** + one video or scripted GIF | OpenHands, Devin demos | [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) + repro kit |
| **P2** | **Mobile PWA pass** completion (matrix M1–M8 signed off) | Mobile-first SaaS | [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) **P5.2** |
| **P3** | **Optional MCP read-only bridge** (e.g. expose a *subset* of tools to an external client) *after* threat model | Cursor MCP ecosystem | New RFC only if sponsor demand clears [RFC-wp23](rfcs/RFC-wp23-mcp-sandboxscan-class.md) gates |

**2026 ecosystem review additions** (see [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) for full details):

| Priority | Deliverable | Source projects | Sprint |
|----------|-------------|-----------------|--------|
| **P0** | **Encrypted-at-rest SQLite** (`sqlcipher` in `db_pool.rs`) | IronClaw, OpenCoordex | A1 |
| **P0** | **WASM fuel metering** (in-process wasmtime fuel API) | Capsule | A2 |
| **P0** | **Tamper-evident audit chain** (SHA-256 hash chain) | OpenCoordex | A3 |
| **P1** | **Bradley-Terry ratings + skill mutation** | AutoEvolve, GEPA | B1-B2 |
| **P1** | **SKILL.md standard + clam-style result caching** | Hermes, ClamBot | B3-B4 |
| **P1** | **Security hardening** (leak scan, SSRF, secret pinning, MMR) | IronClaw, ClamBot, go-agent | C |
| **P2** | **`chump doctor` + OTel GenAI conventions** | Hermes, Rig, AgentMesh | D |

**Research that should drive reorder:** The 2026 ecosystem review adds the **Defense Trinity** (P0) and **Self-Improvement Loop** (P1) as high-priority items alongside existing backlog.
**Research that should drive reorder:** If interviews say “I’d pay for Docker one-liner” vs “I need PR sandbox,” promote **P1 Compose** vs **P2 worktree** accordingly ([MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md)).

---

### 9.6 Quick decision tree

```text
Is it mostly about trust / audit / policy?
  yes → BUILD in Chump core (tools, approvals, stack-status).
Is it about “first five minutes” fear?
  yes → COPY patterns (empty states, compose, suggested prompts).
Is it about model intelligence?
  yes → INTEGRATE (cascade, local, mistral.rs)—do not compete on weights.
Is it about connector breadth (Salesforce, …)?
  yes → DEFER or webhook out to iPaaS; document one reference pattern.
```

---

## 10. Changelog

| Date | Note |
|------|------|
| 2026-04-09 | Initial deep dive from pitch; links to market eval, proof docs, ADR-003. |
| 2026-04-10 | §9 **Build vs copy playbook**: tiers, anti-patterns, prioritized backlog, MCP gates, decision tree. |
| 2026-04-15 | §9.5 updated with [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) items: Defense Trinity (P0), Self-Improvement Loop (P1), Security Hardening (P1), Observability (P2) from 20-project ecosystem review. |

---

## Related

- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — ICP, §2 matrix, §2b scores, N-metrics  
- [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) — launch gates, lenses  
- [CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md) — external academic framing  
- [templates/pilot-invite-email.md](../templates/pilot-invite-email.md) — pilot comms shell  
- [RFC-wp13-mistralrs-mcp-tools.md](rfcs/RFC-wp13-mistralrs-mcp-tools.md) — tool registry vs MCP discovery  
- [RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md) — MCP scanner / bridge threat model  
