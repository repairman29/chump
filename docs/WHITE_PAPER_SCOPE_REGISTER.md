# White paper scope register

This register lists **major documentation areas that are not fully bundled** in the PDF editions (or are included only as **summaries / excerpts**). It answers “where is X?” without implying every file ships in the handoff PDFs.

| Area | Typical location in repo | Why omitted or shortened |
|------|--------------------------|----------------------------|
| Full HTTP API surface | `docs/WEB_API_REFERENCE.md` | Very long reference; PDFs include **`WHITE_PAPER_API_SUMMARY.md`** (route index). |
| Full product roadmap | `docs/ROADMAP.md` | Grows without bound; Volume I uses an **abridged excerpt** generated at build time. |
| Alternate / deep roadmaps | `docs/ROADMAP_FULL.md`, `docs/ROADMAP_PRAGMATIC.md`, etc. | Narrative variants; canonical checklist remains `ROADMAP.md` in repo. |
| Full Battle QA playbook | `docs/BATTLE_QA.md`, `docs/BATTLE_QA_SELF_FIX.md` | Operational detail; PDFs include **`WHITE_PAPER_BATTLE_QA_SUMMARY.md`**. |
| Architecture Decision Records | `docs/adr/`, historical ADRs | Dense history; cite `DOSSIER.md` / `ARCHITECTURE.md` for current shape. |
| Every Mabel / fleet subdoc | `docs/MABEL_*.md`, playbooks | Volume III pulls **FLEET_ROLES**, **MABEL_DOSSIER**, and defense/federal anchors; subtopics stay in repo. |
| Defense market deep dive | `docs/DEFENSE_MARKET_RESEARCH.md` | Large; **defense** build profile can append it to Volume III. |
| Consciousness / frontier thesis (full) | `docs/CHUMP_TO_COMPLEX.md` | Book-scale; PDFs use **`WHITE_PAPER_CHUMP_TO_COMPLEX_EXCERPT.md`** (§0–2 style); **academic** profile can duplicate excerpt on Volume I. |
| UI week / dogfood checklists | `docs/UI_WEEK_*.md`, `.cursor/rules` | Living checklists for builders, not external reviewers. |
| Generated logs and reports | `logs/`, `dist/` | Runtime artifacts; not documentation sources. |

**Honesty rule:** Inline links to Markdown files outside a volume are rewritten at build time to plain text plus a short note, so the PDF does not promise documents you did not ship.
