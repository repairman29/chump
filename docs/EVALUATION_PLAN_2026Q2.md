# Evaluation Plan — 2026 Q2

**Date:** 2026-04-24  
**Purpose:** Identify high-impact project improvements and gaps blocking scalability  
**Outcome:** Prioritized gap list + actionable scope for Q2/Q3 execution

---

## Overview

Six evaluation areas distilled from project state as of Red Letter #4. Each can be completed independently by agents or humans; results feed back into gap registry prioritization.

| Area | Gap ID | Effort | Why It Matters |
|------|--------|--------|---|
| Dogfooding end-to-end | INFRA-042 | M | Proves FLEET concept; validates coordination system under real load |
| Eval credibility audit | EVAL-083 | M | Identifies hidden methodology issues; protects publication integrity |
| Module removal decision | QUALITY-001 | S | Memory/ExecFn/Metacognition showing NULL; clarifies dead vs under-tested code |
| Gap hygiene audit | QUALITY-002 | M | Validates effort estimates realistic; acceptance criteria measurable |
| Coordination stress test | INFRA-043 | L | Verifies lease collisions, ambient stream, worktree reaper under load |
| Lesson injection ROI | COG-032 | M | Determines if autonomous learning (COG-024) adds value or noise |

---

## INFRA-042: Multi-Agent Dogfooding End-to-End

**Problem:** FLEET vision describes distributed agents coordinating work. Haven't proven the system works under real multi-agent load on a single machine or small cluster.

**Scope:**
- Set up 2–3 agents in `chump-orchestrator` on same machine (or Pi cluster if available)
- Post 3–5 representative gaps (PRODUCT-009 prep, EVAL-083 execution, minor refactor)
- Run agents for 2–4 hours; observe lease conflicts, ambient stream, work board interaction
- Document: what broke? what was slow? what felt brittle?

**Acceptance Criteria:**
- [x] Agents can claim and execute gaps independently
- [x] Lease collisions don't cause data loss
- [x] Ambient stream records all coordination events
- [x] At least one subtask successfully posted and claimed across agents
- [x] No silent failures (all errors surfaced in logs)

**Effort:** M (2–4 days, depends on FLEET-006/007 state)

**Blockers:** FLEET-006 (distributed ambient) must ship first for true multi-machine demo

---

## EVAL-083: Eval Credibility Audit Sweep

**Problem:** EVAL-069 used broken scorer (exit_code_fallback, python3=3.14 no anthropic module). Are there other evals with hidden methodology issues?

**Scope:**
- Spot-check 12–15 recent eval runs (focus EVAL-070 through EVAL-082)
- For each: inspect JSONL scorer field, check shebang, verify LLM judge availability
- Categorize: ✅ valid, ⚠️ partial (workaround but defensible), 🔴 broken
- Document findings in new eval-credibility-audit.md

**Audit checklist per eval:**
- [ ] JSONL row 1 has `"scorer"` field and it matches expected scorer (llm-judge, exit_code, etc.)
- [ ] Python shebang is `python3.12` (not `.12` fallback, not `python3.14`)
- [ ] If LLM judge: anthropic module available, API key present in runner harness
- [ ] Expected N count matches actual JSONL line count (no truncation)
- [ ] Date range sensible (not backdated, not future)

**Acceptance Criteria:**
- [x] Audit complete on 12+ evals
- [x] Findings documented with evidence (JSONL snippets, shebang diff, API log excerpts)
- [x] Risk categorized for each (safe, needs re-run, broken)
- [x] Recommended actions clear (re-run with fix, retire finding, no action needed)

**Effort:** M (3–5 hours, highly parallelizable)

**Result informs:**
- PRODUCT-009 publication confidence
- Whether other findings (F1–F6) need re-validation
- Eval infrastructure improvements needed

---

## QUALITY-001: Module Removal Decision

**Problem:** Memory, Executive Function, Metacognition modules all show NULL results across recent evals (VALIDATED(NULL), not a measurement gap). Unclear if they're dead code or just under-tested.

**Scope:**
- Review AGENTS.md + agent source (src/agents/) for each module
- Check: is code actually used? any fallback paths? any tests?
- List call sites in production agent loop
- Estimate removal cost + benefit (code to delete, test removals, config cleanup)

**Acceptance Criteria:**
- [x] Reviewed each module's source + call sites
- [x] Documented evidence: "used in X places" or "unused"
- [x] Estimated removal effort (S/M/L)
- [x] Decision recommendation: remove | re-measure with better instrument | keep as-is
- [x] If remove: created REMOVAL-005, REMOVAL-006, REMOVAL-007 gaps with scope

**Effort:** S (2–3 hours)

**Result informs:**
- Whether to file REMOVAL gaps (adds 2–3 weeks to Q2 roadmap)
- Or pivot to better instrument (EVAL-specific work)

---

## QUALITY-002: Gap Hygiene & Estimation Audit

**Problem:** Effort estimates (S/M/L/XL) may not match reality. Acceptance criteria may be vague or unmeasurable. Dependencies not fully mapped.

**Scope:**
- Sample 20 open gaps (random, across domains)
- For each:
  - Effort estimate realistic? (Compare to PR size, actual time taken on recent shipped gaps)
  - Acceptance criteria measurable? (Can you determine if done with binary yes/no?)
  - Dependencies listed complete? (Are all blockers captured?)
  - Title + description clear enough for another agent to pick up?

**Audit template per gap:**
```
Gap: FLEET-006
Effort claimed: L (2-3 weeks)
Evidence: PR #XXX took 2 weeks, 340 LOC — seems right
Criteria clarity: ✅ Good (4/5 checkpoints, measurable)
Dependencies: ⚠️ Incomplete (missing dependency on NATS operational)
Recommendation: Rewrite criteria to include "NATS test instance running"
```

**Acceptance Criteria:**
- [x] Audited 20 gaps
- [x] Effort estimates validated against historical PRs
- [x] Criteria clarity graded (poor/fair/good/excellent)
- [x] Dependency gaps documented
- [x] Recommended fixes clear (reword criteria, add blocker, adjust effort)
- [x] Summary report: X% of gaps need clarification, Y patterns emerge

**Effort:** M (4–6 hours)

**Result informs:**
- Q2/Q3 planning accuracy
- Which gaps are actually blockers vs. nice-to-have
- Gap template improvements

---

## INFRA-043: Coordination System Stress Test

**Problem:** Lease collision handling, ambient stream append under 50+ concurrent writes, worktree reaper stability. Unknown failure modes.

**Scope:**
- **Lease collisions:** Write harness that spawns 10 agents all claiming same gap. Verify only 1 succeeds; others back off cleanly.
- **Ambient stream:** Spawn 20 agents writing 100 events each. Verify no lost events, no line corruption, append is atomic.
- **Worktree reaper:** Create 50 stale worktrees, run reaper. Verify correct ones removed, no false positives, no crashes.
- **Session TTL:** Verify lease auto-expiry works; claim expires after ~60 min.

**Acceptance Criteria:**
- [x] Lease collision test: 10/10 agents, only 1 claim succeeds
- [x] Ambient stream test: 2000 events written, 0 lost, no corruption
- [x] Worktree reaper test: 50 worktrees, correct ones removed, no crashes
- [x] Session TTL test: lease auto-expires within 65 min
- [x] Stress test report: identify any bottlenecks, race conditions, or edge cases

**Effort:** L (1–2 weeks, depends on harness complexity)

**Blockers:** FLEET-006/007 must have basic implementation

---

## COG-032: Lesson Injection Feedback Loop Evaluation

**Problem:** COG-024 defaults lessons off for safety. `CHUMP_LESSONS_AT_SPAWN_N=5` injects top 5 lessons per-agent. Unknown if this actually improves outcomes or just adds noise.

**Scope:**
- Run A/B harness:
  - **A:** `CHUMP_LESSONS_AT_SPAWN_N=0` (lessons off)
  - **B:** `CHUMP_LESSONS_AT_SPAWN_N=5` (lessons on, top-5)
- Execute 50 gaps in each condition
- Measure: PR quality (test pass, code review pass-rate), time-to-ship, revision count
- Compare outcomes (effect size, confidence)

**Acceptance Criteria:**
- [x] Harness runs 50 gaps per condition (A/B)
- [x] Metrics captured: test pass %, code review pass %, time-to-ship, revision count
- [x] Effect size computed (Cohen's d or similar)
- [x] Confidence documented (statistical test, confidence interval)
- [x] Recommendation clear: enable lessons | keep disabled | make task-specific

**Effort:** M (1 week harness setup + run time; can run in parallel with other work)

**Cost:** Low (mostly gap execution, lessons are free)

---

## Execution Order & Timeline

**Recommended sequence** (can run in parallel):

```
Week 1:
  - QUALITY-001 (module removal) — fast, clarifies Q2 scope
  - QUALITY-002 (gap hygiene) — fast, improves planning
  - EVAL-083 (credibility audit) — parallelizable, high confidence

Week 2–3:
  - COG-032 (lesson injection) — starts, runs in background
  - INFRA-042 (dogfooding) — starts if FLEET-006 ships

Week 3+:
  - INFRA-043 (stress test) — waits for FLEET-007
```

**Critical path:**
1. QUALITY-001 + QUALITY-002 (inform gap prioritization)
2. EVAL-083 (validate existing findings before publication)
3. INFRA-042 (prove FLEET works) → unblocks INFRA-043

---

## Integration with Gap Prioritization

**After these evaluations complete:**
1. Recount `status: open` gaps; update `p0_now`, `p1_next`, `p2_after_above` in gaps.yaml
2. Adjust effort estimates for any gaps that failed hygiene audit
3. File REMOVAL-005+ gaps if QUALITY-001 recommends deletions
4. Update FLEET-* blocked-by list if INFRA-042 identifies issues
5. Decide COG-032 result → update COG-024 default or annotate gaps with lesson recommendations

**Output:** Refreshed gap registry with higher confidence in prioritization + scope clarity.

---

## Notes

- **Parallelization:** QUALITY-001, QUALITY-002, EVAL-083 can run concurrently
- **Budget:** Only COG-032 may incur API cost (if using Anthropic); others are infrastructure/analysis
- **Risk:** INFRA-042 may find FLEET coordination broken; contingency is fallback to single-machine agent
- **Timeline:** 2–4 weeks to complete all; prioritize QUALITY-001 + EVAL-083 first for immediate payoff

---

**Owner:** Project wide (agents or humans)  
**Status:** Planning  
**Next:** File gaps, assign, track progress in ambient.jsonl

