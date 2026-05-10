# Fleet Environment Variables: O–Z

Reference for fleet operators and contributors. Variables starting with
`CHUMP_O` through `CHUMP_Z` (second letter) plus system vars used at runtime.

Tier 2 (tunable): set in `.env` or shell for advanced control.
Tier 3 (runtime): set by the fleet harness; do not override unless debugging.

Full allowlist for CI: `scripts/ci/env-vars-internal.txt`.
Operator-facing Tier 1 vars: `.env.example`.

---

## Tier 2 — Tunable (O–Z)

| Variable | Default | Description |
|----------|---------|-------------|
| `CHUMP_OLLAMA_KEEP_ALIVE` | `5m` | Duration Ollama keeps a model loaded after last request (e.g. `5m`, `1h`). |
| `CHUMP_OLLAMA_NUM_CTX` | `2048` | Context window size passed to Ollama via `num_ctx` option. |
| `CHUMP_OPENAI_CONNECT_TIMEOUT_SECS` | `30` | Connection timeout for OpenAI-compatible API calls. |
| `CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS` | `4` | Hours without operator activity before entering reduced-notification mode. |
| `CHUMP_PAUSED` | `0` | When `1`, fleet workers complete the current task then stop; set to resume. |
| `CHUMP_PERCEPTION_ENABLED` | `1` | Enable perception pre-processing (intent classification + complexity scoring). |
| `CHUMP_PHASE_TIMING` | `0` | Log per-phase timing to stderr for pipeline profiling. |
| `CHUMP_PLAIN_COT` | `0` | Use plain chain-of-thought (no XML wrapper) for thinking traces. |
| `CHUMP_PLAN_MODE` | `0` | Force agent into plan-only mode (produces plan, does not execute). |
| `CHUMP_POLICY_ALLOW_UNVERIFIED` | `0` | Allow tool calls that bypassed policy verification (dangerous; audit log only). |
| `CHUMP_POWERMETRICS_BIN` | `powermetrics` | Path to `powermetrics` binary for energy measurement on Apple Silicon. |
| `CHUMP_PREFER_LARGE_CONTEXT` | `0` | Prefer model slots with larger context windows during cascade selection. |
| `CHUMP_PREFERRED_MODEL_CLASS` | _(none)_ | Force a specific model class (`haiku`, `sonnet`, `opus`) for all sessions. |
| `CHUMP_PREWARM` | `0` | Send a warmup request to the inference backend before the first real call. |
| `CHUMP_PICKER_BIAS_THRESHOLD` | `0.8` | Fraction of recent ships in the same domain that triggers domain-diversity bias in `--pick-gap` (FLEET-045). |
| `CHUMP_PICKER_BIAS_WINDOW` | `10` | Number of most-recently-shipped gaps inspected to compute domain concentration for the picker bias. |
| `CHUMP_PROBE_THRESHOLD` | `0.1` | Bandit probe-phase token budget as a fraction of total budget. |
| `CHUMP_PROJECT_MODE` | `0` | Enable project-scope context (loads project files into every session). |
| `CHUMP_READ_FILE_HARD_CAP_CHARS` | `500000` | Hard character cap on file reads; truncates beyond this limit. |
| `CHUMP_REFLECTION_AB_WITH_LLM` | `0` | Run A/B test of reflection output with and without LLM enhancement. |
| `CHUMP_REFLECTION_INJECTION` | `1` | Inject reflection summary into agent system prompt each session. |
| `CHUMP_REFLECTION_LLM` | `haiku` | Model class for LLM-enhanced reflection synthesis. |
| `CHUMP_REFLECTION_STRICT_SCOPE` | `0` | Limit reflection injection to reflections about the current gap only. |
| `CHUMP_REMOTE` | _(git remote)_ | Git remote name used by fleet push/PR operations (default: `origin`). |
| `CHUMP_REPO_PROFILES` | _(none)_ | Comma-separated list of additional repo profile config paths. |
| `CHUMP_RESERVE_NO_AUTOSTAGE` | `0` | Skip auto-staging new gap YAML on `chump gap reserve`. |
| `CHUMP_RESERVE_SCAN_OPEN_PRS` | `1` | Scan open PRs for duplicate work before reserving a new gap. |
| `CHUMP_RESERVE_VERIFY` | `1` | Run gap preflight verification after `chump gap reserve`. |
| `CHUMP_RESERVE_VERIFY_SLEEP_MS` | `500` | Delay (ms) between reserve and verification check. |
| `CHUMP_RETRIEVAL_RERANK_WEIGHTS` | `0.6,0.4` | Weights `(similarity, recency)` for memory retrieval reranking. |
| `CHUMP_RPC_JSONL_LOG` | _(none)_ | Path to append JSONL log of all RPC requests/responses (debug). |
| `CHUMP_SANDBOX_ALLOWLIST` | _(none)_ | Comma-separated tool names allowed in sandbox mode (others blocked). |
| `CHUMP_SANDBOX_SPECULATION` | `0` | Run speculative tool calls in sandbox before real execution. |
| `CHUMP_SCREEN_VISION_ENABLED` | `0` | Enable screen-vision tool (ADB mobile or macOS screenshot). |
| `CHUMP_SESSION_ENERGY_TOKENS` | _(none)_ | Token budget for session energy tracking (emit warning at 80%). |
| `CHUMP_SESSION_ENERGY_TOOLS` | _(none)_ | Tool-call budget for session energy tracking. |
| `CHUMP_SHIP_NO_AUTOSTAGE` | `0` | Skip auto-staging gap YAML update on `chump gap ship`. |
| `CHUMP_SIMULATE_SEED` | _(none)_ | Random seed for deterministic simulation runs (test/eval). |
| `CHUMP_STACK_PROBE_TIMEOUT_SECS` | `10` | Seconds before a stack-probe health check times out. |
| `CHUMP_STREAM_HTTP` | `0` | Enable HTTP streaming for LLM responses (vs. single-shot JSON). |
| `CHUMP_SYSTEM_PROMPT` | _(none)_ | Override the entire agent system prompt with a literal string (debug). |
| `CHUMP_TASK_DECOMPOSE_THRESHOLD` | `3` | Min sub-task count before decomposition is attempted. |
| `CHUMP_TASK_LEASE_TTL_SECS` | `3600` | Seconds before a task lease expires without a heartbeat renewal. |
| `CHUMP_TASK_STUCK_SECS` | `14400` | Seconds without progress before a task is classified as stuck. |
| `CHUMP_THINKING_LOG_MAX_CHARS` | `10000` | Max chars of thinking trace to log to disk per turn. |
| `CHUMP_THINKING_XML` | `0` | Wrap thinking traces in `<thinking>` XML tags for structured parsing. |
| `CHUMP_TOKEN_ANOMALY_FACTOR` | `3.0` | Multiplier above baseline token-per-turn to flag an anomaly. |
| `CHUMP_TOKEN_ANOMALY_WEBHOOK` | _(none)_ | Webhook URL to POST token-anomaly alerts to. |
| `CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS` | `60` | Circuit-breaker cooldown for tool-level failures. |
| `CHUMP_TOOL_CIRCUIT_FAILURES` | `3` | Consecutive tool failures before that tool's circuit opens. |
| `CHUMP_TOOL_EXAMPLES` | `0` | Inject tool usage examples into the system prompt. |
| `CHUMP_VERIFY_API_BASE` | _(none)_ | Base URL for the verification LLM API (used by `chump verify`). |
| `CHUMP_VERIFY_API_KEY` | _(none)_ | API key for the verification LLM endpoint. |
| `CHUMP_VERIFY_MODEL` | `claude-sonnet-4-5` | Model ID for post-task verification calls. |
| `CHUMP_VERIFY_POSTCONDITIONS` | `0` | Run post-condition verification after task completion. |
| `CHUMP_VISION_API_BASE` | _(none)_ | Base URL for the vision/multimodal LLM API. |
| `CHUMP_VISION_MAX_IMAGE_BYTES` | `5242880` | Max image size (bytes) accepted by vision tools before rejection. |
| `CHUMP_VISION_MODEL` | _(OPENAI_MODEL)_ | Model ID for vision-enabled calls (falls back to `OPENAI_MODEL`). |
| `CHUMP_VISION_TIMEOUT_SECS` | `60` | Seconds before a vision API call times out. |
| `CHUMP_WARM_SERVERS` | _(none)_ | Comma-separated inference base URLs to pre-warm before fleet start. |
| `CHUMP_WASM_FUEL_BUDGET` | `100000` | WASM execution fuel budget per call (instruction limit). |
| `CHUMP_WASM_FUEL_ENABLED` | `0` | Enable WASM fuel metering (cap runaway WASM execution). |
| `CHUMP_WEB_HTTP_TRACE` | `0` | Log all HTTP request/response pairs for the web server. |
| `CHUMP_WEB_INJECT_COS` | `0` | Inject latest COS weekly snapshot into web/PWA agent system context. |
| `CHUMP_WEB_SLIM_TOOLS` | `0` | Reduce tool set exposed to web/PWA sessions (faster, cheaper). |
| `CHUMP_WEB_STATIC_DIR` | `web` | Directory served as static assets by the chump web server. |
| `CHUMP_WEB_URL` | `http://127.0.0.1:3000` | Public base URL for the chump web server (used in push notifications). |

---

## Tier 3 — Runtime state (O–Z, do not override)

**Fleet operation paths (injected by scripts/dispatch):**
`CHUMP_OPERATOR_ACTIVITY_PATH`, `CHUMP_OPERATOR_LAST_SEEN_UNIX`,
`CHUMP_PROFILE_KEY_PATH`, `CHUMP_REMOTE`, `CHUMP_REPO`, `CHUMP_REPO_ROOT`,
`CHUMP_WORKTREE_BASE`, `CHUMP_WORKTREE_ROOT`

**Runtime session / fleet state:**
`CHUMP_PAUSED` _(also operator-settable)_, `CHUMP_SESSION_ID`, `CHUMP_VERSION`

**Test / CI / eval (set by test harnesses only):**
`CHUMP_ORCHESTRATE_STUB`, `CHUMP_SIMULATE_SEED` _(also Tier 2 above)_,
`CHUMP_TEST_AWARE`
