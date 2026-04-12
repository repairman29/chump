# Contributing to Chump

Thank you for improving Chump. This file is the **single checklist** for humans and for **Cursor** agents working in-repo.

---

## Read first

| Audience | Start here |
|----------|------------|
| Everyone shipping product work | [docs/ROADMAP.md](docs/ROADMAP.md), [docs/CHUMP_PROJECT_BRIEF.md](docs/CHUMP_PROJECT_BRIEF.md) |
| Cursor / IDE agents | [AGENTS.md](AGENTS.md), [docs/CHUMP_CURSOR_PROTOCOL.md](docs/CHUMP_CURSOR_PROTOCOL.md), [.cursor/rules/chump-cursor-agent.mdc](.cursor/rules/chump-cursor-agent.mdc); roadmap hub edits → [.cursor/rules/roadmap-doc-hygiene.mdc](.cursor/rules/roadmap-doc-hygiene.mdc) + [docs/CURSOR_CLI_INTEGRATION.md](docs/CURSOR_CLI_INTEGRATION.md) §3.4 |
| Ops and heartbeats | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| First-time run | [docs/EXTERNAL_GOLDEN_PATH.md](docs/EXTERNAL_GOLDEN_PATH.md) |

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
