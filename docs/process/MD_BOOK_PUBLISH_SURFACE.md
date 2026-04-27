---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# mdBook / GitHub Pages publish surface (source of truth)

This repo publishes a **subset** of the documentation via **mdBook** to GitHub Pages at `https://repairman29.github.io/chump/`.

This file is the canonical map of:
- **What is published** (the mdBook nav)
- **Where to edit** (synced from `docs/` vs authored in `book/src/`)
- **How it is built** (workflow + output directory)

## How publishing works

- **Workflow:** `.github/workflows/gh-pages.yml`
  - Runs on every push to `main` (and `workflow_dispatch`)
  - Installs mdBook
  - Runs `scripts/dev/sync-book-from-docs.sh`
  - Runs `mdbook build book`
  - Deploys `docs-site/` to GitHub Pages
- **mdBook config:** `book/book.toml`
  - `src = "src"`
  - `build-dir = "../docs-site"`
  - `site-url = "/chump/"`
- **Nav / chapter list:** `book/src/SUMMARY.md`

## Chapters in the published book (nav)

From `book/src/SUMMARY.md`:

### The Project
- `book/src/introduction.md` — **book-authored**
- `book/src/dissertation.md` — **book-authored** (not overwritten by sync script)
- `book/src/project-brief.md` — **synced** from `docs/briefs/CHUMP_PROJECT_BRIEF.md`

### Getting Started
- `book/src/getting-started.md` — **synced** from `docs/process/EXTERNAL_GOLDEN_PATH.md`
- `book/src/operations.md` — **synced** from `docs/operations/OPERATIONS.md`

### Architecture
- `book/src/architecture.md` — **book-authored** (not overwritten by sync script)
- `book/src/rust-infrastructure.md` — **synced** from `docs/architecture/RUST_INFRASTRUCTURE.md`
- `book/src/metrics.md` — **synced** from `docs/operations/METRICS.md`

### The Consciousness Framework
- `book/src/chump-to-champ.md` — **synced** from `docs/strategy/CHUMP_TO_CHAMP.md`
- `book/src/research-paper.md` — **synced** from `docs/research/consciousness-framework-paper.md`
- `book/src/findings.md` — **book-authored** (not overwritten by sync script)
- `book/src/research-community.md` — **synced** from `docs/research/RESEARCH_COMMUNITY.md`

### Chump to Champ: The Journal
- `book/src/chronicles/index.md` — **book-authored**
- `book/src/chronicles/2026-04-20-instrument-null.md` — **book-authored**
- `book/src/chronicles/2026-04-19-the-fix.md` — **book-authored**
- `book/src/chronicles/2026-04-18-who-i-am.md` — **book-authored**

### Contributing
- `book/src/research-integrity.md` — **synced** from `docs/process/RESEARCH_INTEGRITY.md`
- `book/src/roadmap.md` — **synced** from `docs/strategy/ROADMAP.md`

## Sync mapping (docs → book)

`scripts/dev/sync-book-from-docs.sh` copies the following sources into `book/src/`:

| Canonical source | Published destination |
|---|---|
| `docs/briefs/CHUMP_PROJECT_BRIEF.md` | `book/src/project-brief.md` |
| `docs/process/EXTERNAL_GOLDEN_PATH.md` | `book/src/getting-started.md` |
| `docs/operations/OPERATIONS.md` | `book/src/operations.md` |
| `docs/architecture/RUST_INFRASTRUCTURE.md` | `book/src/rust-infrastructure.md` |
| `docs/operations/METRICS.md` | `book/src/metrics.md` |
| `docs/strategy/CHUMP_TO_CHAMP.md` | `book/src/chump-to-champ.md` |
| `docs/strategy/ROADMAP.md` | `book/src/roadmap.md` |
| `docs/research/consciousness-framework-paper.md` | `book/src/research-paper.md` |
| `docs/research/RESEARCH_COMMUNITY.md` | `book/src/research-community.md` |
| `docs/process/RESEARCH_INTEGRITY.md` | `book/src/research-integrity.md` |

**Rule of thumb:** if a page is in the table above, fix content/links **in `docs/…`**, not in `book/src/…`, or the next publish will overwrite your edits.

**Roadmap bulk edits:** after changing many relative targets in `docs/strategy/ROADMAP.md`, run `python3 scripts/ci/roadmap-mdbook-links.py` (rewrites links for mdBook/GitHub Pages), then `./scripts/dev/sync-book-from-docs.sh` and `mdbook build book`.

## Local preview

```bash
./scripts/dev/sync-book-from-docs.sh
mdbook serve book
```

## Common doc-site failure modes (what to fix)

- **Book-escaping links:** `../docs/...` and `../scripts/...` will 404 on the site.
  - For targets outside the book, use repo links: `https://github.com/repairman29/chump/blob/main/...`
- **Uppercase doc-name links copied from `docs/`:** `FOO.md` links inside published pages often refer to files not in `book/src/`.
  - Replace with book-local chapter links when the target is published, or repo links when not.

CI `scripts/ci/mdbook-linkcheck.py` treats **every nav chapter** from `book/src/SUMMARY.md` as high-signal for escape detection (see `docs/audits/MDBOOK_REMEDIATION_REPORT.md`).

