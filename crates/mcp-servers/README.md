# Chump MCP Servers

Chump ships a collection of lightweight [Model Context Protocol](https://modelcontextprotocol.io/)
servers that expose Chump capabilities over JSON-RPC 2.0 on stdio.  All servers follow the
**MCP spec version 2025-11-05**.

Each server is a self-contained Rust binary.  Set `CHUMP_REPO` (or `CHUMP_HOME`) to the Chump
repository root before running any server that needs access to the repo filesystem.

---

## Servers

### `chump-mcp-eval`

Runs the Chump A/B eval harness and retrieves sweep results.  Demonstrates the **Sampling** and
**Elicitation** patterns introduced in MCP 2025-11-05 (see below).

| Tool | Description |
|---|---|
| `list_fixtures` | List fixture files in `scripts/ab-harness/fixtures/` |
| `run_ab_sweep` | Run a sweep via `run-cloud-v2.py` |
| `get_sweep_results` | Read `logs/ab-harness/<tag>/summary.json` |
| `run_ab_sweep_with_summary` | Run sweep then request a 2-sentence summary via **Sampling** |
| `run_destructive_sweep` | Confirm with the user via **Elicitation** before overwriting results |

**Requires:** `CHUMP_REPO`, Python 3, `run-cloud-v2.py` deps installed.

---

### `chump-mcp-gaps`

Queries the Chump gap registry (`docs/gaps.yaml`) and claims gaps.

| Tool | Description |
|---|---|
| `list_open_gaps` | List open gaps, optional `priority` filter (P1/P2/P3) |
| `get_gap` | Return full gap entry by ID |
| `claim_gap` | Run `scripts/coord/gap-claim.sh` to claim a gap |

**Requires:** `CHUMP_REPO`.

---

### `chump-mcp-coord`

Read-mostly **fleet coordination** for Cursor and other MCP clients: gap preflight, lease listing, musher pick, and ambient tail. Wraps the same shell entrypoints as `docs/process/AGENT_COORDINATION.md` (no `docs/gaps.yaml` status edits; no `.env` reads).

| Tool | Description |
|---|---|
| `gap_preflight` | Run `scripts/coord/gap-preflight.sh` for a list of gap IDs |
| `gap_claim_lease` | Run `scripts/coord/gap-claim.sh` (lease JSON under `CHUMP_LOCK_DIR` / `.chump-locks/`) |
| `lease_list_active` | Summarize active `*.json` lease files |
| `musher_pick` | Run `scripts/coord/musher.sh --pick` |
| `ambient_tail` | Last *N* lines of `ambient.jsonl` |

**Requires:** `CHUMP_REPO` (or `CHUMP_HOME`). Optional `CHUMP_LOCK_DIR` for isolated tests.

---

### `chump-mcp-github`

Wraps the `gh` CLI for common GitHub operations.

| Tool | Description |
|---|---|
| `gh_list_issues` | List issues for a repo, optional label/state filter |
| `gh_create_issue` | Create a new issue |
| `gh_list_prs` | List pull requests |
| `gh_get_pr` | Get PR details by number |

**Requires:** `gh` CLI authenticated.

---

### `chump-mcp-tavily`

Web search via the [Tavily](https://tavily.com/) API.

| Tool | Description |
|---|---|
| `search` | Perform a web search with depth, topic, and result-count controls |

**Requires:** `TAVILY_API_KEY`.

---

### `chump-mcp-adb`

Android Debug Bridge operations for device automation.

| Tool | Description |
|---|---|
| `adb_status` | Check device connection status |
| `adb_connect` | Connect to a device by IP:port |
| `adb_shell` | Run a shell command on the device |
| `adb_screencap` | Capture a screenshot |
| `adb_input` | Send tap/swipe/text input events |
| `adb_logcat` | Stream recent logcat output |

**Requires:** `adb` on PATH, `CHUMP_ADB_DEVICE=ip:port`.

---

## MCP 2025-11-05 patterns: Sampling and Elicitation

Two patterns added in the **2025-11-05 MCP specification** allow servers to reach *back* to the
client for reasoning or user confirmation mid-request.  `chump-mcp-eval` contains reference
implementations with TODO comments explaining each wire format.

### Sampling (`sampling/createMessage`)

An MCP server can ask the **calling agent** (the LLM) to perform a reasoning step and return
the result.  This is useful when the server has raw data (e.g. sweep results) but wants the
agent to synthesise a human-readable summary without the server embedding a second LLM call.

**Flow:**

```
Agent (client)                    chump-mcp-eval (server)
      |                                    |
      |--- tools/call run_ab_sweep_with_summary -->|
      |                            [runs sweep]    |
      |<-- sampling/createMessage -----------------|
      |    { messages: [{role:"user",              |
      |        content: "Summarise these results:  |
      |         ..."}], maxTokens: 256 }           |
      |                                            |
      |--- sampling response ---------------------->|
      |    { role:"assistant",                     |
      |      content: { text: "In this sweep..." } |
      |                                            |
      |<-- tools/call result ----------------------|
      |    { sweep_output: ..., agent_summary: ... }
```

**Example server → client request (JSON-RPC):**

```json
{
  "jsonrpc": "2.0",
  "id": "sampling-1",
  "method": "sampling/createMessage",
  "params": {
    "messages": [
      {
        "role": "user",
        "content": {
          "type": "text",
          "text": "The following is the output of an A/B eval sweep ... Please write exactly 2 sentences summarising the key finding."
        }
      }
    ],
    "maxTokens": 256
  }
}
```

**Example client → server response:**

```json
{
  "jsonrpc": "2.0",
  "id": "sampling-1",
  "result": {
    "role": "assistant",
    "content": {
      "type": "text",
      "text": "The COG-016 prompt variant outperformed baseline by 8 points on coherence. No significant delta was observed on task completion rate."
    }
  }
}
```

See `crates/mcp-servers/chump-mcp-eval/src/main.rs`, function `handle_run_ab_sweep_with_summary`
for the stub implementation and detailed TODO comment.

---

### Elicitation (`elicitation/create`)

An MCP server can pause mid-execution and ask the **human user** for a structured confirmation
or input before continuing a potentially destructive operation.  The client surfaces a UI prompt;
the server proceeds only on an `"accept"` response with the expected field values.

**Flow:**

```
User                Agent (client)              chump-mcp-eval (server)
 |                       |                              |
 |                       |--- tools/call run_destructive_sweep -->|
 |                       |                      [pre-flight OK]   |
 |                       |<-- elicitation/create ----------------|
 |<-- [UI prompt] -------|  { message: "This will overwrite...", |
 |                       |    requestedSchema: {                  |
 |                       |      confirmed: { type: "boolean" }    |
 |                       |    } }                                 |
 |--- [user clicks OK] ->|                                        |
 |                       |--- elicitation response -------------->|
 |                       |    { action: "accept",                 |
 |                       |      content: { confirmed: true } }    |
 |                       |                              [runs sweep]
 |                       |<-- tools/call result ------------------|
```

**Example server → client request (JSON-RPC):**

```json
{
  "jsonrpc": "2.0",
  "id": "elicitation-1",
  "method": "elicitation/create",
  "params": {
    "message": "This sweep will OVERWRITE all existing results in 'my-run-2026'. Fixture: fixtures/cog-016.json  Model: claude-sonnet-4-6. This cannot be undone. Do you want to proceed?",
    "requestedSchema": {
      "type": "object",
      "properties": {
        "confirmed": {
          "type": "boolean",
          "title": "Overwrite existing results?",
          "description": "Check to confirm overwriting all results in the output directory."
        }
      },
      "required": ["confirmed"]
    }
  }
}
```

**Example client → server response (user accepted):**

```json
{
  "jsonrpc": "2.0",
  "id": "elicitation-1",
  "result": {
    "action": "accept",
    "content": { "confirmed": true }
  }
}
```

**Example client → server response (user declined):**

```json
{
  "jsonrpc": "2.0",
  "id": "elicitation-1",
  "result": {
    "action": "decline"
  }
}
```

If `action` is `"decline"` or `"cancel"`, the server must abort without performing the
destructive operation.

See `crates/mcp-servers/chump-mcp-eval/src/main.rs`, function `handle_run_destructive_sweep`
for the stub implementation and detailed TODO comment.

---

## Running a server

```bash
# Build
cargo build --bin chump-mcp-eval

# Invoke (stdio transport — send one JSON-RPC request per line)
echo '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' \
  | CHUMP_REPO=/path/to/chump ./target/debug/chump-mcp-eval

echo '{"jsonrpc":"2.0","method":"list_fixtures","params":{},"id":2}' \
  | CHUMP_REPO=/path/to/chump ./target/debug/chump-mcp-eval
```

## Spec reference

These servers follow [MCP specification version **2025-11-05**](https://modelcontextprotocol.io/specification/2025-11-05/).
Sampling and Elicitation are defined in the `Client Features` section of that spec.
