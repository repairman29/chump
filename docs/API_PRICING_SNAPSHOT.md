# API pricing snapshot (Lane B cross-check)

**Not a contract.** Sponsor-facing caps still require live vendor pages on the **approval date** ([`docs/API_TOKEN_BUDGET_WORKSHEET.md`](./API_TOKEN_BUDGET_WORKSHEET.md)). This file is a **durable, repo-local digest** of what Tavily (or an agent) last saw so diffs month-over-month are easy.

| Field | Value |
|-------|-------|
| **Last refresh (UTC)** | _run `bash scripts/refresh-api-pricing-snapshot.sh`_ |
| **Method** | See [`docs/API_PRICING_MAINTENANCE.md`](./API_PRICING_MAINTENANCE.md) |

**Official sources of truth (bookmark):**

- Anthropic — [Claude pricing](https://docs.anthropic.com/en/docs/about-claude/pricing)
- Together — [Serverless models](https://docs.together.ai/docs/serverless-models) · [Pricing hub](https://www.together.ai/pricing)

---

## Anthropic (search digest)

<!-- SNAPSHOT:ANTHROPIC_START -->
_Pending first run of `scripts/refresh-api-pricing-snapshot.sh` (requires `TAVILY_API_KEY`) or manual paste per [`docs/API_PRICING_MAINTENANCE.md`](./API_PRICING_MAINTENANCE.md) §3._
<!-- SNAPSHOT:ANTHROPIC_END -->

---

## Together (search digest)

<!-- SNAPSHOT:TOGETHER_START -->
_Pending first run of `scripts/refresh-api-pricing-snapshot.sh` (requires `TAVILY_API_KEY`) or manual paste per [`docs/API_PRICING_MAINTENANCE.md`](./API_PRICING_MAINTENANCE.md) §3._
<!-- SNAPSHOT:TOGETHER_END -->

---

## Models mirrored in `cost_ledger.py` (verify after each refresh)

Chump research harness commonly bills:

- `claude-haiku-4-5` / dated variants  
- `claude-sonnet-4-5` / dated variants  
- `meta-llama/Llama-3.3-70B-Instruct-Turbo` (Together serverless)

If Together or Anthropic rename slugs, update **both** this snapshot narrative and `PRICING_USD_PER_M_TOKENS` keys to match what the harness records in `logs/cost-ledger.jsonl`.
