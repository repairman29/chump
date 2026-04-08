# Autonomy roadmap (planning + task execution)

This roadmap turns autonomy into shippable milestones. The goal is: **Chump can pick work, plan it, execute it safely, verify results, and create follow-ups** with minimal human prompting.

## Success metrics (definition of “autonomy”)

- **Task throughput**: at least 1 task/day goes `open → in_progress → done` without human intervention beyond approvals.
- **Verification rate**: tasks marked `done` include at least one verification artifact (test command + pass, or explicit manual check instruction recorded).
- **Low rework**: <20% of “done” tasks need reopening due to missing acceptance criteria or lack of verification.

## Milestone 0 — Surfaces & control (done)

- [x] **Headless RPC mode**: `chump --rpc` JSONL stdin/stdout with streamed `AgentEvent`s and approvals.

## Milestone 1 — Task contract + planner/executor loop (core autonomy)

### 1.1 Task contract (acceptance + verification)

- [ ] **Task notes contract**: every task has structured sections:
  - **Context**
  - **Plan**
  - **Acceptance** (what “done” means)
  - **Verify** (commands/checks to run)
  - **Risks/Approvals** (tools likely to require approval)
- [ ] **TaskTool creates template** when notes are missing.
- [ ] **Parser/helpers** to extract contract fields from notes deterministically.
- [ ] **Tests**: round-trip notes parsing and template insertion.

**Done looks like**
- Creating a task without notes auto-populates the template.
- Contract parsing returns non-empty `acceptance` and `verify` for templated tasks.

### 1.2 Planner → Executor → Verifier loop

- [ ] **Planner**: selects the next task (highest priority, not blocked), expands plan into notes, sets `in_progress`.
- [ ] **Executor**: performs steps; appends progress to notes (timestamped).
- [ ] **Verifier**: runs `run_test` / repo checks; only marks `done` if verify passes; otherwise sets `blocked` and creates a follow-up task.
- [ ] **Episode log**: every completed loop writes an episode summary (what changed, verification, next steps).

**Done looks like**
- A “ship round” can complete at least one simple task end-to-end (with verification) using only tools.

### 1.3 Task claim/lease locking (multi-worker safe)

- [ ] Add a DB-backed **task lease** (claim token + expires_at + owner).
- [ ] Planner claims a task before work; executor renews lease; stuck tasks expire and re-open.

**Done looks like**
- Two concurrent workers cannot both set the same task `in_progress` if leases are enabled.

## Milestone 2 — Autonomy driver + policy automation

- [ ] **Autonomy driver process** (cron-friendly) that drives `chump --rpc`:
  - pull briefing/tasks
  - send `prompt` for one loop
  - stream events and persist logs
- [ ] **Policy-based approvals** (optional): auto-allow “low risk” tool approvals; escalate medium/high.

**Done looks like**
- Cron can run the driver hourly and Chump makes measurable progress (tasks updated, episodes written).

## Milestone 3 — Reliability: conformance fixtures and regression gates

- [ ] **Conformance fixtures** for key tools (`edit_file`, `run_cli` trimming, approvals).
- [ ] **Autonomy tests**: deterministic “mini task” scenarios (create task → plan → do → verify).

**Done looks like**
- CI runs a fast autonomy scenario suite and blocks regressions.

## Milestone 4 — Smarter planning (quality upgrades)

- [ ] Better task selection heuristics (dependency awareness, repo readiness, urgency).
- [ ] Decomposition: large tasks split into subtasks with explicit acceptance/verify per subtask.
- [ ] Memory linkage: project playbooks + gotchas auto-attached to context for relevant tasks.

