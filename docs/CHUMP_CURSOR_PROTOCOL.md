# Chump–Cursor communication protocol

This document defines the **communication protocol** between Chump (heartbeat, Discord bot) and Cursor (agent in this repo): message types, shared context, roles, and lifecycle. Use it together with **AGENTS.md**, **docs/ROADMAP.md**, and **docs/CHUMP_PROJECT_BRIEF.md**.

---

## 1. Roles (well-defined)

Roles are derived from **docs/CHUMP_PROJECT_BRIEF.md** and **docs/ROADMAP.md**.

| Role | System | Responsibilities |
|------|--------|------------------|
| **Orchestrator** | Chump | Reads ROADMAP + CHUMP_PROJECT_BRIEF at round start; picks work from task queue or unchecked roadmap items; delegates to Cursor when appropriate; episode-logs and follows up. |
| **Executor** | Cursor | Reads ROADMAP + CHUMP_PROJECT_BRIEF + AGENTS.md when starting; implements one roadmap item per run; writes code, tests, docs; marks item done in ROADMAP.md; leaves a brief summary for Chump. |
| **Context owner** | Both | Both read and (where allowed) update shared docs. Chump proposes work; Cursor updates ROADMAP.md when an item is complete and may update .cursor/rules, AGENTS.md, and docs. |

**Chump does not:** implement code/tests for roadmap items (delegates to Cursor).  
**Cursor does not:** invent its own roadmap; it works from the prompt and the unchecked items in ROADMAP.md.

---

## 2. Shared data context

Both systems use the same canonical files so priorities and conventions stay aligned.

### 2.1 Required reading (at start of round or handoff)

| File | Chump | Cursor |
|------|--------|--------|
| docs/ROADMAP.md | ✓ Start of work/opportunity/cursor_improve | ✓ Start of handoff or when working in repo |
| docs/CHUMP_PROJECT_BRIEF.md | ✓ Same | ✓ Same |
| AGENTS.md | ✓ When delegating | ✓ Before implementing |
| .cursor/rules/*.mdc | — | ✓ Conventions and handoff expectations |

### 2.2 Shared writable artifacts

| Artifact | Who updates | When |
|----------|-------------|------|
| docs/ROADMAP.md | Cursor (mark item done) | When a roadmap item is completed |
| .cursor/rules/*.mdc, AGENTS.md, docs (e.g. CURSOR_CLI_INTEGRATION.md) | Chump or Cursor | When improving relationship or conventions |
| Task queue (Discord) | Chump | Task create/update/done; Cursor does not touch task queue directly |

### 2.3 Context bundle (optional)

For a handoff, Chump can pass a **context bundle** in the prompt so Cursor has everything in one place:

- **Goal** — One clear sentence (e.g. "Fix the failing tests in logs/battle-qa-failures.txt").
- **Source** — Roadmap section or task ID (e.g. "From docs/ROADMAP.md 'Keep battle QA green'" or "Task #3").
- **Paths or logs** — Relevant file paths or log excerpts (e.g. `logs/battle-qa-failures.txt`, last 20 lines of test output).

Cursor should still read ROADMAP.md and CHUMP_PROJECT_BRIEF.md when relevant; the bundle is additive, not a replacement.

---

## 3. Message types and lifecycle

### 3.1 Handoff request (Chump → Cursor)

**Channel today:** CLI only. Chump runs `run_cli` with `agent -p "<prompt>" --force` (see docs/CURSOR_CLI_INTEGRATION.md).

**Required fields in the prompt:**

| Field | Description | Example |
|-------|-------------|---------|
| Goal | One clear sentence describing what to do | "Fix the failing tests in logs/battle-qa-failures.txt" |
| Source | Where this work comes from | "From docs/ROADMAP.md 'Keep battle QA green'" or "Task #3" |
| Paths or logs | Files or log snippets Cursor needs | "See logs/battle-qa-failures.txt and src/foo.rs" |

**Optional:** Explicit instruction to read ROADMAP and CHUMP_PROJECT_BRIEF (e.g. "Read docs/ROADMAP.md and docs/CHUMP_PROJECT_BRIEF.md when relevant.").

### 3.2 Handoff response (Cursor → Chump)

**Channel today:** Cursor’s reply is captured by the CLI (stdout); Chump sees it after the subprocess exits.

**Cursor must provide:**

- **Outcome** — What was done (e.g. "Fixed test X in src/foo.rs; battle_qa passes.").
- **Files changed** — List or short description (e.g. "src/foo.rs, docs/ROADMAP.md").
- **Roadmap** — If the work completed a roadmap item, Cursor must have edited ROADMAP.md (`- [ ]` → `- [x]`).
- **Next steps** — Brief suggestion for Chump (e.g. "Run battle_qa again; consider marking task #3 done in Discord.").

This summary allows Chump to episode-log and follow up without re-reading the whole codebase.

### 3.3 Lifecycle (single handoff)

1. **Chump:** Reads ROADMAP.md and CHUMP_PROJECT_BRIEF.md; picks one unchecked item or task.
2. **Chump:** Builds handoff prompt (goal + source + paths/logs); invokes Cursor via `run_cli` with `agent -p "..." --force`.
3. **Cursor:** Starts; reads ROADMAP, CHUMP_PROJECT_BRIEF, AGENTS.md; uses prompt + paths/logs to plan.
4. **Cursor:** Implements (code/tests/docs); marks roadmap item done in ROADMAP.md if applicable.
5. **Cursor:** Exits with a brief summary (outcome, files changed, next steps).
6. **Chump:** Receives summary; episode-logs; may set task done or run follow-up (e.g. battle_qa, notify user).

---

## 4. Direct API (future)

Today the only integration is **CLI**: Chump runs the `agent` binary via `run_cli`. A future **direct API** (HTTP) would follow the same protocol:

- **Request:** Same as handoff request (goal, source, paths/logs) as JSON body.
- **Response:** Same as handoff response (outcome, files changed, next steps) as JSON or text.
- **Context:** Same shared files; the API server could optionally accept a small "context bundle" JSON.

When an API is implemented, it will be documented in **docs/CURSOR_CLI_INTEGRATION.md** (e.g. "Direct API" section) and this protocol doc will reference it. The contract above defines the payloads so Chump and Cursor stay aligned whether the transport is CLI or HTTP.

---

## 5. References

| Doc | Purpose |
|-----|---------|
| docs/ROADMAP.md | Single source of truth for work; both read it. |
| docs/CHUMP_PROJECT_BRIEF.md | Focus, conventions, tool usage. |
| AGENTS.md | Chump–Cursor collaboration; when to delegate; handoff format. |
| docs/CURSOR_CLI_INTEGRATION.md | How Chump invokes Cursor (CLI); prompt format; timeouts; future API. |
| .cursor/rules/*.mdc | Repo conventions and handoff expectations for Cursor. |
