# AGENT_START_HERE — Chump North-Star Entry Point (META-1037)

Welcome to the Chump workspace. Read this one-screen summary first, then follow the canonical guides linked below:

- **Canonical Cross-Tool Guide:** [`AGENTS.md`](./AGENTS.md)
- **Claude Code & Fleet Worker Overlay:** [`CLAUDE.md`](./CLAUDE.md)

## 1. Mission & Active Objective

- **Annual Mission:** [`docs/MISSION.md`](./docs/MISSION.md) (active mission pointer: `~/.chump/ACTIVE_MISSION`, scoreboard: `bash scripts/dev/mission-scoreboard.sh`).
- **Current Objective Pointer:** `.chump-locks/current-objective.json` (inspect via `chump objective show` or read `.chump-locks/iter-agenda.jsonl`).
- **Four Pillars:** **Credible** (receipts over self-report), **Effective** (mission-linked user outcomes), **Resilient** (self-healing under failure), **Zero-Waste** (no duplicate implementations or idle token burn).

## 2. Where to Find the Gap Queue

- **Canonical Gap Store:** SQLite `.chump/state.db` (`chump gap list --status open`, `chump gap show <ID>`).
- **Claiming Work:** Always claim atomically via `chump claim <GAP-ID>` in a linked worktree before editing tracked files.

## 3. Do-Not-Re-Fold Rule

- Do not duplicate or inline the contents of [`AGENTS.md`](./AGENTS.md) or [`CLAUDE.md`](./CLAUDE.md) into secondary docs, prompts, or role specs. Link to the canonical sections in [`AGENTS.md`](./AGENTS.md) and [`CLAUDE.md`](./CLAUDE.md) so operational rules have a single source of truth.
