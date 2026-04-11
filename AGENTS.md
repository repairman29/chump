# Chump–Cursor collaboration

This file defines how **Chump** (heartbeat, Discord bot) and **Cursor** (agent in this repo) work together. Both should treat **docs/ROADMAP.md** and **docs/CHUMP_PROJECT_BRIEF.md** as required context. Full doc index: **docs/README.md**. Protocol: **docs/CHUMP_CURSOR_PROTOCOL.md**.

---

## Learned User Preferences

*Maintenance:* see [docs/CONTINUAL_LEARNING.md](docs/CONTINUAL_LEARNING.md) (Cursor **continual-learning** / **agents-memory-updater**; local index under `.cursor/hooks/state/`, gitignored).

- Strong interest in **defense / federal** positioning for Chump-style agents (human-supervised workflows, compliance-aware deployment), not only commercial or IDE use cases.
- **Government revenue:** prioritize **procurement** paths (**SAM.gov** Contract Opportunities, **prime/integrator subcontracting**, **DIU CSO/OT**); treat **Grants.gov / NSF** and similar **assistance** instruments as **university- or eligible-nonprofit-led** routes for an LLC, not the default prime path.
- **Business setup:** solo **for-profit LLC** in progress; **Colorado** as home base for formation and operations; **no relocation** (travel for work is fine).
- For **federal BD and pilot execution**, prefer pointing to **`docs/DEFENSE_PILOT_EXECUTION.md`** and **`docs/FEDERAL_OPPORTUNITIES_PIPELINE.md`** alongside **`docs/DEFENSE_MARKET_RESEARCH.md`**.
- Prefer **automated battle tests, simulations, and hardening** to surface bugs before scaling **broad user research** or outward-facing demos.
- When the repo grows heavy with logs or generated artifacts, favor an **explicit archive or retention plan** so checkouts stay lean without losing retrievable context; see **`docs/STORAGE_AND_ARCHIVE.md`**.
- **MacBook-first / desktop companion:** Prioritize running Chump on a **MacBook** with **native Swift UI** (**ChumpMenu** and related desktop tooling) to interact with the bot; treat **Pixel / edge companion** hardware as **out of scope until explicitly requested**, not the default near-term target.
- Prefer **less Discord-only** operation over time: add **native/desktop paths** that talk to the same Chump backend so Discord is not the sole interface.
- **Hands-on execution:** Prefer having the agent **run commands, inspect logs, and apply fixes** in-repo when the environment allows, rather than only handing the user a checklist to run manually.
- **Product aspiration:** Treat Chump as a **high-autonomy, Mac-first chief-of-staff** for roadmap-driven engineering (orchestration, tools, and repo work), not only a casual Q&A chatbot.
- **GitHub operations:** Prefer **GitHub CLI** (`gh auth login`, `gh auth setup-git`, routine `gh`/`git` pushes) for authentication and pushes over **embedding PATs in `git remote` URLs**; keep tokens in **local `.env`** (gitignored) when tooling needs them, never in chat or committed config.
- **Epistemic / advanced-agent work:** Prefer **clear module boundaries, measurable loops, and pragmatic proxies** over open-ended heavy-math or “paper-perfect” cores that are hard to ship, test, or falsify in Rust.

## Learned Workspace Facts

- In-repo **defense / federal** references include **`docs/DEFENSE_MARKET_RESEARCH.md`**, **`docs/DEFENSE_PILOT_EXECUTION.md`**, and **`docs/FEDERAL_OPPORTUNITIES_PIPELINE.md`** (all linked from **`docs/README.md`**).
- **DoD SBIR/STTR** execution has been **paused on DSIP** pending statutory reauthorization; treat **dodsbirsttr.mil** / DSIP announcements as the live status source before planning SBIR as a near-term wedge.
- **Engineering upgrade tracks** (Claude/Cowork-tier execution plans and pragmatic gates) live in **`docs/ROADMAP_CLAUDE_UPGRADE.md`**, **`docs/CLAUDE_COWORK_UPGRADE_PLAN.md`**, and **`docs/PRAGMATIC_EXECUTION_CHECKLIST.md`**, alongside **`docs/ROADMAP.md`** / **`docs/ROADMAP_PRAGMATIC.md`**.

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
- **GitHub auth (Cursor / local tools):** Keep **`origin`** (and other remotes) as plain `https://github.com/repairman29/Chump.git` or SSH—**do not embed PATs in remote URLs**. Prefer **`gh auth login`** (and `gh auth setup-git` if needed) for Git operations; for Chump or tooling that reads **`GITHUB_TOKEN`**, set it in **local `.env`** only (gitignored). **Rotate** any token that was pasted into chat, logs, or a remote URL.
- **Epistemic / “consciousness” stack (engineering, not phenomenal claims):** Rust modules such as `surprise_tracker`, `blackboard`, `memory_graph`, `holographic_workspace`, etc., plus `scripts/consciousness-baseline.sh`, `consciousness-report.sh`, `consciousness-exercise.sh`. Scope and metrics: **`docs/CHUMP_RESEARCH_BRIEF.md`**, **`docs/CHUMP_TO_COMPLEX.md`**, **`docs/METRICS.md`**.
- **Speculative multi-tool batch (`speculative_execution`):** When the model returns **≥3** tool calls in one turn, `agent_loop` snapshots beliefs/neuromod/blackboard, runs tools, then may **rollback** in-process state if evaluation fails. **Rollback does not undo** filesystem, DB, or network effects from tools. Disable with **`CHUMP_SPECULATIVE_BATCH=0`**. See **`docs/METRICS.md`** and **`docs/ADR-001-transactional-tool-speculation.md`** for semantics vs future transactional tooling.
- **Discord preflight timeout:** Defaults to **10s** (configurable via `CHUMP_MODEL_PREFLIGHT_TIMEOUT_SECS`); preflight errors may mention Pixel **companion** scripts—on **Mac Chump**, use **docs/INFERENCE_PROFILES.md** (vLLM **8000** or Ollama **11434**): restart the **local model server** and/or **Chump bot process** (`run-discord.sh` etc.), not the Discord client app.
- **Primary inference profile:** vLLM-MLX on port **8000** is the standard Mac production setup; Ollama on **11434** is the dev/simple profile. See `docs/INFERENCE_PROFILES.md`.
- **Road tests and metrics:** For Chump validation, benchmarks, and performance baselines, prefer **local** model servers (per `docs/INFERENCE_PROFILES.md`) over external hosted APIs so runs stay repeatable and easier to interpret.

---

## 7. References

| Doc | Purpose |
|-----|---------|
| docs/ROADMAP.md | Single source of truth for what to work on; Chump and Cursor read it. |
| docs/ROADMAP_MASTER.md | Sectioned index of roadmap docs (execution, phases A–I, vision, fleet, metrics/ADRs). |
| docs/ROADMAP_PRAGMATIC.md | Phased achievable backlog (reliability → autonomy → fleet → product); use for *what to do next*. |
| docs/CHUMP_PROJECT_BRIEF.md | Focus, conventions, tool usage. |
| docs/CHUMP_CURSOR_PROTOCOL.md | Communication protocol: roles, shared context, message types, lifecycle, direct API contract. |
| docs/CURSOR_CLI_INTEGRATION.md | How Chump invokes Cursor (CLI); handoff prompt format; timeouts; future direct API. |
| docs/INTENT_ACTION_PATTERNS.md | Intent→action patterns for Discord (Chump and Cursor). |
| docs/INFERENCE_PROFILES.md | Canonical local inference: vLLM-MLX (8000) vs Ollama (11434), env, startup order. |
| .cursor/rules/*.mdc | Repo conventions and handoff expectations for Cursor. |
| .cursor/rules/roadmap-doc-hygiene.mdc | When editing roadmap hub docs: link rules, phase table vs ROADMAP_PRAGMATIC, ADR vs Phase G naming; see docs/CURSOR_CLI_INTEGRATION.md §3.4 for recurring handoff text. |
| .cursor/rules/improve-integration.mdc | Integration improvements: context sharing, automation, collaboration. |
| docs/CONTINUAL_LEARNING.md | Cursor continual-learning: transcript index, `agents-memory-updater`, updating Learned sections in this file. |
