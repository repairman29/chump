# Federal opportunities: what’s “on the market” and how to track it

**Audience:** Solo/LLC builder (software, agents, cyber-adjacent) hunting **live solicitations** and **market intel**. Complements [DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md) and [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md).

**Not legal advice.** Dates and portals change—verify on official sites.

---

## 1. Two different questions

| Question | Best source |
|----------|-------------|
| **What can I bid right now?** (solicitations, RFPs, sources sought) | **[SAM.gov](https://sam.gov) → Contract Opportunities** (and agency-specific portals some notices link to) |
| **Who won what?** (incumbents, NAICS, agencies that buy your thing) | **[USAspending.gov](https://www.usaspending.gov/)** — [API](https://api.usaspending.gov/) works **without** an API key for many read endpoints |

---

## 2. SAM.gov — live federal opportunities (primary)

### UI (fastest to start)

1. Go to [sam.gov](https://sam.gov) → **Search** → **Contract Opportunities**.
2. Filters that usually match a small software shop:
   - **Notice type:** Solicitation, Combined Synopsis/Solicitation, Presolicitation (as needed).
   - **Set-aside:** Total Small Business, Partial Small Business, 8(a) (if certified), etc.
   - **NAICS:** e.g. **541511** (custom computer programming), **541512** (computer systems design), **541519** (other computer related), **541330** (engineering—sometimes IT task orders use adjacent NAICS).
   - **Place of performance:** **Colorado** if you want local; leave open if you can perform remotely (read each solicitation—some require on-site).
3. Sort by **Posted date** or **Response date**; **save** searches if SAM offers saved search / email alerts (account required).

### API (automation after you have SAM + key)

Official docs: [SAM.gov Get Opportunities Public API](https://open.gsa.gov/api/get-opportunities-public-api/).

- Get a **public API key** from your SAM.gov profile (**Profile → API keys** or current equivalent—see SAM help if menu moves).
- Production endpoint (per GSA): `https://api.sam.gov/opportunities/v2/search`
- **Required:** `api_key`, `postedFrom`, `postedTo` (MM/DD/YYYY), **`limit`**. Date range cannot exceed **one year**.
- Optional: `title` (title search only—no full-text body search in v2), `ptype`, `ncode` (NAICS), etc.—see OpenAPI on the GSA page.

**Example (run locally after you export `SAM_API_KEY`):**

```bash
export SAM_API_KEY="your_key_from_sam_gov_profile"
curl -sS "https://api.sam.gov/opportunities/v2/search?api_key=${SAM_API_KEY}&postedFrom=01/01/2026&postedTo=04/10/2026&limit=25&title=software" \
  | python3 -m json.tool | head -200
```

If you get **404** or **403**, re-check the **exact** base path on [open.gsa.gov](https://open.gsa.gov/api/get-opportunities-public-api/) (GSA has used both `https://api.sam.gov/opportunities/v2/search` and `https://api.sam.gov/prod/opportunities/v2/search` in examples) and confirm your key is **active** and **not over daily limits** (public tier limits apply).

---

## 3. USAspending — intel, not bidding

Use this to find **agencies**, **incumbents**, and ** realistic deal sizes** before you chase a NAICS.

**Example:** Recent **smaller** awards (rough filter) in custom programming / systems design NAICS — `POST /api/v2/search/spending_by_award/`:

```bash
curl -sS -X POST "https://api.usaspending.gov/api/v2/search/spending_by_award/" \
  -H "Content-Type: application/json" \
  -d '{
    "filters": {
      "award_type_codes": ["A","B","C","D"],
      "time_period": [{"start_date": "2025-01-01", "end_date": "2026-04-10"}],
      "naics_codes": ["541511", "541512", "541519"],
      "award_amounts": [{"lower_bound": 10000, "upper_bound": 2500000}]
    },
    "fields": ["Award ID", "Recipient Name", "Award Amount", "Start Date", "NAICS", "Awarding Sub Agency"],
    "page": 1,
    "limit": 25,
    "sort": "Start Date",
    "order": "desc"
  }' | python3 -m json.tool
```

That returns **historical awards**, not open RFPs—but it answers “who is winning sub-$2M IT-ish work across civilian + defense components?” Useful for **teaming targets** and **agency lists**.

---

## 4. Defense-specific “open innovation” (not the full SAM firehose)

- **DIU:** Problem statements and CSO-style work: [diu.mil](https://www.diu.mil) — watch **Commercial Solutions Openings** aligned to software/AI.
- **DoD SBIR/STTR:** **Frozen** until DSIP shows reauthorization; still useful for **topic language** ([DEFENSE_MARKET_RESEARCH.md](DEFENSE_MARKET_RESEARCH.md) §1).

---

## 5. State of Colorado (you live/work there)

Federal SAM is the big pool; **Colorado** also buys IT and professional services:

- Use **[Colorado VSS / state procurement](https://www.colorado.gov/)** (search for current **Vendor self-service** / **bid opportunities**—portal names change; start from CO’s central procurement page).
- **SLED** wins are often **faster** first dollars and **past performance** bullets for federal primes.

---

## 6. Weekly rhythm (30 minutes)

| When | Action |
|------|--------|
| **Monday** | SAM saved search: **new** opportunities in your NAICS + small business set-aside; skim titles in 10 minutes. |
| **Wednesday** | USAspending: one query per **target agency** or **NAICS**; note 3 incumbents to research on LinkedIn. |
| **Friday** | DIU + (if relevant) **GSA eBuy** (only after you hold a Schedule—skip until then). |

---

## 7. Realistic expectations for a brand-new LLC

- Many “open” RFPs expect **past performance**, **clearances**, or **CMMC**—you will still **lose** most bids early; the win is **learning** + **one** subcontract or **state** win.
- **Prime path:** use SAM + USAspending to **name** who wins, then **outreach** (see [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md)).

---

## Revision

SAM API paths and UI labels change; re-verify against [open.gsa.gov](https://open.gsa.gov/) and SAM help if a recipe breaks.
