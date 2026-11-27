---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# CLI Flags & Subcommands Reference

Run `chump --help` (or `chump <subcommand> --help`) at any time to inspect the full command tree compiled into your binary.

---

## Core Subcommands Overview

| Subcommand | Purpose |
|------------|---------|
| `chump init [--yes]` | Initialize `.chump/state.db` and verify model readiness in a repository |
| `chump config <init\|show\|validate\|path>` | Manage and schema-validate `~/.chump/config.toml` |
| `chump hook <install\|status\|pre-commit\|pre-push>` | Install and run the native Rust git lease & secret firewall |
| `chump gap <reserve\|list\|show\|preflight\|ship>` | Reserve, query, and transition tasks in `.chump/state.db` |
| `chump claim <GAP-ID> --paths "<globs>"` | Atomically acquire a file/symbol lease and create a linked git worktree |
| `chump preflight` | Run `cargo fmt --check`, `clippy -D warnings`, `check`, and scoped tests locally |
| `chump ship --gap <GAP-ID> --mode <manual\|bot-merge>` | Push branch, open PR, and enforce gate-file auto-merge guards |
| `chump service <install\|status\|uninstall> [--dry-run]` | Manage `chumpd` on macOS `LaunchAgents`, Linux `systemd --user`, or Windows `ChumpDaemon` |
| `chump up [--foreground\|--status]` | Launch or query the `chumpd` supervisor directly |
| `chump fleet <status\|doctor\|level N>` | Inspect worker health, verify auth, or adjust autonomy level (`0` = immediate stop) |
| `chump onboard <owner/repo> [--apply]` | Scan an external repository and seed grounded tasks with `file:line` citations |
| `chump improve <owner/repo> [--apply]` | Run autonomous task pick, worktree edit, test, and PR loop on an external repo |
| `chump external verify-merge --pr <N> --repo <owner/repo>` | Verify GitHub CI and prove new tests fail on base and pass on head |
| `chump llm-complete [--model <tier>] "<prompt>"` | Send a prompt through the shared `ProviderCascade` from scripts |

---

## Global & Cross-Cutting Flags

### `--why`

Appends a single-line rationale to **`stderr`** explaining routing or coordination decisions while keeping **`stdout`** machine-parseable:

| Command | Example `stderr` Output |
|---------|-------------------------|
| `chump gap reserve --domain INFRA --title "..." --why` | `reserved INFRA-042 — why: atomic ID allocation from INFRA sequence` |
| `chump claim INFRA-042 --why` | `claimed INFRA-042 — why: gap open and unclaimed, TTL=14400s` |
| `chump --once "Summarize changes" --why` | `cascade chose slot=gemini-primary — why: priority=10, circuit=closed` |

### `--once "<prompt>"`

Runs a single agent turn in the terminal and exits cleanly (`0` on success).

### `--web [--port <PORT>]`

Starts the local HTTP + SSE operator cockpit and product tool suite (default port `3000`).

### `--acp`

Starts the Agent Client Protocol JSON-RPC 2.0 server over `stdin`/`stdout` for Zed and JetBrains IDEs.

### `--format <human|json|csv>` (and `--json`)

Selects structured output formatting on list and status commands:

```bash
chump gap list --status open --format json | jq '.[].id'
chump gap list --status open --format csv > open-gaps.csv
```

### `--quiet`

Suppresses informational `stdout` output on success, returning exit code `0` or `1` for shell `if` conditions:

```bash
if chump gap list --status open --quiet; then
  echo "Task store healthy"
fi
```

---

## Related Guides

- [CLI Exit Codes](CLI_EXIT_CODES.md)
- [User Guide](USER_GUIDE.md)
