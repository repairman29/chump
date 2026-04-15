# Contributing to Chump

Thank you for improving Chump! Whether you're fixing a typo, adding a feature, or reporting a bug, contributions are welcome.

---

## New contributors

**Start here:**

1. **[docs/EXTERNAL_GOLDEN_PATH.md](docs/EXTERNAL_GOLDEN_PATH.md)** — get Chump running locally (~30 min)
2. **[docs/CHUMP_DISSERTATION.md](docs/CHUMP_DISSERTATION.md)** — understand the architecture and design philosophy
3. **Browse the [documentation site](https://repairman29.github.io/chump/)** for searchable docs

**Good first contributions:**
- Add eval cases to `src/eval_harness.rs` (see `seed_starter_cases()` for the pattern)
- Add tests to untested files (look for large `.rs` files without `#[cfg(test)]` modules)
- Improve docs — fix broken links, clarify setup steps, add examples
- Try the golden path on your platform and report friction via a [bug report](https://github.com/repairman29/chump/issues/new?template=bug_report.md)

---

## Read first (all contributors)

| Audience | Start here |
|----------|------------|
| New contributors | [docs/CHUMP_DISSERTATION.md](docs/CHUMP_DISSERTATION.md), [docs/EXTERNAL_GOLDEN_PATH.md](docs/EXTERNAL_GOLDEN_PATH.md) |
| Picking work items | [docs/ROADMAP.md](docs/ROADMAP.md), [docs/CHUMP_PROJECT_BRIEF.md](docs/CHUMP_PROJECT_BRIEF.md) |
| Cursor / IDE agents | [AGENTS.md](AGENTS.md), [docs/CHUMP_CURSOR_PROTOCOL.md](docs/CHUMP_CURSOR_PROTOCOL.md) |
| Ops and heartbeats | [docs/OPERATIONS.md](docs/OPERATIONS.md) |

**Full doc catalog:** [docs/README.md](docs/README.md).

---

## Local quality bar (match CI)

Run from the repo root before opening a PR:

```bash
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Optional: `bash scripts/verify-external-golden-path.sh` (fast smoke; also runs in CI).

CI definition: [.github/workflows/ci.yml](.github/workflows/ci.yml) (includes `fmt`, Node checks for web, Playwright PWA, battle sim, golden path timing, clippy).

**Ship and merge:** [docs/SHIP_AND_MERGE.md](docs/SHIP_AND_MERGE.md) — PR discipline, squash vs merge, branch protection, merge queue, post-merge ops.

**Superseded experiments (Git):** [docs/archive/SUPERSEDED_BRANCHES.md](docs/archive/SUPERSEDED_BRANCHES.md) — branches not to merge; tag-before-delete procedure.

---

## Code and tools

- **Focused diffs:** match existing style; avoid drive-by refactors unrelated to the task.
- **Repo file edits in Chump:** use **`patch_file`** (unified diff) or **`write_file`** — there is no `edit_file` tool in this tree.
- **Tests:** behavior changes need tests (or a clear reason in the PR why not).
- **Docs:** ops or user-visible behavior → update the relevant file under `docs/` (often [OPERATIONS.md](docs/OPERATIONS.md)). Doc link hygiene: `./scripts/doc-keeper.sh`.

---

## Bug reports

Use the GitHub **Bug report** issue template when possible. Include **OS**, **Rust** (`rustc --version`), **inference** (Ollama version or `OPENAI_API_BASE`), and whether you followed the golden path. Add **`git rev-parse --short HEAD`**. For web issues, note **port** and `curl` for `GET /api/health`. **`./scripts/verify-external-golden-path.sh`** output helps.

---

## Roadmaps

- **[docs/ROADMAP.md](docs/ROADMAP.md)** — checkboxes when work merges.
- **[docs/ROADMAP_PRAGMATIC.md](docs/ROADMAP_PRAGMATIC.md)** — phased backlog order.

---

## Security

Do not commit secrets. See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.
