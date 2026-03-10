# Fully Armored Vehicle: Arsenal and Gaps

This doc is the **master checklist** for a production-grade Chump: what we already have (the arsenal) and what we’re **missing** so the vehicle is fully armored. It ties together [ROADMAP](ROADMAP.md), [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md), [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md), and [ROADMAP_PARALLEL_AGENTS](ROADMAP_PARALLEL_AGENTS.md), and adds the gaps we didn’t cover there (resilience, observability, security, recovery, kill switch, model fallback, etc.).

**Principle:** One Chump, many chimps; dogfood and self-improve; parallel workers and safe concurrency. The armor is everything that makes that setup **reliable, observable, and safe** under load and failure.

**Must-have for "fully armored":** FAV-1 through FAV-5 done, plus BULLETPROOF_CHASSIS Phase A–C (panic/input safety, core tests, CI inprocess-embed + Chump Menu build in rust-agent.yml). **Optional:** FAV-6 (tracing, metrics, graceful shutdown, approval API, config schema); wasmtime in CI.

---

## Plan status: what's in code vs to-do

| Area              | In code today                                                                                                                                                                          | Still to-do                           |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| **Resilience**    | Model retry/backoff, fallback (`CHUMP_FALLBACK_API_BASE`), circuit breaker; doc in TROUBLESHOOTING                                                                                     | Discord reconnect doc (optional)      |
| **Observability** | `CHUMP_LOG_STRUCTURED=1`, request_id in logs, health server (`CHUMP_HEALTH_PORT`), version in logs + health                                                                            | Metrics export; tracing (FAV-6)       |
| **Safety**        | Kill switch (`logs/pause`, `CHUMP_PAUSED=1`); doc in CHUMP_SERVICE / TROUBLESHOOTING                                                                                                   | Formal approval API (FAV-6, optional) |
| **Security**      | Secrets redaction, input caps (`CHUMP_MAX_MESSAGE_LEN`, `CHUMP_MAX_TOOL_ARGS_LEN`), rate limit (`CHUMP_RATE_LIMIT_TURNS_PER_MIN`); doc in TROUBLESHOOTING                              | —                                     |
| **Capacity**      | `CHUMP_MAX_CONCURRENT_TURNS`; batch delegate (`tasks` array, `CHUMP_DELEGATE_MAX_PARALLEL`)                                                                                            | Queue depth doc (optional)            |
| **Chassis**       | BULLETPROOF_CHASSIS Phase A–C done (panic/input safety, core tests, CI inprocess-embed + Chump Menu build in rust-agent.yml); design targets in README; degradation in TROUBLESHOOTING | —                                     |

---

## Part 1: What we have (the arsenal)

### Strategy and roadmaps

| Doc                                                             | Covers                                                                                    |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [ROADMAP](ROADMAP.md)                                           | Six pillars: systems, inference, memory, WASM, multi-agent; phasing.                      |
| [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md)                   | Implementation assessment; panic/input-safety fixes; core unit tests; CI.                 |
| [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md) | Repo awareness, write_file, GitHub read/write, executive mode, self-improve loop; tier 5. |
| [ROADMAP_PARALLEL_AGENTS](ROADMAP_PARALLEL_AGENTS.md)           | One Chump, many chimps; batch delegate; safe concurrent turns; no multi-Chump.            |

### Core behavior and identity

| Doc                                             | Covers                                                                   |
| ----------------------------------------------- | ------------------------------------------------------------------------ |
| [CHUMP_IDENTITY](CHUMP_IDENTITY.md)             | Soul, purpose, memory, heartbeat (design), CLI/exec, logs.               |
| [ORCHESTRATOR_WORKER](ORCHESTRATOR_WORKER.md)   | Delegate tool (summarize, extract); worker model; one Chump many chimps. |
| [CHUMP_SMART_MEMORY](CHUMP_SMART_MEMORY.md)     | SQLite + FTS5, RRF, embed server, in-process embeddings.                 |
| [CHUMP_AUTONOMY_TESTS](CHUMP_AUTONOMY_TESTS.md) | Tiers 0–4 (and tier 5 in dogfood); what each tier unlocks.               |

### Infrastructure and ops

| Doc                                             | Covers                                                  |
| ----------------------------------------------- | ------------------------------------------------------- |
| [CHUMP_SERVICE](CHUMP_SERVICE.md)               | Warm-the-ovens, launchd, embed server, heartbeat-learn. |
| [MLX_MULTI_MODEL](MLX_MULTI_MODEL.md)           | 8000/8001, 30B-only, delegate worker model.             |
| [MEMORY_AND_PROCESSES](MEMORY_AND_PROCESSES.md) | Memory pressure, OOM, what uses RAM, how to free it.    |
| [TROUBLESHOOTING](TROUBLESHOOTING.md)           | vLLM crash, Metal/NSRangeException, connection closed.  |

### Safety and quality

| Doc                                                 | Covers                                     |
| --------------------------------------------------- | ------------------------------------------ |
| [WASM_TOOLS](WASM_TOOLS.md)                         | wasm_calc, wasmtime, no FS/network.        |
| [STRUCTURED_TOOL_OUTPUT](STRUCTURED_TOOL_OUTPUT.md) | tool_choice auto, malformed JSON handling. |
| [USER_STORIES](USER_STORIES.md)                     | 20 stories (repo, git, planning).          |

### Implemented today (summary)

- **Runtime:** Rust, &lt;20MB idle, schema-validated tools, CLI timeout/cap, allowlist/blocklist, audit log (chump.log).
- **Memory:** SQLite + FTS5 + RRF, optional in-process embeddings; proactive recall.
- **Tools:** run_cli, memory, calculator, wasm_calc, delegate (summarize, extract), web_search (Tavily).
- **Orchestration:** One Chump; delegate workers one-at-a-time (parallel workers planned).
- **Ops:** Warm-the-ovens, heartbeat-learn (with optional retry per round), Chump Menu, launchd.
- **Testing:** Autonomy tiers 0–4; unit tests for calc, memory_db, delegate; CI build/test/clippy, inprocess-embed job, Chump Menu build (macOS).

---

## Part 2: What we’re missing (gaps to close)

Gaps are grouped by category. Each item is something we **don’t yet have** or **don’t yet do consistently**; the next section turns these into a prioritized “add to arsenal” plan.

### Resilience

| Gap                      | What we have today                                                                                  | What’s missing                                                                                                                                                             |
| ------------------------ | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Retries with backoff** | Heartbeat has optional `HEARTBEAT_RETRY=1` (one retry per round). Embed health check before recall. | No retry/backoff for **model** calls (local_openai) or **Tavily** on transient failure. One 5xx or connection reset → whole turn fails.                                    |
| **Circuit breaker**      | None.                                                                                               | After N consecutive failures to the model (or embed, or Tavily), stop calling for a cooldown (e.g. 30s) then try again. Avoids hammering a dead server.                    |
| **Model fallback**       | Warm-the-ovens can start 8000; heartbeat preflight can fall back to 8001.                           | No **provider-level** “if 8000 fails, try 8001” for normal Discord/CLI turns. User sees “connection closed” instead of automatic retry or fallback.                        |
| **Discord reconnection** | Serenity handles reconnect; we don’t customize.                                                     | Document or add explicit reconnection/backoff if the gateway drops; optional “replay last N messages” after reconnect (or at least clear session so we don’t half-resume). |

### Observability

| Gap                    | What we have today                                                       | What’s missing                                                                                                                                                     |
| ---------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Structured logging** | Append-only lines in chump.log (msg, reply, cli).                        | No **structured** format (e.g. JSON or key=value) for easy parsing. No request_id or trace_id to follow one turn across log lines.                                 |
| **Metrics**            | None.                                                                    | No counters (turns, tool calls, errors) or latencies (time to first token, turn duration). Would enable “how many turns/hour,” “p99 latency,” “delegate failures.” |
| **Health endpoint**    | Embed server has /health; vLLM has /v1/models. Chump has no HTTP server. | No single **Chump health** check (e.g. “can I reach model + embed + DB?”). Scripts or Chump Menu could call it to show “ready” or “degraded.”                      |
| **Tracing**            | No spans or trace IDs.                                                   | No way to trace one user message → model call → tool calls → reply in one trace (for debugging and latency breakdown).                                             |

### Security and secrets

| Gap                       | What we have today                                                    | What’s missing                                                                                                                                                                                |
| ------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Secrets in logs**       | We log command, channel, user, reply length.                          | No **redaction** policy: ensure tokens (DISCORD_TOKEN, TAVILY_API_KEY, GITHUB_TOKEN) and sensitive args never appear in chump.log or stderr. Malformed tool JSON log could contain user data. |
| **Input caps**            | Discord message length is bounded by Discord; we truncate CLI output. | No explicit **max message length** or **max tool-call payload size** in the agent (could OOM or abuse the model with huge input).                                                             |
| **Rate limit (external)** | Tavily has credits; we prompt “use sparingly.”                        | No **hard cap** (e.g. max N web_search calls per hour) or per-user/channel rate limit for Discord.                                                                                            |

### Recovery and state

| Gap                   | What we have today                                                | What’s missing                                                                                                                                                                  |
| --------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Crash recovery**    | Session persisted per channel; no in-memory “current turn” state. | If the process crashes **mid-turn** (e.g. during a long tool run), we don’t resume; next message starts fresh. Document that “partial turn is lost” or add optional checkpoint. |
| **Graceful shutdown** | Process exits on signal; no drain.                                | No “drain in-flight turns then exit” so we don’t kill a turn mid-stream. Optional for a &lt;20MB process; document.                                                             |

### Safety and control

| Gap                         | What we have today                      | What’s missing                                                                                                                                                                                                                  |
| --------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Kill switch / pause**     | Stop process or Stop Chump in menu.     | No **soft pause**: e.g. file `logs/pause` or env `CHUMP_PAUSED=1` so Chump stays up but refuses new messages (or only responds “I’m paused”) until cleared. Lets you stop work without killing the process or heartbeat script. |
| **Human-in-the-loop gates** | Dogfood doc says “confirm before push.” | No **formal** approval gate: e.g. “destructive” tool (git push, write_file) returns “pending_approval” and a separate “approve last action” flow. Optional; can stay in prompt only.                                            |

### Capacity and limits

| Gap                     | What we have today                                                   | What’s missing                                                                         |
| ----------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Concurrent turn cap** | ROADMAP_PARALLEL_AGENTS Phase 2: semaphore for max concurrent turns. | Not implemented yet. Add `CHUMP_MAX_CONCURRENT_TURNS` and “busy” response.             |
| **Parallel workers**    | ROADMAP_PARALLEL_AGENTS Phase 1: batch delegate.                     | Not implemented yet. Add delegate_batch or tasks array and join_all.                   |
| **Queue depth**         | None.                                                                | If we add a queue (Phase 2), document max queue depth and “reject when full” behavior. |

### Testing and CI

| Gap                    | What we have today                                                  | What’s missing                                                                                                                                                                                |
| ---------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Integration tests**  | Autonomy tiers (live model + optional Tavily). No mock.             | No **mock model server** test: e.g. start a tiny HTTP server that returns valid OpenAI-format JSON; run one full agent turn and assert tool calls and reply. Runs in CI without a real model. |
| **Resilience / chaos** | None.                                                               | No test that “kill model mid-request” and assert we don’t panic and we log or return a clear error.                                                                                           |
| **CI coverage**        | Build, test, clippy; inprocess-embed job; Chump Menu build (macOS). | Optional wasmtime job (rust-agent-wasm.yml).                                                                                                                                                  |

### Deployment and lifecycle

| Gap                     | What we have today                                                  | What’s missing                                                                                                                           |
| ----------------------- | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| **Config schema**       | Env vars documented in README; no formal schema.                    | Optional: JSON schema or checklist of required/optional env for “Discord + heartbeat” vs “CLI only” so operators know what to set.       |
| **Version and upgrade** | Binary version in Cargo.toml; no “Chump version” in logs or health. | Optional: log version at startup; health endpoint could return version. Eases “what’s running?” and upgrade debugging.                   |
| **Migration**           | Memory: JSON → SQLite migrate on first use.                         | No formal **migration** doc (e.g. “upgrading from X to Y: run Z”). For now one DB and one schema; document when we add breaking changes. |

---

## Part 3: Add to arsenal — prioritized plan

Phases below close the gaps in order of impact. **BULLETPROOF_CHASSIS Phase A–C are done** (panic/input safety, core tests, CI inprocess-embed + Chump Menu build in rust-agent.yml).

### Phase FAV-1: Resilience basics (high impact)

- **Model retry:** In `local_openai` (or provider layer), on transient error (connection refused, 5xx, timeout), retry up to 2 times with short backoff (e.g. 1s, 2s). Then return error to the agent so it can say “model temporarily unavailable.”
- **Model fallback (optional):** Env `CHUMP_FALLBACK_API_BASE` (e.g. 8001). If primary (8000) fails after retries, try fallback once for that request. Document when to use (e.g. 30B primary, 7B fallback).
- **Circuit breaker (simple):** In-memory “failure count” per target (model, embed). After e.g. 3 consecutive failures, mark target down for 30s; then allow one request. If it succeeds, reset count. Prevents tight loop when server is dead.
- **Doc:** Add a “Resilience” section to TROUBLESHOOTING: retries, fallback, circuit breaker behavior.

**Exit criteria:** Model retries and optional fallback; circuit breaker for model (and optionally embed); doc updated.

### Phase FAV-2: Observability and control (high impact)

- **Structured log line (optional):** Add a “structured” mode: e.g. env `CHUMP_LOG_STRUCTURED=1` → each log line is JSON with `ts`, `event`, `channel_id`, `request_id`, `tool`, `duration_ms`, etc. Keeps existing text format as default.
- **Request/trace id:** Generate a short request_id per Discord message (or CLI run); include it in every log line for that turn. Enables “grep this id” for one full turn.
- **Health check:** Add a minimal HTTP server (e.g. only when `CHUMP_HEALTH_PORT=18766` set) that serves `GET /health` → 200 and JSON `{ "model": "ok"|"down", "embed": "ok"|"down"|"n/a", "memory": "ok" }` by probing 8000, embed URL, and DB. Chump Menu or scripts can call it.
- **Kill switch:** If file `logs/pause` exists (or `CHUMP_PAUSED=1`), Discord handler responds “I’m paused” without running the agent; heartbeat can skip rounds. Document in CHUMP_SERVICE.

**Exit criteria:** Optional structured logging and request_id; health endpoint; pause file/env; doc.

### Phase FAV-3: Security and limits (medium impact)

- **Secrets redaction:** Before writing to chump.log (or stderr), redact known token names and values (DISCORD_TOKEN, TAVILY_API_KEY, etc.) and truncate or redact tool args that might contain secrets. Document “we never log tokens.”
- **Input caps:** Configurable max user message length (e.g. 16k chars) and max tool-call args size (e.g. 32k). Return clear error if exceeded.
- **Rate limit (optional):** Per Discord user or channel: max N turns per minute (e.g. 5). When exceeded, reply “rate limited; try again in a minute.” Configurable or off by default.

**Exit criteria:** Redaction in place; input caps and rate limit documented or implemented; doc.

### Phase FAV-4: Capacity (parallel agents + chassis)

- **Implemented:** [ROADMAP_PARALLEL_AGENTS](ROADMAP_PARALLEL_AGENTS.md) Phase 1 (batch delegate: `tasks` array, **CHUMP_DELEGATE_MAX_PARALLEL**) and Phase 2 (**CHUMP_MAX_CONCURRENT_TURNS** semaphore for Discord). See [ORCHESTRATOR_WORKER](ORCHESTRATOR_WORKER.md) and [TROUBLESHOOTING](TROUBLESHOOTING.md#security-and-limits).
- **Chassis:** [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md) Phase A–C are done (panic/input safety, core tests, CI inprocess-embed + Chump Menu build).

**Exit criteria:** Parallel workers and concurrent turn cap in place; chassis Phase A–B done.

### Phase FAV-5: Testing and deployment (medium impact)

- **Implemented:** **Mock integration test** in `main.rs`: wiremock returns OpenAI completion JSON, `build_chump_agent_cli()` + `agent.run("Hello")`, assert reply contains mock content. No real model. **Version:** `version::chump_version()` from env `CHUMP_VERSION` or `CARGO_PKG_VERSION`; logged at startup (Discord and Chump CLI); health JSON includes `version`.
- **Done:** CI job with `--features inprocess-embed` and Chump Menu build in [rust-agent.yml](../../.github/workflows/rust-agent.yml). Optional: wasmtime in rust-agent-wasm.yml.

**Exit criteria:** At least one mock-based integration test; version in logs or health. CI inprocess-embed and Chump Menu build run in rust-agent CI.

### Phase FAV-6: Optional and later

- **Tracing:** Full request tracing (span per tool, per model call) if we add a tracing crate later.
- **Metrics export:** Prometheus or statsd endpoint if we want dashboards.
- **Graceful shutdown:** Drain in-flight turns on SIGTERM (optional).
- **Human-in-the-loop API:** Formal “pending_approval” and “approve” flow for destructive ops (optional; can stay prompt-based).
- **Config schema:** JSON schema or markdown checklist for env (optional).

---

## Summary table: arsenal vs gaps

| Category          | In arsenal                                                                                                            | Missing (add in FAV phase)                              |
| ----------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| **Resilience**    | Model retry, fallback, circuit breaker; heartbeat retry; embed health                                                 | Discord reconnect doc (optional)                        |
| **Observability** | chump.log; CHUMP_LOG_STRUCTURED; request_id; health endpoint; Chump Menu                                              | Metrics; tracing (FAV-6, optional)                      |
| **Security**      | Allowlist/blocklist; audit log; WASM; redaction; input caps; rate limit                                               | —                                                       |
| **Recovery**      | Session persistence                                                                                                   | Crash mid-turn doc; drain on shutdown (FAV-6, optional) |
| **Safety**        | Soft pause (logs/pause, CHUMP_PAUSED); prompt-based confirm before push                                               | Formal approval API (FAV-6, optional)                   |
| **Capacity**      | CHUMP_MAX_CONCURRENT_TURNS; batch delegate (tasks array)                                                              | Queue depth doc (optional)                              |
| **Testing**       | Unit tests; autonomy tiers; mock integration test; version in logs/health; CI inprocess-embed; Chump Menu build in CI | Chaos test (opt.)                                       |
| **Deployment**    | launchd; Chump Menu; README; CHUMP_READY_DM_USER_ID + CHUMP_NOTIFY_FULLY_ARMORED                                      | Config schema (optional); migration doc                 |

**Fully armored** = FAV-1 through FAV-5 done (resilience, observability, security, capacity, testing/version), plus BULLETPROOF_CHASSIS Phase A–C. FAV-6 and wasmtime CI are optional polish.

### Notify when ready (Discord DM)

When Chump is fully armored and you want a DM on connect:

1. Set **CHUMP_READY_DM_USER_ID** to your Discord user ID (Settings → Advanced → Developer Mode → right‑click your avatar → Copy User ID).
2. Set **CHUMP_NOTIFY_FULLY_ARMORED=1**.
3. Start Chump with `--discord`. When the bot connects, you get a DM: _"Chump is fully armored and ready. Resilience (retry, fallback, circuit breaker), observability (structured log, request_id, health), security (redaction, input caps, rate limit), kill switch, and capacity (concurrent turns, batch delegate) are in place. You can dogfood and self-improve."_

Without `CHUMP_NOTIFY_FULLY_ARMORED`, the ready DM is the standard "Chump is online and ready to chat" message. The binary loads `.env` from the current directory (or next to the executable) at startup, so these vars are read even when you start via Chump Menu or `cargo run`. If you don't get the DM: ensure your Discord account allows DMs from server members; check the bot's stderr or `logs/discord.log` for "Ready DM failed" or "Could not create DM channel."

---

## Links

- [ROADMAP](ROADMAP.md) — Pillars and phasing.
- [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md) — Harden core first.
- [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md) — Repo, GitHub, executive, self-improve.
- [ROADMAP_PARALLEL_AGENTS](ROADMAP_PARALLEL_AGENTS.md) — One Chump, many chimps.
- [CHUMP_SERVICE](CHUMP_SERVICE.md) — Ops and heartbeat.
- [TROUBLESHOOTING](TROUBLESHOOTING.md) — When things break.
