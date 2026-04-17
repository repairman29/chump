# Multi-agent coordination

**Audience:** AI coding agents (Claude sessions, Cursor, autonomy loops, heartbeat rounds) working on this repo in parallel.

**Problem this solves:** Multiple agents touch the same files and gaps.yaml in parallel. Without coordination, you get:

- Duplicate parallel implementations of the same gap (we shipped `MEM-002` twice in April 2026 — once on `main`, once on `claude/sharp-cannon-2da898`).
- Silent file stomps when two agents edit the same line.
- Merge conflicts on every PR because `cargo fmt` drifts between agents.
- Wasted inference budget on work someone else is already doing.

This doc describes the four-part convention-based system in place as of **2026-04-17**.

---

## 1. `docs/gaps.yaml` — single source of truth for work items

Every improvement opportunity lives here with a stable ID (`EVAL-003`, `COG-004`, `MEM-002`, …) across 11 domains. Schema is self-documenting at the top of the file.

**Before starting work on a gap:**

1. `git fetch && git status` — make sure your branch is current with `origin/main`.
2. `grep -B1 -A5 "id: GAP-XYZ" docs/gaps.yaml` — read the acceptance criteria.
3. Flip `status: open` → `status: in_progress`. Commit just that change with a message like `claim(GAP-XYZ): <one-line what you're doing>`. Push immediately so other agents see the claim on their next fetch.
4. Do the work on your branch (typically `claude/<codename>`).

**On completion:**

1. Flip `status: in_progress` → `status: done` (or `partial` if you left a follow-up).
2. Add `closed_by:` (list of commit SHAs) and `closed_date: YYYY-MM-DD`.
3. If the gap shipped in pieces or deferred scope, file a follow-up gap with a new ID and `depends_on: [GAP-XYZ]`.
4. **Never delete** a gap entry — set `status: done` or `status: deferred` so the audit trail survives.

**Commit message convention:** cite the gap ID. `git log | grep MEM-` should give you the full history of that gap's work.

---

## 2. `.chump-locks/` — path-level optimistic leases

Implemented in **`src/agent_lease.rs`** (bootstrap in progress as of 2026-04-17).

**What it does:** Agents that are about to edit files claim them by writing a JSON lease file under `.chump-locks/<session_id>.json`. Other agents check leases before their own writes and abort on conflict. Leases TTL-expire (30m default, 4h max) and stale-reap on missed heartbeat (15m).

**When to claim:**

- Before editing any file outside your single-session scope.
- Especially before touching shared infrastructure: `src/main.rs`, `Cargo.toml`, `.github/workflows/`, `docs/gaps.yaml`, `scripts/install-hooks.sh`.
- Not needed for files that live in a unique-to-you worktree path (e.g., test output logs, `target/`).

**Claim file format** (one JSON file per session, filename `<session_id>.json`):

```json
{
  "session_id": "claude-funny-hypatia-coordination-docs-1776392268",
  "paths": [
    "docs/AGENT_COORDINATION.md",
    "AGENTS.md",
    "docs/gaps.yaml"
  ],
  "taken_at": "2026-04-17T01:57:48Z",
  "expires_at": "2026-04-17T02:57:48Z",
  "heartbeat_at": "2026-04-17T01:57:48Z",
  "purpose": "short reason — what you're working on",
  "worktree": ".claude/worktrees/funny-hypatia"
}
```

**Path matching:** exact path, directory prefix (`src/foo/` with trailing slash), or `**` glob (`ChumpMenu/**`). No regex.

**Session IDs:** precedence is `CHUMP_SESSION_ID` env → `~/.chump/session_id` file → random UUID.

**Manual claim** (before the Rust module is wired in): write the JSON file by hand. The format is stable — `src/agent_lease.rs` reads it straight.

**After finishing work:** release your lease (`release()` in Rust) or delete the JSON file. Expired leases get auto-reaped but leaving them behind is noisy.

---

## 3. Git branch conventions

- **`main`** — canonical. All CI runs here. Pre-commit hook keeps `cargo fmt` green.
- **`claude/<codename>`** — one branch per agent session. Examples: `claude/funny-hypatia`, `claude/sharp-cannon-2da898`. Worktrees under `.claude/worktrees/<codename>/` mirror the branch name.
- **PR to main** for review/merge. Keep PRs small; rebase yourself rather than asking maintainers to do it.
- **No force-push to main**, even to resolve a cargo-fmt glitch.

**When you fork a branch, immediately `git fetch` the main tip and note the commit.** If main advances significantly before your PR opens, rebase early — don't let main move 20 commits ahead of you or your PR becomes a merge nightmare.

---

## 4. Pre-commit fmt hook

**`scripts/install-hooks.sh`** installs the `pre-commit` hook (symlink into `.git/hooks/` or via `core.hooksPath` once that update lands).

**Why it exists:** multiple agents commit unformatted Rust, CI fails on `cargo fmt --check`, any in-flight dependabot PR has to be re-rebased to pick up the fix. With several agents active, drift was happening every 3-4 commits (April 2026). The hook runs `cargo fmt` on staged `.rs` files before the commit so drift stops at the source.

**Run once after cloning the repo or adding a worktree:**

```bash
./scripts/install-hooks.sh
```

**Skip for one commit only:** `git commit --no-verify` — and only if you have a genuine reason.

---

## Putting it together — the happy-path workflow

1. `git fetch && git pull` your branch.
2. Find an open gap in `docs/gaps.yaml`.
3. Claim a lease on the files you'll touch (write a JSON under `.chump-locks/`).
4. Flip the gap to `status: in_progress` and commit-push that one-line change.
5. Do the work. Cite the gap ID in every commit message.
6. Run tests. Run `cargo fmt --all`. Push.
7. Flip the gap to `status: done` with `closed_by: [<SHA>]` and `closed_date: YYYY-MM-DD`. Push.
8. Release the lease (delete the JSON or call `release()`).
9. Open a PR to main if you're on a branch.

---

## Failure modes to watch for

- **Your branch is wildly behind main** → rebase now, not later. See the [PR #27 retrospective](#) for an example of a rebase that waited too long.
- **Two agents flipped the same gap to `in_progress` at once** → the second one loses on push, pulls, sees the first claim, either picks something else or coordinates via PR comment.
- **Lease expired while you were still working** → refresh with a heartbeat (call `heartbeat()` or rewrite the JSON with a new `heartbeat_at`). If you're gone > 15 minutes without a heartbeat, another agent will reap your lease.
- **No gap exists for what you want to do** → add a new gap with the next sequential ID in the relevant domain. Don't just start editing.

---

## CLI cheatsheet — `chump` lease subcommands

The lease system is available from any shell via the `chump` binary, so
scripts and external agents can participate without writing JSON by hand.

```bash
# Status — list every active lease (yours and others').
chump --leases

# Claim paths (exit 0 on success, exit 2 + stderr on conflict).
chump --claim \
  --paths=src/foo.rs,src/bar/ \
  --ttl-secs=1800 \
  --purpose="implementing FEAT-042"

# Refresh your heartbeat. With --extend-secs, push expiry forward too.
chump --heartbeat --extend-secs=1800

# Release explicitly (or let it expire).
chump --release

# Maintenance: reap any stale/expired lease files.
chump --reap-leases
```

Set `CHUMP_SESSION_ID` in your shell/env to give the session a stable
name across invocations. Without it, each invocation generates a fresh
UUID (fine for one-shot scripts, bad for multi-step work).

```bash
export CHUMP_SESSION_ID="cursor-jeff-$(date +%s)"
chump --claim --paths=src/foo.rs --purpose="refactor foo"
# ... do work ...
chump --release
```

---

## For external agents (Cursor, Codex, scripts without the chump binary)

If you can't call the `chump` binary, write the lease JSON directly.
The format is stable and `src/agent_lease.rs` reads it verbatim.

```bash
SESSION_ID="${CURSOR_SESSION_ID:-cursor-$(date +%s)}"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# macOS uses -v+30M; Linux uses -d "30 minutes".
EXPIRES=$(date -u -v+30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d "30 minutes" +%Y-%m-%dT%H:%M:%SZ)

mkdir -p .chump-locks
cat > ".chump-locks/${SESSION_ID}.json" <<JSON
{
  "session_id": "${SESSION_ID}",
  "paths": ["src/foo.rs", "src/bar/"],
  "taken_at": "${NOW}",
  "expires_at": "${EXPIRES}",
  "heartbeat_at": "${NOW}",
  "purpose": "refactor foo for FEAT-042"
}
JSON

# ... do work ...

# Release when done.
rm -f ".chump-locks/${SESSION_ID}.json"
```

**Heartbeat loop** for long jobs (default stale threshold is 15 min —
without a refresh, other agents will reclaim your files):

```bash
(
  while [ -f ".chump-locks/${SESSION_ID}.json" ]; do
    sleep 60
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NEW_EXP=$(date -u -v+30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || date -u -d "30 minutes" +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp)
    sed -E \
      -e "s/(\"heartbeat_at\"[[:space:]]*:[[:space:]]*\")[^\"]*/\\1${NOW}/" \
      -e "s/(\"expires_at\"[[:space:]]*:[[:space:]]*\")[^\"]*/\\1${NEW_EXP}/" \
      ".chump-locks/${SESSION_ID}.json" > "$tmp" && mv "$tmp" ".chump-locks/${SESSION_ID}.json"
  done
) &
HEARTBEAT_PID=$!
trap "kill $HEARTBEAT_PID 2>/dev/null; rm -f .chump-locks/${SESSION_ID}.json" EXIT
```

**Pre-commit enforcement** is automatic after
`./scripts/install-hooks.sh`: any `git commit` touching a path claimed
by another live session fails with a message naming the holder.
Bypass with `CHUMP_LEASE_CHECK=0` (debug only — defeats the system)
or `git commit --no-verify` (same caveat).

---

## See also

- `docs/gaps.yaml` — the master registry
- `src/agent_lease.rs` — the lease system implementation
- `src/main.rs` — `--claim` / `--release` / `--heartbeat` / `--leases` / `--reap-leases`
- `scripts/git-hooks/pre-commit` — lease-collision guard + cargo-fmt auto-fix
- `scripts/install-hooks.sh` — per-worktree hook installer
- `AGENTS.md` — Chump ↔ Cursor protocol (older, complementary)
