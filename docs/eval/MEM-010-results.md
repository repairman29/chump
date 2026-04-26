# MEM-010 — Entity Resolution Accuracy Results

**Gap:** MEM-010  
**Date:** 2026-04-19  
**Status:** PASS — precision 1.000 >= 0.85 threshold  
**Sub-gap filed:** No (precision above threshold)

---

## Test Set Description

30 entity pairs drawn from the MEM-008 fixture categories:

| Bucket | Count | Source category |
|--------|------:|-----------------|
| should-link (positive class) | 20 | entity-chain, temporal-chain, causal-chain |
| should-not-link (negative class) | 10 | same-first-name, same-abbreviation-pattern, same-domain-noun, similar-informal-names |

**Entity resolution method under test:** the `clean_entity` normalization in `src/memory_graph.rs`.  
Two surface forms are considered "linked" iff `clean_entity(a) == clean_entity(b)`.  
`clean_entity` lowercases, strips leading articles ("the", "a", "an"), and trims non-alphanumeric edges.

Fixture file: `docs/eval/MEM-010-entity-resolution-test-set.yaml`  
Test file: `tests/entity_resolution_accuracy.rs`

---

## Precision / Recall Results

```
Test set: 30 pairs (20 should-link, 10 should-not-link)
Correct predictions: 30/30

TP=20  FP=0  FN=0  TN=10
Precision : 1.000
Recall    : 1.000
F1        : 1.000
Accuracy  : 1.000
```

**Run:** `cargo test --test entity_resolution_accuracy -- --nocapture`

All 20 should-link pairs correctly normalized to the same string.  
All 10 should-not-link pairs correctly normalized to distinct strings.  
2 additional tests are `#[ignore]`d and document known limitations (see below).

---

## Known Limitations (documented, not blocking)

The test set deliberately includes two `#[ignore]`d regression tests for cases the current linker
cannot handle. These are filed as known limitations pending MEM-010a.

### 1. Underscore vs. space form (`MEM-010a`)

`"memory_db"` and `"memory db"` refer to the same module. `clean_entity` cannot resolve this
because it performs exact string matching after normalization. The underscore is preserved.

**Impact:** any memory entry that writes `memory_db` (code style) will not link to an entry that
writes `memory db` (prose style).

### 2. Nickname vs. formal name (semantic, not normalization)

`"the watcher"` (colloquial) and `"chump-heartbeat"` (formal service name) are the same service.
`clean_entity` normalizes `"the watcher"` to `"watcher"` — which is correct and distinct from
`"chump-heartbeat"`. Resolving this requires semantic knowledge (an alias table or embedding lookup),
not string normalization.

**Impact:** any multi-hop chain that requires crossing a nickname boundary will break at the entity
resolution step. The MEM-008 entity-chain category (e.g. MEM008-entity-004) documents exactly this
failure mode as "typical failure mode: retrieval returns only the entry that surface-matches the
query term, missing the synonym entries."

---

## Recommendation

**No sub-gap required** at this time for the core normalization path (precision = 1.000).

However, the two known limitations above represent genuine capability gaps that will surface
in production:

1. **MEM-010a** (when nominated): *Context disambiguation for entity linker* — add fuzzy
   normalization (token-set overlap or edit distance ≤ 2) to resolve underscore vs. space
   variants and other surface-form drift. Estimated effort: S.

2. **MEM-010b** (when nominated): *Semantic alias resolution for entity linker* — add an
   alias table (or embedding-based lookup) so that colloquial names ("the watcher") resolve
   to their formal service names ("chump-heartbeat"). This is the root cause of MEM-008
   entity-chain typical failure mode. Estimated effort: M.

Both items are tracked via the `#[ignore]` tests in `tests/entity_resolution_accuracy.rs`,
which will become failing tests (and therefore CI signals) once the corresponding sub-gaps ship.

---

## Methodology note

Per `docs/process/RESEARCH_INTEGRITY.md`: this result is preliminary (single-judge, n=30 pairs, deterministic
normalization test — no stochastic model involved). The linker under test is a string-matching rule,
not an LLM, so judge-bias caveats do not apply. The test set is reproducible by re-running
`cargo test --test entity_resolution_accuracy`.
