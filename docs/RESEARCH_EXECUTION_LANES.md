# Research execution — Lane A (always-on) vs Lane B (batched spend)

**Goal:** Keep **repo velocity** high on free tiers and offline work while **batching paid API runs** so we do not stall Paper-1 methodology or unrelated engineering.

**Related:** [`docs/eval/preregistered/COST_OPTIMIZATION.md`](./eval/preregistered/COST_OPTIMIZATION.md) (Together free-tier substitutions), [`docs/RESEARCH_INTEGRITY.md`](./RESEARCH_INTEGRITY.md) (judge-family rules), [`docs/TOGETHER_SPEND.md`](./TOGETHER_SPEND.md) (budget ticket + env gates before paid Together runs).

---

## 1. Definitions

| Lane | What belongs here | Success signal |
|------|-------------------|----------------|
| **A — Free / offline** | Harness flags, preregistration, fixtures, deterministic tests, re-analysis of **existing** JSONLs, infra, docs, local or Together **free-tier** smokes | Merged PRs, green CI, reproducible commands, PRELIMINARY notes where appropriate |
| **B — Batched cloud spend** | Preregistered sweeps that require **Anthropic** and/or large **n** per [`docs/eval/preregistered/*.md`](./eval/preregistered/) | One frozen run → one results doc + FINDINGS row; deviations logged in prereg |

**Rule:** Lane B never blocks Lane A. If credits are low, **ship Lane A** and park Lane B behind an explicit “go / budget” decision.

---

## 2. Weekly cadence (suggested)

1. **Monday — pick Lane A slices** (2–3 concrete PRs): infra, harness tests, doc gaps, eval plumbing.
2. **Mid-week — merge Lane A**; run `bash scripts/research-lane-a-smoke.sh` before any ab-harness touch.
3. **Friday — Lane B checkpoint (15 min):** Do we have budget for a batched run next week? If yes, fill **Lane B batch sheet** (§5). If no, defer; Lane A continues.

---

## 3. RESEARCH-018 (length-matched control) — phased

**Prereg:** [`docs/eval/preregistered/RESEARCH-018.md`](./eval/preregistered/RESEARCH-018.md) (locked hypothesis, n=100/cell, 600 trials Lane B).

### Lane A (do now; $0 marginal)

- [x] Harness: `--mode abc --null-prose-match` in `scripts/ab-harness/run-cloud-v2.py` + `gen-null-prose.py`.
- [x] **Smoke:** `bash scripts/research-lane-a-smoke.sh` (self-test + `py_compile`).
- [x] **Dry command template** — pilot + preregistered **n=100/cell** argv (haiku + sonnet invocations) in [`docs/eval/batches/2026-04-22-RESEARCH-018.md`](./eval/batches/2026-04-22-RESEARCH-018.md).
- [x] **Result doc stub** — [`docs/eval/RESEARCH-018-length-matched.md`](./eval/RESEARCH-018-length-matched.md) (**NOT RUN** until JSONL exists).

### Lane B (batched; preregistered n)

- **600 trials** (3 cells × 2 Anthropic tiers × n=100) per prereg §3–4. Interim **n=50 peek** is allowed **only** for smoke-gating per prereg §6 — not for claiming H1/H0.
- **After run:** fill FINDINGS “length-matched control” row + link result doc; append any deviation under prereg §Deviations.

**Free-tier note:** Anthropic agent + judge cells are **not** free-tier substitutes for the preregistered primary matrix. Use Together only where prereg already allows (e.g. Judge 2); do not swap agent tiers without a prereg deviation.

---

## 4. RESEARCH-021 (four families) — phased under credit ceiling

**Prereg:** [`docs/eval/preregistered/RESEARCH-021.md`](./eval/preregistered/RESEARCH-021.md).

**Full AC** (1600 trials + cross-family judges) is **Lane B heavy**; see COST_OPTIMIZATION for Together-first agent substitution where prereg permits.

### Lane A (do now)

- [x] **Table of families × tiers × cells** — [`docs/eval/batches/2026-04-22-RESEARCH-021.md`](./eval/batches/2026-04-22-RESEARCH-021.md) + prep stub [`docs/eval/RESEARCH-021-tier-dependence-4-family.md`](./eval/RESEARCH-021-tier-dependence-4-family.md).
- [x] **Per-family dry run** — commands for **n=1–5** pilots in the batch sheet; Anthropic path runnable without Together; Together-backed families **blocked on `TOGETHER_API_KEY`** (see [`docs/RESEARCH_AGENT_REVIEW_LOG.md`](./RESEARCH_AGENT_REVIEW_LOG.md)).
- [x] **Judge wiring check** — panel strings captured in batch sheet vs prereg; full cross-family execution still needs Together (same log).

### Lane B (batched)

- Prefer **one family at full n=100/cell** *or* **full matrix at reduced n** only if prereg is amended with a deviation entry — do not silently change n.
- Default when budget is tight: **Family 1 (Anthropic) complete** → pause → **Family 2** next budget window (preserves interpretable story).

---

## 5. Lane B batch sheet (copy per run)

Fill this **before** spending; **commit** a copy as
`docs/eval/batches/YYYY-MM-DD-<gap-id>.md` (see
[`docs/eval/batches/README.md`](./eval/batches/README.md)) **and** paste the
same block into the PR that adds JSONLs or the results doc.

```
Batch ID: YYYY-MM-DD-research-0XX
Gap(s): RESEARCH-018 | RESEARCH-021 | …
Prereg commit SHA: _______________
Harness command (exact, single line):
  ________________________________________________
Output tag / log dir: logs/ab-harness/____________
Budget cap (USD): __   Actual (after): __
Stop rule: per prereg §6 / other: ________________
Owner (human or session): ________________
```

---

## 6. Commands reference

| Intent | Command |
|--------|---------|
| Null-prose generator self-test | `python3.12 scripts/ab-harness/gen-null-prose.py --self-test` |
| Lane A smoke (harness import surface) | `bash scripts/research-lane-a-smoke.sh` |
| Lessons A/B/C cloud entrypoint (when running Lane B) | `bash scripts/ab-harness/run-cloud-v2-with-env.sh --help` — loads repo-root `.env`, then same CLI as `run-cloud-v2.py` (`--mode abc`, `--null-prose-match`, `--n-per-cell`, …) |

---

## 7. When you are unsure

- **If it needs an API key and changes n, models, or judges vs prereg →** Lane B + deviation doc, not a silent reroll.
- **If it is code, tests, or re-reading old JSONLs →** Lane A.
- **If Together free tier is flaky that day →** stay on Lane A; reschedule Lane B.

---

## 8. Team / system setup (how we run this)

### 8.1 Roles (keep it lightweight)

| Role | Responsibility |
|------|----------------|
| **Lane A owner (rotating)** | Each week, ensures ≥1 merged PR touches harness/docs/tests without API spend; green `research-lane-a-smoke` locally before push. |
| **Lane B sponsor (human)** | Approves **budget + wall-clock** for a batch; signs the batch file in `docs/eval/batches/` (name + date in the markdown). |
| **Runner** | Whoever executes the sweep: fills §5 template, runs commands from a **linked worktree**, commits JSONL + results under the same PR as far as possible. |

Agents and bots follow the same split: **claim infra / harness gaps** freely; **do not** mark RESEARCH-018/021 `done` until preregistered acceptance criteria and write-ups exist ([`AGENTS.md`](../AGENTS.md) learned preference).

### 8.2 System wiring (already in repo)

| Mechanism | What it does |
|-----------|----------------|
| **`bash scripts/research-lane-a-smoke.sh`** | Fast regression gate: null-prose self-test, `py_compile` on cloud-v2 + spend gate + observer/ledger/sync helpers, `bash -n` on `run-cloud-v2-with-env.sh`, `--help` on key CLIs, `together_spend_gate.py` self-test. |
| **GitHub Actions** | `ci.yml` **test** job runs that script on every PR touching the normal Rust path — Lane A stays protected without API keys in CI. |
| **`docs/eval/batches/`** | Audit trail: one committed markdown per Lane B batch **before** spend (§5 template). |
| **Prereg + pre-commit** | `docs/eval/preregistered/<GAP>.md` + `CHUMP_PREREG_CHECK` guard — no silent methodology drift. |
| **Coordination** | `scripts/gap-reserve.sh`, `gap-preflight.sh`, `gap-claim.sh`, `bash scripts/fleet-status.sh` — same lease bar as engineering work ([`docs/AGENT_LOOP.md`](./AGENT_LOOP.md)). |

### 8.3 Lane B execution environment (secrets)

- **Default:** runner uses **local workstation or dedicated runner** with API keys in `.env` (never commit). CI does **not** need Anthropic/Together keys for Lane B.
- **Optional later:** a **manual `workflow_dispatch`** workflow that accepts a tagged script + budget cap — only add if the team wants centralized reruns; still keep sponsor approval out-of-band (Slack / issue comment).

### 8.4 Labels / triage (GitHub)

Suggested labels (create once in the repo): **`research-lane-a`**, **`research-lane-b`**. Lane B PRs must include the batch file path in the description for audit.

### 8.5 Meeting rhythm (15 min / week)

Agenda: (1) Lane A shipped? (2) Smoke green on `main`? (3) Lane B go/no-go + sponsor? (4) Assign next week’s Lane A owner.

---

## 9. Onboarding one-liner

> **Lane A every day** (CI + smoke); **Lane B only with a committed batch file + sponsor + frozen command** — see `docs/eval/batches/README.md`.
