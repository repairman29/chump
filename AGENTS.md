# Chump–Cursor collaboration

This file defines how **Chump** (heartbeat, Discord bot) and **Cursor** (agent in this repo) work together. Both should treat **docs/ROADMAP.md** and **docs/CHUMP_PROJECT_BRIEF.md** as required context. Full doc index: **docs/README.md**. Protocol: **docs/CHUMP_CURSOR_PROTOCOL.md**.

---

## 1. Roles and shared data context

**Well-defined roles (from docs/CHUMP_PROJECT_BRIEF.md and docs/ROADMAP.md):**

- **Chump (orchestrator):** Reads ROADMAP + CHUMP_PROJECT_BRIEF at round start; picks work from task queue or unchecked roadmap items; delegates to Cursor when appropriate; episode-logs and follows up. Does not implement code/tests for roadmap items—delegates to Cursor.
- **Cursor (executor):** Reads ROADMAP + CHUMP_PROJECT_BRIEF + AGENTS.md when starting; implements one roadmap item per run; writes code, tests, docs; marks item done in ROADMAP.md; leaves a brief summary for Chump. Does not invent its own roadmap—works from the prompt and unchecked items.

**Shared data context:** Both read **docs/ROADMAP.md** and **docs/CHUMP_PROJECT_BRIEF.md** at the start of a round or handoff. Cursor also reads **AGENTS.md** and **.cursor/rules/*.mdc**. Cursor updates **docs/ROADMAP.md** when an item is complete; either side may update **.cursor/rules**, AGENTS.md, or docs (e.g. CURSOR_CLI_INTEGRATION.md) when improving the relationship. See docs/CHUMP_CURSOR_PROTOCOL.md §2 for the full table.

---

## 2. Context both must read

- **Chump** (work, opportunity, cursor_improve rounds): At the start of a round, read **docs/ROADMAP.md** and **docs/CHUMP_PROJECT_BRIEF.md** so choices align with current focus, unchecked roadmap items, and conventions.
- **Cursor** (when working in this repo or on a Chump handoff): Before implementing, read **docs/ROADMAP.md**, **docs/CHUMP_PROJECT_BRIEF.md**, and **AGENTS.md** (this file). Use **.cursor/rules/** for conventions and handoff expectations.

This shared context keeps priorities consistent and avoids duplicate or out-of-scope work.

---

## 3. Strategies for collaboration

### 3.1 Handoffs (Chump → Cursor)

- **When Chump delegates:** Use `run_cli` with `agent -p "..." --force` (see docs/CURSOR_CLI_INTEGRATION.md). The prompt must include:
  - **Goal** — One clear sentence (e.g. "Fix the failing tests in logs/battle-qa-failures.txt").
  - **Source** — Roadmap section or task ID (e.g. "From docs/ROADMAP.md 'Keep battle QA green'" or "Task #3").
  - **Paths or logs** — Relevant files or log snippets so Cursor can act without guessing.
- **Cursor’s job:** Read ROADMAP + CHUMP_PROJECT_BRIEF + AGENTS.md, do the work, then **mark the roadmap item done** in ROADMAP.md (`- [ ]` → `- [x]`) when the item is complete. Leave a brief summary (what was done, files changed, what to do next) in the reply or in a comment so Chump can episode-log and follow up.

### 3.2 cursor_improve rounds

- In **cursor_improve** rounds (or when the soul directs), Chump should pick **one** unchecked roadmap item from "Product and Chump–Cursor" or "Implementation, speed, and quality" and either:
  - **Implement via Cursor:** Invoke `agent -p "..." --force` with a prompt that includes goal, source (ROADMAP section), and any paths/logs; or
  - **Improve the relationship:** Update `.cursor/rules/*.mdc`, AGENTS.md, or docs (e.g. CURSOR_CLI_INTEGRATION.md, CHUMP_PROJECT_BRIEF.md) so future handoffs are clearer.
- Run cursor_improve (or use Cursor directly) to implement **one roadmap item at a time**; mark it done in ROADMAP.md when complete.

### 3.3 Product improvement loop

- **Order of operations:** Improve **rules and docs first** (so Cursor and Chump share context), then **use Cursor to implement** code, tests, and docs.
- Chump may write or update Cursor rules and AGENTS.md; Cursor should follow them and suggest doc/rule updates when conventions are missing or ambiguous.
- Document what works (handoff prompt format, timeout needs, which roadmap items are done) in AGENTS.md or docs/CURSOR_CLI_INTEGRATION.md so the next round is more efficient.

---

## 4. Efficiency

- **Prompt design:** Chump should pass enough context in the `-p` prompt that Cursor rarely needs to ask; include file paths, log excerpts, and the exact roadmap line when relevant.
- **One item at a time:** Avoid bundling multiple roadmap items in one Cursor run; complete and mark one, then move to the next.
- **Marking done:** When Cursor completes a roadmap item, edit ROADMAP.md to check the box (`- [ ]` → `- [x]`) and, if applicable, set task status to done and episode log (Chump can do the latter in the next round).
- **Timeouts:** For Cursor CLI invocations, consider `CHUMP_CLI_TIMEOUT_SECS` ≥ 300 so the agent can finish; document in CURSOR_CLI_INTEGRATION.md if longer runs are needed.

---

## 5. When Chump should delegate to Cursor

- **Complex fixes** — e.g. battle QA failures, clippy, multiple TODOs.
- **User request** — e.g. "use Cursor to fix this" or "let Cursor implement it."
- **cursor_improve round** — Implement one unchecked roadmap item or improve rules/docs for the relationship.
- **After reading ROADMAP and CHUMP_PROJECT_BRIEF** — So the prompt can reference current focus and the specific roadmap item being worked on.

---

## 6. Learned conventions

Incremental notes from Chump–Cursor sessions (high-signal only; parent workspace `AGENTS.md` may hold additional user preferences).

- **GitHub vs Cargo package name:** The canonical GitHub repository for this project is **`repairman29/Chump`**. The Rust package in `Cargo.toml` may still be named **`chump-chassis`**, which can surface in Cargo output and tooling—when diagnosing “wrong repo” or remote confusion, confirm with **`git remote -v`** and repo docs, not the crate name alone.
- **Synthetic Consciousness Framework:** Six modules integrated into the main binary — `surprise_tracker`, `memory_graph`, `blackboard`, `counterfactual`, `precision_controller`, `phi_proxy` — covering Active Inference, HippoRAG-inspired associative memory, Global Workspace Theory, causal reasoning, thermodynamic precision tuning, and IIT proxy metrics. 95 tests (84 original + 10 integration + 1 exercise).
- **Consciousness tooling:** `scripts/consciousness-baseline.sh` captures metrics to `logs/consciousness-baseline.json`; `scripts/consciousness-report.sh` produces a human-readable diagnostic; `scripts/consciousness-exercise.sh` runs the full exercise harness.
- **Discord preflight timeout:** Defaults to **10s** (configurable via `CHUMP_MODEL_PREFLIGHT_TIMEOUT_SECS`); error message distinguishes Mac (vLLM 8000 / Ollama 11434) from Pixel (companion). When "Model server isn't responding" appears, restart the **Chump bot process** (`run-discord.sh` etc.) — not the Discord client app.
- **Primary inference profile:** vLLM-MLX on port **8000** is the standard Mac production setup; Ollama on **11434** is the dev/simple profile. See `docs/INFERENCE_PROFILES.md`.

---

## 7. References

| Doc | Purpose |
|-----|---------|
| docs/ROADMAP.md | Single source of truth for what to work on; Chump and Cursor read it. |
| docs/CHUMP_PROJECT_BRIEF.md | Focus, conventions, tool usage. |
| docs/CHUMP_CURSOR_PROTOCOL.md | Communication protocol: roles, shared context, message types, lifecycle, direct API contract. |
| docs/CURSOR_CLI_INTEGRATION.md | How Chump invokes Cursor (CLI); handoff prompt format; timeouts; future direct API. |
| docs/INTENT_ACTION_PATTERNS.md | Intent→action patterns for Discord (Chump and Cursor). |
| docs/INFERENCE_PROFILES.md | Canonical local inference: vLLM-MLX (8000) vs Ollama (11434), env, startup order. |
| .cursor/rules/*.mdc | Repo conventions and handoff expectations for Cursor. |
| .cursor/rules/improve-integration.mdc | Integration improvements: context sharing, automation, collaboration. |
