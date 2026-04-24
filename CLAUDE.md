# Claude Code — Chump-specific session rules

> **Read [`docs/RESEARCH_INTEGRITY.md`](./docs/RESEARCH_INTEGRITY.md) before touching any eval,
> cognitive-architecture code, or research claim.** It is the canonical source for the
> accurate (tier-dependent instruction-injection) thesis and the prohibited-claims table.

> **Read [`AGENTS.md`](./AGENTS.md) first.** It is the canonical, tool-agnostic
> entry point (build/test/lint commands, code style, gap-registry pattern, PR
> guidelines) and follows the cross-tool [AGENTS.md](https://aaif.io/) convention
> adopted by the Agentic AI Foundation (Linux Foundation, Dec 2025).
>
> **This file** is the Chump-specific overlay: lease coordination, the
> ambient.jsonl peripheral-vision stream, `chump-commit.sh`, the five
> pre-commit guards, session-ID resolution, and merge-queue discipline. None
> of this is portable to other repos — it's the operating procedure for
> Chump's multi-agent dispatcher.
>
> Chump-internal agents read both files at session start (AGENTS.md first,
> then CLAUDE.md as overlay).

## MANDATORY: run before anything else

Every Claude session, every time. Do not pick a gap, create a branch, or edit files until these pass.

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
grep -A3 "status: open" docs/gaps.yaml | head -40
scripts/gap-preflight.sh <GAP-ID>     # exits 1 if done, live-claimed/reserved, or ID missing from gaps.yaml — stop if so
chump --briefing <GAP-ID>             # MEM-007: per-gap context — gap acceptance + relevant reflections + recent ambient + strategic doc refs + prior PRs
```

**Lesson injection — two paths (post-MEM-006):**
- *Spawn-time, systemic.* Set `CHUMP_LESSONS_AT_SPAWN_N=5` (max 20) to have the
  prompt assembler prepend the top-N recency×frequency-ranked lessons from
  `chump_improvement_targets` at every assembly. Default OFF (preserves COG-024
  safe-by-default). Pairs with the per-model opt-in CSV
  (`CHUMP_LESSONS_OPT_IN_MODELS`) — either path can enable injection
  independently. Precedence in the assembled prompt: spawn lessons →
  user-provided base → task planner → COG-016/COG-024 lessons block →
  blackboard → perception summary.
- *Explicit per-gap, intentional.* `chump --briefing <GAP-ID>` (MEM-007) is the
  on-demand query path. Reads docs/gaps.yaml + chump_improvement_targets +
  ambient.jsonl + strategic docs + closed PRs into a single markdown briefing.
  Run after `gap-preflight.sh` and before `gap-claim.sh` so you start the gap
  knowing what the team has already learned about it.

**Task-class-aware lessons gating (EVAL-030, default ON):** the assembler
inspects the raw user prompt and (a) skips the entire lessons block on
trivial chat tokens (< 30 chars trimmed), (b) suppresses the perception
"ask one clarifying question" directive on conditional-chain prompts
("do X, if it fails do Y, then Z"). Set `CHUMP_LESSONS_TASK_AWARE=0` to
disable for harness sweeps measuring the v1 baseline.

The `ambient.jsonl` tail is your peripheral vision — recent file edits, commits, bash calls, and
ALERT events from other concurrent sessions. Event kinds to know:
- `session_start` — another agent just opened a session (note their worktree and gap)
- `file_edit` — another agent edited a file (note the path — may overlap yours)
- `commit` — a commit landed (note the sha and gap — may have advanced main)
- `bash_call` — another agent ran a command (cargo check failure? test run?)
- `ALERT kind=lease_overlap` — **stop and read**: two sessions claim the same file
- `ALERT kind=silent_agent` — a live session stopped heartbeating; its work may be lost
- `ALERT kind=edit_burst` — rapid file mutations in progress; possible rebase stomp

Then claim the gap before writing any code:
```bash
# Write gap claim to lease file — NO YAML EDIT, no git push needed:
scripts/gap-claim.sh <GAP-ID>
```

**The ID you claim MUST already exist on `origin/main` OR be reserved for your session.**
For **new** gaps, run **`scripts/gap-reserve.sh <DOMAIN> "short title"`** (JSON
leases) or **`chump gap reserve DOMAIN title…`** / `chump gap reserve --domain D
--title T` (SQLite `state.db` after `chump gap import`) before
`gap-preflight.sh` / `gap-claim.sh` — it atomically picks the next free ID (main +
open PRs touching `docs/gaps.yaml` when `gh` works + live leases) and writes
`pending_new_gap: {id, title, domain}` into your lease. Add the `- id:` row to
`docs/gaps.yaml` and ship implementation in the **same** PR. `gap-preflight.sh`
blocks other sessions on that ID until the lease expires.
**Bootstrap only:** if you cannot run `gap-reserve.sh`, use
`CHUMP_ALLOW_UNREGISTERED_GAP=1 scripts/gap-preflight.sh …` on the tiny filing PR
(INFRA-020 escape hatch). Concurrent invention caused INFRA-016/017/018.

This writes `.chump-locks/<session>.json` with `gap_id` set. Other bots running
`gap-preflight.sh` will see the claim instantly (reads local files — no network).
Claims auto-expire with the session TTL — no stale locks possible.

## Ship pipeline (always use this, not manual git push + gh pr create)

```bash
scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
```

This rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and enables auto-merge.
It also writes the gap claim at start and re-checks the gap after rebase.

**Only touch `docs/gaps.yaml` when a gap ships** (set `status: done` + `closed_date`).
Never add `in_progress`, `claimed_by`, or `claimed_at` to gaps.yaml — those fields
are gone. Claims live in lease files now.

## Hard rules

- **Never push directly to `main`.** Branch is `claude/<codename>`, worktree under `.claude/worktrees/<codename>/`.
- **Always work in a linked worktree, never in the main repo root.** `gap-claim.sh` now refuses to run from `/Users/jeffadkins/Projects/Chump` directly — use `.claude/worktrees/<name>/`. Override with `CHUMP_ALLOW_MAIN_WORKTREE=1` only for bootstrapping.
- **Never start work on a gap without running `gap-preflight.sh` first.** It takes 3 seconds and prevents hours of wasted work.
- **Never leave a lease file behind.** Delete `.chump-locks/<session_id>.json` or call `chump --release` when done.
- **Commit often.** Uncommitted edits are at risk of being overwritten by `git pull`. Stage-commit every 30 minutes of work.
- **Commit explicitly, never implicitly.** Use `scripts/chump-commit.sh <file1> [file2 ...] -m "msg"` instead of `git add && git commit`. The wrapper resets any unrelated staged files from OTHER agents before committing so their in-flight WIP doesn't leak into your commit (observed twice on 2026-04-17 — memory_db.rs stomp in cf79287, DOGFOOD_RELIABILITY_GAPS.md stomp in a5b5053).
- **If your branch is more than 15 commits behind main, rebase before continuing.**
- **`CHUMP_GAP_CHECK=0 git push`** — bypass the pre-push gap-preflight hook. Use when gap IDs in commit bodies cause false positives (e.g. a cleanup commit that mentions a gap ID it doesn't implement).
- **Auto-merge IS the default** (since INFRA-MERGE-QUEUE, 2026-04-19). `bot-merge.sh --auto-merge` arms `gh pr merge --auto --squash` at PR creation. The GitHub merge queue rebases each PR onto current `main` and re-runs CI before the atomic squash, so commits aren't lost and stale-base merges can't happen. See `docs/MERGE_QUEUE_SETUP.md`.
- **Atomic PR discipline.** Once `bot-merge.sh` runs, treat the PR as frozen — **do not push more commits to it**. If you need to add work, open a *new* PR from a fresh worktree (cheap with the musher dispatcher) and let the queue land them in order. Pushing-after-arm reintroduces the squash-loss footgun the queue exists to prevent.[^pr52]
- **bot-merge.sh recovery — manual ship path (INFRA-028).** If `scripts/bot-merge.sh` hangs, times out, or is broken while you still have a clean branch in a linked worktree, ship by hand the same way that unblocked RESEARCH-027 cycle 5: `git push -u origin <branch> --force-with-lease` (or without `-u` if upstream exists), then `gh pr create --base main --title "…" --body "…"`, then `gh pr merge <N> --auto --squash` when you want the merge queue. Re-run `scripts/gap-preflight.sh <GAP-ID>` first if you are gap-scoped. After a manual ship, update `docs/gaps.yaml` on the same branch (and run `chump gap ship <GAP-ID>` if you use the SQLite gap store) and release any `.chump-locks/<session>.json` lease for that gap so the ledger matches reality.
- **If the merge queue is stuck.** Symptoms: queue URL shows entries but head PR hasn't landed in >30 min, or `gh pr view <n> --json autoMergeRequest` shows auto-merge armed but PR state is still `OPEN` long after CI finished. Recovery (in order — try least-destructive first):
  1. **Diagnose.** `gh pr checks <n>` + open `https://github.com/repairman29/chump/queue/main` — identify the blocking PR. Common causes: CI failure on the queue's temp merge branch, required-check timeout, a rebase conflict the queue couldn't resolve, or auto-merge silently disarmed by a force-push / branch-protection change.
  2. **Re-run CI if flaky.** `gh run rerun <run-id> --failed` on the queue's temp branch run. Do NOT rerun on the PR branch itself — the queue grades its own temp branch, not yours.
  3. **Dequeue the blocker.** `gh pr merge <blocker-pr> --disable-auto`. This removes it from the queue without closing it; the PRs behind it start progressing. The blocker then either (a) gets a fix in a *new* PR (atomic discipline still applies — don't push to the blocker) or (b) is closed if superseded.
  4. **Recover lost commits via checkpoint tag.** `bot-merge.sh` pushes a `pr-<N>-checkpoint` tag at arm time. If a PR's branch got clobbered (force-push, squash-loss race), run `git fetch origin --tags && git checkout pr-<N>-checkpoint` in a fresh worktree — every commit that was on the branch at arm time is recoverable from that tag. See PR #52 / PR #65 history for the original incident.
  5. **Nuclear option — drain the queue.** If multiple PRs are tangled and (1–4) won't untangle them, disable auto-merge on *all* queued PRs (`for n in $(gh pr list --search 'is:open' --json number -q '.[].number'); do gh pr merge $n --disable-auto 2>/dev/null; done`), let main settle, then re-arm the PRs one at a time with `gh pr merge <n> --auto --squash` in priority order. Announce in ambient.jsonl before doing this — siblings will see their PRs dequeue and may otherwise assume a failure.
  6. **When in doubt, ask the human.** The queue has admin-only failure modes (branch-protection rule changes, required-check renames, queue disabled in settings) that agents can't fix. If steps 1–5 don't move the queue, flag the state in ambient.jsonl with `ALERT kind=queue_stuck` and stop — don't start churning new PRs against a broken queue.
- **Keep PRs intent-atomic (not file-count-bounded).** A PR is one logical change — a feature, a bug fix, a codemod, a config update. Mechanical multi-file refactors (renames, dead-code removal, dep swaps) ship as a *single* PR no matter the file count, because (a) atomic = no broken intermediate `main` state, (b) CI verifies the whole change end-to-end, and (c) one revert beats coordinating three. Stack only when the changes are *logically* distinct (e.g. "land the new API, then migrate callers, then delete the old API"). Old "≤ 5 files" guidance was for human reviewers; with merge-queue + required-CI, codemod-style PRs are the world-class default. If a human review is genuinely needed, label the PR `human-review-wanted` and split for them.

[^pr52]: Historical context — PR #52 (2026-04-18) lost 11 commits when an agent kept pushing after auto-merge was armed; GitHub captured the branch at first-CI-green and dropped everything pushed after. Recovery PR #65 was hand-cherry-picked. The merge queue (INFRA-MERGE-QUEUE) closes the race only if you stop pushing once the PR is in the queue.

## Worktree disk hygiene

Linked worktrees under `.claude/worktrees/` are the main **disk** risk on agent-heavy machines: each keeps its own `target/` (often multi‑GB after `cargo clippy` / `cargo test`). After a successful ship, `bot-merge.sh` **purges `./target`** in that worktree when it writes `.bot-merge-shipped` (skip with **`CHUMP_KEEP_TARGET=1`** if you still need the cache there).

**Stale trees (merged PR or deleted remote branch):** prefer automation over hand-tuning `git worktree list`.

1. **`scripts/stale-worktree-reaper.sh`** — default is **dry-run** (safe to run anytime). With **`--execute`**, it archives selected eval logs then `git worktree remove --force` under `.claude/worktrees/` only when the script’s guards pass (cooldown, no conflicting lease, process / log freshness — see the script header).
2. **macOS — expected setup for dogfooding:** run **`scripts/install-stale-worktree-reaper-launchd.sh`** once per machine so the reaper runs **hourly**. **Verify:** `launchctl list | grep ai.openclaw.chump-stale-worktree-reaper`. **Logs:** `/tmp/chump-stale-worktree-reaper.out.log` and `/tmp/chump-stale-worktree-reaper.err.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-stale-worktree-reaper.plist`.
3. **Opt out** for one worktree the reaper should never remove: **`touch <worktree-path>/.chump-no-reap`**.

Manual escape hatch from the **main** checkout: `git worktree remove .claude/worktrees/<name>` when you are sure nothing has that directory as its cwd.

## Session ID resolution (how leases are scoped)

`gap-claim.sh` picks a session ID in this priority order — first non-empty wins:

1. `$CHUMP_SESSION_ID` — explicit override (set by `bot-merge.sh` or manually)
2. `$CLAUDE_SESSION_ID` — injected by Claude Code SDK; unique per agent session (**best**)
3. `.chump-locks/.wt-session-id` — worktree-scoped ID generated once per linked worktree (stable across re-runs within the same worktree session)
4. `$HOME/.chump/session_id` — machine-scoped legacy fallback (shared across all sessions — avoid)

The worktree-scoped ID (3) is automatically generated and cached the first time `gap-claim.sh` runs in a new worktree. It is scoped to `.claude/worktrees/<name>/` so concurrent sessions in different worktrees never collide.

## Pre-commit guards (coordination audit, 2026-04-17)

After install (`./scripts/install-hooks.sh`), every `git commit` runs five checks. Most are silent no-ops; each one fails loud with a bypass hint.

| Check | What it blocks | Bypass env | Why |
|---|---|---|---|
| lease-collision | file claimed by a different live session | `CHUMP_LEASE_CHECK=0` | silent stomps |
| stomp-warning | staged file mtime > 10 min (non-blocking) | `CHUMP_STOMP_WARN=0` | cross-agent staging drift |
| gaps.yaml discipline | adds `status: in_progress` / `claimed_by:` / `claimed_at:` to the YAML | `CHUMP_GAPS_LOCK=0` | claim fields live in `.chump-locks/`, not the ledger |
| **gap-ID hijack** (NEW 2026-04-18) | gaps.yaml diff *changes* an existing gap's `title:` or `description:` (silent ID reuse) | `CHUMP_GAPS_LOCK=0` | caught PR #60 ↔ #65 EVAL-011 collision; new work needs a new ID, not redefinition |
| **duplicate-ID insert** (INFRA-GAPS-DEDUP, 2026-04-19; test in INFRA-015, 2026-04-20) | gaps.yaml commit leaves the file with two entries sharing the same `id:` | `CHUMP_GAPS_LOCK=0` | closes the hole that let the 7 collision pairs (COG-007/008/009/010/011, MEM-003, EVAL-003) in per Red Letter #2; test: `scripts/test-duplicate-id-guard.sh` |
| cargo-fmt auto-fix | unformatted `.rs` (auto-fixes + re-stages) | — | CI `cargo fmt --check` thrash |
| cargo-check build guard | staged `.rs` fails `cargo check --bin chump --tests` | `CHUMP_CHECK_BUILD=0` | broken-compile commits triggering `fix(ci):` follow-ups |
| **wrong-worktree commit** (NEW 2026-04-18, in `chump-commit.sh`) | named files have no changes in current worktree but DO have changes in a sibling worktree | `CHUMP_WRONG_WORKTREE_CHECK=0` | catches the "python script wrote to main repo while user thought they were in a worktree" failure mode that wasted ~30 min on 2026-04-18 |
| **preregistration required** (RESEARCH-019) | closing an EVAL-\* or RESEARCH-\* gap to `status: done` without a `docs/eval/preregistered/<GAP-ID>.md` committed | `CHUMP_PREREG_CHECK=0` with justification | hypothesis must be locked before data collection — retrospective or doc-only gaps use the bypass |

`git commit --no-verify` bypasses ALL five. Use very sparingly — `--no-verify` is the reason task #58 (Metal crash) and half the duplicate-work incidents shipped.

## Dispatched-subagent backend (COG-025, 2026-04-19)

If you wake up inside a `chump-orchestrator`-dispatched worktree, you may be
running on either backend depending on what the operator set
`CHUMP_DISPATCH_BACKEND` to:

- **`claude` (default).** You are running as `claude -p <prompt> --dangerously-skip-permissions` — the original AUTO-013 baseline. Anthropic-only.
- **`chump-local`.** You are running inside Chump's own multi-turn agent loop (`chump --execute-gap <GAP-ID>`) driven by whatever provider `$OPENAI_API_BASE` + `$OPENAI_MODEL` resolve to (Together free tier, mistral.rs, Ollama, hosted OpenAI). Cost-routing path.

The contract is identical either way: read `CLAUDE.md` mandatory pre-flight,
do the gap, ship via `scripts/bot-merge.sh --gap <id> --auto-merge`, reply
ONLY with the PR number. The orchestrator records which backend ran on the
reflection row (`notes` field, prefix `backend=<label>`) so PRODUCT-006 and
the COG-026 A/B aggregator can split outcomes by backend.

## Coordination docs

- `docs/gaps.yaml` — master gap registry (claims NOT stored here — only open/done status)
- `docs/AGENT_COORDINATION.md` — full coordination system (leases, branches, failure modes, five-job pre-commit spec)
- `scripts/gap-preflight.sh` — gap availability check (reads lease files + checks done on main)
- `scripts/gap-claim.sh` — write a gap claim to your session's lease file
- `scripts/bot-merge.sh` — ship pipeline (calls gap-claim.sh automatically)
- `scripts/stale-pr-reaper.sh` — runs hourly, auto-closes PRs whose gaps landed on main
- `scripts/stale-worktree-reaper.sh` — removes merged / orphaned linked worktrees under `.claude/worktrees/` (default dry-run; use `--execute`). macOS hourly install: `scripts/install-stale-worktree-reaper-launchd.sh` (see **Worktree disk hygiene** above)
- `scripts/git-hooks/pre-commit` — five-job coordination hook (see table above)
- `scripts/git-hooks/pre-push` — gap-preflight gate (blocks pushes with `done`/stolen-claim gap IDs)
- `scripts/git-hooks/post-checkout` — auto-installs hooks into every worktree after `git worktree add`

## Rust-native gap store (INFRA-023, shipped 2026-04-21)

The chump binary now embeds a SQLite gap store at `.chump/state.db`. These commands are available
alongside the legacy shell scripts (both paths work; YAML/JSON remain authoritative for one release):

```bash
chump gap import                          # seed DB from docs/gaps.yaml (idempotent)
chump gap list [--status open] [--json]   # list gaps; --json output is musher-compatible
chump gap reserve --domain INFRA --title "..." [--priority P1] [--effort s]
chump gap claim <GAP-ID> [--session ID] [--worktree PATH]
chump gap preflight <GAP-ID>             # exit 0=available, 1=done/claimed
chump gap ship <GAP-ID> [--session ID]
chump gap dump [--out docs/gaps.yaml]    # export to YAML for git-diff review
```

**Git-diff story.** `.chump/state.db` is binary. Commit `chump gap dump > .chump/state.sql`
alongside any DB mutations so humans reviewing PRs see a readable diff. After a merge conflict
in `.chump/state.sql`, regenerate it with `chump gap dump --out .chump/state.sql`.
