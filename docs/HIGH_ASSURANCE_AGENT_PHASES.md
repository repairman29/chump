# High-Assurance Agent: Work Package Phases

Work packages (WPs) for hardening Chump's autonomous capabilities toward a high-assurance posture. Referenced throughout TOOL_APPROVAL.md, env_flags.rs, and the inference stack.

## Current posture

Chump ships a layered approval system today:
- **`CHUMP_TOOLS_ASK`** — human-in-the-loop gate before tool execution
- **`CHUMP_AIR_GAP_MODE`** — disable outbound internet tools at registration
- **`CHUMP_CLI_ALLOWLIST` / `CHUMP_CLI_BLOCKLIST`** — narrow `run_cli` to known-good commands
- **`CHUMP_AUTO_APPROVE_LOW_RISK`** — heuristic risk scoring on shell commands
- **Tool circuit breaker** — stops hammering a broken tool after N consecutive failures

This covers pilots and controlled lab use. The WPs below describe the roadmap toward stricter containment.

## WP-1: Approval surface completeness

**Goal:** Every client surface (PWA, Discord, CLI, RPC, Tauri) handles `tool_approval_request` and resolves via `POST /api/approve` with the same JSON contract.

**Shipped (P3.1):** PWA, Discord, ChumpMenu/Tauri, RPC all wired. Surface parity checklist in [TOOL_APPROVAL.md](TOOL_APPROVAL.md#surface-parity-checklist-p31).

**Remaining:** CLI one-shot path doesn't surface approvals when no tools are in the ask set (by design, but needs explicit audit if `run_cli` is added to ask set in headless mode).

## WP-2: Sandboxed shell execution

**Goal:** `run_cli` runs in a contained environment (SSH-jump or container) rather than directly on the host shell. Today `run_cli` has host-trust level — the allowlist reduces but does not eliminate risk.

**Current state:** Host shell only. Pilot recipe mitigates with tight `CHUMP_CLI_ALLOWLIST`.

**WP-2.3:** MCP "SandboxScan-class" scanner integration — Chump does not yet ship a generic MCP bridge for workspace scanners. Threat model and adoption gates: [rfcs/RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md).

## WP-3: Policy override API (shipped, P3.2–P3.3)

**Goal:** Time-boxed, session-scoped relaxation of the approval gate for trusted web sessions.

**Shipped:** `CHUMP_POLICY_OVERRIDE_API=1` enables `POST /api/policy-override` with `session_id`, `relax_tools`, `ttl_secs`. Applies only to PWA/Tauri web sessions. Discord/CLI/autonomy paths are unaffected. Every skipped approval still writes `tool_approval_audit` with result `policy_override_session`. TTL clamped 60s–7 days.

## WP-4: Audit and governance (shipped baseline)

**Goal:** Complete audit trail for every tool decision.

**Shipped:** `tool_approval_audit` events in `logs/chump.log`. Export via `GET /api/tool-approval-audit`. PWA Settings → Governance snapshot. See [TOOL_APPROVAL.md](TOOL_APPROVAL.md#audit-log).

## WP-5: Air-gap posture (shipped)

**Goal:** Fully disconnected operation with no outbound tool calls.

**Shipped:** `CHUMP_AIR_GAP_MODE=1` removes `web_search` and `read_url` at tool registration. `GET /api/stack-status` surfaces `air_gap_mode: true`. Startup config logs a warning if `TAVILY_API_KEY` is set while air-gap is on.

See [Defense Pilot Repro Kit](DEFENSE_PILOT_REPRO_KIT.md) for the full air-gapped setup checklist.

## WP-6: Cognitive budget tightening

**Goal:** Agent self-limits tool calls under high uncertainty.

**WP-6.1 (shipped):** `CHUMP_BELIEF_TOOL_BUDGET=1` — when belief state shows high task epistemic uncertainty, `precision_controller::recommended_max_tool_calls` tightens the per-turn tool budget. Documented in [METRICS.md](METRICS.md).

## WP-7: In-process inference isolation (mistral.rs)

**Goal:** Full in-process inference with no HTTP surface between agent and model.

**Current state:** `CHUMP_INFERENCE_BACKEND=mistralrs` with a Metal build bypasses the HTTP cascade entirely. This eliminates one network attack surface but requires the binary to be built with `--features mistralrs-infer` or `mistralrs-metal`.

See [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b for the full mistral.rs setup.

## Pilot recipe (combines WPs 1–6)

```bash
CHUMP_AIR_GAP_MODE=1               # WP-5
CHUMP_TOOLS_ASK=run_cli,write_file  # WP-1
CHUMP_CLI_ALLOWLIST=git,cargo,cat   # WP-2 partial mitigation
CHUMP_MAX_CONCURRENT_TURNS=1        # WP-4 audit clarity
CHUMP_BELIEF_TOOL_BUDGET=1          # WP-6.1
# WP-3 optional: CHUMP_POLICY_OVERRIDE_API=1 for time-boxed relax
```

Full setup: [DEFENSE_PILOT_REPRO_KIT.md](DEFENSE_PILOT_REPRO_KIT.md).

## See Also

- [Tool Approval](TOOL_APPROVAL.md)
- [Defense Pilot Repro Kit](DEFENSE_PILOT_REPRO_KIT.md)
- [Inference Profiles](INFERENCE_PROFILES.md)
- [Operations](OPERATIONS.md)
