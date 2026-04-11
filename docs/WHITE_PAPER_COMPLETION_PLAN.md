# White paper completion plan (fullest practical scope)

**Goal:** Take the Markdown → PDF pipeline from “good bundled handoff” to the **fullest useful edition** we can produce from this repository—without pretending the PDF replaces the live `docs/` tree.

**Current baseline:** `docs/white-paper-manifest.json` + `docs/white-paper-profiles.json` + `scripts/build-white-papers.py` (LaTeX via Docker, `--chrome-pdf`, or `--html-only`), edition notice with **git SHA / date / changelog excerpt**, roadmap excerpt (manifest `roadmap_excerpt_lines`), reference-style link expansion, Volume I–III chapter lists, scope register, API + Battle QA summaries, checksums + `dist/white-papers/README.txt`, optional `--merge`, CI workflow **white-papers.yml**.

**How to use this doc:** Work top to bottom within each phase, or parallelize phases B + C while someone owns phase A. Check items in git when done.

---

## Phase A — Content completeness (what’s *in* the PDF)

### A1. Volume strategy (pick one primary shape)

- [x] **Decision:** **Three volumes** — I (showcase), II (technical), III (fleet / Mabel / defense / federal) so I/II stay readable.
- [x] `volume-3-fleet-defense` in the manifest with a tight chapter list (see A3).

### A2. Must-add chapters (high value, still manageable)

| Candidate | Volume | Rationale |
|-----------|--------|-----------|
| `BATTLE_QA.md` (+ pointer to failure triage doc) | II or III | Evidence story for agent QA; long—consider **extract** (A4). |
| `INTENT_CALIBRATION.md` | I or II | Shows structured NLP / intent evaluation. |
| `WEDGE_PILOT_METRICS.md` | I | Pilot SQL/API recipes; aligns with market story. |
| `TRUST_SPECULATIVE_ROLLBACK.md` | Already II | ✓ |
| `FLEET_ROLES.md` | III or II appendix | Fleet positioning without every Mabel doc. |
| `MABEL_DOSSIER.md` | III | Single-entry companion narrative. |
| `DEFENSE_MARKET_RESEARCH.md` | III | Only if defense is an active audience (large; consider extract). |
| `CHUMP_TO_COMPLEX.md` §1–2 only | III or II appendix | Research positioning; **not** full frontier §3 unless you want a book. |
| `CONTRIBUTING.md` | II (short) | Reviewers often expect contribution/repro guidance. |
| `LICENSE` | I or II (first pages) | Plain text or Pandoc `--include-in-header` note; legal clarity. |

### A3. “Omit on purpose” register (1–2 pages)

- [x] Add `docs/WHITE_PAPER_SCOPE_REGISTER.md`: table of **major** doc areas **not** bundled (or summarized) with **one-line** why.

### A4. Tame oversized sources (fullest *useful*, not fullest *page count*)

- [x] **`WEB_API_REFERENCE.md`:** **`WHITE_PAPER_API_SUMMARY.md`** (route table from `web_server.rs`) in Volume II; full reference stays in repo (scope register).
- [x] **`ROADMAP.md`:** Build-time excerpt (`roadmap_excerpt_lines` in manifest → `docs/_generated_roadmap_excerpt.md` in preprocess dir).
- [x] **`BATTLE_QA.md`:** **`WHITE_PAPER_BATTLE_QA_SUMMARY.md`** in Volume II + pointer to full doc.

### A5. Front matter per volume

- [x] **Version line:** git SHA + date in Pandoc YAML metadata + `_00_edition_notice.md`.
- [ ] **Audience / classification** (optional): “Public / partner / academic / controlled” footer.
- [x] **Change log excerpt:** top `changelog_excerpt_lines` of `CHANGELOG.md` in edition notice.

---

## Phase B — Toolchain & typography (how good it *looks* and *behaves*)

### B1. Link and reference hygiene

- [x] Preprocessor expands **reference-style** links `[text][id]` to inline when `[id]: url` definitions exist, then applies the same bundle rules as inline links.
- [x] **Bare** `docs/foo.md` in backticks: unchanged (code span; no false promises).

### B2. Mermaid and diagrams

- [ ] **Option A:** Pre-pass: `mmdc` / `@mermaid-js/mermaid-cli` to SVG, store under `docs/img/generated/`, reference from a **white-paper-only** include file.
- [ ] **Option B:** Pandoc **Lua filter** + `mermaid-filter` (heavier CI).
- [ ] Target: ECOSYSTEM_VISION + ARCHITECTURE diagrams at minimum.

### B3. LaTeX-quality PDF path (primary artifact)

- [x] Default **recommended** path: Docker `pandoc/ubuntu-latex` in CI + locally for **print-quality** PDFs.
- [ ] Add **custom LaTeX template** (fonts, paragraph spacing, running header with volume title).
- [x] **Chrome path** documented as **fast preview** in `WHITE_PAPER_READER_GUIDE.md` (layout differs from LaTeX).

### B4. HTML preview parity

- [x] `scripts/build-white-papers.py --html-only` writes standalone HTML per volume.

---

## Phase C — Automation & provenance

### C1. CI artifact

- [x] GitHub Actions **`.github/workflows/white-papers.yml`**: on `main`/`master` (docs/script paths) + `workflow_dispatch`, build PDFs (Docker), upload `dist/white-papers/` as an artifact. *(Releases attachment still optional.)*

### C2. Reproducible builds

- [ ] Pin Docker image digest in `CHUMP_WHITE_PAPER_IMAGE` (workflow or local env).
- [x] Document image default + pinning hook in `WHITE_PAPER_READER_GUIDE.md`.

### C3. Checksums

- [x] After build, emit `*.pdf.sha256` / `*.html.sha256` next to outputs.

---

## Phase D — Audience packs (optional “flavors”)

Manifest **profiles** (separate JSON or `--profile academic`):

| Profile | Emphasis |
|---------|----------|
| `default` | Three volumes as in manifest (intent, wedge, summaries, III fleet/defense). |
| `academic` | + `WHITE_PAPER_CHUMP_TO_COMPLEX_EXCERPT` appended to Volume I (duplicate OK for I-only readers). |
| `defense` | + `DEFENSE_MARKET_RESEARCH.md` appended to Volume III. |
| `operator` | + `SETUP_QUICK`, `SENTINEL_PLAYBOOK`, `GPU_TUNING` appended to Volume II. |

- [x] `--profile` in `scripts/build-white-papers.py` + `docs/white-paper-profiles.json`.

---

## Phase E — Distribution kit (what you attach in email)

- [x] `dist/white-papers/README.txt` (generated) + SHA/date/profile lines.
- [x] Optional merged PDF: `--merge` + `pdfunite` → `chump-white-paper-merged.pdf`.

---

## Phase F — Success criteria (definition of “fullest”)

You are **done** with “fullest practical” when:

1. **Coverage:** A reader can understand **what it is**, **how to try it**, **how you test it**, **how you operate it**, and **what you are not claiming**—without opening the repo.
2. **Honesty:** Scope register + link rewriting make omissions **explicit**.
3. **Evidence:** At least one **evaluation** chapter path (Battle QA / intent / pilot metrics) is represented in prose or summary form.
4. **Repro:** Version (SHA/date) on the cover or edition notice; optional CI artifacts.
5. **Visuals:** Key architecture / ecosystem figures render in PDF (not raw mermaid code fences).
6. **Print:** LaTeX/Docker path produces a PDF you would hand to a serious reviewer.

---

## Suggested execution order (single owner, ~2–4 weeks calendar)

1. **Week 1:** A2 (pick adds) + A5 (version injection) + C1 (CI artifact).  
2. **Week 2:** A4 (API + roadmap summaries) + B1 (reference links).  
3. **Week 3:** B2 (mermaid → SVG) + B3 (template).  
4. **Week 4:** A3 scope register + D (one profile) + E distribution README.

Parallel track: **Phase D** profiles ship alongside the default three-volume manifest; use `--profile` when an audience needs extra appendices.

---

## References

- Manifest: [white-paper-manifest.json](white-paper-manifest.json)  
- Profiles: [white-paper-profiles.json](white-paper-profiles.json)  
- Build script: [../scripts/build-white-papers.py](../scripts/build-white-papers.py)  
- Doc index: [00-INDEX.md](00-INDEX.md)  
- Showcase entry: [SHOWCASE_AND_ACADEMIC_PACKET.md](SHOWCASE_AND_ACADEMIC_PACKET.md)
