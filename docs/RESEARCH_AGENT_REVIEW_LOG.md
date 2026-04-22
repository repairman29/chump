# Research / docs agent — review & double-back log

Append-only style: add a **new dated section** at the top when closing a session or hitting a blocker. Keep bullets short; link out to PRs, batch sheets, and prereg docs.

---

## 2026-04-22 — Lane A→B→C sweep (session)

### Bugs / CI (resolved on `main`; keep for archaeology)

- **`mcp_discovery` flaky tests:** parallel tests mutated `PATH` / `HOME` / `XDG_CONFIG_HOME`; fixed by serializing env-mutating tests (`src/mcp_discovery.rs`).
- **`skill_hub` test:** assertion depended on global `CHUMP_BRAIN_PATH`; fixed by asserting on the written `SKILL.md` content (`src/skill_hub.rs`).

### Double-back (open)

- **PR [#432](https://github.com/repairman29/chump/pull/432):** Lane A checklist closure + this review log + batch sheet argv/SHAs — merge when review policy allows.
- **PR [#431](https://github.com/repairman29/chump/pull/431)** (`docs-mdbook-remed-09`): mdBook / mirror link fixes for `chump-to-complex` + research paper. **CI green** (`plan`, `build-and-linkcheck`, `sync-idempotency`); **`mergeStateStatus` stayed `BLOCKED`** under branch protection until required reviews/approvals land. Squash **auto-merge** was enabled where policy allows — confirm merge after human review.
- **Lane B integrity — Together key:** preregistered **RESEARCH-018** requires cross-family **Judge 2** on Together (`Llama-3.3-70B-Instruct-Turbo`). **RESEARCH-021** non-Anthropic families need **`TOGETHER_API_KEY`** (and budget) before primary pilots/sweeps. Anthropic-only pilots are acceptable for **schema / wiring smoke** only; label **PRELIMINARY** and do not substitute for preregistered judge panels without a **Deviations** entry.
- **Prereg “locked SHA” fields:** several prereg headers still use placeholder `<SHA-filled-at-merge>`. When starting a paid batch, record the **git blob** (or merge commit) in the batch sheet — see filled examples under `docs/eval/batches/2026-04-22-RESEARCH-018.md`.
- **Local `git stash` inventory:** multiple WIP stashes on old feature branches (e.g. EVAL-076, gaps-*). Nothing is lost, but **none are on GitHub** until applied to a branch and committed. Reap or branch-archive before aggressive `stash clear`.
- **Git branch naming collision:** if a branch named exactly `docs` exists, `git checkout -b docs/something` fails (`refs/heads/docs` is a file, not a directory). Prefer `research-…` / `claude/…` style names, or rename the stray `docs` branch.

### Lane A checklist (this session)

- Added **NOT RUN** results stub: [`docs/eval/RESEARCH-018-length-matched.md`](./eval/RESEARCH-018-length-matched.md).
- Extended **RESEARCH-018** batch sheet with **preregistered Lane B** command templates (haiku + sonnet tiers, n=100/cell) and prereg blob SHAs.
- Re-ran **`bash scripts/research-lane-a-smoke.sh`** — pass.
