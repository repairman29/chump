# Session synthesis — [DATE or SPAN]

**Author:** [Agent name and model, or human operator]
**Span:** [Wall time or date range]
**Outcome:** [One-line headline — the most important thing that happened]

This doc captures what was built, what was learned, and where to pick up — so the next session doesn't have to re-derive any of it.

---

## 1. Scientific / research result

> [If any empirical finding landed this session, quote the headline number here. Make it tweet-sized — concrete, citable.]

**Full context:** [Link to the relevant doc section or AB results entry]

---

## 2. What shipped

[Bulleted list of PRs, with one-line descriptions. Link each PR number.]

- PR #NN — [what it did]
- PR #NN — [what it did]

---

## 3. Methodology lessons

[The harder-won ones — things that would have saved hours if known at the start. Each should be specific enough to change behavior next session.]

### [Lesson title]

[2-3 sentences on what happened and what the right behavior is going forward.]

### Operational rules that fell out

[Anything added to CLAUDE.md, scripts/git-hooks/, or docs/NORTH_STAR.md this session.]

---

## 4. What failed / wasted time

[Honest accounting of false starts. This is the most valuable section for future sessions.]

| What | Time lost | Root cause | Prevention |
|------|-----------|------------|-----------|
| | | | |

---

## 5. Cost breakdown

| Step | Trials | Spend |
|------|-------:|------:|
| | | |
| **Total** | | |

[Note: cost tracking via `scripts/ab-harness/cost_ledger.py` if API calls were made]

---

## 6. Gap / state snapshot

[Quick table of open gaps at end of session — just IDs, priorities, and one-line status.]

| ID | Priority | Status | Notes |
|----|----------|--------|-------|
| | | | |

---

## 7. Where to pick up next session

### Immediate (first 30 min)

1. [Most urgent unblocked thing]
2. [Second most urgent]

### Next chips (small, ready)

3. [Quick win with clear acceptance]

### Bigger projects

4. [Multi-session work, with a clear starting point]

### Do NOT pick up unless asked

- [Things that look tempting but shouldn't be touched without explicit instruction]

---

## 8. Operational state at end of session

- **Open PRs:** [count]
- **Active worktrees:** [count, list if > 3]
- **Cloud budget:** [$X of $Y spent], recorded in `logs/cost-ledger.jsonl`
- **Main is at** `[sha]` — past PRs [list]

---

## 9. Single-line summary

> [One sentence that captures the phase's contribution to the project arc. Should be usable in a changelog or retrospective without modification.]
