# Pragmatic Roadmap

"Ships this quarter" cut of the backlog — P1 items and high-leverage P2 items that are unblocked, have clear scope, and realistic effort (S or M). Full backlog in [ROADMAP_FULL.md](ROADMAP_FULL.md).

**Current quarter: Q2 2026.** As of 2026-04-19.

---

## Now — already in progress or immediate next

| ID | Title | Effort | Why now |
|----|-------|--------|---------|
| AUTO-013 | Chump-orchestrator mode — self-dispatching meta-loop | XL | Step 1 + 2 shipped; step 3+ in progress |
| COG-023 | Sonnet carve-out from COG-016 directive | M | Confirmed at n=100; single-file change |
| EVAL-030 | Task-class-aware lessons block | M | Fixes the root cause of COG-016 neuromod harm |
| INFRA-MERGE-QUEUE | GitHub merge queue | S | Prevents squash-loss footgun; INFRA-PUSH-LOCK is its co-dep |
| INFRA-PUSH-LOCK | Pre-push hook blocks post-arm pushes | S | 30-line hook; pairs with merge queue |

## Next — unblocked, high leverage, S/M effort

| ID | Title | Effort | Notes |
|----|-------|--------|-------|
| INFRA-COST-CEILING | Per-session cloud spend cap | S | Simple config + hard stop; blocks runaway agents |
| INFRA-BOT-MERGE-LOCK | bot-merge.sh marks worktree shipped | S | Prevents double-merge footgun |
| INFRA-AGENT-CODEREVIEW | Code-reviewer agent for src/* PRs | M | Quality gate before auto-merge |
| COMP-010 | Brew formula + signed installer | S | Removes `git clone` onboarding friction |
| COMP-013 | MCPwned / DNS rebinding audit | S | Security hygiene; hour-long audit |
| COMP-011a | Adversary-mode-lite — static-rules monitor | S | Static rules only; no LLM cost |
| COMP-014 | Fix cost ledger ($0.00 bug) | M | Provider attribution broken since cascade |
| MEM-007 | Agent context-query before working on a gap | M | Reduces duplicate work across sessions |
| EVAL-028 | CatAttack robustness sweep | S | Harness already supports `--distractor`; run cost ~$1 |
| EVAL-035 | Belief-state ablation A/B | S | Single run ~$2; validates or cuts belief_state.rs |
| EVAL-038 | ASK_JEFF ambiguous-prompt A/B | S | Validates Social Cognition sensor |
| RESEARCH-001 | "2000+ A/B trials" blog post | M | Publishable; drives external credibility |
| FRONTIER-005 | goose competitive positioning | M | Strategic clarity on differentiation |

## This quarter (Q2) — P2, M effort, cleared dependencies

| ID | Title | Effort |
|----|-------|--------|
| EVAL-032 | Perception layer ablation A/B | M |
| EVAL-033 | Attention mitigation A/B | M |
| COG-020 | DeepMind 10-faculty architecture map | S |
| MEM-006 | Lessons-loaded-at-spawn | M |
| INFRA-AGENT-ESCALATION | Formal agent escalation pattern | M |
| INFRA-DISPATCH-POLICY | musher dispatch policy | M |
| COMP-008 | Recipes abstraction | M |
| COMP-009 | Extend MCP-server catalog to 6+ | M |

## Deferred to Q3+ (L/XL effort or blocked)

| ID | Title | Effort | Blocker |
|----|-------|--------|---------|
| EVAL-034 | Memory retrieval multi-hop QA | L | Needs SAKE infra |
| COG-024 | Default lessons-OFF | L | Needs EVAL-030 first |
| COMP-011b | Adversary mode full (LLM-based) | L | Needs COMP-011a results |
| EVAL-031 | Search-Augmented Reasoning | L | Speculative; needs AutoRefine study |
| EVAL-037 | Multi-agent coordination A/B | L | Needs coordination system stable |
| EVAL-039 | Longitudinal learning A/B | L | Needs months of reflection-DB data |
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
