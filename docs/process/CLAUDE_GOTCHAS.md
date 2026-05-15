# CLAUDE.md — operational gotchas (cold layer)

> **Read on-demand when you hit a specific failure surface** — chump
> binary hung, raw-YAML guard fired, fleet starved, syspolicyd wedge,
> rebase footgun, etc. This file used to live in `CLAUDE.md`; DOC-018
> (2026-05-04) split out the hot layer (mandatory pre-flight, hard
> rules, ship pipeline) so every spawn doesn't pay the ~13K-token tax.
> The hot layer is now [`/CLAUDE.md`](../../CLAUDE.md). Operators and
> agents read both — but only this one when something specific breaks.

> **Read [`RESEARCH_INTEGRITY.md`](./RESEARCH_INTEGRITY.md) before touching any eval,
> cognitive-architecture code, or research claim.** It supersedes earlier framing in
> CHUMP_PROJECT_BRIEF.md and CHUMP_RESEARCH_BRIEF.md. The accurate thesis is narrower than
> what those docs say.

> **Read [`/AGENTS.md`](../../AGENTS.md) first.** It is the canonical, tool-agnostic
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
chump gap preflight <GAP-ID>            # exits 1 if done, live-claimed/reserved, or ID missing from registry — stop if so
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

**Hung-binary alarm (INFRA-275, observed 2026-05-02).** Distinct symptom
from staleness: `chump gap …` returns no output, no errors, never exits.
`ps` shows accumulating chump processes in state `UE` (uninterruptible
exit). Direct `sqlite3 .chump/state.db 'SELECT COUNT(*) FROM gaps'` works
instantly — so the DB is fine; the *binary itself* is wedged at
`_dyld_start` (the dynamic linker, before `main()`). Root cause: macOS
Sequoia's `syspolicyd` (Gatekeeper / code-signing arbiter) gets the
binary's *inode* into a pending-decision wedge, and every subsequent
launch of the same inode queues behind it. **DO NOT** fall back to
direct `docs/gaps/<ID>.yaml` writes — concurrent siblings each scanning
the filesystem will pick the same "next free" ID and collide. Heal
instead with:

```bash
scripts/dev/chump-binary-unwedge.sh           # probes + replaces wedged inode
CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-binary-unwedge.sh   # skip probe, just heal
```

The doctor moves the wedged binary aside as
`~/.cargo/bin/chump.wedged-inode-<n>` and copies the same content back
through a fresh inode (which `syspolicyd` treats as a new file with no
prior decision). `kill -9` on the UE-state zombies is best-effort; they
fully clear only on reboot but are otherwise harmless. `sudo kill
syspolicyd` (operator-only — needs sudo) is the nuclear option if even
the fresh inode hangs.

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

**NATS deployment decision (FLEET-053, 2026-05-15).** As of this date, the Cold Water scheduled trigger (`trig_01GA2XVbAZtpkBaWfrEo1CrP`) does **not** have `CHUMP_NATS_URL` set to a public broker — no public NATS broker has been provisioned for the fleet. Consequence: Cold Water cycle ambient evidence will show only local-file events from that runner session; cross-machine fleet activity is **not** visible in Cold Water output. This is intentional, not an oversight. Do **not** file a finding like "NATS subscription silent" or "ambient stream empty" — local-file silence in a Cold Water context reflects the absence of a broker, not a bug. If a public broker is provisioned in future, set `CHUMP_NATS_URL=nats://<host>:4222` in the trigger environment and remove this note.

Event kinds to know:
- `session_start` — another agent just opened a session (note their worktree and gap)
- `file_edit` — another agent edited a file (note the path — may overlap yours)
- `commit` — a commit landed (note the sha and gap — may have advanced main)
- `bash_call` — another agent ran a command (cargo check failure? test run?)
- `ALERT kind=lease_overlap` — **stop and read**: two sessions claim the same file
- `ALERT kind=silent_agent` — a live session stopped heartbeating; its work may be lost
- `ALERT kind=edit_burst` — rapid file mutations in progress; possible rebase stomp
- `ALERT kind=queue_config_drift` — branch-protection rule on `main` no longer matches `docs/baselines/branch-protection-main.json`; auto-merge may be silently disarmed (INFRA-121, run `scripts/ops/branch-protection-drift.sh --dry-run` to inspect)

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

- **Default to haiku for routine project work (INFRA-369, 2026-05-03).** `.claude/settings.json` pins `"model": "claude-haiku-4-5"` + `"effortLevel": "medium"` for this repo. Rationale: opus-4-7 high is ~50× haiku per token; one fleet session burned $92 of workspace credit + maxed the $20/mo subscription cap. For routine ship-a-gap work haiku is plenty. Override per-session via `/model` in the Claude Code app for genuinely hard tasks. Per-fleet override: `FLEET_MODEL=sonnet scripts/dispatch/run-fleet.sh` (INFRA-364).
- **Never push directly to `main`.** Branch + worktree naming follow [AGENTS.md → Naming conventions](./AGENTS.md#naming-conventions-infra-186-2026-05-01) (canonical: `chump/<codename>` branch, `.chump/worktrees/<name>` worktree). Existing `claude/*` branches and `.claude/worktrees/` paths are accepted by tooling for backward compat — new work uses the `chump/` prefix so the project owns the namespace, not whichever tool is running this session.
- **Always work in a linked worktree, never in the main repo root.** `chump claim` refuses to run from the main repo root — use a linked worktree under `.chump/worktrees/<name>/` (canonical) or `.claude/worktrees/<name>/` (legacy, accepted). Override with `CHUMP_ALLOW_MAIN_WORKTREE=1` only for bootstrapping.
- **Never start work on a gap without running `chump gap preflight <GAP-ID>` first.** It takes 3 seconds and prevents hours of wasted work.
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
- **Branch-protection / workflow-job alignment (CREDIBLE-058, 2026-05-14).** Branch protection requires three check contexts: `test`, `audit`, `ACP protocol smoke test (Zed / JetBrains compatible)`. If you rename any of these workflow jobs in `.github/workflows/`, branch protection still expects the OLD name and every PR will stall with "required check missing." The pre-commit hook now catches this: any staged change to `.github/workflows/*.yml` triggers `scripts/ci/audit-branch-protection.sh --baseline --check-staged`, which verifies every required context matches a job name in the staged YAML. If you intentionally rename a job and update branch protection, run `scripts/ci/audit-branch-protection.sh --update-baseline` to commit the new baseline. Bypass: `CHUMP_BRANCH_PROTECTION_AUDIT=0 git commit ...`. Drift is also signalled via `kind=branch_protection_drift` in ambient.jsonl.
- **Workflow-only / gap-only PR path-filter trap (INFRA-272, 2026-05-02).** Required CI checks (`test`, `audit`, `ACP smoke test`) are gated by `dorny/paths-filter` inside `.github/workflows/ci.yml`'s `changes` job, which uses an **allowlist** in the `code:` filter. If a PR's diff matches NONE of the allowlist patterns, the gated jobs mark "skipped" and branch protection treats that as missing-not-passing — auto-merge can never satisfy it (killed PR #803 entirely, almost killed PR #874 on 2026-05-02). **Decision: option (a) — extend the allowlist.** `.github/workflows/**` and `docs/gaps/**` are now in `code:`, so workflow-only and gap-filing PRs trigger all required checks. If you add a new top-level path that PRs may exclusively touch (e.g. a new config dir), add it to the `code:` filter or your PR will get stuck. PR #874 is the regression fixture: gap+workflow+script diff, all three required checks fired green. Bypass for genuine docs-only sweeps: keep diffs in `docs/` (excluding `docs/gaps/`) and accept the skip — branch protection lets the rollup pass when shards skip uniformly.
- **bot-merge.sh recovery — manual ship path (INFRA-028).** If `scripts/coord/bot-merge.sh` hangs, times out, or is broken while you still have a clean branch in a linked worktree, ship by hand the same way that unblocked RESEARCH-027 cycle 5: `git push -u origin <branch> --force-with-lease` (or without `-u` if upstream exists), then `gh pr create --base main --title "…" --body "…"`, then `gh pr merge <N> --auto --squash` when you want the merge queue. Re-run `chump gap preflight <GAP-ID>` first if you are gap-scoped. After a manual ship, run `chump gap ship <GAP-ID> --update-yaml` to flip status in `.chump/state.db` and regenerate `docs/gaps/<GAP-ID>.yaml` on the same branch, and release any `.chump-locks/<session>.json` lease for that gap so the ledger matches reality.
- **If auto-merge is stuck.** (Pre-INFRA-201 framing was "queue stuck"; in practice the symptoms and recovery are identical because there is no queue — see auto-merge note above.) Symptoms: `gh pr view <n> --json autoMergeRequest` shows auto-merge armed but PR state is still `OPEN` long after CI finished. Recovery (in order — try least-destructive first):
  0. **Confirm it's actually stuck (INFRA-306).** `gh pr view <n> --json state -q .state` first. If `MERGED`, abandon recovery — the PR landed and your "stuck" view was 30s stale. `bot-merge.sh` and `pr-watch.sh` both run this check before any force-push since INFRA-306; manual recovery should too.
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

## Agent UI verification (PRODUCT-037, 2026-05-08)

When a gap touches `web/` (PWA, static assets, `app.js`, `index.html`, etc.), the agent **must** verify the served UI before shipping — not just that the files exist, but that the server actually serves them correctly. Use `scripts/dev/dev-server.sh` (not `restart-chump-web.sh` or `run-web.sh`, which are operator tools with git-pull + full rebuild logic that are wrong for in-worktree verification).

```bash
# 1. Start a lightweight dev server on a dedicated port (won't collide with the
#    operator's live server on 3000, and won't do a git pull / release build).
scripts/dev/dev-server.sh start --port 3737

# 2. Verify key paths respond 200.  Default paths: /api/health and /v2/
scripts/dev/dev-server.sh verify --port 3737

# 3. Verify additional app-specific paths your gap touches.
scripts/dev/dev-server.sh verify --port 3737 /v2/ /api/dashboard /api/jobs

# 4. Check health manually if you want the JSON body.
curl -s http://127.0.0.1:3737/api/health | python3 -m json.tool

# 5. Stop when done (good hygiene — don't leave stray processes).
scripts/dev/dev-server.sh stop --port 3737
```

**Port 3737 is the agent verification default.** It is reserved for in-worktree agent checks; port 3000 is the operator's live server. This prevents agents from stomping the running PWA.

**Build flag.** By default `dev-server.sh start` uses the nearest pre-built binary (`target/debug/chump` preferred over `target/release/chump`). Pass `--build` to rebuild first:

```bash
scripts/dev/dev-server.sh start --port 3737 --build   # rebuild debug binary, then start
```

**`cargo run` fallback.** If no binary exists at all (fresh clone), `dev-server.sh start` automatically builds a debug binary before starting.

**Status + restart helpers:**

```bash
scripts/dev/dev-server.sh status   # exit 0 if running, exit 1 if stopped
scripts/dev/dev-server.sh restart  # stop + start in one shot
```

**Gotcha — worktree `target/` may be empty (PRODUCT-037).** Linked worktrees share `CARGO_TARGET_DIR` only if the env is explicitly set; by default each worktree has its own `target/`. If `start` reports "no pre-built binary found", pass `--build` or point `CARGO_TARGET_DIR` at the main repo's target:

```bash
CARGO_TARGET_DIR="$(git rev-parse --show-toplevel)/target" \
  scripts/dev/dev-server.sh start --port 3737
```

**Must-do for PWA gap acceptance.** Any gap whose `acceptance_criteria` mentions the UI or PWA must include at least one `verify` pass in its acceptance evidence. Document the passing output in your PR body:

```
## UI verification
$ scripts/dev/dev-server.sh verify --port 3737 /api/health /v2/
[dev-server] PASS  200  /api/health
[dev-server] PASS  200  /v2/
[dev-server] all paths OK
```

## Speculative execution (INFRA-193, opt-in)

Default coordination is **exclusive lease** — one agent per gap. That serializes work and adds coordination latency. For latency-critical or high-diversity gaps you can opt two (or more) agents into a deliberate race:

```bash
# Both agents add --speculative when claiming the same gap:
scripts/coord/gap-claim.sh INFRA-NNN --speculative              # agent A
CHUMP_SPECULATIVE=1 scripts/coord/gap-preflight.sh INFRA-NNN    # agent B preflight
scripts/coord/gap-claim.sh INFRA-NNN --speculative              # agent B claim

# Or via bot-merge.sh end-to-end (propagates to gap-claim.sh + post-arm sweep):
scripts/coord/bot-merge.sh --gap INFRA-NNN --auto-merge --speculative
```

**Semantics:**
- `gap-claim.sh --speculative` writes `"speculative": true` into the lease.
- `gap-preflight.sh` allows concurrent claims **only when both sides are speculative**. A non-speculative claimer is still blocked by any existing claim (and a speculative claimer is still blocked by an existing non-speculative claim — opting out of the race forfeits the right to race).
- `bot-merge.sh --speculative` propagates the flag to gap-claim.sh AND, after auto-merge is armed, runs a **loser sweep**: scans open PRs that cite the same gap ID and closes them with `Auto-closing as superseded by #N`. The losers' branches stay intact (no force-push, no commit loss) — re-open or cherry-pick if the winner is later reverted.

**When it makes sense:** latency-critical gaps; gaps where two agents have very different strengths (e.g. one Claude, one Gemini); research/eval gaps where the diversity is itself the signal. Cost: 2x compute. Benefit: 0x coordination latency + diversity bonus.

**Bypass envs:** `CHUMP_SPECULATIVE_SWEEP=0` skips the loser-PR closure step; `CHUMP_SPECULATIVE=1` enables the mode without `--speculative`.

**Tests:** `scripts/ci/test-speculative-execution.sh` covers the four-quadrant claim matrix (spec×spec allow, spec×excl block, excl×spec block, lease writes `speculative=true`).

## Worktree disk hygiene

Linked worktrees under `.claude/worktrees/` are the main **disk** risk on agent-heavy machines: each keeps its own `target/` (often multi‑GB after `cargo clippy` / `cargo test`). After a successful ship, `bot-merge.sh` **purges `./target`** in that worktree when it writes `.bot-merge-shipped` (skip with **`CHUMP_KEEP_TARGET=1`** if you still need the cache there).

**Stale trees (merged PR or deleted remote branch):** prefer automation over hand-tuning `git worktree list`.

1. **`scripts/ops/stale-worktree-reaper.sh`** — default is **dry-run** (safe to run anytime). With **`--execute`**, it archives selected eval logs then `git worktree remove --force` under `.claude/worktrees/` only when the script’s guards pass (cooldown, no conflicting lease, process / log freshness — see the script header).
2. **macOS — expected setup for dogfooding:** run **`scripts/setup/install-stale-worktree-reaper-launchd.sh`** once per machine so the reaper runs **hourly**. **Verify:** `launchctl list | grep dev.chump.stale-worktree-reaper`. **Logs:** `/tmp/chump-stale-worktree-reaper.out.log` and `/tmp/chump-stale-worktree-reaper.err.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/dev.chump.stale-worktree-reaper.plist`.
3. **Opt out** for one worktree the reaper should never remove: **`touch <worktree-path>/.chump-no-reap`**.

Manual escape hatch from the **main** checkout: `git worktree remove .claude/worktrees/<name>` when you are sure nothing has that directory as its cwd.

**Cold-build cost (INFRA-202, 2026-05-02).** Disk reclaim doesn't help the *time* tax: every fresh worktree pays a 5–15 min cold `cargo check` / `clippy` because each `target/` starts empty. Observed 2026-05-01: `bot-merge.sh` hit a 900s clippy timeout on a freshly-created worktree. Fix is **sccache as a rustc wrapper** — install once per machine with `scripts/setup/install-sccache.sh` (idempotent: `brew install sccache` + writes `.cargo/config.toml` with `rustc-wrapper = "sccache"` and a 10G cache). The first worktree to build a given crate version populates the cache; every subsequent worktree gets it in <60s. `.cargo/config.toml` is `.gitignore`d so each machine controls its own cache config (CI runners without sccache won't break). Opt out with `rm .cargo/config.toml`.

**Shared CARGO_TARGET_DIR phantom fingerprint error (INFRA-1138, 2026-05-14).** `install-sccache.sh` (INFRA-481) sets `target-dir = "/Users/.../Chump/target"` in `.cargo/config.toml` so all linked worktrees share a single target directory (saving disk). Side-effect: cargo's fingerprint cache is also shared. If worktree A compiled `tests/cli_fleet_coord.rs` and stored the fingerprint in the shared target, worktree B (which may not have that test file on its branch) reads the cached fingerprint and tries to verify the file — failing with `couldn't read tests/cli_fleet_coord.rs: No such file or directory`. **Fix (INFRA-1138):** the pre-push test gate sets `CARGO_TARGET_DIR="$REPO_ROOT_T/.cargo-test-target"` (per-worktree) for the `cargo test` invocation. sccache (configured via `rustc-wrapper` in `.cargo/config.toml`) still provides cross-worktree object-code caching — only the fingerprint/incremental data is isolated. The `.cargo-test-target` directory lives inside each linked worktree and is cleaned up when the worktree is deleted. **Symptom:** `Test-Gate-Bypass: phantom fingerprint from sibling worktree` trailers on commits from before INFRA-1138.

**Reaper visibility — heartbeat + ambient events (INFRA-120, 2026-05-01).** All three reapers (`stale-pr-reaper.sh`, `stale-worktree-reaper.sh`, `stale-branch-reaper.sh`) emit a `kind=reaper_run` event into `.chump-locks/ambient.jsonl` on every run with `status=ok|fail` and per-reaper counts. They also stamp `/tmp/chump-reaper-<name>.heartbeat` (`pr` / `worktree` / `branch`). Each reaper rotates its own `/tmp/chump-stale-*-reaper.{out,err}.log` to a single `.1` archive at 5MB so logs never grow unbounded.

A separate watchdog grades the heartbeats and ALERTs the fleet when a reaper goes silent:
- **Watchdog:** `scripts/ops/reaper-heartbeat-watchdog.sh` — emits `ALERT kind=reaper_silent` into `ambient.jsonl` when a reaper hasn't heartbeated in 2h (pr), 4h (worktree), or 48h (branch) — i.e. ~2-4× the launchd cadence per the gap acceptance criteria. Visible in the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`.
- **macOS install (do this once per dogfood machine):** `scripts/setup/install-reaper-watchdog-launchd.sh` — runs every 30 min. **Verify:** `launchctl list | grep dev.chump.reaper-watchdog`. **Disable:** `launchctl unload ~/Library/LaunchAgents/dev.chump.reaper-watchdog.plist`.
- **Manual check:** `scripts/ops/reaper-heartbeat-watchdog.sh` (no flags) prints per-reaper status and exits 0 even with ALERTs (so launchd doesn't loop on it).
- **Quickly grep the stream:** `tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"reaper_(run|silent)"'`.

## ambient.jsonl rotation (INFRA-122, 2026-05-02)

`.chump-locks/ambient.jsonl` is the file-side of the peripheral-vision stream and is appended-to by every agent on every event. Without rotation it grows ~4MB/day under fleet load and reaches multi-GB over a few weeks.

- **Rotation script:** `scripts/dev/ambient-rotate.sh` — keeps `AMBIENT_RETAIN_DAYS` (default 7) of events in-place, archives older events to `.chump-locks/ambient.jsonl.YYYY-MM-DD.gz`, and writes a `{"event":"rotated",...}` summary line.
- **macOS install (do this once per dogfood machine):** `scripts/setup/install-ambient-rotate-launchd.sh` — runs the rotate script daily at 03:00 local. **Verify:** `launchctl list | grep dev.chump.ambient-rotate`. **Logs:** `/tmp/chump-ambient-rotate.{out,err}.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/dev.chump.ambient-rotate.plist`.
- **Self-monitoring:** if `ambient.jsonl` exceeds `AMBIENT_SIZE_ALERT_MB` (default 50MB), the rotate script emits an `ALERT kind=ambient_oversize` event into the stream itself — visible during the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`. Catches the case where rotation isn't installed or the schedule broke.
- **Querying historical data:** `scripts/dev/ambient-query.sh` transparently reads from the live log + all rotated `.gz` archives in chronological order. Use `--since 24h` to bound the search.

## Overnight research scheduler (INFRA-114, 2026-04-26)

Research churn (eval sweeps, A/B studies, ablations) runs overnight, not during the workday. Daytime is for the dispatcher and agent work.

- **Drop-in directory:** `scripts/overnight/` — every executable `*.sh` runs in lex order. Rename to `*.disabled` to skip.
- **Wrapper:** `scripts/eval/run-overnight-research.sh` — 1h per-job timeout, lockfile guard, per-run logs in `.chump/overnight/<run-id>.log`, emits `overnight_start` / `overnight_done` / `overnight_job_fail` to `ambient.jsonl`.
- **macOS install:** `scripts/setup/install-overnight-research-launchd.sh` (default 02:00 daily; override with `CHUMP_OVERNIGHT_HOUR`/`CHUMP_OVERNIGHT_MINUTE`).
- **On-demand smoke test:** `launchctl start dev.chump.overnight-research` after install, then `tail /tmp/chump-overnight-research.out.log`.
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
| out-of-scope (INFRA-189, 2026-05-01; INFRA-337 subagent-enforce, 2026-05-02) | pre-commit | MY lease declares `paths` and I'm staging files OUTSIDE that scope | `CHUMP_SCOPE_CHECK=0` (disable) / `CHUMP_SCOPE_CHECK=warn` (force warn) / `CHUMP_SCOPE_CHECK=enforce` (force block) | wrong-worktree commits + cross-fixture leaks (INFRA-076 class). **Default depends on session origin**: subagent sessions (`session_id` prefix `chump-anon-` or `subagent-`, i.e. Agent-tool spawns) default to **enforce** — out-of-scope edits in narrowly-dispatched subagents are almost always hallucinated/scope-creep and cheap to retry (META-025 dispatch-quality finding). Operator-driven sessions default to **warn** to preserve ergonomics during the INFRA-189 false-positive observation window. Only triggers when the lease has a non-empty `paths` field — agents that don't declare scope still work as before. Test: `scripts/ci/test-scope-check-subagent-enforce.sh`. |
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

## Spawning subagents (META-025 / INFRA-332, 2026-05-02)

**Self-ship rate baseline: 25-33%.** Across this session and historical
`chump_improvement_targets` telemetry, subagents that produce work
self-ship the resulting PR only 25-33% of the time. Work-quality of
output (when produced) is high — the failure is at the ship-stage
hand-off, not at cognition. Most stalls are `bot-merge.sh` hanging on
the INFRA-275 syspolicyd binary wedge.

**Two disciplines fix this:**

1. **Every Agent-tool prompt MUST include the standard shipping
   epilogue.** Verbatim copy from
   [`scripts/dispatch/subagent-shipping-epilogue.md`](scripts/dispatch/subagent-shipping-epilogue.md).
   The epilogue covers: bot-merge canonical path, `chump-binary-unwedge.sh`
   heal, manual `git push + gh pr create + gh pr merge` fall-back path,
   forbidden anti-patterns (silent YAML fallback, `--no-verify`),
   and the final-report format. Full context and anti-patterns are in
   [`docs/process/SUBAGENT_DISPATCH.md`](docs/process/SUBAGENT_DISPATCH.md).
   The single subagent in this session that did self-ship was the one
   whose briefing included these explicit fall-back instructions.

2. **`Agent` vs `SendMessage` discipline.** `Agent` spawns a fresh
   subagent with no memory of prior runs — use it for new work.
   `SendMessage` resumes an existing subagent by `agentId` — use it to
   continue, ask for status, or unblock a stuck agent. **Never use
   `Agent` to check on an existing subagent** — you waste a slot and
   get a "fresh session, no context" response. (Mistake observed
   2026-05-02 in the very session that produced this rule.) See
   [`docs/gaps/DOC-015.yaml`](docs/gaps/DOC-015.yaml).

When you write a subagent prompt: think of it as briefing a smart
colleague who just walked into the room — they haven't seen the
conversation, don't know what you've tried. Self-contained briefing,
explicit file paths to read, explicit success criteria from the gap,
explicit shipping epilogue.

**INFRA-419 reaper:** flags subagents that exceed `CHUMP_SUBAGENT_BUDGET_MIN`
(default 30 tool calls) without invoking `bot-merge.sh`.

## Fleet launcher (INFRA-203, canonical entry point)

`scripts/dispatch/run-fleet.sh` is the canonical way to spawn N parallel
Claude Code agents on this repo. It opens a tmux session with one control
pane (live status) plus N worker panes; each worker loops:
pick-gap → claim → worktree → spawn `claude -p` → ship via `bot-merge.sh` →
release → loop. The `claude -p --dangerously-skip-permissions` invocation
matches `WorkBackend::Headless` from `src/dispatch.rs` (INFRA-191 Phase 2).

```bash
scripts/dispatch/run-fleet.sh                         # default FLEET_SIZE=8
FLEET_SIZE=4 scripts/dispatch/run-fleet.sh
FLEET_DOMAIN_FILTER=INFRA scripts/dispatch/run-fleet.sh   # INFRA-only fleet
FLEET_DRY_RUN=1 scripts/dispatch/run-fleet.sh             # print plan, exit
FLEET_SIZE=0 scripts/dispatch/run-fleet.sh                # tear down
tmux attach -t chump-fleet                                # watch the panes
```

Knobs (all env): `FLEET_SIZE`, `FLEET_TIMEOUT_S` (per-agent claude timeout,
default 1800s), `FLEET_PRIORITY_FILTER` (default `P0,P1`),
`FLEET_DOMAIN_FILTER` (default any; use for INFRA-206-style domain affinity),
`FLEET_EFFORT_FILTER` (default `xs,s,m`), `FLEET_SESSION` (tmux session name,
default `chump-fleet`), `FLEET_LOG_DIR` (default `/tmp/chump-fleet-<sid>`),
`CARGO_TARGET_DIR` (auto-set to a shared `target/` per INFRA-210 to avoid
per-worktree multi-GB rebuilds).

**Poll-jitter + idle-backpressure (INFRA-315, 2026-05-03).** Without
randomization, sibling workers' poll loops phase-lock and stampede the
same gap. Observed live in the 2026-05-02 cascade fleet run: 4 workers
all picked `INFRA-187` because they polled at the same instant, and 3 of
4 hit "worktree create failed" before chump-local even spawned. Default
±30% randomization breaks the synchronization. After
`CHUMP_STARVE_THRESHOLD` consecutive empty picks (default 3), each worker
emits `kind=fleet_starved` to `ambient.jsonl` so the operator sees the
quiet fleet is starved (filters too tight, queue empty) instead of
guessing. Knobs: `CHUMP_POLL_JITTER` (% randomization, default 30),
`CHUMP_STARVE_THRESHOLD` (consecutive empties before ALERT, default 3).
Aggregate view: `scripts/dispatch/fleet-status.sh --pane starvation` —
shows last-24h `fleet_starved` count per agent + per filter combination,
so a tight `FLEET_DOMAIN_FILTER` accumulating all the events IS the
diagnosis.

Auto-pickup excludes `EVAL-*`, `RESEARCH-*`, `META-*` (those need human
judgment) and any gap with non-empty `depends_on`. Smoke test:
`scripts/ci/test-run-fleet-smoke.sh`.

**INFRA-420 cost guard:** `FLEET_BACKEND=claude` is refused without
`CHUMP_FLEET_ALLOW_CLAUDE_BACKEND=1` — Opus is ~50× haiku per token and
has burned workspace credit caps in prior sessions.

## Coordination docs

- `.chump/state.db` — **canonical** gap registry (SQLite, since INFRA-059); accessed via `chump gap …` subcommands
- `docs/gaps/<ID>.yaml` — human-readable per-file mirror (post-INFRA-188; the legacy monolithic `docs/gaps.yaml` was deleted), regenerated by `chump gap set/ship/dump`; commit alongside DB mutations so PRs are reviewable
- `.chump/state.sql` — readable diff of the SQLite schema/data; regenerate with `chump gap dump --out .chump/state.sql` after merge conflicts
- `docs/process/AGENT_COORDINATION.md` — full coordination system (leases, branches, failure modes, pre-commit spec)
- `docs/process/POST_INFRA_188_GOTCHAS.md` — short-lived (2026 Q3 prune target) operational gotchas observed during the post-cutover ship wave: `gh run rerun --failed` replays old payloads, `<DOMAIN>-<NUM>:` PR titles trip `gap-status-check`, the 38 lost per-file YAMLs (INFRA-240), `chump gap reserve` writes at outer `repo_root()` not linked-worktree CWD (INFRA-247), and the `chump` vs `chump-coord` binary path split. Read once at session start during the cleanup window; the doc auto-prunes when `scripts/audit/check-post-infra-188-gotchas-prunable.sh` returns 0.
- `chump gap preflight` — gap availability check (reads lease files + checks done on main); Rust-based replacement for deprecated `scripts/coord/gap-preflight.sh`
- `chump claim` — write a gap claim to your session's lease file; Rust-based replacement for deprecated `scripts/coord/gap-claim.sh`
- `scripts/coord/bot-merge.sh` — ship pipeline (calls `chump claim` automatically)
- `scripts/coord/gap-doctor.py` — drift detector + repair tool (INFRA-155). Compares `.chump/state.db` against `docs/gaps/<ID>.yaml` files (post-INFRA-188; previously the monolithic `docs/gaps.yaml`) and reports four buckets: DB done / YAML open (regen YAML), DB open / YAML done (sync DB from YAML), DB-only orphans, YAML-only ghosts. Run `gap-doctor.py doctor` for a read-only report; `sync-from-yaml --apply` drains pre-INFRA-152 hand-edit drift; `sync-from-db --apply` regenerates YAML from DB. The 2026-04-28 first run drained 25 status:open-but-actually-done rows in one shot.
- `scripts/ops/stale-pr-reaper.sh` — runs hourly, auto-closes PRs whose gaps landed on main. **INFRA-1195 freshness gate (2026-05-14)**: before auto-closing, the reaper checks the PR's `updatedAt` timestamp. If updated within `CHUMP_CURATOR_FRESHNESS_MIN` minutes (default 10), the close is **skipped** and a `kind=curator_skip_active_rebase` event is emitted to `ambient.jsonl`. This prevents false-closes during active rebase/force-push windows. Bypass: `CHUMP_CURATOR_FRESHNESS_MIN=0`. If you see these events but the PR is genuinely stale, wait for the freshness window to expire or close manually.
- `scripts/ops/stuck-pr-filer.sh` — INFRA-307, hourly. Detects stuck PRs (DIRTY > 4h, required CI red > 2h, BEHIND > 20 commits, or auto-merge disarmed with no live owner lease) and **files them as INFRA P1 cleanup gaps** so `run-fleet.sh` picks them up under default filters. This replaces the human-as-relay loop ("agent A's PR #472 is stuck — please tell A"): the cleanup work belongs to whoever the fleet picks up next, not the original (often-exited) author. De-dups by title (`PR #N stuck — …`); skips drafts, dependabot, and `chore(gaps): file/reserve …` PRs. Emits `ALERT kind=pr_stuck` to ambient and is graded by the reaper-heartbeat-watchdog. Bypass: `CHUMP_STUCK_PR_FILER=0`. macOS install: `scripts/setup/install-stuck-pr-filer-launchd.sh`. Test: `scripts/ci/test-stuck-pr-filer.sh`.
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
chump gap restore --from-sql              # rebuild state.db from .chump/state.sql when DB is corrupted (INFRA-538)
```

### state.db corruption recovery (INFRA-538)

If `.chump/state.db` is corrupted or missing but `.chump/state.sql` (the tracked YAML mirror) is intact:

```bash
# Verify state.sql exists and has content
wc -l .chump/state.sql

# Rebuild state.db from the YAML mirror.
# Automatically backs up existing state.db → state.db.bak before overwriting.
chump gap restore --from-sql

# Verify the row count looks right
sqlite3 .chump/state.db "SELECT COUNT(*) FROM gaps"

# Optional: re-import per-file docs/gaps/ YAMLs to pick up any gaps added
# since the last state.sql regen
chump gap import
```

If `state.sql` is also corrupted or out of date, fall back to rebuilding from the per-file YAML mirrors in `docs/gaps/`:
```bash
# Remove corrupted state.db and rebuild from scratch via import
rm .chump/state.db
chump gap import   # seeds a fresh state.db from docs/gaps/*.yaml
```

## Doctor / health / fleet-status — which entry point does what (INFRA-1218)

Four similarly-named entry points; pick the right one for the symptom:

| Tool | Purpose | When to use |
|---|---|---|
| `scripts/dev/chump-binary-unwedge.sh` | Heal the wedged-inode `_dyld_start` hang (INFRA-275) | `chump gap …` hangs, `ps` shows `UE` processes |
| `chump --doctor` (Rust subcommand) | Config + environment sanity report | Setup verification, "is my env wired right" |
| `chump fleet doctor` (Rust subcommand) | Fleet-wide health report — agents, leases, queue | Operator daily check / dashboards |
| `chump health` (Rust subcommand) | SLO-style metrics digest, fleet pillar grades | KPI / pillar-balance review |
| `scripts/dispatch/fleet-status.sh` | Operator-facing tmux dashboard (panes) | Interactive monitoring |
| `scripts/dispatch/fleet-status.sh --once` | Single-pane snapshot to stdout | CI / unattended loops / `scripts/dev/fleet-status.sh` is a shim for this |

The `chump-doctor` *concept* (env vars like `CHUMP_DOCTOR_SKIP`, the heal pattern, the binary-probe preflight) is still named `chump-doctor` everywhere — INFRA-1218 only renamed the script *file* from `chump-doctor.sh` to `chump-binary-unwedge.sh` to disambiguate the filename from `chump --doctor`. The Rust subcommand and the wedge-recovery script have different jobs; their names should reflect that.

## Known error classes — self-help index (INFRA-590)

Scripts append `See: docs/process/CLAUDE_GOTCHAS.md#<anchor>` to high-frequency
errors so you can jump directly to the recovery steps. The four anchored classes:

<a id="error-binary-wedge"></a>
### error-binary-wedge — chump binary wedged by syspolicyd

**Symptom:** `chump gap …` hangs indefinitely (no output, never exits). `ps` shows
chump processes in state `UE` (uninterruptible exit). Direct `sqlite3 .chump/state.db`
works — the DB is fine, the binary is wedged at `_dyld_start`.

**Root cause:** macOS Sequoia's `syspolicyd` (Gatekeeper) gets the binary's inode into a
pending-decision queue; every subsequent launch of the same inode blocks behind it.

**Recovery:**
```bash
scripts/dev/chump-binary-unwedge.sh                     # probe + replace wedged inode (preferred)
CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-binary-unwedge.sh  # skip probe, just heal
# Nuclear (needs sudo): sudo kill syspolicyd
```
The doctor moves the wedged binary to `~/.cargo/bin/chump.wedged-inode-<n>` and copies
content back through a fresh inode that syspolicyd treats as new. Zombie UE processes
clear on reboot but are otherwise harmless. Rebuild if doctor fails:
```bash
cargo build --release --bin chump && cp target/release/chump ~/.local/bin/chump
```

<a id="error-gap-collision"></a>
### error-gap-collision — gap already claimed or open PR exists

**Symptom:** `gap-preflight.sh` or `bot-merge.sh` exits with "SKIP <GAP-ID> — open PR
#N … is already implementing this gap" or "claimed by session …".

**Root cause:** Another agent (or a prior session of yours) is actively working this
gap. Picking the same gap produces wasted compute and a merge collision.

**Recovery:**
```bash
chump gap list --status open              # find a different pickable gap
# If the existing PR is abandoned and you own it:
CHUMP_PREFLIGHT_PR_CHECK=0 scripts/coord/gap-preflight.sh <GAP-ID>
# To race intentionally (INFRA-193):
CHUMP_SPECULATIVE=1 scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

<a id="error-missing-closed-pr"></a>
### error-missing-closed-pr — status:done committed without a real PR number

**Symptom:** pre-commit exits with "INCOMPLETE CLOSURE (INFRA-107) — gap(s) flipped to
status:done with missing or non-numeric closed_pr".

**Root cause:** A `docs/gaps/<ID>.yaml` file was hand-edited to `status: done` without
setting `closed_pr` to a real PR number (or it was set to `TBD`). The guard requires an
actual numeric PR number so the registry is auditable.

**Recovery:**
```bash
# Use the canonical ship path instead of hand-editing:
chump gap ship <GAP-ID> --closed-pr <PR-NUMBER> --update-yaml
# If you must hand-edit, set the field explicitly:
#   closed_pr: 404   ← real numeric PR number, not TBD
# Bypass (escape hatch only):
CHUMP_GAPS_LOCK=0 git commit ...
```

<a id="error-wrong-worktree"></a>
### error-wrong-worktree — refusing to claim gap in the main worktree

**Symptom:** `gap-claim.sh` exits with "ERROR: refusing to claim gap in the main
worktree."

**Root cause:** You ran `gap-claim.sh` (or `bot-merge.sh`, which calls it) from the
primary repo checkout instead of a linked worktree. Concurrent agents share the same
`.chump-locks/` dir in the main checkout, causing lease ID collisions.

**Recovery:**
```bash
# Create a linked worktree and re-run from there:
git worktree add .claude/worktrees/<name> -b chump/<name> origin/main
cd .claude/worktrees/<name>
scripts/coord/gap-claim.sh <GAP-ID>
# Bootstrap escape hatch (short-lived solo work only):
CHUMP_ALLOW_MAIN_WORKTREE=1 scripts/coord/gap-claim.sh <GAP-ID>
```

---

<a id="worktree-path-confusion"></a>
### worktree-path-confusion — macOS /tmp → /private/tmp symlink corrupts gitdir (INFRA-779)

**Symptom:** Inside a linked worktree, `git rev-parse --show-toplevel` returns
the wrong path (the main checkout or a sibling worktree path). Git commands
operate on the wrong tree, silently staging or committing to the wrong branch.

**Root cause:** On macOS, `/tmp` is a symlink to `/private/tmp`. When
`git worktree add /tmp/chump-infra-NNN` is run, git records the worktree in
`.git/worktrees/chump-infra-NNN/gitdir` as `/tmp/chump-infra-NNN/.git`. But the
worktree's actual path on disk is `/private/tmp/chump-infra-NNN`. Concurrent
sibling claims can overwrite each other's gitdir back-reference.

**Symptoms in practice:**
- `git status` shows another gap's files
- `git add` stages to the wrong branch
- `git log` shows a commit history from a different worktree

**Recovery:**
```bash
# 1. Identify the correct worktree name:
git worktree list | grep <gap-id>
# 2. Repair the gitdir back-reference (INFRA-779 fix):
echo "/private/tmp/chump-infra-NNN/.git" \
    > /Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN/gitdir
# 3. Verify the fix (env vars on one line so the shell expands both before git runs):
GIT_DIR=/Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN GIT_WORK_TREE=/private/tmp/chump-infra-NNN git status
# 4. Use explicit vars for all git commands in that worktree session:
GIT_DIR=/Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN GIT_WORK_TREE=/private/tmp/chump-infra-NNN git add <files>
GIT_DIR=/Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN GIT_WORK_TREE=/private/tmp/chump-infra-NNN git commit -m "..."
```

**Prevention:** `chump claim` auto-runs the gitdir repair since INFRA-779.
If claiming manually via `gap-claim.sh`, add the repair step immediately after
`git worktree add`.

---

<a id="stale-lease-cleanup"></a>
### stale-lease-cleanup — detecting and releasing orphaned leases

**Symptom:** `gap-preflight.sh` or `chump claim` reports "lease conflict" but no
agent is actively working the gap. The lease file exists in `.chump-locks/` but
the process that wrote it is no longer running.

**Root cause:** An agent crashed, timed out, or was killed before it could call
`chump --release`. The lease file persists because it is written atomically but
never cleaned up.

**Detecting orphaned leases:**
```bash
# List all active leases:
ls .chump-locks/claim-*.json
# For each lease, check if the holding process is alive:
python3 -c "
import json, os, sys
for f in sorted(os.listdir('.chump-locks')):
    if not f.startswith('claim-'): continue
    d = json.loads(open('.chump-locks/' + f).read())
    pid = int(f.split('-')[2])  # PID is encoded in filename
    alive = os.path.exists(f'/proc/{pid}') or not os.system(f'kill -0 {pid} 2>/dev/null')
    print(f'{\"ALIVE\" if alive else \"DEAD\":6} pid={pid} gap={d.get(\"gap_id\",\"?\")} session={d[\"session_id\"]}')
"
# macOS equivalent (no /proc):
for f in .chump-locks/claim-*.json; do
    pid=$(basename "$f" .json | cut -d- -f3)
    if kill -0 "$pid" 2>/dev/null; then echo "ALIVE pid=$pid $f"
    else echo "DEAD  pid=$pid $f"; fi
done
```

**Releasing a stale lease:**
```bash
# Safe release (verifies session matches):
chump --release --lease .chump-locks/claim-<gap>-<pid>-<ts>.json
# If chump --release fails, remove manually after confirming process is dead:
kill -0 <pid> 2>/dev/null && echo "still alive!" || rm .chump-locks/claim-<gap>-<pid>-<ts>.json
```

**When to release:**
- Process dead (kill -0 returns nonzero) and heartbeat is stale (> 10 min old)
- Worktree was removed with `git worktree remove --force` but lease file remains
- CI/CD orphaned a claim after a timeout

**When NOT to release:**
- Process is still alive — the agent may be mid-commit or awaiting CI
- You are not sure — check ambient.jsonl for recent events from that session first

---

<a id="event-registry-bypass"></a>
### event-registry-bypass — bypassing the EVENT_REGISTRY pre-commit guard (INFRA-754)

**Symptom:** Pre-commit hook rejects your commit with:
```
[event-registry] ERROR: kind 'my_new_event' appears in staged diff but is NOT registered
[event-registry] Add an entry to docs/observability/EVENT_REGISTRY.yaml before committing.
```

**Root cause:** You added a new `"kind":"my_new_event"` literal in a script or
Rust source, but didn't register it in the event registry. The guard is
pattern-based: any `"kind":"X"` string literal in the staged diff triggers it.

**Correct fix — always preferred:**
1. Add an entry to `docs/observability/EVENT_REGISTRY.yaml`:
```yaml
  - kind: my_new_event
    emitter: scripts/coord/my-script.sh (INFRA-NNN)
    trigger: one-line description of when this fires
    consumers: [fleet-brief, watchdog]
    fields_required: [ts, kind, <other fields>]
```
2. Stage the YAML alongside your other changes and commit.

**Bypass (test fixtures and rare cases only):**
```bash
# Set the bypass env var AND add a trailer to the commit body:
CHUMP_OBS_BUDGET_BYPASS=1 git commit -m "$(cat <<'EOF'
fix: my change

Obs-Bypass-Reason: test fixture only — kind=my_test_event never emitted in production
EOF
)"
```

**Bypass discipline:**
- Only bypass for test fixtures or when the kind is intentionally not registered
- The `Obs-Bypass-Reason` trailer is mandatory — the audit log searches for it
- Never bypass for production event kinds — register them properly instead
- If you find yourself bypassing repeatedly for a real kind, the fix is to register it

---

### ci-yml merge-driver orphan step (INFRA-1199)

**Symptom:** After rebasing, `.github/workflows/ci.yml` ends with a dangling step:
```yaml
      - name: gap-reserve concurrency (INFRA-021)
```
…with no `run:` or `uses:` body. GitHub Actions rejects the file with
*"This run likely failed because of a workflow file issue"* — zero CI jobs run,
no checks appear, the PR is permanently blocked.

**Root cause:** The `scripts/git/merge-driver-ci-yml-add-row.sh` custom merge
driver resolves ci.yml conflicts by appending the lines theirs-branch added
beyond the common ancestor. If the theirs-branch's version of ci.yml contained
an incomplete step (a `- name:` header without a `run:` body), the driver
blindly appended it. As of INFRA-1199, the driver detects this via
`validate_step_bodies()` and exits 1 (falls back to standard 3-way merge)
instead of writing the orphan step.

**If you hit this before the fix is deployed:**
```bash
# Remove the trailing orphan step manually
# Open .github/workflows/ci.yml in your editor and delete the dangling '- name:' line at the end
git add .github/workflows/ci.yml
git commit --amend --no-edit
```

**Permanent fix:** INFRA-1199 landed in `scripts/git/merge-driver-ci-yml-add-row.sh`.
If you see this after INFRA-1199, check that:
1. The driver script is the INFRA-1199 version (`grep 'INFRA-1199' scripts/git/merge-driver-ci-yml-add-row.sh`)
2. The merge driver attribute is registered in `.gitattributes`

---

## Fleet git worktree path confusion (INFRA-779)

**Problem:** On macOS, `/tmp` is a symlink to `/private/tmp`. When a linked worktree
is created at `/tmp/chump-<name>`, its `gitdir` back-pointer records the path as
`/private/tmp/chump-<name>/.git`. If a concurrent sibling agent has a worktree nested
inside the main project (e.g. `.chump/worktrees/infra-855-dedup`), git's internal
path resolution can resolve `git rev-parse --show-toplevel` to the WRONG worktree
directory. This causes `REPO_ROOT` to point at a sibling's tree, leading `bot-merge.sh`
to push from the wrong branch, pre-commit hooks to operate on wrong files, and
`state.db` lookups to hit a stale copy.

**Symptoms:**
- `bot-merge.sh` header shows wrong branch: `=== bot-merge: chump/infra-855-dedup → main ===`
  even though the lease is for a different gap.
- `gap-preflight.sh` says gap "not found in gap registry" but it IS in the main
  `state.db`.
- `git branch --show-current` from the worktree returns the correct branch, but
  `git rev-parse --show-toplevel` returns a different worktree's path.

**Recovery (per-command):**
```bash
# Set explicit GIT_DIR + GIT_WORK_TREE for all git operations in the worktree.
# Replace chump-infra-918 with your worktree name.
GIT_DIR=/Users/jeffadkins/Projects/Chump/.git/worktrees/chump-infra-918 \
GIT_WORK_TREE=/private/tmp/chump-infra-918 \
  git <cmd>

# For bot-merge, pass env vars before the invocation:
cd /private/tmp/chump-infra-918
GIT_DIR=/Users/jeffadkins/Projects/Chump/.git/worktrees/chump-infra-918 \
GIT_WORK_TREE=/private/tmp/chump-infra-918 \
  bash scripts/coord/bot-merge.sh --gap INFRA-918 --auto-merge
```

**Prevention:**
`chump claim` now runs `git worktree repair` after `git worktree add` to fix the
gitdir back-pointer. If you create worktrees manually, run:
```bash
git -C /Users/jeffadkins/Projects/Chump worktree repair
```

**Diagnosis:**
```bash
# Check what git thinks the toplevel is vs what it should be:
cd /private/tmp/chump-<name>
git rev-parse --show-toplevel        # may return wrong path
git rev-parse --absolute-git-dir     # should be .git/worktrees/chump-<name>
cat $(git rev-parse --absolute-git-dir)/gitdir   # should be /private/tmp/chump-<name>/.git
```

---

## cargo test must not inherit parent shell git env (INFRA-1057)

**Problem:** When `cargo test --bin chump --tests` is run from a linked `/tmp/` worktree,
tests that spawn git subprocesses (e.g. `make_repo()`, `scan_rescues()`, git init fixtures)
inherit `GIT_DIR` / `GIT_WORK_TREE` / `GIT_COMMON_DIR` / `GIT_INDEX_FILE` from the parent
shell. This causes those git calls to operate on the main repo's `.git/config` instead of
the isolated tempdir, producing config-lock errors, identity-guard failures, or wrong
results (e.g. rescue-tally counting commits from the main repo instead of 0).

**Rule:** Any test or production function that spawns a git subprocess with `Command::new("git")`
and intends to operate on a specific directory must clear the four git env vars:

```rust
Command::new("git")
    .args(...)
    .current_dir(&some_tempdir)
    .env_remove("GIT_DIR")
    .env_remove("GIT_WORK_TREE")
    .env_remove("GIT_COMMON_DIR")
    .env_remove("GIT_INDEX_FILE")
    // Only for commits using t@t.t / ci@chump.test fixture identities:
    .env("CHUMP_GIT_IDENTITY_CHECK", "0")
    .output()
```

**CI gate:** `scripts/ci/test-cargo-tests-from-worktree.sh` spawns a fresh linked
worktree and runs the targeted test modules; it must pass on every PR.

**Symptoms of missing env_remove:**
- `git init` locks `/Users/.../Projects/Chump/.git/config` instead of the tempdir
- `rescue_tally::infra667_count_rescues_returns_zero_on_empty_repo` returns non-zero
- version tests fail with "git config failed" or INFRA-787 identity guard error
- Tests pass in isolation but fail when run from a linked `/tmp/` worktree

---

## Stale lease cleanup

**Problem:** When `bot-merge.sh` fails mid-run (test failure, rebase conflict, OOM),
it may leave a `.chump-locks/<session>.json` lease file behind. The next `chump claim`
on the same gap will fail with "lease conflict" because the old lease still exists.

**As of INFRA-919**, `bot-merge.sh` installs an EXIT trap that deletes the lease on
any exit. If you are on an older `bot-merge.sh` or the trap failed, use the following:

**Detecting orphaned leases:**
```bash
# List all active leases with their gap IDs and ages:
ls -la .chump-locks/*.json 2>/dev/null
# Check if the gap the lease claims is still truly open/in-progress:
cat .chump-locks/<session>.json | python3 -m json.tool
```

**Releasing a stale lease:**
```bash
# Preferred — idempotent, updates ambient.jsonl:
chump --release --lease .chump-locks/<session>.json

# Manual fallback if chump is wedged:
rm .chump-locks/<session>.json
```

**After cleanup, verify the gap can be reclaimed:**
```bash
scripts/coord/gap-preflight.sh <GAP-ID>   # should pass
chump claim <GAP-ID>
```

**Preventing future orphans:** Run `chump-binary-unwedge.sh` after any failed `bot-merge.sh`
invocation — it now reaps stale leases along with zombie processes.

---

## EVENT_REGISTRY pre-commit guard bypass (INFRA-755 / CHUMP_OBS_BUDGET_BYPASS)

**Problem:** The observability budget guard (`INFRA-755`) blocks commits that add
> 50 lines of feature code (`.rs/.sh/.py`) without adding at least one observability
hook (`tracing::info!`, ambient event, or `chump_improvement_targets` lesson). This
prevents "dark" features that can't be diagnosed from `ambient.jsonl`.

**When to bypass:** Only when the new code IS itself an observability tool (e.g.
`chump-doctor --probe-resources`), a test, or infrastructure that by design has no
observable runtime path (e.g. build scripts, CI fixtures).

**How to bypass correctly:**
```bash
# 1. Add a bypass reason trailer to the commit body:
CHUMP_OBS_BUDGET_BYPASS=1 git commit -m "$(cat <<'EOF'
feat(infra-395): chump-doctor --probe-resources substrate check

<body text>

Obs-Bypass-Reason: probe_resources() is itself an observability tool —
its stderr output IS the observable signal for fleet operators.
EOF
)"

# 2. Verify the trailer is in the commit:
git log -1 --format="%B" | grep "Obs-Bypass-Reason"
```

**When NOT to bypass:**
- New `claude -p` dispatch paths without a corresponding ambient event.
- New gap-filing or claim logic without `kind=<name>` event emission.
- Error handlers that silently swallow exceptions.

In those cases, add the observability hook first, then commit normally.
The registered event kinds are in `docs/process/EVENT_REGISTRY.md`; new
kinds must be registered there before use (pre-commit guard enforces this).

## CI cascade-cancel pattern (INFRA-1002)

**Symptom:** CI reports `fast-checks=failure cargo-test=cancelled` and the PR check is red.
An agent (or operator) looking at this sees "multiple things broken" when really there is
ONE real failure (`fast-checks`) and ONE cascade-cancel (`cargo-test` was preempted by the
earlier failure, not because anything tested by `cargo-test` is actually broken).

**Why it happens:** GitHub Actions cancels downstream shards when a parallel shard fails.
The cancelled shard's result shows as `cancelled`, not `skipped`, so it looks like a second
independent failure.

**How the rollup classifies results (INFRA-1002):**
```
cascade_cancel: result == 'cancelled' AND at least one peer == 'failure'
real_failure:   result == 'failure'
               OR result == 'cancelled' AND no peer == 'failure'
```

**What to do:**
1. Read the rollup's `=== INFRA-1002 shard classification ===` block in the CI log.
2. Fix only the `real_failures` list. Cascade-cancelled shards will auto-recover when
   the real failure is fixed and you push again — they are NOT independent bugs.
3. Do NOT assume `N cancelled` means `N bugs`. Cascade-cancels are collateral damage.

**Retry scope for INFRA-1003 (auto-rerun):**
The auto-rerun gate uses `real_failures` (not `cascade_cancels`) to decide which tests
to rerun. A cascade-cancel is benign for retry purposes — only the root failure needs
investigation.

**Test fixture:** `scripts/ci/test-rollup-cascade-cancel.sh` (7 assertions).

## e2e-pwa shadow DOM traversal — `#msg-input` locator pattern (INFRA-817, INFRA-1018, INFRA-1066)

**Symptom:** Five e2e-pwa Playwright tests time out waiting for `page.locator("#msg-input")`.
Output: `Timeout 30000ms exceeded … Locator: locator('#msg-input') … waiting for element to be visible`.
The tests are: "loads home", "navigate between views", "mobile viewport",
"/task creates assistant reply", "New chat clears thread".

**Root cause (regressed 2026-05-13, ~2h red-main):**
`web/v2/index.html` has a V1→V2 backward-compat shim (`createTestAliases()`) that aliases
`<chump-chat>`'s internal `#input` element to `#msg-input` at the top level so Playwright can
find it without shadow-piercing selectors.  The shim broke when code used:
```javascript
viewChat.shadowRoot?.querySelector('chump-chat')  // WRONG — viewChat has NO shadow root
```
`<chump-view-chat>` uses **light DOM** (`this.innerHTML = '...'`), so `.shadowRoot` is always
`null` and optional chaining short-circuits silently.  The alias never ran; `#msg-input`
was never created; all 5 tests timed out.

**Correct traversal (INFRA-1018 fix, merged a87d8e8b):**
```javascript
const viewChat   = document.querySelector('chump-view-chat');
const chumpChat  = viewChat?.querySelector('chump-chat');     // light DOM child
const input      = chumpChat?.shadowRoot?.getElementById('input'); // chump-chat HAS shadow root
if (input && input.id !== 'msg-input') input.id = 'msg-input';
```
Rule: **`<chump-view-chat>` is light DOM; `<chump-chat>` is shadow DOM.**
Always traverse light DOM to reach `<chump-chat>`, then use `.shadowRoot` for its internals.

**Retry loop (also required):**
`<chump-chat>`'s shadow root is populated in `connectedCallback()`, which fires asynchronously
relative to `DOMContentLoaded`.  A single `DOMContentLoaded` handler may run before the
shadow root exists.  The shim must retry every 100 ms until the alias is live:
```javascript
function scheduleTestAliases() {
  if (createTestAliases()) return;
  setTimeout(scheduleTestAliases, 100);
}
```

**Pre-commit guard:** none yet (INFRA-1066 AC #6, optional).
If you add e2e selectors that need shadow piercing, use Playwright's `>>>` shadow-piercing
combinator (`page.locator('chump-chat >>> #input')`) rather than relying on DOM aliases.

## Parallel-ship: two PRs for the same gap (CREDIBLE-066, 2026-05-14)

When two sessions race to claim and ship the same gap, the resulting two PRs interact with the gate machinery in non-obvious ways.

**How GitHub closes the losing PR:**  
If the losing PR's head branch is deleted (e.g., `chump claim` cleanup path deletes the old branch via `gh api .../git/refs/heads/... -X DELETE`), GitHub closes the PR automatically within ~1s. The `issues/{n}/events` API shows `event=closed`, `actor=<repo-owner-via-token>`, and `closed_by=null` — **indistinguishable from a manual operator close.**

**Which gates fire:**

| Gate | When it fires | Does it catch parallel-ship? |
|---|---|---|
| INFRA-1219 (pr-create dedup) | At `gh pr create` time | Yes — if the first PR is still open when the second is created |
| INFRA-1139 (orphan-pr-closer) | On a schedule (cron-like) | Yes — if gap becomes `done` while the losing PR is still open |
| INFRA-1220 (cooldown stamp) | When orphan-pr-closer closes a PR | No — branch-deletion close bypasses the stamp |

**What to do:**  
- If you delete a branch that backs a PR: expect GitHub to close the PR silently. Check `gh pr view <N> --json state` to confirm.
- If you reclaim a gap that had an open PR: let `chump claim` handle branch cleanup; it stamps the cooldown when it detects an existing PR for the gap. Do not manually delete branches without checking for associated open PRs first.
- The dedup gate (INFRA-1219) is the strongest protection: it fires synchronously at `pr create` time and blocks before a second PR exists.

## Auto-merge rollup-FAILURE trap (INFRA-1342, 2026-05-15)

GitHub's `statusCheckRollup.state` is set to `FAILURE` when **any** check on a
commit fails — including non-required checks. When rollup state is FAILURE,
`mergeable_state` flips to `blocked` and auto-merge silently refuses to fire,
even if every branch-protection required context (e.g. `test`, `audit`, `ACP
protocol smoke test`) reports SUCCESS.

**Symptom:** PRs sit with `BLOCKED auto=true`, all `*-required` checks green,
but GitHub won't merge. `gh pr view N --json mergeStateStatus` returns
`"BLOCKED"`. The only hint is that some non-required check has `FAILURE`.

**Root cause discovered:** `tauri-cowork-e2e` flakes with
`TimeoutError: Waiting for element to be located By(css selector, chump-chat)`
on slow GitHub Actions VMs when 18+ `type="module"` scripts delay
`DOMContentLoaded`. Even though `tauri-cowork-e2e` is not in branch protection,
its `FAILURE` conclusion pollutes the overall rollup state.

**Fix (INFRA-1342):** Add `continue-on-error: true` to any CI job that is:
- NOT in branch protection required contexts, AND
- Known to be flaky or environment-sensitive

GitHub treats `continue-on-error: true` jobs as `neutral` in the rollup
even on failure, so `statusCheckRollup.state` stays `SUCCESS`.

```yaml
  my-flaky-job:
    runs-on: ubuntu-latest
    continue-on-error: true   # ← prevents rollup FAILURE on flake
    steps:
      ...
```

**Jobs fixed in INFRA-1342** (all now have `continue-on-error: true`):
- `tauri-cowork-e2e` — Tauri WebDriver flake on slow VMs
- `e2e-pwa` — Ollama + Playwright, environment-sensitive
- `e2e-battle-sim` — lightweight but can time out
- `e2e-golden-path` — cargo build + file-presence checks

**Jobs fixed in INFRA-1348** (full audit of all non-required jobs):
- `changes` — `dorny/paths-filter` can fail transiently (network/runner issue); COE makes failure neutral so downstream jobs safely skip rather than blocking
- `test-e2e` — aggregates e2e shards (which already have COE); COE here guards against runner errors in the aggregator itself

**Ongoing enforcement:** `scripts/ci/test-rollup-not-blocked-by-flaky-job.sh` parses
`ci.yml` and asserts every non-required job has either `continue-on-error: true` or
a PR-trigger exclusion. Run it after any ci.yml change.

**When adding a new CI job:** if it is NOT in branch protection required contexts,
add `continue-on-error: true` to prevent it from blocking fleet-wide auto-merge.

**Workaround when already blocked:** Re-trigger the flaky check.
If it fails again: `gh pr merge <N> --squash --admin` to bypass.
