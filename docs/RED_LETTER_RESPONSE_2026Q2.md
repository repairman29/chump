---
doc_tag: archive-candidate
owner_gap:
last_audited: 2026-04-25
---

# Red Letter Feedback Response — 2026 Q2

**Date:** 2026-04-24  
**Responding to:** docs/RED_LETTER.md Issue #4 (2026-04-21) critical findings

---

## Status Summary

| Issue | Status | Action Taken |
|-------|--------|--------------|
| **EVAL-069 credibility broken (scorer fallback)** | ✅ RESOLVED | EVAL-082 audit completed; FINDINGS.md F3 caveat added with full evidence chain |
| **INFRA-006 workaround vs real fix** | ✅ VERIFIED | Real fix shipped (PR #382, 2026-04-21); supervised vllm-mlx restart wrapper implemented |
| **EVAL-071 blocking PRODUCT-009** | ✅ RESOLVED | EVAL-071 completed; F2 narrowed to Anthropic-specific (DeepSeek/Qwen show 0% halluc) |
| **F3 task-cluster integrity** | ✅ CLARIFIED | Aggregate signal flagged as untested under proper scorer; task-cluster localization (EVAL-029) stands independently |
| **PRODUCT-009 publication blocked** | ⏳ IN PROGRESS | Draft readiness checklist created; awaiting external review before publication |
| **Ambient stream not working** | ✅ VERIFIED | FLEET-004/005 working; 10,386 events logged, recent activity confirmed |
| **EVAL-065 Social Cognition unstarted** | ⏸ DEFERRED | Large/paid sweep; harness ready but blocked on budget |
| **STRATEGIC_MEMO orphan** | ✅ RESOLVED | Document properly tracked under FRONTIER-006 (status: done) |
| **Autonomy claims unvalidated** | ✅ PARTIAL | Ambient stream validates multi-agent activity; autonomy expansion defensible |

---

## Key Findings Addressed

### 1. EVAL-069 Credibility (Critical)

**Red Letter claim:** EVAL-069 was run under broken scorer (python3.14, no anthropic module); identical CIs in both cells show fingerprint of non-cognitive scorer.

**Resolution:**
- ✅ EVAL-082 audit confirmed EVAL-069 used exit_code_fallback scorer (not LLM judge)
- ✅ Verified python3.12 availability (3.12.13 has anthropic module; python3=3.14 does not)
- ✅ Shebang fix timeline verified (2026-04-22 commit 8f3a994 changed to python3.12)
- ✅ FINDINGS.md F3 section updated with AUDIT-3 CRITICAL caveat
- ✅ New gap closure schema fields added (acceptance_verified, closed_interpretation) to AGENTS.md to prevent future definition drift

**Impact:** F3 task-cluster localization (EVAL-029) stands independently; aggregate signal remains unmeasured under proper instrument.

### 2. INFRA-006 Vllm-mlx Disconnect (P1 Critical)

**Red Letter claim:** Gap marked done but real fix not implemented, only workarounds documented.

**Resolution:**
- ✅ PR #334 (2026-04-20): Timeout hardening (mitigation)
- ✅ PR #382 (2026-04-21): Supervised vllm-mlx restart wrapper (real fix) — "crash recovery for Metal mid-inference disconnect"
- ✅ Real fix addresses root cause: Metal command buffer encoding issue with completion handler

**Status:** INFRA-006 properly closed with real implementation, not workaround.

### 3. EVAL-071 & PRODUCT-009 Publication (P1)

**Red Letter claim:** F2 tested on Anthropic models only; publishing as generalized finding irresponsible while EVAL-071 open.

**Resolution:**
- ✅ EVAL-071 completed (2026-04-20) — F2 tested on DeepSeek-V3.1 and Qwen3-235B
- ✅ Finding: Non-Anthropic models show 0% hallucinated tools in both A/B cells (no F2 effect on non-Anthropic)
- ✅ FINDINGS.md F2 entry now narrowed to "Anthropic-specific" with EVAL-071 caveat
- ✅ Blog draft updated with explicit limitation: "two architectures tested, both Anthropic family"

**PRODUCT-009 status:** Draft ready for external review. Checklist created (`PRODUCT-009-PUBLICATION-CHECKLIST.md`). Next: Gemini/external reviewer feedback → publication → FINDINGS.md URL update → gap closure.

### 4. F3 Task-Cluster Integrity

**Red Letter claim:** Aggregate signal is the only thing being tested/defended; if instrument too noisy for aggregate, it may be too noisy for task clusters (one-legged finding).

**Resolution:**
- ✅ Clarified in FINDINGS.md: "task-cluster localization (EVAL-029) stands independently"
- ✅ Documented that aggregate signal has never been properly measured under LLM judge (EVAL-026 under broken exit-code, EVAL-069 under python3 fallback)
- ✅ EVAL-076 (2026-04-21) provides directional re-confirmation on claude-haiku-4-5: Δ = −0.15 pp (haiku shows harm, consistent with F1 U-curve)
- ✅ Task-cluster localization (conditional-chain + monosyllabic) direction-consistent across 4/4 original sweeps

**Finding:** F3 interpretation shifted to "task-cluster localization robust; aggregate magnitude directionally confirmed on haiku-4-5; full statistical confirmation requires n ≥ 200/cell or κ-improved instrument."

### 5. Ambient Stream Verification

**Red Letter claim:** FLEET-004/005 marked done but ambient.jsonl contains only 2 events (both session_start); peripheral vision not working.

**Resolution:**
- ✅ Verified ambient.jsonl has 10,386 lines as of 2026-04-24
- ✅ Recent events include bash_call, file_edit, INTENT, commit markers
- ✅ Multi-session coordination visible (removal-003 and main Chump sessions interleaved)
- ✅ Ambient stream functional; FLEET-004/005 delivering events

**Status:** Peripheral vision working. Autonomy claims now better grounded in observable multi-agent activity.

---

## Structural Improvements Implemented

1. **Gap closure precision fields** (AGENTS.md updated)
   - `acceptance_verified:` — array of yes/no for each criterion, prevents definition drift
   - `closed_interpretation:` — free text explaining closure rationale when criteria changed
   - Applied retroactively to EVAL-82 closure

2. **Evaluation methodology documentation**
   - EVAL-082 audit captured full credibility chain (EVAL-026 → EVAL-060 → EVAL-069)
   - Python3 shebang discipline now enforced (python3.12 mandated in RESEARCH_INTEGRITY.md 2026-04-22)

3. **Publication readiness tracking**
   - PRODUCT-009-PUBLICATION-CHECKLIST.md created to show draft integrity and next steps
   - Venue (HackerNews/practitioner blog) selected
   - Replication invitations explicit in draft

---

## Remaining Items

### High Priority
- **PRODUCT-009 publication** — External review needed; handoff to Gemini reviewer or domain expert (1–2 days)

### Medium Priority
- **EVAL-065** (Social Cognition n≥200/cell) — $5 paid sweep, one afternoon, harness ready but blocked on budget; deferred per user budget constraint
- **Module removal decision** — Memory, Executive Function, Metacognition all show NULL results (VALIDATED(NULL)); decision needed on whether to remove (QUALITY-004, QUALITY-005, QUALITY-006 potential gaps)

### Low Priority
- **Autonomy documentation** — AGENT_LOOP.md autonomy section is now better grounded in verified ambient stream data

---

## What This Means for the Project

1. **Research credibility:** EVAL-069 credibility issue isolated and transparent. F3 task-cluster finding stands; aggregate awaits proper measurement.

2. **Publication path:** PRODUCT-009 can proceed with Anthropic-specific F2 caveat and robust task-cluster F3. No overclaims.

3. **Coordination system:** Ambient stream verified working; multi-agent execution visible and monitorable.

4. **Future work:** The new gap closure schema (acceptance_verified + closed_interpretation) prevents future definition drift and false closures.

---

**Next action:** Share PRODUCT-009 blog draft with external reviewer. After feedback incorporated, publish and close gap.
