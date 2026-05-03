---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-03
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
| "Show me all gaps (open + done)" | [ROADMAP_FULL.md](ROADMAP_FULL.md) — complete multi-horizon view |
| "What is the north-star architecture?" | [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) — long-horizon capability bets |
| "What's the product vision / user stories?" | [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) — Chief of Staff vision |
| "How does Mabel evolve?" | [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — fleet-monitor → Sentinel path |
| "Competitive benchmarking / Hermes?" | [HERMES_COMPETITIVE_ROADMAP.md](HERMES_COMPETITIVE_ROADMAP.md) — redirects to current analysis |

---

## Canonical hierarchy

```
.chump/state.db (canonical) +      ← authoritative gap registry (ground truth)
docs/gaps/<ID>.yaml mirrors          since INFRA-188 (per-file replaces monolithic
    ↓ populates                      docs/gaps.yaml; INFRA-059 made SQLite canonical)
ROADMAP_FULL.md                    ← all gaps view
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

## Current state (2026-05-03)

- **Sprint:** see [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md)
- **Total gaps:** 685 (594 done, 86 open, 2 blocked, 3 deferred) as of 2026-05-03
- **Open by domain:** INFRA 48, FLEET 10, META 9, RESEARCH 5, EVAL 4, COG 2, others 8
- **Recent merge cadence:** ~200 gaps closed in the 2026-05-02 → 2026-05-03 fleet session
  (cascade activation via free-tier providers — Cerebras / Groq / Together / NVIDIA /
  Hyperbolic / OpenRouter / GitHub Models / Gemini — landed
  [INFRA-256](../gaps/INFRA-256.yaml) / [INFRA-259](../gaps/INFRA-259.yaml) /
  [INFRA-260](../gaps/INFRA-260.yaml); coordination tooling hardening landed
  [META-017](../gaps/META-017.yaml) / [META-022](../gaps/META-022.yaml);
  dispatcher / fleet-scaling architecture filed in [INFRA-314](../gaps/INFRA-314.yaml) /
  [FLEET-032..034](../gaps/FLEET-032.yaml)). Detail in
  [INFRA-317 session synthesis](../gaps/INFRA-317.yaml).

For up-to-date gap counts:

```sh
sqlite3 .chump/state.db "SELECT status, COUNT(*) FROM gaps GROUP BY status"
chump gap list --status open --json | jq length
```

---

## Related

- [.chump/state.db + docs/gaps/](../gaps/) — master gap registry (SQLite canonical, per-file YAML mirrors)
- [CHUMP_TO_CHAMP.md](CHUMP_TO_CHAMP.md) — cognitive architecture research direction (gate for 10+ gaps)
- [RED_LETTER.md](RED_LETTER.md) — weekly issue log; drives reactive gap filing
