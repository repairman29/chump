# Gap Rollback Runbook — INFRA-899

> **Purpose.** Step-by-step procedure for recovering a gap that entered a
> failed or stalled state: agent dead, lease unreleased, worktree dirty,
> or CI permanently red with no path forward.
>
> **Automated path.** `scripts/ops/rollback-gap.sh <GAP-ID>` executes steps
> 1–5 automatically and emits `kind=gap_rollback_executed` to `ambient.jsonl`.
> Read this runbook to understand what it does before using `--force`.
>
> **Related.** INFRA-872 (failure detection — detects the failure and calls
> rollback); INFRA-889 (automatic rollback execution in the curator loop).

---

## When to use this runbook

A gap needs rollback when **all** of:

1. A lease file exists in `.chump-locks/claim-<GAP-ID>-*.json`
2. **At least one** of:
   - No commit on the gap's branch in the last 2 h (`git log --since="2h ago"`)
   - The CI for the gap's open PR has been red for > 2 h with no new push
   - The agent process is dead (tmux pane gone, `ps aux` shows no Claude)
   - The worktree path no longer exists

**Do not rollback** gaps that are making forward progress (recent commits, CI
recovering, agent still running).

---

## Step-by-step procedure

### Step 0 — Identify the gap state

```bash
GAP_ID="INFRA-XXX"   # set this

# Find the lease file
ls .chump-locks/claim-${GAP_ID}-*.json 2>/dev/null || echo "no lease"

# Find the branch
git branch | grep "$GAP_ID" | head -3

# Find the worktree
git worktree list | grep "$GAP_ID"

# Check last commit on the branch
BRANCH=$(git branch --list "*${GAP_ID}*" | tr -d ' *')
git log "$BRANCH" --oneline -3 2>/dev/null || echo "no commits / branch gone"
```

### Step 1 — Kill the agent process (if running)

```bash
# List tmux panes
tmux list-panes -a -F "#{pane_id} #{pane_title} #{pane_current_command}" 2>/dev/null | grep -i "$GAP_ID"

# Kill the pane (replace %N with actual pane ID)
tmux kill-pane -t %N

# If not in tmux, find and kill by process
ps aux | grep "claude.*$GAP_ID" | awk '{print $2}' | xargs kill -TERM 2>/dev/null || true
```

### Step 2 — Release the lease

```bash
# Automated release (preferred)
chump --release --lease .chump-locks/claim-${GAP_ID}-*.json

# Manual fallback: delete the lease file directly
LEASE=$(ls .chump-locks/claim-${GAP_ID}-*.json 2>/dev/null | head -1)
if [[ -n "$LEASE" ]]; then
    echo "Removing lease: $LEASE"
    rm -f "$LEASE"
fi
```

### Step 3 — Remove the worktree

```bash
WORKTREE_PATH=$(git worktree list | grep "$GAP_ID" | awk '{print $1}')

if [[ -n "$WORKTREE_PATH" ]]; then
    echo "Removing worktree: $WORKTREE_PATH"
    git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || \
        rm -rf "$WORKTREE_PATH"
    git worktree prune
fi
```

### Step 4 — Delete the branch

```bash
BRANCH=$(git branch --list "*${GAP_ID}*" | tr -d ' *' | grep "claim$" | head -1)

if [[ -n "$BRANCH" ]]; then
    echo "Deleting branch: $BRANCH"
    git branch -D "$BRANCH" 2>/dev/null || true
    git push origin --delete "$BRANCH" 2>/dev/null || true
fi
```

### Step 5 — Reset gap status to open

```bash
# Reset status and add failure note
chump gap set "$GAP_ID" status open
chump gap set "$GAP_ID" notes "Rolled back on $(date -u +%Y-%m-%dT%H:%M:%SZ) — agent stalled / CI red. Re-pick when root cause addressed."
```

### Step 6 — Emit rollback event to ambient

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AMB="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"
printf '{"ts":"%s","kind":"gap_rollback_executed","gap_id":"%s","worktree_removed":true,"branch_deleted":true,"lease_released":true,"operator":"manual"}\n' \
    "$TS" "$GAP_ID" >> "$AMB"
```

### Step 7 — Verify clean state

```bash
# Confirm no lease remains
ls .chump-locks/claim-${GAP_ID}-*.json 2>/dev/null && echo "WARN: lease still present" || echo "OK: no lease"

# Confirm no worktree
git worktree list | grep "$GAP_ID" && echo "WARN: worktree still listed" || echo "OK: worktree gone"

# Confirm gap is open
chump gap show "$GAP_ID" | grep "status:"
```

---

## Quick reference card

```bash
# One-liner: automated rollback (confirm before running)
bash scripts/ops/rollback-gap.sh INFRA-XXX

# Dry run first (prints what would happen, no changes)
bash scripts/ops/rollback-gap.sh --dry-run INFRA-XXX

# Force rollback even if gap looks healthy (dangerous — use with care)
bash scripts/ops/rollback-gap.sh --force INFRA-XXX
```

---

## Failure classes and recovery guidance

| Failure class | Symptom | Recovery |
|---|---|---|
| `transient` | Network blip, rate-limit hit once | Auto-rollback safe; re-pick immediately |
| `infra` | Worktree corrupted (INFRA-779), git broken | Auto-rollback safe; fix root cause before re-pick |
| `code_quality` | Pre-commit hook failed repeatedly | Manual review; fix AC or add bypass with reason |
| `stalled` | No commits for 2 h, no visible error | Manual review; check agent logs; may need human to un-stick |
| `oom` | Cargo OOM-killed mid-build (INFRA-349) | Auto-rollback safe; add CHUMP_CARGO_JOBS=1 to re-pick |

For `code_quality` and `stalled`, investigate root cause before re-claiming the gap.
For `transient` and `infra`, rollback immediately and re-pick.

---

## Do's and Don'ts

**Do:**
- Always run `--dry-run` first when unsure
- Check `ambient.jsonl` for `kind=gap_rollback_executed` to confirm the event was emitted
- File a new gap for the root cause if it's systemic (`code_quality` or `stalled`)
- Release leases before deleting worktrees (avoids stale gitdir references)

**Don't:**
- Delete `.chump-locks/*.json` files directly without `chump --release` — the
  DB may still hold the lease record
- Force-delete a worktree before confirming the agent is dead — you risk
  corrupting the agent's in-progress work
- Re-claim a stalled gap immediately — diagnose first or you'll re-enter the
  same failure loop

---

## See also

- `CLAUDE.md` → Fleet scaling gate (back-off triggers)
- `docs/process/CLAUDE_GOTCHAS.md` → Operational gotchas (INFRA-779, binary wedge)
- `scripts/ops/rollback-gap.sh` — automated implementation of this runbook
- `src/cost_ledger.rs` — cost quota guard (rollback also cancels pending spend)
