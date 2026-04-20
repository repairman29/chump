# Agent Loop — Autonomous Work Queue

Give this doc to any Claude Code agent to put it on the shared work queue. It will pick gaps, do the work, ship PRs, and loop — without needing to be re-prompted.

---

## Starting a new agent — two modes

### Interactive Claude Code session (recommended)

1. Open a new Claude Code session
2. Type `/loop` — this gives the agent the `ScheduleWakeup` tool so it can self-pace
3. Paste as the first (or only) message:

```
You are a Chump agent on the autonomous work queue. Read docs/AGENT_LOOP.md and follow the loop instructions exactly. Start immediately — call ScheduleWakeup after each gap ships.
```

`/loop` is critical. Without it the agent has no way to reschedule itself and will stop after one gap.

### Unattended / scripted (shell loop wrapper)

```bash
scripts/agent-loop.sh
# or with a cap:
scripts/agent-loop.sh --max-gaps 10
```

This re-invokes `claude -p` with the AGENT_LOOP prompt after each gap. The agent does one gap per run and exits; the shell handles the retry loop. No `/loop` needed.

### If `/loop` isn't available

If the agent reports that `ScheduleWakeup` is not a recognized tool, fall back to the shell wrapper above. The shell wrapper is always reliable; `/loop` is a speedup (warm cache, no re-init cost).

---

## The loop (what every agent does)

```
1. git fetch origin main --quiet
2. scripts/musher.sh --pick          → get your gap assignment
3. scripts/gap-preflight.sh <GAP-ID> → verify it's still available
4. chump --briefing <GAP-ID>         → load context for this gap
5. Do the work in .claude/worktrees/<codename>/
6. scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
7. Go to step 1
```

If `musher.sh --pick` returns nothing (queue empty): sleep 5 minutes, then retry from step 1.

---

## Full instructions (for the agent)

### Your job
Pick the next available gap from `docs/gaps.yaml`, do the work, ship a PR, repeat. The gap registry and lease system coordinate you with other agents — you never need to ask a human what to work on.

### Step-by-step

**1. Sync and check the queue**
```bash
git fetch origin main --quiet
scripts/musher.sh --pick
```
`musher.sh --pick` reads the live gap registry + active leases + open PRs and prints the best unclaimed gap for you. If the queue is empty it exits 1 — sleep 5 min and retry.

**2. Preflight**
```bash
scripts/gap-preflight.sh <GAP-ID>
```
Exits 1 if the gap was claimed between your `--pick` and now. If it fails, run `--pick` again.

**3. Load context**
```bash
chump --briefing <GAP-ID>
```
Produces a single markdown briefing: gap description, acceptance criteria, relevant lessons from `chump_improvement_targets`, recent ambient events, prior PRs that touched the same domain.

**4. Read the project rules**
Read `AGENTS.md` (build/test/lint/style) and `CLAUDE.md` (coordination, worktrees, commit discipline) before touching any files. They're short.

**5. Claim and work**
```bash
scripts/gap-claim.sh <GAP-ID>
# work in .claude/worktrees/<codename>/
```
Always work in a linked worktree, never in the main repo root.

**6. Ship**
```bash
scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
```
This rebases on main, runs fmt/clippy/tests, opens the PR, and arms auto-merge. It prints the PR number when done. Once it runs, treat the PR as frozen — don't push more commits to it.

**7. Loop**
Return to step 1.

---

### Rules that matter most

| Rule | Why |
|------|-----|
| Always work in `.claude/worktrees/<codename>/` | Main repo stomps break other agents |
| Use `scripts/chump-commit.sh` not `git add && git commit` | Prevents cross-agent staging drift |
| Keep PRs ≤ 5 files, ≤ 5 commits | Smaller PRs land faster; merge conflicts are cheaper |
| Never touch `docs/gaps.yaml` except to set `status: done` when shipping | Claims live in `.chump-locks/`, not the YAML |
| Never push to `main` directly | Branch is `claude/<codename>` |
| Never touch COG-031 | Held at v9; requires explicit human decision |

---

### Self-scheduling with ScheduleWakeup (when in /loop mode)

After every gap ships OR after a queue-empty check, call `ScheduleWakeup` with:
- `prompt`: the exact text `"You are a Chump agent on the autonomous work queue. Read docs/AGENT_LOOP.md and follow the loop instructions exactly. Start immediately — call ScheduleWakeup after each gap ships."`
- `delaySeconds`: **60** if you just shipped, **270** if queue was empty (stays inside the 300s cache TTL)
- `reason`: one line — e.g. `"shipped INFRA-007, checking queue for next gap"` or `"queue empty, retrying in 270s"`

Without this call at the end of every turn, the loop dies. Always call it.

---

### Checking what's available right now

```bash
scripts/musher.sh --status          # full dispatch table
scripts/musher.sh --assign 3        # 3 non-overlapping assignments for 3 agents
scripts/musher.sh --why <GAP-ID>    # explain why a gap is/isn't available
scripts/musher.sh --check <GAP-ID>  # conflict analysis for a specific gap
```

---

### Signals from other agents

Check `tail -20 .chump-locks/ambient.jsonl` before starting work. Key events:

- `session_start` — another agent is online; note their gap
- `file_edit` — note the path (may overlap yours)
- `commit` — note the sha (may have advanced main past your rebase)
- `ALERT kind=lease_overlap` — **stop**: two sessions claim the same files
- `ALERT kind=silent_agent` — a live session stopped heartbeating; its work may be lost

---

### When to stop looping

- `musher.sh --pick` returns nothing AND all gaps are blocked by dependencies
- You hit an unresolvable merge conflict (rebase manually, then continue)
- A gap is marked `effort: XL` (musher never auto-assigns these — skip and pick the next)
- Jeff tells you to stop

---

*This doc is the only prompt you need. Pass it to any new agent to add it to the fleet.*
