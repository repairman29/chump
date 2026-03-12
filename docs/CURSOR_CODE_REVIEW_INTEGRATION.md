# Cursor Code Review Integration

How Cursor integrates with Chump for code reviews and enhancements. See also **AGENTS.md** (Cursor agent instructions) and **.cursor/rules/productivity_guidelines.mdc** (handoffs and code review rules).

## Workflow

1. **Chump** conducts a self-review using the `diff_review` tool (runs `git diff` or `git diff --staged` in the repo and sends the diff to a worker). The result is a short self-audit suitable for the PR description.
2. **Cursor** provides additional insights based on Chump's review and the actual diff.
3. **Chump** (or the human) reviews Cursor's feedback and incorporates improvements.

## Handoff format (Cursor → Chump / human)

When Cursor finishes work that Chump or a human will follow up on, provide a **detailed summary** so the next round has context:

- **What was done** — Brief description of changes (e.g. "Added AGENTS.md and expanded CURSOR_CODE_REVIEW_INTEGRATION; updated productivity_guidelines.mdc.").
- **Files changed** — List of paths touched.
- **What to do next** — Next steps (e.g. "Run tests; commit and open PR.") or "Done."
- **Blockers / follow-ups** — Anything that needs a decision or further work.

This aligns with **.cursor/rules/productivity_guidelines.mdc**: Cursor should provide detailed summaries during handoffs; Chump should confirm understanding and request clarifications.

## Best practices

- **Context:** Provide context and specific bullet points for guidance. Chump should give Cursor clear, context-rich code descriptions; Cursor should do the same when handing back.
- **Conventions:** Follow Git rules and conventions from [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md).
- **Diff analysis:** When reviewing, ensure detailed diff analysis:
  - `git diff` — working tree vs HEAD.
  - `git diff --staged` — staged changes (what will be committed).
- **Prioritize Chump's self-review:** When Chump has already run `diff_review`, use that self-audit as the starting point and add or refine feedback (bugs, simplicity, style, tests, docs).

## Example: Chump self-review (diff_review)

Chump calls the `diff_review` tool with optional `staged_only: true`. The tool runs `git diff` (or `git diff --staged`) in the repo and delegates to a worker that returns a short self-audit. Chump puts that in the PR body.

## Example: Cursor review (after seeing a diff)

When you have a diff (e.g. from Chump's handoff or from running `git diff` / `git diff --staged` locally):

1. Read the diff and any self-audit Chump provided.
2. Add bullet-point feedback: unintended side effects, simpler approach, bugs, style, missing tests or docs.
3. If implementing fixes, make the changes and then provide a handoff summary (see above).

```bash
# Get full context when reviewing
git diff
git diff --staged
```
