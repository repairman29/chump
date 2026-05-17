# Subagent dispatch — shipping epilogue + briefing protocol

> **Filed in:** [META-025](../gaps/META-025.yaml) — measured 25-33% subagent
> self-ship rate this session against ~80% work-quality. Two bottlenecks:
> (1) ship-stage hand-off (fixed by the shipping epilogue below), and
> (2) clarifying-question hesitation (fixed by the no-clarifying-questions
> directive below). **Every subagent prompt must include both.**

## The no-clarifying-questions directive (paste into every subagent prompt)

Add this as the **first section** of every subagent prompt, before the task
description:

```
## Execution contract (read before anything else)

- **No clarifying questions.** You have everything you need. If something is
  ambiguous, make the most reasonable call, note it in your final report, and
  keep moving. Do not stop to ask.
- **Auto-decide on ambiguous AC.** If an acceptance criterion is vague, apply
  the most conservative interpretation that still satisfies the letter of the
  criterion. Document your interpretation in one line; do not pause.
- **Scope is fixed.** Do not expand beyond the deliverables listed. Do not
  do adjacent cleanup, refactors, or "while I'm here" changes.
- **Ship or report BLOCKED.** Every session ends with either a PR number or
  a one-line BLOCKED reason. "I wasn't sure" is not a valid BLOCKED reason —
  make the call and ship.
```

This single addition is responsible for the majority of the expected ship-rate
improvement. The hesitation / clarifying-question mode is the most common
subagent failure pattern after ship-stage wedges.

---

## The 25%→80% problem

Across this session's 4 dispatched subagents, 1 self-shipped a PR and 3 wrote
complete work that stalled at `bot-merge.sh`. Across the historical
`chump_improvement_targets` dispatch telemetry, 33% shipped / 33% killed /
33% stalled. The work-quality of agents that produce IS high — 425-line
position docs, 460-line preregs, multi-file fixtures with schema validators.
The failure is at the ship-stage hand-off where `chump gap …` commands hang
or `bot-merge.sh` waits forever.

The single subagent that did self-ship (EVAL-094 → PR #909) was the one
whose briefing included explicit fall-back-to-manual-recovery instructions.
That's the canary. **Every subagent prompt should include the shipping
epilogue below.**

## The shipping epilogue (paste into every subagent prompt)

```
## Shipping (CRITICAL — read in full before ending)

```bash
# Canonical path:
scripts/coord/bot-merge.sh --gap <YOUR-GAP-ID> --auto-merge
```

**If `chump gap …` or `bot-merge.sh` hangs > 30s** (no output, no progress):

```bash
# Heal the wedged binary (INFRA-275). Idempotent; safe to run.
scripts/dev/chump-binary-unwedge.sh
```

> **STOP: wall-clock budget is `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S` (default 900s = 15 min).**
> If `bot-merge.sh` has been running for 15 minutes with no progress markers
> (`▶ <stage> starting …` / `✓ <stage> done`), **do not wait** — execute
> manual recovery NOW. Passive waiting is what stalls subagents; the doctor
> + manual path are always faster than an indefinite hang.

**If still hung after the doctor, OR if the 15-min wall-clock budget expires** —
fall back to manual recovery (INFRA-028 path):

```bash
# 0. Verify you are on the right branch (INFRA-1598 guard)
chump verify-claim-branch || exit 1

# 1. Push your branch
CHUMP_GAP_CHECK=0 git push -u origin <your-branch> --force-with-lease

# 2. Open the PR by hand
gh pr create --base main --title "<title>" --body "<body>"

# 3. Arm auto-merge
gh pr merge <PR-number> --auto --squash

# 4. Close the gap in the canonical store (if your PR closes it)
chump gap ship <GAP-ID> --closed-pr <PR-number> --update-yaml
```

**If `chump gap` itself hangs** during step 4: the doctor again, or skip
step 4 — the closer-pr-batcher will catch up on the next cron run
(INFRA-219 / INFRA-307).

**Do NOT** silently fall back to writing `docs/gaps/<ID>.yaml` directly —
concurrent siblings each scanning the filesystem for "next free ID"
produce silent collisions (INFRA-301).

**Do NOT** use `git commit --no-verify` to bypass guards. Per-guard bypass
envs (`CHUMP_GAP_CHECK=0`, `CHUMP_CHECK_BUILD=0`, `CHUMP_RAW_YAML_EDIT=1` +
`RAW_YAML_REASON: <text>` trailer) are documented in CLAUDE.md and safe
when applicable.

**Final report format** — reply with this structure under 250 words:
```
PR number: #NNNN  (or "BLOCKED" + one-line reason)
Files changed: <count>
Tests added: <count or "none">
CI state at hand-off: <green / pending / failed-with-fix-noted>
Open TBDs: <bullet list, or "none">
Notes: <2-3 sentences on tricky calls or recovery paths used>
```
```

## What goes in the briefing BEFORE the epilogue

The shipping epilogue is the LAST section of the prompt. Structure in order:

1. **No-clarifying-questions directive** (above) — verbatim, first thing.
2. **What you're building** — one paragraph, the deliverable named.
3. **Read first (in order)** — explicit file paths the agent should load
   before writing. Don't paste content; tell them what to read.
4. **The contract** — what the deliverable MUST contain (acceptance
   criteria from the gap, schema fields, success criteria).
5. **What you must NOT do** — concrete forbiddances (don't expand scope,
   don't bypass guards, don't hand-edit per-file YAMLs).
6. **The shipping epilogue** (above) — verbatim, no edits.

## Model default — always use sonnet (INFRA-515)

Fleet workers default to `FLEET_MODEL=sonnet` since 2026-05-06 (INFRA-515).
**Do not dispatch subagents on haiku.** Haiku asks clarifying questions instead
of acting, and in `--dangerously-skip-permissions` mode there is nobody to
answer — the agent sits idle for 600 s and is killed. Sonnet ships on the
first attempt; haiku ships 1-in-9. The cost differential is real but the
throughput differential is larger.

When calling the `Agent` tool manually, omit `model:` (inherits the session
default, which is sonnet for fleet sessions) or explicitly pass `"model": "sonnet"`.

## Write-ahead log — protect edits from /tmp reap (INFRA-1200)

Worktrees live in `/tmp`, which macOS can reap without warning. Before writing
any file, subagents **should** wrap the write through `chump-edit-wrap.sh` so
the new content is persisted to the stable main-repo tree first. If the
worktree is reaped, `chump-edit-replay.sh` re-applies all patches to a fresh
worktree in seconds.

```bash
# Before: write directly (unsafe — /tmp reap loses work)
cat new-content.txt > /private/tmp/chump-INFRA-NNN/src/foo.rs

# After: wrap through the WAL (safe)
cat new-content.txt | \
  CHUMP_WORKTREE_ROOT=/private/tmp/chump-INFRA-NNN \
  scripts/coord/chump-edit-wrap.sh INFRA-NNN \
  /private/tmp/chump-INFRA-NNN/src/foo.rs
```

Recovery after `/tmp` reap:

```bash
# Fresh worktree already created (e.g. via chump claim --resume)
scripts/coord/chump-edit-replay.sh INFRA-NNN /private/tmp/chump-INFRA-NNN
```

Patches are stored in `.chump-plans/<GAP-ID>/` in the main repo. They are
cleaned up automatically 7 days after the gap ships.

## Timeout rescue path — find WIP on the branch (INFRA-525)

`worker.sh` now installs a `SIGALRM` trap at `FLEET_TIMEOUT_S − 30 s`. If an
agent is killed by the fleet timeout, it first runs:

```bash
git add -A && git commit -m "WIP-<gap>: timeout-rescue" && git push -u origin <branch>
```

The work is on the remote branch even if the agent never reached `bot-merge.sh`.
Recovery:

```bash
git fetch origin
git checkout <branch>         # branch name is in the gap's lease JSON
# inspect, finish, and ship normally
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

If the branch is missing entirely, the agent was killed before the trap fired
(rare — only possible if `SIGKILL` was used instead of `SIGTERM/SIGALRM`).
In that case, the work is lost; re-claim and re-implement.

## Anti-patterns observed

These are real failure modes from this session, not theoretical:

- **Subagent asks clarifying questions instead of shipping.** The prompt
  ends there — the operator never sees the work. Fixed by the
  no-clarifying-questions directive at the top of every prompt. Root cause:
  default model behavior optimizes for safety-via-confirmation; fleet
  subagents must be pre-authorized to make judgment calls.
- **Subagent pauses on ambiguous AC instead of making a call.** Often
  accompanied by "I need more context" or "could you clarify". The
  auto-decide rule (most conservative interpretation + document it) closes
  this. If the call turns out wrong, the gap is re-opened — cheaper than
  a stalled agent.
- **Subagent writes prereg, commits locally, never pushes.** Fixed by the
  epilogue's manual-recovery section.
- **Operator uses `Agent` tool to "check status" of an existing subagent
  instead of `SendMessage`.** Spawns a fresh agent with no context;
  wastes a slot. (See [DOC-015](../gaps/DOC-015.yaml).)
- **Multiple subagents claim same gap because lease lookups failed.**
  Mitigated by `gap-claim.sh` running before any work; subagents must
  preflight.
- **Subagent silently falls back to direct YAML write when `chump gap
  reserve` hangs.** Caught by [INFRA-301](../gaps/INFRA-301.yaml)'s
  trace-log instrumentation; remediated by the chump-doctor heal path
  in [INFRA-275](../gaps/INFRA-275.yaml).

## Re-measurement contract

[META-025](../gaps/META-025.yaml) commits to remeasuring after this
template lands: N=5 fresh subagent dispatches, self-ship rate target
≥ 70% (vs 25% baseline). Two changes are being tracked together:
(1) shipping epilogue (already in use since META-025), and
(2) no-clarifying-questions directive (added in COG-053).
If the rate still doesn't improve, the bottleneck has shifted — file a new
gap with the observed failure taxonomy rather than patching this doc further.

## Model defaults (post INFRA-515)

Fleet workers default to **`sonnet`** (`FLEET_MODEL=sonnet`). This replaced
the earlier `haiku` default — haiku's tendency to ask clarifying questions
instead of making judgment calls was the dominant source of dispatch waste.

| Context | Default model | Override |
|---|---|---|
| Fleet workers (`run-fleet.sh`) | `sonnet` | `FLEET_MODEL=haiku` to cut cost |
| IDE / interactive sessions | `haiku` | — |
| Curator / PM runs | `opus` | `CHUMP_CURATOR_MODEL=sonnet` |

Cost-sensitive sweeps: `FLEET_MODEL=haiku scripts/dispatch/run-fleet.sh`.
Opus is ~50× haiku per token — reserve for structured PM reasoning (gap
prioritization, pillar rebalancing) where reasoning quality matters.

## Timeout-checkpoint and WIP-rescue (post INFRA-525)

When `claude -p` approaches `FLEET_TIMEOUT_S`, worker.sh commits any
in-progress edits and pushes the branch before killing the process:

```
WIP-<GAP-ID>: timeout-rescue checkpoint (INFRA-525)
```

The worker emits `kind=fleet_timeout_checkpoint` (ALERT level) to
`ambient.jsonl`. Watch for it with:

```bash
tail -f .chump-locks/ambient.jsonl | grep fleet_timeout_checkpoint
```

**Operator recovery from a WIP checkpoint:**

```bash
# 1. Find the WIP branch (check ambient.jsonl or gh pr list)
git fetch origin
git checkout chump/<gap-id>-claim

# 2. Review partial work, continue the implementation

# 3. Ship normally once complete
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

If no PR exists yet for the branch:
```bash
gh pr create --head chump/<gap-id>-claim --base main --title "<title>"
gh pr merge <N> --auto --squash
```

Opt-out of WIP checkpoints: `CHUMP_WIP_CHECKPOINT=0` — work is lost on
timeout if set (useful for short-lived test workers only).

## See also

- [META-025](../gaps/META-025.yaml) — parent gap, dispatch-quality findings
- [INFRA-275](../gaps/INFRA-275.yaml) — the syspolicyd binary wedge that
  causes most ship-stage hangs
- [INFRA-301](../gaps/INFRA-301.yaml) — gap-reserve.sh tripwire
- [DOC-015](../gaps/DOC-015.yaml) — Agent vs SendMessage discipline
- [INFRA-333..337](../gaps/) — sibling improvements (pre-flight,
  heartbeat, telemetry report, stall taxonomy, scope enforcement)
- [COG-053](../gaps/COG-053.yaml) — no-clarifying-questions directive +
  auto-decide rule (the parallel fix to INFRA-515's sonnet default)
- [INFRA-515](../gaps/INFRA-515.yaml) — fleet-model default flipped from
  haiku to sonnet; haiku's clarifying-question hesitation kills throughput
- [INFRA-525](../gaps/INFRA-525.yaml) — worker.sh WIP-rescue checkpoint:
  work is committed + pushed at T-30s before fleet timeout
- [CLAUDE.md](../../CLAUDE.md) "Spawning subagents" subsection (added
  with this PR)
