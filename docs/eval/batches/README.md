## Lane B batch sheets

This folder is the **audit trail for paid / preregistered research runs** (Lane B).

- Create **one** batch sheet **before spending**.
- Name it `YYYY-MM-DD-<GAP-ID>.md`.
- Include the **exact single-line command** you will run and the intended output tag/dir.
- If you deviate from prereg (models, n, judges, fixtures, stop rules), log the deviation **in the prereg doc** (append-only), not by editing locked fields.

Template to copy is in `docs/RESEARCH_EXECUTION_LANES.md` §5.

# Lane B batch records (audit trail)

**Purpose:** Every **preregistered paid sweep** (Lane B) gets a **committed**
markdown file **before** spend starts. That gives the team a durable record:
who sponsored budget, exact command line, output tag, and stop rules.

**Playbook:** [`docs/RESEARCH_EXECUTION_LANES.md`](../../RESEARCH_EXECUTION_LANES.md) §5–§8.

---

## How to add a batch

1. Copy [`TEMPLATE.md`](TEMPLATE.md) (or the §5 **Lane B batch sheet** in
   `RESEARCH_EXECUTION_LANES.md`).
2. Fill every field (no placeholders left).
3. Save as **`YYYY-MM-DD-<GAP-ID>.md`** in this directory (example:
   `2026-04-28-RESEARCH-018.md`).
4. Commit it on the **same branch** as the harness/results PR **before** you
   begin paying for trials (or as the first commit of that PR).
5. Paste the same block into the GitHub PR description.

---

## Naming

- One file per **batch** (a single frozen `run-cloud-v2.py` invocation or agreed
  equivalent). If you stop and resume with different argv, open a **new** file.

---

## After the run

Append to the same file (or link a sibling result doc):

- Actual cost (USD) and wall-clock
- Path to JSONL / `logs/ab-harness/` tag
- Link to `docs/eval/RESEARCH-*-*.md` results
- Prereg **Deviations** pointer if anything changed vs lock
