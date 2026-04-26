---
doc_tag: log
owner_gap:
last_audited: 2026-04-25
---

# mdBook / GitHub Pages remediation — completion report

This document closes the **mdBook publish surface** workstream: keep the public book aligned with canonical `docs/`, avoid broken relative links on GitHub Pages, and guard the pipeline in CI.

## Goals

- **Predictable publish output:** `book/src/` mirrors for synced chapters stay in sync with `docs/`; book-only chapters stay authoritative in `book/src/`.
- **No book-escaping relative links** on published nav pages (links that resolve outside the generated `docs-site/` tree and 404 on Pages).
- **CI before merge:** mdBook build, lightweight link escape checks, and sync idempotency.

## What shipped (themes)

| Area | Outcome |
|------|---------|
| **Publish map** | `docs/process/MD_BOOK_PUBLISH_SURFACE.md` documents nav chapters, sync mapping, local preview, and common failure modes. |
| **Sync** | `scripts/sync-book-from-docs.sh` copies agreed `docs/` sources into `book/src/`; `architecture.md` / `dissertation.md` / `findings.md` / chronicles remain book-authored. |
| **Roadmap links** | `scripts/roadmap-mdbook-links.py` rewrites `docs/strategy/ROADMAP.md` targets to GitHub blob URLs or in-nav `./chapter.md` links so the synced roadmap chapter does not emit dead local `.html` neighbors on Pages. |
| **Doc hygiene** | Published and adjacent docs were updated for **mistral.rs** consolidation (`docs/architecture/MISTRALRS.md` replaces removed split/matrix filenames in cross-links). |
| **CI** | `.github/workflows/mdbook-verify.yml` runs sync, `mdbook build book`, and `python3 scripts/mdbook-linkcheck.py`; a job asserts `git diff --exit-code book/src` after sync. Relevant script and workflow paths are in the workflow `paths` filter. |
| **Link checker** | `scripts/mdbook-linkcheck.py` flags **book-escaping** `href`/`src` values on **all mdBook nav chapters** (derived from `book/src/SUMMARY.md`, using `docs-site/`-relative paths so names like `index.html` under `chronicles/` do not collide with the site root). It also flags **missing static assets** (css/js/images/fonts) anywhere under `docs-site/`. |

## Operator checklist (after editing synced docs)

1. Edit the **canonical** file under `docs/` (see the sync table in `docs/process/MD_BOOK_PUBLISH_SURFACE.md`).
2. For large `docs/strategy/ROADMAP.md` link edits: `python3 scripts/roadmap-mdbook-links.py`.
3. `./scripts/sync-book-from-docs.sh`
4. `mdbook build book` (output `docs-site/` per `book/book.toml`).
5. `python3 scripts/mdbook-linkcheck.py`
6. Commit **both** `docs/…` and updated `book/src/…` copies when the sync script touches them.

## Optional follow-ups (not required for baseline hygiene)

- **Stricter HTML existence checks** for every generated page (including print / search helpers): today missing in-tree `*.html` targets are only indirectly discouraged via escape checks on nav chapters.
- **Orphan GitHub URLs** in `ROADMAP.md`: some blob targets may still 404 on github.com until missing legacy doc names are renamed, restored, or link text is pointed at a real file.
- **Periodic re-run** of `roadmap-mdbook-links.py` whenever contributors reintroduce large batches of bare `FOO.md` links in the roadmap.

## References

- `docs/process/MD_BOOK_PUBLISH_SURFACE.md` — publish surface and sync ownership.
- `book/src/SUMMARY.md` — mdBook nav (also drives linkcheck nav coverage).
- `.github/workflows/gh-pages.yml` — Pages deploy (sync + build on `main`).
