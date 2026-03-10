# Chump project brief — what we’re building

**Purpose:** Single place we keep updated so Chump (and humans) know **what we’re building** and **what’s in focus**. When Chump reads this (or we store a summary in his memory), he can answer “what’s the plan?” and align his work with it.

**Update this doc** when we change priorities or complete a phase. Chump learns from it via [TEACHING_CHUMP_WHAT_WE_BUILD](TEACHING_CHUMP_WHAT_WE_BUILD.md).

---

## What Chump is

- **One Chump, many chimps:** Single orchestrator (Chump) with delegate workers (chimps). No multiple Chump instances.
- **Local-first:** Rust agent, vLLM-MLX (or Ollama), SQLite + FTS5 + RRF memory, optional in-process embeddings. Discord + CLI; tools: run_cli, memory, calculator, wasm_calc, delegate (summarize, extract), web_search (Tavily).
- **Dogfood goal:** Chump will be able to read and edit his own repo, use GitHub (read/write his repos), and run in “executive” mode (no CLI allowlist) when we choose. Self-improve loop: read roadmaps → pick task → implement → test → commit (and push with approval).

---

## Current focus (what we’re doing now)

- **Bulletproof the chassis:** Fix panic/input risks (memory_tool unwrap, FTS5 query escaping); add core unit tests (memory_tool, cli_tool, local_openai). See [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md).
- **Fully armored vehicle:** After chassis, add resilience (retries, circuit breaker, model fallback), observability (health endpoint, structured log, request_id), and kill switch (pause). Then parallel workers (batch delegate) and concurrent turn cap. See [FULLY_ARMORED_VEHICLE](FULLY_ARMORED_VEHICLE.md).
- **Teaching Chump:** Use [CHUMP_PROJECT_BRIEF](CHUMP_PROJECT_BRIEF.md) (this doc) and key roadmaps so Chump can read or have summarized into memory; then he knows the plan when we ask or when he self-improves. See [TEACHING_CHUMP_WHAT_WE_BUILD](TEACHING_CHUMP_WHAT_WE_BUILD.md).

---

## Key docs (where the full plans live)

| Doc                                                             | What it’s for                                                                         |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| [ROADMAP](ROADMAP.md)                                           | Six pillars: systems, inference, memory, WASM, multi-agent.                           |
| [BULLETPROOF_CHASSIS](BULLETPROOF_CHASSIS.md)                   | Harden core: no panics, FTS5 safe, tests, CI.                                         |
| [FULLY_ARMORED_VEHICLE](FULLY_ARMORED_VEHICLE.md)               | Arsenal + gaps; FAV-1–FAV-6 (resilience, observability, security, capacity, testing). |
| [ROADMAP_DOGFOOD_SELF_IMPROVE](ROADMAP_DOGFOOD_SELF_IMPROVE.md) | Repo awareness → write_file → GitHub → executive mode → self-improve loop; tier 5.    |
| [ROADMAP_PARALLEL_AGENTS](ROADMAP_PARALLEL_AGENTS.md)           | One Chump, many chimps: batch delegate, concurrent turn cap.                          |
| [TEACHING_CHUMP_WHAT_WE_BUILD](TEACHING_CHUMP_WHAT_WE_BUILD.md) | How Chump learns the plan (brief, memory, heartbeat, read_file).                      |

---

## Phases at a glance

1. **Chassis** — Bulletproof: panic/input fixes, tests, CI.
2. **Armor** — FAV-1 resilience, FAV-2 observability + pause, FAV-3 security, FAV-4 parallel agents + chassis done.
3. **Dogfood** — Repo awareness (CHUMP_REPO, read_file/list_dir), then write_file, then GitHub, then executive mode, then self-improve loop.
4. **Teaching** — Keep this brief updated; Chump reads it (or we store a summary) so he knows the plan.

When in doubt: **update this brief**, then have Chump read it or store “current focus: …” in memory.
