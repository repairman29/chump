# Cursor + Claude Code on Chump — coordination index

**Purpose:** One entry point for teams that use **both** surfaces on the same repo. Same invariants everywhere; only cadence and tooling differ.

---

## When to use which surface

| Situation | Prefer | Why |
|-----------|--------|-----|
| Long autonomous queue, warm context, `ScheduleWakeup` | **Claude Code** + `scripts/agent-loop.sh` or `/loop` | Built-in self-scheduling and Chump tool parity. |
| IDE pair-programming, subagents, repo-wide refactors | **Cursor** (Composer + rules) | Tight edit loop, diff review, multi-file navigation. |
| Discord / `run_cli` / automation says “fix X in worktree Y” | **Cursor CLI** (`agent -p`) | Headless, scriptable; same lease rules as IDE. |
| Filing a gap under contention | **Either** — must run `scripts/gap-reserve.sh` first | IDs are global; surface does not matter. |
| Shipping + merge queue | **Either** — `scripts/bot-merge.sh` / hooks | Same bar; no surface bypasses hooks. |

**Both at once:** common in squads (one agent in Claude Code, another in Cursor). Use distinct **`CHUMP_SESSION_ID`** values, smaller PRs, and **`bash scripts/fleet-status.sh`** before picking work.

---

## Shared invariants (non-negotiable)

1. **`git fetch origin main`** before coordination reads.
2. **`scripts/gap-preflight.sh <GAP-ID>`** then **`scripts/gap-claim.sh <GAP-ID>`** before shared edits (or reserve-then-file flow per **`docs/AGENT_LOOP.md`**).
3. **Linked worktrees** for feature work — not the main checkout root (see **`CLAUDE.md`**).
4. **No hook bypass** (`CHUMP_*=0`, `--no-verify`) to clear unexplained errors.

---

## Doc map

| Doc | Role |
|-----|------|
| **`docs/AGENT_LOOP.md`** | Autonomous loop, anti-stomp, `gap-reserve`, `/loop` vs shell wrapper, **Dual-surface team model**. |
| **`docs/CHUMP_CURSOR_FLEET.md`** | Cursor-specific: CLI smoke, subagents, `run_cli`, env table, **Claude handoff** paste-back. |
| **`docs/AGENT_COORDINATION.md`** | Leases, ambient, merge semantics. |
| **`docs/INTENT_ACTION_PATTERNS.md`** | Discord / `run_cli` delegation wording. |
| **`CLAUDE.md`** | Worktrees, `chump-commit.sh`, Chump-only mechanics. |

---

## Smoke (no API keys)

From repo root after `cargo build --bin chump`:

```bash
bash scripts/coord-surfaces-smoke.sh
# or pass any other open gap id (CI uses RESEARCH-018):
bash scripts/coord-surfaces-smoke.sh RESEARCH-018
```

Extends the Cursor-only probe in `scripts/cursor-cli-status-and-test.sh` (which still covers `agent` + optional one-shot LLM) with **gap-preflight, gap-claim, musher, briefing** checks using an isolated `CHUMP_LOCK_DIR`.
