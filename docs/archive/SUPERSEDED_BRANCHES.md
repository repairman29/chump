# Superseded remote branches

Branches listed here were **experiments or agent side branches**. Capabilities worth keeping were **merged or reimplemented on `main`**. Do **not** treat these as second lines of development—open PRs against **`main`** only.

## Registry

| Remote ref | Status | Notes |
|------------|--------|--------|
| `origin/claude/heuristic-swanson` | **Superseded** (2026-04) | Short stack (MCP/worktree/context firewall/cognitive UI experiments). `main` is far ahead on the same merge-base; full merge would **revert** integrated work. |

Update this table when you intentionally retire another long-lived experiment.

## Archive before delete (recommended)

Preserves the exact commit graph in git **without** keeping a confusing default remote branch.

**Script (creates the tag locally; you push):**

```bash
./scripts/archive-superseded-branch.sh origin/claude/heuristic-swanson
```

**Manual equivalent:**

```bash
git fetch origin
TAG="archive/claude-heuristic-swanson-$(date -u +%Y%m%d)"
git tag -a "$TAG" -m "Archive superseded branch origin/claude/heuristic-swanson (see docs/archive/SUPERSEDED_BRANCHES.md)" origin/claude/heuristic-swanson
git push origin "$TAG"
```

Optional: remove the remote branch after the tag push (requires repo admin; irreversible for the branch name—recoverable from the tag).

```bash
git push origin --delete claude/heuristic-swanson
```

## If you need code from a superseded branch

1. `git fetch origin`
2. `git log --oneline origin/claude/heuristic-swanson` (or inspect the archive tag)
3. **Cherry-pick specific commits** onto a fresh branch from `main`, or re-port manually with tests.

Never merge the whole branch into `main` without a full diff review against this doc.
