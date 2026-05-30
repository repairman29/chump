---
doc_tag: process-doctrine
audience: shepherd, quartermaster, ci-audit, orchestrator, any agent running /loop
purpose: Codifies when an unwedging move is reversible and well-bounded enough to execute WITHOUT operator approval. The "don't ask, ship" rule for reflexes.
status: v1 (2026-05-30) — operator-ratified
origin: META-225 — operator verbatim: "automate this for FFS.. these are petty bullshit problems that we should not have to deal with"
---

# Shepherd Autonomy Ladder

## Background

On 2026-05-30 the operator had to manually approve three unwedging moves that
should have been automatic:

1. **Daemon not loaded.** INFRA-2295 (stale-pr-rebase-bot) shipped to main
   hours earlier but `launchctl bootstrap` was never run. 8 DIRTY PRs sat
   unrescued because no daemon was running the installer.
2. **Ghost PR open.** Gap INFRA-2067 was `status:done` but PR #2837 was still
   open in a CONFLICTING state. Pure noise on every queue scan.
3. **Main worktree drift.** ~150 untracked yaml + stale state.db blocked the
   shepherd from cleanly pulling main to run the installer. Required surgical
   `git show origin/main:<path>` extraction.

Each of these is a **reflexive, reversible, well-bounded action** — the kind
that a human would do without a second thought. The operator should never
be the one pulling the trigger.

## The decision table

| Move | Reversible? | Bounded? | Operator impact if wrong? | Approved without asking? |
|---|---|---|---|---|
| Run a newly-shipped `install-*.sh` | Yes — unload/reload | Yes — touches only one plist | Daemon briefly restarts | **YES** |
| Close a PR whose gap is `status:done` | Partially — can reopen | Yes — only DIRTY/CONFLICTING PRs | PR closed, easy to reopen | **YES** |
| Emit ambient drift alert | Yes — stateless emit | Yes — debounced 6h | None | **YES** |
| Reserve a worktree-cleanup gap | Yes — can close | Yes — P1/s, no code change | One extra gap in registry | **YES** |
| Merge a PR to main | No | No — affects main | Potentially breaks trunk | **NO — ask** |
| Force-reset main worktree | No | No — loses uncommitted work | Data loss | **NO — ask** |
| Rotate GitHub secrets | Partially | No — fleet-wide impact | Auth outage | **NO — ask** |
| Scale the fleet up | Yes (scale down) | No — resource cost | Cost + chaos | **NO — ask** |
| Close a PR whose gap is `status:open` | Yes — reopen | No — destroys active work | Lost PR | **NO — ask** |
| Delete a branch | No | No — history loss risk | Data loss | **NO — ask** |

**General rule:** auto-execute when ALL of these hold:
- The action is **reversible within minutes** by a single command
- The action has **bounded blast radius** (affects one PR, one plist, one file)
- The action is **well-defined by existing signals** (gap status, launchctl list, git counts)
- The action has **no destructive side-effects** on the main branch or canonical state

If any condition is false, pause and emit an ambient alert instead.

## The 3 approved-without-asking patterns (META-225)

These are the first three patterns ratified as auto-execute. Each has a daemon
shipped in this PR.

### Pattern 1: Daemon auto-activation (`daemon-activator-loop.sh`)

**Trigger:** A `scripts/setup/install-*.sh` or `scripts/launchd/*.plist` appears
in the last 24h of `origin/main` commits, and the corresponding launchd label is
not in `launchctl list`.

**Action:** Extract the installer via `git show origin/main:<path>` (robust to
dirty local worktree), run it, emit `kind=daemon_auto_activated`.

**Why it's safe:** The installer is idempotent — it unloads then reloads. At
worst, the daemon briefly restarts. The plist was already reviewed in the PR
that shipped it.

**Failure mode:** If the installer exits non-zero, emit `kind=daemon_activator_failed`
and leave it for the next tick. Never retry-loop; never page the operator on first
failure.

### Pattern 2: Ghost PR closure (`ghost-pr-closer.sh`)

**Trigger:** An open PR whose title contains a gap ID where `chump gap show`
returns `status:done`, AND the PR's `mergeStateStatus` is `DIRTY` or `CONFLICTING`.

**Action:** `gh pr close <N> --comment "Ghost — gap <ID> already status=done; closing per META-225 auto-fixer at <ts>"`. Emit `kind=ghost_pr_closed`. Self-throttle: max 5 closes per run; overflow to `.chump/ghost-pr-deferred.jsonl`.

**Why it's safe:** The gap is done — the work already shipped on main via a
different PR. The ghost branch is stale by definition. Closing it removes noise;
reopening is a single `gh pr reopen` command.

**Boundary condition:** Do NOT close if `mergeStateStatus` is anything other than
DIRTY or CONFLICTING. A gap that is `status:done` but has a clean PR might be a
data anomaly — leave it for operator review.

### Pattern 3: Main worktree drift alert (`main-worktree-drift-detector.sh`)

**Trigger:** Main worktree has >50 untracked yaml files under `docs/gaps/` OR
is >20 commits behind `origin/main`.

**Action:** Emit `kind=main_worktree_drift_detected` with `untracked_yaml`,
`commits_behind`, `suggested_action`. Reserve a P1/s META gap titled
`"main worktree cleanup — N untracked yaml + M commits behind"` with concrete AC.
Write debounce state to `.chump/main-worktree-drift-last.json` (6h cooldown).

**Why it's safe:** The daemon only reads (git ls-files, git rev-list) and emits.
The gap reserve is a non-destructive filing. No worktree modification, no git
commands with side-effects.

**The daemon does NOT auto-fix the drift** — it alerts and files a gap. A
future iteration could add `git stash + pull` for the sub-50 clean case, but
that requires human-readable state verification first.

## Anti-patterns (when to STILL ask)

These situations look like they match the approved patterns but have
disqualifying properties. Always escalate to operator instead.

| Situation | Why to ask |
|---|---|
| Gap is `status:done` but `closed_pr` field is empty | Possible data anomaly — gap may not actually have shipped; needs human verification |
| PR has active reviews or discussion | Closing a PR mid-discussion burns goodwill and context |
| Install script has not been code-reviewed (no PR merge in git log) | The plist content is unreviewed; don't blindly execute arbitrary installers |
| Drift count jumped by 100+ in a single tick | May indicate a runaway import loop, not normal accumulation; alert but don't auto-reserve |
| Multiple consecutive `daemon_activator_failed` events for same label | The installer is broken, not just a one-off; filing a gap is the right response, not retrying |
| Fleet is in RED state (`fleet_wedge` event in last 30m) | Any autonomous action during a wedge can compound chaos; freeze and wait |

## Extending the ladder

To add a new approved-without-asking pattern:

1. Verify the move passes the 4-condition test (reversible, bounded, well-defined,
   non-destructive).
2. Implement as a daemon in `scripts/coord/` with `scanner-anchor` comments.
3. Add an installer + plist + bootstrap-manifest entry.
4. Write a smoke test in `scripts/ci/test-*.sh`.
5. Add the pattern to this doc's "approved" section.
6. The first N=5 approved patterns form the "reflexes" tier. Beyond that, re-evaluate
   whether the whole class should be promoted to an operator-configurable policy
   (e.g. `CHUMP_AUTO_CLOSE_GHOSTS=1`) rather than hardcoded.

## Cross-references

- `docs/process/SHIP_ASSIST_PLAYBOOK.md` — Class 9: Quartermaster auto-fixers
- `.claude/agents/quartermaster.md` — Auto-fixers section
- `scripts/coord/daemon-activator-loop.sh` — Pattern 1 implementation
- `scripts/coord/ghost-pr-closer.sh` — Pattern 2 implementation
- `scripts/coord/main-worktree-drift-detector.sh` — Pattern 3 implementation
- `docs/process/REAPER_DOCTRINE.md` — complementary doctrine for PR reaping decisions
