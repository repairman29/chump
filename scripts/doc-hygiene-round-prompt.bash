#!/usr/bin/env bash
# Shared prompt for doc_hygiene heartbeat rounds. Sourced by heartbeat-self-improve.sh
# and heartbeat-doc-hygiene-loop.sh — do not execute directly.

doc_hygiene_prompt() {
  cat <<'EOF'
Self-improve round: **doc and roadmap hygiene** (editor tier). You are Chump.

**Goal:** Keep documentation accurate and navigable — not product code changes this round unless a doc fix absolutely requires a one-line comment in src (avoid; prefer docs only).

**Do first:**
1. ego read_all (brief). task list — if there is an open task titled or tagged for doc/roadmap hygiene, prefer that scope.
2. run_cli "./scripts/doc-keeper.sh" — if it exits non-zero, fix **broken relative Markdown links** and re-run until it passes (or you hit 3 doc-keeper attempts; then episode log and notify with remaining failures).
3. read_file docs/README.md **or** docs/00-INDEX.md (whichever exists) to see how docs are organized.

**In scope (edit only these unless a task explicitly says otherwise):**
- `docs/**/*.md`
- Repo root `AGENTS.md` if present
- `.cursor/rules/*.mdc` if present

**Out of scope:** Rust/source refactors, behavior changes, new features — defer to a normal `work` or `cursor_improve` round.

**Edits to make (pick what matters this round; one coherent batch, roughly ≤8 files):**
- Replace legacy tool name **edit_file** with **patch_file** (or **write_file** where appropriate) in prose, tables, and examples.
- Fix broken relative links (same rules as doc-keeper: paths may be doc-relative or repo-root `scripts/…`, `src/…`).
- Reconcile **stale cross-references** between hub files (e.g. docs/ROADMAP.md, docs/ROADMAP_CLAUDE_UPGRADE.md, docs/PRAGMATIC_EXECUTION_CHECKLIST.md, docs/CHUMP_PROJECT_BRIEF.md) **only** for factual errors (wrong filenames, removed tools). Do **not** change roadmap **scope** or priorities.
- **Roadmap checkboxes (`- [ ]` / `- [x]`):** Only flip to `[x]` if you **verified** in this same round (e.g. read the cited source file or ran a targeted check). If unsure, leave the box and fix wording only.

**Tools:** read_file, list_dir, **patch_file** (unified diff) for targeted edits, **write_file** for new small files. Do **not** use edit_file — it does not exist.

**Verify:** After edits, run_cli "./scripts/doc-keeper.sh" again (DOC_KEEPER_STALE_SCAN=0 is default).

**WRAP UP:** episode log (files touched, doc-keeper result). Update ego (current_focus). notify Jeff only if blocked, doc-keeper still red after retries, or you need a product decision. Be concise.

RULES: Docs-only round; no git push unless your environment already allows it and you have a normal commit flow; DRY_RUN → no push; one focused hygiene batch per round.
EOF
}
