# API vendor pricing — monthly refresh (Chump + humans)

**Why:** [`docs/API_TOKEN_BUDGET_WORKSHEET.md`](./API_TOKEN_BUDGET_WORKSHEET.md) and [`scripts/ab-harness/cost_ledger.py`](../scripts/ab-harness/cost_ledger.py) depend on **current** public $/million-token rates. Vendors change prices; this process keeps **search-backed digests** and (when needed) the ledger table aligned.

**Cadence:** at least **monthly** (calendar **1st** is the default anchor; a GitHub reminder fires on the 1st — see below). Sooner after any announced price change.

---

## 1. What gets updated

| Artifact | Who updates | Notes |
|----------|-------------|--------|
| [`docs/API_PRICING_SNAPSHOT.md`](./API_PRICING_SNAPSHOT.md) | Script **or** Chump agent | Append-only digests between `<!-- SNAPSHOT:*_START -->` markers (script replaces the block). |
| [`scripts/ab-harness/cost_ledger.py`](../scripts/ab-harness/cost_ledger.py) `PRICING_USD_PER_M_TOKENS` | Human review after digest | Only when vendor rates **materially** change; keep comment “Updated YYYY-MM-DD” + source URLs. |
| Batch sheets / open PRs | Humans | Historical batches are **not** retro-edited; new runs cite the snapshot date. |

---

## 2. Option A — scripted refresh (Tavily API)

**Requires:** `TAVILY_API_KEY` in the environment (same as Chump web search — see [`docs/OPERATIONS.md`](./OPERATIONS.md), [`crates/mcp-servers/chump-mcp-tavily`](../crates/mcp-servers/chump-mcp-tavily/README.md)).

```bash
cd "$(git rev-parse --show-toplevel)"
export TAVILY_API_KEY="tvly-…"   # or: set -a && source .env && set +a
bash scripts/refresh-api-pricing-snapshot.sh
```

The script calls Tavily’s **search** HTTP API (same contract as `chump-mcp-tavily`), writes digested snippets into `docs/API_PRICING_SNAPSHOT.md`, then prints **follow-ups**: re-open the snapshot, compare to Anthropic/Together official pages, and patch `cost_ledger.py` if the table is stale.

**CI:** This script is **not** run in default CI (no secrets on PRs). Optional: add org secret `TAVILY_API_KEY` and a **manual** `workflow_dispatch` workflow if you want GitHub-hosted refreshes later.

---

## 3. Option B — Chump (or any MCP agent) with Tavily

When **`TAVILY_API_KEY`** is configured, Chump already exposes Tavily-backed **`web_search`** (unless `CHUMP_AIR_GAP_MODE=1` — see [`docs/OPERATIONS.md`](./OPERATIONS.md)).

**Prompt template (paste monthly or after vendor announcements):**

```
Task: refresh API pricing artifacts for Lane B budgeting.

1. Read docs/API_PRICING_MAINTENANCE.md and docs/API_TOKEN_BUDGET_WORKSHEET.md §1.
2. Use web_search (Tavily) with queries focused on OFFICIAL pages:
   - Anthropic: current $/MTok for claude-haiku-4-5 and claude-sonnet-4-5 (and any judge models we use) on docs.anthropic.com pricing.
   - Together: serverless $/MTok for meta-llama/Llama-3.3-70B-Instruct-Turbo on docs.together.ai or together.ai pricing.
3. Update docs/API_PRICING_SNAPSHOT.md: set "Last refresh (UTC)" to now, replace the two digest sections with concise bullet summaries + URLs + "checked as of <date>".
4. If rates changed vs scripts/ab-harness/cost_ledger.py PRICING_USD_PER_M_TOKENS, update that dict (conservative rounding), bump the "Updated" comment, and list models touched.
5. Open a single PR; commit message: "chore(pricing): refresh API pricing snapshot <YYYY-MM-DD>".
```

If you later wire **Brave Search** (or another provider) into Chump, keep the same prompt shape: **official-domain snippets first**, then update the snapshot and ledger after human skim.

---

## 4. Option C — Brave Search API (optional)

Not bundled in-repo today. If you add a Brave MCP server or HTTP tool:

- Restrict queries to `site:anthropic.com`, `site:docs.anthropic.com`, `site:together.ai`, `site:docs.together.ai` to reduce blog spam.
- Still write results into **`docs/API_PRICING_SNAPSHOT.md`** using the same section headings so humans can diff month-over-month.

---

## 5. Verification checklist (always human)

- [ ] Open each **official** pricing URL from the snapshot and confirm the table row you care about (Haiku / Sonnet / Llama 3.3 70B-Turbo).
- [ ] If `cost_ledger.py` changed, run a tiny local harness pilot or `python3.12 scripts/ab-harness/cost_ledger.py --report` sanity check.
- [ ] `bash scripts/research-lane-a-smoke.sh` still passes (no Python syntax regressions).

---

## 6. Automation already in-repo

| Mechanism | Purpose |
|-----------|---------|
| [`.github/workflows/api-pricing-monthly-reminder.yml`](../.github/workflows/api-pricing-monthly-reminder.yml) | On the **1st of each month**, opens a **tracking issue** with a link to this doc and the script (no API keys required). |

Close the issue after the refresh PR merges.
