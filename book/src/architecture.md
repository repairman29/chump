# System Architecture

> _A reference summary. For the full technical narrative including Mermaid diagrams,
> Rust type signatures, and contributor guidance, read [The Dissertation](./dissertation.md)._

---

## Process Model

Chump is a **single Rust binary** (`chump`) with five entry points sharing one
SQLite database and one consciousness substrate:

| Flag | Surface | Transport |
|---|---|---|
| `./run-web.sh` | Web PWA + REST API | HTTP/SSE on port 3000 (Axum) |
| `--chump "…"` | CLI REPL / one-shot | stdio |
| `--discord` | Discord bot | WebSocket gateway (Serenity) |
| `--acp` | ACP server | JSON-RPC over stdio |
| `--autonomy-once` | Autonomous heartbeat | internal |

All surfaces share one agent loop (`src/agent_loop/`), one tool middleware stack
(`src/tool_middleware.rs`), and one consciousness substrate
(`src/consciousness_traits.rs`).

---

## Cognitive Loop

```
Input → Perception → Context Assembly → Model → Tool Middleware → State Updates → Output
           ↑                                           |
           └───────────── (1–15 tool iterations) ─────┘
```

1. **Perception** (`src/perception.rs`) — rule-based, zero LLM calls. Produces
   `PerceivedInput`: `TaskType` (Question / Action / Planning / Research / Meta /
   Unclear), detected entities, constraints, risk indicators, ambiguity score.

2. **Context Assembly** (`src/context_assembly.rs`) — builds the system prompt from
   ego state, tasks, memories, blackboard broadcast, belief summary, regime, and
   neuromodulation levels.

3. **Model** (`src/provider_cascade.rs`) — sends prompt to LLM (Ollama, vLLM,
   mistral.rs, or cloud cascade). Parses response; detects and retries if tool calls
   are missing or malformed.

4. **Tool Middleware** (`src/tool_middleware.rs`) — every tool call passes through:
   circuit breaker → concurrency semaphore → rate limiter → neuromod-adjusted
   timeout → execution → surprise recording → belief update → blackboard post →
   audit log.

5. **State Updates** — episode logged, neuromodulation updated, memory graph
   triples extracted, ego state written back.

---

## Data Layer

Single SQLite file (`{CHUMP_HOME}/chump.sqlite` or `sessions/chump_memory.db`),
WAL mode, 16-connection r2d2 pool (`src/db_pool.rs`).

Key tables:

| Table | Purpose |
|---|---|
| `chump_memory` | Declarative memory: FTS5 + confidence + provenance + TTL |
| `chump_memory_graph` | Entity-relation-entity triples for PPR associative recall |
| `chump_prediction_log` | Per-tool surprisal for Active Inference proxy |
| `chump_causal_lessons` | Counterfactual lessons from negative episodes |
| `chump_episodes` | Narrative history with sentiment and tags |
| `chump_tasks` | Work queue: priority, assignee, leases, acceptance criteria |
| `chump_tool_health` | Tool success/failure metrics |
| `chump_sessions` | Session metadata + ego state |
| `chump_eval_cases` | Property-based eval cases for regression detection |

Schema evolution via `ALTER TABLE ADD COLUMN` with `let _ =` (silently ignores
"already exists"). No migration framework.

---

## Consciousness Substrate

Nine modules, each implementing a trait in `src/consciousness_traits.rs`, unified
in a `ConsciousnessSubstrate` global singleton:

| # | Module | File | Trait |
|---|---|---|---|
| 1 | Surprise Tracker | `src/surprise_tracker.rs` | `SurpriseSource` |
| 2 | Belief State | `src/belief_state.rs` | `BeliefTracker` |
| 3 | Blackboard | `src/blackboard.rs` | `GlobalWorkspace` |
| 4 | Neuromodulation | `src/neuromodulation.rs` | `Neuromodulator` |
| 5 | Precision Controller | `src/precision_controller.rs` | `PrecisionPolicy` |
| 6 | Memory Graph | `src/memory_graph.rs` | `AssociativeMemory` |
| 7 | Counterfactual | `src/counterfactual.rs` | `CausalReasoner` |
| 8 | Phi Proxy | `src/phi_proxy.rs` | `IntegrationMetric` |
| 9 | Holographic Workspace | `src/holographic_workspace.rs` | `HolographicStore` |

The feedback loop: tool outcomes → Surprise Tracker → Precision Controller regime
→ Neuromodulation → modulate thresholds + blackboard salience weights → Context
Assembly → system prompt → LLM decisions → tools → back to step 1.

---

## Memory: Three-Path Recall

```
Query → expansion (1-hop PPR)
      → FTS5 keyword search
      → semantic search (optional embeddings)
      → graph PPR (alpha=0.85, multi-hop)
      → Reciprocal Rank Fusion (freshness decay + confidence weight)
      → context compression (4K char budget)
```

Every memory carries: `confidence` [0,1], `verified` (0/1/2), `sensitivity`,
`expires_at`, `memory_type` (semantic_fact / episodic_event / user_preference /
summary / procedural_pattern).

---

## Tool Governance

**Approval tiers** (configured via `CHUMP_TOOLS_ASK`):
- **Allow** — execute immediately (most read tools)
- **Ask** — emit `ToolApprovalRequest`; wait for Discord button, web card, or ACP
  `session/request_permission` response
- **Auto-approve** — low-risk heuristic patterns bypass the gate

**Circuit breaker:** opens after 3 consecutive failures, 60s cooldown.

**Speculative execution:** 3+ tool calls in one turn → snapshot beliefs/neuromod/
blackboard → execute all → evaluate surprisal + confidence → commit or rollback
in-process state (external side effects are not rolled back).

---

## ACP — Agent Client Protocol

`chump --acp` runs JSON-RPC over stdio implementing the
[Agent Client Protocol](https://agentclientprotocol.com).

**V1 methods:** `initialize`, `authenticate`, `session/{new, load, list, prompt,
cancel, set_mode, set_config_option}`.

**Agent-initiated RPCs (bidirectional):** `session/request_permission`,
`fs/{read_text_file, write_text_file}`, `terminal/{create, output, wait_for_exit,
kill, release}`.

Session state persists to `{CHUMP_HOME}/acp_sessions/{session_id}.json` (atomic
rename writes). When the editor declares `fs` or `terminal` capability, file and
shell operations delegate to the editor's environment — critical for SSH-remote and
devcontainer setups.

See [`docs/architecture/ACP.md`](https://github.com/repairman29/chump/blob/main/docs/architecture/ACP.md) for wire-level documentation.

---

## Provider Cascade

```
Request → local Ollama / vLLM (primary)
        → mistral.rs in-process (optional feature flag)
        → cloud API (CHUMP_FALLBACK_API_BASE, optional)
```

Retry with backoff (`CHUMP_LLM_RETRY_DELAYS_MS`), circuit breaker after 3 failures.
The Precision Controller's `ModelTier` recommendation (Fast / Standard / Capable /
Specialist) gates which providers are tried in each regime.

---

## Safety Controls

- **Kill switch:** `touch logs/pause` or `CHUMP_PAUSED=1`
- **Input caps:** `CHUMP_MAX_MESSAGE_LEN`, `CHUMP_MAX_TOOL_ARGS_LEN`
- **run_cli allowlist/blocklist:** `CHUMP_CLI_ALLOWLIST`, `CHUMP_CLI_BLOCKLIST`
- **Secret redaction:** in all log output
- **Audit log:** every tool call logged with input, output, latency, approval outcome
- **ask_jeff tool:** stores blocking questions for human review when uncertainty > 0.75

---

## Eval Framework

`src/eval_harness.rs` — property-based evaluation stored in SQLite:

- `EvalCase`: input + expected behavioral properties (contains, not_contains,
  json_path, regex)
- `EvalRun`: result per case per run, compared against baseline for regression
  detection
- Run via: `./scripts/ci/battle-qa.sh` or `cargo test eval`

Current seed suite: 5 cases. Target: 50+ covering multi-turn history and
context-window boundary behavior.
