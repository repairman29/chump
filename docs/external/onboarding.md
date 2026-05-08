# Onboarding: Consuming Chump in an External Project

This guide walks you through bootstrapping Chump integration in your project (e.g., Surety Robotics).

## Prerequisites

- **Rust 1.80+** or **Python 3.10+** (depending on integration mode)
- **Git** (Chump tracks state via git worktrees and branches)
- **SQLite 3.40+** (for state.db)
- **4 GB RAM, 2 GB disk** minimum for a single-worker Chump instance
- **Network:** local NATS (optional, for multi-agent coordination)

## Phase 1: Environment Setup

### 1.1 Clone and initialize

```bash
git clone https://github.com/[your-org]/chump.git
cd chump
git fetch origin main --quiet
```

### 1.2 Install Chump CLI

```bash
# From source (recommended for external integration)
cargo build --release -p chump
export PATH="$PWD/target/release:$PATH"

# Or, via your package manager (check your deployment setup)
chump --version
```

### 1.3 Initialize state.db and worktree root

```bash
# Create the coordination database
chump init --domain YOUR_DOMAIN --no-fleet

# Verify setup
ls -la .chump/
# Should contain: state.db, oauth-token.json, .gitignore
```

### 1.4 Validate ambient hooks (optional, for cross-agent events)

```bash
bash scripts/setup/install-ambient-hooks.sh
# Emits events to .chump-locks/ambient.jsonl as agents claim/ship work
```

## Phase 2: First Integration — Query the Gap Registry

### 2.1 List open gaps in your domain

```bash
chump gap list --domain YOUR_DOMAIN --status open
```

Output:
```
ID             | Title                        | Status | Priority | Effort
────────────────────────────────────────────────────────────────────────────
YOUR_DOMAIN-42 | Example integration task     | open   | P1       | m
YOUR_DOMAIN-43 | Another task                 | open   | P2       | s
```

### 2.2 Inspect a specific gap

```bash
chump gap show YOUR_DOMAIN-42

# Output includes:
# - Title, description, acceptance criteria
# - Dependencies (other gaps this blocks on)
# - Estimated effort (s/m/l) and priority (P0/P1/P2)
# - Status and who claimed it
```

### 2.3 Claim a gap (create a worktree, start work)

```bash
chump claim YOUR_DOMAIN-42 --paths "src/,docs/" --branch main

# What this does:
# 1. Fetches latest main
# 2. Creates a git worktree at .claude/worktrees/your-domain-42-<timestamp>
# 3. Reserves a lease in .chump-locks/ (prevents collisions with other agents)
# 4. Returns the worktree path
```

Output:
```
Claimed YOUR_DOMAIN-42
Worktree: /path/to/chump/.claude/worktrees/your-domain-42-20260508-120000
Lease: .chump-locks/your-domain-42-20260508-120000.json (expires in 2h)
```

## Phase 3: Integrate Chump into Your Build/Deploy

### 3.1 Embed the Chump CLI in your CI pipeline

```bash
# Example: GitHub Actions
- name: Query gaps
  run: |
    chump gap list --domain YOUR_DOMAIN --json > gaps.json
    # Parse gaps.json, filter by priority, and dispatch work
```

### 3.2 Use `CHUMP_SCRIPTS` environment variable for vendored scripts

```bash
export CHUMP_SCRIPTS="/path/to/my/scripts"
# Now: chump invoke my-script --arg value
# Looks for: $CHUMP_SCRIPTS/my-script (no .sh extension needed)
```

Alternative: inline scripts via `scripts/chump-*`:
```bash
bash scripts/coord/chump-commit.sh src/ -m "my commit message"
```

### 3.3 Coordinate multi-repo state with state.db

```bash
# Each repo gets its own state.db fork + schema
# Chump manages merges automatically on branch rebase

# Query repo-specific missions:
chump mission list --repo YOUR_REPO --status pending

# Claim work atomically across repos:
chump claim YOUR_DOMAIN-42 --repo YOUR_REPO
```

## Phase 4: Validate the Integration

### 4.1 Run a smoke test

```bash
chump --self-test
# Verifies:
# - state.db is readable/writable
# - Git worktree creation works
# - Lease acquisition and release
# - Ambient hook write (if enabled)
```

### 4.2 Simulate a work flow

```bash
# Claim → edit → commit → ship workflow
chump claim YOUR_DOMAIN-999 --paths "README.md"

# Make a change
echo "test" >> .claude/worktrees/your-domain-999-*/README.md

# Commit (using Chump's atomic wrapper)
bash scripts/coord/chump-commit.sh README.md -m "WIP: test integration"

# Review the commit
git log -1 --format="%H %s"

# Ship (open PR, arm auto-merge, update gap status)
bash scripts/coord/bot-merge.sh --gap YOUR_DOMAIN-999 --auto-merge
```

### 4.3 Inspect the ambient event log

```bash
tail -20 .chump-locks/ambient.jsonl
# Should see events like:
# {"ts":"2026-05-08T...","kind":"lease_acquired","gap_id":"YOUR_DOMAIN-999",...}
# {"ts":"2026-05-08T...","kind":"commit","sha":"abc123",...}
# {"ts":"2026-05-08T...","kind":"pr_opened","pr_number":42,...}
```

## Phase 5: Common Patterns

### Multi-domain coordination

```bash
# Query gaps across multiple domains
chump gap list --domain "INFRA,YOUR_DOMAIN" --status open

# Filter by effort
chump gap list --domain YOUR_DOMAIN --effort "s,m" --status open
```

### Dependency chains

```bash
# Show what depends on YOUR_DOMAIN-42
chump gap list --depends-on YOUR_DOMAIN-42

# Show what YOUR_DOMAIN-42 depends on
chump gap show YOUR_DOMAIN-42 | grep depends_on
```

### Leases and collision avoidance

```bash
# List active leases (agents currently working)
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "no active leases"

# Release a lease manually (if agent crashes)
chump --release --lease .chump-locks/YOUR_DOMAIN-42-*.json
```

## Troubleshooting

### state.db locked

```bash
# Another agent is holding the lock
# Wait 30s or:
pkill -f "sqlite.*state.db"  # last resort
```

### Worktree creation fails

```bash
# Check if the path already exists
ls -d .claude/worktrees/your-domain-42-* 2>/dev/null

# Remove stale worktree
rm -rf .claude/worktrees/your-domain-42-<old-timestamp>

# Retry
chump claim YOUR_DOMAIN-42
```

### Lease expiration

By default, leases expire in **2 hours**. To renew:
```bash
chump --renew --lease .chump-locks/YOUR_DOMAIN-42-*.json --ttl 2h
```

## Next Steps

1. **Run a full workflow** — claim → edit → commit → ship on a real gap
2. **Set up CI/CD integration** — automate gap queries and dispatch in your pipeline
3. **Configure MCP servers** — see [mcp-config-catalog.md](mcp-config-catalog.md)
4. **Explore state.db semantics** — see [state-db-semantics.md](state-db-semantics.md)
5. **Read failure recovery** — see [failure-recovery.md](failure-recovery.md) to prepare for production

---

**Stuck?** Check [failure-recovery.md](failure-recovery.md) for common issues, or file a gap with `chump gap reserve --domain INFRA --title "onboarding issue: ..."`.
