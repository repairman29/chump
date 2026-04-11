# Defense / public-sector pilot — reproducibility kit

**Goal:** Give a sponsor or security reviewer a **minimal, repeatable** path from cold clone to a **human-in-the-loop** demo without implying cloud inference or multi-tenant SaaS.

**Not legal advice.** ATO/RMF language belongs in *your* SSP; Chump docs only describe technical behavior.

**Offline RMF-style Markdown shells** (placeholders for drafts, not an ATO package): [COMPLIANCE_TEMPLATES.md](COMPLIANCE_TEMPLATES.md).

---

## 1. Preconditions

- **Hardware:** Mac (Apple Silicon typical) or Linux host you control; optional Pixel + Termux for fleet demos ([ANDROID_COMPANION.md](ANDROID_COMPANION.md)).
- **Network:** For strict CUI posture, use **air-gapped** or **isolated VPC**; set `OPENAI_API_BASE` to **on-box** inference only (Ollama, vLLM-MLX, etc.).
- **Secrets:** Copy `.env.example` → `.env`; **do not** commit `.env`. Prefer no cloud keys for pilot, or document each external endpoint in the SSP.

---

## 2. Cold clone → build → web

```bash
git clone <your-fork-or-release> chump && cd chump
./scripts/setup-local.sh   # or follow SETUP_QUICK.md
cargo build --release
# Local model: e.g. ollama serve + pull per SETUP_QUICK.md
./run-local.sh --web       # or: cargo run --release -- --web
```

Open the PWA at the printed port (e.g. `http://127.0.0.1:3000`). If using `CHUMP_WEB_TOKEN`, configure the token in PWA settings.

---

## 3. Human-in-the-loop approvals

High-risk tools can require explicit approval:

- Env: **`CHUMP_TOOLS_ASK`** (comma-separated tool names), e.g. `run_cli,write_file`.
- UX: PWA chat streams **`ToolApprovalRequest`**; user **Allow / Deny** (see [TOOL_APPROVAL.md](TOOL_APPROVAL.md), [OPERATIONS.md](OPERATIONS.md)).

Demo script: intentionally trigger a flagged `run_cli` and show deny/allow audit in `logs/chump.log` (`tool_approval_audit`).

**Sponsor-safe defaults (governance):** For public demos and sponsor machines, treat **approval as the default** for shell-capable tools:

| Setting | Pilot recommendation |
|---------|-------------------------|
| **`CHUMP_TOOLS_ASK`** | Include at least **`run_cli`** (and any other tools you do not want silent execution for), e.g. `run_cli,write_file`. |
| **`CHUMP_AUTO_APPROVE_LOW_RISK`** | **Unset or `0`** — do not auto-allow `run_cli` during a pilot. |
| **`CHUMP_AUTO_APPROVE_TOOLS`** | **Unset** — no blanket auto-approve list for demos. |

Optional autonomy helpers belong in **lab** profiles only; document any deviation in your SSP or runbook. See [TOOL_APPROVAL.md](TOOL_APPROVAL.md) (Pilot / sponsor demos).

### Air-gap tool posture (CHUMP_AIR_GAP_MODE)

Set **`CHUMP_AIR_GAP_MODE=1`** in `.env` so the agent does **not** register **`web_search`** or **`read_url`** (no outbound general-Internet search/fetch tools at the orchestrator layer). This does **not** sandbox **`run_cli`**—keep **`CHUMP_TOOLS_ASK`** and allowlists aligned with your trust story ([TOOL_APPROVAL.md](TOOL_APPROVAL.md)). Inventory and rationale: [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) §18.

### Trust ladder and pilot allowlist (WP-2.2)

Read the full table in [TOOL_APPROVAL.md](TOOL_APPROVAL.md) (**Trust ladder**). For a **Mac pilot demo**, treat **`run_cli` as host shell**, not WASM: set a **narrow** **`CHUMP_CLI_ALLOWLIST`** of prefixes you are willing to explain (examples only—tune to your repo):

```bash
# Example: dev demo on trusted laptop (adjust/remove tools you do not need)
CHUMP_CLI_ALLOWLIST=cargo,git,rg,pytest,python3,npm,node,curl,agent
```

Pair with **`CHUMP_TOOLS_ASK=run_cli,write_file`** (or your full sensitive list) so sponsors see Allow/Deny. **`CHUMP_EXECUTIVE_MODE`** should stay **off** during the demo.

---

## 4. Pilot metrics export (N3/N4)

```bash
./scripts/export-pilot-summary.sh
# or: curl -sS http://127.0.0.1:<port>/api/pilot-summary
```

Recipes over SQLite: [WEDGE_PILOT_METRICS.md](WEDGE_PILOT_METRICS.md).

---

## 5. Trust boundaries (say out loud in demo)

- **Speculative rollback** restores **in-process** state only — not disk, Git remotes, Discord, or third-party APIs ([TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md)).
- **`run_cli`** is **host shell** — **not** “sandboxed shell.” WASM tools (`wasm_calc`, `wasm_text`, etc.) are a **separate, smaller** trust tier ([TOOL_APPROVAL.md](TOOL_APPROVAL.md) trust ladder). Stricter runners (container / SSH-jump) are future work.
- **MCP security / repo scanners:** Do not assume an MCP-attached “sandbox scanner” inherits Chump’s registration-time air-gap or audit story. See [RFC-wp23-mcp-sandboxscan-class.md](rfcs/RFC-wp23-mcp-sandboxscan-class.md).

---

## 6. Federal pipeline (business motion)

Opportunity rhythm and Colorado/ecosystem context: [FEDERAL_OPPORTUNITIES_PIPELINE.md](FEDERAL_OPPORTUNITIES_PIPELINE.md).  
Execution checklist: [DEFENSE_PILOT_EXECUTION.md](DEFENSE_PILOT_EXECUTION.md).

---

## 7. Alignment reference

Strategic doc vs implementation: [EXTERNAL_PLAN_ALIGNMENT.md](EXTERNAL_PLAN_ALIGNMENT.md).

**Air-gap:** **`CHUMP_AIR_GAP_MODE`** is implemented (WP-4.1); outbound-tool list and extensions live in [HIGH_ASSURANCE_AGENT_PHASES.md](HIGH_ASSURANCE_AGENT_PHASES.md) **§18**. Pair with **`CHUMP_TOOLS_ASK`** / allowlists for **`run_cli`** per the trust ladder (**WP-2.2**).
