# Autonomy roadmap (planning + task execution)

This roadmap turns autonomy into shippable milestones. The goal is: **Chump can pick work, plan it, execute it safely, verify results, and create follow-ups** with minimal human prompting.

## Success metrics (definition of “autonomy”)

- **Task throughput**: at least 1 task/day goes `open → in_progress → done` without human intervention beyond approvals.
- **Verification rate**: tasks marked `done` include at least one verification artifact (test command + pass, or explicit manual check instruction recorded).
- **Low rework**: <20% of “done” tasks need reopening due to missing acceptance criteria or lack of verification.

## Milestone 0 — Surfaces & control (done)

- [x] **Headless RPC mode**: `chump --rpc` JSONL stdin/stdout with streamed `AgentEvent`s and approvals.

**Ordering:** See [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) phase **B** for how this file fits the full achievable backlog.

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

### 1.3 Task claim/lease locking (multi-worker safe) — **implemented**

- [x] DB-backed **task lease** (claim token + `expires_at` + owner) in `task_db`; used by `autonomy_loop.rs`.
- [x] Planner claims before work; renew before verify; release on exit; `chump --reap-leases` + task tool `reap_leases`.

**Still open**
- [ ] **Conformance tests**: two logical workers, second cannot claim same task; CI fixture (see [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) B3/B4).

**Done looks like**
- Two concurrent workers cannot both hold a valid lease on the same task; tests prove it.

## Milestone 2 — Autonomy driver + policy automation

## Ops: running autonomy in production (recommended)

Use the **single-task-per-run** loop for reliability.

- **Run once**: `chump --autonomy-once`
- **Cron/supervisor wrapper**: `./scripts/autonomy-cron.sh`
- **Preflight maintenance**: `chump --reap-leases` (runs automatically from `scripts/autonomy-cron.sh`)

Recommended env:
- `CHUMP_AUTONOMY_ASSIGNEE`: which queue to work (default `chump`)
- `CHUMP_AUTONOMY_OWNER`: lease owner identifier (unique per machine/worker)
- `CHUMP_TASK_LEASE_TTL_SECS`: lease TTL (default 900)
- `CHUMP_TASK_STUCK_SECS`: requeue cutoff for stale `in_progress` with no active lease (default 1800). Used by `--reap-leases`.

Repo tasks (multi-repo) notes:
- If a task has `repo` set, `--autonomy-once` will deterministically run `github_clone_or_pull` then `set_working_repo` before execution/verification.
- This requires enabling repo tooling via env:
  - `GITHUB_TOKEN` + `CHUMP_GITHUB_REPOS` (allowlist)
  - `CHUMP_MULTI_REPO_ENABLED=1` and `CHUMP_HOME` or `CHUMP_REPO`

Suggested cadence:
- every 5–15 minutes (depending on provider budget and how long tasks take)

- [ ] **Autonomy driver process** (cron-friendly) that drives `chump --rpc`:
  - pull briefing/tasks
  - send `prompt` for one loop
  - stream events and persist logs
- [ ] **Policy-based approvals** (optional): auto-allow “low risk” tool approvals; escalate medium/high.

**Done looks like**
- Cron can run the driver hourly and Chump makes measurable progress (tasks updated, episodes written).

## Milestone 3 — Reliability: conformance fixtures and regression gates

- [ ] **Conformance fixtures** for key tools (`patch_file`, `write_file`, `run_cli` trimming, approvals).
- [ ] **Autonomy tests**: deterministic “mini task” scenarios (create task → plan → do → verify).

**Done looks like**
- CI runs a fast autonomy scenario suite and blocks regressions.

## Milestone 4 — Smarter planning (quality upgrades)

- [ ] Better task selection heuristics (dependency awareness, repo readiness, urgency).
- [ ] Decomposition: large tasks split into subtasks with explicit acceptance/verify per subtask.
- [ ] Memory linkage: project playbooks + gotchas auto-attached to context for relevant tasks.

