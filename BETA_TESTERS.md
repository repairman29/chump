# Beta Tester Guide

Thanks for testing Chump. This doc tells you what to expect, what's known-broken, and how to report feedback.

## What Chump is

A self-hosted AI coding agent that runs on your machine with local models (Ollama). It has persistent memory, task tracking, tool governance, and a web UI. Think "Aider or Cursor, but fully self-hosted with durable state."

## Time to first success

| Step | Time |
|------|------|
| Clone + setup | 2 min |
| `cargo build` (first time) | 15-25 min |
| `ollama pull qwen2.5:14b` | 5-15 min (9 GB) |
| Start web + verify health | 1 min |
| **Total** | **~30 min** |

The Rust compile is the long part. This is normal. Subsequent builds are fast (~10s incremental).

## What to test

1. **Web PWA** (`./run-web.sh` then open http://127.0.0.1:3000)
   - Ask it to explain some code
   - Ask it to create a file
   - Ask it to run a shell command
   - Check that `/api/health` returns OK

2. **CLI** (`./run-local.sh -- --chump "your prompt here"`)
   - Does it respond?
   - Does it use tools when appropriate?

3. **Setup experience**
   - Was anything confusing in the README or golden path?
   - Did any step fail unexpectedly?

## What NOT to worry about

- **Discord bot** — optional, skip it for now
- **Fleet/Mabel/Pixel** — future features, not in scope
- **ChumpMenu (macOS menu bar)** — nice-to-have, not the primary surface
- **Provider cascade** — advanced multi-model routing, skip for beta
- **Consciousness framework** — experimental internal feature, ignore it
- **Heartbeats/schedules** — for 24/7 operation, not needed for testing
- **Empty dashboard panels** — normal without `chump-brain/` and heartbeats

## Known limitations

- **Response latency:** 30-60s per response with local 14B models. This is model inference time, not a bug.
- **First response after restart:** May take longer as the model loads into memory.
- **macOS only tested regularly.** Linux should work. Windows needs WSL2.
- **No pre-built binaries yet.** You must compile from source.
- **Large `.env.example`:** 400 lines of options. Start with `.env.minimal` (10 lines) instead.

## System requirements

- **RAM:** 16 GB minimum (Ollama + 14B model needs ~10 GB)
- **Disk:** ~15 GB (Rust toolchain + model + build artifacts)
- **CPU:** Apple Silicon recommended. x86_64 works but slower inference.
- **OS:** macOS 13+ or Linux. Windows via WSL2.

## How to report feedback

### Something broke

Use the [bug report template](https://github.com/repairman29/chump/issues/new?template=bug_report.md). Include:
- What step you were on
- The error message or unexpected behavior
- Output of `./scripts/verify-external-golden-path.sh`

### Something was confusing

Use the [friction report template](https://github.com/repairman29/chump/issues/new?template=friction_report.md). This is just as valuable as bug reports. If a step was unclear, took too long, or made you guess — that's a friction report.

### Quick feedback

If it's small, just open a plain GitHub issue with the label `beta-feedback`.

## Env file guide

Start with `.env.minimal` — it has the 3 lines you actually need for Ollama. The full `.env.example` is a reference for power users.

| Variable | Required? | Default |
|----------|-----------|---------|
| `OPENAI_API_BASE` | Yes | `http://localhost:11434/v1` |
| `OPENAI_API_KEY` | Yes | `ollama` |
| `OPENAI_MODEL` | Yes | `qwen2.5:14b` |
| `RUST_LOG` | No | `warn,chump=info` |
| `DISCORD_TOKEN` | No | Comment out to skip Discord |
| `CHUMP_HOME` | No | Auto-detected from binary location |
| `CHUMP_REPO` | No | Auto-detected from git |

Everything else in `.env.example` is optional and can be ignored until you need it.
