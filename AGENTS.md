# Cursor agent instructions (Chump–Cursor productivity)

When working in this repo, especially on handoffs from Chump or code review tasks, follow these rules so Chump and Cursor improve together.

**Priorities:** Improve implementation (ship working code/docs), speed (less friction, faster rounds), quality (tests, clarity), and bot capabilities—especially **understanding the user in Discord and acting on intent** (infer what they want from natural language; create tasks, run commands, or answer without over-asking). See docs/ROADMAP.md for the "Bot capabilities (Discord)" section.

## Context to read first

- **docs/ROADMAP.md** — Chump's roadmap; single source of truth for what to work on. Pick from unchecked items and priorities when Chump delegates or you're improving the product. Do not invent your own roadmap.
- **docs/CHUMP_PROJECT_BRIEF.md** — Current focus and conventions (tool usage, naming, Git). Use with ROADMAP.md.
- **docs/CURSOR_CODE_REVIEW_INTEGRATION.md** — Code review workflow (Chump `diff_review` → Cursor insights) and handoff format.
- **.cursor/rules/** — Project rules (e.g. `productivity_guidelines.mdc`): handoffs, code review, integration.

## Handoffs from Chump

- Chump may delegate to you via Cursor CLI (`agent -p "..." --force`) with a goal and context.
- **Provide detailed summaries** of changes and context when you finish work, so the next Chump round (or human) can continue without re-reading the whole diff.
- Summaries should include: what was done, what files changed, what to do next (or "done"), and any blockers or follow-ups.

## Code review

- **Prioritize** reviewing and improving code based on Chump’s self-review when you receive a diff or PR context.
- Chump runs `diff_review` (git diff → worker) before committing; that output is a self-audit for the PR body.
- When you review:
  - Use `git diff` and `git diff --staged` for full context when needed.
  - Provide **specific, bullet-point feedback** (bugs, simplicity, style, alignment with CHUMP_PROJECT_BRIEF).
  - Follow Git and repo conventions from CHUMP_PROJECT_BRIEF and .cursor/rules.

## Implementation

- Implement code, tests, and docs as requested; don’t limit yourself to research.
- Follow tool usage and naming conventions from CHUMP_PROJECT_BRIEF and .cursor/rules.
- When adding or changing behavior, add or update tests and docs as appropriate.
