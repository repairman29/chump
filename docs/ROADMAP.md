# Chump roadmap

**This file is the single source of truth for what to work on.** Doc index: [README.md](README.md). For a **sectioned map** of every roadmap doc (phases, vision, fleet, metrics), see [ROADMAP_MASTER.md](ROADMAP_MASTER.md). Heartbeat (work, opportunity, cursor_improve rounds), the Discord bot, and Cursor agents should read this file—and `docs/CHUMP_PROJECT_BRIEF.md` for focus and conventions—to know what they're doing. Do not invent your own roadmap; pick from the unchecked items below, from the task queue, or from codebase scans (TODOs, clippy, tests).

**Ordered achievable plan:** For a full phased backlog (what is realistic on one machine vs fleet vs research), read [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) (phases A–G, I, H). Use it when choosing *what to do next*; use this file to *check boxes* when work merges.

**Single vision:** For the one goal and the order to build/deploy the ecosystem (Horizon 1 → 2 → 3), see [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md). Use it to align this roadmap with fleet roles and deployment.

**North star:** Roadmap and focus should improve **implementation** (ship working code and docs), **speed** (faster rounds, less friction, quicker handoffs), **quality** (tests, clippy, error handling, clarity), and **bot capabilities**—especially **understanding the user in Discord and taking action from intent** (infer what they want from natural language; create tasks, run commands, or answer without over-asking).

## How to use this file

- **Full prioritized backlog:** The consolidated list of everything that remains (Priority 1–5) is in [ROADMAP_FULL.md](ROADMAP_FULL.md). Bots read it at round start; pick from unchecked items by priority.
- **Chump (heartbeat / Discord):** In work rounds, use the task queue first; when the queue is empty or in opportunity/cursor_improve rounds, read this file and `docs/CHUMP_PROJECT_BRIEF.md`, then create tasks or do work from the unchecked items (or from ROADMAP_FULL.md).
- **Cursor (when Chump delegates or you're in this repo):** Read this file and `docs/CHUMP_PROJECT_BRIEF.md` when starting. Pick implementation work from the roadmap priorities or from the prompt Chump gave you. Align with conventions in CHUMP_PROJECT_BRIEF and `.cursor/rules/`.

### Aspirational: Claude-tier core upgrades

Long-horizon architecture backlog (semantic context vs summarization, smarter edits, task-driven autonomy continuations, structured reasoning, delegate preprocessing of huge tool output): **[ROADMAP_CLAUDE_UPGRADE.md](ROADMAP_CLAUDE_UPGRADE.md)**. Reference only until individual tasks there are implemented and checked off (optionally mirror adopted work as items in this file).

## Current focus (align with CHUMP_PROJECT_BRIEF)

- **Implementation, speed, quality, bot capabilities:** Prioritize work that improves what we ship, how fast we ship it, how good it is, and how well the Discord bot understands and acts on user intent (NLP / natural language).
- Improve the product and the Chump–Cursor relationship: rules, docs, handoffs, use Cursor to implement.
- Task queue and GitHub (optional): create tasks from Discord or issues; use chump/* branches and PRs unless CHUMP_AUTO_PUBLISH is set.
- Keep the stack healthy: Ollama, embed server, battle QA self-heal, autonomy tests. **Run the roles in the background:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender (Chump Menu → Roles tab; schedule with launchd/cron per docs/OPERATIONS.md).
- **Fleet expansion:** Chump external work, research rounds, review round; Mabel watch rounds; Scout/PWA as primary interface — see [FLEET_ROLES.md](FLEET_ROLES.md).
- **Long-term vision:** In-process inference (mistral.rs), eBPF observability, managed browser (Firecrawl), stateless task decomposition, JIT WASM tools — see [TOP_TIER_VISION.md](TOP_TIER_VISION.md).

### Product: Chief of staff (COS) — autonomous staff + product factory

Product vision, **60 user stories**, phased waves (instrument → close the loop → discovery factory → adjacent products): **[PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md)**. Weekly snapshot script: **`./scripts/generate-cos-weekly-snapshot.sh`** → `logs/cos-weekly-*.md`.

**Wave 1 (instrument):**
- [x] COS weekly Markdown snapshot from `chump_memory.db` (`scripts/generate-cos-weekly-snapshot.sh`).
- [x] Schedule snapshot: `cos-weekly-snapshot.plist.example` + `./scripts/install-roles-launchd.sh` (Monday 08:00); unload in `unload-roles-launchd.sh`.
- [x] `[COS]` task template in [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md); heartbeat context injects latest `logs/cos-weekly-*.md` on COS-oriented rounds (`context_assembly`).
- [x] ChumpMenu README links to [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md).

**Wave 2 (COS close the loop) — partial:**
- [x] **W2.1** Weekly COS heartbeat: `scripts/heartbeat-self-improve.sh` runs **`WEEKLY_COS_PROMPT`** on Mondays (local, 05:00–22:00) once per day (`logs/.weekly-cos-last-run`); disable with `CHUMP_WEEKLY_COS_HEARTBEAT=0`. Context type **`weekly_cos`** gets COS snapshot injection (`context_assembly`).
- [x] **W2.2** Interrupt notify policy: **`CHUMP_INTERRUPT_NOTIFY_POLICY=restrict`**, **`CHUMP_NOTIFY_INTERRUPT_EXTRA`**, `src/interrupt_notify.rs`, `docs/COS_DECISION_LOG.md`; context hint in `assemble_context`.
- [x] **W2.3** Decision log: **`docs/COS_DECISION_LOG.md`** (brain-relative `cos/decisions/YYYY-MM-DD.md` + template + interrupt tags).
- [x] **W2.4** ChumpMenu Chat tab: streaming `/api/chat` + **Allow once / Deny** → `POST /api/approve` (same bearer as chat).

**Wave 3 (discovery factory) — scripts landed:**
- [x] **W3.1** `scripts/github-triage-snapshot.sh` + **W3.2** `scripts/ci-failure-digest.sh` (SHA dedupe file) + **W3.3** `scripts/repo-health-sweep.sh` (`REPO_HEALTH_AUTOFIX=1`) + **W3.4** `scripts/golden-path-timing.sh` (CI artifact + relaxed limit in [.github/workflows/ci.yml](../.github/workflows/ci.yml)).

**Wave 4 (adjacent products / COS factory):**
- [x] **W4.1** [PROBLEM_VALIDATION_CHECKLIST.md](PROBLEM_VALIDATION_CHECKLIST.md) · **W4.2** `scripts/scaffold-side-repo.sh` + `templates/side-repo/` · **W4.3** [templates/cos-portfolio.md](templates/cos-portfolio.md) · **W4.4** `scripts/quarterly-cos-memo.sh`

### Market wedge and pilot metrics (H1 + market demands plan)

Single index: [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §8. Supporting docs and scripts:

- [x] Pilot SQL / API / JSONL recipes for N3–N4: [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md)
- [x] Golden path extension (PWA task + optional `autonomy_once`): [WEDGE_H1_GOLDEN_EXTENSION.md](WEDGE_H1_GOLDEN_EXTENSION.md), [scripts/wedge-h1-smoke.sh](../scripts/wedge-h1-smoke.sh)
- [x] Intent calibration harness (labeled set + procedure): [INTENT_CALIBRATION.md](INTENT_CALIBRATION.md)
- [x] Model flap drill (reliability acceptance): [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) (Model flap drill)
- [x] Public trust summary + diagram (speculative rollback limits): [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md)
- [x] PWA-first H1 path audit (no Discord required for wedge): [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md)
- [x] PWA **in-app** discoverability for task create / wedge hint — [web/index.html](../web/index.html) Tasks panel + [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md)
- [x] **N4 pilot export:** `GET /api/pilot-summary` + [scripts/export-pilot-summary.sh](../scripts/export-pilot-summary.sh) + [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) + [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md)
- [x] **Phase 2 market critique (docs):** [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §2b baseline scores, §4.2 sprint tracker, §4.4 progress line; [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) quarterly pass; README troubleshooting; [CONTRIBUTING.md](../CONTRIBUTING.md) repro
- [x] **Phase 2 research scaffolding:** evidence tables + blind scratch pad in [MARKET_RESEARCH_EVIDENCE_LOG.md](docs/MARKET_RESEARCH_EVIDENCE_LOG.md); §4.2/§4.4 cross-links in [MARKET_EVALUATION.md](docs/MARKET_EVALUATION.md) (sessions themselves still tracked below).
- [ ] **Phase 2 research execution:** complete **≥5** blind sessions (log B1–B5) + **≥8** interviews (fill MARKET_EVALUATION §4.4); then refresh §2b scores from evidence. **Evidence tables:** [MARKET_RESEARCH_EVIDENCE_LOG.md](MARKET_RESEARCH_EVIDENCE_LOG.md). **Sprint:** [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **S1**.

## Universal power / daily driver (full program)

**Goal:** Make Chump **reliable, reachable, governable, context-rich, and polished** enough to serve as a **primary execution layer** (overcome “hobby stack” limits). **Authoritative pillar backlog and acceptance criteria:** [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) (items **P1.x–P5.x**).

**Rollup — check a box when that pillar’s exit criteria in that doc are met:**

- [x] **P1 — Reliability boring** — green-path + preflight + CI + degraded UX matrix + **`turn_error` hints** + **local OpenAI retry/circuit doc** (**P1.5–P1.6** done in [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md)).
- [x] **P2 — Reach** — **P2.1–P2.5** shipped in [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) (Web Push MVP, async jobs, webhook hardening, cron snippets, repo profiles). **Stretch:** **P2.6** remote runner RFC/MVP.
- [x] **P3 — Governance** — **P3.1–P3.5** shipped (approval parity, baseline approve tests + policy overrides + audit export + autopilot controls). **Optional tighten:** full **P3.2** SSE-continues-after-approve e2e behind stub provider; dedicated filterable audit **page**.
- [x] **P4 — Compounding context** — **P4.1–P4.5** shipped ([CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md), session limits doc, optional LLM e2e flag, task spine hints, COS decisions API + PWA). **Optional:** automated long-thread soak.
- [ ] **P5 — Product polish** — **P5.2** mobile pass done (touch targets, sidecar overlay, drawer responsive, input/approval compacted); **P5.3** parity matrix done; **P5.4** turn_error copy done. **Remaining:** **P5.1** onboarding (partial: PWA bar + Settings + step track — [PWA_ONBOARDING_WIZARD.md](PWA_ONBOARDING_WIZARD.md), needs pilot friction log rows); **P5.5** signed/notarized distribution ([PACKAGING_AND_NOTARIZATION.md](PACKAGING_AND_NOTARIZATION.md), needs Apple Developer cert).

**Execution order:** P1 → P2 → P3 → P4 → P5 (see dependency notes in [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md)).

### Architecture vs proof (sustained use)

External reviews often praise **runtime depth** (cascade, context assembly, approvals, consciousness, speculative batches) while warning **“built but not proven.”** The roadmap already tracks most *features*; this block tracks **evidence** so claims stay tied to the repo and [DAILY_DRIVER_95_STEPS.md](DAILY_DRIVER_95_STEPS.md).

| Review theme | Already in roadmap / docs | Gap to close |
|--------------|---------------------------|--------------|
| Policy-driven cascade, privacy, regimes | P1–P4, [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md), [CONTEXT_PRECEDENCE.md](CONTEXT_PRECEDENCE.md) | Keep green; extend only with metrics when changing defaults. |
| Speculative rollback ≠ file/HTTP undo | [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md), [ADR-001](ADR-001-transactional-tool-speculation.md), `sandbox_tool` | Prefer **sandbox / git worktrees** for reversible file work; do not imply full transactional side effects. |
| PWA “developer-grade” / scaling | **P5** polish, [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md), [UI_MANUAL_TEST_MATRIX_20.md](UI_MANUAL_TEST_MATRIX_20.md) | **FE architecture gate** — [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md) (accepted); still scope large dashboard work deliberately. |
| Inference wall time dominates UX | [PERFORMANCE.md](PERFORMANCE.md), [STEADY_RUN.md](STEADY_RUN.md), [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md), `CHUMP_LIGHT_CONTEXT` | **Latency envelope** below; hardware/model path is primary lever—document baseline before arguing “fast enough.” |
| Consciousness adds latency; utility unclear | [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md), A/B harness in ROADMAP “Chump-to-Complex” | **Utility pass** below (same tasks, on vs off). |
| One operator, intermittent use | Phase 2 blinds, daily driver | **Blinds + 95-step plan** are the corrective—[PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) for review hygiene. |

**Unchecked proof work (pick in order; do not skip P5 while inventing new “consciousness” features):**

- [x] **Latency envelope (daily driver):** Measured and documented in [LATENCY_ENVELOPE.md](LATENCY_ENVELOPE.md). Tool-free fast path + schema compaction + KV cache keep-alive: **26s → 0.5s** (warm cache) on qwen2.5:7b Ollama. Three optimization layers: `compact_tools_for_light()`, `message_likely_needs_tools()` with `response_wanted_tools()` auto-retry, `keep_alive=30m`. See [PERFORMANCE.md](PERFORMANCE.md) §8.
- [x] **PWA / dashboard FE gate:** Architecture choice recorded in [ADR-003-pwa-dashboard-fe-gate.md](ADR-003-pwa-dashboard-fe-gate.md); linked from [PWA_TIER2_SPEC.md](PWA_TIER2_SPEC.md) and [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) **P5**.
- [ ] **Overnight / 72h soak:** Execute the window described in [DAILY_DRIVER_95_STEPS.md](DAILY_DRIVER_95_STEPS.md) (roles + primary surface). **Checklist:** [SOAK_72H_LOG.md](SOAK_72H_LOG.md). Capture **pre/post**: SQLite size/WAL pattern, model server restarts, `logs/` growth, and `GET /api/stack-status` samples; append here, [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md), or [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) §Soak.
- [x] **Consciousness utility pass:** Same **scripted** task mix with `CHUMP_CONSCIOUSNESS_ENABLED=0` vs `1` (wall time, pass/fail, optional baseline JSON). **Procedure + log table:** [CONSCIOUSNESS_UTILITY_PASS.md](CONSCIOUSNESS_UTILITY_PASS.md). Extend [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) §8 when correlating with inference A/Bs; cross-link [METRICS.md](METRICS.md).
- [x] **Review stat hygiene:** [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) + `./scripts/print-repo-metrics.sh`; CI prints metrics after [verify-external-golden-path.sh](../scripts/verify-external-golden-path.sh).

## Prioritized goals (unchecked = work to do)

### Bot capabilities (Discord: understanding and intent)

- [x] Understand user intent in Discord: infer what the user wants (create task, run something, answer question, remember something) from natural language; take the right action (task create, run_cli, memory store, etc.) without asking for clarification when intent is clear. Soul and INTENT_ACTION_PATTERNS.md guide this.
- [x] Document intent→action patterns: add examples or rules (e.g. in .cursor/rules or docs) so Chump and Cursor improve at parsing "can you …", "remind me …", "run …", "add a task …", etc.
- [x] Reduce over-asking: when the user's message implies a clear action, do it and confirm briefly; only ask when genuinely ambiguous or dangerous. In soul: "Prefer action over asking."
- [x] Improve reply quality and speed in Discord: concise answers, optional structured follow-ups (e.g. "I created task 3; say 'work on it' to start"). In soul: "Reply concisely; add a short follow-up when relevant."

### Push to Chump repo and self-reboot

- [x] Ensure Chump repo is in `CHUMP_GITHUB_REPOS` and `GITHUB_TOKEN` is set so the bot can git_commit and git_push to chump/* branches. Set `CHUMP_AUTO_PUSH=1` so the bot may push after commit without asking. Documented in OPERATIONS.md and .env.example.
- [x] After pushing changes that affect the bot (soul, tools, src): run `scripts/self-reboot.sh` to kill the current Discord process, rebuild release, and start the new bot. Documented in OPERATIONS.md "Push to Chump repo and self-reboot"; user can say "reboot yourself" or invoke via run_cli. Optional: `CHUMP_SELF_REBOOT_DELAY=10`.

### Capability improvements (no model changes)

- [x] Context window summarize-and-trim: when token count exceeds `CHUMP_CONTEXT_SUMMARY_THRESHOLD`, delegate summarizes oldest messages and one summary block is injected; `CHUMP_CONTEXT_MAX_TOKENS` wired in context_window and local_openai.
- [x] Soul / system prompt reorder: hard rules first, tool examples, routing table, assemble_context, soul and brain last (primacy/recency for small models). `CHUMP_TOOL_EXAMPLES` override.
- [x] Context round filter: `assemble_context()` gates sections by `CHUMP_HEARTBEAT_TYPE` (work = tasks only; research = episodes; cursor_improve = git diff + frustrating episodes; CLI = all).
- [x] Delegate task types: classify (text + categories) and validate (text + criteria) added in delegate_tool.rs.
- [x] Tool-side intelligence: read_file auto-summary when file exceeds `CHUMP_READ_FILE_MAX_CHARS` (default 4000); run_cli middle-trim (first 1K + last 2K with marker).

### Product and Chump–Cursor

- [x] Add or refine `.cursor/rules/*.mdc` so Cursor follows repo conventions and handoff format.
- [x] Update AGENTS.md and docs (e.g. CURSOR_CLI_INTEGRATION.md, CHUMP_PROJECT_BRIEF.md) so Cursor and Chump have clear context.
- [x] Improve handoffs: when Chump calls Cursor CLI, pass enough context in the prompt; document what works in docs.
- [x] Run cursor_improve rounds (or Cursor) to implement one roadmap item at a time; mark done here when complete.
- [x] Define Chump–Cursor communication protocol and direct API contract: roles, shared context, message types, lifecycle (docs/CHUMP_CURSOR_PROTOCOL.md); expand CURSOR_CLI_INTEGRATION.md with prompt format, timeouts, and API contract for future HTTP bridge.

### Keep roles running (background help)

- [x] Run Farmer Brown on a schedule (e.g. launchd every 120s) so the stack is diagnosed and repaired automatically. Run Heartbeat Shepherd, Sentinel, Memory Keeper, Oven Tender on their recommended schedules. See docs/OPERATIONS.md "Roles" and "Farmer Brown"; one-shot: `./scripts/install-roles-launchd.sh` installs all five plists for 24/7. Chump Menu → Roles tab shows all five.

### Implementation, speed, and quality

- [x] Reduce unwrap() in non-test code: high-impact call sites fixed (limits, agent_loop, github_tools). Remaining unwraps verified as test-only (delegate_tool, episode_db, state_db, schedule_db, task_db, repo_tools, memory_*, calc_tool, local_openai, main, cli_tool).
- [x] Fix or document TODOs in `src/`: no TODO/FIXME in src/ currently; add docs/TODO.md or code comments when introducing new work.
- [x] Keep battle QA green: run `BATTLE_QA_ITERATIONS=5 ./scripts/battle-qa.sh` until pass; fix failures in logs/battle-qa-failures.txt. Self-heal: see docs/BATTLE_QA_SELF_FIX.md and WORK_PROMPT "run battle QA and fix yourself."
- [x] Clippy clean: run `cargo clippy` and fix warnings.
- [x] Speed: shorten round latency where possible (prompt size, tool use batching, model choice). Documented in docs/OPERATIONS.md "What slows rounds (speed)".
- [x] Quality: ensure edits include tests/docs where appropriate; clear PR descriptions and handoff summaries. In docs/CHUMP_PROJECT_BRIEF.md "Quality".

### Optional integrations

- [x] GitHub: add repo to CHUMP_GITHUB_REPOS, set GITHUB_TOKEN; Chump can list issues, create branches, open PRs. Documented in .env.example, docs/OPERATIONS.md "Push to Chump repo", docs/AUTONOMOUS_PR_WORKFLOW.md.
- [x] ADB tool: see docs/ROADMAP_ADB.md for Pixel/Termux companion; enable via CHUMP_ADB_* in .env (see .env.example).

### Fleet / Mabel–Chump symbiosis

See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) and [FLEET_ROLES.md](FLEET_ROLES.md) for context.

- [x] **Mutual supervision:** Mac has PIXEL_SSH_HOST (and PIXEL_SSH_PORT); Pixel has MAC_TAILSCALE_IP, MAC_SSH_PORT, MAC_CHUMP_HOME; Pixel SSH key on Mac. Both restart scripts run and exit 0 when heartbeats are up. **Checklist + gate:** [OPERATIONS.md](OPERATIONS.md) (Mutual supervision); **`./scripts/verify-mutual-supervision.sh`** from the Mac (exit 0 = both directions OK).
- [x] **Single fleet report:** Mabel's report round writes `logs/mabel-report-*.md` + notify. **Retire Mac hourly-update** when stable: **`./scripts/retire-mac-hourly-fleet-report.sh`** (see [OPERATIONS.md](OPERATIONS.md) Single fleet report). Chump keeps notify for ad-hoc.
- [x] **Hybrid inference:** On the Pixel set **`MABEL_HEAVY_MODEL_BASE`** (e.g. `http://<MAC_TAILSCALE_IP>:8000/v1`); **`heartbeat-mabel.sh`** switches API for **research** and **report** only; patrol/intel/verify/peer_sync stay on local `OPENAI_API_BASE`. Documented in [OPERATIONS.md](OPERATIONS.md) Hybrid inference + [ANDROID_COMPANION.md](ANDROID_COMPANION.md); helper: **`scripts/apply-mabel-badass-env.sh`**.
- [x] **Peer_sync loop:** Chump writes **`brain/a2a/chump-last-reply.md`** via `context_assembly::record_last_reply` (Discord + web). **`PEER_SYNC_PROMPT`** in **`scripts/heartbeat-mabel.sh`** instructs `memory_brain read_file a2a/chump-last-reply.md` and episode log line "Chump said: …".
- [x] **Mabel self-heal (Pixel):** **`scripts/mabel-farmer.sh`** runs **`start-companion.sh`** when local model/bot is down if **`MABEL_FARMER_FIX_LOCAL=1`** (default). See script header and OPERATIONS **Keeping the stack running**.
- [x] **On-demand status:** Discord **`!status`** / **`status report`** — **Chump** and **Mabel** reply with latest **`logs/mabel-report-*.md`** when present; otherwise Chump points to Mabel/Pixel and the retire script ([`discord.rs`](../src/discord.rs) `on_demand_fleet_status_markdown`).

### PWA / brain workflows (Phase D — pragmatic)

- [x] **Quick capture hardening:** `POST /api/ingest` and **`/api/shortcut/capture`** enforce **512 KiB** max payload, optional **`source`** provenance comment, `RequestBodyLimitLayer` on JSON routes; PWA sends `source: pwa`. See [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md), [CHUMP_BRAIN.md](CHUMP_BRAIN.md) Capture size.
- [x] **External repo + projects:** Documented **`CHUMP_REPO`** / **`CHUMP_HOME`**, multi-repo, **`projects/`** playbooks, and PWA **`/api/projects`** in [CHUMP_BRAIN.md](CHUMP_BRAIN.md) External repos; heartbeat prompts already use `memory_brain` + `set_working_repo`.
- [x] **Research pipeline (baseline):** PWA **`/api/research`** creates queued briefs under **`research/`**; agent-side multi-pass synthesis via **`RESEARCH_BRIEF_PROMPT`** → **`research/latest.md`** and research rounds in **`heartbeat-self-improve.sh`**. Full “Research X for me” one-shot product flow remains incremental (see [ROADMAP_FULL.md](ROADMAP_FULL.md) Tier 1).
- [x] **Watchlists + alerts:** **`GET /api/watch/alerts`** scans **`watch/*.md`** for flagged bullets (urgent / deadline / `[!]` / asap / etc.); **`GET /api/briefing`** includes **Watchlists** + **Watch alerts**. Mabel **`INTEL_PROMPT`** reads **`watch/`** when present ([`heartbeat-mabel.sh`](../scripts/heartbeat-mabel.sh)).
- [x] **Morning briefing DM:** **`scripts/morning-briefing-dm.sh`** — fetch **`/api/briefing`**, format with **`jq`**, pipe to **`chump --notify`** (schedule via cron/launchd). Optional Web Push “research ready” still future.

### Rust infrastructure (reliability & velocity)

Design and status: [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md). Suggested sequence: Tower → tracing → proc macro → inventory → typestate → pool → notify.

- [x] **Tower middleware** (~1 d): Wrap every tool call in a composable stack (timeout, concurrency limit, rate limit, circuit breaker, tracing). Replaces ad-hoc tool timeouts and collapses tool health / error-budget into one layer. Build once at startup; all tools get same guarantees. **Done:** `tool_middleware.rs` with 30s timeout + tool_health_db recording + per-tool circuit breaker + process-wide **`CHUMP_TOOL_MAX_IN_FLIGHT`** concurrency; all Discord/CLI/web registrations use `wrap_tool()`. Full Tower ServiceBuilder layers (rate limit, extra layers) can be added next.
- [x] **tracing migration** (1–2 d): Replace/adjoin `chump_log` with `tracing` spans (agent turn = span, tool call = child span). Unifies logging, episode recording, tool health, introspect; span DB makes "what did I do last session?" trivial. **Done (first phase):** tracing + tracing-subscriber in main (RUST_LOG); agent_loop events (agent_turn, tool_calls); tool_middleware `#[instrument]` on execute. chump_log kept; span DB / introspect later.
- [x] **Proc macro for tools** (~1.5 d): `#[chump_tool(name, description, schema)]` on impl block generates `name()`, `description()`, `input_schema()`; ~30 lines per tool. Done: chump-tool-macro crate, calc_tool migrated. See RUST_INFRASTRUCTURE.md.
- [x] **inventory tool registration** (~0.5 d): Auto-collect tools at link time via `inventory`; `register_from_inventory()` in discord.rs; new tool = one `submit!` in tool_inventory (or per-tool file). Enables Chump self-discovery. **Done:** see RUST_INFRASTRUCTURE.md §3.
- [x] **Typestate session** (~0.5 d): `Session<S: SessionState>` (Uninitialized → Ready → Running → Closed); CLI uses start/close so double-close and tools-before-assemble don't compile. **Done:** `src/session.rs`; see RUST_INFRASTRUCTURE.md §5.
- [x] **rusqlite connection pool** (~0.5 d): r2d2-sqlite + WAL + busy_timeout in `src/db_pool.rs`; all DB modules use pool. **Done:** see RUST_INFRASTRUCTURE.md §7.
- [x] **notify file watcher** (~0.5 d): Real-time repo watch via `notify` in `src/file_watch.rs`; `assemble_context` drains "Files changed since last run (live)". **Done:** see RUST_INFRASTRUCTURE.md §6.

### External readiness (adoption / “take flight”)

Baseline docs: [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md), [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md), [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md). README quick start must stay aligned with the golden path.

- [x] **README + golden path:** Root [README.md](../README.md) describes Chump (not a placeholder), links LICENSE, and quick start matches [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md).
- [x] **External safety banner** in `.env.example` (executive mode, auto-push, cascade privacy, autonomy/RPC cautions).
- [x] **Naive onboarding pass:** Cold clone + timed `cargo build` recorded in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md); launch gates L2/L6 updated in [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md); smoke script [`verify-external-golden-path.sh`](../scripts/verify-external-golden-path.sh). Optional: third-party reviewer still welcome.
- [x] **Optional polish:** README architecture diagram + PWA preview asset; GitHub **issue template** for bugs (see `.github/ISSUE_TEMPLATE/`).
- [ ] **Novice OOTB desktop distribution:** **In-tree (unsigned QA):** bundled **`chump` + Tauri shell**, first-run wizard (Ollama + optional **OpenAI-compatible** base, streaming `ollama pull`, **Application Support** `.env`, health-gated start), retail plist mode **`CHUMP_BUNDLE_RETAIL=1`** in [`scripts/macos-cowork-dock-app.sh`](../scripts/macos-cowork-dock-app.sh), macOS bundle CI [`.github/workflows/tauri-desktop.yml`](../.github/workflows/tauri-desktop.yml). **Still open for public download:** Apple **signing + notarization** + versioned DMG/pkg. Spec: [PACKAGED_OOTB_DESKTOP.md](PACKAGED_OOTB_DESKTOP.md).

### Strategic evaluation alignment (external enterprise / defense doc)

Living map of an external strategy paper vs this repo: [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md). Granular work packages (WP-IDs), priorities, and completion rules: [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) (**§3** includes **WP-1.4** matrix + **WP-1.5** multimodal RFC **Proposed**). Theme order defaults to **inference/ops → pilot kit → fleet transport → research/RFCs**. Optional in-process depth: [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md).

- [x] **Alignment doc + pilot repro kit + inference RFC skeleton:** [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md), [rfcs/RFC-inference-backends.md](rfcs/RFC-inference-backends.md).
- [x] **Inference hardening (ops + UX):** Extend [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) and [OPERATIONS.md](OPERATIONS.md) with a **degraded-mode** playbook (MLX OOM symptoms, Ollama fallback, when `farmer-brown` applies); ensure browser/PWA surfaces `stack-status` `inference.error` where users already load stack status (e.g. Providers/settings flows) when `models_reachable === false`.

### mistral.rs — higher-performance agents (measurement + next tier)

- [x] **Agent power path:** [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) (metrics, fixed AB prompts, modes A/B/C), [`scripts/mistralrs-inference-ab-smoke.sh`](../scripts/mistralrs-inference-ab-smoke.sh), [`scripts/env-mistralrs-power.sh`](../scripts/env-mistralrs-power.sh); PWA streaming default in [`scripts/run-web-mistralrs-infer.sh`](../scripts/run-web-mistralrs-infer.sh).
- [ ] **RFC multimodal (WP-1.5):** Accept or reject [RFC-mistralrs-multimodal-in-tree.md](rfcs/RFC-mistralrs-multimodal-in-tree.md) with rationale, then implement per RFC if accepted ([MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md)). **Sprint:** [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **S2**.
- [x] **Structured output / grammar (in-process mistral):** S3 spike: [ADR-002](ADR-002-mistralrs-structured-output-spike.md), matrix row, opt-in **`CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA`** on **tool-free** completions in [`mistralrs_provider.rs`](../src/mistralrs_provider.rs). **Follow-up:** tool-argument grammar / repair when JSON reliability is the bottleneck ([MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md)). **Sprint:** **S3**.
- [x] **run_cli governance (pilot tier):** Document sponsor-safe defaults (`CHUMP_TOOLS_ASK`, `CHUMP_AUTO_APPROVE_*` off for demos) in [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) or [TOOL_APPROVAL.md](TOOL_APPROVAL.md); optional follow-up issue for containerized or SSH-jump execution profile.
- [x] **Fleet transport spike:** Design note under [FLEET_ROLES.md](FLEET_ROLES.md) or [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) + time-boxed prototype — **outbound** WebSocket or MQTT over Tailscale from Pixel to Mac; Mac **pauses** sentinel-delegated repair when peer last-seen exceeds threshold (no infinite wait).
- [x] **WASM tool lane:** Extend [WASM_TOOLS.md](WASM_TOOLS.md) with a “new sandboxed tool” checklist; explicit **non-goal** near term: WASM-wrapping all of `run_cli`.
- [x] **High-assurance agent architecture (paper → phases):** [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) — **§3 master registry** (WP-1.1 … **WP-1.4** … WP-8.1), **§4 handoff template**, **§17** when to check this box. Rule: **one WP-ID per Cursor run**; set WP **Status** to **Done** in §3 when merged. **Closed under §17 strict (2026-04-09):** all **P0** WPs **2.2**, **3.1**, **4.1** are **Done** in §3. (Use **§17 loose** if you later reopen the umbrella until Phases 1–5 are materially complete—document in a follow-up PR.)

### Repo hygiene and storage (periodic; see [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md))

Baseline: `scripts/cleanup-repo.sh` + archive layout documented. Below = optional polish when disk or clone maintenance matters.

- [x] **Embed cache hygiene** — Document or script safe pruning of `.fastembed_cache/` when using `inprocess-embed` (re-download cost vs disk); cross-link STORAGE_AND_ARCHIVE.md. **Done:** [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) § In-process embed cache.
- [x] **Git maintenance runbook** — Short maintainer note: when to run `git gc`, how to spot history bloat / large blobs, links to GitHub limits; no obligation for routine devs. **Done:** [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) § Git maintenance.
- [x] **Quarterly cold export** — Runbook: tarball `sessions/`, `logs/`, and a defined subset of **`chump-brain/`** (or full brain) to cold storage; one-page restore/smoke check so archives are trustworthy. **Done:** [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) § Quarterly cold export + `cleanup-repo.sh`.

### Turnstone-inspired deployment (observability, safety, governance)

Phased deployment for production-ready ops and compliance. See plan in repo; OPERATIONS.md and ARCHITECTURE.md document the result.

- [x] **Phase 1 — Observability:** Tool-call metrics in middleware; health endpoint includes `model_circuit`, `status` (healthy/degraded), `tool_calls`. OPERATIONS.md "Observability (GET /health)".
- [x] **Phase 2 — Safety:** Heuristic risk for run_cli (and optional write_file); CHUMP_TOOLS_ASK; approval flow with ToolApprovalRequest; one approval UX (Discord + Web); audit logging (tool_approval_audit in chump.log). OPERATIONS.md "Tool approval", docs/TOOL_APPROVAL.md, ARCHITECTURE.md "Tool policy (allow / deny / ask)".
- [x] **Phase 3 — Resilience and governance:** Per-tool circuit breaker (CHUMP_TOOL_CIRCUIT_*); retention and audit documented (OPERATIONS.md "Retention and audit"); RUST_INFRASTRUCTURE.md updated. Session eviction at capacity is optional and deferred (single-session or low concurrency).

### Backlog (see docs/WISHLIST.md)

- [x] run_test tool: structured pass/fail, which tests failed (wrap cargo/npm test). Implemented in src/run_test_tool.rs; registered in Discord and CLI agent builds.
- [x] read_url: fetch docs page (strip nav/footer) for research. Implemented in src/read_url_tool.rs; registered in Discord and CLI agent builds.
- [x] Task routing (assignee): task_db assignee column (chump/mabel/jeff/any); task tool create/list; context_assembly "Tasks for Jeff". See docs/FLEET_ROLES.md.
- [ ] Other wishlist items as prioritized (screenshot+vision → [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **S4**; **watch_file** → **S5**; **sandbox** / **introspect** done — see [WISHLIST.md](WISHLIST.md); emotional memory done — episode sentiment + recent frustrating in context_assembly).

### Autonomy (planning + task execution)

See `docs/AUTONOMY_ROADMAP.md` for the detailed milestone plan.

- [x] **Task contract**: structured task notes (Context/Plan/Acceptance/Verify/Risks) + `task_contract` helpers (`ensure_contract`, section accessors) + tests. Task tool applies template on create.
- [x] **Planner → Executor → Verifier loop**: `autonomy_loop::autonomy_once` — pick task, lease, contract preflight, agent executor prompt, verify (`run_test` / Verify commands), `done` or `blocked` + episode + follow-up task.
- [x] **Task claim/lease locking**: DB-backed leases in `task_db` + `autonomy_loop.rs` (claim, renew, release); `chump --reap-leases` and task tool `reap_leases`. **Tests:** `task_db::task_lease_second_owner_cannot_claim_until_released`; ops: [OPERATIONS.md](OPERATIONS.md).
- [x] **Autonomy driver / ops**: `scripts/autonomy-cron.sh` (reap-leases + `--autonomy-once`); **`CHUMP_RPC_JSONL_LOG`** mirrors `chump --rpc` JSONL to a file. **Auto-approve (opt-in):** **`CHUMP_AUTO_APPROVE_LOW_RISK`** (low-risk `run_cli`) and **`CHUMP_AUTO_APPROVE_TOOLS`**; audited as `tool_approval_audit` (see [OPERATIONS.md](OPERATIONS.md)).
- [x] **Autonomy conformance tests**: `autonomy_loop` tests with fake executor/verifier; lease contention test in `task_db`; **CI:** `.github/workflows/ci.yml` runs `cargo test` + `cargo clippy`.

### Chump-to-Complex transition (synthetic consciousness)

Master vision and detail: [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md). Research brief for external review: [CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md).

**Section 1 — Harden and measure (near-term)**

- [x] **Metric definitions** (`docs/METRICS.md`): CIS, Turn Duration, Auto-approve Rate, Phi Proxy, Surprisal Threshold — exact computation from DB/logs.
- [x] **A/B harness**: consciousness modules enabled vs disabled (`CHUMP_CONSCIOUSNESS_ENABLED=0`); compare task success, tool calls, latency. (Live runs complete: 2026-04-15)
- [ ] **A/B Round 2 (Paper Grade)**: Add LLM-as-a-judge scoring for prompt semantic accuracy, and capture scaling curves across 3+ models (e.g. 3B vs 9B vs 14B) to correlate latency penalty with parameter counts.
- [x] **memory_graph in context_assembly**: inject triple count when graph has triples.
- [x] **Blackboard persistence**: persist high-salience entries to `chump_blackboard_persist`; restore on startup; prune to top 50.
- [x] **Phi proxy calibration**: per-session metrics to `chump_consciousness_metrics` table for phi–surprisal correlation tracking.
- [x] **Consciousness regression suite**: 5 regression tests asserting module state transitions (high-surprise regime shift, persistence roundtrip, metrics recording, A/B toggle, memory_graph in context).
- [x] **Battle QA consciousness gate**: compares consciousness baselines; warns on surprisal regression (>50%) and lesson count drops.

**Section 2 — Build missing core (medium-term)**

- [x] **Belief state module** (`src/belief_state.rs`): per-tool Beta(α,β) confidence, task trajectory tracking, EFE scoring (G = ambiguity + risk − pragmatic_value), context injection. `update_tool_belief()` and `decay_turn()` called from agent_loop hot path after every tool result. 9 tests.
- [x] **EFE-based tool ordering** (2026-04-14): `efe_order_tool_calls()` in agent_loop scores tools by Expected Free Energy and reorders execution (lowest G first). Combined with epsilon-greedy exploration. Belief state now drives action selection, not just context.
- [x] **Precision-weighted surprisal** (2026-04-14): `surprise_tracker::compute_surprisal()` amplifies surprise when beliefs are confident (×1.4 at low uncertainty), dampens when uncertain (×0.6). Closes the Active Inference perception-action loop.
- [x] **Surprise-driven escalation**: epistemic uncertainty check in agent_loop after tool calls; posts high-urgency blackboard entry when task uncertainty exceeds threshold (`CHUMP_EPISTEMIC_ESCALATION_THRESHOLD`).
- [x] **Control shell for blackboard**: regime-adaptive `SalienceWeights` (exploit/balanced/explore/conservative) replacing static weights; manual override via `set_salience_weights()`.
- [x] **Async module posting**: `tokio::sync::mpsc` unbounded channel with `post_async()` and `init_async_channel()` drain task; falls back to synchronous post if channel not initialized.
- [x] **Subscriber filtering**: `Blackboard::subscribe()` registers module interests; `read_subscribed()` returns only matching entries with cross-module read tracking.
- [x] **LLM-assisted triple extraction**: `extract_triples_llm()` sends text to worker model, parses JSON array of (S,R,O,confidence); regex fallback on any failure. `store_triples_with_confidence()` uses confidence as weight.
- [x] **Personalized PageRank**: proper iterative PPR with power method (α=0.85, ε=1e-6 convergence) over adjacency loaded from connected component BFS. Replaces bounded BFS in `associative_recall()`.
- [x] **Valence and gist**: `relation_valence()` maps relations to [-1,+1]; `entity_valence()` computes weighted average; `entity_gist()` produces one-sentence summary with tone and top relations.
- [x] **Noise-as-resource exploration**: `exploration_epsilon()` returns regime-dependent ε; `epsilon_greedy_select()` picks random non-best index with probability ε. Wired into agent_loop via `efe_order_tool_calls()` (2026-04-14).
- [x] **Dissipation tracking**: `record_turn_metrics()` logs tool_calls, tokens, duration, regime, surprisal EMA, and dissipation_rate to `chump_turn_metrics` table. Wired into agent_loop at turn end.
- [x] **Episode causal graph**: `CausalGraph` with nodes (Action/Outcome/Observation) and edges; `build_causal_graph_heuristic()` constructs DAG from episode tool calls; `paths_from()` for traversal; JSON serialization.
- [x] **Counterfactual query engine**: `counterfactual_query()` implements simplified do-calculus — single intervention, graph path analysis, past lesson lookup. Returns predicted outcome with confidence and reasoning.
- [x] **Human review loop**: `claims_for_review()` surfaces high-confidence frequently-applied lessons; `review_causal_claim()` boosts or reduces confidence based on user confirmation.

**Shipped (2026-04-15) — perception, eval, enriched memory, retrieval, verification**

- [x] **Structured perception layer** (`src/perception.rs`): TaskType classification, entity extraction, constraint detection, risk indicators, ambiguity scoring. Wired into agent_loop before the main model call.
- [x] **Eval framework** (`src/eval_harness.rs`): EvalCase, EvalCategory, ExpectedProperty types. DB tables chump_eval_cases, chump_eval_runs. Property-based checking with regression detection, wired into battle_qa.
- [x] **Memory enrichment**: chump_memory gains confidence, verified, sensitivity, expires_at, memory_type columns. Memory tool accepts confidence, memory_type, expires_after_hours params.
- [x] **Retrieval improvements**: RRF merge weighted by freshness decay and confidence. Query expansion via memory graph. Context compression to 4K char budget.
- [x] **Action verification**: ToolVerification struct in tool_middleware.rs. Post-execution verification for write tools. ToolVerificationResult SSE event.
- [x] **Configurable thresholds**: CHUMP_EXPLOIT_THRESHOLD, CHUMP_BALANCED_THRESHOLD, CHUMP_EXPLORE_THRESHOLD, CHUMP_NEUROMOD_NA_ALPHA, CHUMP_NEUROMOD_SERO_ALPHA, CHUMP_LLM_RETRY_DELAYS_MS, CHUMP_ADAPTIVE_OUTCOME_WINDOW.
- [x] **cargo-audit CI job**: `.github/workflows/` runs cargo-audit for dependency vulnerability scanning.
- [x] **Error handling fixes**: ask_jeff_tool, provider_quality, rpc_mode hardened.

**Section 3 — Frontier concepts (long-term, research-grade; gate criteria in CHUMP_TO_COMPLEX.md)**

- [ ] **Quantum cognition prototype**: density matrix belief states for ambiguity resolution; gate: >5% improvement on multi-choice tool selection. **Sprint:** [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **S7**.
- [ ] **Topological integration metric (TDA)**: persistent homology on blackboard traffic; gate: better correlation with task success than phi_proxy. **Sprint:** **S8**.
- [x] **Synthetic neuromodulation** (`src/neuromodulation.rs`): three modulators (dopamine, noradrenaline, serotonin) as system-wide meta-parameters. DA scales reward sensitivity, NA modulates regime thresholds (wired into precision_controller), 5HT controls tool budget, temporal patience, **and tool-free fast path threshold** (wired into agent_loop 2026-04-14). Context injection and health endpoint metrics. 8 tests.
- [x] **Holographic Global Workspace** (`src/holographic_workspace.rs`): `amari-holographic` v0.19 ProductCl3x32 (256-dim, ~46 capacity). Encodes blackboard entries as HRR key-value pairs; `sync_from_blackboard()` called in context_assembly; query_similarity and retrieve_by_key for content-based and key-based lookup. Health endpoint metrics. 7 tests.
- [x] **Speculative execution** (`speculative_execution.rs`, wired from `agent_loop` for ≥3 tools/batch): snapshots belief_state, neuromod, full blackboard; `evaluate()` uses surprisal **EMA delta since fork** plus confidence and failure ratio; `rollback()` restores in-process state only. See `docs/ADR-001-transactional-tool-speculation.md`. Tests in `speculative_execution` + integration coverage.
- [ ] **Workspace merge for fleet**: two Chump instances share blackboard via peer_sync for bounded turns (dynamic autopoiesis). **Sprint:** [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) **S9**.
- [x] **Abstraction audit** (`src/consciousness_traits.rs`): 9 trait interfaces — `SurpriseSource`, `BeliefTracker`, `PrecisionPolicy`, `GlobalWorkspace`, `IntegrationMetric`, `CausalReasoner`, `AssociativeMemory`, `Neuromodulator`, `HolographicStore` — each with a `Default*` implementation backed by the current singleton modules. `ConsciousnessSubstrate` bundles all 9 into a single injectable struct. 9 tests.

## When you complete an item

- Uncheck → check the box in this file (patch_file or write_file: `- [ ]` → `- [x]`).
- If it was a task, set task status to done and episode log.
- Optionally notify if something is ready for review.

## Related docs

Full index: [README.md](README.md). Key: [ROADMAP_MASTER.md](ROADMAP_MASTER.md) (navigation hub), [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) (sprint catalog **S1–S16** covering all major backlog sources), [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) (phased achievable backlog: A–G, I, H), [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) (daily driver / universal power pillars **P1–P5**), [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) / [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) (external adoption), [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md) (strategy paper vs stack), [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md) (sponsor repro path), [ROADMAP_FULL.md](ROADMAP_FULL.md) (consolidated remaining work, Priority 1–5; historical detail), [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md), [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md), [FLEET_ROLES.md](FLEET_ROLES.md), [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) (Tower, tracing, proc macro, inventory, typestate, pool, notify), [AUTONOMY_ROADMAP.md](AUTONOMY_ROADMAP.md), [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md), [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md), [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md), [WISHLIST.md](WISHLIST.md), [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) (master vision: chump → complex transition), [CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md) (external review brief), [TOP_TIER_VISION.md](TOP_TIER_VISION.md) (legacy long-term capabilities; superseded by CHUMP_TO_COMPLEX.md).
