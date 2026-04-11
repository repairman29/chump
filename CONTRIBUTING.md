# Contributing to Chump

## Bug reports (minimal repro)

Use the GitHub **Bug report** issue template when possible. Include **OS**, **Rust** (`rustc --version`), **inference** (Ollama version or `OPENAI_API_BASE`), and whether you followed **[docs/EXTERNAL_GOLDEN_PATH.md](docs/EXTERNAL_GOLDEN_PATH.md)**. Add **`git rev-parse --short HEAD`** (or release tag) so we know which tree you ran. For web issues, note **port** and `curl` output for `GET /api/health` (and `GET /api/pilot-summary` if relevant) if possible. **`./scripts/verify-external-golden-path.sh`** output helps (build + file checks). If you are running a **market pilot**, note whether `GET /api/pilot-summary` matches your expectations ([docs/WEDGE_PILOT_METRICS.md](docs/WEDGE_PILOT_METRICS.md)).

## PR checklist

- Run **`cargo test`** and **`cargo clippy --workspace --all-targets`** locally before pushing.
- Memory graph curated PPR recall@k is covered by **`cargo test memory_graph_curated_recall_topk`** (serial DB isolation); **`scripts/memory-graph-benchmark.sh`** is optional timing.
- CI runs the same on **push/PR to `main`** (see `.github/workflows/ci.yml`).
- For behavior changes, add or extend tests; for ops changes, update **`docs/OPERATIONS.md`** or the relevant doc under **`docs/`**.

## Roadmap

- **`docs/ROADMAP.md`** — checkboxes to mark when work merges.
- **`docs/ROADMAP_PRAGMATIC.md`** — phased order (reliability → autonomy → fleet → …).

## Agent handoffs

See **`AGENTS.md`** and **`docs/CHUMP_CURSOR_PROTOCOL.md`** for Chump–Cursor prompts and conventions.
