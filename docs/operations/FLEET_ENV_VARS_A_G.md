# Fleet Environment Variables: A–G

Reference for fleet operators and contributors. Source of truth for runtime vs.
Tier 2 (tunable): set in `.env` or shell for advanced control.
Tier 3 (runtime): set by the fleet harness; do not override unless debugging.

Full allowlist for CI: `scripts/ci/env-vars-internal.txt`.
Operator-facing Tier 1 vars: `.env.example`.

---

## Tier 2 — Tunable (A–G)

| Variable | Default | Description |
|----------|---------|-------------|
| `CHUMP_A2A_CHANNEL_ID` | _(none)_ | Discord channel ID for agent-to-agent messaging (INFRA-A2A). |
| `CHUMP_A2A_PEER_USER_ID` | _(none)_ | Discord user ID of the peer agent for A2A direct messages. |
| `CHUMP_ACTIVATION_DISABLED` | `0` | When `1`, skip the activation-gate check on startup. |
| `CHUMP_ADAPTIVE_OUTCOME_WINDOW` | `20` | Window size (in sessions) for bandit outcome smoothing. |
| `CHUMP_ADB_DEVICE` | _(none)_ | ADB device serial for screen-vision mobile testing. |
| `CHUMP_ADB_ENABLED` | `0` | Enable ADB-based screen-vision capture tool. |
| `CHUMP_ADVERSARY_ENABLED` | `0` | Enable adversarial red-team agent in debug mode. |
| `CHUMP_ADVERSARY_MODE` | `passive` | Adversary mode: `passive` (observe) or `active` (inject). |
| `CHUMP_ADVERSARY_MODEL` | Sonnet | Model class used by the adversary sub-agent. |
| `CHUMP_ALLOW_DISCORD_RUSTLS` | `0` | Allow Discord TLS via rustls instead of native TLS (use when native TLS unavailable). |
| `CHUMP_ALLOW_GAP_REWRITE` | `0` | Allow overwriting an existing gap YAML on `chump gap reserve`. |
| `CHUMP_ALLOW_LOCAL_SSRF` | `0` | Allow tool requests to localhost URLs (internal testing only). |
| `CHUMP_ALLOW_RECYCLE` | `0` | Allow re-opening a closed gap and reassigning to a new session. |
| `CHUMP_AMBIENT_IN_PROMPT` | `0` | Inject last N ambient events into the agent system prompt. |
| `CHUMP_AMBIENT_LOG` | _(auto)_ | Path to `ambient.jsonl`; defaults to `.chump-locks/ambient.jsonl`. |
| `CHUMP_AMBIENT_NATS` | `0` | Mirror ambient events to NATS subject `chump.ambient` (FLEET-006). |
| `CHUMP_BALANCED_THRESHOLD` | `0.5` | Bandit balanced-phase lower reward bound before switching to exploit. |
| `CHUMP_BANDIT_STRATEGY` | `adaptive` | Bandit strategy override: `explore`, `exploit`, `balanced`, `probe`, or `adaptive`. |
| `CHUMP_BINARY_STALENESS_CHECK` | `1` | Verify chump binary freshness before worker spawn; set `0` to skip. |
| `CHUMP_BRAIN_AUTOLOAD` | `1` | Auto-load `.chump/brain.md` into agent context at session start. |
| `CHUMP_BRAIN_PATH` | `.chump/brain.md` | Path to the brain file relative to repo root. |
| `CHUMP_BROWSER_AUTOAPPROVE` | `0` | Auto-approve browser tool calls without interactive prompt. |
| `CHUMP_BYPASS_BLACKBOARD` | `0` | Skip blackboard read/write (useful for isolated tests). |
| `CHUMP_BYPASS_CLOSED_PR_GUARD` | `0` | Skip the closed-PR guard in pre-commit/pre-push hooks. |
| `CHUMP_BYPASS_NEUROMOD` | `0` | Disable neuromodulation updates for this session. |
| `CHUMP_BYPASS_PERCEPTION` | `0` | Skip perception pre-processing step in the agent loop. |
| `CHUMP_BYPASS_SPAWN_LESSONS` | `0` | Skip lessons injection when spawning a worker session. |
| `CHUMP_CASCADE_MAX_PREFERRED_WAITS` | `3` | Max RPM-wait retries before the cascade falls through to the next slot. |
| `CHUMP_CASCADE_RETRY_AFTER_EXHAUSTED_S` | `60` | Seconds to wait after all cascade slots exhausted before retrying. |
| `CHUMP_CASCADE_RPM_HEADROOM` | `5` | RPM headroom buffer kept when scheduling cascade slot requests. |
| `CHUMP_CASCADE_STRATEGY` | `preferred` | Cascade slot selection: `preferred`, `round-robin`, or `cheapest`. |
| `CHUMP_CIRCUIT_COOLDOWN_SECS` | `120` | Circuit-breaker cooldown before allowing requests after threshold hit. |
| `CHUMP_CIRCUIT_FAILURE_THRESHOLD` | `3` | Consecutive failures before a cascade slot's circuit opens. |
| `CHUMP_CONTEXT_HYBRID_MEMORY` | `0` | Enable hybrid context (verbatim recent turns + LLM summary of older turns). |
| `CHUMP_CONTEXT_SUMMARY_THRESHOLD_AUTONOMY` | `80000` | Token count that triggers context summarization in autonomy sessions. |
| `CHUMP_CONTEXT_SUMMARY_THRESHOLD_LIGHT` | `40000` | Token threshold for summarization in light sessions. |
| `CHUMP_CONTEXT_SUMMARY_THRESHOLD_RESEARCH` | `60000` | Token threshold for summarization in research sessions. |
| `CHUMP_CONTEXT_VERBATIM_TURNS` | `4` | Number of most-recent verbatim turns kept before summarization. |
| `CHUMP_COST_CACHE_READ_PER_MTK` | `0.30` | Override cache-read token cost in $/MTok (env overrides `model_rates.yaml`). |
| `CHUMP_COST_INPUT_PER_MTK` | `3.00` | Override input token cost in $/MTok. |
| `CHUMP_COST_OUTPUT_PER_MTK` | `15.00` | Override output token cost in $/MTok. |
| `CHUMP_DEBUG_LOG` | `0` | Enable verbose debug logging to stderr. |
| `CHUMP_DEBUG_LOG_PATH` | _(none)_ | File path for debug log output; implies `CHUMP_DEBUG_LOG=1`. |
| `CHUMP_DELEGATE` | `0` | Enable delegation of subtasks to spawned subagents. |
| `CHUMP_DELEGATE_CONCURRENT` | `0` | Allow concurrent (parallel) delegated subagents. |
| `CHUMP_DELEGATE_MAX_PARALLEL` | `2` | Max parallel subagent slots when `CHUMP_DELEGATE_CONCURRENT=1`. |
| `CHUMP_DELEGATE_PREPROCESS` | `0` | Run prompt preprocessing before delegating to subagent. |
| `CHUMP_DELEGATE_PREPROCESS_CHARS` | `4000` | Max chars extracted during delegation preprocessing. |
| `CHUMP_DISABLE_ASK_JEFF` | `0` | Suppress HITL prompts that ask the operator directly. |
| `CHUMP_DISPATCH_BACKEND` | `local` | Dispatch backend: `local` (tmux), `remote` (SSH), or `docker`. |
| `CHUMP_DISPATCH_DEPTH` | `2` | Max recursion depth for dispatched task chains. |
| `CHUMP_DISPATCH_HANG_TIMEOUT_SECS` | `300` | Seconds before a dispatched task is considered hung. |
| `CHUMP_DOCKER_IMAGE` | _(none)_ | Docker image for sandboxed execution (requires `CHUMP_DISPATCH_BACKEND=docker`). |
| `CHUMP_DOCKER_MOUNT` | _(none)_ | Host path to mount into the Docker sandbox. |
| `CHUMP_DOCKER_NETWORK` | `bridge` | Docker network mode for sandboxed containers. |
| `CHUMP_EMBED_CACHE_DIR` | `.chump/embed-cache` | Directory for on-disk embedding cache files. |
| `CHUMP_EMBED_INPROCESS` | `0` | Run the embedding model in-process (no HTTP hop); needs `mistralrs` feature. |
| `CHUMP_EMBED_URL` | _(none)_ | Base URL of an external embedding API (used when `CHUMP_EMBED_INPROCESS=0`). |
| `CHUMP_EXPLOIT_THRESHOLD` | `0.7` | Bandit exploit-phase minimum reward before staying in exploit. |
| `CHUMP_EXPLORE_THRESHOLD` | `0.3` | Bandit explore-phase maximum reward before transitioning out. |
| `CHUMP_FIX_CLIPPY_REPO` | _(none)_ | Repo root path to apply auto-fix clippy pass to; used by CI guards. |
| `CHUMP_FLAGS` | _(none)_ | Comma-separated feature flags injected at runtime (replaces compile-time features). |
| `CHUMP_FREE_TIER_DELAY_MS` | `0` | Artificial inter-request delay in ms when `CHUMP_FREE_TIER_MODE=1`. |
| `CHUMP_FREE_TIER_MODE` | `0` | Enable free-tier rate-limiting dispatch (adds `CHUMP_FREE_TIER_DELAY_MS` between calls). |
| `CHUMP_FRUSTRATION_THRESHOLD` | `3` | Consecutive identical tool-call failures before emitting a frustration signal. |

---

## Tier 3 — Runtime state (A–G, do not override)

Set by the OS, Cargo build, or fleet harness. Overriding these in production will
break fleet coordination.

**System / OS / Cargo:**
`CARGO_MANIFEST_DIR`, `CARGO_PKG_VERSION`, `HOME`, `HOST`, `HOSTNAME`, `PATH`, `USER`, `XDG_CONFIG_HOME`

**Session / gap state (injected by worker.sh):**
`CHUMP_GAP_ID`, `CHUMP_SESSION_ID`, `CLAUDE_SESSION_ID`, `CHUMP_EXECUTION`

**Fleet automation flags (set per-invocation by dispatch scripts):**
`CHUMP_ALLOW_GAP_REWRITE` _(test/ci only)_, `CHUMP_ALLOW_RECYCLE` _(test/ci only)_,
`CHUMP_BINARY_STALENESS_CHECK` _(set by run-fleet.sh)_

**Test / CI / eval (set by test harnesses only):**
`CHUMP_BATTLE_BENCHMARK`, `CHUMP_BATTLE_LABEL`, `CHUMP_BATTLE_PRINT_METRICS`,
`CHUMP_COG027_GATE`, `CHUMP_EVAL_WITH_JUDGE`, `CHUMP_EXTRACT_BATCH`,
`CHUMP_EXTRACT_FACT_CHARS`, `CHUMP_GEN_STUB_FILE`, `FLEET_029_AMBIENT_GLANCE_SKIP`
