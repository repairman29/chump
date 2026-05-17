---
doc_tag: canonical
owner_gap:
last_audited: 2026-05-16
---

# Roadmap index

Navigation guide to all roadmap docs. **`docs/ROADMAP.md` is the canonical
top-level entry point** for "what is chump working on right now." This index
exists for navigation across the focused horizon docs.

---

## Which doc to read

### Start here
| Question | Doc |
|----------|-----|
| **"What is chump working on right now?"** | **[../ROADMAP.md](../ROADMAP.md) — canonical top-level entry, updated 2026-05-16** |

### Focused horizon docs (added 2026-05-16)
| Question | Doc |
|----------|-----|
| **"Is the work actually moving the product?"** | **[MISSION_YIELD.md](MISSION_YIELD.md) — single weekly number, the rule of X. Headline metric.** |
| **"What order do we ship in to avoid rework?"** | **[ROADMAP_WAVES.md](ROADMAP_WAVES.md) — 4 waves, prerequisite-explicit. Read second when picking next gap.** |
| **"How does the COS role operate?"** | **[../process/COS_OPERATING_MODEL.md](../process/COS_OPERATING_MODEL.md) — operating cadence + productization path** |
| "How do we get to 50 PRs/hour?" | [ROADMAP_50_PER_HOUR.md](ROADMAP_50_PER_HOUR.md) — 15-day infra-throughput push (subject to wave order) |
| "What experience are we building for Marcus?" | [ROADMAP_MARCUS.md](ROADMAP_MARCUS.md) — customer arc, 5 milestones (M-A → M-E) |
| "What's in the design-conversation backlog?" | [ROADMAP_BACKLOG.md](ROADMAP_BACKLOG.md) — 8 items decided 2026-05-16 |
| "What did we ship this week?" | [../syntheses/cos-weekly-*.md](../syntheses/) — Sunday digests, Mission Yield delta |

### Reference / horizon docs
| Question | Doc |
|----------|-----|
| "What's shipping this sprint?" | [ROADMAP_SPRINTS.md](ROADMAP_SPRINTS.md) — two-week sprint slices |
| "What's the Q2 2026 cut?" | [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) — unblocked P1/P2 items only |
| "Show me all gaps (open + done)" | [ROADMAP_FULL.md](ROADMAP_FULL.md) — complete multi-horizon view |
| "What is the north-star architecture?" | [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) — long-horizon capability bets |
| "What's the product vision / user stories?" | [PRODUCT_ROADMAP_CHIEF_OF_STAFF.md](PRODUCT_ROADMAP_CHIEF_OF_STAFF.md) — Chief of Staff vision |
| "How does Mabel evolve?" | [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — fleet-monitor → Sentinel path |
| "Competitive benchmarking / Hermes?" | [HERMES_COMPETITIVE_ROADMAP.md](HERMES_COMPETITIVE_ROADMAP.md) — redirects to current analysis |
| "What's the mission / north star?" | [NORTH_STAR.md](NORTH_STAR.md) — mission + 4 pillars |

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
