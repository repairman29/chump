---
doc_tag: canonical
owner_gap: DOC-022
last_audited: 2026-05-12
---

# Using Chump as a coordination platform in your own repo

> **First reader:** Surety Robotics' Reeve project.
> **TL;DR:** point `CHUMP_REPO` at your repo, vendor three scripts, wire one Claude Code hook, and you get the full Chump fleet coordination loop (gap registry, lease system, bot-merge pipeline) against your own codebase.

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| `chump` binary on `PATH` | `brew install chump` or `cargo install chump` |
| Git repo with a `main` branch | Must have `.git/` at root |
| `gh` CLI authenticated | `gh auth status` must pass |
| Claude Code (for agents) | Optional — scripts work standalone |

---

## 2. Set `CHUMP_REPO`

`CHUMP_REPO` tells every `chump` invocation where the coordination state lives. Set it in your repo's `.env` (or shell profile):

```bash
# .env (or ~/.zshrc / ~/.bashrc)
export CHUMP_REPO=/path/to/your-repo
```

Chump loads `.env` via `dotenvy` walking up from CWD, so agents and scripts running in linked worktrees under `/tmp/` will find the correct repo root automatically.

**Verification:**
```bash
chump gap list --status open   # should open/create state.db inside your repo
```

---

## 3. Seed the gap registry

On a fresh repo, seed an empty state database:

```bash
chump gap import --bootstrap   # creates .chump/state.db + .chump/state.sql
```

After seeding, gaps are filed and tracked via:
```bash
chump gap reserve --domain INFRA --title "My first gap"
chump gap list --status open
```

`state.db` is the canonical store; never edit it directly. Commit `.chump/state.sql` (the human-readable diff mirror) so CI can diff it.

---

## 4. Vendor the coordination scripts

Copy three scripts into your `scripts/coord/` directory (or wherever you prefer):

```bash
# From a Chump checkout or via curl:
mkdir -p scripts/coord scripts/git-hooks

cp /path/to/chump/scripts/coord/bot-merge.sh    scripts/coord/
cp /path/to/chump/scripts/coord/gap-preflight.sh scripts/coord/
cp /path/to/chump/scripts/coord/gap-claim.sh     scripts/coord/
```

These scripts read `CHUMP_REPO` from the environment, so they work against your repo without modification. Keep them in your repo (not as a git submodule) so you can patch them freely.

**Optional extras** (recommended for multi-agent fleets):
```bash
cp /path/to/chump/scripts/coord/chump-commit.sh   scripts/coord/
cp /path/to/chump/scripts/coord/gap-status.sh     scripts/coord/
```

---

## 5. Install pre-commit hooks (subset)

You don't need all of Chump's hooks. The minimal useful set:

```bash
mkdir -p scripts/git-hooks
cp /path/to/chump/scripts/git-hooks/pre-commit-gap-divergence.sh scripts/git-hooks/
cp /path/to/chump/scripts/git-hooks/pre-commit-git-identity.sh   scripts/git-hooks/
```

Wire them into `.git/hooks/pre-commit`:

```bash
cat > .git/hooks/pre-commit << 'EOF'
#!/usr/bin/env bash
REPO="$(git rev-parse --show-toplevel)"
# Gap registry write discipline (prevents direct state.db edits)
[ -x "$REPO/scripts/git-hooks/pre-commit-gap-divergence.sh" ] && \
  "$REPO/scripts/git-hooks/pre-commit-gap-divergence.sh" || exit 1
# Git identity guard (prevents committing as t@t.t from version tests)
[ -x "$REPO/scripts/git-hooks/pre-commit-git-identity.sh" ] && \
  "$REPO/scripts/git-hooks/pre-commit-git-identity.sh" || exit 1
EOF
chmod +x .git/hooks/pre-commit
```

Skip hooks you don't need (e.g., `pre-commit-obs-budget.sh` requires the Chump observability registry).

---

## 6. Wire Claude Code ambient hooks

Add this to `.claude/settings.json` in your repo so agent sessions emit to `ambient.jsonl`:

```json
{
  "hooks": {
    "SessionStart": [{
      "hooks": [{
        "type": "command",
        "command": "REPO=$(git rev-parse --show-toplevel 2>/dev/null) && [ -x \"$REPO/scripts/dev/ambient-emit.sh\" ] && \"$REPO/scripts/dev/ambient-emit.sh\" session_start 2>/dev/null || true",
        "async": true
      }]
    }]
  }
}
```

`ambient.jsonl` accumulates fleet health events at `.chump-locks/ambient.jsonl`. Read it with:
```bash
tail -30 .chump-locks/ambient.jsonl | python3 -m json.tool
```

---

## 7. `.gitignore` entries

Add to your `.gitignore`:

```gitignore
# Chump coordination state — runtime only, not committed
.chump-locks/*.json
.chump-locks/ambient.jsonl

# Compiled chump binary (if building from source in-repo)
target/

# Chump worktree artifacts
.chump/worktrees/
```

**Do commit:**
- `.chump/state.sql` — the readable gap registry diff (for PR reviews)
- `.chump/state.db` — the SQLite canonical store
- `scripts/coord/*.sh` — the vendored coordination scripts
- `.claude/settings.json` — agent hook configuration

---

## 8. Bootstrap runbook (clean repo → first dispatched gap)

```bash
# 1. Install chump
brew install chump   # or: cargo install chump

# 2. Point at your repo
export CHUMP_REPO="$(pwd)"
echo "CHUMP_REPO=$(pwd)" >> .env

# 3. Seed the gap registry
chump gap import --bootstrap

# 4. File your first gap
chump gap reserve --domain INFRA --title "RESILIENT: add CI lint gate"

# 5. Claim and work it
chump claim INFRA-1
# → creates /tmp/chump-infra-1 worktree + lease

# 6. Ship
cd /tmp/chump-infra-1
# ... implement ...
scripts/coord/bot-merge.sh --gap INFRA-1 --auto-merge
```

---

## 9. Multi-agent configuration (`CHUMP_REPO_PROFILES`)

For teams where different agents work different repos simultaneously:

```bash
export CHUMP_REPO_PROFILES="reeve=/path/to/reeve,chump=/path/to/chump"
```

Switch active repo in a session:
```bash
chump set-repo reeve   # sets working repo for this session
chump gap list         # lists gaps from the Reeve registry
```

---

## See also

- [`CLAUDE.md`](../../CLAUDE.md) — Chump-internal session rules (reference, not required for external use)
- [`docs/process/AGENT_COORDINATION.md`](./AGENT_COORDINATION.md) — Lease system and branch model
- [`scripts/coord/README.md`](../../scripts/coord/README.md) — Full coordination script reference
- [`docs/process/CLAUDE_GOTCHAS.md`](./CLAUDE_GOTCHAS.md) — Operational failure modes and recovery
