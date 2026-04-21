# RESEARCH-018 — Null-prose generator (Cell C infrastructure)

**Part of:** RESEARCH-018 length-matched scaffolding-as-noise control
**Preregistration:** [`preregistered/RESEARCH-018.md`](preregistered/RESEARCH-018.md)
**Ships:** `scripts/ab-harness/gen-null-prose.py`
**Does not close:** RESEARCH-018 — this is one of several pieces (harness integration + sweep still pending).

---

## What this ships

`scripts/ab-harness/gen-null-prose.py` produces a deterministic markdown-
structured block of semantically-null random prose, length-matched to a
target character count. It is the **Cell C** content needed to run
RESEARCH-018's three-cell design:

- **Cell A** — real COG-016 lessons block (~2,000 chars, directive content)
- **Cell B** — no injection
- **Cell C** — length-matched null prose (~2,000 chars, no directive content)

Without Cell C, we cannot distinguish "the lessons block's *content* shifts
agent behavior" from "adding 2,000 characters of ceremony to the system
prompt shifts agent behavior." Ruling on that alternative is the
preregistered H1 of RESEARCH-018.

## Design decisions

### 1. Frequency-matched English words, no directive vocabulary

The word bank is ~250 high-frequency English words (drawn from the top 300
most common), filtered to remove:
- Second-person pronouns ("you", "your") — could trigger direct-address
  behavior shifts.
- Imperative verbs ("do", "make", "use") — could read as instructions.
- Rubric-adjacent tokens ("rule", "require", "correct") — could match
  task-scoring keywords.

At generation time, a banned-substring list additionally rejects any
output containing: `lesson, always, never, important, must, should,
correct, wrong, hallucinat*, tool, function, avoid, rule, require,
ensure, verify, validate, error, fail, succeed, pass, try, attempt,
prohibit, allow`.

The result is grammatically well-formed English that says nothing
actionable — which is exactly the point.

### 2. Markdown skeleton preserved

Real lessons blocks use an H2 heading + bulleted list. Cell C matches
that skeleton (`## Notes\n\n- bullet\n- bullet\n...`) so the only
difference between cells is **content**, not **structure**. If we used
a single prose paragraph for Cell C, we would confound content with
structure — a weaker control.

### 3. Length match ±2%

Chump's real lessons blocks vary from ~1,500 to ~2,500 chars depending
on which priority targets hit the 5-lesson limit. Cell C matches the
actual Cell A length per trial. The ±2% tolerance is tight enough to
rule out "the extra 50 characters made the difference" and loose enough
that the generator's sentence-boundary snapping doesn't bounce.

### 4. Deterministic

Given `(target_chars, seed)`, the generator produces byte-identical
output. Downstream reproducibility: every Cell C trial in a sweep is
regeneratable from its `target_chars` and a trial-level seed.

## Self-test

```bash
python3.12 scripts/ab-harness/gen-null-prose.py --self-test
```

Validates:
- Length accuracy at targets 500, 1000, 2000, 4000 — all within ±2%
- Deterministic (same args → same output)
- Different seeds produce different output
- 20-seed battery contains no banned substrings
- Markdown skeleton (H2 + bullets) preserved

All 8 checks pass on origin/main.

## Sample output (target=500, seed=42)

```
## Notes

- Amount soft flower enter early cabinet smile. Second soft wake other between picture letter. An beyond during either night place.
- Sit river sign other less each machine person food. Stand think chair side letter hill. Chain during wide star hear book beyond kind black huge.
- Think area slow meadow or bright write what item before. From to quiet purple village tree in past dance simple be area rope earth.
- Drawer road neither large village way rest meadow calm few cabinet.
```

Length: 493 chars (target 500, Δ=−7, within ±2%).

## Integration path into `run-cloud-v2.py`

The Cell C integration is **not yet shipped**. Recommended steps for
whoever picks up the harness side of RESEARCH-018:

1. Add a `--cell-c-null-prose` CLI flag to `scripts/ab-harness/run-cloud-v2.py`.
   When set, rotate trials through three cells (A, B, C) instead of two.
2. For each Cell C trial, compute the Cell A lessons block's character
   count first, then invoke `gen_null_prose.generate(target_chars, seed=trial_seed)`.
   Inject the resulting string into the system prompt at the same
   position the lessons block occupies in Cell A.
3. Emit `cell` field values `"A"`, `"B"`, `"C"` in the JSONL so
   downstream analysis (`mediation-analysis.py`, aggregation scripts)
   sees three exposure levels.
4. Update `docs/eval/preregistered/RESEARCH-018.md` §3 with the exact
   harness invocation; do **not** edit the locked fields above the
   Deviations log.

Estimated effort for the harness wiring: ~2 hours + a 3-trial smoke
test before the n=100 sweep.

## Usage from the CLI

```bash
# Stand-alone
python3.12 scripts/ab-harness/gen-null-prose.py --target-chars 2000 --seed 42

# Match the character length of an existing lessons block
python3.12 scripts/ab-harness/gen-null-prose.py \
    --match-file /tmp/lessons_block_capture.txt \
    --seed 42 --out /tmp/placebo.md
```

## Integration with other infrastructure

- **`mediation-analysis.py`** (RESEARCH-023): Cell C trials feed the same
  mediation decomposition. With three exposure levels, report (A−B) and
  (C−B) deltas separately; the preregistered H1 holds if
  `|Δ(A−B)| > |Δ(C−B)| + 0.05`.
- **`analyze-module-references.py`** (RESEARCH-022): Cell C outputs are a
  natural negative control for reference-rate analysis. If the agent's
  reference rate on Cell C content is ≥ Cell A's, "reference rate"
  reflects verbosity rather than module-conditioning — important
  methodology check to run once Cell C data lands.

## What remains

RESEARCH-018 acceptance items, for future agent visibility:

- [x] Null-prose generator (this ship)
- [ ] `run-cloud-v2.py` --null-prose-match flag
- [ ] n=100 sweep on haiku-4-5 reflection (Cell A + B + C)
- [ ] n=100 sweep on sonnet-4-5 reflection (Cell A + B + C)
- [ ] Result doc in `docs/eval/RESEARCH-018-length-matched.md` with Wilson 95% CIs + decision-rule verdict
- [ ] `docs/FINDINGS.md` updated with ceremony-vs-content verdict per preregistration §9

Each remaining item is a separate small shipment. Cell C content is now
a solved problem.
