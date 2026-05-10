# Chump Continual Learning — Agent Session Handoff

This file captures cross-session learnings, discoveries, and operational
patterns for agent-to-agent handoff. Managed by `agents-memory-updater`.
See `AGENTS.md` for the cross-tool convention.

## Session: CREDIBLE-017 exit code standardization (2026-05-10)

### Worktree config misconfiguration

- **Bug**: `.chump/worktrees/credible-017` had `core.worktree` pointing to
  `infra-617` instead of `credible-017` in the worktree-specific git config
  (`.git/worktrees/credible-017/config`).
- **Symptom**: `git rev-parse --show-toplevel` returned the wrong directory,
  breaking `bot-merge.sh`, `chump-commit.sh`, and all git operations in that
  worktree. Any edit appeared in the wrong checkout.
- **Fix**: `GIT_DIR=<path> git config core.worktree /correct/path`
- **Detection**: Run `scripts/coord/check-worktree-config.sh` (INFRA-794).
- **Root cause**: `gap-claim.sh` or `git worktree add` does not validate
  `core.worktree` after creation. Needs fix in the worktree creation flow.

### `chump-commit.sh` index mutex broken on linked worktrees

- **Bug**: `_INDEX_MUTEX="$REPO_ROOT/.git/.chump-index-mutex"` (line 219)
  fails when `.git` is a **file** (linked worktree) instead of a directory.
- **Fix**: Use `$(git rev-parse --git-dir)/.chump-index-mutex` instead.
- **Bypass**: `CHUMP_INDEX_LOCK=0`
- **Filed as**: INFRA-793

### Bot-merge / pre-push test suite timeout

- **Observation**: `bot-merge.sh` ran `cargo test --workspace` (1786 tests)
  with a 3600s timeout. The pre-push hook already scopes to
  `--bin chump --tests` (INFRA-761). Bot-merge was inconsistent.
- **Mitigation**: Changed bot-merge.sh to `cargo test --bin chump --tests`
  with 1200s timeout in INFRA-795.
- **Residual**: Cold cache runs still take 4-6 minutes. sccache helps on
  re-runs. Tree-hash caching in pre-push hook prevents re-runs on same tree.

### Stale WIP cross-contamination

- **Observation**: The INFRA-617 branch's working tree changes (kpi_report.rs,
  pricing reverts, gap yaml) were present in the `credible-017` worktree
  because both worktrees shared the same object store and the `core.worktree`
  misconfig meant git didn't properly isolate them.
- **Fix**: `chump-commit.sh` is designed to prevent this (resets unrelated
  staging first). Proper `core.worktree` isolation prevents the root cause.

### Working tree operations

- Always verify `core.worktree` in linked worktrees before editing.
- `chump-commit.sh` is the canonical commit tool — never bare `git commit`.
- Use `CHUMP_INDEX_LOCK=0` when `chump-commit.sh` fails with index mutex errors.
- Use `CHUMP_TEST_GATE=0` bypass with `Test-Gate-Bypass:` trailer for
  pre-push test gate timeouts.

## Handoff format (META, 2026-05-10)

When handing off work between agents, structure the handoff as:

```markdown
## Goal

<one-line summary of what we're shipping>

## Instructions

- <bullet: actionable directives>
- <bullet: known workarounds and bypasses>

## Discoveries

1. **<title>**: <description (2-3 sentences with root cause, fix, symptoms)>

## Accomplished

- **<GAP-ID>**: <what was done, commit SHAs>

## To Do Next

### File <N> gaps (in priority order):

1. **<DOMAIN> — <title>** (effort xs/s/m/l/xl)
   - <steps>
2. ...

## Relevant files / directories

- `<path>` — <what's there, what needs to change>
```
