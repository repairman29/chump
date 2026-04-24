# Evaluation Prioritization Framework

**Date:** 2026-04-24  
**Purpose:** Guide execution order and resource allocation for 6 evaluation gaps  
**Output:** Prioritized roadmap with critical dependencies

---

## Executive Summary

Six evaluation gaps filed (INFRA-042, EVAL-083, QUALITY-001, QUALITY-002, INFRA-043, COG-032) feed into gap registry refresh and Q2/Q3 planning.

**Recommended execution order:**
1. **Week 1 (parallel):** QUALITY-001, QUALITY-002, EVAL-083 — fast, high ROI
2. **Week 2–3:** COG-032 (background), INFRA-042 (if FLEET-006 ships)
3. **Week 3+:** INFRA-043 (waits for FLEET-007)

---

## Prioritization Criteria

Each gap evaluated against:
- **Impact:** How much does this unblock or clarify?
- **Effort:** Realistic time estimate
- **Risk:** What goes wrong if we skip it?
- **Dependencies:** What must ship first?
- **Parallelizability:** Can agents work on this independently?

| Gap | Impact | Effort | Risk | Dependencies | Parallel? |
|-----|--------|--------|------|---|---|
| **QUALITY-001** | Very High | **2–3h** | High (shapes removal decisions) | None | ✅ Yes (2+ agents) |
| **QUALITY-002** | High | **4–6h** | Medium (planning accuracy) | None | ✅ Yes (2+ agents) |
| **EVAL-083** | Very High | **3–5h** | Very High (publication blocker) | None | ✅ Yes (4+ agents) |
| **COG-032** | Medium | **1 week** (background) | Low (optional optimization) | None | ✅ Yes (runs in parallel) |
| **INFRA-042** | Very High | **2–4 days** | Very High (validates FLEET) | FLEET-006/007 | ⚠️ Must wait for blocker |
| **INFRA-043** | High | **1–2 weeks** | Medium (scale validation) | FLEET-007 | ⚠️ Must wait for blocker |

---

## Week 1: Quick Wins (Parallel)

### QUALITY-001 (2–3 hours)
**Owner:** Any agent  
**Outcome:** Clarify whether to file REMOVAL-005/006/007 gaps

**Why first:** Results directly inform Q2 scope. If "remove," adds 2–3 weeks. If "re-measure," pivots to better instrument (fast). If "keep," closes discussion.

**Execution:**
1. Read AGENTS.md section on Memory / Executive Function / Metacognition
2. Grep src/agents/ for usage of each module
3. Check test coverage (grep test files)
4. Document findings in a review MD
5. Make 3-way decision with evidence

### QUALITY-002 (4–6 hours)
**Owner:** 2 agents (split 10 gaps each)  
**Outcome:** Validated gap registry; identified clarity issues

**Why first:** Informs subsequent gaps filed. If estimates are wildly off, adjust all future effort predictions.

**Execution:**
1. Random sample 20 open gaps
2. For each: check effort against historical PRs, acceptance clarity, dependencies
3. Grade each (poor/fair/good/excellent clarity)
4. Rewrite any gaps scoring "poor"
5. Commit changes

### EVAL-083 (3–5 hours)
**Owner:** 4 agents in parallel (3–4 evals each)  
**Outcome:** Publication confidence or re-run list

**Why first:** Blocks PRODUCT-009 publication (P1). If other evals have EVAL-069-like issues, must fix before publishing PRODUCT-009 findings.

**Execution:**
1. Assign evals (EVAL-070 through EVAL-082, roughly alphabetical)
2. Check JSONL: grep `"scorer"` row 1
3. Check runner script shebang
4. Check FINDINGS.md for any mention of this eval
5. File findings in master audit report
6. Categorize: safe | needs re-run | broken

---

## Week 1 Output

- **QUALITY-001 decision:** Remove | re-measure | keep
- **QUALITY-002 report:** 20-gap audit + clarity rewrites committed
- **EVAL-083 report:** 12+ evals audited, safe/at-risk categorized

**Next action:** Re-prioritize gaps.yaml based on QUALITY-001 decision + QUALITY-002 findings.

---

## Week 2–3: Background + Blocker-Dependent

### COG-032 (Starts Week 2, runs in background)
**Owner:** Agent with capacity for 1-week async harness  
**Outcome:** Lesson injection ROI quantified

**Why defer one week:** Lower priority than Week 1 items; can run in parallel without blocking planning.

**Execution:**
1. Harness setup (read COG-024, understand CHUMP_LESSONS_AT_SPAWN_N)
2. Run A (50 gaps, lessons off) in background
3. Run B (50 gaps, lessons on) in parallel
4. Collect metrics: test %, review %, time, revisions
5. Compute effect size (t-test, Cohen's d)
6. Document recommendation

**Timeline:** 1 week wall-clock time (but only ~10 hours hands-on); results feed into gap annotation system.

### INFRA-042 (Starts Week 2–3, IF FLEET-006 ships)
**Owner:** Agent with FLEET-006 expertise  
**Outcome:** FLEET concept validated or issues identified

**Why defer:** Blocked on FLEET-006. If FLEET-006 ships on schedule (2–3 weeks), INFRA-042 can start Week 2–3.

**Execution:**
1. Set up 2–3 agents in chump-orchestrator
2. Post 3–5 gaps to work board
3. Run 2–4 hours, monitor logs
4. Document: what broke? what was slow? what felt brittle?
5. File follow-up gaps (FLEET-008/009/010 tuning) if issues found

**Contingency:** If FLEET-006 delayed, defer INFRA-042 to Week 4+.

---

## Week 3+: Scale Validation

### INFRA-043 (Starts Week 3–4, IF FLEET-007 ships)
**Owner:** Infrastructure engineer or agent with harness experience  
**Outcome:** Coordination system stress-tested; bottlenecks identified

**Why last:** Most complex; waits on FLEET-007. Results feed into FLEET-008+ gap scope.

**Execution:**
1. Write harness for lease collisions (10 agents, same gap)
2. Write harness for ambient stream (20 agents, 100 events each)
3. Write harness for worktree reaper (50 stale worktrees)
4. Write harness for TTL expiry (monitor lease auto-expire)
5. Run all; document findings

**Timeline:** 1–2 weeks (includes harness complexity + analysis).

---

## Gap Registry Refresh (Post-Week 1)

After QUALITY-001, QUALITY-002, EVAL-083 complete:

1. **Count open gaps by domain** (before/after hygiene fixes)
2. **Update `current_priorities` section in gaps.yaml:**
   - If QUALITY-001 = remove: file REMOVAL-005/006/007 in P1
   - If QUALITY-002 found clarity issues: re-prioritize affected gaps
   - If EVAL-083 found broken evals: mark for re-run before PRODUCT-009 publication
3. **Re-sort p0_now / p1_next / p2_after_above**
4. **Document refresh rationale** in gaps.yaml meta section

---

## Success Criteria

**Week 1:**
- [ ] QUALITY-001 decision documented (remove | re-measure | keep)
- [ ] QUALITY-002 audit complete (20 gaps reviewed, clarity rewrites committed)
- [ ] EVAL-083 audit complete (12+ evals categorized, safe/at-risk list published)
- [ ] Gap registry priorities updated based on findings

**Week 2–3:**
- [ ] COG-032 harness running (results pending end of week)
- [ ] INFRA-042 scheduled (if FLEET-006 ships; otherwise deferred)

**Week 3+:**
- [ ] INFRA-043 harness running (if FLEET-007 ships)
- [ ] All evaluation results fed back into gap registry

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| QUALITY-001 is "remove" → 2–3 week delay | Start REMOVAL gaps immediately; parallelize with other P2 work |
| EVAL-083 finds broken evals → PRODUCT-009 blocked | Re-run broken evals in parallel; estimate 1–2 extra weeks |
| FLEET-006 delayed → INFRA-042 blocked | Defer to Week 4+; start COG-032 + QUALITY gaps in parallel |
| COG-032 shows lessons are harmful → revert COG-024 | Low risk; decision is binary and reversible |

---

## Integration with Next Gap Prioritization

**Input from these evaluations:**
- QUALITY-001: Removal gaps (if needed) join P1
- QUALITY-002: Clarity rewrites committed; estimates validated
- EVAL-083: Publication blockers surfaced; re-run list created
- COG-032: Update CoG gaps with lesson recommendations
- INFRA-042: FLEET-008/009/010 tuning priorities clarified
- INFRA-043: FLEET scale requirements documented

**Output:**
- Refreshed gaps.yaml with validated estimates + clarity
- REMOVAL gaps (if applicable) in P1 queue
- FLEET-008/009/010 scope + effort refined
- COG-024 default updated or per-gap lessons configured
- PRODUCT-009 publication path cleared or blocked with remediation list

---

## Notes

- **Cost:** Mostly effort; only COG-032 may incur API spend if using Anthropic
- **Parallelization:** Q1 gaps (QUALITY-001/002, EVAL-083) are highly parallelizable; assign to 4+ agents
- **Communication:** Log progress in ambient.jsonl; post daily summary for visibility
- **Checkpoints:** End of Week 1, end of Week 2, end of Week 3 — brief status sync

---

**Owner:** Project coordination  
**Timeline:** 3 weeks (weeks 1–3), with Week 2–3 background tasks extending into Week 4  
**Next checkpoint:** 2026-05-01 (end of Week 1)

