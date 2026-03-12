# Heartbeat reliability improvements

Ways to improve how often self-improve rounds succeed (more `Round X: ok`, fewer `exit non-zero`).

## Implemented

- **run_cli more forgiving:** Accepts `command`, `cmd`, `content`, `shell`, `script`, top-level string, or first string in object. Reduces "missing command" when the model sends a different JSON shape.
- **Longer CLI timeout in heartbeat:** Script exports `CHUMP_CLI_TIMEOUT_SECS=120` (override with env). Reduces timeouts on `cargo test` and multi-step work.
- **Soul guidance:** System prompt now says: use `"command"` for run_cli; use read_file to read files, not run_cli cat or git.

## Optional (env / config)

- **CHUMP_CLI_TIMEOUT_SECS:** Set to 180 or 300 in `.env` if rounds still timeout on heavy tests.
- **CHUMP_EXECUTIVE_MODE=1:** For heartbeat only, gives no allowlist and higher timeout/cap; use only if you trust the agent. Audit in chump.log.
- **HEARTBEAT_RETRY=1:** Script retries once per round on non-zero exit; can recover from transient errors.

## Future / code

- **Battle QA in heartbeat:** Use smaller max_queries (e.g. 10) for battle_qa rounds so they finish sooner; or run battle_qa less often in the cycle.
- **Tool error → retry:** If the agent runtime surfaced tool errors back to the model with a "retry with correct args" hint, the model could fix the call instead of the round failing.
- **Round timeout:** Optional max wall-clock time per round (e.g. 15 min) so one stuck round doesn’t block the next; would require the script to run the agent with a timeout wrapper.
- **Log exit reason:** Log the actual error (e.g. "missing command", "timed out", "tool X failed") next to "exit non-zero" so we can prioritize fixes.

## See also

- [OPERATIONS.md](OPERATIONS.md) — Reliable one-shot run, single process, Ollama.
- [AUTONOMOUS_PR_WORKFLOW.md](AUTONOMOUS_PR_WORKFLOW.md) — Round types and safety.
