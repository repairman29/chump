# Architecture

## What Chump is

Single local agent (Rust + AxonerAI): one orchestrator, optional delegate workers. Tools: run*cli (allowlist/blocklist, timeout, cap), memory (SQLite FTS5 + optional semantic RRF), calculator, wasm_calc, delegate (summarize/extract), web_search (Tavily). Repo tools when CHUMP_REPO set: read_file, list_dir, write_file, edit_file; optional git*_, gh\__, diff_review. Brain when state DB available: task, schedule, ego, episode, memory_brain, notify. Discord + CLI; session per channel; proactive memory recall before each turn.

## Soul and purpose

System prompt defines personality (dev buddy, curious, opinions). Override with `CHUMP_SYSTEM_PROMPT`. When state DB is present, prompt gains continuity/agency: use brain and ego, write things down, act without being asked. Task/schedule/diff_review/notify are called out in soul so Chump uses them.

## Memory

SQLite `sessions/chump_memory.db` with FTS5; fallback `sessions/chump_memory.json`. Optional embed server (port 18765) or `--features inprocess-embed` for semantic recall; RRF merges keyword + semantic when both available. State/episodes/tasks/schedule in same DB (chump_state, chump_episodes, chump_tasks, chump_scheduled).

## Resilience and safety

Model: retries with backoff, optional `CHUMP_FALLBACK_API_BASE`, circuit breaker after 3 failures. Kill switch: `logs/pause` or `CHUMP_PAUSED=1`. Input caps: `CHUMP_MAX_MESSAGE_LEN`, `CHUMP_MAX_TOOL_ARGS_LEN`. Optional rate limit and concurrent-turn cap. Secrets redacted in logs. Executive mode (`CHUMP_EXECUTIVE_MODE=1`) disables allowlist for run_cli; audit in chump.log.

## Delegate

When `CHUMP_DELEGATE=1`, delegate tool runs summarize or extract via a worker (same or smaller model). `CHUMP_WORKER_API_BASE` / `CHUMP_WORKER_MODEL` for separate worker. diff_review uses same worker with code-review prompt.
