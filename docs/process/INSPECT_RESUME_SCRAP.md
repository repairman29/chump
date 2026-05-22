# Inspect / Resume / Scrap — the Saturday-morning surface (INFRA-1456)

> A wedged agent should feel like debugging a normal local git branch.
> If it doesn't, the operator becomes a Chump-administrator instead of
> a developer — and the abstraction is net-negative.

## The scenario

It's Saturday morning. You ran a 20-agent fleet Friday night. `chump fleet
status` says **18 green, 2 wedged**. You have 60 seconds to figure out
why those 2 are wedged before you start regretting installing Chump.

The three commands below are the eject-and-inspect surface. They make a
wedged gap legible the way `git status` makes a confused branch legible.

## chump inspect &lt;gap-id&gt;

Opens a debug view for a wedged gap.

- With `tmux` available, spawns a 3-pane session:
  1. **Worktree shell** — already `cd`'d to the lease's worktree.
  2. **Live ambient tail** — `tail -F ambient.jsonl | grep <gap-id>`.
  3. **Recent ambient snapshot** — last 50 events for this gap.
- Without `tmux`, prints the same three sections as text.

```
chump inspect INFRA-1234
```

If the lease points at a worktree that no longer exists on disk, the
command prints a clear pointer at INFRA-779 (gitdir-confusion) recovery
and falls back to text mode.

**v1 limitation:** the per-bash command trajectory (cmd / cwd / exit-code
/ stdout-tail per agent invocation) is **not yet captured**. The pane
shows a placeholder noting the follow-up gap. Today the recent ambient
events stream is the best signal.

## chump resume &lt;gap-id&gt;

Validates that a wedged worktree is **recoverable** before the operator
re-attaches it to the fleet.

Checks:
- Lease still present in `.chump-locks/`
- Worktree directory still on disk
- No dangling `rebase-merge` / `rebase-apply` / `MERGE_HEAD` /
  `CHERRY_PICK_HEAD` state
- `git status --porcelain` is empty (no uncommitted churn that would
  surprise an agent re-picking the gap)

Verdicts:
- `ready` — exits 0; safe to re-pick (operator triggers fleet restart)
- `dirty <reason>` — exits 1; operator must fix
- `worktree_missing` — exits 1; run `chump scrap` then `chump claim`
- `lease_missing` — exits 1; run `chump claim`

```
chump resume INFRA-1234
```

Emits `kind=gap_resumed` to ambient.jsonl with the verdict.

## chump scrap &lt;gap-id&gt;

Cleanly destroys a wedged gap with **zero residue**.

Tears down:
- The linked git worktree (`git worktree remove --force`, with `rm -rf`
  fallback if the gitdir is corrupt)
- The lease JSON in `.chump-locks/`
- The local branch (`git branch -D`)
- Dangling worktree refs (`git worktree prune`)

```
chump scrap INFRA-1234
```

Emits `kind=gap_scrapped` to ambient.jsonl with per-component success
flags so a sweeper script can detect partial scraps.

**v1 limitation:** no sandbox-container teardown yet — v1 INFRA-1454
uses macOS `sandbox-exec` (no container). When INFRA-1454 v2 adds
Linux/podman/Docker support, scrap will also `podman rm -f <ctr>` /
`docker rm -f <ctr>` for the gap's container.

## End-to-end recovery recipe

```bash
# 1. See what's wedged
chump fleet status

# 2. Eject into the worst offender
chump inspect INFRA-1234
#    (tmux opens; investigate; commit or stash any in-progress work)

# 3. Decide:
#    (a) recoverable → fix in worktree, then:
chump resume INFRA-1234
#        if "ready", restart fleet to re-pick the gap

#    (b) not recoverable → throw it away:
chump scrap INFRA-1234
#        re-claim fresh:
chump claim INFRA-1234
```

## Telemetry

Every invocation emits to `.chump-locks/ambient.jsonl`:

| Command | Event kind | Fields |
|---|---|---|
| `chump inspect` (no event) | _none_ | view-only |
| `chump resume`  | `gap_resumed` | `gap`, `verdict`, `summary` |
| `chump scrap`   | `gap_scrapped` | `gap`, `session`, `worktree_removed`, `lease_removed`, `branch_deleted` |

The fleet dashboard (`chump health`) tracks `gap_resumed` / `gap_scrapped`
counts as a leading indicator of operator-rescue burden: if recoveries
spike, the upstream wedge-cause needs a real fix, not more inspect/scrap.
