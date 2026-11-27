---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Multi-Agent File Leases & Worktrees

When two or more coding agents edit the same git checkout concurrently, they fail in predictable ways: silent file overwrites, mid-rebase stomps, duplicate PRs for the same bug, and accidental edits to CI workflows.

Chump solves this at the repository boundary using four deterministic primitives that work with **any** coding harness (`Claude Code`, `Cursor`, `Codex CLI`, `OpenCode`, `Aider`, `goose`, or human `git commit`):

1. **Canonical SQLite Task Store (`.chump/state.db`)** — atomic task reservation and dependency tracking.
2. **Path & Symbol Leases (`.chump-locks/<session>.json`)** — time-bounded ownership of file globs or Rust/TS symbols.
3. **Isolated Linked Git Worktrees** — one branch and working tree per claimed task.
4. **Native Rust Git Firewall (`chump hook` + `chump ship`)** — `<2ms` pre-commit/pre-push enforcement and gate-file auto-merge protection.

---

## 1. End-to-End Lifecycle

```
chump gap reserve  ──►  .chump/state.db (assigns unique ID, e.g. INFRA-042)
        │
        ▼
  chump claim      ──►  Creates isolated worktree (/tmp/chump-infra-042)
                        + branch (chump/infra-042-claim)
                        + lease (.chump-locks/<session>.json)
                        + emits gap_claimed to .chump-locks/ambient.jsonl
        │
        ▼
  Agent Edits      ──►  chump hook pre-commit verifies staged paths match
                        the session's lease, scans for secrets, & runs rustfmt
        │
        ▼
chump preflight    ──►  Runs fmt, clippy -D warnings, check, & scoped tests
        │
        ▼
  chump ship       ──►  Pushes branch, opens PR, blocks --auto-merge if gate
                        files (.github/workflows/*, hooks) were modified
```

---

## 2. Task Registry (`.chump/state.db`)

Tasks ("gaps") live in `.chump/state.db` in SQLite WAL mode, supporting concurrent readers and serialized atomic writes without YAML merge conflicts.

```bash
# Reserve a new task atomically
chump gap reserve \
  --domain INFRA \
  --title "Enforce connection pool timeout in SQLite store" \
  --priority P1 \
  --effort s

# Inspect open tasks
chump gap list --status open
chump gap list --status open --format json

# Check whether a task is unblocked and unclaimed
chump gap preflight INFRA-042
```

---

## 3. Path & Symbol Leases (`.chump-locks/`)

`chump claim` atomically checks `.chump-locks/*.json` for overlapping active claims before creating a worktree and writing your lease:

```bash
# Path-glob lease (exclusive to the directory or files listed)
chump claim INFRA-042 \
  --role target \
  --paths "crates/chump-storage/**,tests/storage_pool.rs" \
  --reason "Add busy_timeout configuration and regression test"
```

### Lease JSON Schema

Each active lease is a plain JSON file under `.chump-locks/<session_id>.json` (gitignored):

```json
{
  "session_id": "claim-infra-042-41820-1795800000",
  "gap_id": "INFRA-042",
  "purpose": "gap:INFRA-042",
  "paths": [
    "crates/chump-storage/**",
    "tests/storage_pool.rs"
  ],
  "taken_at": "2026-11-27T18:00:00Z",
  "heartbeat_at": "2026-11-27T18:15:00Z",
  "expires_at": "2026-11-27T22:00:00Z"
}
```

### Lease Rules

- **Non-overlapping globs run in parallel:** Agent A leasing `crates/chump-pal/**` and Agent B leasing `web/site/**` commit and push simultaneously with zero contention.
- **Overlapping globs fail closed:** If Agent B attempts to claim or `git commit` a file covered by Agent A's unexpired lease, `chump claim` and `LeaseCollisionGuard` reject the operation immediately and print the owning `session_id` and `gap_id`.
- **Automatic crash recovery:** Every lease carries an `expires_at` timestamp and PID/session metadata. The `chumpd` supervisor (`lease_reaper.rs`) automatically reaps expired or dead-PID leases so crashed agent tabs never wedge the repository.
- **Explicit release:** Run `chump --release` when abandoning work early.

---

## 4. Pre-Commit & Pre-Push Firewall (`chump hook`)

Install the compiled Rust hooks in any repository:

```bash
chump hook install
chump hook status
```

| Guard | Stage | What It Enforces |
|-------|-------|------------------|
| `LeaseCollisionGuard` | `pre-commit` | Blocks commits touching files leased by another active `CHUMP_SESSION_ID`. |
| `SecretPatternGuard` | `pre-commit` | Blocks API keys, OAuth tokens (`sk-ant-*`, `ghp_*`, AWS keys), and private keys before they enter git history. |
| `SubmoduleSanityGuard` | `pre-commit` | Prevents accidental submodule pointer regressions. |
| `RustFmtGuard` | `pre-commit` | Verifies Rust formatting on staged `.rs` files. |
| `ProtectedBranchGuard` | `pre-push` | Prevents direct pushes to `main` / `master` so all work lands via reviewable PRs. |

Never pass `git commit --no-verify` to bypass a lease collision—resolve the scope overlap or wait for the sibling PR to land.

---

## 5. Coordination Event Stream (`ambient.jsonl`)

Every coordinator lifecycle transition appends one structured RFC3339 JSON event line to `.chump-locks/ambient.jsonl`:

- `gap_claimed` / `lease_released` / `stale_lease_reaped`
- `commit_created` / `preflight_passed`
- `pr_shipped` / `gate_file_automerge_refused`
- `fleet_auth_fallback` / `provider_circuit_opened`

Tail the live stream during multi-agent runs:

```bash
tail -f .chump-locks/ambient.jsonl
```

---

## 6. Shipping & Gate-File Protection (`chump ship`)

When implementation and `chump preflight` pass inside your worktree:

```bash
# Push branch and open PR for human review
chump ship --gap INFRA-042 --mode manual

# Or arm GitHub squash auto-merge (only allowed when zero gate files were touched)
chump ship --gap INFRA-042 --mode bot-merge
```

**Gate-file auto-merge refusal:** `crates/chump-ship` inspects the branch diff against `origin/main`. If the PR modifies `.github/workflows/**`, `scripts/git-hooks/**`, `crates/chump-git-hooks/**`, or security gate configs, `chump ship` refuses `--auto-merge` by construction so a human operator always reviews changes to the CI or hook firewall.

For external repositories, pair `chump ship` with `chump external verify-merge --pr <N> --repo <owner/repo> --gap <ID>` to verify that new regression tests fail on base and pass on head before merging.

---

## Related Guides

- [IDE & Terminal Workflows](CHUMP_CURSOR_FLEET.md)
- [Daemon & Service Operations](../operations/OPERATIONS.md)
- [System Architecture](../architecture/ARCHITECTURE.md)
