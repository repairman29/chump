# Product reality check (avoid “invented stats” reviews)

**Problem:** Write-ups that mix **real architectural critique** with **wrong dates, test counts, or timelines** look authoritative but train the team on fiction. That erodes trust in retrospectives and in external messaging.

**Fix:** Separate **opinion** (latency feels slow, breadth vs depth) from **facts** pulled from the repo with one command.

---

## Before any “balanced product review” or investor-style memo

1. Run from repo root:

   ```bash
   ./scripts/print-repo-metrics.sh
   ```

2. Paste the **entire Markdown table** into the review doc (or appendix). Update the narrative to match those numbers, or label numbers as **subjective / timed on machine X**.

3. For **first-run truth**, cite one of:

   - [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) (timed rows + cold clone table),
   - `./scripts/verify-external-golden-path.sh` (CI + local compile gate),
   - `./scripts/golden-path-timing.sh` (build wall time JSONL in CI artifacts).

4. For **adoption evidence**, cite [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §4 / [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) blind session table — do **not** claim “five blinds done” until those rows are filled.

---

## Weekly maintainer ritual (~20 minutes)

| Step | Action |
|------|--------|
| 1 | \`./scripts/print-repo-metrics.sh\` — confirm doc/test counts moved as expected after big merges. |
| 2 | Run **one** row of [DAILY_DRIVER_95_STEPS.md](DAILY_DRIVER_95_STEPS.md) you have **not** done this week (honest progress on the 95-step plan). |
| 3 | If a review claimed a bug is “fixed,” verify with the smallest automated check that touches it (unit test, \`verify-external-golden-path\`, or Playwright slice). |

---

## Cadence vs scope creep

- **Daily-driver first** is already the documented bias: [DAILY_DRIVER_95_STEPS.md](DAILY_DRIVER_95_STEPS.md), [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md) Horizon 1, [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md).
- New flagship features belong **behind** green gates: launch table in [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md), not ahead of them.

---

## Related

- [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) — launch gate + matrix  
- [SCRIPTS_REFERENCE.md](SCRIPTS_REFERENCE.md) — \`print-repo-metrics.sh\`  
- [CONTINUAL_LEARNING.md](CONTINUAL_LEARNING.md) — AGENTS.md / transcript mining (preferences, not repo stats)
