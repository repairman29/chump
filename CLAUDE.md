# Claude Code — Chump-specific session rules

> **Read [`docs/process/RESEARCH_INTEGRITY.md`](./docs/process/RESEARCH_INTEGRITY.md) before touching any eval,
> cognitive-architecture code, or research claim.** It supersedes earlier framing in
> CHUMP_PROJECT_BRIEF.md and CHUMP_RESEARCH_BRIEF.md. The accurate thesis is narrower than
> what those docs say.

> **Read [`AGENTS.md`](./AGENTS.md) first.** It is the canonical, tool-agnostic
> entry point (build/test/lint commands, code style, gap-registry pattern, PR
> guidelines) and follows the cross-tool [AGENTS.md](https://aaif.io/) convention
> adopted by the Agentic AI Foundation (Linux Foundation, Dec 2025).
>
> **This file** is the Chump-specific overlay: lease coordination, the
> ambient.jsonl peripheral-vision stream, `chump-commit.sh`, the
> commit-time guards, session-ID resolution, and merge-queue discipline. None
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
bash scripts/setup/install-ambient-hooks.sh 2>&1 | tail -2  # FLEET-023: idempotent — wires SessionStart/PreToolUse/PostToolUse/Stop hooks into ~/.claude/settings.json so this session emits to ambient.jsonl. Bypass with CHUMP_AMBIENT_INSTALL_SKIP=1 in env.
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
chump-coord watch &  # FLEET-006: cross-machine peripheral vision (NATS); local file tail above is the durable fallback. Skip if NATS unavailable.
chump gap list --status open                     # canonical (.chump/state.db); per-file mirror fallback: grep -lE 'status:[[:space:]]*open' docs/gaps/*.yaml
python3 scripts/coord/gap-doctor.py doctor       # INFRA-155 (live 2026-04-28): detect YAML↔SQLite drift, ghost gaps, orphan rows BEFORE you reserve. Bucket 3 > 0 means a future `chump gap reserve` may collide silently.
scripts/coord/gap-preflight.sh <GAP-ID>     # exits 1 if done, live-claimed/reserved, or ID missing from registry — stop if so
chump --briefing <GAP-ID>             # MEM-007: per-gap context — gap acceptance + relevant reflections + recent ambient + strategic doc refs + prior PRs
```

**Stale-binary alarm (INFRA-148, ongoing risk).** `chump --version` is wired
to a model probe today (don't rely on it). To check binary freshness run
`ls -la $(which chump)` and compare to `git log origin/main --since=...
src/gap_store.rs src/main.rs --oneline | head` — if main has commits to
either path *after* your binary's mtime, **rebuild before any
`chump gap …` operation**:

```bash
cargo build --release --bin chump && cp target/release/chump ~/.local/bin/chump
```

Stale binary symptoms hit at least 4× this cycle — `chump gap import`
rejecting valid YAML, `--closed-pr` flag missing, dump dropping rows,
silent ID collisions. **Rebuild is cheaper than the friction it prevents.**

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
  on-demand query path. Reads `.chump/state.db` (mirrored in `docs/gaps/<ID>.yaml`) + chump_improvement_targets +
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
ALERT events from other concurrent sessions.

**Scope reminder (FLEET-023, 2026-05-02).** `ambient.jsonl` is **filesystem-local** to whatever machine / sandbox you're on. Cross-machine peripheral vision goes through NATS (FLEET-006: `chump-coord watch`, subjects `chump.events.>`). In a fresh remote sandbox (Cold Water, ephemeral CI runner, etc.) where no NATS broker is reachable, the file tail will only show *this* session's own events — typically just two `session_start` lines from this session itself. That's expected, not a bug. If you need cross-machine signal, ensure `CHUMP_NATS_URL` is set to a reachable broker before flagging "ambient empty" as a finding.

Event kinds to know:
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
scripts/coord/gap-claim.sh <GAP-ID>
```

**The ID you claim MUST already exist on `origin/main` OR be reserved for your session.**
For **new** gaps, prefer **`chump gap reserve --domain INFRA --title "short title"`**
(canonical SQLite path post-INFRA-059). The legacy
`scripts/coord/gap-reserve.sh <DOMAIN> "short title"` shell path still works as a
fallback. Both paths atomically pick the next free ID (main registry + open PRs +
live leases) and write `pending_new_gap: {id, title, domain}` into your lease.
Run `chump gap ship <ID> --update-yaml` so the human-readable mirror at
`docs/gaps/<ID>.yaml` reflects the new gap, and ship implementation in the
**same** PR. `gap-preflight.sh` blocks other sessions on that ID until the
lease expires.
**Bootstrap only:** if you cannot run `gap-reserve.sh`, use
`CHUMP_ALLOW_UNREGISTERED_GAP=1 scripts/coord/gap-preflight.sh …` on the tiny filing PR
(INFRA-020 escape hatch). Concurrent invention caused INFRA-016/017/018.

This writes `.chump-locks/<session>.json` with `gap_id` set. Other bots running
`gap-preflight.sh` will see the claim instantly (reads local files — no network).
Claims auto-expire with the session TTL — no stale locks possible.

## Ship pipeline (always use this, not manual git push + gh pr create)

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

This rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and enables auto-merge.
It also writes the gap claim at start and re-checks the gap after rebase.

**Gap status changes go through `chump gap ship --update-yaml`** (canonical
since INFRA-059). It flips `status: done` + stamps `closed_date` in
`.chump/state.db` AND regenerates `docs/gaps/<ID>.yaml` so the human-readable
diff lands in the same PR. Never hand-edit any `docs/gaps/<ID>.yaml` to add
`in_progress`, `claimed_by`, or `claimed_at` — those fields are gone. Claims
live in lease files; status lives in the SQLite store.

**`--gap` is effectively required (INFRA-237, 2026-05-02).** `bot-merge.sh`
refuses to ship without a gap ID — either passed explicitly (`--gap INFRA-NNN`),
auto-derived from a canonical branch name (`chump/infra-NNN-...`,
`claude/research-NNN-...`, `chore/file-infra-NNN`), or explicitly suppressed
with `--gap none` for genuine non-gap PRs (dependabot bumps, doc-only sweeps).
Without one of these, the script exits 2 with a banner naming all three
remediation paths. This closes the path that left `status:open` ghosts after
their implementing PR landed (INFRA-241 backfill class) by guaranteeing the
INFRA-154 auto-close step always has a gap ID to flip. Tests:
`scripts/ci/test-bot-merge-gap-auto-derive.sh` (auto-derive happy paths) and
`scripts/ci/test-bot-merge-requires-gap.sh` (the contract: missing-gap exits
non-zero with an actionable error).

**Auto-close on ship (INFRA-154, 2026-04-28).** `bot-merge.sh` now runs
`chump gap ship <ID> --closed-pr <PR#> --update-yaml` between `gh pr create`
and arming auto-merge, then commits + pushes the resulting
`docs/gaps/<ID>.yaml` + `.chump/state.sql` diff onto the same branch. The merge queue squashes the
close commit together with the implementation commit, so origin/main sees
**one atomic closure** with `status=done` + `closed_pr=<this-PR>` — no more
"flip status to done after PR #N landed" follow-up commits (5+ such
bot-effort PRs the week of 2026-04-22..28). Disable with
`CHUMP_AUTO_CLOSE_GAP=0` for partial-progress / split PRs that should not
fully close their gap. Skipped automatically when the gap is already done,
when no `--gap` was given, or when the chump binary doesn't support
`--closed-pr` (pre-INFRA-156 binaries).

## Hard rules

- **Never push directly to `main`.** Branch + worktree naming follow [AGENTS.md → Naming conventions](./AGENTS.md#naming-conventions-infra-186-2026-05-01) (canonical: `chump/<codename>` branch, `.chump/worktrees/<name>` worktree). Existing `claude/*` branches and `.claude/worktrees/` paths are accepted by tooling for backward compat — new work uses the `chump/` prefix so the project owns the namespace, not whichever tool is running this session.
- **Always work in a linked worktree, never in the main repo root.** `gap-claim.sh` refuses to run from `/Users/jeffadkins/Projects/Chump` directly — use a linked worktree under `.chump/worktrees/<name>/` (canonical) or `.claude/worktrees/<name>/` (legacy, accepted). Override with `CHUMP_ALLOW_MAIN_WORKTREE=1` only for bootstrapping.
- **Never start work on a gap without running `gap-preflight.sh` first.** It takes 3 seconds and prevents hours of wasted work.
- **Never leave a lease file behind.** Delete `.chump-locks/<session_id>.json` or call `chump --release` when done.
- **Commit often.** Uncommitted edits are at risk of being overwritten by `git pull`. Stage-commit every 30 minutes of work.
- **Commit explicitly, never implicitly.** Use `scripts/coord/chump-commit.sh <file1> [file2 ...] -m "msg"` instead of `git add && git commit`. The wrapper resets any unrelated staged files from OTHER agents before committing so their in-flight WIP doesn't leak into your commit (observed twice on 2026-04-17 — memory_db.rs stomp in cf79287, DOGFOOD_RELIABILITY_GAPS.md stomp in a5b5053).
- **Never hand-edit `docs/gaps/<ID>.yaml`.** Per-file gap YAMLs are *derived artifacts* of `.chump/state.db` (canonical post-INFRA-188). Mutate gaps ONLY through `chump gap` subcommands (`reserve`, `claim`, `set`, `ship`); each writes a freshness marker (`.chump/.last-yaml-op`) the pre-commit raw-YAML-edit guard checks. The guard is **blocking** since INFRA-200 — if it fires, switch to the CLI rather than bypass with `CHUMP_RAW_YAML_EDIT=1`. Hand-editing primary state caused the INFRA-049/052/055/057/064 + INFRA-208 corruption class. The legacy `docs/gaps.yaml` is now gitignored (it was deleted in INFRA-188 but stale chump binaries kept re-creating it as a side-effect — observed 5+ times in the 2026-05-02 cleanup pass).
- **If your branch is more than 15 commits behind main, rebase before continuing.**
- **Long COG-\* branches forbidden (INFRA-062 / M4, 2026-04-25).** Cognitive-architecture experiments must land behind a `runtime_flags` flag and ship in days, not weeks. Workflow: (1) new COG-\* gap lands a `cog_NNN` flag default-off, (2) bench harness compares flag-off baseline vs flag-on candidate (reflection rows tag `notes=flags=cog_NNN`), (3) cycle review flips default by removing the `if runtime_flags::is_enabled("cog_NNN")` gate, (4) cleanup PR removes the dead flag entry. Branches that sit > 5 days mid-experiment are evidence the flag pattern was skipped — split into trunk-friendly increments. See `src/runtime_flags.rs` for the API; `CHUMP_FLAGS=cog_040,cog_041` enables at runtime.
- **`CHUMP_GAP_CHECK=0 git push`** — bypass the pre-push gap-preflight hook. Use when gap IDs in commit bodies cause false positives (e.g. a cleanup commit that mentions a gap ID it doesn't implement).
- **Auto-merge IS the default** (since INFRA-MERGE-QUEUE, 2026-04-19; **strict mode disabled INFRA-201, 2026-05-01**). `bot-merge.sh --auto-merge` arms `gh pr merge --auto --squash` at PR creation — **BUT ONLY if all required CI checks are passing** (see **CI pre-flight gate** below). **There is no real GitHub merge queue on this repo** — the feature is org Team/Enterprise only and the `merge_queue` rule type returns 422 on a personal-account repo (see `docs/process/MERGE_QUEUE_SETUP.md` for the failed API attempts). INFRA-201 disabled the `strict` (require-up-to-date-branches) flag on the legacy branch protection: PRs land as soon as their **own** required checks (`test`, `audit`, `ACP smoke test`) are green, regardless of whether `main` has moved underneath them. This eliminates the BEHIND-cascade traffic jam that happens when N PRs auto-merge in parallel (observed 2026-05-01: 10 PRs blocked → 4 → 2 within seconds when strict was flipped off). The squash-loss footgun PR #52 originally taught us about is still mitigated by **atomic PR discipline** (don't push after arming auto-merge) plus the `pr-<N>-checkpoint` tag `bot-merge.sh` writes; treat the absence of a real queue as the reason that discipline is non-negotiable.
- **CI pre-flight gate (INFRA-CHOKE prevention, 2026-04-24).** `bot-merge.sh` now checks `gh pr checks <N>` before arming auto-merge. If Release job, Crate Publish dry-run, or any other required check is failing, auto-merge is NOT armed and a diagnostic comment is posted to the PR. This prevents PR #470-style situations where a PR is queued waiting for broken shared infrastructure. If your PR fails this check: (1) check the failing job logs, (2) fix the underlying issue (often in `.github/workflows/release.yml` or infrastructure), (3) re-run `scripts/coord/bot-merge.sh --gap <ID> --auto-merge` when checks pass. Disable with `CHUMP_SKIP_CI_GATE=1` only for genuine edge cases (legacy infra jobs, known flakes you've already triaged).
- **Atomic PR discipline.** Once `bot-merge.sh` runs, treat the PR as frozen — **do not push more commits to it**. If you need to add work, open a *new* PR from a fresh worktree (cheap with the musher dispatcher) and let the queue land them in order. Pushing-after-arm reintroduces the squash-loss footgun the queue exists to prevent.[^pr52]
- **bot-merge.sh recovery — manual ship path (INFRA-028).** If `scripts/coord/bot-merge.sh` hangs, times out, or is broken while you still have a clean branch in a linked worktree, ship by hand the same way that unblocked RESEARCH-027 cycle 5: `git push -u origin <branch> --force-with-lease` (or without `-u` if upstream exists), then `gh pr create --base main --title "…" --body "…"`, then `gh pr merge <N> --auto --squash` when you want the merge queue. Re-run `scripts/coord/gap-preflight.sh <GAP-ID>` first if you are gap-scoped. After a manual ship, run `chump gap ship <GAP-ID> --update-yaml` to flip status in `.chump/state.db` and regenerate `docs/gaps/<GAP-ID>.yaml` on the same branch, and release any `.chump-locks/<session>.json` lease for that gap so the ledger matches reality.
- **If auto-merge is stuck.** (Pre-INFRA-201 framing was "queue stuck"; in practice the symptoms and recovery are identical because there is no queue — see auto-merge note above.) Symptoms: `gh pr view <n> --json autoMergeRequest` shows auto-merge armed but PR state is still `OPEN` long after CI finished. Recovery (in order — try least-destructive first):
  1. **Diagnose.** `gh pr checks <n>` + open `https://github.com/repairman29/chump/queue/main` — identify the blocking PR. Common causes: CI failure on the queue's temp merge branch, required-check timeout, a rebase conflict the queue couldn't resolve, or auto-merge silently disarmed by a force-push / branch-protection change.
  2. **Re-run CI if flaky.** `gh run rerun <run-id> --failed` on the queue's temp branch run. Do NOT rerun on the PR branch itself — the queue grades its own temp branch, not yours.
  3. **Dequeue the blocker.** `gh pr merge <blocker-pr> --disable-auto`. This removes it from the queue without closing it; the PRs behind it start progressing. The blocker then either (a) gets a fix in a *new* PR (atomic discipline still applies — don't push to the blocker) or (b) is closed if superseded.
  4. **Recover lost commits via checkpoint tag.** `bot-merge.sh` pushes a `pr-<N>-checkpoint` tag at arm time. If a PR's branch got clobbered (force-push, squash-loss race), run `git fetch origin --tags && git checkout pr-<N>-checkpoint` in a fresh worktree — every commit that was on the branch at arm time is recoverable from that tag. See PR #52 / PR #65 history for the original incident.
  5. **Nuclear option — drain the queue.** If multiple PRs are tangled and (1–4) won't untangle them, disable auto-merge on *all* queued PRs (`for n in $(gh pr list --search 'is:open' --json number -q '.[].number'); do gh pr merge $n --disable-auto 2>/dev/null; done`), let main settle, then re-arm the PRs one at a time with `gh pr merge <n> --auto --squash` in priority order. Announce in ambient.jsonl before doing this — siblings will see their PRs dequeue and may otherwise assume a failure.
  6. **When in doubt, ask the human.** The queue has admin-only failure modes (branch-protection rule changes, required-check renames, queue disabled in settings) that agents can't fix. If steps 1–5 don't move the queue, flag the state in ambient.jsonl with `ALERT kind=queue_stuck` and stop — don't start churning new PRs against a broken queue.
- **Keep PRs intent-atomic (not file-count-bounded).** A PR is one logical change — a feature, a bug fix, a codemod, a config update. Mechanical multi-file refactors (renames, dead-code removal, dep swaps) ship as a *single* PR no matter the file count, because (a) atomic = no broken intermediate `main` state, (b) CI verifies the whole change end-to-end, and (c) one revert beats coordinating three. Stack only when the changes are *logically* distinct (e.g. "land the new API, then migrate callers, then delete the old API"). Old "≤ 5 files" guidance was for human reviewers; with merge-queue + required-CI, codemod-style PRs are the world-class default. If a human review is genuinely needed, label the PR `human-review-wanted` and split for them.
- **Stacked-PR rebase footgun (INFRA-239, 2026-05-02).** When you ship a stack — lower PR (`chump/foo-phase1` → `main`) plus upper PR (`chump/foo-phase2` → `chump/foo-phase1`, opened via `bot-merge.sh --stack-on PREV-GAP`) — and the **upper PR lands first** (squash-merges into the lower branch), the lower branch ends up with `[Phase 1 commits…] + [Phase 2 squash-merge on top]`. If `main` then moves and the lower PR goes DIRTY, a plain `git rebase origin/main` **silently drops the upper squash-merge** — it replays only the original Phase 1 commits onto current `main`. `pr-watch.sh`'s auto-rebase has the same blind spot. Recovery: after the rebase completes, run `git fetch origin --tags && git cherry-pick <upper-PR-merge-sha>` (find the sha via `gh pr view <upper-PR> --json mergeCommit -q .mergeCommit.oid`). **Verify the upper PR's content is present** (`grep` for a symbol it adds) before `git push --force-with-lease`. Caught on PR #783/#798. If you see "Phase N+1 not implemented" after a stacked rebase, this is why.
- **GitHub Actions multi-line strings — always heredoc, never inline (INFRA-157, 2026-04-28).** A `gh pr create --body "Verdict:..."` with column-1 lines inside a `run: |` block silently terminates YAML's pipe scalar. The workflow is rejected at parse time before any step runs — and the failure mode is invisible from `gh run list` (looks like "the run failed" not "the file is malformed"). When you need a multi-line PR/issue body, build it in a bash heredoc (`BODY=$(cat <<EOF ... EOF)`) so YAML never sees the embedded newlines:

  ```yaml
  - run: |
      BODY=$(cat <<EOF
      First line.

      Second line after blank.
      EOF
      )
      gh pr create --body "${BODY}"
  ```

  The same pattern was load-bearing for `ftue-clean-machine.yml` — every clean-machine FTUE run failed at parse time for ~30 attempts before this fix. Treat any column-1 token inside `run: |` as a parse-time risk and rebuild it via heredoc.
- **GitHub Actions cannot create PRs in this repo (INFRA-162, 2026-04-28).** `gh pr create` from a workflow returns `GraphQL: GitHub Actions is not permitted to create or approve pull requests`. Enabling it requires Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests" — a repo-admin action. Until that flips, workflows that need to deliver an artifact to main should `git push origin HEAD:main` directly (with `chump-ftue-bot` or similar bot identity); the artifact is doc-only and bot-authored, so direct push is appropriate. Branch protection allows GITHUB_TOKEN pushes for these bot identities.
- **Homebrew formulae must live in a tap (INFRA-161, 2026-04-28).** `brew install --build-from-source ./Formula/foo.rb` fails on modern Homebrew with `Homebrew requires formulae to be in a tap`. The CI workaround is `brew tap-new <name>/local --no-git --quiet && cp Formula/foo.rb $(brew --repo <name>/local)/Formula/ && brew install --build-from-source <name>/local/foo`. This also makes the verification reflect the real user install path (the documented one is `brew tap repairman29/chump && brew install chump`) instead of a workflow-only shortcut.

[^pr52]: Historical context — PR #52 (2026-04-18) lost 11 commits when an agent kept pushing after auto-merge was armed; GitHub captured the branch at first-CI-green and dropped everything pushed after. Recovery PR #65 was hand-cherry-picked. The merge queue (INFRA-MERGE-QUEUE) closes the race only if you stop pushing once the PR is in the queue.

## Worktree disk hygiene

Linked worktrees under `.claude/worktrees/` are the main **disk** risk on agent-heavy machines: each keeps its own `target/` (often multi‑GB after `cargo clippy` / `cargo test`). After a successful ship, `bot-merge.sh` **purges `./target`** in that worktree when it writes `.bot-merge-shipped` (skip with **`CHUMP_KEEP_TARGET=1`** if you still need the cache there).

**Stale trees (merged PR or deleted remote branch):** prefer automation over hand-tuning `git worktree list`.

1. **`scripts/ops/stale-worktree-reaper.sh`** — default is **dry-run** (safe to run anytime). With **`--execute`**, it archives selected eval logs then `git worktree remove --force` under `.claude/worktrees/` only when the script’s guards pass (cooldown, no conflicting lease, process / log freshness — see the script header).
2. **macOS — expected setup for dogfooding:** run **`scripts/setup/install-stale-worktree-reaper-launchd.sh`** once per machine so the reaper runs **hourly**. **Verify:** `launchctl list | grep ai.openclaw.chump-stale-worktree-reaper`. **Logs:** `/tmp/chump-stale-worktree-reaper.out.log` and `/tmp/chump-stale-worktree-reaper.err.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-stale-worktree-reaper.plist`.
3. **Opt out** for one worktree the reaper should never remove: **`touch <worktree-path>/.chump-no-reap`**.

Manual escape hatch from the **main** checkout: `git worktree remove .claude/worktrees/<name>` when you are sure nothing has that directory as its cwd.

**Cold-build cost (INFRA-202, 2026-05-02).** Disk reclaim doesn't help the *time* tax: every fresh worktree pays a 5–15 min cold `cargo check` / `clippy` because each `target/` starts empty. Observed 2026-05-01: `bot-merge.sh` hit a 900s clippy timeout on a freshly-created worktree. Fix is **sccache as a rustc wrapper** — install once per machine with `scripts/setup/install-sccache.sh` (idempotent: `brew install sccache` + writes `.cargo/config.toml` with `rustc-wrapper = "sccache"` and a 10G cache). The first worktree to build a given crate version populates the cache; every subsequent worktree gets it in <60s. `.cargo/config.toml` is `.gitignore`d so each machine controls its own cache config (CI runners without sccache won't break). Opt out with `rm .cargo/config.toml`.

**Reaper visibility — heartbeat + ambient events (INFRA-120, 2026-05-01).** All three reapers (`stale-pr-reaper.sh`, `stale-worktree-reaper.sh`, `stale-branch-reaper.sh`) emit a `kind=reaper_run` event into `.chump-locks/ambient.jsonl` on every run with `status=ok|fail` and per-reaper counts. They also stamp `/tmp/chump-reaper-<name>.heartbeat` (`pr` / `worktree` / `branch`). Each reaper rotates its own `/tmp/chump-stale-*-reaper.{out,err}.log` to a single `.1` archive at 5MB so logs never grow unbounded.

A separate watchdog grades the heartbeats and ALERTs the fleet when a reaper goes silent:
- **Watchdog:** `scripts/ops/reaper-heartbeat-watchdog.sh` — emits `ALERT kind=reaper_silent` into `ambient.jsonl` when a reaper hasn't heartbeated in 2h (pr), 4h (worktree), or 48h (branch) — i.e. ~2-4× the launchd cadence per the gap acceptance criteria. Visible in the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`.
- **macOS install (do this once per dogfood machine):** `scripts/setup/install-reaper-watchdog-launchd.sh` — runs every 30 min. **Verify:** `launchctl list | grep ai.openclaw.chump-reaper-watchdog`. **Disable:** `launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-reaper-watchdog.plist`.
- **Manual check:** `scripts/ops/reaper-heartbeat-watchdog.sh` (no flags) prints per-reaper status and exits 0 even with ALERTs (so launchd doesn't loop on it).
- **Quickly grep the stream:** `tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"reaper_(run|silent)"'`.

## ambient.jsonl rotation (INFRA-122, 2026-05-02)

`.chump-locks/ambient.jsonl` is the file-side of the peripheral-vision stream and is appended-to by every agent on every event. Without rotation it grows ~4MB/day under fleet load and reaches multi-GB over a few weeks.

- **Rotation script:** `scripts/dev/ambient-rotate.sh` — keeps `AMBIENT_RETAIN_DAYS` (default 7) of events in-place, archives older events to `.chump-locks/ambient.jsonl.YYYY-MM-DD.gz`, and writes a `{"event":"rotated",...}` summary line.
- **macOS install (do this once per dogfood machine):** `scripts/setup/install-ambient-rotate-launchd.sh` — runs the rotate script daily at 03:00 local. **Verify:** `launchctl list | grep ai.openclaw.chump-ambient-rotate`. **Logs:** `/tmp/chump-ambient-rotate.{out,err}.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/ai.openclaw.chump-ambient-rotate.plist`.
- **Self-monitoring:** if `ambient.jsonl` exceeds `AMBIENT_SIZE_ALERT_MB` (default 50MB), the rotate script emits an `ALERT kind=ambient_oversize` event into the stream itself — visible during the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`. Catches the case where rotation isn't installed or the schedule broke.
- **Querying historical data:** `scripts/dev/ambient-query.sh` transparently reads from the live log + all rotated `.gz` archives in chronological order. Use `--since 24h` to bound the search.

## Overnight research scheduler (INFRA-114, 2026-04-26)

Research churn (eval sweeps, A/B studies, ablations) runs overnight, not during the workday. Daytime is for the dispatcher and agent work.

- **Drop-in directory:** `scripts/overnight/` — every executable `*.sh` runs in lex order. Rename to `*.disabled` to skip.
- **Wrapper:** `scripts/eval/run-overnight-research.sh` — 1h per-job timeout, lockfile guard, per-run logs in `.chump/overnight/<run-id>.log`, emits `overnight_start` / `overnight_done` / `overnight_job_fail` to `ambient.jsonl`.
- **macOS install:** `scripts/setup/install-overnight-research-launchd.sh` (default 02:00 daily; override with `CHUMP_OVERNIGHT_HOUR`/`CHUMP_OVERNIGHT_MINUTE`).
- **On-demand smoke test:** `launchctl start ai.openclaw.chump-overnight-research` after install, then `tail /tmp/chump-overnight-research.out.log`.
- **Conventions:** see `scripts/overnight/README.md`.

When you migrate an existing eval/A/B sweep, drop it as `scripts/overnight/<NN>-<short>.sh`, smoke-test it directly, and verify the next run picks it up.

## Session ID resolution (how leases are scoped)

`gap-claim.sh` picks a session ID in this priority order — first non-empty wins:

1. `$CHUMP_SESSION_ID` — explicit override (set by `bot-merge.sh` or manually)
2. `$CLAUDE_SESSION_ID` — injected by Claude Code SDK; unique per agent session (**best**)
3. `.chump-locks/.wt-session-id` — worktree-scoped ID generated once per linked worktree (stable across re-runs within the same worktree session)
4. `$HOME/.chump/session_id` — machine-scoped legacy fallback (shared across all sessions — avoid)

The worktree-scoped ID (3) is automatically generated and cached the first time `gap-claim.sh` runs in a new worktree. It is scoped to `.claude/worktrees/<name>/` so concurrent sessions in different worktrees never collide.

## Commit-time guards (coordination audit, 2026-04-17; expanded since)

Every commit runs the checks below. Most are silent no-ops; each one fails loud with a bypass hint. Most live in `scripts/git-hooks/pre-commit` (installed via `./scripts/setup/install-hooks.sh`); the **wrong-worktree** check lives in the `scripts/coord/chump-commit.sh` wrapper and only runs if you commit through it. See the pre-commit hook header for the canonical list and ordering.

| Check | Where | What it blocks | Bypass env | Why |
|---|---|---|---|---|
| lease-collision | pre-commit | file claimed by a different live session | `CHUMP_LEASE_CHECK=0` | silent stomps |
| out-of-scope (INFRA-189, 2026-05-01) | pre-commit | MY lease declares `paths` and I'm staging files OUTSIDE that scope | `CHUMP_SCOPE_CHECK=0` (disable) / `CHUMP_SCOPE_CHECK=enforce` (block instead of warn) | wrong-worktree commits + cross-fixture leaks (INFRA-076 class). Default **warn** for the first week so we observe false-positive rate; flip to `enforce` after. Only triggers when the lease has a non-empty `paths` field — agents that don't declare scope still work as before. |
| stomp-warning | pre-commit | staged file mtime > 10 min (non-blocking) | `CHUMP_STOMP_WARN=0` | cross-agent staging drift |
| gaps.yaml discipline | pre-commit | adds `status: in_progress` / `claimed_by:` / `claimed_at:` to the YAML | `CHUMP_GAPS_LOCK=0` | claim fields live in `.chump-locks/`, not the ledger |
| gap-ID hijack (2026-04-18) | pre-commit | gaps.yaml diff *changes* an existing gap's `title:` or `description:` (silent ID reuse) | `CHUMP_GAPS_LOCK=0` | caught PR #60 ↔ #65 EVAL-011 collision; new work needs a new ID, not redefinition |
| duplicate-ID insert (INFRA-GAPS-DEDUP, 2026-04-19; test in INFRA-015) | pre-commit | gaps.yaml ends up with two entries sharing the same `id:` | `CHUMP_GAPS_LOCK=0` | closes the hole that let the 7 collision pairs in per Red Letter #2; test: `scripts/ci/test-duplicate-id-guard.sh` |
| recycled-ID guard (INFRA-014, 2026-04-21) | pre-commit | reopening a previously-`done` gap with new content under the same id | `CHUMP_GAPS_LOCK=0` | new work gets a new ID; closed gaps are immutable history |
| closed_pr integrity guard (INFRA-107, 2026-04-26) | pre-commit | flipping a gap to `status: done` when `closed_pr` is absent, `TBD`, or any non-numeric value | `CHUMP_GAPS_LOCK=0` | PRODUCT-009 false closure shipped with `closed_pr: TBD`; RED_LETTER #2 caught it days later; test: `scripts/ci/test-closed-pr-guard.sh` |
| preregistration required (RESEARCH-019) | pre-commit | closing an `EVAL-*` or `RESEARCH-*` gap to `status: done` without a `docs/eval/preregistered/<GAP-ID>.md` committed | `CHUMP_PREREG_CHECK=0` with justification | hypothesis must be locked before data collection — retrospective / doc-only gaps use the bypass |
| preregistration content (INFRA-113, 2026-04-28) | pre-commit | preregistration file exists but is empty / a stub / unfilled `TEMPLATE.md` — no sample size, no judge identity, no A/A baseline reference, no effect threshold, no prohibited-claims pointer | `CHUMP_PREREG_CONTENT_CHECK=0` for genuinely retrospective gaps | file existence is not enough; the methodology contract must actually be locked. Test: `scripts/ci/test-prereg-content-guard.sh` (5 cases). Stub-prereg gaps shipped before this guard motivated the gap |
| cross-judge audit (INFRA-079, 2026-04-28) | pre-commit | closing an `EVAL-*` or `RESEARCH-*` gap without `cross_judge_audit:` (≥2 judge families) OR `single_judge_waived: true` + reason OR a prereg declaring single-judge scope | `CHUMP_CROSS_JUDGE_CHECK=0` with justification | EVAL-074 cost ~$1.50 + half a day + 3 amendment PRs because a Llama-only judge labeled the result; test: `scripts/ci/test-cross-judge-guard.sh` |
| submodule sanity (INFRA-018, 2026-04-19) | pre-commit | adding a gitlink (mode 160000) without a matching `.gitmodules` entry | `CHUMP_SUBMODULE_CHECK=0` | sql-migrate gitlink broke `actions/checkout` on every PR for days |
| cargo-fmt auto-fix | pre-commit | unformatted `.rs` (auto-fixes + re-stages) | — | CI `cargo fmt --check` thrash |
| cargo-check build guard | pre-commit | staged `.rs` fails `cargo check --bin chump --tests` | `CHUMP_CHECK_BUILD=0` | broken-compile commits triggering `fix(ci):` follow-ups |
| docs-delta check (INFRA-009, 2026-04-20) | pre-commit | adds a `docs/*.md` without deleting one or adding a `Net-new-docs:` trailer | `CHUMP_DOCS_DELTA_CHECK=0` | counter-pressure on doc sprawl per Red Letter #3 (advisory until 2026-04-28, blocking after) |
| credential-pattern guard (INFRA-018, 2026-04-20) | pre-commit | staged diff matches common API-key / token shapes | `CHUMP_CREDENTIAL_CHECK=0` | secrets caught before they hit git history |
| book sync guard (INFRA-170, 2026-05-01) | pre-commit | staged `docs/process/*.md` edit drifts `book/src/` (canonical sync script produces uncommitted book/ changes) | `CHUMP_BOOK_SYNC_CHECK=0` | PR #625 silently drifted the book mirror, jamming the merge queue 12 PRs deep on 2026-04-29; runs the sync script automatically and tells you to `git add book/`; test: `scripts/ci/test-book-sync-guard.sh` |
| raw-YAML-edit guard (INFRA-094 advisory → INFRA-200 blocking, 2026-05-02) | pre-commit | commit modifies any `docs/gaps/<ID>.yaml` (post-INFRA-188; previously `docs/gaps.yaml`) without a fresh chump-gap CLI marker (`.chump/.last-yaml-op` within last 5 min) | `CHUMP_RAW_YAML_EDIT=1` env + `RAW_YAML_REASON: <text>` trailer (intentional manual edit), or `CHUMP_RAW_YAML_LOCK=0` (kill switch) | Cold Water Issue #9 measured 66% hand-edit rate (33/50 commits) under the prior advisory mode; flipped to blocking; test: `scripts/ci/test-raw-yaml-guard.sh` |
| wrong-worktree commit (2026-04-18) | `chump-commit.sh` | named files have no changes in this worktree but DO have changes in a sibling worktree | `CHUMP_WRONG_WORKTREE_CHECK=0` | catches the "edited the wrong checkout" failure mode that wasted ~30 min on 2026-04-18; only runs if you use `chump-commit.sh` |

`git commit --no-verify` bypasses ALL pre-commit guards (the chump-commit.sh wrapper has its own bypass envs). Use very sparingly — `--no-verify` is the reason task #58 (Metal crash) and half the duplicate-work incidents shipped.

## Dispatched-subagent backend (COG-025, 2026-04-19)

If you wake up inside a `chump-orchestrator`-dispatched worktree, you may be
running on either backend depending on what the operator set
`CHUMP_DISPATCH_BACKEND` to:

- **`claude` (default).** You are running as `claude -p <prompt> --dangerously-skip-permissions` — the original AUTO-013 baseline. Anthropic-only.
- **`chump-local`.** You are running inside Chump's own multi-turn agent loop (`chump --execute-gap <GAP-ID>`) driven by whatever provider `$OPENAI_API_BASE` + `$OPENAI_MODEL` resolve to (Together free tier, mistral.rs, Ollama, hosted OpenAI). Cost-routing path.

The contract is identical either way: read `CLAUDE.md` mandatory pre-flight,
do the gap, ship via `scripts/coord/bot-merge.sh --gap <id> --auto-merge`, reply
ONLY with the PR number. The orchestrator records which backend ran on the
reflection row (`notes` field, prefix `backend=<label>`) so PRODUCT-006 and
the COG-026 A/B aggregator can split outcomes by backend.

## Coordination docs

- `.chump/state.db` — **canonical** gap registry (SQLite, since INFRA-059); accessed via `chump gap …` subcommands
- `docs/gaps/<ID>.yaml` — human-readable per-file mirror (post-INFRA-188; the legacy monolithic `docs/gaps.yaml` was deleted), regenerated by `chump gap set/ship/dump`; commit alongside DB mutations so PRs are reviewable
- `.chump/state.sql` — readable diff of the SQLite schema/data; regenerate with `chump gap dump --out .chump/state.sql` after merge conflicts
- `docs/process/AGENT_COORDINATION.md` — full coordination system (leases, branches, failure modes, pre-commit spec)
- `scripts/coord/gap-preflight.sh` — gap availability check (reads lease files + checks done on main)
- `scripts/coord/gap-claim.sh` — write a gap claim to your session's lease file
- `scripts/coord/bot-merge.sh` — ship pipeline (calls gap-claim.sh automatically)
- `scripts/coord/gap-doctor.py` — drift detector + repair tool (INFRA-155). Compares `.chump/state.db` against `docs/gaps/<ID>.yaml` files (post-INFRA-188; previously the monolithic `docs/gaps.yaml`) and reports four buckets: DB done / YAML open (regen YAML), DB open / YAML done (sync DB from YAML), DB-only orphans, YAML-only ghosts. Run `gap-doctor.py doctor` for a read-only report; `sync-from-yaml --apply` drains pre-INFRA-152 hand-edit drift; `sync-from-db --apply` regenerates YAML from DB. The 2026-04-28 first run drained 25 status:open-but-actually-done rows in one shot.
- `scripts/ops/stale-pr-reaper.sh` — runs hourly, auto-closes PRs whose gaps landed on main
- `scripts/ops/stale-worktree-reaper.sh` — removes merged / orphaned linked worktrees under `.claude/worktrees/` (default dry-run; use `--execute`). macOS hourly install: `scripts/setup/install-stale-worktree-reaper-launchd.sh` (see **Worktree disk hygiene** above)
- `scripts/ops/reaper-heartbeat-watchdog.sh` — INFRA-120 watchdog that ALERTs `ambient.jsonl` when any stale-* reaper misses its expected cadence (pr 2h / worktree 4h / branch 48h). macOS install: `scripts/setup/install-reaper-watchdog-launchd.sh`
- `scripts/git-hooks/pre-commit` — coordination hook (see **Commit-time guards** table above)
- `scripts/git-hooks/pre-push` — gap-preflight gate (blocks pushes with `done`/stolen-claim gap IDs)
- `scripts/git-hooks/post-checkout` — auto-installs hooks into every worktree after `git worktree add`

## Gap registry — `.chump/state.db` is canonical (INFRA-059, 2026-04-25)

INFRA-023 (2026-04-21) added the SQLite store; INFRA-059 (M1 of the
World-Class Roadmap) **flipped authority** from the then-monolithic
`docs/gaps.yaml` to `.chump/state.db` so concurrent agents no longer race
on a single hot YAML file. (The April 2026 corruption incidents —
INFRA-049/052/055/057/064 — were all instances of that race.) INFRA-188
(2026-05-02) then deleted the monolithic `docs/gaps.yaml` and replaced it
with per-file `docs/gaps/<ID>.yaml` mirrors, eliminating the merge-conflict
hotspot entirely.

- **`chump gap …` subcommands are the primary interface.** They mutate
  `.chump/state.db` directly.
- **`docs/gaps/<ID>.yaml` files are a regenerated mirror**, not a source.
  They exist so PRs have a human-readable diff. Regenerate via `chump gap
  ship --update-yaml` (per-ship) or `chump gap dump` (full export to
  `docs/gaps/`).
- **`.chump/state.sql` is the readable diff of the SQLite store** — commit
  it alongside any DB mutation so reviewers can see what changed (binary
  SQLite is unreviewable). After a merge conflict in the SQL dump,
  regenerate with `chump gap dump --out .chump/state.sql`.
- **Legacy shell scripts (`gap-claim.sh`, `gap-reserve.sh`,
  `gap-preflight.sh`) still work** as fallbacks and are wired into hooks,
  but the Rust-native commands are preferred. Note: the shell scripts
  predate the SQLite store — they operate on lease files and (post-INFRA-188)
  `docs/gaps/<ID>.yaml` files; they do **not** read or write
  `.chump/state.db`. So when an agent is driving via `bot-merge.sh` (which
  calls `gap-claim.sh`), the lease layer and the SQLite store are
  independent. The two converge when `chump gap ship --update-yaml`
  regenerates the per-file YAML mirrors at ship time.

```bash
chump gap import                          # one-time: seed DB from per-file docs/gaps/<ID>.yaml mirrors (historical: pre-INFRA-188 it read the monolithic docs/gaps.yaml)
chump gap list [--status open] [--json]   # list gaps; --json output is musher-compatible
chump gap reserve --domain INFRA --title "..." [--priority P1] [--effort s]
chump gap claim <GAP-ID> [--session ID] [--worktree PATH]
chump gap preflight <GAP-ID>              # exit 0=available, 1=done/claimed
chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]   # flip status: done + stamp closed_date (+ closed_pr if given); --update-yaml regenerates docs/gaps/<ID>.yaml
chump gap set <GAP-ID> [--title|--description|--priority|--effort|--status|--notes|--source-doc|--opened-date|--closed-date|--closed-pr N|--acceptance-criteria "a|b|c"|--depends-on "X,Y"]
chump gap dump                            # full export to per-file docs/gaps/<ID>.yaml mirrors
```
