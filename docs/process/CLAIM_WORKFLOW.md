# How to claim work — full walkthrough

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

Chump uses a gap registry stored canonically in `.chump/state.db` (SQLite,
since INFRA-059). `docs/gaps/<ID>.yaml` files are a human-readable
per-file mirror that gets regenerated, not edited by hand.

0. **Install pre-commit hooks** (one-shot, after fresh clone or `git
   worktree add`) — `scripts/setup/install-hooks.sh`. Idempotent. Without
   them, your commits silently bypass every guard — Cold Water Issue #10
   (2026-05-02) found 9 gaps shipped to `origin/main` with `closed_pr: TBD`
   precisely because remote-dispatched sandboxes had skipped this step.
   `bot-merge.sh` now auto-bootstraps if hooks are missing.
1. **Pick an open gap** — `chump gap list --status open`.
2. **Preflight** — `chump gap preflight <GAP-ID>` checks done-on-main and
   live claims by sibling sessions.
3. **Claim** — `chump gap claim <GAP-ID>` writes a lease file under
   `.chump-locks/<session_id>.json`. Claims do not go in the registry —
   they live in lease files only. The `CHUMP_GAPS_LOCK` pre-commit guard
   rejects writes of `in_progress`/`claimed_by`/`claimed_at` to any
   `docs/gaps/<ID>.yaml`. Never leave a lease behind.
4. **Work in a linked worktree** — `git worktree add .chump/worktrees/<name>
   -b chump/<codename> origin/main`. Never work in the main repo root.
5. **Reclaim disk** — `bot-merge.sh` deletes `./target` after ship unless
   `CHUMP_KEEP_TARGET=1`. For merged/abandoned trees run
   `scripts/ops/stale-worktree-reaper.sh` (dry-run by default; `--execute`
   to remove), or install the hourly LaunchAgent
   `scripts/setup/install-stale-worktree-reaper-launchd.sh`. Per-tree
   opt-out: `touch <worktree>/.chump-no-reap`.

## Diagnosing divergence (META-014)

Before filing an RCA/regression gap claiming "X reverted my change" or
"origin has unexpected state," verify against origin/main directly:

```bash
git fetch origin main --quiet
git show origin/main:<file> | head -50
git diff HEAD origin/main -- <file>
```

INFRA-238 is the cautionary example: ~30 minutes wasted on a P0 RCA for a
phantom revert that was actually a local checkout 8 commits behind
origin/main.

When the gap ships, `chump gap ship <GAP-ID> --update-yaml` flips `status:
done`, stamps `closed_date`, and regenerates `docs/gaps/<GAP-ID>.yaml`
atomically with the implementing PR.

## Subagent briefing + fleet launcher

Every `Agent`-tool prompt must start with
`docs/process/SUBAGENT_DEFAULT_BRIEFING.md` (or
`bash scripts/lib/get-agent-briefing-prefix.sh`). Override:
`CHUMP_AGENT_DEFAULT_PREFIX=<path>`.

Canonical multi-agent launcher: `scripts/dispatch/run-fleet.sh` — N tmux
panes + a control pane, each worker looping pick-gap → claim → worktree →
`claude -p --dangerously-skip-permissions` → ship via `bot-merge.sh` →
release. Defaults: `FLEET_SIZE=8`, P0/P1 only, xs/s/m effort only. Stop
with `tmux kill-session -t chump-fleet` or `FLEET_SIZE=0
scripts/dispatch/run-fleet.sh`.

## Gap closure precision fields

- `acceptance_verified:` — array of yes/no per acceptance criterion.
- `closed_interpretation:` — free text explaining closure rationale when
  criteria changed mid-execution.
