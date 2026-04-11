# Reader guide (appendix to Volume I)

This appendix is **only for the PDF white-paper build**. It does not replace `docs/README.md` in the repository.

## What Volume I is for

| Audience | Suggested path |
|----------|----------------|
| **Executive / partner** | `SHOWCASE_AND_ACADEMIC_PACKET` (sections 1–2, 9.1), then `README`, then skim `MARKET_EVALUATION` |
| **Academic or technical reviewer** | Full packet §9.2, then `DOSSIER` and `ARCHITECTURE` in **Volume II** |
| **Operator / pilot** | `EXTERNAL_GOLDEN_PATH` in this volume, then Volume II `OPERATIONS` and the API summary (full reference stays in repo) |

## Glossary (short)

| Term | Meaning |
|------|---------|
| **Chump** | The Rust agent process: tool loop, SQLite state, optional Discord / web / CLI. |
| **PWA** | Browser UI served by `chump --web` (chat, tasks, dashboard APIs). |
| **Cowork** | Tauri desktop shell wrapping the same web UI; talks to the local HTTP sidecar. |
| **Brain** | Optional markdown wiki under `chump-brain/` (playbooks, portfolio). |
| **Heartbeat** | Scheduled autonomous rounds (ship, self-improve, roles, etc.). |
| **Battle QA** | Large scripted query suite to stress the agent; used for regression. |
| **Cascade** | Optional multi-slot OpenAI-compatible routing (local + cloud fallbacks). |
| **Mabel** | Optional Android (Pixel/Termux) companion agent in the fleet narrative—not required for the minimal golden path. |

## What these PDFs omit

Volumes I–III **cannot** include the whole `docs/` tree. See **`WHITE_PAPER_SCOPE_REGISTER.md`** for a concise “not bundled (or only summarized)” list. Typical material left in the repo only includes: deep roadmaps (`ROADMAP_PRAGMATIC`, `ROADMAP_FULL`), extra Mabel subdocs, the full `WEB_API_REFERENCE`, consciousness metrics scripts, and historical ADRs. The **SHOWCASE** packet §12 maps topics to canonical filenames if you clone the repository later.

## Regenerating or extending the PDFs

From the repository root, with Pandoc (and LaTeX or Docker) or Chrome headless:

- `./scripts/build-white-papers.sh --docker` — recommended for print-quality PDF (matches CI).
- `./scripts/build-white-papers.sh --chrome-pdf` — fast local preview on macOS without TeX.
- `./scripts/build-white-papers.sh --html-only` — standalone HTML per volume (email / quick review).
- `./scripts/build-white-papers.sh --profile academic|defense|operator` — optional appendices from `docs/white-paper-profiles.json`.
- `./scripts/build-white-papers.sh --merge` — after PDFs, `pdfunite` into `chump-white-paper-merged.pdf` if `pdfunite` is on `PATH`.

Chapter lists live in `docs/white-paper-manifest.json`. The build injects **git SHA**, **date**, and a **changelog excerpt** into the edition notice; it rewrites links to Markdown files **not** in that volume so a shared PDF does not promise documents you did not bundle. `dist/white-papers/README.txt` and `*.sha256` files are generated on successful builds.

**Toolchain (CI):** `CHUMP_WHITE_PAPER_IMAGE` defaults to `pandoc/ubuntu-latex:3.6` (see `.github/workflows/white-papers.yml`). Pin a digest in that env var when you need bit-for-bit reproducible LaTeX runs.
