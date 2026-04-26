---
doc_tag: log
owner_gap: PRODUCT-009
last_audited: 2026-04-25
---

# PRODUCT-009: Publication Readiness Checklist

**Status as of 2026-04-24:** Draft is ready for external review.

## Integrity Verification (Completed)

- [x] **Reviewed against RESEARCH_INTEGRITY.md** — No overclaims, CIs included, n/κ preserved
- [x] **All findings cite source docs** — EVAL-025, EVAL-027, EVAL-029, EVAL-042, EVAL-046, COG-031 referenced
- [x] **Each finding includes honest-limits section** — Caveats and limitations explicit for F1–F6
- [x] **Cross-family judge bias disclosed** — F2 explicitly narrowed to Anthropic models (EVAL-071 result)
- [x] **Aggregate signal caveat documented** — F3 caveat explains EVAL-069 credibility issue
- [x] **Replication invitations explicit** — "We explicitly invite replication" + cost estimation ($5)

## Acceptance Criteria Status

| Criterion | Status | Notes |
|-----------|--------|-------|
| Venue selected | ✅ Done | HackerNews / practitioner blog |
| Draft reviewed for integrity | ✅ Done | 2026-04-20 RESEARCH_INTEGRITY.md pass |
| Draft reviewed by external reader | ⏳ Pending | Awaiting Gemini or external reviewer |
| Publication live with URL | ⏳ Pending | After external review |
| FINDINGS.md replication-invitation updated | ⏳ Pending | After publication |

## Final Draft Quality Checks

### Structure
- Opening framing: ✅ Clear, accessible to practitioners
- Finding 1 (F1 U-curve): ✅ Well-motivated, honest limits included
- Finding 2 (F2 halluc): ✅ Anthropic-specific caveat included, judge bias explained
- Finding 3 (F3 clusters): ✅ Localization focus, aggregate caveat in place
- Finding 4 (F4 cross-judge): ✅ Reframing explained (prompt asymmetry not model family)
- Finding 5 (F5 judge bias): ✅ κ values included, 0.059 / -0.250 / 0.250 documented
- Finding 6 (F6 few-shot): ✅ Existence proof (n=1) explicitly marked, cost stated ($0.20)
- Replication section: ✅ Explicit invitations, cost estimates, harness paths

### Caveats & Disclaimers
- [x] Single-team findings noted (F1, F6)
- [x] Cross-family validation gaps noted (F2 Anthropic-specific, F4 reframing)
- [x] N-size limitations noted (F2 = 2,600 trials, F5 = n=12 preliminary)
- [x] Judge-bias section explains both reward patterns (tool-call hallucination, misunderstanding clarifying questions)
- [x] "What we don't claim" section covers consciousness, generalization, other modules

### Integrity Against Known Issues
- F3 aggregate: ✅ "Whether the original aggregate signal was real or an artifact... is an open question"
- F5 preliminary: ✅ Marked as preliminary, v2 fix shipped, full re-score pending
- F2 judge bias: ✅ v2 prompt deployed, re-score pending
- F6 n=1: ✅ Marked as existence proof, generalization unknown

## Next Steps to Closure

1. **External review** (1–2 days)
   - Share draft with Gemini reviewer or domain expert
   - Collect feedback on accessibility, overclaim risk, framing
   - Incorporate revisions

2. **Publish** (depends on venue)
   - HackerNews: post to HN homepage, monitor comments/feedback
   - Or: Medium / practitioner blog (e.g., Substack, dev.to)

3. **Close PRODUCT-009**
   - Update docs/audits/FINDINGS.md "How to cite" section with live URL
   - Update replication-invitation text in FINDINGS.md
   - Close gap in docs/gaps.yaml with `status: done`, cite PR number
   
## Current Word Count & Shape
- ~2,100 words ✓ (optimal for HN/practitioner blog)
- Skimming path: frontmatter + headlines + "Bonus section" covers findings in 2 min
- Deep read: 5–8 min with all caveats

---

**Ready for handoff to external reviewer.**
