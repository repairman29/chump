# Chump roadmap

**This file is the single source of truth for what to work on.** Doc index: [docs/README.md](docs/README.md). Heartbeat (work, opportunity, cursor_improve rounds), the Discord bot, and Cursor agents should read this file—and `docs/CHUMP_PROJECT_BRIEF.md` for focus and conventions—to know what they're doing. Do not invent your own roadmap; pick from the unchecked items below, from the task queue, or from codebase scans (TODOs, clippy, tests).

**Single vision:** For the one goal and the order to build/deploy the ecosystem (Horizon 1 → 2 → 3), see [docs/ECOSYSTEM_VISION.md](docs/ECOSYSTEM_VISION.md). Use it to align this roadmap with fleet roles and deployment.

**North star:** Roadmap and focus should improve **implementation** (ship working code and docs), **speed** (faster rounds, less friction, quicker handoffs), **quality** (tests, clippy, error handling, clarity), and **bot capabilities**—especially **understanding the user in Discord and taking action from intent** (infer what they want from natural language; create tasks, run commands, or answer without over-asking).

## How to use this file

- **Full prioritized backlog:** The consolidated list of everything that remains (Priority 1–5) is in [ROADMAP_FULL.md](ROADMAP_FULL.md). Bots read it at round start; pick from unchecked items by priority.
- **Chump (heartbeat / Discord):** In work rounds, use the task queue first; when the queue is empty or in opportunity/cursor_improve rounds, read this file and `docs/CHUMP_PROJECT_BRIEF.md`, then create tasks or do work from the unchecked items (or from ROADMAP_FULL.md).
- **Cursor (when Chump delegates or you're in this repo):** Read this file and `docs/CHUMP_PROJECT_BRIEF.md` when starting. Pick implementation work from the roadmap priorities or from the prompt Chump gave you. Align with conventions in CHUMP_PROJECT_BRIEF and `.cursor/rules/`.

## Current focus (align with CHUMP_PROJECT_BRIEF)

- **Implementation, speed, quality, bot capabilities:** Prioritize work that improves what we ship, how fast we ship it, how good it is, and how well the Discord bot understands and acts on user intent (NLP / natural language).
- Improve the product and the Chump–Cursor relationship: rules, docs, handoffs, use Cursor to implement.
- Task queue and GitHub (optional): create tasks from Discord or issues; use chump/* branches and PRs unless CHUMP_AUTO_PUBLISH is set.
- Keep the stack healthy: Ollama, embed server, battle QA self-heal, autonomy tests. **Run the roles in the background:** Farmer Brown, Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender (Chump Menu → Roles tab; schedule with launchd/cron per docs/OPERATIONS.md).
- **Fleet expansion:** Chump external work, research rounds, review round; Mabel watch rounds; Scout/PWA as primary interface — see [docs/FLEET_ROLES.md](docs/FLEET_ROLES.md).
- **Long-term vision:** In-process inference (mistral.rs), eBPF observability, managed browser (Firecrawl), stateless task decomposition, JIT WASM tools — see [docs/TOP_TIER_VISION.md](docs/TOP_TIER_VISION.md).

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

See [docs/ROADMAP_MABEL_DRIVER.md](docs/ROADMAP_MABEL_DRIVER.md) and [docs/FLEET_ROLES.md](docs/FLEET_ROLES.md) for context.

- [ ] **Mutual supervision:** Mac has PIXEL_SSH_HOST (and PIXEL_SSH_PORT); Pixel has MAC_TAILSCALE_IP, MAC_SSH_PORT, MAC_CHUMP_HOME; Pixel SSH key on Mac. Both restart scripts (restart-chump-heartbeat.sh, restart-mabel-heartbeat.sh) run and exit 0 when heartbeats are up. Document checklist in OPERATIONS.md; optional verify-mutual-supervision.sh.
- [ ] **Single fleet report:** Mabel's report round is the single scheduled fleet report. When stable, unload Mac hourly-update (launchctl bootout ai.chump.hourly-update-to-discord). Chump keeps notify for ad-hoc (blocked, PR ready). Doc in OPERATIONS.md; optional on-demand !status.
- [ ] **Hybrid inference:** Set MABEL_HEAVY_MODEL_BASE on Pixel so research/report rounds use Mac 14B; patrol/intel/verify/peer_sync stay local. Document in OPERATIONS.md or ANDROID_COMPANION.md.
- [ ] **Peer_sync loop:** Mabel reads Chump's last a2a reply and logs "Chump said: …" in episode. PEER_SYNC_PROMPT in heartbeat-mabel.sh instructs this; if the runtime does not inject a2a channel history and a tool/API is needed to read the last reply, implement that and add here: "peer_sync: tool or API to read last a2a reply".
- [ ] **Mabel self-heal (Pixel):** When mabel-farmer.sh finds Pixel llama-server or bot down, run local fix (e.g. start-companion.sh). Optional MABEL_FARMER_FIX_LOCAL=1; document in script and OPERATIONS.md.
- [ ] **On-demand status (follow-up):** Mabel handles `!status` / "status report" in Discord or a2a to return the same unified report on demand (e.g. run report logic or read latest `mabel-report-*.md`).

### Rust infrastructure (reliability & velocity)

Design and status: [docs/RUST_INFRASTRUCTURE.md](docs/RUST_INFRASTRUCTURE.md). Suggested sequence: Tower → tracing → proc macro → inventory → typestate → pool → notify.

- [x] **Tower middleware** (~1 d): Wrap every tool call in a composable stack (timeout, concurrency limit, rate limit, circuit breaker, tracing). Replaces ad-hoc tool timeouts and collapses tool health / error-budget into one layer. Build once at startup; all tools get same guarantees. **Done:** `tool_middleware.rs` with 30s timeout + tool_health_db recording; all Discord/CLI/web registrations use `wrap_tool()`. Full Tower ServiceBuilder layers (concurrency, rate limit, circuit breaker) can be added next.
- [x] **tracing migration** (1–2 d): Replace/adjoin `chump_log` with `tracing` spans (agent turn = span, tool call = child span). Unifies logging, episode recording, tool health, introspect; span DB makes "what did I do last session?" trivial. **Done (first phase):** tracing + tracing-subscriber in main (RUST_LOG); agent_loop events (agent_turn, tool_calls); tool_middleware `#[instrument]` on execute. chump_log kept; span DB / introspect later.
- [x] **Proc macro for tools** (~1.5 d): `#[chump_tool(name, description, schema)]` on impl block generates `name()`, `description()`, `input_schema()`; ~30 lines per tool. Done: chump-tool-macro crate, calc_tool migrated. See RUST_INFRASTRUCTURE.md.
- [x] **inventory tool registration** (~0.5 d): Auto-collect tools at link time via `inventory`; `register_from_inventory()` in discord.rs; new tool = one `submit!` in tool_inventory (or per-tool file). Enables Chump self-discovery. **Done:** see RUST_INFRASTRUCTURE.md §3.
- [x] **Typestate session** (~0.5 d): `Session<S: SessionState>` (Uninitialized → Ready → Running → Closed); CLI uses start/close so double-close and tools-before-assemble don't compile. **Done:** `src/session.rs`; see RUST_INFRASTRUCTURE.md §5.
- [x] **rusqlite connection pool** (~0.5 d): r2d2-sqlite + WAL + busy_timeout in `src/db_pool.rs`; all DB modules use pool. **Done:** see RUST_INFRASTRUCTURE.md §7.
- [x] **notify file watcher** (~0.5 d): Real-time repo watch via `notify` in `src/file_watch.rs`; `assemble_context` drains "Files changed since last run (live)". **Done:** see RUST_INFRASTRUCTURE.md §6.

### Turnstone-inspired deployment (observability, safety, governance)

Phased deployment for production-ready ops and compliance. See plan in repo; OPERATIONS.md and ARCHITECTURE.md document the result.

- [x] **Phase 1 — Observability:** Tool-call metrics in middleware; health endpoint includes `model_circuit`, `status` (healthy/degraded), `tool_calls`. OPERATIONS.md "Observability (GET /health)".
- [x] **Phase 2 — Safety:** Heuristic risk for run_cli (and optional write_file); CHUMP_TOOLS_ASK; approval flow with ToolApprovalRequest; one approval UX (Discord + Web); audit logging (tool_approval_audit in chump.log). OPERATIONS.md "Tool approval", docs/TOOL_APPROVAL.md, ARCHITECTURE.md "Tool policy (allow / deny / ask)".
- [x] **Phase 3 — Resilience and governance:** Per-tool circuit breaker (CHUMP_TOOL_CIRCUIT_*); retention and audit documented (OPERATIONS.md "Retention and audit"); RUST_INFRASTRUCTURE.md updated. Session eviction at capacity is optional and deferred (single-session or low concurrency).

### Backlog (see docs/WISHLIST.md)

- [x] run_test tool: structured pass/fail, which tests failed (wrap cargo/npm test). Implemented in src/run_test_tool.rs; registered in Discord and CLI agent builds.
- [x] read_url: fetch docs page (strip nav/footer) for research. Implemented in src/read_url_tool.rs; registered in Discord and CLI agent builds.
- [x] Task routing (assignee): task_db assignee column (chump/mabel/jeff/any); task tool create/list; context_assembly "Tasks for Jeff". See docs/FLEET_ROLES.md.
- [ ] Other wishlist items as prioritized (screenshot+vision, introspect, sandbox; emotional memory done — episode sentiment + recent frustrating in context_assembly).

### Autonomy (planning + task execution)

See `docs/AUTONOMY_ROADMAP.md` for the detailed milestone plan.

- [ ] **Task contract**: structured task notes (Context/Plan/Acceptance/Verify/Risks) + helpers + tests.
- [ ] **Planner → Executor → Verifier loop**: pick next task, expand plan, execute, verify, update task status, write episode.
- [ ] **Task claim/lease locking**: prevent duplicate work across multiple workers; lease expiry handling.
- [ ] **Autonomy driver**: cron-friendly driver that runs `chump --rpc` and persists event logs; optional policy-based auto-approvals for low-risk.
- [ ] **Autonomy conformance tests**: deterministic scenarios that validate end-to-end execution and block regressions in CI.

### Chump-to-Complex transition (synthetic consciousness)

Master vision and detail: [docs/CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md). Research brief for external review: [docs/CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md).

**Section 1 — Harden and measure (near-term)**

- [ ] **Metric definitions** (`docs/METRICS.md`): CIS, Turn Duration, Auto-approve Rate, Phi Proxy, Surprisal Threshold — exact computation from DB/logs.
- [ ] **A/B harness**: consciousness modules enabled vs disabled (`CHUMP_CONSCIOUSNESS_ENABLED=0`); compare task success, tool calls, latency.
- [ ] **memory_graph in context_assembly**: inject triple count and top-N entity associations for the current query.
- [ ] **Blackboard persistence**: optionally persist high-salience entries to SQLite for cross-session continuity.
- [ ] **Phi proxy calibration**: correlate phi_proxy scores against human-judged "coherent vs incoherent" turns.
- [ ] **Consciousness regression suite**: deterministic mock scenarios asserting module state transitions.
- [ ] **Battle QA consciousness gate**: fail battle-qa if phi_proxy or surprisal metrics regress beyond threshold.

**Section 2 — Build missing core (medium-term)**

- [ ] **Belief state module** (`src/belief_state.rs`): latent state vector, Bayesian update per turn, Expected Free Energy (G) policy scoring for tool selection.
- [ ] **Surprise-driven escalation**: agent autonomously asks human when belief uncertainty exceeds threshold (epistemic agency).
- [ ] **Control shell for blackboard**: lightweight rule engine or classifier replacing static salience scoring.
- [ ] **Async module posting**: Tokio broadcast channel for non-blocking blackboard writes.
- [ ] **LLM-assisted triple extraction**: delegate worker extracts structured (S, R, O) triples with confidence; regex fallback.
- [ ] **Personalized PageRank**: proper PPR with teleport vector replacing bounded BFS in memory_graph.
- [ ] **Valence and gist**: scalar valence + one-sentence gist per triple cluster for "System 1" recall.
- [ ] **Noise-as-resource exploration**: epsilon-greedy tool selection in Explore regime, epsilon derived from surprisal variance.
- [ ] **Dissipation tracking**: log compute cost per turn as "heat"; plot against "work done" (tasks completed).
- [ ] **Episode causal graph**: delegate-produced DAG of (action → outcome); stored adjacency list; do-calculus counterfactual queries.
- [ ] **Human review loop for causal claims**: surface high-impact counterfactuals for confirmation before they influence behavior.

**Section 3 — Frontier concepts (long-term, research-grade; gate criteria in CHUMP_TO_COMPLEX.md)**

- [ ] **Quantum cognition prototype**: density matrix belief states for ambiguity resolution; gate: >5% improvement on multi-choice tool selection.
- [ ] **Topological integration metric (TDA)**: persistent homology on blackboard traffic; gate: better correlation with task success than phi_proxy.
- [ ] **Synthetic neuromodulation**: dopamine/noradrenaline/serotonin proxies as system-wide meta-parameters; gate: outperforms fixed thresholds on 50-turn diverse task set.
- [ ] **Holographic Global Workspace**: HRR-encoded distributed state; gate: >90% retrieval accuracy, <1ms latency.
- [ ] **Speculative execution prototype**: fork belief state + blackboard before multi-step plan; commit or rollback (software-level reversible computation).
- [ ] **Workspace merge for fleet**: two Chump instances share blackboard via peer_sync for bounded turns (dynamic autopoiesis).
- [ ] **Abstraction audit**: trait-based interfaces for all consciousness modules to enable future substrate swaps.

## When you complete an item

- Uncheck → check the box in this file (edit_file: `- [ ]` → `- [x]`).
- If it was a task, set task status to done and episode log.
- Optionally notify if something is ready for review.

## Related docs

Full index: [docs/README.md](docs/README.md). Key: [ROADMAP_FULL.md](ROADMAP_FULL.md) (consolidated remaining work, Priority 1–5; pick from unchecked items), [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md), [CLOSING_THE_GAPS.md](CLOSING_THE_GAPS.md), [FLEET_ROLES.md](FLEET_ROLES.md), [RUST_INFRASTRUCTURE.md](RUST_INFRASTRUCTURE.md) (Tower, tracing, proc macro, inventory, typestate, pool, notify), [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md), [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md), [CURSOR_CLI_INTEGRATION.md](CURSOR_CLI_INTEGRATION.md), [WISHLIST.md](WISHLIST.md), [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) (master vision: chump → complex transition), [CHUMP_RESEARCH_BRIEF.md](CHUMP_RESEARCH_BRIEF.md) (external review brief), [TOP_TIER_VISION.md](TOP_TIER_VISION.md) (legacy long-term capabilities; superseded by CHUMP_TO_COMPLEX.md).
