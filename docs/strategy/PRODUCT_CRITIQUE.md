---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# Product Critique

Quarterly pass over Chump's product quality — launch gates, onboarding experience, and known gaps. Companion to [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) (current state) and [RED_LETTER.md](RED_LETTER.md) (adversarial weekly review).

## Launch gates

| Gate | ID | Status | Notes |
|------|----|---------|----|
| Cold clone → working bot under 30 min | L1 | ✓ Pass | EXTERNAL_GOLDEN_PATH.md verified |
| `cargo build` time < 10 min | L2 | ✓ Pass | ~7 min on M4 (noted in friction log) |
| Preflight passes on clean `.env` | L3 | ✓ Pass | `chump-preflight.sh` checks health + stack-status |
| No secrets in `.env.example` | L4 | ✓ Pass | Uses placeholder values |
| `config/` excluded from git | L5 | ✗ FAIL | `config/config.yaml` leaked Together.ai key (fba4b11); `.gitignore` fix needed |
| Battle QA pass rate ≥ 85% | L6 | 🔧 Unknown | No recent documented run; last known ~87–92% |
| FTUE completes without error | L7 | ✓ Pass | `complete_onboarding` tool tested |
| `/api/health` responds within 2s cold | L8 | ✓ Pass | Observed in soak; pre-fork in release build |

## Quarterly critique (Q1 2026 — completed)

**Shipped:**
- Multi-surface (Discord, PWA, CLI, Slack, Telegram)
- ACP (Zed/JetBrains) with 96 unit tests
- Consciousness framework A/B validated at preregistered power (specifics private)
- Multi-agent coordination (lease files, gap-claim, bot-merge pipeline)
- Provider cascade (8 providers, ~72k free RPD)

**Critical gaps at Q1 close:**
- Lessons-block fake-tool-call amplification on weak-tier substrates — patch P1 but not yet shipped (task-class-aware lessons + frontier-tier carve-out in progress; specifics private)
- Published benchmarks: empty table in BENCHMARKS.md
- 946 `unwrap()` calls in production code
- Credential leak in git history (Together.ai key)

## Quarterly critique (Q2 2026 — in progress)

**Focus for Q2:**
- Ship the frontier-tier carve-out and the task-class-aware lessons gap
- Run and publish BENCHMARKS.md results
- Cross-family judge validation (Ollama integration onward)
- Adversary-mode-lite (COMP-011a)
- Fix cost ledger $0.00 bug (COMP-014)

## See Also

- [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) — detailed honest assessment
- [RED_LETTER.md](RED_LETTER.md) — weekly adversarial review
- [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) — friction entries with resolutions
- [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — market positioning
