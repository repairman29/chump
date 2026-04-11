# Tool approval (CHUMP_TOOLS_ASK)

When **CHUMP_TOOLS_ASK** is set, listed tools require explicit user approval before execution. The agent emits a request (tool name, risk level, reason), waits for Allow or Deny (or timeout), then continues.

## Trust ladder (WASM vs native tools vs host shell)

**Say this clearly in pilots:** `run_cli` is **not** sandboxed like WASM. Shell access is **host-trust**—the same privileges as the user running Chump. Approvals, allowlists, and air-gap flags **reduce risk** but do not turn the shell into a WASI guest.

| Tier | Examples | What the operator is trusting |
|------|----------|-------------------------------|
| **1 — Bounded WASM** | `wasm_calc`, `wasm_text` (when wasmtime + matching `.wasm` present) | Only each module’s stdin/stdout contract; **no** host FS/network passed by default ([WASM_TOOLS.md](WASM_TOOLS.md)). |
| **2 — Native “bounded” tools** | `read_file`, `calculator`, `task`, `memory_brain`, … | Chump code paths + your repo/brain layout; still full process, not a sandbox VM. |
| **3 — Network / outbound (orchestrator)** | `web_search`, `read_url` (unless **`CHUMP_AIR_GAP_MODE=1`**) | General Internet or arbitrary URLs; disable at registration in air-gap mode ([DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md)). |
| **4 — Host shell** | `run_cli` (and `git` / `cargo` aliases) | **Full shell** on the host: read/write anywhere the user can, invoke installers, push remotes, etc. Use **`CHUMP_CLI_ALLOWLIST`** / **`CHUMP_CLI_BLOCKLIST`** to narrow commands (companion/Mabel **requires** a sensible allowlist on device; empty allowlist = any command). |
| **5 — Human gate** | **`CHUMP_TOOLS_ASK`** | User must Allow/Deny before execution; audit in **`tool_approval_audit`**. |
| **6 — Lab / executive** | **`CHUMP_EXECUTIVE_MODE=1`** | Most permissive `run_cli` profile (longer timeout, larger cap, no allowlist/blocklist enforcement in that path—see `.env.example`). **Not** for sponsor demos. |

**Pilot recipe:** Combine tier **4** (tight **`CHUMP_CLI_ALLOWLIST`**) + tier **5** (**`CHUMP_TOOLS_ASK`** includes `run_cli`) + optional tier **3** off (**`CHUMP_AIR_GAP_MODE`**) + tier **6** **off**.

**Future — MCP “SandboxScan-class” scanners:** Chump does **not** ship a generic MCP bridge for workspace scanners or dynamic tool discovery. Threat model and adoption gates: [RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md) (**WP-2.3**).

## Configuration

- **CHUMP_TOOLS_ASK** — Comma-separated tool names, e.g. `run_cli`, `write_file`. Empty/unset = no approval.
- **CHUMP_APPROVAL_TIMEOUT_SECS** — Seconds to wait (default 60, min 5, max 600). After timeout the tool is treated as denied.

## Heuristic risk (no LLM)

For `run_cli`, risk is computed from the command string. Patterns that raise risk include: `rm -rf /`, `sudo`, `chmod 777`, `DROP TABLE`, credential-like args, writing to block devices. Levels: low, medium, high. For other tools (e.g. write_file) a generic "tool requires approval" reason is used. Risk is shown in the approval UI and written to the audit log.

## Approval UX

- **Discord:** Bot sends a message with "Allow once" and "Deny" buttons. Click to resolve.
- **Web/PWA:** Approval card in chat or POST `/api/approve` with `{"request_id": "<uuid>", "allowed": true|false}`.
- **ChumpMenu:** **Chat** tab uses the same web stack: streams SSE from `POST /api/chat` and resolves approvals via `POST /api/approve` (same contract as the PWA). See [ARCHITECTURE.md](ARCHITECTURE.md).

## Pilot / sponsor demos

For **defense / enterprise pilots**, keep **human-in-the-loop** visible: set **`CHUMP_TOOLS_ASK`** so `run_cli` (and other sensitive tools) require explicit Allow/Deny in the PWA or Discord. Leave **`CHUMP_AUTO_APPROVE_LOW_RISK`** and **`CHUMP_AUTO_APPROVE_TOOLS`** off unless you intentionally run a hands-off lab profile and accept the risk.

Repro checklist: [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md). Every decision still lands in **`tool_approval_audit`** in `logs/chump.log` for after-action review.

**Future hardening (not required for doc-only pilots):** containerized or SSH-jump **`run_cli`** profiles are a follow-up; today **`run_cli`** is host shell unless you replace the runner.

## Audit log

Every decision is logged to **logs/chump.log** with event `tool_approval_audit`: timestamp, tool name, args preview, risk level, result (`allowed` | `denied` | `timeout`). With `CHUMP_LOG_STRUCTURED=1` each line is JSON. No PII; secrets are redacted per existing policy.
