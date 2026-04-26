---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump dispatch rules — injected into every autonomous agent prompt

> This file is read programmatically by `dispatch.rs` and `execute_gap.rs` and
> injected verbatim into the system prompt for every Chump-dispatched agent
> (both `claude` and `chump-local` backends). Keep it under 60 lines.
> Full rules in CLAUDE.md; AGENTS.md is the cross-tool canonical entry point.

## Hard rules (no exceptions)

- **Never push to `main`.** Branch is `claude/<codename>`, worktree under `.claude/worktrees/<codename>/`.
- **Commit with `scripts/chump-commit.sh <file1> [file2] -m "msg"`**, not bare `git add && git commit`. The wrapper prevents cross-agent staging drift.
- **Run `cargo fmt --all` before committing any `.rs` file.** The pre-commit hook does it, but if you bypass with `--no-verify` you must run it manually. CI fails on unformatted code.
- **Atomic PR discipline.** Once `bot-merge.sh` runs, do NOT push more commits to that branch. Open a new worktree for follow-on work.
- **Never leave a lease file behind.** `bot-merge.sh` handles cleanup. If you abort early, run `chump --release`.

## Ship pipeline

```bash
scripts/bot-merge.sh --gap <GAP-ID> --auto-merge
```

This rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and enables auto-merge. Do not run `git push` or `gh pr create` manually.

## Research integrity

Before touching any eval fixture, cognitive-architecture code, or research claim:

- Read `docs/process/RESEARCH_INTEGRITY.md`. The accurate thesis is narrower than what CHUMP_PROJECT_BRIEF.md and CHUMP_RESEARCH_BRIEF.md say.
- Do not write "cognitive architecture is validated" — individual modules (surprisal, belief state, neuromod) are unablated.
- Do not write "Surprisal EMA: Confirmed" — that claim is unsupported pending EVAL-043.
- Any eval delta from n<100 or Anthropic-only judges must be described as "preliminary".

## Coordination

- The gap is already claimed in this worktree when this prompt is injected.
- Read `docs/gaps.yaml` for the gap's acceptance criteria.
- Check `.chump-locks/ambient.jsonl` for recent activity from sibling sessions.
- Use `CHUMP_GAP_CHECK=0 git push` only when gap IDs in commit bodies cause false positives on the pre-push hook.
