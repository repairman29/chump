# Chump: research brief for external review

**Purpose:** A concise, technically accurate description of **Chump** as implemented today—suitable for cognitive scientists, neuroscientists, AI safety researchers, and systems engineers who want to evaluate architecture and claims without reading the whole codebase.

**Repository:** [repairman29/Chump](https://github.com/repairman29/Chump) (Rust; primary binary name `chump`).

**Related internal docs:** [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md), [ARCHITECTURE.md](ARCHITECTURE.md), [ROADMAP.md](ROADMAP.md), [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md), [AGENTS.md](../AGENTS.md).

---

## 1. Executive summary

**Chump** is a **local-first software agent**: a single Rust process that orchestrates calls to an **OpenAI-compatible LLM** (typically vLLM-MLX on port 8000 or Ollama on 11434), exposes a **tool-using** policy (CLI, filesystem, GitHub, memory, scheduling, etc.), and persists state in **SQLite**. It runs as a **Discord bot**, **CLI**, **RPC**, and optional **web** surfaces, sharing one agent loop implementation.

A recent engineering addition is a **“synthetic consciousness framework”**: six **operational modules** that log metrics, bias routing, and inject short summaries into the system prompt. These are **computational analogues** inspired by Active Inference, associative memory graphs, global workspace–style broadcasting, counterfactual/causal heuristics, precision/energy budgeting, and a coarse **integration proxy** (“phi proxy”). They are **not** claims that the system is conscious or that the brain is implemented; they are **instrumented control-and-telemetry layers** whose value is an **empirical question** (measurably better tool use, stability, or calibration—or not).

---

## 2. System boundary and deployment

| Aspect | Today’s implementation |
|--------|-------------------------|
| **Language / runtime** | Rust (Tokio async), `axum` HTTP for health/approval APIs |
| **Agent framework** | **AxonerAI**: provider abstraction, tool registry, sessions |
| **Model** | External OpenAI-compatible server; configurable base URL and model name |
| **Persistence** | SQLite (WAL, pooled connections): memory (FTS5), tasks, episodes, schedules, tool health, prediction log, memory graph triples, causal lessons, etc. |
| **Primary UX** | Discord (per-channel sessions); CLI for dev and heartbeat-style runs |
| **Observability** | `tracing`, structured logs, `GET /health` including a **consciousness dashboard** JSON aggregate |

**Fleet context (optional):** The project also describes **multi-node** operation (e.g. Mac + Pixel “Mabel”) and shared roadmaps; the **core agent** remains one Rust binary with environment-driven configuration.

---

## 3. What “Chump” does in one turn (Discord or CLI)

1. **Preflight:** Check model server reachability (timeout configurable, e.g. `CHUMP_MODEL_PREFLIGHT_TIMEOUT_SECS`).
2. **Context assembly:** Build a **system prompt** from hard rules, tool/routing hints, **round-filtered** sections (work vs research vs cursor_improve, etc.), **file watcher** “recently changed” paths, **proactive memory recall** (keyword + optional semantic embeddings + graph-assisted recall), **task/schedule/episode** excerpts, and—when active—the **consciousness summaries** (surprise, blackboard, lessons, precision, integration metric).
3. **Model call:** Send conversation history + tool schemas to the provider; support **native tool calls** and a **text fallback** parser for models that emit `Using tool '…' with input: {…}` on end-of-turn.
4. **Tool execution:** Each tool runs through **middleware** (timeout, health recording, **surprise** / **energy** accounting, optional **tool-call budget** warnings to a shared **blackboard**). Some tools require **human approval** (`CHUMP_TOOLS_ASK` + Discord/Web resolver).
5. **Loop:** Repeat model ↔ tool until end-turn or iteration cap; optionally **continuation** batch to reduce “keep going” friction.
6. **Session lifecycle:** Typestate `Session` (CLI) reduces invalid ordering; `close_session` can run housekeeping (e.g. mark surfaced causal lessons).

**Provider routing:** A **cascade** can prefer different API slots (local vs cloud) by environment; **precision regime** (explore/exploit-style) can **bias** slot choice and how much explanatory context is injected.

---

## 4. Tools and autonomy surface (representative, not exhaustive)

- **Execution:** `run_cli` with allowlist/blocklist, caps, middle-trim on long output; optional executive mode (dangerous; audited).
- **Codebase:** `read_file`, `list_dir`, `write_file`, `edit_file`, `diff_review`, GitHub helpers when configured.
- **Cognition helpers:** `delegate` (summarize, extract, classify, validate) on a worker model; `web_search` (Tavily); `read_url`.
- **Brain / state:** `task`, `schedule`, `episode_log`, `memory` store/recall, `notify`, etc.
- **Meta:** `run_cli` can invoke **Cursor CLI** for delegated coding (see [CHUMP_CURSOR_PROTOCOL.md](CHUMP_CURSOR_PROTOCOL.md)).

This is a **broad tool graph**; risk is mitigated by policy, timeouts, circuit breakers, and optional approval—not by the consciousness layer alone.

---

## 5. Memory and state

- **Episodic / narrative:** Episodes logged to SQLite; sentiment and frustration cues can feed **counterfactual** lesson extraction (heuristic text patterns, not causal discovery from interventions).
- **Declarative memory:** FTS5 keyword search; optional **semantic** channel (embed server or in-process `fastembed`); **RRF-style fusion** plus **graph** suggestions from subject–relation–object triples extracted heuristically from stored text.
- **Associative graph:** Stored triples with weights; recall uses bounded multi-hop traversal with damping (PageRank-inspired), not a learned knowledge graph.

---

## 6. The “synthetic consciousness framework” (engineering view)

**Naming note:** The label is **motivational and thematic**. For scientific audiences, treat each piece as a **named subsystem** with **inputs, outputs, and logs**.

| Module | Role (as built) | Typical signals |
|--------|------------------|-----------------|
| **surprise_tracker** | Prediction-error style **surprisal** from tool outcomes and latency vs EMA; logs to DB; high surprise → **blackboard** post | EMA surprisal, counts, per-tool stats |
| **memory_graph** | Extract/store triples; **associative_recall** for RRF | Triple counts, recall contributors |
| **blackboard** | Shared workspace: salience, novelty, cross-module **read** tracking | Broadcast text to context; phi uses cross-reads |
| **counterfactual** | After certain episodes, **heuristic** “lessons” stored and retrieved into context; confidence decay / apply tracking | Lesson count, failure patterns (aggregated) |
| **precision_controller** | Discrete **regimes** (e.g. exploit vs explore); recommends model tier, tool budgets, **energy** counters; may post regime changes | Regime, budgets, escalation rate |
| **phi_proxy** | Scalar/graph summary of **module coupling** via blackboard activity (proxy for “integration,” not IIT Φ) | Dashboard JSON, optional context line |

**Regime-dependent behavior:** Context injection can be **richer or leaner** depending on regime; provider slot choice can be **biased**; per-turn tool volume can trigger **blackboard** warnings.

**Evaluation hooks:** Integration tests (`consciousness_tests`), wiremock **E2E bot tests** (full pipeline without a live LLM), shell scripts (`consciousness-baseline.sh`, `consciousness-report.sh`), and battle QA can snapshot baselines after runs.

---

## 7. Safety, governance, and reliability (selected)

- Tool **allow / deny / ask** policy; heuristic risk scoring for dangerous CLI patterns.
- **Audit** logging for approvals; **circuit breakers** and tool health DB.
- **Input/output caps**; kill switch via env or `logs/pause`.
- **Secrets redaction** in logs (best-effort).

---

## 8. Explicit non-claims

Reviewers should not infer the following from the codebase or naming:

- Chump is **not** asserted to be phenomenally conscious or to possess **qualia**.
- **phi_proxy** is **not** Integrated Information Theory’s Φ computed on a physical substrate; it is a **hand-designed graph statistic** on module traffic.
- **counterfactual** lessons are **not** causal effects identified via randomized experiments; they are **text heuristics** over logged episodes.
- **Active Inference**-style quantities are **operationalized** as surprisal and budgets, not the full variational mechanics of a generative model.

---

## 9. Questions we would ask frontier scientists

1. **Validity:** Which of the proxies (surprisal, coupling, regime switches) correlate with **human-judged** errors, **task success**, or **calibration** in controlled tasks?
2. **Redundancy:** Do blackboard + graph + memory fusion provide **marginal gain** over a simpler memory-only baseline under A/B tests?
3. **Counterfactuals:** How should **lesson extraction** be upgraded (e.g. explicit counterfactual prompts to the LLM, structured JSON, human review) without **false certainty**?
4. **Safety:** Does regime-driven **cloud bias** or **tool budget** pressure create **predictable failure modes** (e.g. under-tooling, over-delegation)?
5. **Measurement:** What **benchmarks** (beyond unit/integration tests) would you require to take this line of work seriously in publication form?

---

## 10. Reproducibility

- Build and test: `cargo test` (100+ tests as of recent mainline, including consciousness and E2E mock flows).
- Ops: see [OPERATIONS.md](OPERATIONS.md) and [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md).
- Environment: `.env.example` lists key variables (model URL, Discord token, optional cascade keys, consciousness tunables).

---

## 11. One-paragraph pitch (for email forward)

Chump is an open, local-first Rust agent that drives a tool-using LLM against SQLite-backed memory, tasks, and episodes, with Discord and CLI entry points. It couples that core loop to a new **instrumented “consciousness-inspired” layer**: surprisal and latency tracking, a salience-based blackboard, associative memory triples, heuristic causal lessons, regime-based precision/energy budgeting, and a coarse integration proxy—all logged and partially surfaced to the model. The research question is whether these structures improve **measurable** agent behavior (stability, appropriate tool use, calibration) rather than whether the system is conscious; we welcome critique of the **scientific mapping** from theory names to code and suggestions for **rigorous evaluation**.

---

*Document version: aligned with repository architecture as of 2026; update when major subsystems change.*
