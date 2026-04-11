# ADR-001: Transactional tool speculation (future work)

**Status:** Proposed — not implemented.  
**Public summary (diagram):** [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md)  
**Context:** [`speculative_execution`](../src/speculative_execution.rs) today snapshots and restores **in-process** state (beliefs, neuromodulation, blackboard). Tools **execute against the real environment**; rollback cannot undo filesystem writes, HTTP calls, Discord messages, or SQLite changes made through tools.

**E2 baseline (shipped):** The **`sandbox_run`** tool (`src/sandbox_tool.rs`) runs a **single** shell command in a **detached git worktree** and removes the worktree afterward (`CHUMP_SANDBOX_ENABLED=1`). That covers **repo-scoped** experimentation but is **not** wired into the speculative batch path yet; agents must call the tool explicitly.

**Decision (current):** Ship honest **memory-only** rollback and document limits (see [`METRICS.md`](METRICS.md) §1b, [`AGENTS.md`](../AGENTS.md)).

**Options for true transactional semantics:**

1. **Dry-run / mock executor** — A parallel code path that records intended effects without applying them; only “commit” applies. High cost: every tool must support simulation or be blocklisted.
2. **Sandbox workspace** — Git worktree or temp clone for repo tools; discard directory on rollback. Covers file tools only.
3. **Phase E sandbox tool** — See [`ROADMAP_PRAGMATIC.md`](ROADMAP_PRAGMATIC.md) Phase E (E2). A bounded subprocess or worktree for commands aligns with (2).

**Gate:** Implement only after Phase E sandbox (or equivalent) exists **and** product need is clear (e.g. repeated harmful multi-tool batches in production). Until then, prefer `CHUMP_SPECULATIVE_BATCH=0` if the batch path causes confusion.

**Consequences:** Full transactional speculation is a **platform** feature (tool policy + executor), not a tweak to `rollback()`.
