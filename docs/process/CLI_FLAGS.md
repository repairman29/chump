# chump CLI flags reference

Global flags work with any subcommand. Subcommand-specific flags are documented
via `chump <command> --help`.

## Global flags

| Flag | Short | Description |
|---|---|---|
| `--version` | `-V` | Print `chump X.Y.Z (SHA built DATE)` and exit |
| `--verbose` | `-v` | Escalate `RUST_LOG` to `debug` (no-op if `RUST_LOG` already set) |
| `--debug` | — | Same as `--verbose` plus a startup header: version, args, timestamp |
| `--help` | `-h` | Print command reference and exit |
| `--briefing <GAP-ID>` | — | Emit gap context (MEM-007) for agent use before claim |
| `--desktop` | — | Launch the Tauri desktop app wrapper |
| `--web` | — | Start the PWA web server (default port 3000) |
| `--acp` | — | ACP stdio mode for Zed / JetBrains / VS Code |
| `--discord` | — | Discord gateway bot (requires `--features discord`) |
| `--telegram` | — | Telegram bot (requires `TELEGRAM_BOT_TOKEN`) |
| `--slack` | — | Slack Socket Mode bot (requires `SLACK_BOT_TOKEN`) |
| `--rpc` | — | Internal JSON-RPC loop (fleet workers) |
| `--preflight <GAP-ID>` | — | Run gap-preflight.sh and exit |
| `--plugins-list` | — | List discovered on-disk plugins and search paths |
| `--plugins-install <path>` | — | Copy a local plugin directory to `~/.chump/plugins/` |
| `--execute-gap <GAP-ID>` | — | Execute a gap as an autonomous agent |

## --verbose / --debug details

Both flags set `RUST_LOG=debug` before tracing is initialized, enabling
`tracing::debug!` events from all crates.

`--debug` additionally writes to stderr:

```
[debug] chump 1.2.3 (abc1234) started at 14:05:32.801
[debug] args: ["gap", "list", "--debug"]
```

To persist debug output to a file, combine with `CHUMP_TRACING_FILE`:

```bash
CHUMP_TRACING_FILE=1 chump --debug gap list
# → logs/tracing.jsonl in the runtime base directory
```

To get JSON-formatted debug output:

```bash
CHUMP_TRACING_JSON_STDERR=1 chump --verbose gap list
```
