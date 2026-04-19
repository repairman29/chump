# Sprint Roadmap

Two-week sprints for near-term execution. Feeds into [ROADMAP.md](ROADMAP.md) (checked tasks) and [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) (Q2 priorities). Sprint IDs are not gap IDs — sprints bundle several gaps into a shippable slice.

## Current — S1 (2026-04-14 to 2026-04-27)

**Theme:** Validation + infra hardening

| Gap | Title | Owner | Status |
|-----|-------|--------|--------|
| COG-016 | Model-tier-aware lessons gate | auto | done |
| EVAL-025 | COG-016 directive validation (n=100) | auto | done |
| INFRA-MERGE-QUEUE | GitHub merge queue | auto | done |
| INFRA-PUSH-LOCK | Pre-push hook | auto | done |
| AUTO-013 (steps 1–2) | Chump-orchestrator MVP scaffold | auto | done |
| COG-023 | Sonnet carve-out from COG-016 | auto | in-queue |
| EVAL-030 | Task-class-aware lessons block | auto | in-queue |

**Exit criteria:** COG-023 + EVAL-030 shipped; chump-orchestrator step 3 started.

---

## S2 (2026-04-28 to 2026-05-11)

**Theme:** Measurement + quality gates

| Gap | Title | Est. effort |
|-----|-------|-------------|
| EVAL-028 | CatAttack adversarial robustness sweep | S |
| EVAL-035 | Belief-state ablation A/B | S |
| EVAL-038 | ASK_JEFF ambiguous-prompt A/B | S |
| INFRA-AGENT-CODEREVIEW | Code-reviewer agent for src/* PRs | M |
| INFRA-COST-CEILING | Per-session spend cap | S |
| COMP-014 | Fix cost ledger ($0.00 bug) | M |
| MISTRALRS-MULTIMODAL | RFC-mistralrs-multimodal-in-tree accept/reject | S |

---

## S3 (2026-05-12 to 2026-05-25)

**Theme:** Discovery + external credibility

| Gap | Title | Est. effort |
|-----|-------|-------------|
| RESEARCH-001 | "2000+ A/B trials" blog post | M |
| COMP-010 | Brew formula + signed installer | S |
| COMP-013 | MCPwned / DNS rebinding audit | S |
| MEM-007 | Agent context-query before gap work | M |
| EVAL-032 | Perception layer ablation A/B | M |
| MISTRALRS-STRUCTURED | Structured-output spike (llama-server compat) | M |

---

## Deferred (S4+)

| Gap | Reason for deferral |
|-----|---------------------|
| COG-024 | Needs EVAL-030 + EVAL-028 results first |
| EVAL-034 | Needs SAKE infra |
| EVAL-037 | Multi-agent coordination must be stable |
| COMP-011b | Needs COMP-011a static-rules results |

---

## See Also

- [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) — Q2 2026 cut (same items, sorted by leverage)
- [ROADMAP_FULL.md](ROADMAP_FULL.md) — complete gap registry
- [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) — mistral.rs inference milestones
