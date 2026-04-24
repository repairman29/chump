# `docs/audit/` — static/license/CVE sweep output (INFRA-044)

This directory is written by **`scripts/audit/run-all.sh`**, the dispatcher that
covers **Stage A** of the AI pre-audit pipeline described in
[`docs/EXPERT_REVIEW_PANEL.md`](../EXPERT_REVIEW_PANEL.md): "Static & license
sweep — `cargo clippy --pedantic`, `cargo-deny`, `cargo-audit`, `cargo-udeps`,
`cargo-machete`, `lychee`."

## Running

```bash
# One-shot local run
scripts/audit/run-all.sh

# Only a single tool
scripts/audit/run-all.sh --tool clippy

# Also stage suggested follow-up gap templates for critical findings
AUDIT_AUTO_FILE_GAPS=1 scripts/audit/run-all.sh
```

The dispatcher never exits non-zero on individual tool failures — missing
tools are recorded as `SKIPPED` and tool failures as `FAIL` with a severity
tier so CI can run the sweep weekly without blocking on advisory-db churn.

## Output layout

```
docs/audit/
├── README.md                        (this file)
├── findings-YYYY-MM-DD.md           (aggregated, severity-tiered report)
└── raw/
    ├── clippy-YYYY-MM-DD.log
    ├── cargo-deny-YYYY-MM-DD.log
    ├── cargo-audit-YYYY-MM-DD.log
    ├── cargo-udeps-YYYY-MM-DD.log
    ├── cargo-machete-YYYY-MM-DD.log
    └── lychee-YYYY-MM-DD.log
```

## Severity tiers

| Tier | Meaning | Action |
|------|---------|--------|
| critical | CVE, license conflict, RUSTSEC advisory | Auto-file a gap; block commercial ship |
| high | Build-breaking warning promoted to error | Fix in next batch PR |
| medium | `clippy::pedantic` lints | Batch-ship a refactor PR |
| low | Dead deps, doc link rot | File a janitor gap when count > 10 |
| info | Tool clean or skipped | No action |

## Weekly CI

[`.github/workflows/audit-weekly.yml`](../../.github/workflows/audit-weekly.yml)
runs the dispatcher every Monday 09:00 UTC and uploads `docs/audit/` as a
90-day-retained artifact. Manual trigger: **Actions → audit-weekly → Run
workflow**.

## Scope & non-goals

In scope:

- Dispatcher at `scripts/audit/run-all.sh` running the six tools above.
- Aggregated `findings-YYYY-MM-DD.md` with severity tiers.
- Auto-file suggestion for critical findings (opt-in via env var).
- Weekly CI wiring.

**Not** in scope (per INFRA-044 description — "this gap surfaces only — fixes
land as follow-up gaps from findings"):

- Actually fixing clippy/audit/deny findings.
- Running other stages of the AI pre-audit pipeline (Stage E onboarding-sim is
  [DOC-004](../gaps.yaml); Stage G safety audit is [PRODUCT-018](../gaps.yaml)).
- Human-reviewer dispatching from `docs/EXPERT_REVIEW_PANEL.md` — that is
  Tier 3 review, a separate future gap.
