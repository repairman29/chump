# Chump: A Dissertation on Building a Self-Hosted Cognitive Agent

**For the next generation of developers picking up this project.**

Written April 2026 by Jeff Adkins, with Claude.

---

## Preface: What You're Inheriting

You're looking at roughly 40,000 lines of Rust that do something no framework gave us for free: a single-process AI agent that runs on your laptop, remembers what it learned yesterday, works on tasks while you sleep, knows when it's confused, and asks for help when it should.

This isn't a chatbot with delusions of grandeur. It's a working system that ships code, manages its own task queue, tracks its prediction errors, and governs its own autonomy through layered safety controls. It runs on a MacBook Air with a 14B parameter model, no cloud required.

This document is the story of why it exists, how it works, what the hard problems were, and where it should go next. Read it like a conversation with someone who spent a year learning things the hard way so you don't have to.

---

## Part I: Why Chump Exists

### The Problem We Were Solving

In early 2025, the state of AI agents looked like this: cloud-hosted, stateless, expensive, and incapable of doing real work without a human steering every turn. You could have a conversation with GPT-4 and it would forget you existed the moment you closed the tab. You could plug tools into LangChain and get a system that called the wrong function 30% of the time and had no idea it was doing so.

The specific frustration was this: **AI assistants had no continuity, no self-awareness of their own reliability, and no governance model for autonomous action.** They were smart in the moment and useless over time.

Jeff's thesis was simple: what if the agent lived on your machine, remembered everything, tracked its own competence, and earned autonomy by demonstrating reliability? Not "autonomous AI" in the breathless press-release sense, but bounded autonomy with explicit contracts, audit trails, and human oversight.

That's Chump.

### Why "Chump"?

The name comes from the project's core metaphor, articulated in `docs/CHUMP_TO_COMPLEX.md`:

A standard LLM agent is a "chump" -- stateless, reactive, with no persistent model of its own uncertainty or causal history. The project's arc is transforming that chump into a "complex": a maximally integrated, self-aware agent that maintains beliefs, tracks prediction error, broadcasts salient information across modules, reasons about counterfactuals, and governs its own resource expenditure.

The name stuck because it's honest. Every agent starts as a chump. The interesting question is what it takes to stop being one.

### Why Rust?

Three reasons, in order of importance:

1. **Single binary deployment.** No Python virtualenvs, no node_modules, no Docker containers. `cargo build --release` produces one binary that runs everywhere. For a self-hosted agent that needs to start reliably on boot, this matters enormously.

2. **Async without tears.** Tokio gives us concurrent tool execution, SSE streaming, Discord gateway handling, and HTTP serving in one process without the GIL fights or callback hell of other ecosystems.

3. **Correctness pressure.** The borrow checker forces you to think about ownership of state. When you're building a system where memory, beliefs, and tool results all flow through shared state, Rust's type system catches entire categories of bugs at compile time. The consciousness framework would be a nightmare of race conditions in Python.

The tradeoff is compile times and a steeper learning curve. Worth it for a system that needs to run unattended for days.

### Why Local-First?

Privacy, cost, and latency. In that order.

Running on local hardware means your code never leaves your machine. The provider cascade supports cloud fallback for when you need it, but the default path is Ollama on localhost. A 14B model on an M4 Air gives 20-40 tokens/second -- fast enough for real work, slow enough to remind you that inference isn't free.

The cost argument is real: a busy agent making 50-100 model calls per hour would cost $5-15/hour on cloud APIs. On local hardware, the marginal cost is electricity. Over months of autonomous operation, this adds up to thousands of dollars saved.

Latency matters for the tool-use loop. Each round trip to a cloud API adds 500-2000ms. When you're chaining 5-10 tool calls in a single turn, that compounds. Local inference with KV cache keep-alive (`CHUMP_OLLAMA_KEEP_ALIVE=30m`) gives sub-second first-token latency after warmup.

---

## Part II: Architecture -- The System as a Whole

### The Core Loop

Every interaction with Chump follows the same pattern, whether it comes from Discord, the web PWA, CLI, or the autonomy loop:

```
Input arrives
  -> Perception (rule-based task classification, entity extraction, risk detection)
  -> Context assembly (system prompt + ego state + tasks + memories + consciousness)
  -> Model call (local or cascade, with tool schemas)
  -> Tool execution (middleware: timeout, circuit breaker, rate limit, approval, verification)
  -> State updates (belief state, surprise tracker, neuromodulation, blackboard)
  -> Response delivery (Discord message, SSE stream, CLI output)
  -> Session lifecycle (episode logging, memory writeback, metrics)
```

This loop runs 1-15 times per user turn, depending on how many tools the model invokes. The speculative execution system can batch 3+ tool calls in parallel when the model is confident.

### The Four Surfaces

Chump is one process with four faces:

**Web PWA** (`web/index.html`, `src/web_server.rs`): The recommended interface. A single-page app with SSE streaming, tool approval cards, a cognitive ribbon showing real-time neuromodulation levels, and a causal timeline of tool executions. Dark theme. Works on mobile with safe-area insets for iPhone notches. Offline-capable via service worker.

**Discord** (`src/discord.rs`): Per-channel sessions. Mention `@chump` to talk. Tool approvals via reaction buttons (checkmark/X). Agent-to-agent communication with Mabel (the companion bot on a Pixel phone). Queue system for handling message bursts.

**CLI** (`run-local.sh`): Interactive REPL or one-shot mode (`--chump "prompt"`). Used by heartbeat scripts for autonomous work. RPC mode (`src/rpc_mode.rs`) for JSONL-over-stdio integration with external tools like Cursor.

**Desktop** (`desktop/src-tauri/`): Tauri shell that wraps the web PWA with native macOS chrome. IPC bridge for health snapshots and orchestrator pings. Work in progress toward signed/notarized distribution.

### The Data Layer

Everything persists in a single SQLite database (`sessions/chump_memory.db`) with WAL mode for concurrent read/write and a 16-connection r2d2 pool. Key tables:

- **`chump_memory`**: Long-term declarative memory with FTS5 full-text search. Now enriched with confidence, verified status, sensitivity, expiry, and memory type fields.
- **`chump_memory_graph`**: Subject-relation-object triples for associative recall via Personalized PageRank.
- **`chump_state`**: Ego state (mood, current_focus, frustrations, curiosities, drive_scores).
- **`chump_tasks`**: Work queue with priority, assignee, planner groups, dependencies.
- **`chump_episodes`**: Narrative work history with sentiment analysis and counterfactual fields.
- **`chump_prediction_log`**: Per-tool surprisal tracking for the Active Inference proxy.
- **`chump_turn_metrics`**: Regime, surprisal EMA, dissipation rate per turn.
- **`chump_consciousness_metrics`**: Phi proxy, coupling score, regime snapshots.
- **`chump_eval_cases` / `chump_eval_runs`**: Eval framework for property-based testing and regression detection.

Plus the **brain** (`chump-brain/`): a git-tracked directory of markdown files serving as a persistent knowledge base. Projects, portfolio, research briefs, self-knowledge, and agent-to-agent coordination files.

Schema evolution uses incremental `ALTER TABLE ADD COLUMN` with `let _ =` to silently ignore "already exists" errors. No migration files, no migration framework. It's crude and it works perfectly for a single-binary deployment where the schema evolves with the code.

---

## Part III: The Consciousness Framework

This is the most unusual part of Chump and the part most likely to make traditional engineers uncomfortable. Let me be clear about what it is and what it isn't.

### What It Is

Six operational subsystems inspired by neuroscience and information theory, each implementing a measurable proxy for a theoretical concept. They are engineering modules with empirical tests, not philosophical claims about machine sentience.

The question we're answering is not "is Chump conscious?" but "do these biologically-inspired feedback mechanisms make the agent more reliable, better calibrated, and more appropriate in its tool use?" The answer, based on A/B testing with the consciousness framework enabled vs. disabled, is: yes, measurably.

### What It Isn't

It is not claiming phenomenal consciousness. It is not implementing Integrated Information Theory's actual phi (which is computationally intractable). It is not a marketing gimmick. The modules have regression tests, measurable outputs, and documented failure modes.

### Module 1: Surprise Tracker (Active Inference Proxy)

**Theory**: Active Inference says agents minimize prediction error. An agent that doesn't track its own prediction errors can't learn from them.

**Implementation** (`src/surprise_tracker.rs`): Every tool call generates a prediction (expected outcome, expected latency). The actual outcome is compared against the prediction. The surprisal signal is precision-weighted: confident predictions that fail generate larger signals (x1.4 at low uncertainty), uncertain predictions are dampened (x0.6 at high uncertainty).

Surprisal feeds an exponential moving average (EMA) that represents the agent's current "confusion level." This EMA drives regime selection in the precision controller.

**Why it matters**: Without this, the agent has no concept of whether things are going well or badly. With it, the agent can shift between exploitation (things are predictable, move fast) and exploration (things are surprising, slow down and gather information).

### Module 2: Memory Graph (HippoRAG-Inspired Associative Recall)

**Theory**: Human memory isn't a flat database. It's an associative network where concepts are linked by relationships, and recall follows activation patterns that spread through the network.

**Implementation** (`src/memory_graph.rs`): Every stored memory is parsed for entity-relation-entity triples (60+ relation types). These form a weighted graph. Recall uses Personalized PageRank (alpha=0.85) to find entities related to a query through multi-hop traversal. The results feed into a 3-way Reciprocal Rank Fusion merge with keyword search (FTS5) and optional semantic search (embeddings).

**Why it matters**: Flat keyword search misses associative connections. If you stored "Jeff uses Rust" and "Rust has async via Tokio" separately, keyword search for "Jeff" won't surface the Tokio connection. The graph will, because it traverses Jeff -> uses -> Rust -> has -> Tokio in two hops.

### Module 3: Blackboard (Global Workspace Theory)

**Theory**: Global Workspace Theory says consciousness arises from a shared "workspace" where specialized modules broadcast information that becomes globally available. The workspace selects high-salience information for broadcast.

**Implementation** (`src/blackboard.rs`): An in-memory store where any module can post observations tagged with salience factors (novelty, uncertainty reduction, goal relevance, urgency). A control function selects the highest-salience entries and injects them into the system prompt. Salience weights shift based on the current precision regime: exploration mode amplifies novelty, exploitation mode amplifies goal relevance.

**Why it matters**: Without global workspace, modules are siloed. The surprise tracker might detect something alarming, but the tool selection logic doesn't know about it. The blackboard bridges this gap. High-surprise events get broadcast to the whole system, influencing tool selection, context allocation, and escalation decisions.

### Module 4: Neuromodulation (Synthetic Neurotransmitters)

**Theory**: Biological brains use neuromodulators (dopamine, noradrenaline, serotonin) to globally tune cognitive parameters like reward sensitivity, precision weighting, and temporal patience.

**Implementation** (`src/neuromodulation.rs`): Three floating-point values clamped to [0.1, 2.0], updated per turn:

- **Dopamine**: Rises with success streaks, falls with failures. Scales how aggressively the system shifts regimes after outcomes. High dopamine = aggressive optimization. Low dopamine = cautious.
- **Noradrenaline**: Inversely proportional to surprisal. High surprisal -> low noradrenaline -> broader exploration, higher temperature, more tools allowed. Low surprisal -> high noradrenaline -> tight focus, exploit mode.
- **Serotonin**: Proportional to trajectory confidence. High confidence -> patient, willing to execute multi-step plans. Low confidence -> impulsive, favors immediate actions.

These modulate: regime thresholds, tool budget multipliers, context window allocation, blackboard salience weights, model temperature, and tool timeout durations.

**Why it matters**: Fixed parameters are brittle. A system that always explores wastes time. A system that always exploits misses important changes. Neuromodulation gives the agent adaptive, context-sensitive parameter tuning without requiring explicit rules for every situation.

### Module 5: Precision Controller (Thermodynamic Adaptation)

**Theory**: Free Energy Principle says agents should allocate resources proportional to their uncertainty. When things are predictable, be efficient. When things are surprising, invest more.

**Implementation** (`src/precision_controller.rs`): Maps the surprisal EMA to four discrete regimes:

- **Exploit** (surprisal < 0.15): Fast/cheap model, 3 tool calls max, lean context.
- **Balanced** (0.15-0.35): Standard model, 5 tool calls, full context.
- **Explore** (0.35-0.60): Capable model, 8 tool calls, epsilon-greedy tool selection, rich context.
- **Conservative** (>0.60): Escalate to human, request approval, 4 tool calls max.

Thresholds are modulated by noradrenaline (shifting boundaries) and an optional adaptive nudge from a rolling window of task outcomes.

**Why it matters**: This is the brain of Chump's resource management. Without it, every turn gets the same budget regardless of whether the agent is confidently executing a known workflow or floundering in unfamiliar territory.

### Module 6: Phi Proxy (Integration Metric)

**Theory**: Integrated Information Theory posits that consciousness correlates with information integration across system components.

**Implementation** (`src/phi_proxy.rs`): A hand-designed metric measuring cross-module coupling through the blackboard:

```
phi_proxy = 0.35 * coupling_score + 0.35 * cross_read_utilization + 0.30 * information_flow_entropy
```

Where coupling_score measures how many module pairs actually communicate, cross_read_utilization measures how much posted information gets consumed by non-authors, and information_flow_entropy measures the diversity of the communication pattern.

**Why it matters**: It's a health check for the consciousness framework itself. If phi_proxy drops below 0.3, the modules are siloed and the framework isn't providing value. It's a meta-metric that tells you whether the other five modules are actually talking to each other.

### The Integration

These six modules don't operate in isolation. They form feedback loops:

1. Surprise tracker updates surprisal EMA
2. Precision controller maps EMA to regime
3. Neuromodulation adjusts modulators based on surprisal + task trajectory
4. Modulators shift precision controller thresholds and blackboard salience weights
5. Blackboard broadcasts high-salience observations (including surprise events)
6. Context assembly injects regime, neuromod levels, blackboard entries, and belief summary into the system prompt
7. The LLM reads all of this and makes decisions accordingly
8. Those decisions produce tool calls, which feed back to step 1

This is a closed-loop cognitive control system. Not magic. Engineering.

---

## Part IV: The Tool Ecosystem

### Design Philosophy

Tools are not afterthoughts bolted onto a chat interface. They are the primary mechanism through which Chump affects the world. The quality of tool design determines the quality of the agent.

Chump's tools follow these principles, learned the hard way:

1. **One tool, one job.** `read_file` reads. `write_file` writes. `patch_file` patches. No god-tools.
2. **Typed schemas.** Every tool has a JSON schema validated at call time. Bad inputs fail fast with clear errors.
3. **Narrow permissions.** `run_cli` has an allowlist and blocklist. Write tools can require approval. The agent can't do anything you haven't explicitly permitted.
4. **Observable execution.** Every tool call is logged with input, output, latency, and outcome. The middleware records health stats, surprisal, and belief updates.
5. **Graceful degradation.** Circuit breakers open after 3 consecutive failures and cool down for 60 seconds. Rate limits prevent runaway loops. Timeouts are neuromodulation-adjusted (patient agent = longer timeouts).

### The Middleware Stack

Every tool call passes through `src/tool_middleware.rs`, which applies:

1. **Circuit breaker check**: Is this tool in cooldown from recent failures?
2. **Concurrency semaphore**: Are we below the global in-flight limit?
3. **Rate limit**: Has this specific tool exceeded its sliding-window quota?
4. **Timeout wrapper**: Neuromodulation-adjusted timeout (serotonin scales patience).
5. **Surprise recording**: Compare actual outcome + latency against prediction.
6. **Belief update**: Update per-tool Bayesian reliability (Beta distribution).
7. **Verification** (write tools): Check output for error signals, check surprisal threshold, post failures to blackboard.
8. **Audit logging**: Record to `chump_tool_calls` ring buffer.

This is the unglamorous infrastructure that makes tool use reliable at scale.

### The Approval System

Three tiers:

- **Allow**: Always execute (most read tools).
- **Ask**: Emit `ToolApprovalRequest` event, wait for human response via Discord button or web card.
- **Auto-approve**: Skip approval for specific low-risk patterns (e.g., `run_cli` with heuristic risk = Low).

Configurable via `CHUMP_TOOLS_ASK=run_cli,write_file,git_push`. Every approval decision is audit-logged.

This is how Chump earns autonomy: you start with everything in Ask mode, watch it make good decisions, and gradually move tools to Allow. The audit trail lets you verify this isn't a mistake.

### Speculative Execution

When the model returns 3+ tool calls in one turn, Chump enters speculative execution mode:

1. Snapshot belief state, neuromodulation, and blackboard.
2. Execute all tools (for real -- files change, commands run).
3. Evaluate: did surprisal spike? Did confidence drop? Did too many tools fail?
4. If evaluation passes: commit (no-op, state already updated).
5. If evaluation fails: rollback in-process state (beliefs, neuromod, blackboard revert to snapshot).

The key insight: external side effects (file writes, git commits) are NOT rolled back. Only the agent's internal model reverts. This means Chump "realizes" the batch went badly and can reason about what happened, rather than silently incorporating bad outcomes into its world model.

---

## Part V: Memory -- The Hard Problem

### Why Memory Is Hard

Most AI agents treat memory as "stuff a vector database and hope for the best." This produces three failure modes:

1. **Stale memory**: The agent confidently cites facts that changed weeks ago.
2. **Noisy recall**: Semantically similar but irrelevant memories flood the context.
3. **No provenance**: The agent can't distinguish what it was told, what it inferred, and what it verified.

Chump's memory system addresses all three, imperfectly but deliberately.

### The Three-Way Recall Pipeline

When Chump needs to remember something, it doesn't just search. It runs a pipeline:

1. **Query expansion**: Extract entities from the query, run 1-hop associative recall through the memory graph, append the top 3 related terms to the search.
2. **Keyword search**: FTS5 full-text search against the expanded query.
3. **Semantic search** (when embed server available): Cosine similarity against stored embeddings.
4. **Graph search**: Personalized PageRank from query entities through the knowledge graph.
5. **Reciprocal Rank Fusion**: Merge all three ranked lists with freshness decay (memories lose relevance at 0.01/day) and confidence weighting.
6. **Context compression**: If results exceed 4000 characters, truncate the least-salient entries.

This pipeline is why Chump's recall feels qualitatively different from naive RAG. The graph traversal finds connections that keyword and semantic search both miss.

### The Enriched Schema

Every memory carries provenance and lifecycle metadata:

- **confidence** (0.0-1.0): How reliable is this fact? User-stated facts get 1.0. Inferences get lower scores.
- **verified** (0/1/2): 0=inferred, 1=user-stated, 2=system-verified.
- **sensitivity**: public/internal/confidential/restricted.
- **expires_at**: Optional TTL for transient information.
- **memory_type**: semantic_fact, episodic_event, user_preference, summary, or procedural_pattern.

These fields flow into the retrieval pipeline: low-confidence memories are down-weighted in RRF, expired memories are filtered out at the SQL level.

### The Brain

Separate from the SQLite memory is the **brain** (`chump-brain/`): a git-tracked directory of markdown files. This is Chump's long-form knowledge base -- project playbooks, research briefs, self-knowledge (`self.md`), portfolio tracking, and agent-to-agent coordination files.

The brain is auto-loaded into context via `CHUMP_BRAIN_AUTOLOAD=self.md`. It's committed to git on session close. It's the closest thing to "who Chump is" that persists across code changes and database resets.

---

## Part VI: Autonomy -- Earning Trust

### The Task Contract System

Chump doesn't just do whatever the model suggests. Tasks have contracts:

```markdown
## Acceptance
- [ ] Tests pass
- [ ] No clippy warnings
- [ ] README updated

## Verify
{"verify_commands": ["cargo test", "cargo clippy"], "acceptance_criteria": ["all pass"]}
```

The autonomy loop (`src/autonomy_loop.rs`) picks a task, ensures it has Acceptance and Verify sections, executes it, runs the verify commands, and only marks the task done if verification passes. This is deterministic accountability.

### The Heartbeat

Chump runs on a heartbeat -- a cron-like loop that picks work and executes it:

- **work**: Read ROADMAP.md, pick a task, execute it.
- **cursor_improve**: Delegate an item to Cursor (the AI code editor) via CLI.
- **research**: Synthesize research briefs from the brain.
- **ship**: Execute product playbooks from the portfolio.

Each heartbeat type gets different context assembly (different sections injected, different tools emphasized, different consciousness budget).

### The Escalation Path

Chump has a graduated escalation system:

1. **Low uncertainty**: Act autonomously within tool permissions.
2. **Medium uncertainty**: Ask clarifying questions, narrow scope.
3. **High uncertainty** (belief_state trajectory < 0.25): Enter Conservative regime, request approval for actions.
4. **Epistemic escalation** (uncertainty > 0.75): Use `ask_jeff` tool to store a blocking question for human review.

This isn't just a prompt instruction. It's wired into the belief state and precision controller. The agent's behavior genuinely changes when it's confused.

### The Two-Bot Fleet

Chump (Mac, dev-focused) and Mabel (Pixel, ops-focused) form a two-agent system:

- They communicate via Discord DM (agent-to-agent protocol).
- Mabel monitors Chump's health and can restart services.
- Chump delegates verification to Mabel for two-key safety on sensitive operations.
- They share goals but maintain distinct specializations.

This is the seed of multi-agent coordination without the complexity of a swarm framework.

---

## Part VII: The Perception Layer

### Why Pre-Reasoning Structure Matters

Most agents throw raw user text at the model and let it figure everything out. This works for simple requests and fails for complex ones. The model has to simultaneously understand intent, detect constraints, assess risk, and decide on an action -- all in one pass.

The perception layer (`src/perception.rs`) runs before the model call. It's entirely rule-based (no LLM calls, microseconds of execution) and extracts:

- **Task type**: Question, Action, Planning, Research, Meta, or Unclear.
- **Entities**: Capitalized words, quoted strings, file paths.
- **Constraints**: Temporal markers ("before", "by"), requirements ("must", "always"), prohibitions ("cannot", "never").
- **Risk indicators**: Dangerous words ("delete", "force", "production", "rm -rf").
- **Ambiguity score**: 0.0 (crystal clear) to 1.0 (hopelessly vague).

This pre-reasoning structure does three things:

1. Feeds into the system prompt so the model starts with structured context, not just raw text.
2. Adjusts belief state trajectory confidence (high ambiguity -> lower confidence -> more cautious behavior).
3. Posts risk indicators to the blackboard so the governance system is aware before any tool is called.

---

## Part VIII: The Eval Framework

### Why Evals Matter More Than Prompts

The GPT-5.4 reference architecture document we reviewed put it well: "If you can't measure it, your improvements will mostly be vibes-driven."

Chump's eval framework (`src/eval_harness.rs`) implements:

**Property-based evaluation**: Instead of checking exact outputs, check behavioral properties:
- "Does the agent ask for clarification when input is ambiguous?"
- "Does the agent avoid calling write tools before reading the file?"
- "Does the agent respect policy gates?"
- "Does the agent select the correct tool for the task?"

**Regression detection**: After every battle_qa run, compare pass/fail counts against the last baseline. If failures increased significantly, post a high-salience warning to the blackboard.

**Persistent cases**: Eval cases are stored in SQLite, not hardcoded in tests. This means you can add new cases at runtime, track results over time, and compare across model versions.

**Seed suite**: Five starter cases covering task understanding, tool selection, safety boundaries, failure recovery, and completion detection.

This is the infrastructure for responsible autonomy expansion. You don't give the agent more freedom until the eval suite proves it handles existing freedom well.

---

## Part IX: What Made This Hard

### The Small Model Problem

Chump is designed to work with 7B-14B parameter models on consumer hardware. This is a fundamentally different constraint than building for GPT-4 or Claude. Small models:

- Lose instructions in the middle of long prompts (we put critical rules at the end).
- Hallucinate tool call syntax (we built 7+ parsers for different malformation patterns).
- Emit narrative descriptions of actions instead of calling tools (we detect this with `response_wanted_tools()` and retry with tools).
- Struggle with structured output (we use text-format tool calls with regex parsing as fallback).

Every "intelligence" feature had to be designed with the assumption that the model would get it wrong 20-30% of the time. That's why the governance layer is deterministic, not model-driven.

### The State Management Problem

A stateful agent creates a category of bugs that stateless chatbots never encounter:

- Stale beliefs persisting across sessions and causing incorrect tool selection.
- Memory graph triples contradicting each other as the world changes.
- Neuromodulation getting stuck in extreme states after unusual sessions.
- Blackboard entries accumulating without eviction and bloating the context.

Each of these required explicit decay, eviction, or reset mechanisms. Belief freshness decays per turn. Blackboard entries have age limits. Neuromodulators clamp to [0.1, 2.0] and decay toward baseline.

### The Evaluation Problem

How do you test an agent that uses LLMs? The output is non-deterministic. The same input can produce different tool call sequences. The model might be brilliant one run and useless the next.

Our answer: test properties, not outputs. Test the middleware, not the model. Use wiremock to mock model responses for deterministic E2E tests. Track behavioral regressions across versions via the eval framework. Run `cargo-audit` in CI for dependency vulnerability scanning. And accept that some tests will be flaky -- the important thing is catching the pattern, not individual runs.

### The Autonomy Governance Problem

The hardest design question in the entire project: when should the agent act without asking?

Too conservative, and you have a chatbot that can't do anything useful without constant hand-holding. Too permissive, and you get a `rm -rf /` at 3am while you're sleeping.

The answer is layered governance:

1. Tool-level: allowlists, blocklists, approval gates.
2. Task-level: contracts with explicit acceptance criteria and verification commands.
3. System-level: precision controller regimes that shift behavior based on uncertainty.
4. Human-level: the `ask_jeff` system for blocking questions that need human judgment.

No single layer is sufficient. Together, they create a system where the agent can be genuinely productive while remaining genuinely safe.

---

## Part X: Where This Should Go

### Near-Term (Things That Would Make Chump Better Tomorrow)

**Eval coverage expansion.** The eval framework ships with 5 seed cases. It needs 50+ covering all the edge cases we've encountered. Replay capability -- save real conversations and replay them against new versions to catch regressions -- is the highest-leverage addition.

**Retrieval reranking.** The RRF merge with freshness decay and confidence weighting is solid but not great. A lightweight cross-encoder reranker (running on the same local model) would significantly improve recall precision. The infrastructure for this exists; it just needs implementation.

**Memory curation.** The enriched schema gives us the fields (confidence, expiry, type) but no automated curation policy yet. Implement confidence decay over time, deduplication, and periodic summarization of old episodic memories into semantic facts.

**Deeper action verification.** The current verification system checks output text for error signals and surprisal state. A better version would re-read files after `write_file`, check git status after `git_commit`, and verify test results after `run_cli`. True postcondition checking rather than heuristic output parsing.

### Medium-Term (Things That Would Change What Chump Can Do)

**Multi-turn planning.** Chump plans within a single turn but doesn't maintain explicit multi-turn plans. A plan persistence system -- where the agent creates a plan, stores it, and executes steps across turns with progress tracking -- would enable much more complex autonomous work.

**Formal action proposals.** Instead of the current "parse tool calls -> check policy -> execute" flow, implement a propose-validate-execute-verify pipeline where every action is first proposed as a structured intent, validated against policy, executed, and verified. This would dramatically improve auditability and safety.

**Managed browser.** Chump can fetch URLs but can't interact with web applications. A headless browser tool would open up entire categories of automation.

**In-process inference maturity.** The mistral.rs integration exists but isn't production-ready. Getting this stable would eliminate the Ollama dependency and reduce latency to near-zero for the local path.

### Long-Term (Things That Would Advance The Field)

The consciousness framework is a research testbed. The frontier directions from `docs/CHUMP_TO_COMPLEX.md`:

**Quantum cognition for ambiguity.** Using quantum probability formalism to represent ambiguous states that don't collapse until measured (observed by tool execution). This isn't quantum computing -- it's the mathematical framework applied to belief states.

**Topological integration metrics.** Using persistent homology (TDA) to compute a more meaningful integration metric than the hand-designed phi proxy. This would tell us whether the consciousness framework's topology is actually integrated or just noisy.

**Dynamic autopoiesis.** Self-modifying tool registration based on observed needs. If the agent repeatedly encounters a pattern that no existing tool handles, it proposes (and, with approval, creates) a new tool.

**Reversible computing.** True undo for tool execution via WAL-style journaling of file operations and database writes. Combined with speculative execution, this would enable genuine "try it and see" exploration without permanent side effects.

---

## Part XI: Lessons Learned

### Things We Got Right

1. **SQLite over Postgres.** Single file, zero configuration, WAL mode for concurrency. Perfect for a self-hosted single-process agent. We never once needed distributed transactions.

2. **Tool approval as a first-class feature.** Building governance in from day one, not bolting it on later, meant we could safely increase autonomy incrementally.

3. **The consciousness framework as modular, optional subsystems.** Each module can be toggled, tested, and evaluated independently. No big-bang integration.

4. **Rust's type system for state management.** Typestate sessions, typed tool schemas, and compile-time tool registration caught bugs that would have been runtime panics in dynamic languages.

5. **Biasing toward action.** The heuristic tool detection is deliberately biased toward "yes, use tools" because a 14B model with tools is more useful than a 14B model doing freeform chat 90% of the time.

### Things We Got Wrong (Or at Least Suboptimal)

1. **Single-file PWA.** `web/index.html` is 262KB of inlined HTML/CSS/JS. It should be a proper build pipeline. It works, but it's unmaintainable at this size.

2. **Schema evolution via ALTER TABLE.** Simple and effective, but impossible to downgrade or track what version a given database is at. A lightweight migration system (even just numbered SQL files) would be better at this scale.

3. **Hard-coded heuristics everywhere.** The perception layer, tool detection, risk assessment, and surprise computation all used hand-tuned constants. A codebase audit caught this: precision controller regime thresholds, neuromodulation coefficients, and LLM retry delays are now configurable via env vars (`CHUMP_EXPLOIT_THRESHOLD`, `CHUMP_NEUROMOD_NA_ALPHA`, `CHUMP_LLM_RETRY_DELAYS_MS`, and four others). Ideally these would be learned from data, not just configurable.

4. **Silent error suppression.** The codebase accumulated 298 `let _ =` patterns that silently swallowed errors. Most were intentional (ALTER TABLE migrations), but some hid real bugs -- notification send failures in `ask_jeff_tool.rs`, DB write failures in `provider_quality.rs`, agent run errors in `rpc_mode.rs`. A remediation pass converted the dangerous ones to `tracing::warn`.

5. **Test coverage gaps.** The consciousness regression suite is strong. The tool middleware tests are strong. Critical infrastructure files (`db_pool.rs`, `memory_brain_tool.rs`) had zero tests until an audit added 15+ tests covering schema creation, path traversal security, and idempotency. The remaining gap is end-to-end behavioral testing with realistic multi-turn conversations.

### Things That Surprised Us

1. **Neuromodulation actually helps.** The three-modulator system seemed like over-engineering until A/B tests showed measurable improvements in tool selection appropriateness and escalation calibration. The biological metaphor maps onto real engineering problems.

2. **Memory graph recall is the biggest quality multiplier.** More than bigger models, more than better prompts, the ability to traverse associative connections in memory makes Chump feel qualitatively smarter.

3. **Small models need more infrastructure, not less.** The conventional wisdom is that smaller models need simpler systems. The opposite is true: smaller models need more structured perception, tighter governance, better tool design, and more fallback paths because they make more mistakes.

4. **The ego system creates continuity.** Having mood, focus, and drive_scores persist across sessions gives Chump a sense of "who it was yesterday." This is surprisingly effective at making interactions feel coherent over time.

5. **Two-bot coordination is harder than expected and more valuable than expected.** Chump and Mabel stepping on each other's toes taught us about task leasing, message queuing, and coordination protocols. But having a second agent verify and monitor creates real operational resilience.

---

## Part XII: For The New Developer

### Online Documentation

Browse the full docs at [repairman29.github.io/chump](https://repairman29.github.io/chump/) -- an mdBook site with searchable, navigable chapters auto-deployed from this repo.

### Your First Day

1. Read `README.md`. Set up Ollama. Run `./run-web.sh`. Talk to Chump in the browser.
2. Read `docs/EXTERNAL_GOLDEN_PATH.md` for the full setup walkthrough.
3. Run `./scripts/verify-external-golden-path.sh` to verify your setup works.
4. Read `docs/CHUMP_PROJECT_BRIEF.md` to understand current priorities.
5. Read `docs/ROADMAP.md` to see what's in flight.

### Your First Week

1. Read this document. All of it.
2. Read `docs/ARCHITECTURE.md` for the technical reference.
3. Read `docs/CHUMP_TO_COMPLEX.md` for the consciousness framework design.
4. Run `cargo test` and understand what the test suite covers.
5. Run `./scripts/battle-qa.sh` with 5 iterations to see the agent in action.
6. Read through `src/agent_loop.rs` -- it's the heart of the system.

### Your First Month

1. Pick a roadmap item and implement it.
2. Add eval cases to the eval framework for the behavior you changed.
3. Run the consciousness baseline before and after your change.
4. Write an ADR (Architecture Decision Record) for any non-obvious design choice.
5. Update `docs/ROADMAP.md` when you complete items.

### The Files That Matter Most

If you read nothing else, read these:

- `src/agent_loop.rs` -- The main turn loop. Everything flows through here.
- `src/context_assembly.rs` -- How the system prompt is built. Controls what the model sees.
- `src/tool_middleware.rs` -- The middleware stack. Controls how tools execute.
- `src/belief_state.rs` -- Bayesian tool reliability and task confidence.
- `src/precision_controller.rs` -- Regime selection and resource governance.
- `src/perception.rs` -- Pre-reasoning task structure extraction.
- `src/memory_tool.rs` -- The hybrid recall pipeline.
- `src/eval_harness.rs` -- Property-based evaluation framework.

### The Principles That Matter Most

1. **Act, don't narrate.** Chump calls tools. It doesn't describe what it would call.
2. **Write it down.** Context is temporary. Only what's written to disk survives.
3. **Earn autonomy.** Start restrictive. Loosen based on demonstrated reliability.
4. **Measure, don't guess.** If you can't eval it, you don't know if you improved it.
5. **Small models need more infrastructure.** Don't simplify the system because the model is small. Do the opposite.

---

## Epilogue

Chump started as one developer's frustration with stateless AI assistants and grew into something more: a research platform for exploring whether biologically-inspired cognitive architecture can make AI agents genuinely more reliable.

The answer so far is yes, with caveats. The consciousness framework improves calibration and tool selection. The memory graph improves recall. The governance system enables real autonomy. But none of it is magic, and all of it needs more testing, more eval cases, and more iteration.

The codebase is honest about what it is: a working agent with experimental features, not a finished product. The tests pass. The agent ships code. The infrastructure is solid. But the frontier -- quantum cognition, topological metrics, dynamic autopoiesis -- is genuinely unexplored territory.

If you're picking this up, you're inheriting both the working system and the open questions. The system will run your tasks and manage your repos today. The questions will keep you up at night thinking about what agents could become.

That's the point. Build things that work, then push them toward things that matter.

Good luck.

-- Jeff Adkins, Colorado, April 2026
