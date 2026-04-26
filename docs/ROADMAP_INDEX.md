---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Roadmap index

Navigation guide to all roadmap docs. Use this as your entry point; each linked doc is
self-contained. Source files kept in place (index-only merge — sources not deleted).

---

## Which doc to read

| Question | Doc |
|----------|-----|
| "What should I work on right now?" | [ROADMAP.md](ROADMAP.md) — operational backlog, checked/unchecked items |
| "What's shipping this sprint?" | [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) — two-week sprint slices (S1 current) |
| "What's the Q2 2026 cut?" | [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) — unblocked P1/P2 items only |
| "Show me all 186 gaps (open + done)" | [ROADMAP_FULL.md](ROADMAP_FULL.md) — complete multi-horizon view |
| "What is the north-star architecture?" | [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) — long-horizon capability bets |
| "What's the product vision / user stories?" | [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) — Chief of Staff vision |
| "How does Mabel evolve?" | [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — fleet-monitor → Sentinel path |
| "Competitive benchmarking / Hermes?" | [HERMES_COMPETITIVE_ROADMAP.md](HERMES_COMPETITIVE_ROADMAP.md) — redirects to current analysis |

---

## Canonical hierarchy

```
docs/gaps.yaml                     ← authoritative gap registry (ground truth)
    ↓ populates
ROADMAP_FULL.md                    ← all 186 gaps
    ↓ filtered to
ROADMAP_PRAGMATIC.md               ← Q2 2026 unblocked items
    ↓ sliced into
ROADMAP_SPRINTS.md                 ← two-week execution windows
    ↓ tracked in
ROADMAP.md                         ← checked/unchecked operational backlog
```

**North-star / product layers** (independent of the above):
- `ROADMAP_UNIVERSAL_POWER.md` — architectural capability bets (long horizon)
- `PRODUCT_ROADMAP_CHIEF_OF_STAFF.md` — product/user story layer
- `ROADMAP_MABEL_DRIVER.md` — mobile fleet evolution

---

## Current state (2026-04-20)

- **Sprint:** S1 (2026-04-14 → 2026-04-27) — see [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md)
- **Open gaps:** ~8 on `main` (from `docs/gaps.yaml` — source of truth)
- **Total:** 186 gaps (50 open, 136 done as of 2026-04-19)

For up-to-date gap counts: `grep "status: open" docs/gaps.yaml | wc -l`

---

## Related

- [docs/gaps.yaml](gaps.yaml) — master gap registry
- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — cognitive architecture research direction (gate for 10+ gaps)
- [RED_LETTER.md](RED_LETTER.md) — weekly issue log; drives reactive gap filing
