# API token and USD budget worksheet (Lane B)

**Audience:** humans and agents preparing a **Lane B** run (`docs/RESEARCH_EXECUTION_LANES.md`).  
**Goal:** Turn **preregistration + batch command + vendor pricing** into a reproducible **token call count**, **order-of-magnitude USD**, and a sponsor-facing **budget cap** — without inventing methodology or silently changing `n`.

**Non-goals:** This doc does not store live prices. Always confirm **$/million tokens** on the vendor site (or your enterprise contract) on the **date you request budget**, and cite that URL in the batch sheet.

---

## 1. Sources you must read (in order)

| Step | Document | What to extract |
|------|----------|-----------------|
| 1 | [`docs/eval/preregistered/<GAP>.md`](./eval/preregistered/) | Hypothesis lock, **n per cell**, cells, **models per role** (agent / judges), fixtures, stop rules |
| 2 | Proposed or committed [`docs/eval/batches/YYYY-MM-DD-<GAP>.md`](./eval/batches/) | **Exact** harness argv, output tag, pilot vs full matrix |
| 3 | [`docs/TOGETHER_SPEND.md`](./TOGETHER_SPEND.md) | Env gates (`CHUMP_TOGETHER_JOB_REF`), sponsor block template |
| 4 | [`scripts/ab-harness/cost_ledger.py`](../scripts/ab-harness/cost_ledger.py) → `PRICING_USD_PER_M_TOKENS` | Repo’s **conservative** $/MTok table for reconciling estimates (must still match vendor for the models you use) |
| 5 | Vendor pricing (external) | [Anthropic Claude pricing](https://docs.anthropic.com/en/docs/about-claude/pricing), [Together serverless models](https://docs.together.ai/docs/serverless-models) (or [together.ai/pricing](https://www.together.ai/pricing/)) |

If argv, models, or `n` disagree with prereg → **stop** and add a **Deviations** entry to the prereg file (append-only); do not “just run” the convenient command.

---

## 2. Call accounting for `run-cloud-v2.py`

The harness loads `fixture["tasks"]` and truncates with `limit = min(len(tasks), args.limit)` where `args.limit` is set from `--limit` **or** overridden by `--n-per-cell` when present (`run-cloud-v2.py` after parse).

Let:

- **W** = number of tasks in the run = `min(full_fixture_count, limit)`.
- **C** = number of cells = **2** for `--mode ab` or `--mode aa`, **3** for `--mode abc`.
- **J** = number of judges = comma-separated length of `--judge` or `--judges` (mutually exclusive argv; same `dest` in `run-cloud-v2.py`).

Then **one** `run-cloud-v2.py` invocation performs:

| Role | Completions per invocation | Notes |
|------|---------------------------|--------|
| **Agent** | `W × C` | One agent completion per (task, cell). |
| **Each judge** | `W × C` | Every judge runs on every (task, cell) row (`trial()` loop). |

**Examples**

- `--mode abc --n-per-cell 100` on a fixture with ≥100 tasks → `W=100`, `C=3` → **300** agent completions; with **2** judges → **600** completions **per** judge model.
- Two separate invocations (e.g. haiku tier + sonnet tier per [`docs/eval/batches/2026-04-22-RESEARCH-018.md`](./eval/batches/2026-04-22-RESEARCH-018.md)) → **sum** the table above for **each** command before requesting total budget.

**Other harness scripts:** If the command is not `run-cloud-v2.py`, open that script (or its shell wrapper) and derive counts from its loops the same way — **no guessing**; cite the line structure or helper you used in the batch sheet notes.

---

## 3. Default token ceilings (harness defaults)

When you have **no** pilot JSONL yet, use these **ceilings** from `run-cloud-v2.py` so estimates are **conservative** (real usage is often lower):

| Call kind | `max_tokens` (completion cap) | Suggested input token **planning** range per call |
|-----------|-------------------------------|---------------------------------------------------|
| Agent (`call_anthropic` / Together / OpenAI path) | **800** | **2.5k–8k** in: task text + optional system (lessons / null-prose / task-aware block). RESEARCH-018 prereg cites ~2k-char lessons; with rubric-like system content, **plan toward the high end** for cell A/C. |
| Judge (`call_judge`) | **200** | **1.5k–6k** in: fixed judge system + rubric + agent answer (agent answer bounded by agent cap). |

These are **not** substitutes for measuring a pilot; they avoid underestimating.

---

## 4. Estimation tiers (pick one and say which)

### Tier A — Pilot-measured (preferred)

1. Run a **small** batch from the same batch sheet (e.g. `--n-per-cell 5` or fewer tasks) with keys present.
2. Inspect `logs/cost-ledger.jsonl` or run:

   ```bash
   python3.12 scripts/ab-harness/cost_ledger.py --report --group-by purpose
   ```

3. Sum **input_tokens** and **output_tokens** (or rolled-up `$`) for `v2-agent:*` vs `v2-judge:*` purposes.
4. Scale:  
   `estimate_tokens_role ≈ (pilot_tokens / pilot_W / pilot_C) × planned_W × planned_C`  
   (and the same pattern per judge). If pilot used fewer tasks, scale linearly in **W** only when the harness is linear in tasks.

### Tier B — Heuristic (before keys exist)

1. Compute **completion counts** from §2.
2. Assign per-role `(input_in, output_in)` using §3 ranges (use **high** input if sponsor budget is tight).
3. `tokens_in_role ≈ completions × input_in`, same for output.
4. Convert with vendor **$/MTok** (input and output often differ — use both columns).

Always label Tier B estimates explicitly in the batch sheet.

---

## 5. USD rollup

For each **model string** (e.g. `claude-haiku-4-5`, `claude-sonnet-4-5`, `meta-llama/Llama-3.3-70B-Instruct-Turbo`):

```
USD_model ≈ (tokens_in / 1e6) × $/MTok_in + (tokens_out / 1e6) × $/MTok_out
```

Sum across models → **subtotal**. Then:

- Add **headroom** (recommended **25–40%**) for retries, failed trials, rescoring (`rescore-jsonl.py`), or a second pilot.
- **Together-only cap:** If the sponsor splits Anthropic vs Together budgets, repeat the rollup **only** for models whose API id is Together (judge strings with `together:` prefix, or Together-routed agents).

**`CHUMP_TOGETHER_JOB_REF`:** The Together subtotal (plus Together-side headroom) must still fit the process in [`docs/TOGETHER_SPEND.md`](./TOGETHER_SPEND.md); the **approved USD** line is filled by a human.

---

## 6. What to paste into the Lane B batch sheet

After completing §§1–5, append to the batch markdown (same PR as the run):

- **Estimation tier:** A (pilot) or B (heuristic).
- **Completion counts:** agent = `…`; per-judge = `…` (show arithmetic from W, C, J).
- **Token assumptions:** table: model → assumed in/out per completion (or pilot totals).
- **Pricing citations:** Anthropic + Together URLs + **date checked**.
- **Subtotal USD by provider** (Anthropic sum, Together sum) + **headroom %** → **requested cap**.

This satisfies “token-based budget” traceability without storing volatile prices in git.

---

## 7. Instruction block for agents (copy into your prompt)

When a user asks you to **fill or review a Lane B budget**, do **all** of the following in your answer:

1. **List the files you used** (prereg path, batch path, `cost_ledger.py`, vendor URLs + date).
2. **Quote the exact harness command** (or confirm it matches the committed batch file).
3. **Derive W, C, J** and show **agent completions** and **completions per judge** using §2 formulas.
4. State **Tier A or Tier B** (§4). If Tier B, print the assumed input/output token row per model from §3.
5. Show **USD math** in a small table (model → in tok → out tok → $/MTok in/out from vendor → line USD).
6. Add **headroom** and give a **single recommended `Budget cap (USD)`** for the batch sheet **and** the Together-only slice if applicable.
7. **Explicit gaps:** If fixture size, `--limit`, or argv is ambiguous, **ask** — do not guess W.

---

## 8. Related commands

```bash
# After any paid pilot
python3.12 scripts/ab-harness/cost_ledger.py --report --group-by model
python3.12 scripts/ab-harness/cost_ledger.py --json
```

---

## 9. Minimal batch skeleton (commit under `docs/eval/batches/`)

See also **§5** of [`docs/RESEARCH_EXECUTION_LANES.md`](./RESEARCH_EXECUTION_LANES.md) for the core fields.

```markdown
Batch ID: YYYY-MM-DD-research-0XX
Gap(s): RESEARCH-018
Prereg commit SHA: <git rev-parse for prereg file>
Harness command (exact, single line):
  python3.12 scripts/ab-harness/run-cloud-v2.py …
Output tag / log dir: logs/ab-harness/<tag>*
Budget cap (USD): <sponsor-filled>   Actual (after): __
Stop rule: per prereg §6
Owner (human or session): __

## Token / USD estimate (see docs/API_TOKEN_BUDGET_WORKSHEET.md)
- Tier: A | B
- W=__, C=__, J=__ → agent completions=__; per-judge completions=__
- Assumptions + vendor URLs + date checked:
- Anthropic USD (est): __
- Together USD (est): __
- Headroom: __% → requested cap: __
```
