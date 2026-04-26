# Hermes Competitive Roadmap

**Goal:** Close capability gaps with [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), then surpass them on differentiated axes where Chump's architecture has real advantages.

**Honest framing:** Hermes has 89.5k stars, 12.2k forks, 4,286 commits, and Nous Research backing. We cannot win on stars/adoption in 2026. We can win on **technical depth, deployment simplicity, memory sophistication, and empirical research credibility.**

---

## Phase 0: Strategic Analysis

### Hermes's Real Strengths

1. **Skills system** — the self-improvement loop. After completing 5+ tool-call tasks, Hermes autonomously creates reusable `SKILL.md` procedure documents. This is **procedural memory** codified.
2. **Plugin architecture** — three discovery sources (user dir, project dir, pip entry points), with `plugin.yaml` metadata and registry-based auto-discovery.
3. **Pluggable context engine** — `ContextEngine` ABC lets users swap compression/retrieval strategies per deployment.
4. **Multi-platform gateway** — one `AIAgent` class serves 18+ adapters (Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Mattermost, Email, SMS, DingTalk, Feishu, WeCom, BlueBubbles, Home Assistant, iMessage).
5. **6 execution backends** — local, Docker, SSH, Daytona, Modal, Singularity. Serverless "hibernating" environments.
6. **Voice/Vision/Browser** — voice mode, image paste, browser automation (Browserbase, Browser Use, Chrome CDP), FLUX 2 Pro image generation, 5 TTS providers.
7. **Skills Hub ecosystem** — skills.sh directory, `/.well-known/skills/index.json` endpoints, `hermes skills tap add` for custom GitHub sources, security scanning on install.

### Hermes's Actual Weaknesses (Chump's attack surface)

From [Vectorize's memory analysis](https://vectorize.io/articles/hermes-agent-memory-explained):

1. **No entity resolution** — "cannot recognize that 'Alice' and 'my coworker Alice' refer to the same person." Chump's memory graph solves this via Personalized PageRank traversal.
2. **Keyword-only cross-session search** — FTS5 struggles with rephrased queries; users need exact terminology. Chump does FTS5 + semantic + graph RRF.
3. **Compression loss** — facts not flagged during memory flush are lost. Chump's enriched schema (confidence, expiry, verified) preserves provenance.
4. **~1,300 token hot-memory budget** — hard cap on `MEMORY.md` + `USER.md`. Chump uses full SQLite with ranked retrieval.
5. **Curation by agent judgment** — no principled confidence tracking. Chump has belief state and per-tool Bayesian reliability.
6. **No empirical benchmarks in README** — they make capability claims without measurement. Chump has `CHUMP_CONSCIOUSNESS_ENABLED` A/B harness.
7. **Python install friction** — `curl | bash`, `uv`, pip, Python env drift. Chump is single `cargo build --release` binary.

### Where Chump Already Wins

Capabilities Hermes **does not have**:
- Consciousness framework (surprise tracker, neuromodulation, belief state, precision controller, blackboard, phi proxy)
- Speculative execution with belief-state rollback
- Structured perception layer (rule-based pre-reasoning)
- Property-based eval framework with regression detection in DB
- Post-execution action verification for write tools
- Memory graph with Personalized PageRank
- Enriched memory schema (confidence/expiry/verified/sensitivity/memory_type)
- Rust single-binary deployment

---

## Phase 1: Close the Gaps (6–8 weeks)

Priority order is impact × feasibility. These items are achievable with current architecture and let Chump match Hermes's standout UX.

### 1.1 Skills System (P0 — biggest gap)

**Why:** This is Hermes's flagship differentiator. Without it, Chump has episodes (what happened) but not reusable procedures (how to do things).

**Implementation:**
- New module `src/skills.rs` + `src/skill_tool.rs`
- Filesystem layout: `chump-brain/skills/<skill-name>/SKILL.md`
- SKILL.md format (steal directly from Hermes, it's a good spec):
  ```yaml
  ---
  name: fix-clippy-warnings
  description: Systematic approach to resolving Rust clippy warnings
  version: 1
  platforms: [macos, linux]
  metadata:
    tags: [rust, lint, refactor]
    category: code-quality
    requires_toolsets: [repo, cli]
  ---
  ## When to Use
  [trigger conditions]
  ## Quick Reference
  [one-line summary]
  ## Procedure
  1. [step]
  2. [step]
  ## Pitfalls
  [known failure modes]
  ## Verification
  [how to confirm success]
  ```
- New tool `skill_manage` with actions: `create`, `patch`, `edit`, `delete`, `list`, `view`
- Progressive disclosure: system prompt includes skill metadata only (name + short description); full content loaded on `skill_view(name)`
- DB table `chump_skills` with columns: `name`, `description`, `version`, `category`, `tags_json`, `created_at`, `last_used_at`, `use_count`, `success_count`, `failure_count`
- Auto-create trigger logic in `agent_loop.rs`:
  - After successful completion of 5+ tool call task
  - After user correction (detect via diff_review or user "no, try X instead")
  - After recovery from tool failure streak
- Filter by active toolsets (hide skills whose `requires_toolsets` aren't registered)

**Chump-specific advantage:** Wire skill success/failure into belief state. Track per-skill reliability with Beta distribution, same pattern as per-tool reliability. Makes skills measurably better over time, not just accumulating.

### 1.2 Plugin Entry Points (P0)

**Why:** Chump's `inventory::submit!` macro works for in-tree tools but has no discovery path for external plugins. Third parties must fork.

**Implementation:**
- New trait `ChumpPlugin` in `src/plugin.rs` with `name()`, `version()`, `register_tools(&mut Registry)`, `config_schema()`
- Three discovery sources (steal Hermes's pattern):
  1. `~/.chump/plugins/<name>/` — user-level
  2. `.chump/plugins/<name>/` — project-level (in CHUMP_REPO)
  3. Cargo dependency with `chump-plugin` feature — build-time integration
- `plugin.yaml` metadata per plugin directory
- `ChumpPluginManifest` struct: name, version, entry_path, requires_features, config_schema
- `cargo install chump-plugin-<foo>` pattern for shareable plugins
- New CLI: `chump plugins list`, `chump plugins install <url>`, `chump plugins disable <name>`

**Chump-specific advantage:** Rust's compile-time safety means plugins are verified at install time, not runtime. No "plugin installed but crashes at runtime" like Python.

### 1.3 Pluggable Context Engine (P1)

**Why:** `context_assembly.rs` is currently monolithic — every section is hardcoded. Different deployments need different strategies (heavy autonomy vs. light chat vs. research synthesis).

**Implementation:**
- Extract `ContextEngine` trait from current `context_assembly.rs`:
  ```rust
  pub trait ContextEngine: Send + Sync {
      fn assemble(&self, session: &Session, state: &AgentState) -> Result<ContextBlock>;
      fn should_compress(&self, prompt_tokens: u32) -> bool;
      fn compress(&self, messages: &[Message]) -> Result<Vec<Message>>;
      fn update_from_response(&mut self, usage: &TokenUsage);
  }
  ```
- Default implementation: `DefaultContextEngine` = current `assemble_context()` logic
- Additional implementations:
  - `LightChatContextEngine` — slim context for PWA/CLI (already exists as `CHUMP_LIGHT_CONTEXT=1` flag, refactor into separate engine)
  - `AutonomyContextEngine` — heartbeat rounds, roadmap-heavy
  - `ResearchContextEngine` — research brief synthesis
- Selection via `CHUMP_CONTEXT_ENGINE=default|light|autonomy|research`
- Plugin engines: `src/plugin.rs` can register custom engines

**Chump-specific advantage:** Context engines get typed access to the consciousness framework (neuromod, belief state, blackboard). Hermes's engines only see messages and token counts.

### 1.4 Cross-Session Memory Search (P1)

**Why:** Chump has FTS5 for memories but doesn't have Hermes's `session_search` tool that searches across all past sessions and returns LLM-summarized results.

**Implementation:**
- New tool `session_search` that queries `chump_web_messages_fts` and `chump_episodes`
- LLM-summarization step: take top-k matches, send to delegate worker with "summarize these past conversations relevant to '{query}'" prompt
- Returns: bullet-point summary with session IDs as citations
- DB table already exists (`chump_web_messages` with FTS5 trigger) — just needs the tool wrapper

**Chump-specific advantage:** Our RRF pipeline can merge FTS5 + semantic + memory graph results. Hermes only has FTS5. Same query, qualitatively better recall.

### 1.5 Additional Messaging Platforms (P2)

**Why:** Hermes lists 15+ platforms. Chump has Discord + PWA + CLI. Platform reach drives adoption.

**Prioritized additions:**
1. **Telegram** — highest value (many users, simple Bot API, Python alternatives exist in Rust crates like `teloxide`)
2. **Matrix** — federated, appeals to privacy-conscious users who'd use self-hosted Chump anyway
3. **Slack** — business/enterprise appeal
4. **Signal** — via `signal-cli` bridge

**Implementation pattern:**
- New `src/adapters/` directory
- Trait `PlatformAdapter` with `send_message()`, `subscribe()`, `handle_approval()`
- Per-adapter modules: `src/adapters/telegram.rs`, `matrix.rs`, etc.
- Each adapter creates sessions identical to Discord adapter
- Unified gateway launcher: `chump gateway --platforms discord,telegram,matrix`

### 1.6 Checkpoints with Rollback (P2)

**Why:** Hermes has automatic checkpoints; Chump has speculative execution but not conversation-level rollback.

**Implementation:**
- Extend `chump_web_sessions` table with `parent_checkpoint_id`
- Tool `checkpoint` with actions: `create <name>`, `rollback <id>`, `list`, `delete`
- On rollback, branch the session and preserve the old branch for history
- CLI commands: `/checkpoint`, `/rollback`
- Discord/PWA UI shows checkpoint markers in the timeline

### 1.7 Event Hooks System (P2)

**Why:** Hermes has hookable lifecycle points. Enables third-party integrations without core changes.

**Implementation:**
- New module `src/hooks.rs` with lifecycle events:
  - `turn_start`, `turn_end`
  - `tool_call_start`, `tool_call_result`
  - `approval_requested`, `approval_resolved`
  - `session_start`, `session_end`
  - `skill_created`, `skill_updated`
- Hook registration via plugin system or config
- Hook execution is non-blocking (spawn task) unless declared `sync`

---

## Phase 2: Differentiate (4–6 weeks)

Make Chump's existing advantages **legible and provable**.

### 2.1 Publish the Consciousness Framework A/B Results (P0)

**Why:** Hermes has no benchmarks. Chump has `CHUMP_CONSCIOUSNESS_ENABLED=0|1` A/B testing. Publish a real study.

**Deliverable:**
- Run the consciousness A/B harness on 50 standardized tasks
- Measure: task completion rate, tool call count, latency, calibration error, appropriateness (judged by blind reviewer)
- Write up as `docs/CONSCIOUSNESS_STUDY_RESULTS.md` with honest negative findings where they exist
- Blog post + LinkedIn / HN / r/LocalLLaMA announcement
- **The goal isn't to prove superiority — it's to be the only project in the space with any empirical data**

### 2.2 Head-to-Head Benchmark vs Hermes (P0)

**Why:** Both projects make capability claims. Direct comparison on a standard task suite is defensible content.

**Deliverable:**
- Install Hermes in parallel
- Define 20 benchmark tasks covering: file editing, git operations, research synthesis, multi-step debugging, ambiguous request handling
- Run each task on both agents with same local model (e.g., `qwen2.5-14b`)
- Score: completion, number of clarification turns, accuracy, tool selection appropriateness, hallucination rate
- Publish as `docs/HERMES_BENCHMARK.md` with reproducible scripts
- **Play fair** — if Hermes wins on X, say so. Credibility > winning.

### 2.3 Memory Graph Demonstrations (P1)

**Why:** Our biggest unique capability vs Hermes. Make it visible.

**Deliverable:**
- Visualization tool: `chump brain graph` renders memory graph as interactive HTML/SVG
- Demo queries that Hermes's FTS5 cannot answer (multi-hop associations)
- PWA dashboard section showing live graph with current session highlights
- `docs/architecture/MEMORY_GRAPH_VS_FTS5.md` with specific query examples and side-by-side output

### 2.4 Honest Deployment Comparison (P1)

**Why:** Single binary vs Python + uv + plugins is a real dev-experience advantage.

**Deliverable:**
- Video/GIF: "Install Hermes vs Install Chump" in under 60 seconds
- Blog post: "Why Chump uses Rust (honestly, it's the deployment story)"
- Benchmark install-to-first-tool-call time on fresh Ubuntu VM
- Document the tradeoffs honestly (compile time vs run time)

### 2.5 Skill Effectiveness Metrics (P2)

**Why:** If Chump steals skills, Chump should prove they work better. Hermes tracks skill existence; Chump should track skill **reliability**.

**Deliverable:**
- Wire skill success/failure into belief state (Beta distribution per skill)
- Expose per-skill metrics: success_rate, avg_tool_calls_saved, confidence
- Show decay: skills unused in N sessions lose confidence
- New dashboard view: "Skill Health" ranking by confidence × recency × use_count

---

## Phase 3: Leapfrog (8–12 weeks)

Things Hermes doesn't have or can't easily add.

### 3.1 Fleet Coordination as First-Class (P0)

**Why:** Hermes has subagent delegation (up to 3 concurrent child agents). Chump has Chump+Mabel (Mac+Pixel). Expand this to a real fleet story.

**Implementation:**
- `chump fleet join <coordinator-url>` — register as worker
- `chump fleet dispatch <task>` — coordinator routes work
- Shared SQLite via WAL replication or litefs
- Dynamic role negotiation (which agent handles research vs coding vs ops)
- Two-key approval already implemented — generalize to N-key for sensitive actions
- Workspace merge protocol for collaboration on shared problems

**Advantage:** Hermes subagents are short-lived workers. Chump fleet is a long-running multi-agent system with shared memory and specialized roles.

### 3.2 Browser Automation (P1)

**Why:** Hermes has Browserbase/Browser Use/Chrome CDP. Chump's `read_url` only fetches static content.

**Implementation:**
- Feature flag `browser` in Cargo.toml
- Optional dependency: `headless_chrome` or `chromiumoxide`
- New tools: `browser_navigate`, `browser_click`, `browser_fill`, `browser_screenshot`, `browser_extract`
- Sandboxed per session, auto-close on session end
- Approval-gated by default (`CHUMP_TOOLS_ASK=browser_*`)

### 3.3 Execution Backends (P1)

**Why:** Hermes has 6 execution backends. Chump has local + sandbox worktree.

**Implementation (prioritized):**
1. **Docker backend** — `CHUMP_EXECUTION=docker:ubuntu:22.04` runs `run_cli` in ephemeral container
2. **SSH backend** — `CHUMP_EXECUTION=ssh:user@host` for remote execution (useful for fleet)
3. **Modal backend** (optional) — serverless Python execution for ML/data tasks

Uses existing `run_cli` tool with pluggable executor trait.

### 3.4 Skill Hub / Marketplace (P1)

**Why:** Hermes has skills.sh, well-known endpoints, community sources. Chump needs distribution channels for plugins + skills.

**Implementation:**
- `chump skills search <query>` — queries skill registries
- `chump skills install <name>` — downloads, verifies signature, runs security scan
- Host `chump-skills-registry` at chump.example.com/skills
- Accept community submissions via PR to registry repo
- Reuse pattern from `.well-known/skills/index.json` — interoperable with Hermes's ecosystem

**Strategic:** Make Chump skills installable from Hermes's sources. Parasitize their ecosystem, contribute back.

### 3.5 Voice Mode (P2)

**Why:** Nice to have, Hermes has it, low differentiation but table-stakes for 2026 agents.

**Implementation:**
- Optional feature `voice`
- STT: `whisper-rs` (in-process Whisper)
- TTS: integrate with macOS `say`, Linux `espeak`, or external provider (11Labs, Cartesia)
- PWA audio UI: mic button, playback of responses

### 3.6 Cowork / IDE Integration (P2)

**Why:** Hermes has ACP protocol for IDE integration. Chump already has Cursor integration but not a formal protocol.

**Implementation:**
- Document and formalize current Cursor integration as `Chump Agent Protocol (CAP)`
- Implement ACP adapter so Chump speaks Hermes's protocol too
- Neovim plugin + VSCode extension
- Cowork mode: multiple agents collaborate on same codebase with locking

### 3.7 Novel Research Capabilities Hermes Can't Easily Add (P0 strategic)

The consciousness framework gives Chump research angles Hermes simply cannot pursue without rearchitecting. Prioritize these for differentiation:

1. **Active Inference benchmarks** — publish results vs baseline LLM agents on prediction error calibration
2. **Neuromodulation A/B** — show measurable improvement in tool selection when DA/NA/5HT are active
3. **Phi proxy correlation** — prove coupling metric predicts task success
4. **Bayesian tool reliability** — show how per-tool Beta distribution improves tool selection over session length
5. **Surprisal-driven escalation** — measure false-positive/negative rates vs naive approaches

Each is a blog post or workshop paper. Cumulatively, they establish Chump as the **research-credible cognitive agent** while Hermes remains the mass-market OpenClaw alternative.

---

## Phase 4: Ecosystem (ongoing)

### 4.1 Skill Contributions to Hermes Ecosystem

If Chump skills are compatible with Hermes's SKILL.md format (steal it directly, same spec), then every skill Chump authors is also usable in Hermes. This is a one-way value flow: Chump users can pull skills from skills.sh, but Hermes users need Chump to use Chump-authored skills.

Actually — invert: **deliberately make Chump's skill format a superset of Hermes's**, so Chump skills can be downgraded to Hermes skills (losing Chump-specific metadata) but Hermes skills work natively in Chump. This positions Chump as "compatible plus more" rather than "another walled garden."

### 4.2 Academic Positioning

The consciousness framework appeals to academic AI safety / cognitive science audiences. Hermes appeals to developers. These are different tribes. Don't try to beat Hermes on DevRel; target the other audience.

**Concrete actions:**
- Submit consciousness framework writeup to a workshop (NeurIPS Agent workshops, ICLR workshops)
- Post Chump-to-Champ roadmap to LessWrong (aligned with their epistemics)
- Present at local AI meetups as "bounded autonomy with measured cognition"

### 4.3 Contract / Consulting Play

If Chump becomes credibly the "serious research-grade local agent," that's a positioning for:
- Defense / federal contracts (air-gapped, auditable, local-first)
- Enterprise prospects allergic to cloud LLMs
- Academic / research labs

Hermes cannot credibly target this market — Python + plugin complexity + cloud provider dependency make it a non-starter for air-gapped environments.

---

## Execution Plan

### Quarter 1 (next 8 weeks) — **Close the Gap**

**Week 1–2:** Skills system (1.1) + plugin entry points (1.2)
**Week 3–4:** Pluggable context engine (1.3) + session search tool (1.4)
**Week 5–6:** Telegram + Matrix adapters (1.5) + checkpoints (1.6)
**Week 7:** Event hooks (1.7)
**Week 8:** Documentation, blog post, announcement

### Quarter 2 (following 8 weeks) — **Differentiate**

**Week 9–10:** Consciousness A/B study (2.1) — 50-task benchmark run
**Week 11–12:** Head-to-head Hermes benchmark (2.2) — publishable results
**Week 13–14:** Memory graph demos (2.3) + deployment comparison (2.4)
**Week 15–16:** Skill effectiveness metrics (2.5) + research writeups

### Quarter 3+ (ongoing) — **Leapfrog**

- Fleet coordination (3.1) — this is a multi-month effort
- Browser + execution backends (3.2, 3.3) — feature flags, incremental
- Skill Hub (3.4) — infrastructure work
- Voice / IDE / research publications (3.5–3.7) — as time permits

---

## Success Metrics

**6 months from public launch:**
- Feature parity with Hermes on: skills, plugin system, pluggable context, 3+ messaging platforms, checkpoints
- Published A/B benchmark vs Hermes with reproducible scripts
- At least one peer-reviewed workshop submission (consciousness framework)
- 5+ external contributors (any size PR)
- Documented deployment path for air-gapped / enterprise use

**12 months:**
- 1k+ stars (modest vs Hermes's 89.5k, but credible)
- Active Discord/Matrix community
- Paid consulting engagement or contract
- Skill ecosystem with 20+ community-contributed skills
- At least one published paper or preprint on consciousness framework

**What success does NOT look like:**
- Matching Hermes on star count (unrealistic)
- Winning every benchmark (some Hermes will be better at; be honest)
- Replacing Hermes (different audiences, both can thrive)

---

## What to Steal Directly (with attribution)

These are specific patterns that should be copied as-is from Hermes, with credit in commit messages:

1. **SKILL.md format spec** — YAML frontmatter + 5 standard sections. Adopt verbatim for interop.
2. **Plugin manifest format** — `plugin.yaml` with name, version, entry, requires.
3. **Progressive disclosure** — list metadata → view content → view references.
4. **`/.well-known/skills/index.json`** — skill hub endpoint convention.
5. **ContextEngine ABC shape** — `should_compress()`, `update_from_response()` method names.
6. **Gateway message adapter pattern** — one agent class serving many platforms.
7. **Skill auto-creation triggers** — 5+ tool calls, error recovery, user correction.

Commit message format: `feat(skills): adopt Hermes SKILL.md format for interop (credit: NousResearch/hermes-agent)`

---

## Final Thought

We are not going to "take out Hermes." That framing is wrong. Hermes has too much momentum and different goals. What we **are** going to do is become the credible **research-grade alternative** that Hermes structurally cannot become — because Python + plugin sprawl + no consciousness framework prevents them from serving the academic / defense / serious-engineering audiences.

**Chump is Kafka to Hermes's Slack.** Different tool, different audience, both can be big.

The roadmap above gets us from "cool side project" to "the serious option in the space." That's the real game.

---

**Sources:**
- [Hermes Agent architecture docs](https://hermes-agent.nousresearch.com/docs/developer-guide/architecture)
- [Hermes Agent skills system](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)
- [Hermes Agent context engine plugins](https://hermes-agent.nousresearch.com/docs/developer-guide/context-engine-plugin)
- [Vectorize: How Hermes Agent Memory Actually Works](https://vectorize.io/articles/hermes-agent-memory-explained)
- [GitHub - NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
