# Tool approval (CHUMP_TOOLS_ASK)

When **CHUMP_TOOLS_ASK** is set, listed tools require explicit user approval before execution. The agent emits a request (tool name, risk level, reason), waits for Allow or Deny (or timeout), then continues.

## Configuration

- **CHUMP_TOOLS_ASK** — Comma-separated tool names, e.g. `run_cli`, `write_file`. Empty/unset = no approval.
- **CHUMP_APPROVAL_TIMEOUT_SECS** — Seconds to wait (default 60, min 5, max 600). After timeout the tool is treated as denied.

## Heuristic risk (no LLM)

For `run_cli`, risk is computed from the command string. Patterns that raise risk include: `rm -rf /`, `sudo`, `chmod 777`, `DROP TABLE`, credential-like args, writing to block devices. Levels: low, medium, high. For other tools (e.g. write_file) a generic "tool requires approval" reason is used. Risk is shown in the approval UI and written to the audit log.

## Approval UX

- **Discord:** Bot sends a message with "Allow once" and "Deny" buttons. Click to resolve.
- **Web/PWA:** Approval card in chat or POST `/api/approve` with `{"request_id": "<uuid>", "allowed": true|false}`.
- **ChumpMenu:** **Chat** tab uses the same web stack: streams SSE from `POST /api/chat` and resolves approvals via `POST /api/approve` (same contract as the PWA). See [ARCHITECTURE.md](ARCHITECTURE.md).

## Audit log

Every decision is logged to **logs/chump.log** with event `tool_approval_audit`: timestamp, tool name, args preview, risk level, result (`allowed` | `denied` | `timeout`). With `CHUMP_LOG_STRUCTURED=1` each line is JSON. No PII; secrets are redacted per existing policy.
