# Pragmatic full roadmap — what we can actually build

**Purpose:** One ordered plan for work that is **technically feasible** on this repo, this stack, and typical hardware. It **filters** [ROADMAP_FULL.md](ROADMAP_FULL.md) (which mixes done history with backlog) and **grounds** [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) frontier items in honest gates.

**How to use:** Pick the **next unchecked item in your current phase** (A → B → …). When something ships, check it in [ROADMAP.md](ROADMAP.md) and optionally here. For Chump–Cursor handoffs, cite the **phase + item id** (e.g. “B2 task contract”).

**What this is not:** A promise to build everything below in order. Phases can overlap once **gates** are met (e.g. you can do C1 while B3 is in progress if you have two devices).

---

## Principles

1. **Ship vertical slices** — Each milestone should leave the system *observably* better (logs, tests, or user-visible behavior), not just more abstractions.
2. **Prefer code + tests over docs-only** — Docs updates follow shipping; they do not replace shipping.
3. **Environment gates are real** — Fleet items need Mac + Pixel (or equivalent) and SSH/Tailscale; skip phase C until A and B are healthy on one machine.
4. **Research stays gated** — Quantum cognition, TDA-as-Φ, reversible-computing energy claims: see [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) §3; **do not** schedule as product work until a cheap experiment passes its stated gate.

---

## Snapshot: already shipped (do not re-plan)

These exist in `src/` and are wired enough for production paths; extend them, do not restart them.

| Area | Status |
|------|--------|
| Discord bot, tools, approval, circuit breaker, health | Shipped |
| PWA / web sessions, tasks API, cascade, roles scripts | Shipped |
| Consciousness stack (surprise, blackboard, memory graph PPR+LLM, belief, precision, counterfactual, neuromod thresholds, holographic sync) | Shipped |
| `chump --rpc`, `chump --autonomy-once`, task **leases** (`task_db` + `autonomy_loop.rs`), `--reap-leases` | Shipped |
| Battle QA + consciousness baseline gate | Shipped |

**Gap (closed):** Lease locking, autonomy conformance, CI, and ops docs are reflected in [ROADMAP.md](ROADMAP.md) (2026-04-10).

---

## Phase A — Reliability and observability (single machine, always possible)

**Gate:** None. **Outcome:** Fewer silent failures; easier debugging when vLLM/Ollama flaps.

| Id | Work | Notes |
|----|------|--------|
| A1 | **Inference stability playbook** — Document and script: OOM backoff, smaller model / `max_num_seqs`, Farmer Brown behavior when 8000 is down. Link [GPU_TUNING.md](GPU_TUNING.md), [STEADY_RUN.md](STEADY_RUN.md). | [x] **`docs/INFERENCE_STABILITY.md`** + [OPERATIONS.md](OPERATIONS.md) link. |
| A2 | **Introspect v1** — Tool or `/health` field: last N tool calls from `chump_tool_calls` (and/or `chump_tool_health`). | [x] **`GET /health` → `recent_tool_calls`** (15 rows); `introspect` tool unchanged. |
| A3 | **Tracing phase 2 (optional)** — Persist span summaries or expand `#[instrument]` coverage for hot paths. | [x] **`#[instrument]`** on `ChumpAgent::run`, `execute_tool_calls_with_approval`, `StreamingProvider::complete`, `autonomy_once` / `autonomy_once_impl`. Span persistence still optional. |
| A4 | **Keep battle QA + clippy green in CI** — Ensure PR checks run `cargo test` subset + clippy; document in CONTRIBUTING or OPERATIONS. | [x] **`.github/workflows/ci.yml`** + **`CONTRIBUTING.md`**. |

**Maps to:** ROADMAP “implementation, speed, quality”; ROADMAP_FULL P3 introspect (partial).

---

## Phase B — Autonomy that closes the loop (repo-only, highest product ROI)

**Gate:** A4 acceptable (tests run locally). **Outcome:** Tasks move `open → in_progress → done` with verification, without inventing new science.

| Id | Work | Notes |
|----|------|--------|
| B1 | **Task contract** — Structured notes: Context / Plan / Acceptance / Verify / Risks; template on create; deterministic parse helpers + tests. | [x] **`task_contract.rs`** + task tool; accessors `context` / `plan` / `risks`. |
| B2 | **Planner → Executor → Verifier** — One bounded loop: pick task, plan in notes, execute with tools, run `run_test` / checks from Verify section, set `done` or `blocked` + episode. | [x] **`autonomy_loop::autonomy_once`**. |
| B3 | **Lease hardening** — Document lease fields; integration test: two workers, second cannot claim same task; document `CHUMP_AUTONOMY_OWNER`. | [x] **`task_lease_second_owner_cannot_claim_until_released`**; OPERATIONS + `.env.example`. |
| B4 | **Autonomy conformance tests** — Deterministic mini-scenarios in CI (temp dir, mock-friendly tools). | [x] Existing **`autonomy_loop`** tests + lease test; **GitHub Actions** `cargo test`. |
| B5 | **RPC driver polish** — Cron script persists JSONL events; optional low-risk auto-approve policy behind env flag. | [x] **`CHUMP_RPC_JSONL_LOG`**; **`autonomy-cron.sh`**; **`CHUMP_AUTO_APPROVE_LOW_RISK`** + **`CHUMP_AUTO_APPROVE_TOOLS`** (audit in `tool_approval_audit`). |

**Maps to:** ROADMAP “Autonomy” section; AUTONOMY_ROADMAP.md milestones 1–3.

---

## Phase C — Fleet symbiosis (two machines + network)

**Gate:** B3 or B4 started (you trust autonomy enough to run on a schedule). **Outcome:** Mac and Pixel back each other; one fleet report; hybrid inference.

| Id | Work | Notes |
|----|------|--------|
| C1 | **Mutual supervision checklist** — Env vars, SSH, restart scripts exit 0; `verify-mutual-supervision.sh`; OPERATIONS.md section. | [x] **`scripts/verify-mutual-supervision.sh`** + OPERATIONS **Mutual supervision** + validation gate. |
| C2 | **Single fleet report** — Mabel report as source of truth; retire duplicate Mac hourly report when stable. | [x] **OPERATIONS** done criterion + **`scripts/retire-mac-hourly-fleet-report.sh`**. |
| C3 | **Hybrid inference** — `MABEL_HEAVY_MODEL_BASE` → Mac 14B; fall back locally. | [x] **`heartbeat-mabel.sh`** + **OPERATIONS** Hybrid inference; **`.env.example`** Pixel block. |
| C4 | **Peer_sync** — Read `chump-brain/a2a/chump-last-reply.md` (or tool) into Mabel episode; align `PEER_SYNC_PROMPT`. | [x] **`record_last_reply`** + **`PEER_SYNC_PROMPT`** (`memory_brain read_file a2a/chump-last-reply.md`). |
| C5 | **Mabel self-heal** — `mabel-farmer.sh` + `MABEL_FARMER_FIX_LOCAL`. | [x] **`mabel-farmer.sh`** (default **FIX_LOCAL=1**). |
| C6 | **On-demand `!status`** — Unified report from Discord/a2a. | [x] **Chump + Mabel** Discord: **`!status`** / **`status report`** → latest `mabel-report-*.md` or guidance. |

**Maps to:** ROADMAP “Fleet / Mabel–Chump”; ROADMAP_FULL Priority 2.

---

## Phase D — Product expansion (PWA and brain workflows)

**Gate:** PWA running for your use case. **Outcome:** Less Discord friction; repeatable research/capture flows.

| Id | Work | Notes |
|----|------|--------|
| D1 | **Research pipeline** — Multi-pass “research X” → brief in `brain/research/`; optional notify. | [x] **Baseline:** `/api/research` + **`RESEARCH_BRIEF_PROMPT`** / research rounds → **`research/latest.md`**. Optional notify + one-shot “Research X” UI still incremental. |
| D2 | **Quick capture hardening** — Shortcut → `/api/ingest` → brain `capture/`; OCR/transcribe optional later. | [x] **512 KiB** cap, **`source`** field, PWA + shortcut; OCR/transcribe still future. |
| D3 | **External repo work** — Heartbeat reads `projects/` list; `CHUMP_REPO` switching documented. | [x] **Docs:** [CHUMP_BRAIN.md](CHUMP_BRAIN.md) External repos; prompts already use **`projects/`** + **`set_working_repo`**. |
| D4 | **Watchlists** — `watch/*.md` + Mabel rounds (deals / finance / github). | [x] **`/api/watch/alerts`** + briefing + **INTEL_PROMPT** `watch/` pass; flag markers documented in [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md). |
| D5 | **Morning briefing + push** — Synthesis round + notification. | [x] **`/api/briefing`** extended + **`scripts/morning-briefing-dm.sh`**. Web Push “briefing ready” still optional. |

**Maps to:** ROADMAP_FULL Priority 4 (Tier 1–3).

---

## Phase E — Tools and safety (medium effort, clear scope)

**Gate:** B2 partial (agent runs multi-step tool batches reliably).

| Id | Work | Notes |
|----|------|--------|
| E1 | **Screenshot + vision** — ADB `screencap` or Mac capture → vision API; one use case (e.g. “what’s on screen”). | ROADMAP_FULL P3; privacy + cost gate. |
| E2 | **Sandbox tool** — Git worktree or temp clone; run command; summarize; teardown. | [x] **`sandbox_run`** ([`src/sandbox_tool.rs`](src/sandbox_tool.rs)); `CHUMP_SANDBOX_ENABLED=1`; tests; see [`ROADMAP_REMAINING_GAPS.md`](ROADMAP_REMAINING_GAPS.md) for hardening + ADR G2 backlog. |

**Maps to:** ROADMAP wishlist; WISHLIST.md.

---

## Phase F — Consciousness: finish the wiring (optional, bounded)

**Gate:** Someone cares about metrics dashboards or research demos. **Outcome:** Fewer “dead” exports; honest benchmarks.

| Id | Work | Notes |
|----|------|--------|
| F1 | **Wire `reward_scaling()` into `surprise_tracker`** — Learning rate scales with dopamine proxy; test + METRICS.md note. | [x] **`surprise_tracker::record_prediction`** scales EMA alpha by `neuromodulation::reward_scaling()`; tests + METRICS. |
| F2 | **Wire `salience_modulation()` into blackboard `SalienceFactors::score`** (or document why not). | [x] **Default on**; `CHUMP_NEUROMOD_SALIENCE_WEIGHTS=0` disables. |
| F3 | **Memory graph benchmark** — Small curated set; recall@k; script in `scripts/`. | [x] **`cargo test memory_graph_curated_recall_topk`** (default CI) + **`scripts/memory-graph-benchmark.sh`** (timing; ignored `associative_recall_benchmark`). |
| F4 | **Speculative execution** — Either wire behind a tool/flag with **real** rollback (incl. blackboard restore) or keep prototype-only and remove from “shipped” narrative. | [x] **`agent_loop`**: when **≥3** tools in one batch, **`fork` / `evaluate` / `commit|rollback`** ([`src/agent_loop.rs`](src/agent_loop.rs)). **`rollback()`** restores beliefs, neuromod, blackboard (+ subscriptions); **does not** undo filesystem/DB/network tool effects. Disable: **`CHUMP_SPECULATIVE_BATCH=0`**. |
| F5 | **Adaptive regime thresholds** — Simple bandit or moving average on task success; env-gated. | [x] **`CHUMP_ADAPTIVE_REGIME=1`** + rolling window in `precision_controller`; **`task_db::task_update_status`** records **`done`** (success) and **`blocked`** (failure). **`abandoned`** and other statuses **do not** update the window (neutral). |
| F6 | **Lesson upgrade** — Causal graph output feeds `chump_causal_lessons` instead of only heuristics. | [x] **`persist_causal_graph_as_lessons`** + **`analyze_episode`** persists heuristic graph edges. |

**Maps to:** CHUMP_TO_COMPLEX Section 2 remaining bullets; ROADMAP “Chump-to-Complex” Section 3 only if gates pass.

---

## Phase G — Frontier (explicitly deprioritized for product)

Only after F1–F3 show measurable value **or** a dedicated research week.

| Id | Work | Gate (from CHUMP_TO_COMPLEX) |
|----|------|------------------------------|
| G1 | Quantum cognition toy (density matrix tool choice) | \>5% on synthetic multi-choice benchmark (likely fails — OK). |
| G2 | TDA on blackboard traffic | Correlates better than phi_proxy with task success. |
| G3 | Workspace merge (fleet blackboard) | C1–C4 stable. |

**Maps to:** CHUMP_TO_COMPLEX §3; ROADMAP unchecked frontier lines.

---

## Phase I — Repo hygiene and storage (periodic, low urgency)

**Gate:** None. **Outcome:** Long-running clones stay small and recoverable; no loss of *project* context (git + docs) while trimming local/runtime bulk.

**Baseline (already in repo):** [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md), `scripts/cleanup-repo.sh`, `.cursorignore`. Pick these when disk, backups, or “ancient clone” maintenance matters.

| Id | Work | Notes |
|----|------|--------|
| I1 | **Embed cache hygiene** — Document or script safe pruning of `.fastembed_cache/` (`inprocess-embed`); trade-off: disk vs re-download on next embed use. | [x] **[STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md)** § In-process embed cache. |
| I2 | **Git maintenance runbook** — When/how to run `git gc`; spotting huge history or accidental large blobs; maintainer-only. | [x] **[STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md)** § Git maintenance. |
| I3 | **Quarterly cold export** — Runbook + checklist: archive `sessions/`, `logs/`, and an explicit **`chump-brain/`** subset (or full) to cold storage; one-page restore / verify. | [x] **[STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md)** § Quarterly cold export. |

**Maps to:** [ROADMAP.md](ROADMAP.md) “Repo hygiene and storage”.

---

## Phase H — “Someday” (platform / research hardware)

Not scheduled. Track in [TOP_TIER_VISION.md](TOP_TIER_VISION.md): mistral.rs in-process, eBPF, managed browser, JIT WASM, HomeKit, etc.

---

## Recommended default order (if you have one Mac and the repo)

1. **A2** → **B1** → **B2** → **B3/B4** (parallel OK) → **B5**  
2. Then **C1–C6** (fleet symbiosis) when Pixel + network are in play — **C1–C6 shipped** in repo/docs as of 2026-04; operational unload of Mac hourly-update is still a human step when you declare report stable.  
3. Then **D1–D5** (PWA/brain slice — **D1–D5 baseline shipped**); **E1–E2** when autonomy is trustworthy.  
4. **F\*** as needed; **G\*** only with explicit time box.  
5. **I\*** (storage / git / quarterly export) on a **calendar** or when disk is tight—not blocking product work.

---

## Maintenance

- **Owner:** Human + Chump episode log; Cursor implements by phase item.
- **Reconcile quarterly:** Compare this file to [ROADMAP.md](ROADMAP.md) checkboxes; fix drift (e.g. autonomy leases). Optionally run **Phase I** items (storage / export runbook) on the same rhythm. Cross-check [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **§ Backlog coverage** so no open source is orphaned.
- **Version:** 2026-04-09 (Phase D baseline: capture + docs + research API/heartbeat). **Phase I** added 2026-04-09 (repo hygiene backlog). **ROADMAP_SPRINTS** linked 2026-04-09. Update when a phase gate changes or a major subsystem ships.
