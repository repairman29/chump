---
doc_tag: decision-record
owner_gap: INFRA-001b
last_audited: 2026-04-25
---

# ADR-001: Transactional tool speculation

**Status:** Accepted — INFRA-001b shipped 2026-04-18 (sandbox speculation via git worktree).  
**Public summary (diagram):** [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md)  
**Context:** [`speculative_execution`](../src/speculative_execution.rs) today snapshots and restores **in-process** state (beliefs, neuromodulation, blackboard). Tools **execute against the real environment**; rollback cannot undo filesystem writes, HTTP calls, Discord messages, or SQLite changes made through tools.

**E2 baseline (shipped):** The **`sandbox_run`** tool (`src/sandbox_tool.rs`) runs a **single** shell command in a **detached git worktree** and removes the worktree afterward (`CHUMP_SANDBOX_ENABLED=1`). That covers **repo-scoped** experimentation but is **not** wired into the speculative batch path yet; agents must call the tool explicitly.

**Decision (original):** Ship honest **memory-only** rollback and document limits (see [`METRICS.md`](METRICS.md) §1b, [`AGENTS.md`](../AGENTS.md)).

**Options for true transactional semantics:**

1. **Dry-run / mock executor** — A parallel code path that records intended effects without applying them; only “commit” applies. High cost: every tool must support simulation or be blocklisted.
2. **Sandbox workspace** — Git worktree or temp clone for repo tools; discard directory on rollback. Covers file tools only.
3. **Phase E sandbox tool** — See [`ROADMAP_PRAGMATIC.md`](ROADMAP_PRAGMATIC.md) Phase E (E2). A bounded subprocess or worktree for commands aligns with (2).

**Gate (original):** Implement only after Phase E sandbox (or equivalent) exists **and** product need is clear (e.g. repeated harmful multi-tool batches in production). Until then, prefer `CHUMP_SPECULATIVE_BATCH=0` if the batch path causes confusion.

**Consequences:** Full transactional speculation is a **platform** feature (tool policy + executor), not a tweak to `rollback()`.

---

## Addendum: INFRA-001b — Sandbox speculation shipped (2026-04-18)

Option 2 (sandbox workspace) was implemented in `src/speculative_execution.rs` and `src/cli_tool.rs`.

### Activation

Set `CHUMP_SANDBOX_SPECULATION=1` before starting the agent. The feature is **off by default** so existing deployments are unaffected.

### How it works

| Event | Sandbox OFF (default) | Sandbox ON |
|---|---|---|
| `fork()` | snapshots in-process state | snapshots state + `git worktree add --detach .chump-spec-<millis>` |
| `commit()` | applies in-process state | copies changed files from worktree to real tree via `git diff --name-only` + `ls-files --others`, removes worktree |
| `rollback()` | restores in-process state | restores state + removes worktree (no files applied) |

**Worktree lifecycle:**
- Created in repo root as `.chump-spec-<unix_millis>/` (detached HEAD, matches current commit)
- Stored in `SPECULATIVE_SANDBOX_PATH: Mutex<Option<PathBuf>>` (one active sandbox per process)
- Removed via `git worktree remove --force`; fallback `rm -rf` if that fails

### Tool routing

`cli_tool` (`src/cli_tool.rs`) is the first tool wired in. When `sandbox_speculation_enabled()` and a sandbox is active, the tool's working directory is redirected to the sandbox root instead of the real repo root. This means shell commands run inside the worktree and their filesystem effects are isolated.

Full per-tool policy: [`docs/POLICY-sandbox-tool-routing.md`](POLICY-sandbox-tool-routing.md).

### Limitations

- **Repo-scoped only.** Rollback cannot undo HTTP calls, Discord messages, SQLite writes via `episode_db`, or any effect outside the git worktree.
- **Single sandbox per process.** Nested speculative forks do not create nested worktrees; the existing sandbox is reused. Inner commits/rollbacks operate on the same worktree.
- **No network tool sandboxing.** Tools like `web_fetch`, `discord_send`, `fleet_tool` are not rerouted. See policy doc for the full safe/sandboxed/never classification.
- **commit_sandbox_to_real copies files, not git history.** The worktree's commits are discarded; only working-tree changes are applied to the real tree.
