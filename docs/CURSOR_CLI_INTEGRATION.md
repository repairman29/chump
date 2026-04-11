# Cursor CLI integration

How **Chump** invokes **Cursor** for implementation work: CLI today, optional direct API later. For roles, shared context, and message types see **docs/CHUMP_CURSOR_PROTOCOL.md**.

---

## 1. Overview

- **Chump** (heartbeat, Discord) delegates implementation to **Cursor** by running the Cursor CLI (`agent`) via `run_cli`.
- The **communication protocol** (handoff request/response, shared context, lifecycle) is defined in **docs/CHUMP_CURSOR_PROTOCOL.md**.
- Both systems read **docs/ROADMAP.md** and **docs/CHUMP_PROJECT_BRIEF.md**; Cursor also reads **AGENTS.md** and **.cursor/rules/**.

---

## 2. Current integration: CLI

### 2.1 Prerequisites

- **Cursor CLI** installed and in `PATH` (e.g. `~/.local/bin` or `~/.cursor/bin`). Install: `curl https://cursor.com/install -fsS | bash`.
- In `.env`: `CHUMP_CURSOR_CLI=1`.
- If you use an allowlist: add `agent` to `CHUMP_CLI_ALLOWLIST` so Chump can run the Cursor CLI.
- **Working directory:** Chump runs `run_cli` with `CHUMP_REPO` or `CHUMP_HOME` as cwd when set; Cursor runs in the repo so paths in the prompt are correct.

### 2.2 Invocation

Chump calls:

```bash
run_cli with command: agent --model auto -p "<prompt>" --force
```

- No `--path`; the full handoff description goes inside `-p "..."`.
- `--force` runs non-interactively so the agent can finish without user input.
- Chump must not truncate the prompt; include goal, source, and paths/logs (see §3).

### 2.3 Environment variables

| Variable | Purpose | Suggested |
|----------|----------|-----------|
| CHUMP_CURSOR_CLI | Enable Cursor CLI delegation | `1` when using Cursor |
| CHUMP_CLI_TIMEOUT_SECS | Timeout for `run_cli` (seconds) | `300` for normal Cursor runs; `600` for cursor_improve |
| CHUMP_REPO / CHUMP_HOME | Repo root for run_cli cwd and Cursor | e.g. `~/Projects/Chump` |
| CHUMP_CLI_ALLOWLIST | If set, must include `agent` | e.g. `cargo,git,agent,...` |

---

## 3. Handoff prompt format (Chump → Cursor)

Follow **docs/CHUMP_CURSOR_PROTOCOL.md** §3.1. Every prompt must include:

1. **Goal** — One clear sentence (e.g. "Fix the failing tests in logs/battle-qa-failures.txt").
2. **Source** — Roadmap section or task ID (e.g. "From docs/ROADMAP.md 'Keep battle QA green'" or "Task #3").
3. **Paths or logs** — Relevant file paths or log excerpts so Cursor can act without guessing.

Optional but helpful: "Read docs/ROADMAP.md and docs/CHUMP_PROJECT_BRIEF.md when relevant."

### Example prompt

```
Goal: Fix the failing tests listed in logs/battle-qa-failures.txt.
Source: From docs/ROADMAP.md "Keep battle QA green".
Paths/logs: See logs/battle-qa-failures.txt (last 30 lines). Focus on src/runner.rs if the failure points there.
Read docs/ROADMAP.md and docs/CHUMP_PROJECT_BRIEF.md when relevant.
```

### 3.4 Roadmap doc hygiene (recurring)

Use this for **cursor_improve**, quarterly reconcile, or after a big phase ships so hub docs stay aligned.

**Handoff prompt (paste and adjust):**

```
Goal: Roadmap documentation hygiene pass — reconcile hub docs with docs/ROADMAP_PRAGMATIC.md; fix broken relative links in docs/; resolve ADR vs Phase G naming ambiguity.
Source: Recurring maintenance; .cursor/rules/roadmap-doc-hygiene.mdc checklist.
Paths: docs/ROADMAP_MASTER.md, docs/ROADMAP.md, docs/ROADMAP_PRAGMATIC.md, docs/ROADMAP_REMAINING_GAPS.md, docs/README.md (roadmap rows only). Follow the rule file’s checklist; do not change roadmap scope — consistency and links only unless the prompt adds a specific item.
```

Chump can schedule this like any other **cursor_improve** round (same timeout guidance as §4).

---

## 4. Timeouts and long runs

- **CHUMP_CLI_TIMEOUT_SECS** applies to all `run_cli` calls, including Cursor. Use **≥ 300** (5 minutes) for typical Cursor runs.
- For **cursor_improve** or multi-file refactors, use **600** (10 minutes) or higher; document in this file if you need longer (e.g. for large test runs).
- If Cursor hits the timeout, Chump will see partial output; the protocol still expects Cursor to leave a short summary when possible (what was done, what’s left).

---

## 5. What Cursor must do after a handoff

See **docs/CHUMP_CURSOR_PROTOCOL.md** §3.2. In short:

- Do the work (code, tests, docs).
- If the work completes a roadmap item, edit **docs/ROADMAP.md** and change the corresponding `- [ ]` to `- [x]`.
- Leave a **brief summary**: outcome, files changed, suggested next steps (e.g. "Run battle_qa again; mark task #3 done in Discord").

Chump uses this summary to episode-log and follow up.

---

## 6. Direct API (future / contract)

Today the only integration is **CLI**. A future **direct API** (HTTP) would keep the same semantics so Chump and Cursor stay aligned.

### 6.1 API contract (for implementers)

- **Endpoint:** e.g. `POST /cursor/run` or similar (to be defined when implemented).
- **Request body (JSON):**
  - `goal` (string): One clear sentence.
  - `source` (string): Roadmap section or task ID.
  - `paths_or_logs` (string, optional): File paths or log excerpts.
  - `context_bundle` (object, optional): Additional key-value context (e.g. task id, branch name).
- **Response:**
  - Success: `200` with body containing `outcome`, `files_changed`, `next_steps` (and optionally raw stdout).
  - Timeout or failure: `4xx`/`5xx` with error message; Chump should treat as failed handoff and episode-log.
- **Timeouts:** Server should enforce a max duration (e.g. 300–600s) consistent with CHUMP_CLI_TIMEOUT_SECS.
- **Context:** The API server runs in the repo (or has access to it) so Cursor can read ROADMAP.md, CHUMP_PROJECT_BRIEF.md, and the paths mentioned in the request.

When a direct API is implemented, update this section with the real endpoint, auth (if any), and link from **docs/CHUMP_CURSOR_PROTOCOL.md** §4.

---

## 7. Best practices

- **One item per run:** Don’t bundle multiple roadmap items in one Cursor prompt; complete and mark one, then start another.
- **Prompt design:** Chump should pass enough in the prompt that Cursor rarely has to ask; include file paths, log snippets, and the exact roadmap line when relevant.
- **Document what works:** If you find a prompt shape or timeout that works well, add it here or in AGENTS.md so the next round is more efficient.
- **Roadmap cluster:** When editing `docs/ROADMAP*.md`, ADRs, or `docs/README.md` roadmap rows, follow **`.cursor/rules/roadmap-doc-hygiene.mdc`** (or run the §3.4 recurring handoff).
- **Rules and docs first:** When improving the relationship, update **.cursor/rules**, AGENTS.md, or docs (e.g. this file, CHUMP_CURSOR_PROTOCOL.md) before asking Cursor to implement code; then use Cursor to implement.

---

## 8. References

| Doc | Purpose |
|-----|---------|
| docs/CHUMP_CURSOR_PROTOCOL.md | Roles, shared context, message types, lifecycle, future API. |
| docs/ROADMAP.md | Single source of truth for work; both read it. |
| docs/CHUMP_PROJECT_BRIEF.md | Focus, conventions, tool usage. |
| AGENTS.md | When Chump delegates; handoff format; marking done. |
| scripts/test-cursor-cli-integration.sh | Script to verify Cursor CLI and CHUMP_CURSOR_CLI. |
| scripts/cursor-cli-status-and-test.sh | Status checks and one-shot test. |
