# Paramedic safety rules (INFRA-1463)

Safety rules for any automated or manual squash/rescue action that mutates a
PR branch's history. These apply to the paramedic daemon (INFRA-1375) and to
the manual "tangled-stack rebase recipe" in
[`CLAUDE_GOTCHAS.md`](./CLAUDE_GOTCHAS.md#tangled-stack-rebase-recipe-infra-1660-2026-05-21).

## The foot-gun: `git reset --soft <main>` on a stale branch

`git reset --soft <ref>` moves `HEAD` to `<ref>` but leaves the index and
working tree untouched. If the branch being reset is older than `<ref>` and
`<ref>` has since gained new files (from unrelated, already-merged PRs), the
resulting `git diff --cached` shows those new files as **deletions** — they
exist in `<ref>` but not in the (stale) working tree. Committing that stage
produces a commit that deletes files it never touched, and squash-merging it
into `main` deletes them there too.

This is silent: `git status` after the reset looks like a normal set of
staged changes, not an error. Nothing about the reset itself fails or warns.

### Incident: PR #2068 (2026-08-28)

A `git reset --soft chump/main` was run to squash an init-leak commit on a
branch that had fallen behind `main`. Between the branch's base and `main`,
a different, already-merged PR had added 38 test files, including
`scripts/ci/test-tauri-filter-scope.sh`. The reset staged all 38 as
deletions; the resulting commit — once pushed and merged — deleted them from
`main`. The deletion was only caught because a later CI run failed on a
missing test script, not because any safety check fired.

## Rules

1. **Never use `git reset --soft <main>` to squash a PR branch that predates
   recent `main` commits.** The paramedic daemon's `SQUASH_INIT_LEAK` action
   (`crates/chump-paramedic/src/paramedic.rs`, `action_squash_init_leak`)
   does not perform an automated squash for this reason — it posts a PR
   comment asking a human to squash, and directs them to
   `git rebase -i --autosquash <main>` or `git filter-repo` with an explicit
   commit-drop, neither of which can silently reintroduce deletions the way
   `reset --soft` can.
2. **Run the safety pre-check before any reset-squash.**
   `scripts/coord/paramedic-safe-squash-check.sh <branch-ref> [<main-ref>]`
   runs `git diff --name-status <branch-ref> <main-ref>` and aborts (exit 1)
   if `main` has more than `CHUMP_SQUASH_SAFETY_MAX_ADDITIONS` (default 5)
   file additions since the branch diverged — exactly the condition that
   would turn a `reset --soft` squash into a mass deletion. Wire this into
   the tangled-stack rebase recipe before running `git reset --soft
   origin/main`:
   ```bash
   scripts/coord/paramedic-safe-squash-check.sh HEAD origin/main || exit 1
   git reset --soft origin/main
   ```
3. **If the check aborts, don't force it.** Fall back to a real
   `git rebase -i --autosquash origin/main` (drop/fixup the leak commit by
   hand) or `git filter-repo` with an explicit commit to drop — both operate
   commit-by-commit and cannot turn an unrelated file addition into a
   deletion.

## Smoke test

`scripts/ci/test-paramedic-no-reset-squash.sh` builds a fixture repo where a
branch and `main` diverge, `main` gains new files after the divergence, and
asserts:

- `paramedic-safe-squash-check.sh` aborts (non-zero exit) when the addition
  count exceeds the threshold, and prints the file(s) that would be deleted.
- `paramedic-safe-squash-check.sh` succeeds when the addition count is at or
  under the threshold.
- The paramedic `SQUASH_INIT_LEAK` action path
  (`action_squash_init_leak` in `crates/chump-paramedic/src/paramedic.rs`)
  contains no `reset --soft` call.
