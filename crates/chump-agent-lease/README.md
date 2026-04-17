# chump-agent-lease

**Path-level optimistic leases for multi-agent coordination on a shared repo.**

When multiple AI agents (Claude sessions, Cursor, GitHub Actions bots, nightly cron jobs) edit the same repository in parallel, they can silently stomp each other's work. This crate provides a minimal cooperative protocol to prevent that:

- Before editing files, an agent **claims** the paths it's working on.
- Other agents **check** for conflicts before their own writes.
- Leases **expire** automatically on TTL + heartbeat, so a crashed agent never holds locks permanently.

The protocol is deliberately minimal — plain JSON on disk, no daemon, no network. That means external agents (editors, CI, bash scripts) can participate just by reading/writing the files.

## Why

Running one agent is easy. Running five agents on the same codebase is a silent-data-loss event waiting to happen. Observed failure modes that motivated this crate:

- Agent A writes `foo.rs`, agent B's `git pull` overwrites A's uncommitted changes.
- Two agents implement the same gap in parallel because neither checked what the other was doing.
- `cargo fmt` drift from concurrent commits forces rebase after rebase.

Existing tooling (OS file locks, git worktrees, PR-level branch protection) doesn't cover the "multiple agents in one repo at once" case. This crate does.

## Installation

```toml
[dependencies]
chump-agent-lease = "0.1"
```

## Example

```rust
use chump_agent_lease::{claim_paths, release, DEFAULT_TTL_SECS};

fn main() -> anyhow::Result<()> {
    // Claim the files you're about to edit.
    let lease = claim_paths(
        &["src/foo.rs", "src/bar/"],
        DEFAULT_TTL_SECS,
        "refactoring foo for FEAT-042",
    )?;

    // ... your edits ...

    // Release when done (or let the TTL expire).
    release(&lease)?;
    Ok(())
}
```

For long-running work, use `claim_with_heartbeat` so a tokio task refreshes your lease automatically:

```rust
use chump_agent_lease::{claim_with_heartbeat, release};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let (lease, _heartbeat_handle) = claim_with_heartbeat(
        &["src/foo.rs"],
        /* ttl_secs */ 1800,
        "long-running reindex",
        /* heartbeat_interval_secs */ 60,
    )?;
    // ... do work for 20 minutes ...
    release(&lease)?;
    Ok(())
}
```

## Conflict check

Before editing a file that's in an unclaimed path, check for someone else's claim:

```rust
use chump_agent_lease::{is_path_claimed_by_other, current_session_id};

let my_id = current_session_id();
if let Some(holder) = is_path_claimed_by_other("src/foo.rs", &my_id) {
    eprintln!("foo.rs is claimed by {holder}; backing off");
    return;
}
// ... edit foo.rs ...
```

## On-disk format

One JSON file per session under `<repo>/.chump-locks/<session_id>.json`:

```json
{
  "session_id":  "claude-funny-hypatia",
  "paths":       ["src/foo.rs", "src/bar/"],
  "taken_at":    "2026-04-17T01:57:48Z",
  "expires_at":  "2026-04-17T02:27:48Z",
  "heartbeat_at":"2026-04-17T01:57:48Z",
  "purpose":     "refactoring foo for FEAT-042",
  "worktree":    ".claude/worktrees/funny-hypatia"
}
```

Timestamps are RFC3339 UTC; any language can read or write them. External agents without the crate can write the JSON directly.

## Path matching

Three match types:

- **Exact**: `src/foo.rs` — matches only `src/foo.rs`.
- **Directory prefix**: `src/bar/` (trailing slash) — matches anything under `src/bar/`.
- **Glob**: `ChumpMenu/**` — same as prefix `ChumpMenu/`. `**` alone matches every path.

No regex, no `fnmatch`. Simple by design.

## Session IDs

Each agent process has a stable session id. Precedence:

1. `CHUMP_SESSION_ID` env var — preferred for named long-running agents.
2. `$HOME/.chump/session_id` — persistent cache across runs for the same user+machine.
3. Random UUID — ephemeral fallback for one-off scripts.

## The enforcement floor

The lease protocol is **cooperative**: a malicious or poorly-written agent can ignore it. For an enforcement floor, pair this crate with a pre-commit hook that rejects commits touching another session's claimed paths. See the `chump` repository's `scripts/git-hooks/pre-commit` for a reference implementation.

## License

MIT. Part of the [Chump](https://github.com/repairman29/chump) project.
