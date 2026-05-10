# Fleet Environment Variables: H–N

Reference for fleet operators and contributors. Variables starting with
`CHUMP_H` through `CHUMP_N` (second letter of the var name).

Tier 2 (tunable): set in `.env` or shell for advanced control.
Tier 3 (runtime): set by the fleet harness; do not override unless debugging.

Full allowlist for CI: `scripts/ci/env-vars-internal.txt`.
Operator-facing Tier 1 vars: `.env.example`.

---

## Tier 2 — Tunable (H–N)

| Variable | Default | Description |
|----------|---------|-------------|
| `CHUMP_HEARTBEAT_ELAPSED` | _(runtime)_ | Seconds elapsed in the current heartbeat round; injected by worker.sh. |
| `CHUMP_HEARTBEAT_ROUND` | _(runtime)_ | Current heartbeat round number; injected by worker.sh. |
| `CHUMP_HEARTBEAT_TYPE` | _(runtime)_ | Heartbeat phase label (`gap`, `reflect`, `idle`); injected by worker.sh. |
| `CHUMP_HITL_PROACTIVE_DISABLED` | `0` | Suppress proactive HITL check-ins during long autonomous runs. |
| `CHUMP_INCLUDE_COS_WEEKLY` | `0` | Inject the latest COS weekly snapshot into agent system prompt. |
| `CHUMP_INTERRUPT_NOTIFY_POLICY` | `always` | When to send push notifications on operator interrupt: `always`, `on-change`, or `never`. |
| `CHUMP_LEASE_GATE` | _(runtime)_ | Path to the active session lease file; injected by gap-claim.sh. |
| `CHUMP_LESSONS_AT_SPAWN_ACK` | `0` | When `1`, log a confirmation line when lessons are injected at spawn. |
| `CHUMP_LESSONS_AT_SPAWN_N` | `5` | Max number of lessons injected into the system prompt at worker spawn. |
| `CHUMP_LESSONS_DENY_FAMILIES` | _(none)_ | Comma-separated lesson family names to exclude from retrieval. |
| `CHUMP_LESSONS_EMBEDDING_TIMEOUT_MS` | `2000` | Max ms to wait for embedding API when retrieving lessons. |
| `CHUMP_LESSONS_OPT_IN_MODELS` | _(none)_ | Comma-separated model IDs that receive lessons injection (empty = all models). |
| `CHUMP_LESSONS_TASK_AWARE` | `1` | Weight lessons retrieval toward the current task description. |
| `CHUMP_LESSON_QUALITY_THRESHOLD` | `0.6` | Minimum cosine similarity score for a lesson to be injected. |
| `CHUMP_LIGHT_CHAT_HISTORY_MESSAGES` | `10` | Max chat history messages retained in light-mode sessions. |
| `CHUMP_LIGHT_COMPLETION_MAX_TOKENS` | `2048` | Max output tokens for light-mode completions. |
| `CHUMP_LIGHT_CONTEXT` | `0` | Enable compressed context assembly for light sessions. |
| `CHUMP_LIGHT_INCLUDE_BRAIN_AUTOLOAD` | `1` | Include brain.md in light-mode system context. |
| `CHUMP_LIGHT_INCLUDE_STATE_DB` | `0` | Include gap-store state summary in light-mode context. |
| `CHUMP_LLM_RETRY_DELAYS_MS` | `1000,3000,9000` | Comma-separated exponential back-off delays (ms) for LLM API retries. |
| `CHUMP_LOGPROBS_ENABLED` | `0` | Request log-probabilities from the LLM API (Anthropic extended output feature). |
| `CHUMP_MAX_MESSAGE_LEN` | `200000` | Hard cap on single message length (chars) before truncation. |
| `CHUMP_MAX_TOOL_ARGS_LEN` | `50000` | Hard cap on tool argument payload (chars) before rejection. |
| `CHUMP_MEMORY_DECAY_RATE` | `0.95` | Exponential decay rate applied to memory cluster relevance scores per day. |
| `CHUMP_MEMORY_LLM_SUMMARIZE` | `0` | Use LLM (haiku) to compress memory clusters instead of extractive summary. |
| `CHUMP_MEMORY_MMR_LAMBDA` | `0.5` | MMR diversity-relevance trade-off λ for memory retrieval (0=diverse, 1=relevant). |
| `CHUMP_MEMORY_RERANK` | `0` | Apply cross-encoder reranking to memory retrieval results. |
| `CHUMP_MEMORY_SUMMARIZE_MAX_CLUSTERS` | `10` | Max memory clusters to summarize in a single background sweep. |
| `CHUMP_MEMORY_SUMMARIZE_MIN_AGE_DAYS` | `7` | Minimum age (days) before a memory cluster is eligible for summarization. |
| `CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER` | `3` | Minimum cluster size before summarization is attempted. |
| `CHUMP_MISTRALRS_LOGGING` | `0` | Enable verbose mistral.rs library logging (very noisy). |
| `CHUMP_MODEL_PREFLIGHT_TIMEOUT_SECS` | `30` | Seconds to wait for model preflight health-check before failing. |
| `CHUMP_MULTI_REPO_ENABLED` | `0` | Enable multi-repo gap tracking (reads `CHUMP_GITHUB_REPOS` list). |
| `CHUMP_NEUROMOD_NA_ALPHA` | `0.1` | Noradrenaline learning rate for neuromodulation state updates. |
| `CHUMP_NEUROMOD_SERO_ALPHA` | `0.1` | Serotonin learning rate for neuromodulation state updates. |
| `CHUMP_NOTIFY_FULLY_ARMORED` | `0` | Suppress all push notifications even in autonomy mode. |
| `CHUMP_NOTIFY_INTERRUPT_EXTRA` | _(none)_ | Extra message appended to interrupt push notification payloads. |
| `CHUMP_NUM_CTX_WARN` | `110000` | Warn if context exceeds this token count (default ~110K for 128K models). |

---

## Tier 3 — Runtime state (H–N, do not override)

**Heartbeat / round state (injected by worker.sh per-round):**
`CHUMP_HEARTBEAT_ELAPSED`, `CHUMP_HEARTBEAT_ROUND`, `CHUMP_HEARTBEAT_TYPE`,
`CHUMP_CURRENT_ROUND_TYPE`, `CHUMP_CURRENT_SLOT_CONTEXT_K`

**Operator presence (updated by fleet monitor):**
`CHUMP_OPERATOR_LAST_SEEN_UNIX`

**Test / CI / eval (set by test harnesses only):**
`CHUMP_LESSONS_AT_SPAWN_ACK` _(also Tier 2 above — set 1 in CI for audit logs)_
