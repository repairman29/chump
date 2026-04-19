# Pragmatic Roadmap

"Ships this quarter" cut of the backlog — P1 items and high-leverage P2 items that are unblocked, have clear scope, and realistic effort (S or M). Full backlog in [ROADMAP_FULL.md](ROADMAP_FULL.md).

**Current quarter: Q2 2026.** As of 2026-04-19.

> **Research thesis (accurate as of 2026-04-19):** Instruction injection effects vary
> systematically by model tier. Lessons blocks help haiku-4-5 (confirmed n=100). They harm
> sonnet-4-5 (+0.33 hallucination rate, confirmed n=100). Neuromod is net-negative on dynamic
> tasks (EVAL-029). The individual cognitive modules (surprisal EMA, belief state, neuromod)
> are **unablated** — EVAL-043 resolves this. See [RESEARCH_INTEGRITY.md](RESEARCH_INTEGRITY.md).

---

## Hotfix — ship before anything else

| ID | Title | Effort | Why |
|----|-------|--------|-----|
| INFRA-GAPS-DEDUP | Fix 7 duplicate gap IDs in registry | S | Corrupted index; every agent session is unreliable until fixed |
| INFRA-PUSH-LOCK | Pre-push hook blocks post-arm pushes | S | PR #52 footgun still loaded; merge queue doesn't close it |

## Now — already in progress or immediate next

| ID | Title | Effort | Why now |
|----|-------|--------|---------|
| AUTO-013 | Chump-orchestrator mode — self-dispatching meta-loop | XL | Step 1–5 shipped; ongoing |
| EVAL-030 | Task-class-aware lessons block | M | Shipped; EVAL-030-VALIDATE pending |
| EVAL-041 | Human grading baseline (complete EVAL-010) | M | Prerequisite for publication; ~40 hrs Jeff |
| EVAL-042 | Cross-family judge re-run (Llama-3.3-70B) | S | ~$3 cloud; fixes judge-bias caveat on all prior findings |
| RESEARCH-002 | Align all docs to accurate research thesis | M | Prevents propagating false claims to new contributors/agents |
| COG-025 | Dispatch-backend pluggability (Together) | M | P1; enables 90% cost reduction on autonomous dispatch |
| COG-026 | Validate Together-big on agent loop A/B | S | Needs COG-025 first |

## Next — unblocked, high leverage, S/M effort

| ID | Title | Effort | Notes |
|----|-------|--------|-------|
| EVAL-043 | Ablation suite (belief_state, surprisal, neuromod) | M | ~$15 cloud; validates or cuts each module independently |
| INFRA-COST-CEILING | Per-session cloud spend cap | S | Simple config + hard stop; blocks runaway agents |
| INFRA-BOT-MERGE-LOCK | bot-merge.sh marks worktree shipped | S | Prevents double-merge footgun |
| INFRA-AGENT-CODEREVIEW | Code-reviewer agent for src/* PRs | M | Quality gate before auto-merge |
| COMP-010 | Brew formula + signed installer | S | Removes `git clone` onboarding friction |
| COMP-011a | Adversary-mode-lite — static-rules monitor | S | Static rules only; no LLM cost |
| COMP-014 | Fix cost ledger ($0.00 bug) | M | Provider attribution broken since cascade |
| EVAL-028 | CatAttack robustness sweep | S | Harness already supports `--distractor`; ~$1 |
| EVAL-035 | Belief-state ablation A/B | S | Superseded by EVAL-043 — fold in |
| EVAL-038 | ASK_JEFF ambiguous-prompt A/B | S | Pair with COG-027 task-aware ask gate |
| COG-027 | Task-aware ask-vs-execute policy | S | Fixes perception directive on procedural tasks |

## This quarter (Q2) — P2, M effort, cleared dependencies

| ID | Title | Effort |
|----|-------|--------|
| EVAL-032 | Perception layer ablation A/B | M |
| EVAL-033 | Attention mitigation A/B | M |
| MEM-008 | Multi-hop QA fixture spec (pilot) | S |
| MEM-009 | Reflection episode quality filtering | M |
| MEM-010 | Entity resolution accuracy A/B | M |
| INFRA-AGENT-ESCALATION | Formal agent escalation pattern | M |
| INFRA-DISPATCH-POLICY | musher dispatch policy | M |
| COMP-008 | Recipes abstraction | M |
| COMP-009 | Extend MCP-server catalog to 6+ | M |

## Deferred to Q3+ (L/XL effort or blocked)

| ID | Title | Effort | Blocker |
|----|-------|--------|---------|
| EVAL-034 | Memory retrieval multi-hop QA | L | Needs MEM-008 fixture spec first |
| EVAL-044 | Multi-turn eval fixture | M | Needs EVAL-043 ablations first |
| COG-024 | Default lessons-OFF | L | Needs EVAL-030 first |
| COMP-011b | Adversary mode full (LLM-based) | L | Needs COMP-011a results |
| EVAL-031 | Search-Augmented Reasoning | L | Speculative; needs AutoRefine study |
| EVAL-037 | Multi-agent coordination A/B | L | Needs coordination system stable |
| EVAL-039 | Longitudinal learning A/B | L | Needs months of reflection-DB data |
| INFRA-AMBIENT-STREAM-SCALE | Ambient stream retention at fleet scale | M | Not a bottleneck until fleet > 5 agents |
| INFRA-FILE-LEASE | File-level path leases | M | Nice-to-have; gap-level is sufficient for now |

---

## Effort key

| Symbol | Range |
|--------|-------|
| S | Hours to 1 day |
| M | 1–3 days |
| L | 1–2 weeks |
| XL | Multiple weeks |

## See Also

- [ROADMAP.md](ROADMAP.md) — canonical checked/unchecked backlog
- [ROADMAP_FULL.md](ROADMAP_FULL.md) — complete gap registry
- [docs/gaps.yaml](gaps.yaml) — machine-readable source
