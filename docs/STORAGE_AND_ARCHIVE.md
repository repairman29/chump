# Storage, cleanup, and archive (keep context without filling the disk)

This repo’s **git history stays small** (~10MB of objects in a typical clone). Most disk use is **local build output and runtime data**, which you can trim or archive without losing *project* context—roadmaps, briefs, and code stay in git.

**Superseded remote branches** (experiments you are not merging) are documented separately: [archive/SUPERSEDED_BRANCHES.md](archive/SUPERSEDED_BRANCHES.md) and [`scripts/archive-superseded-branch.sh`](../scripts/archive-superseded-branch.sh).

## What uses space (typical)

| Path | Role | Safe to remove? |
|------|------|-----------------|
| `target/` | Rust `cargo` artifacts | Yes — `cargo build` / `cargo test` rebuilds. Often **multi‑GB**. |
| `ChumpMenu/.build/` | SwiftPM build for the menu app | Yes — rebuilds on next Xcode/Swift build. |
| `.fastembed_cache/` | Optional in-process embed model cache | Yes — re-downloads on first use (see `inprocess-embed` feature). |
| `sessions/` | SQLite + session files (`chump_memory.db`, etc.) | **Archive first** if you care about history; see below. |
| `logs/` | `chump.log`, QA logs, JSONL | **Archive first** if you want a paper trail. |
| `chump-brain/` | Wiki / brain markdown (if present) | Do **not** delete without backup; not in default `.gitignore` for content you care about. |

## Strategy: “don’t lose context”

1. **Source of truth stays in git** — `docs/ROADMAP.md`, `NORTH_STAR.md`, `AGENTS.md`, code. Cleaning `target/` does not touch that.
2. **Runtime data** (`sessions/`, `logs/`) — if you need continuity across months, **tarball + date** before deleting local copies. Keep the archive on another volume, cloud, or Time Machine; the repo only needs a *pointer* (this doc + optional one-line note in `logs/README.md` if you add one).
3. **Optional manifest** — the archive script writes `ARCHIVE_MANIFEST.txt` inside each tarball (paths, approximate sizes, timestamp) so you know what was preserved without opening SQLite.
4. **Git never stored `target/`** — teammates don’t pay your 11GB; it’s always local.

## Commands (quick)

```bash
# Reclaim the most space: Rust build dir (rebuild later)
cargo clean

# Swift menu app build cache
rm -rf ChumpMenu/.build
```

## Scripted cleanup and archive

From repo root:

```bash
# Dry run: show what would happen
./scripts/cleanup-repo.sh --dry-run

# Clean build dirs only (default)
./scripts/cleanup-repo.sh

# Archive sessions + logs, then empty those directories
./scripts/cleanup-repo.sh --archive-runtime --prune-runtime-after-archive
```

Archives default to `./archive/` (gitignored) with a timestamped name. Override destination:

```bash
export CHUMP_ARCHIVE_DIR="$HOME/Archive/Chump-archives"
./scripts/cleanup-repo.sh --archive-runtime
```

## Ongoing habits

- Run `cargo clean` before long breaks or when switching toolchains if disk is tight.
- Prefer **archiving** large log drops (battle QA, RPC JSONL) once a milestone ships, then gzip.
- If `sessions/chump_memory.db` grows large, archiving **is** your backup; vacuuming is optional SQLite maintenance (outside this doc’s scope).

## Cursor / IDE

A `.cursorignore` file excludes `target/`, build dirs, and runtime folders from indexing so the editor stays fast and does not duplicate huge trees into context.

---

## In-process embed cache (`.fastembed_cache/`)

When you build with the **`inprocess-embed`** Cargo feature, the first run may download embedding models into **`.fastembed_cache/`** (gitignored). **Safe to delete** the directory; the next run re-downloads (network + time cost). To reclaim disk without touching `target/`:

```bash
rm -rf .fastembed_cache
```

Cross-link: optional `cleanup-repo.sh` does not remove this by default; add a manual step or alias if you use embeddings often.

---

## Git maintenance (maintainers)

**When to run `git gc`:** After large history rewrites, or if `.git` grows unexpectedly on a long-lived clone. Routine developers rarely need it.

```bash
git gc --prune=now
```

**Spotting huge blobs:** `git rev-list --objects --all | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | sed -n 's/^blob //p' | sort -rnk2 | head` (lists largest blobs). If a secret or multi-GB file was committed, use `git filter-repo` or BFG (outside this doc). **GitHub** push limits and LFS policies: see GitHub Docs → repositories → managing large files.

---

## Quarterly cold export (sessions + logs + brain)

**Goal:** Off-site backup of **runtime** and **wiki** without relying on the laptop alone.

1. **Runtime (automated):** Use [scripts/cleanup-repo.sh](../scripts/cleanup-repo.sh):
   ```bash
   export CHUMP_ARCHIVE_DIR=~/Archive/Chump-archives
   ./scripts/cleanup-repo.sh --archive-runtime
   ```
   Each tarball includes `ARCHIVE_MANIFEST.txt` listing paths and timing.

2. **Brain (`chump-brain/`):** Not included in that tarball by default. Quarterly, copy or tar the brain directory separately (exclude machine-local junk if any):
   ```bash
   tar -C "$(dirname "$CHUMP_BRAIN_PATH")" -czf ~/Archive/Chump-archives/chump-brain-$(date +%Y%m%d).tar.gz "$(basename "${CHUMP_BRAIN_PATH:-chump-brain}")"
   ```
   Adjust if `CHUMP_BRAIN_PATH` is absolute.

3. **Restore smoke check:** Unpack an archive to a temp dir; confirm `ARCHIVE_MANIFEST.txt` lists expected folders; for SQLite, open `sessions/chump_memory.db` with `sqlite3 .tables` if present. For brain, spot-check `self.md` or `portfolio.md`.

4. **Schedule:** Calendar reminder (e.g. quarterly) or tie to [docs/ROADMAP.md](ROADMAP.md) Phase I reconciliation.
