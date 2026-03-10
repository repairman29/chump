# Troubleshooting

## Degradation and fallbacks

Chump degrades gracefully when dependencies are down. No silent panics: each path either works or returns a clear fallback or error.

| Dependency                    | When it fails                                          | What Chump does                                                                                                                                                                                                                                                              |
| ----------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Embed server**              | Down, unreachable, or health check fails               | **Keyword-only recall.** Memory tool uses FTS5 (and in-memory keyword match when using JSON fallback) only; no semantic/RRF merge. Recall still returns relevant entries when the query matches keywords.                                                                    |
| **SQLite (chump_memory.db)**  | Missing, corrupt, or unwritable                        | **JSON fallback.** Memory reads and writes `sessions/chump_memory.json` instead. Existing JSON is used as-is; new entries append. Migrate later by running once with DB available so `memory_db` can migrate JSON into the DB.                                               |
| **Model server (8000 / API)** | 5xx, connection refused, timeout, or connection closed | **User-visible error.** The agent does not panic. The user sees a clear message such as "model temporarily unavailable" or "connection closed before message completed." Fix by starting or restarting the model server (e.g. warm-the-ovens, or run `./serve-vllm-mlx.sh`). |

See [CHUMP_SMART_MEMORY](CHUMP_SMART_MEMORY.md) for memory architecture and [CHUMP_SERVICE](CHUMP_SERVICE.md) for warm-the-ovens and heartbeat.

## Making Chump aware and capable (Discord)

- **Repo awareness:** Set **CHUMP_REPO** (or **CHUMP_HOME**) to the path of the Chump/rust-agent repo. The system prompt will tell Chump “Your codebase is at &lt;path&gt;” and **run_cli** will use that directory as the working directory for commands (so `cargo test`, `git status` run in the repo).
- **Read/write repo tools:** **read_file** (path, optional start_line/end_line) and **list_dir** (path, default “.”) let Chump read the codebase without running shell commands. **write_file** (path, content, mode: overwrite/append) lets Chump edit files under the repo when you ask; it only works when CHUMP_REPO or CHUMP_HOME is set, and every write is logged in `logs/chump.log`. See [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md) Phase 1–2.
- **Full exec for testing:** Set **CHUMP_EXECUTIVE_MODE=1**. run_cli then ignores allowlist/blocklist and uses executive timeout (default 300s) and output cap (default 50k chars). All such runs are audited in `logs/chump.log` with `executive=1`. Use only when you want Chump to have full host authority (e.g. “run cargo build”, “git push”).
- **GitHub read (Phase 3):** Set **GITHUB_TOKEN** (or **CHUMP_GITHUB_TOKEN**) and **CHUMP_GITHUB_REPOS** (e.g. `owner/chump`). Chump gets **github_repo_read** (file content) and **github_repo_list** (directory listing) for those repos only.
- **Git commit/push (Phase 4):** With CHUMP_REPO and CHUMP_GITHUB_REPOS set, **git_commit** (repo, message) and **git_push** (repo, branch) run in CHUMP_REPO; repo must be in the allowlist. Every commit and push is logged in `logs/chump.log`. Configure git credentials (e.g. credential helper or token in remote) so push works. **CHUMP_AUTO_PUSH=1** lets Chump push after commit without a second confirmation (default 0).
- **Clone/pull (Phase 3):** **github_clone_or_pull** clones (or pulls) allowlisted repos into **CHUMP_HOME/repos/owner_name** so you can use read_file/list_dir on the local copy. Logged in `logs/chump.log`.
- **Summary:** `CHUMP_REPO` + `read_file`/`list_dir`/`write_file` + optional GitHub/git env + optional `CHUMP_EXECUTIVE_MODE=1` gives Discord Chump full self-improve and push capability.

## Resilience: retries, fallback, circuit breaker

The **model** provider (local OpenAI) uses:

- **Retries:** On transient errors (connection refused, timeout, 5xx), the agent retries up to 2 times with backoff (1s, 2s). Then it returns an error so the user sees “model temporarily unavailable” (or similar) instead of a silent failure.
- **Fallback (optional):** Set `CHUMP_FALLBACK_API_BASE` (e.g. `http://localhost:8001/v1`) so that if the primary URL (e.g. 8000) fails after retries, one attempt is made to the fallback. Use when you run a second model (e.g. 7B on 8001) and want automatic failover.
- **Circuit breaker:** After 3 consecutive failures to the same base URL, that URL is marked “open” for 30 seconds. During that time, no request is sent (avoids hammering a dead server). After 30s, one request is allowed; if it succeeds, the counter resets.

Embed server and Tavily do not yet have retry/backoff or circuit breaker; only the model provider does.

## Security and limits

- **Secrets redaction:** Chump never logs token values. Before writing to `logs/chump.log`, the process redacts the values of `DISCORD_TOKEN`, `TAVILY_API_KEY`, `OPENAI_API_KEY`, and `GITHUB_TOKEN` (if they appear in the log line) with `[REDACTED]`. Malformed tool JSON is logged with `args: [REDACTED]` so tool arguments (which may contain user content) never appear in stderr. Do not rely on logs for debugging token issues; ensure tokens are set in env or `.env` only.

- **Input caps:** User messages and tool-call argument size are capped to avoid abuse or OOM:
  - **CHUMP_MAX_MESSAGE_LEN** (default 16384): Max characters per user message. If exceeded, the user sees “Message too long (max N characters).”
  - **CHUMP_MAX_TOOL_ARGS_LEN** (default 32768): Max bytes for a single tool-call input (as JSON). If exceeded, the tool returns a clear error.

- **Rate limit (optional):** **CHUMP_RATE_LIMIT_TURNS_PER_MIN** (default 0 = off): Per Discord channel, max number of turns per minute. When exceeded, the bot replies “Rate limited; try again in a minute.” Set to e.g. 5 to throttle a busy channel.

- **Concurrent turns cap (optional):** **CHUMP_MAX_CONCURRENT_TURNS** (default 0 = no cap): Max number of Discord turns running at once (any channel). When at capacity, new messages get “I’m at capacity; try again in a moment.” Valid range 1–32. Use to avoid overloading the model or OOM when many users message at once.

- **Executive mode (full exec):** For testing or self-improve, Chump can run **any** shell command (no allowlist/blocklist) with higher timeout and output cap. Set **CHUMP_EXECUTIVE_MODE=1** (or `true`). Optional: **CHUMP_EXECUTIVE_TIMEOUT_SECS** (default 300), **CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS** (default 50000). Every run_cli in executive mode is logged with `executive=1` in `logs/chump.log`. Only set this when you intend Chump to have full host authority (e.g. dedicated machine or VM). See [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md) Phase 5.

---

## Port 8000 / vLLM-MLX server crash

If the model server exits immediately after starting, or Chump reports **"connection closed before message completed"** when calling `http://localhost:8000/v1/chat/completions`, the vLLM-MLX process likely crashed during Metal/GPU initialization.

**Typical crash:**

```
*** Terminating app due to uncaught exception 'NSRangeException', reason: '*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array'
```

Stack trace will show `libmlx.dylib` and `mlx::core::metal::Device` (or `MetalAllocator`). This usually means MLX could not get a valid Metal device list (e.g. empty array indexed at 0).

**What to do:** See the README section **"If the server on port 8000 crashes or Chump says connection closed"**: use Ollama as a fallback, or try `MLX_DEVICE=cpu`, a smaller model (`VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit`), and running the server from a normal Terminal. If the problem persists, prefer Ollama for local inference.
