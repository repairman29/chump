# Architecture

## What Chump is

Single local agent (Rust + AxonerAI): one orchestrator, optional delegate workers. Tools: run*cli (allowlist/blocklist, timeout, cap, middle-trim for long output), memory (SQLite FTS5 + optional semantic RRF), calculator, wasm_calc, wasm_text, delegate (summarize, extract, classify, validate), web_search (Tavily). Repo tools when CHUMP_REPO set: read_file (auto-summary for large files), list_dir, write_file, patch_file (unified diff); optional git*_, gh\__, diff_review. Brain when state DB available: task, schedule, ego, episode, memory_brain, notify. Discord + CLI; session per channel; proactive memory recall before each turn. Context: system prompt is ordered for small-model primacy/recency (hard rules first, tool examples, routing, round-filtered assemble_context, soul/brain last). When message history exceeds token threshold, oldest messages are summarized via delegate and replaced with one summary block (CHUMP_CONTEXT_SUMMARY_THRESHOLD, CHUMP_CONTEXT_MAX_TOKENS).

## Soul and purpose

System prompt defines personality (dev buddy, curious, opinions). Override with `CHUMP_SYSTEM_PROMPT`. When state DB is present, prompt gains continuity/agency: use brain and ego, write things down, act without being asked. Task/schedule/diff_review/notify are called out in soul so Chump uses them.

## Memory

SQLite `sessions/chump_memory.db` with FTS5; fallback `sessions/chump_memory.json`. Optional embed server (port 18765) or `--features inprocess-embed` for semantic recall; RRF merges keyword + semantic when both available. State/episodes/tasks/schedule in same DB (chump_state, chump_episodes, chump_tasks, chump_scheduled).

## Resilience and safety

Model: retries with backoff (configurable via `CHUMP_LLM_RETRY_DELAYS_MS`), optional `CHUMP_FALLBACK_API_BASE`, circuit breaker after 3 failures. Kill switch: `logs/pause` or `CHUMP_PAUSED=1`. Input caps: `CHUMP_MAX_MESSAGE_LEN`, `CHUMP_MAX_TOOL_ARGS_LEN`. Optional rate limit and concurrent-turn cap. Secrets redacted in logs. Executive mode (`CHUMP_EXECUTIVE_MODE=1`) disables allowlist for run_cli; audit in chump.log.

### Tool policy (allow / deny / ask)

Tools can be in an "ask" set (env **CHUMP_TOOLS_ASK**, comma-separated names). When the agent is about to run a tool in that set, it does not execute immediately: it emits a **ToolApprovalRequest** event and waits for a resolution (allow, deny, or timeout). Heuristic risk (e.g. for run_cli: `rm -rf /`, sudo, chmod 777, DROP TABLE, credential-like args) is computed without an LLM and included in the request. One approval UX is required: **Discord** (message with Allow/Deny buttons), **Web** (POST /api/approve or in-chat approval card), or **ChumpMenu** (Chat tab streams SSE and posts Allow/Deny to `/api/approve`). Resolutions are passed back via **approval_resolver** (in-process map keyed by request_id). All approval outcomes are audit-logged to chump.log (event `tool_approval_audit`).

## Perception layer

`src/perception.rs`: structured pre-reasoning pass before the main model call. Classifies `TaskType` (code_edit, question, research, debug, creative, admin), extracts named entities, detects constraints (deadlines, file paths, version pins), flags risk indicators (destructive ops, auth, external calls), and scores ambiguity (0.0–1.0). Wired into `agent_loop.rs` — perception result is injected into context so the model sees structured input, not just raw text. Ambiguity score feeds escalation decisions; risk indicators feed tool approval heuristics.

## Action verification

`ToolVerification` struct in `tool_middleware.rs`. After write-tool execution, a post-verification step checks the tool's effect (e.g. file exists, expected content, command exit code). Emits `ToolVerificationResult` SSE event to web/PWA clients. Verification pass/fail is logged alongside the tool outcome.

## Eval framework

`src/eval_harness.rs`: property-based eval with `EvalCase`, `EvalCategory`, `ExpectedProperty` types. DB tables `chump_eval_cases` and `chump_eval_runs` track cases and results. Property checking (contains, not_contains, json_path, regex, custom) with regression detection. Wired into `battle_qa` for automated quality gates.

## Enriched memory

`chump_memory` table extended with `confidence` (0.0–1.0), `verified` (bool), `sensitivity` (public/internal/secret), `expires_at` (optional TTL), `memory_type` (fact/preference/episode/skill/context). Memory tool accepts `confidence`, `memory_type`, `expires_after_hours` params. Retrieval pipeline: RRF merge weighted by freshness decay and confidence; query expansion via memory graph; context compression to 4K char budget.

## Delegate

When `CHUMP_DELEGATE=1`, delegate tool runs summarize, extract, classify (message routing), and validate (output quality guard) via a worker (same or smaller model). `CHUMP_WORKER_API_BASE` / `CHUMP_WORKER_MODEL` for separate worker. diff_review uses same worker with code-review prompt. read_file and run_cli use tool-side intelligence (auto-summary for files over CHUMP_READ_FILE_MAX_CHARS; middle-trim for long CLI output).
