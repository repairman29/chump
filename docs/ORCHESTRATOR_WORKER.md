# Orchestrator–worker design (Phase 3)

Minimal design for Chump: **one Chump** (orchestrator) who can use **as many workers (chimps)** as he wants. One orchestrator (main agent with tools) delegates subtasks to workers (single LLM calls with fixed prompts, no tools). The Rust host implements the state machine; the model does not control routing.

## Topology

- **Orchestrator (Chump):** The existing Chump agent (full tools, soul, session). One identity, one process. Decides when to delegate and interprets worker results.
- **Workers (chimps):** Single completion calls: system prompt + one user message, no tools, no session. Used for narrow tasks (summarize, extract, etc.). Same or smaller model via `OPENAI_API_BASE` or `CHUMP_WORKER_API_BASE`. Single task or **batch** (see below); many in parallel when Chump passes a `tasks` array (see [ROADMAP_PARALLEL_AGENTS](ROADMAP_PARALLEL_AGENTS.md)).

Handoffs are **tool calls**: the orchestrator calls a tool (e.g. `delegate`) with a fixed JSON schema; the host runs the worker and returns the result string. The model never sees the raw state machine.

## Handoff schema (deterministic)

The host defines the schema; the model fills it.

**Delegation request (tool input):**

- **Single task:** `task_type` (string enum, e.g. `"summarize"`), plus task-specific payload: e.g. for `summarize`, `text` (string), `max_sentences` (optional number).
- **Batch:** `tasks` (array of objects). Each item: `task_type`, `text`, and optionally `max_sentences` (summarize) or `instruction` (extract). The host runs tasks in parallel (up to **CHUMP_DELEGATE_MAX_PARALLEL**, default 4, cap 32).

**Delegation response (tool output):**

- **Single task:** A single string: the worker’s completion text (or an error message).
- **Batch:** Numbered lines: `1. &lt;result1&gt;\n2. &lt;result2&gt;...` (one line per task). No JSON so the orchestrator can use it naturally in the next turn.

## State machine (host-side)

1. User message → orchestrator.
2. Orchestrator runs (agent loop with tools).
3. If orchestrator calls `delegate` with valid `task_type` and payload:
   - Host builds worker system prompt for that task type.
   - Host calls `provider.complete([user: payload], None, max_tokens, Some(worker_system_prompt))` (no tools).
   - Host returns worker’s `.text` as the tool result.
4. Orchestrator continues with the tool result in context; may reply to the user or call more tools.

All branching (when to delegate, which task type) is in the model; all execution (running the worker, parsing, retries) is in the host.

## Delegated task types

### summarize

- **task_type:** `"summarize"`.
- **Payload:** `text` (string), optional `max_sentences` (number, default 3).
- **Worker system prompt:** “You are a summarizer. Summarize the following in at most N sentences. Output only the summary, no preamble.”
- **Use case:** Orchestrator can delegate long-content summarization instead of doing it in-context, saving tokens and keeping the main turn short.

### extract (implemented)

- **task_type:** `"extract"`.
- **Payload:** `text` (string), optional `instruction` (string, e.g. "names and dates"; default: key facts/entities as a short list).
- **Worker system prompt:** "You are an extractor. From the following text, [instruction]. Output only the extracted items, one per line or as a short list. No preamble."
- **Use case:** Orchestrator can delegate entity or fact extraction to the worker.

## Heartbeat alignment

Today: **warm-the-ovens** runs on first message (start server if port down, wait up to 90s). That is “wake the model server on demand.”

For orchestrator–worker:

- **Scout / cron:** A lightweight job (e.g. cron or launchd) can periodically check “is there work for the orchestrator?” (e.g. new Discord messages, queue depth). If yes, ensure model server is up (call the same warm-the-ovens script or a no-op if already warm), then the bot processes messages as today. No change to the bot binary required; the “scout” is the existing Discord gateway plus warm-the-ovens on first message.
- **Heavy-model wake:** The expensive operation is starting vLLM-MLX. Keeping the Discord process running and starting the model on first message (CHUMP_WARM_SERVERS=1) already defers that cost until needed. A future “scout” could be a separate tiny process that only pings the gateway or checks a queue and does not load the model.

So Phase 3 heartbeat is “document that warm-the-ovens is the on-demand wake; optional future scout for queue-driven wake.” No new daemon required for the minimal design.

## Worker-specific model (implemented)

Set **`CHUMP_WORKER_API_BASE`** and/or **`CHUMP_WORKER_MODEL`** to point the delegate worker at a different endpoint or model (e.g. 7B on port 8001). If unset, the worker uses `OPENAI_API_BASE` and `OPENAI_MODEL` (same as the main agent).

## Batch delegate (implemented)

- Pass **`tasks`** (array of `{ task_type, text, max_sentences?, instruction? }`) to run multiple delegate calls in parallel. **CHUMP_DELEGATE_MAX_PARALLEL** (default 4, range 1–32) caps concurrent worker calls per batch. Response is numbered lines: `1. ...`, `2. ...`, etc. Prompt the model to use the `tasks` array when it needs several summarize/extract results in one turn.

## Optional future

- **More task types:** e.g. `translate`, each with a fixed worker prompt and payload schema.
- **Concurrent turns:** Documented and implemented via **CHUMP_MAX_CONCURRENT_TURNS** (Discord); see [TROUBLESHOOTING](TROUBLESHOOTING.md#security-and-limits). Full plan: [ROADMAP_PARALLEL_AGENTS.md](ROADMAP_PARALLEL_AGENTS.md).
