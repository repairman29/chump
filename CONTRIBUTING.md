# Contributing to Chump

## PR checklist

- Run **`cargo test`** and **`cargo clippy --workspace --all-targets`** locally before pushing.
- CI runs the same on **push/PR to `main`** (see `.github/workflows/ci.yml`).
- For behavior changes, add or extend tests; for ops changes, update **`docs/OPERATIONS.md`** or the relevant doc under **`docs/`**.

## Roadmap

- **`docs/ROADMAP.md`** — checkboxes to mark when work merges.
- **`docs/ROADMAP_PRAGMATIC.md`** — phased order (reliability → autonomy → fleet → …).

## Agent handoffs

See **`AGENTS.md`** and **`docs/CHUMP_CURSOR_PROTOCOL.md`** for Chump–Cursor prompts and conventions.
