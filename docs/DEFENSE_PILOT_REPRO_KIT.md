---
doc_tag: runbook
owner_gap:
last_audited: 2026-04-25
---

# Defense Pilot Reproduction Kit

Checklist and configuration reference for running Chump in a high-assurance / air-gapped posture suitable for defense or enterprise pilots. Designed to be reproducible without internet access after initial setup.

## Pilot posture summary

| Layer | Setting | Why |
|-------|---------|-----|
| Internet tools | `CHUMP_AIR_GAP_MODE=1` | Disables `web_search` and `read_url` at registration |
| Shell access | `CHUMP_CLI_ALLOWLIST=git,cargo,cat,ls,grep` (example) | Narrows `run_cli` to a known-good command set |
| Human gate | `CHUMP_TOOLS_ASK=run_cli,write_file` | All file writes and shell calls require explicit Allow/Deny |
| Concurrency | `CHUMP_MAX_CONCURRENT_TURNS=1` | One turn at a time — predictable audit trail |
| Auto-approve | `CHUMP_AUTO_APPROVE_LOW_RISK=` (unset) | No automatic approvals; everything goes through the gate |
| Executive mode | `CHUMP_EXECUTIVE_MODE=` (unset) | Normal allowlist/blocklist enforcement |
| Inference | Local vLLM-MLX or Ollama only | No cloud API calls during demo |

## Step-by-step repro

### 1. Pre-demo setup (do this the day before)

```bash
# Pull model weights while you still have internet
./scripts/restart-vllm-if-down.sh          # starts serve-vllm-mlx.sh, downloads 14B if needed
./scripts/wait-for-vllm.sh                 # waits until /v1/models returns 200

# Verify offline capability
curl -s http://127.0.0.1:8000/v1/models    # should return model list without network
```

### 2. .env for pilot session

```bash
# Inference — local only
OPENAI_API_BASE=http://127.0.0.1:8000/v1
OPENAI_API_KEY=not-needed
OPENAI_MODEL=mlx-community/Qwen2.5-14B-Instruct-4bit

# Air-gap — disable outbound tools
CHUMP_AIR_GAP_MODE=1

# Human gate on sensitive tools
CHUMP_TOOLS_ASK=run_cli,write_file,task

# Narrow shell allowlist
CHUMP_CLI_ALLOWLIST=git,cargo,cat,ls,grep,find,echo

# Concurrency
CHUMP_MAX_CONCURRENT_TURNS=1

# No cloud fallback during pilot
CHUMP_CASCADE_ENABLED=0
```

### 3. Start Chump

```bash
./run-web.sh       # or ./run-discord.sh for Discord surface
./scripts/chump-preflight.sh
```

Verify `GET /api/stack-status` shows:
- `air_gap_mode: true`
- `tool_policy.tools_ask` contains your listed tools
- `inference.models_reachable: true`

### 4. Smoke test the approval flow

1. Open the PWA or Discord
2. Ask Chump to run a harmless shell command: `"run ls in the repo root"`
3. An approval card should appear — click **Allow once**
4. Confirm the command ran and the result is shown
5. Check `logs/chump.log` for the `tool_approval_audit` entry

### 5. Air-gap confirmation

With `CHUMP_AIR_GAP_MODE=1`, the `web_search` and `read_url` tools are **not registered**. Asking Chump to search the web should produce a "tool not available" response, not a network call.

Verify: `GET /api/stack-status` → `registered_tools` should not contain `web_search`.

## Trust tier reference

See [TOOL_APPROVAL.md](TOOL_APPROVAL.md#trust-ladder-wasm-vs-native-tools-vs-host-shell) for the full trust ladder. For pilots, the recommended posture is:
- Tier 4: tight `CHUMP_CLI_ALLOWLIST`
- Tier 5: `CHUMP_TOOLS_ASK` includes `run_cli`
- Tier 3 off: `CHUMP_AIR_GAP_MODE=1`
- Tier 6 off: `CHUMP_EXECUTIVE_MODE` unset

## Audit trail

Every approval decision is logged to `logs/chump.log` with event `tool_approval_audit`:
- timestamp, tool name, args preview, risk level, result (`allowed` / `denied` / `timeout`)

Export via `GET /api/tool-approval-audit?limit=50&format=csv` for after-action review.

## Known limitations

- `run_cli` is **host shell**, not sandboxed. The allowlist reduces but does not eliminate risk — a sponsor with the Allow button can still run any allowlisted command.
- Air-gap mode does not block LLM API calls to `OPENAI_API_BASE` — it only removes the web browsing tools. If you need to air-gap the model API too, use a locally-served model with no internet.
- Containerized `run_cli` (SSH-jump profile) is a roadmap item, not yet shipped. See [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md).

## See Also

- [Tool Approval](TOOL_APPROVAL.md)
- [Operations](OPERATIONS.md) — Air-gap mode section
- [High-Assurance Agent Phases](HIGH_ASSURANCE_AGENT_PHASES.md)
- [Inference Stability](INFERENCE_STABILITY.md)
