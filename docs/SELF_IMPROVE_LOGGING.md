# Self-improve and ops logging

Use this when you want **structured, grep-friendly logs** for debugging, timing analysis, and closed-loop improvement (scripts, battle QA, heartbeat).

## Quick start

From the repo root:

```bash
source ./scripts/env-self-improve-logging.sh
chump --web   # or --discord, etc.
```

Or set variables manually (see below).

## `RUST_LOG` and crate paths

The binary is built from the **`rust-agent`** package. Module filters use the Rust crate name: **`rust_agent::…`**, not `chump::…`. A line like `chump=debug` in `RUST_LOG` has no effect.

Examples:

- Default when `RUST_LOG` is unset: see `src/tracing_init.rs` (`DEFAULT_RUST_LOG`) — `info` with extra `debug` on agent loop, cascade, and local OpenAI.
- Cowork-style:  
  `RUST_LOG=warn,rust_agent=debug,rust_agent::agent_loop=debug,rust_agent::task_executor=debug,rust_agent::speculative_execution=debug,axonerai=info`

## Tracing output (`CHUMP_TRACING_*`)

| Variable | Effect |
|----------|--------|
| `CHUMP_TRACING_JSON_STDERR=1` | JSON lines on stderr (good for log aggregators). |
| `CHUMP_TRACING_FILE=1` | Append JSON lines to `logs/tracing.jsonl` under the runtime base (same tree as `logs/chump.log`). |
| `CHUMP_TRACING_FILE=/path/to/file.jsonl` | Append JSON to that path (relative paths are under runtime base). |

Human-readable stderr + JSON file is supported when JSON stderr is off and a file path is set.

## Application logs (`logs/chump.log`)

| Variable | Effect |
|----------|--------|
| `CHUMP_LOG_STRUCTURED=1` | Each line is JSON (easier to parse in scripts). |
| `CHUMP_LOG_TIMING=1` | Extra timing lines for Discord turns, provider cascade, and OpenAI-compatible calls (see `docs/OPERATIONS.md`, `docs/MABEL_PERFORMANCE.md`). |

Secrets in text are redacted when written through `chump_log` (tokens/keys such as `DISCORD_TOKEN`, `OPENAI_API_KEY`, `HF_TOKEN`, `CHUMP_WEB_TOKEN`, etc.).

## HTTP API tracing

| Variable | Effect |
|----------|--------|
| `CHUMP_WEB_HTTP_TRACE=1` | Adds `TraceLayer` to the **`/api/*` router only** (not static PWA files), so you get request spans in tracing without noise from asset requests. |

Pair with `RUST_LOG=tower_http=debug` (or `trace`) if you need more detail from the tower stack.

## mistral.rs (in-process)

With `CHUMP_INFERENCE_BACKEND=mistralrs` and the `mistralrs-infer` feature, logs include:

- Cold start: `mistralrs loading model` / `mistralrs model loaded` with `elapsed_ms`.
- Each completion: `mistralrs chat complete` with `elapsed_ms` and `streaming` true/false.

Set `rust_agent::mistralrs_provider=debug` in `RUST_LOG` if you lowered the default.

## Files

- `src/tracing_init.rs` — subscriber, defaults, file/JSON layers.
- `src/chump_log.rs` — structured log lines, redaction.
- `scripts/env-self-improve-logging.sh` — recommended exports for a self-improve session.
