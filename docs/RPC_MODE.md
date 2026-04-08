# RPC mode (stdin/stdout JSONL)

Chump supports a **headless RPC mode** intended for automation and autonomy drivers (cron, supervisors, other agents, IDE glue).

- **Input**: one JSON object per line on stdin (JSONL / NDJSON)
- **Output**: one JSON object per line on stdout (JSONL / NDJSON)
- **Events**: streamed as `AgentEvent` payloads (same shape as web SSE)

Run:

```bash
chump --rpc
```

## Protocol

On startup, the process prints:

```json
{"type":"rpc_ready","protocol":1}
```

### Commands (stdin)

#### `ping`

```json
{"type":"ping","id":"optional-correlation-id"}
```

Response:

```json
{"type":"pong","id":"optional-correlation-id"}
```

#### `prompt`

Starts one agent turn. The turn streams events until a `turn_complete` or `turn_error` event arrives.

```json
{"type":"prompt","message":"Your message","session_id":"default","bot":"chump","id":"req-1","max_iterations":10}
```

Notes:
- `session_id` defaults to `"default"`.
- `bot` can be `"chump"` or `"mabel"` (defaults to env behavior).
- Only **one active turn** is allowed per process; concurrent `prompt` commands will return an error.

#### `approve`

Resolves a pending tool approval request (when `CHUMP_TOOLS_ASK` includes the tool name).

```json
{"type":"approve","request_id":"<request_id>","allowed":true,"id":"req-1"}
```

Response:

```json
{"type":"ack","id":"req-1"}
```

### Output events

Every agent event is wrapped as:

```json
{"type":"event","event":{ "...AgentEvent..." },"id":"req-1"}
```

The `event` payload is the same `AgentEvent` enum used by the web SSE API (snake_case).

Common event types:
- `web_session_ready`
- `turn_start`
- `tool_call_start`
- `tool_approval_request`
- `tool_call_result`
- `text_complete`
- `turn_complete`
- `turn_error`

## Minimal example (bash)

```bash
printf '%s\n' \
  '{"type":"ping","id":"p1"}' \
  '{"type":"prompt","id":"t1","session_id":"default","message":"Say hi in 5 words"}' \
| chump --rpc
```

