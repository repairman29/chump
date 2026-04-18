# chump-mcp-adb

A standalone [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server exposing [Android Debug Bridge (ADB)](https://developer.android.com/tools/adb) operations over JSON-RPC stdio. Plug it into any MCP-aware agent (Claude Desktop, Zed, the [`chump`](https://github.com/repairman29/chump) agent, etc.) to give the model device control without writing a custom tool layer.

## Install

```bash
cargo install chump-mcp-adb
```

Requires `adb` on PATH (install via Android Studio or `brew install android-platform-tools`).

## Configure

Connect at least one device or emulator via USB / WiFi / `adb connect`. The server uses whatever `adb devices` reports.

In Claude Desktop / Zed:

```json
{
  "mcpServers": {
    "adb": {
      "command": "chump-mcp-adb"
    }
  }
}
```

## Tools provided

- `adb_devices` — list connected devices
- `adb_shell` — run a shell command on a device
- `adb_install` — install an APK
- `adb_logcat` — tail logcat with optional filter
- `adb_screenshot` — capture a PNG and return base64

(Full schema published via the standard MCP `tools/list` JSON-RPC method — the agent discovers them automatically.)

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo)

## License

MIT.

## Companion crates

- [`chump-mcp-github`](https://crates.io/crates/chump-mcp-github) — GitHub MCP server
- [`chump-mcp-tavily`](https://crates.io/crates/chump-mcp-tavily) — Tavily search MCP server
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — manage MCP server lifecycles inside an agent runtime
