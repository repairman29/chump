# Chump Product Gap Plan — Closing Every Gap

> Execution plan for all gaps identified in PRODUCT_ANALYSIS.md.
> Generated 2026-04-15. Ordered by severity then effort.

---

## Phase 1: Survival (Week 1-2) — "Stop the bleeding"
> Users bounce on latency and blank screens. Fix these or nothing else matters.

### G2: Streaming tokens to UI [Critical]
**Problem:** Users stare at a blank screen for 30-60s with no feedback.
**Solution:** The inference backend (vLLM-MLX, Ollama) already supports streaming. Wire SSE token events from the provider through to the PWA.
**Files:**
- `src/streaming_provider.rs` — already has `TextComplete` events; add per-token `TokenDelta` events
- `src/stream_events.rs` — add `TokenDelta { content: String }` variant
- `web/index.html` — handle `token_delta` SSE events, append to chat bubble in real-time
**Effort:** ~80 lines Rust + ~30 lines JS
**Metric:** Time-to-first-visible-character < 2s

### G1: Latency reduction (30-60s → <15s) [Critical]
**Problem:** 2 LLM roundtrips per tool turn (decide tool → execute → summarize).
**Solutions (stack, not pick-one):**
1. **KV cache warmup:** Pre-compute system prompt KV cache on server start. vLLM-MLX supports `--prefill-cache`. Saves 1-3s per turn.
   - `scripts/serve-vllm-mlx.sh` — add `--system-prompt-cache` flag
   - `src/discord.rs` — extract system prompt to a cacheable constant
2. **Prompt compaction:** Audit system prompt token count. Current HARD_RULES + INTENT_ACTION_COMPACT + tool examples may exceed 1500 tokens. Target: <800 tokens for light mode.
   - `src/discord.rs` — measure and trim
3. **Parallel tool execution:** When model requests multiple tools, execute concurrently (already partially implemented in `executor.rs`).
4. **3B model for simple tasks:** Route greetings, math, and single-tool calls to Qwen2.5-3B (~2x faster). Use 7B for multi-step reasoning.
   - `src/precision_controller.rs` — add model tier routing based on message complexity
   - `.claude/launch.json` — add Multi-MLX config (3B + 7B)
5. **Speculative tool start:** If the model's first 20 tokens strongly indicate a tool call (e.g., starts with `{"name": "task"`), begin parsing/executing before generation completes.
   - `src/streaming_provider.rs` — add speculative parsing in token stream
**Effort:** 2-3 days across multiple files
**Metric:** Median turn time < 15s (tool turns), < 5s (chat turns)

---

## Phase 2: Adoption (Week 2-4) — "Make it effortless to start"
> If setup takes more than 5 minutes, most users quit.

### G5: One-click install [High]
**Problem:** Users must: install Rust, clone repo, build, install inference backend, configure env vars, start server.
**Solution:** Tiered approach:
1. **Homebrew tap** (Mac):
   ```
   brew tap repairman29/chump
   brew install chump
   chump --setup  # interactive: picks inference backend, downloads model
   ```
   - Create `Formula/chump.rb` with pre-built binary from GitHub Releases
   - `chump --setup` wizard: detect hardware → recommend model → download → start
2. **GitHub Release binaries:** CI builds universal macOS binary + Linux x86_64
   - `.github/workflows/release.yml` — cargo build --release, create GitHub Release
3. **Docker image** (Linux/teams):
   - `Dockerfile` — multi-stage: build Rust binary, bundle with Ollama
   - `docker-compose.yml` already exists, needs refinement
**Effort:** 3-4 days
**Metric:** Time from `brew install` to first chat < 5 minutes

### G3: Onboarding friction [High]
**Problem:** OOTB wizard exists but doesn't automate inference setup.
**Solution:** Enhance `chump --setup` / PWA first-run:
1. **Auto-detect inference:** On first PWA load, probe localhost:11434 (Ollama), :8000 (vLLM), :8001 (MLX). If found, auto-configure. If not, show "Start inference" button.
2. **Model download progress:** If Ollama detected, offer one-click `ollama pull qwen2.5:7b` with progress bar in PWA.
3. **Health check dashboard:** Replace current "Inference unreachable" banner with actionable troubleshooting: "Ollama isn't running. [Start it] or [Switch to MLX]."
4. **First-task guided flow:** After setup, auto-create a sample task and walk user through completing it.
**Files:**
- `web/index.html` — enhanced inference banner with action buttons
- `web/ootb-wizard.js` — auto-detect logic
- `src/routes/health.rs` — add `/api/inference-probe` endpoint
**Effort:** 2-3 days
**Metric:** Onboarding completion rate > 80%

---

## Phase 3: Capability (Week 3-5) — "Make Chump actually smart"
> Reliable + fast + easy to start. Now make it capable.

### G4: Task dependency DAGs [Medium]
**Problem:** `decompose_task_tool` creates flat task lists. Chump can't reason about prerequisites.
**Solution:**
1. **Schema:** Add `depends_on TEXT` (JSON array of task IDs) to `chump_tasks` table
   - `src/task_db.rs` — migration + query: `SELECT * FROM chump_tasks WHERE status='open' AND (depends_on IS NULL OR all_deps_done(depends_on))`
2. **Decompose tool update:** Force LLM to output dependency graph when breaking down goals
   - `src/decompose_task_tool.rs` — schema update, dependency validation
3. **Planner tool:** Query unblocked tasks, suggest next action
   - `src/task_planner_tool.rs` — DAG-aware scheduling
4. **PWA visualization:** Simple dependency arrows in task list
   - `web/index.html` — task card shows "Blocked by: #3, #5" badges
**Effort:** 2 days
**Metric:** Chump autonomously sequences 5-step projects without human ordering

### G8: 7B model quality ceiling [Medium]
**Problem:** 7B models miss tool calls, hallucinate parameters, lose context.
**Solution:** Defense in depth (already partially built):
1. **Cascade inference:** Try 3B first (fast), fall back to 7B (capable), fall back to 14B (rare)
   - `src/cascade.rs` — already exists, needs tuning of fallback triggers
2. **Self-verification:** After tool execution, ask model "did this achieve the goal?" before reporting success
   - `src/agent_loop.rs` — add verification step after tool results
3. **Fine-tuning dataset:** Collect all battle test interactions + tool call logs → create SFT dataset for Qwen2.5-7B tool use
   - `scripts/export-sft-data.py` — new script, reads from `chump_turn_metrics` + `chump_prediction_log`
4. **Structured output mode:** Force JSON-only responses for tool calls (vLLM-MLX supports guided generation)
**Effort:** 3-5 days (cascade tuning: 1d, verification: 1d, SFT: 2-3d)
**Metric:** Battle test score stays 100% across 50 consecutive runs

---

## Phase 4: Growth (Week 5-8) — "Show the world"
> Product works. Now people need to know it exists.

### G6: Demo video / marketing assets [Medium]
**Problem:** No way to show Chump's value without installing it.
**Solution:**
1. **60-second demo video:** Screen recording of battle test scenarios — real tool calls, task creation, file creation, multi-turn close. Voiceover: "Watch Chump actually do things."
2. **Landing page:** Static site at chump.dev (or GitHub Pages). Hero: "Your AI dev that runs on your Mac." CTA: `brew install chump`
3. **README overhaul:** Current README is developer-focused. Add: 30-second GIF, feature comparison table, one-liner install.
4. **Blog post:** "How we went from 0% to 100% on AI agent reliability with a 7B model"
**Effort:** 2-3 days
**Metric:** GitHub stars growth rate

### G7: KPI telemetry / analytics [Medium]
**Problem:** We have cognitive-state API but no persistent dashboards or trend tracking.
**Solution:**
1. **Battle test CI:** Run `battle-pwa-live.sh` nightly, log scores to SQLite
   - `.github/workflows/battle-test.yml` or `scripts/autonomy-cron.sh` integration
2. **Session analytics:** Track per-session: tool call rate, narration rate, latency p50/p95, user satisfaction (thumbs up/down on messages)
   - `src/web_sessions_db.rs` — add `session_metrics` table
   - `web/index.html` — add thumbs up/down buttons on assistant messages
3. **Dashboard:** New sidecar tab "Analytics" showing trends
   - `web/index.html` — chart.js or sparkline-based trend view
**Effort:** 3-4 days
**Metric:** Can answer "is Chump getting better or worse this week?" with data

---

## Phase 5: Scale (Week 8+) — "Beyond solo dev"

### G9: Mobile/tablet experience [Low]
**Problem:** PWA works on mobile but touch targets are small, no voice input.
**Solution:**
1. Touch-friendly CSS pass (min 44px targets, already partially done)
2. Voice input via Web Speech API — critical for dictation use case
3. Responsive sidecar (bottom sheet on mobile instead of side panel)
**Effort:** 2 days

### G10: Multi-user / team features [Low]
**Problem:** Chump is single-user. Teams can't share task boards or agent context.
**Solution:** Future — requires auth, per-user sessions, shared task DB. Likely a hosted offering, not local-first.
**Effort:** Large (weeks). Defer until product-market fit is proven.

---

## Execution Priority Matrix

| Gap | Severity | Effort | ROI | Sprint |
|-----|----------|--------|-----|--------|
| G2 Streaming tokens | Critical | Small | Huge | 1 |
| G1 Latency reduction | Critical | Medium | Huge | 1 |
| G5 One-click install | High | Medium | High | 2 |
| G3 Onboarding friction | High | Medium | High | 2 |
| G4 Task DAGs | Medium | Small | Medium | 3 |
| G8 Model quality | Medium | Large | Medium | 3 |
| G6 Demo/marketing | Medium | Small | High | 4 |
| G7 KPI telemetry | Medium | Medium | Medium | 4 |
| G9 Mobile UX | Low | Small | Low | 5 |
| G10 Multi-user | Low | Large | Low | 5+ |

---

## Definition of Done: "World-Class Chump"

- [ ] 100% battle test score maintained across 50 consecutive runs
- [ ] Median tool turn < 15s, chat turn < 5s
- [ ] First-token visible in < 2s (streaming)
- [ ] `brew install chump && chump --setup` → first chat in < 5 minutes
- [ ] Onboarding completion > 80%
- [ ] Chump autonomously completes a 5-step project with DAG dependencies
- [ ] Demo video published, README has 30-second GIF
- [ ] Nightly battle test CI with trend dashboard
