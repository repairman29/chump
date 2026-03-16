# Chump Fleet Roadmap — Consolidated

**Generated:** 2026-03-14 (Free-Tier Maximizer added 2026-03-15)
**Status:** All Sprints 1–4 (CLOSING_THE_GAPS) done. All capability improvements, bot capabilities, Turnstone phases 1–3, product/Cursor integration, roles, push/self-reboot — done. This file covers **everything that remains**.

**How to use this file:** Bots read this at round start. Pick from unchecked items by priority. Mark `- [ ]` → `- [x]` when done. One item at a time. Episode-log completions. Delegate to Cursor for implementation work.

**Reference docs:** CLOSING_THE_GAPS.md (design reference, all sprints done), RUST_INFRASTRUCTURE.md (design specs for infra items), FLEET_ROLES.md + PROPOSAL_FLEET_ROLES.md (fleet expansion specs), WISHLIST.md (backlog tools), TOP_TIER_VISION.md (long-term).

---

## Priority 0 — Free-Tier Maximizer (zero-cost 70B inference)

**Goal:** Stack 8 free cloud providers into the cascade → ~71,936 RPD of 70B-class inference at $0. Enables 5-minute heartbeat intervals instead of 45m, and cloud-quality responses for all interactive sessions.

**Math:** Heartbeat at 5m/8h = 192 RPD = **0.27% of total free budget**. We can run multiple bots, burst sprints, and 1-minute intervals trivially.

**Reference:** `docs/PROVIDER_CASCADE.md`, `FREE_TIER_MAXIMIZER_PLAN.md` (see Downloads).

**Code already done (2026-03-15):**
- [x] `MAX_SLOTS` bumped from 5 → 9 in `provider_cascade.rs`
- [x] RPD tracking added: `rpd_limit`, `calls_today`, `day_start` per slot; `within_rate_limit()` checks both RPM and RPD; `record_call()` increments both counters; cascade log shows `rpd=N/limit`
- [x] `CHUMP_PROVIDER_{N}_RPD` env var parsed in `from_env()`
- [x] `heartbeat-learn.sh` uses 5m interval when `CHUMP_CASCADE_ENABLED=1`
- [x] `.env.example` updated with all 8 provider slots + RPD vars + privacy notes
- [x] `docs/PROVIDER_CASCADE.md` rewritten with full 9-slot config, RPD docs, privacy routing
- [x] `scripts/check-providers.sh` shows RPM/RPD budget per slot

### Sprint F1: Wire It Up (~30 min, human action required)

**Goal:** Get all 8 providers live. Heartbeat immediately benefits from cloud quality + 5m intervals.

- [x] Sign up for **Cerebras**: https://cloud.cerebras.ai — grab API key → `csk_...`
- [x] Sign up for **Mistral**: https://console.mistral.ai/api-keys — grab API key (needs phone)
- [x] Sign up for **GitHub Models**: https://github.com/marketplace/models — use existing GitHub PAT
- [x] Sign up for **NVIDIA NIM**: https://build.nvidia.com — grab API key (needs phone)
- [x] Sign up for **SambaNova**: https://cloud.sambanova.ai — grab API key ($5 free credit)
- [x] Add all keys to `.env` using the 9-slot template in `.env.example`
- [x] Run `./scripts/check-providers.sh` — confirm all 8 cloud slots green
- [x] Run `CHUMP_LOG_TIMING=1 ./scripts/heartbeat-learn.sh` for 1 round — verify cascade selects Groq/Cerebras
- [x] Confirm heartbeat interval is now 5m (log line: `interval=5m`)

**Already have:** Groq key (slot 1), OpenRouter key (slot 4), Gemini key (slot 5).

### Sprint F2: Privacy Routing (~1 hour, Cursor task)

**Goal:** Hard-gate `trains`-tagged providers from work/code rounds. Prevents proprietary code reaching Mistral/Gemini free tiers.

- [x] Add `CHUMP_PROVIDER_{N}_PRIVACY=safe|caution|trains` env var to `ProviderSlot` in `provider_cascade.rs`
- [x] Parse `CHUMP_PROVIDER_{N}_PRIVACY` in `from_env()` (default `safe`)
- [x] Add `PrivacyTier` enum: `Safe`, `Caution`, `Trains`
- [x] `first_available_slot()` accepts optional `min_privacy: PrivacyTier` param; skips slots below threshold
- [x] Export `CHUMP_ROUND_PRIVACY=safe` from heartbeat when `CHUMP_HEARTBEAT_TYPE` is `work|cursor_improve|battle_qa`; cascade enforces it
- [x] Update `.env.example`: mark slots 3 (Mistral) and 5 (Gemini) with `CHUMP_PROVIDER_3_PRIVACY=trains`
- [x] Mark done in ROADMAP.md

### Sprint F3: Provider Dashboard (~1 hour, Cursor task)

**Goal:** Visibility into daily spend across all slots without digging through logs.

- [x] Add `GET /api/cascade-status` endpoint in `web_server.rs`: returns per-slot `{name, calls_today, rpd_limit, calls_this_minute, rpm_limit, circuit_state}`
- [x] Wire into PWA `/api/cascade-status` — show in Settings panel or a new "Providers" tab
- [x] Daily Discord DM summary: "Today: X Groq, Y Cerebras, Z Mistral, N local fallbacks" — add to `hourly-update-to-discord.sh` (or a new `daily-provider-summary.sh` cron)
- [x] Update `check-providers.sh` to include `calls_today` if runtime API is available
- [x] Mark done in ROADMAP.md

### Sprint F4: TaskAware Strategy (~2 hours, Cursor task)

**Goal:** Route round types to appropriate quality tier. Save expensive slots for code work; burn Mistral/OpenRouter for research/opportunity.

- [x] New `CascadeStrategy::TaskAware` enum variant in `provider_cascade.rs`
- [x] `TaskAware::first_available_slot()` reads `CHUMP_CURRENT_ROUND_TYPE` env var
- [x] Low-priority round types (`research`, `opportunity`, `discovery`) skip slots 1–2 (Groq/Cerebras); go directly to 3–4 (Mistral/OpenRouter)
- [x] High-priority types (`work`, `cursor_improve`, `battle_qa`) use full priority order
- [x] Heartbeat scripts export `CHUMP_CURRENT_ROUND_TYPE` before invoking the agent
- [x] Mark done in ROADMAP.md

### Sprint F5: Cloud-Only Headless Mode (~0.5 hour, config)

**Goal:** Heartbeat runs even when Mac is sleeping / Ollama is down. Cron job on Pixel or $0 cloud function drives rounds.

- [x] Verify heartbeat script tolerates `slot 0` being absent (preflight already handles `cascade:N` output — confirm)
- [x] Create `scripts/heartbeat-cloud-only.sh`: sets `CHUMP_CASCADE_ENABLED=1`, skips local model preflight, runs 5m/8h rounds using cloud-only cascade
- [x] Test: start with `OPENAI_API_BASE` unset, cascade enabled → should complete a round via Groq
- [x] Document "Mode B: Cloud-Only Heartbeat" in `docs/OPERATIONS.md`
- [x] Mark done in ROADMAP.md

### The $10 Play

- [x] Top up **OpenRouter** with $10 (one-time): https://openrouter.ai/credits — RPD jumps from 200 → 1,000 (5×). Highest single-dollar ROI in the stack.
- [x] Update `CHUMP_PROVIDER_4_RPD=1000` in `.env` after topup.

---

## Priority 1 — Rust Infrastructure (velocity & reliability)

These compound: proc macro makes tools fast to write, inventory eliminates registration, typestate prevents runtime bugs, pool prevents SQLITE_BUSY, notify makes file watching real-time. Do in order.

**Suggested sequence:** proc macro → inventory → typestate → pool → notify.

### Proc macro for tools (~1.5d)

- [x] Create a `chump-tool-macro` proc macro crate in the workspace.
- [x] Implement `#[chump_tool(name = "...", description = "...", schema = r#"..."#)]` attribute on impl block (generates name, description, input_schema; you provide execute).
- [x] Generate `name()`, `description()`, `input_schema()` with compile-time JSON schema validation.
- [x] Migrate one existing tool (`calc_tool`) as proof of concept; verify it compiles and tests pass.
- [x] Document usage pattern in RUST_INFRASTRUCTURE.md; update ROADMAP_FULL.md.

**Target:** ~30 lines per new tool instead of ~80. Pays off by the 4th tool.

### inventory tool registration (~0.5d) — **Done**

- [x] Add `inventory` crate to workspace dependencies.
- [x] Define `ToolEntry` struct with `fn new(factory: fn() -> Box<dyn Tool>)` and optional `when_enabled()`.
- [x] All tools (except MemoryTool) submitted in `tool_inventory.rs` via `inventory::submit! { ToolEntry::new(..., "sort_key").when_enabled(f) }`.
- [x] Replace manual registry list in `discord.rs` with `register_from_inventory(&mut registry)` + single MemoryTool registration.
- [x] Optional `is_enabled()` (env-based gating) via `when_enabled()`.
- [x] Update RUST_INFRASTRUCTURE.md; mark done in ROADMAP.md.

**Impact:** Eliminates "forgot to register" bugs. Enables Chump self-discovery (write a tool file → works on restart). Optional follow-up: move each `submit!` into the corresponding tool file.

### Typestate session lifecycle (~0.5d) — **Done**

- [x] Define `SessionState` trait and states: `Uninitialized`, `Ready`, `Running`, `Closed`.
- [x] Implement `Session<S: SessionState>` wrapper. Only `Session<Ready>` can `start()` → `Running`; only `Running` can `close()` → `Closed`.
- [x] Refactor `discord.rs` and `main.rs` to use typed session (`session.rs`; `chump_system_prompt(context)`; CLI gets `(Agent, Session<Ready>)`, calls start/close).
- [x] Impossible states (close twice, tools before assemble) do not compile.
- [x] Update RUST_INFRASTRUCTURE.md; mark done in ROADMAP.md.

**Impact:** Correctness for overnight autonomous runs.

### rusqlite connection pool (~0.5d) — **Done**

- [x] Add `r2d2` and `r2d2_sqlite` to workspace dependencies.
- [x] Create shared pool: `OnceLock<Pool<SqliteConnectionManager>>` with WAL + `PRAGMA busy_timeout=5000` in `src/db_pool.rs`.
- [x] Single `db_pool::get()` accessor; all DB modules use pool in production (test uses direct open for isolation).
- [x] Update RUST_INFRASTRUCTURE.md; mark done in ROADMAP.md.

**Impact:** Prevents SQLITE_BUSY under concurrent tool execution.

### notify file watcher (~0.5d) — **Done**

- [x] Add `notify` crate to workspace dependencies.
- [x] Implement `notify::recommended_watcher` in `src/file_watch.rs`; watcher thread sends paths to channel; `drain_recent_changes()` drains for "what changed since last run".
- [x] `assemble_context()` drains and injects "Files changed since last run (live):" (in addition to git diff).
- [x] Update RUST_INFRASTRUCTURE.md; mark done in ROADMAP.md.

**Impact:** Makes watch-style context real-time between heartbeat rounds.

---

## Priority 2 — Fleet / Mabel–Chump Symbiosis

These make Mabel a true peer. Do in order; each builds on the last.

### Mutual supervision (~0.5d)

- [ ] Verify Mac has `PIXEL_SSH_HOST` and `PIXEL_SSH_PORT` set; Pixel has `MAC_TAILSCALE_IP`, `MAC_SSH_PORT`, `MAC_CHUMP_HOME`.
- [ ] Verify Pixel SSH key is authorized on Mac.
- [ ] Both restart scripts (`restart-chump-heartbeat.sh`, `restart-mabel-heartbeat.sh`) run and exit 0 when heartbeats are up.
- [ ] Write `verify-mutual-supervision.sh` that checks all of the above and reports pass/fail.
- [ ] Document checklist in OPERATIONS.md under "Mutual supervision."
- [ ] Mark done in ROADMAP.md.

### Single fleet report (~0.5d)

- [ ] Confirm Mabel's `report` round produces a unified fleet report (both devices, task status, health, recent episodes).
- [ ] When Mabel report is stable and running on schedule: unload Mac hourly-update plist (`launchctl bootout ai.chump.hourly-update-to-discord`).
- [ ] Chump retains `notify` for ad-hoc alerts (blocked, PR ready) — not scheduled reports.
- [ ] Document in OPERATIONS.md under "Fleet reporting."
- [ ] Mark done in ROADMAP.md.

### Hybrid inference (~0.5d)

- [ ] Set `MABEL_HEAVY_MODEL_BASE` on Pixel pointing to Mac's Ollama (e.g. `http://<MAC_TAILSCALE_IP>:11434`).
- [ ] Research and report rounds on Mabel use Mac 14B model; patrol/intel/verify/peer_sync stay local (3B/4B).
- [ ] Test: Mabel research round completes using Mac model; falls back to local if Mac is unreachable.
- [ ] Document in OPERATIONS.md or ANDROID_COMPANION.md.
- [ ] Mark done in ROADMAP.md.

### Peer_sync loop (~0.5d)

- [ ] Mabel's `peer_sync` round reads Chump's last a2a reply and logs "Chump said: …" in episode.
- [ ] If the runtime doesn't inject a2a channel history: implement a tool or API to read the last a2a reply (e.g. query Discord channel or SQLite).
- [ ] `PEER_SYNC_PROMPT` in `heartbeat-mabel.sh` drives this behavior.
- [ ] Mark done in ROADMAP.md.

### Mabel self-heal (~0.5d)

- [ ] When `mabel-farmer.sh` detects Pixel `llama-server` or bot process is down, run local fix (e.g. `start-companion.sh`).
- [ ] Gate behind `MABEL_FARMER_FIX_LOCAL=1` env var.
- [ ] Document in `mabel-farmer.sh` header and OPERATIONS.md.
- [ ] Mark done in ROADMAP.md.

### On-demand status command (~0.5d)

- [ ] Mabel handles `!status` or "status report" in Discord (or a2a) by returning the unified fleet report on demand.
- [ ] Implementation: run report logic inline or read latest `mabel-report-*.md`.
- [ ] Mark done in ROADMAP.md.

---

## Priority 3 — Backlog Tools (close the loops)

From WISHLIST.md. These fill remaining capability gaps.

### screenshot + vision

- [ ] Implement headless screenshot capture (or use ADB `screencap` on Pixel).
- [ ] Pipe screenshot to vision API (or local vision model) for interpretation.
- [ ] Use cases: verify UI state, read error dialogs, confirm deployment success.
- [ ] Register tool; add to routing table.

### introspect tool

- [ ] Query recent tool-call history from tracing spans (or tool_health_db).
- [ ] Ground truth vs episodes — "what did I actually do last session?"
- [ ] Depends on: tracing span DB (optional subscriber layer → SQLite). Can start with tool_health_db queries as interim.
- [ ] Register tool; add to routing table.

### sandbox tool

- [ ] Clean copy of working tree (cp or Docker), run commands, teardown.
- [ ] No pollution of the real working tree.
- [ ] Use cases: try risky refactors, test dependency upgrades, run untrusted code.
- [ ] Register tool; add to routing table.

---

## Priority 4 — Fleet Expansion (next horizon)

From FLEET_ROLES.md and PROPOSAL_FLEET_ROLES.md. These transform the fleet from "agents building agents" into a personal operations team. **Critical path: Chump Web PWA is the gateway** — most items below depend on it.

### Tier 1 — Ship first (highest ROI)

#### Chump Web PWA (Tier 2) — THE GATEWAY

**Spec:** [docs/PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md). Execute phases in order; mark items there and here as done.

- [x] **Phase 1.1** — Sessions + history: POST/GET/DELETE/PUT `/api/sessions`, GET `/api/sessions/:id/messages`; persist user + assistant messages on chat; session sidebar in PWA (backend then frontend).
- [x] **Phase 1.2** — File attachments: POST `/api/upload`, GET `/api/files/:id`; extend chat with `attachments`; attach UI + drag/paste.
- [x] **Phase 1.3** — Slash commands: client palette; `/task`, `/tasks`, `/status`, `/briefing`, etc.; backend `bot` field on `/api/chat`.
- [x] **Phase 1.4** — Message actions: copy, retry, stop generating, scroll FAB, timestamps, link detection.
- [x] **Phase 1.5** — Bot switcher: Chump vs Mabel in header; bot field on chat.
- [x] **Phase 2.1** — Task management: GET/POST/PUT/DELETE `/api/tasks`; Tasks tab in sidecar.
- [x] **Phase 2.2** — Quick capture: POST `/api/ingest`; capture modal (upload/paste/URL/photo).
- [x] **Phase 2.3** — Briefing: GET `/api/briefing`; briefing view/tab (tasks + episodes).
- [x] **Phase 2.4** — Research: POST/GET `/api/research`, GET `/api/research/:id`; research tab.
- [x] **Phase 2.5** — Watchlists: GET/POST/DELETE `/api/watch`, GET `/api/watch/alerts`; Watch tab.
- [x] **Phase 2.6** — Projects: GET/POST `/api/projects`, POST `/api/projects/:id/activate`.
- [x] **Phase 3.1** — Web push: subscribe/unsubscribe, VAPID (store subscriptions; send path optional).
- [x] **Phase 3.2** — Offline: SW cache sessions/tasks/briefing; offline banner (queue optional).
- [x] **Phase 4** — Polish: settings panel, keyboard shortcuts (responsive/a11y/haptics optional).
- [x] **Phase 5** — iOS Shortcuts: `/api/shortcut/*` endpoints + docs/IOS_SHORTCUTS.md.

Replaces Discord as primary interface. Unlocks: everything in Tier 1–3 below.

#### Research pipeline (~2–3d) — depends on PWA for triggering/viewing

- [ ] "Research X for me" → multi-pass research with plan → synthesize → brief in brain (`research/`).
- [ ] Chump orchestrates; can delegate sub-questions to Mabel via task create + `message_peer`.
- [ ] Push notification: "Research brief on [thing] is ready."
- [ ] New heartbeat round type: `research_brief` (synthesize what Mabel collected).

#### Quick capture (~1d) — depends on PWA

- [ ] iPhone → iOS Shortcut "Hey Siri, capture for Chump" → photo or dictation.
- [ ] HTTP POST to Chump Web `/api/ingest`.
- [ ] Chump processes (OCR, transcribe, summarize) → stores in brain (`capture/`).
- [ ] Use cases: whiteboard photos, receipts, business cards, ideas.

#### External project work (~1d)

- [ ] `CHUMP_REPO` can point at other projects (infrastructure already supports this).
- [ ] `project` command or env switch; heartbeat round reads from a projects list in brain (`projects/`).
- [ ] Chump does real work on non-Chump repos.

### Tier 2 — Ship next (high value, medium effort)

#### Brain watchlists + Mabel watch rounds (~2d)

- [ ] `watch/deals.md` — price/deal tracking. Mabel `deal_watch` round: check prices via web_search + read_url, notify on threshold.
- [ ] `watch/finance.md` — stocks/crypto watchlist. Mabel `finance_watch` round: check prices, threshold alerts, store historical data.
- [ ] `watch/github.md` — repos to monitor. Mabel `github_watch` round: new issues, PRs, releases, comments. Create tasks for Chump if action needed.

#### Morning briefing (~1d) — depends on PWA for push, watchlists for content

- [ ] Mabel synthesis round: overnight work summary, weather, calendar, news on configured topics, task queue for Jeff.
- [ ] Push notification to iPhone lock screen; tap → PWA full briefing.
- [ ] `news_brief` round type on Mabel.

#### GitHub watcher (~1d)

- [ ] Mabel monitors starred repos for new releases, your repos for new issues/PRs/comments.
- [ ] Summarize → notify + task create for Chump if action needed.

#### iOS Shortcut triggers (~0.5d each)

- [ ] Pre-built shortcuts: deploy, run tests, status report, create task, check on Chump, check on Mabel.
- [ ] Each shortcut = HTTP POST to Chump Web API.
- [ ] "Hey Siri, deploy to production."

### Tier 3 — Build when foundation is solid

- [ ] **Task routing with assignee** — auto-route to right agent or Jeff. (Assignee column exists; routing logic needed.)
- [ ] **Calendar integration** (~2d) — Google Calendar API or shared iCal; smart reminders with brain context.
- [ ] **Learning assistant** (~1d) — `learning_goals` in ego; Mabel finds resources; Chump creates practice tasks; weekly brief.
- [ ] **Review round** — Chump checks GitHub notifications, reviews PRs, responds to comments. New heartbeat round type.

### Tier 4 — Long-term

- [ ] **Phone automation recipes** — ADB closed-loop: screencap → OCR → decide → input. Recipes in brain.
- [ ] **HomeKit bridge** — voice → Chump → home control.
- [ ] **Health data trends** — HealthKit export → Chump analysis.

---

## Priority 5 — Long-term Vision (TOP_TIER_VISION.md)

Not actionable now. Track for when the foundation is ready.

- [ ] In-process inference (mistral.rs) — eliminate Ollama overhead.
- [ ] eBPF observability — kernel-level tracing of agent behavior.
- [ ] Managed browser (Firecrawl) — full web interaction beyond read_url.
- [ ] Stateless task decomposition — break large tasks into parallelizable units.
- [ ] JIT WASM tools — compile tools to WASM for sandboxed, portable execution.

---

## Completed (reference only)

Everything below is done. Kept for context; do not re-work.

- [x] **Sprints 1–4** (CLOSING_THE_GAPS): assemble_context, close_session, trim notice, schedule integration, config validation, task priority, schedule check, time/round awareness, morning report, PR follow-up, tool health DB, git_stash/revert, sanity_check_reply, episode sentiment, exit 127 recording, watch-style context, ask_jeff tool + DB.
- [x] **Capability improvements:** summarize-and-trim, soul reorder, context round filter, delegate classify/validate, read_file auto-summary, run_cli middle-trim.
- [x] **Bot capabilities:** intent inference, intent→action patterns, reduce over-asking, reply quality/speed.
- [x] **Push & self-reboot:** GitHub integration, self-reboot script, CHUMP_AUTO_PUSH.
- [x] **Product & Chump–Cursor:** rules, AGENTS.md, protocol doc, cursor_improve rounds, handoff format.
- [x] **Implementation/speed/quality:** unwrap() cleanup, TODOs, battle QA, clippy, speed, quality conventions.
- [x] **Roles:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender — all on launchd.
- [x] **Turnstone phases 1–3:** observability, safety (tool approval), resilience/governance (circuit breaker).
- [x] **Backlog tools:** run_test, read_url, task routing (assignee).
- [x] **Rust infra (partial):** Tower middleware (timeout + health + circuit), tracing (events + instrument, chump_log kept).
- [x] **Optional integrations:** GitHub, ADB tool.

---

## When you complete an item

1. Check the box in this file: `- [ ]` → `- [x]`.
2. If it was a task, set task status to done and episode log.
3. Optionally notify if something is ready for review.
4. Update relevant docs (RUST_INFRASTRUCTURE.md, OPERATIONS.md, etc.).
