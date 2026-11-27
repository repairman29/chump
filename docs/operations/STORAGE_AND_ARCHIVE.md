---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Storage, Worktree & Cache Hygiene

A typical Chump git clone is small, while local compiler caches (`target/`), linked agent worktrees, and embedding caches can grow to multiple gigabytes over heavy multi-agent development. All runtime and build directories are gitignored so you can reclaim disk space safely without losing repository history or configuration.

---

## 1. What Uses Disk Space

| Path | Contents | Safe to Delete? |
|------|----------|-----------------|
| `target/` | Rust `cargo` build artifacts | **Yes** — `cargo build` / `cargo test` rebuilds on demand. |
| `/tmp/chump-*` | Linked git worktrees from completed tasks | **Yes, once merged/closed** — prune with `git worktree prune`. |
| `.fastembed_cache/` | Optional local embedding model weights (`inprocess-embed`) | **Yes** — re-downloaded automatically on next use. |
| `sessions/` | Local chat/memory SQLite DB (`chump_memory.db`) | **Archive first** if you want to keep conversational history. |
| `logs/` | `chump.log` and evaluation JSONL traces | **Archive first** if you retain audit trails. |
| `.chump/state.db` | Canonical repository task queue (SQLite WAL) | **Keep** — stores your repository's task and PR ledger. |

---

## 2. Quick Disk Reclamation Commands

```bash
# 1. Reclaim Rust build artifacts (typically largest consumer: 2–15 GB)
cargo clean

# 2. Prune stale git worktree administrative entries after removing merged /tmp worktrees
git worktree list
git worktree prune

# 3. Clear optional local embedding cache
rm -rf .fastembed_cache
```

Inside a Chump source checkout, you can also use the dry-runnable cleanup helper:

```bash
./scripts/dev/cleanup-repo.sh --dry-run
./scripts/dev/cleanup-repo.sh
```

---

## 3. Archiving Runtime Sessions & Logs

Before clearing `sessions/` or `logs/` on a long-running workstation, create a dated archive outside the repository:

```bash
mkdir -p "$HOME/Chump-Archives"
tar -czf "$HOME/Chump-Archives/chump-runtime-$(date +%Y%m%d).tar.gz" sessions logs 2>/dev/null || true
```

In source checkouts, `./scripts/dev/cleanup-repo.sh --archive-runtime` automates tarball creation with an `ARCHIVE_MANIFEST.txt` summary.

---

## 4. Preventing Disk Exhaustion Automatically

Configure `disk_floor_gb` in `~/.chump/config.toml`:

```toml
[fleet]
disk_floor_gb = 5.0
```

When free disk space falls below `disk_floor_gb`, `chumpd` and `chump preflight` pause new worktree creation cleanly rather than corrupting git indices or failing mid-link with `ENOSPC`.

---

## Related Guides

- [Daemon & Service Operations](OPERATIONS.md)
- [File Leases & Worktrees](../process/AGENT_COORDINATION.md)
