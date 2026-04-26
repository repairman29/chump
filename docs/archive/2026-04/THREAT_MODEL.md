# Chump Threat Model (COMP-012)

> **MAESTRO-structured threat model for Chump as an agentic-AI system.**
> Last updated: 2026-04-19. Authored by COMP-012.

MAESTRO (Machine Learning, Agentic Execution, Safeguards, Threats, Risks, and Operations) is a
threat-modeling framework specifically designed for agentic AI systems. It organises analysis
around the seven layers most relevant to autonomous agents: Model, Application, Storage,
Transport, Runtime, Orchestration, and Operations. This document applies MAESTRO to Chump's
actual implementation, citing real source files and scripts rather than generic guidance.

---

## 1. System Description

### What Chump is

Chump is a **multi-agent AI orchestrator** written in Rust. An orchestrator process
(`src/main.rs`, `src/agent_loop/orchestrator.rs`) drives one or more language models through a
multi-turn tool-use loop. Optional delegate workers (`src/delegate_tool.rs`) run on the same
or a smaller model for sub-tasks (summarise, extract, classify, validate). A cognitive
architecture overlay — belief state, surprisal EMA, neuromodulation hints, a reflection flywheel
— lives in `src/belief_state.rs`, `src/surprise_tracker.rs`, `src/neuromodulation.rs`,
`src/reflection_db.rs` — and is injected into prompts at assembly time
(`src/agent_loop/prompt_assembler.rs`).

**Deployment surface:** single local process on macOS/Linux, talking to an LLM API (Anthropic
Claude, or a locally-run model via Ollama/mistral.rs). Optionally exposes a web API on
`localhost:CHUMP_WEB_PORT`, a Discord bot, and three first-party MCP servers
(`crates/mcp-servers/`). A fleet mode (`src/fleet.rs`) allows multiple Chump instances to
coordinate across a local network.

**Multi-agent coordination:** concurrent agents share a git repo. Coordination happens through
file-system lease files in `.chump-locks/` (`src/agent_lease.rs`), an ambient event stream
(`.chump-locks/ambient.jsonl`), and pre-commit hooks (`scripts/git-hooks/pre-commit`).

### Trust Boundaries

```
┌────────────────────────────────────────────────────────────┐
│  TRUST ZONE: Operator (local machine, host user process)   │
│                                                            │
│  ┌──────────┐  stdio  ┌──────────────────────────────────┐ │
│  │  Claude  │◄───────►│  Chump orchestrator process      │ │
│  │  (LLM)   │         │  - tool_middleware.rs             │ │
│  │          │         │  - adversary.rs (COMP-011a)       │ │
│  └──────────┘         │  - context_firewall.rs            │ │
│                        │  - tool_policy.rs                │ │
│  ┌──────────┐         │  - approval_resolver.rs           │ │
│  │ Delegate │◄───────►│                                   │ │
│  │  worker  │  stdio  └──────────────────────────────────┘ │
│  └──────────┘                         │                     │
│                              Host shell (run_cli)           │
│                              File system (write_file)       │
│                              Git history (git_tools)        │
└────────────────────────────────────────────────────────────┘
             │
             │  HTTPS / TLS (LLM API calls only)
             ▼
     ┌─────────────────┐
     │ LLM API provider │
     │ (Anthropic, etc) │
     └─────────────────┘

     ┌─────────────────┐
     │ MCP servers      │  stdin/stdout pipes — no TCP socket
     │ chump-mcp-adb    │  (structurally immune to DNS rebinding;
     │ chump-mcp-github │   see docs/audits/SECURITY_MCP_AUDIT.md)
     │ chump-mcp-tavily │
     └─────────────────┘
```

**Key trust boundary facts:**
- The LLM runs *outside* the process boundary; its output is untrusted text that the orchestrator
  parses and routes to tools.
- `run_cli` executes on the **host shell** with full user privileges — it is NOT sandboxed by
  default (`docs/operations/TOOL_APPROVAL.md` trust ladder tier 4).
- MCP servers are child processes communicating via stdio pipes; no exposed TCP ports
  (`docs/audits/SECURITY_MCP_AUDIT.md`).
- The web API (`CHUMP_WEB_PORT`) binds on localhost; cross-origin requests require
  `CHUMP_WEB_TOKEN` when configured.

### Data Flows

| Flow | Path | Sensitivity |
|---|---|---|
| User message → LLM | `src/agent_loop/orchestrator.rs` → provider API | Medium — may contain user PII |
| LLM response → tool calls | `src/agent_loop/tool_runner.rs` → `tool_middleware.rs` | High — tool inputs are LLM-generated |
| Tool output → LLM | `run_cli` stdout, `read_file` content, etc. | Varies — may contain secrets |
| Orchestrator → delegate | `src/delegate_tool.rs` → `src/context_firewall.rs` | High — firewall must strip secrets |
| Memory reads/writes | `src/memory_db.rs`, `src/memory_brain_tool.rs` → SQLite | Medium — persisted user context |
| Reflection writes | `src/reflection_db.rs` → `sessions/chump_memory.db` | Internal — eval data, improvement targets |
| MCP bridge | `src/mcp_bridge.rs` → child process stdio | Depends on MCP server (GitHub token, Tavily key) |
| Ambient events | `.chump-locks/ambient.jsonl` | Internal — session IDs, file paths, bash commands |

---

## 2. Threats Chump Mitigates

### 2.1 Prompt Injection

**Threat:** Adversarial content embedded in tool outputs, web pages, files, or user messages
attempts to hijack the agent's tool-use behaviour — e.g., a file contains instructions to
exfiltrate the API key or delete files.

**Chump's mitigations:**

**Adversary rule engine (`src/adversary.rs`, COMP-011a):** When `CHUMP_ADVERSARY_ENABLED=1`, every
tool call is checked against rules in `chump-adversary.yaml` before execution. Rules match on
tool name and input field contents; `action: block` causes the orchestrator to return an error
instead of executing the tool. Alerts are written to `.chump-locks/ambient.jsonl` as
`kind=adversary_alert` events so concurrent sessions can see them. Default is OFF — operators
opt in by setting `CHUMP_ADVERSARY_ENABLED=1` and authoring a `chump-adversary.yaml` ruleset.
The engine is a thin rule-based filter; it does not perform semantic analysis and can be evaded
by paraphrasing.

**Context firewall (`src/context_firewall.rs`):** Before any orchestrator-to-delegate delegation,
text is passed through a sanitiser that (a) redacts known-secret patterns (API keys with `sk-`/
`ghp_`/`AKIA` prefixes, Bearer tokens, JWTs, PEM private keys, config-style `password=` / 
`secret=` fields) and (b) truncates payloads above 32,000 characters with a `[…truncated by
context firewall]` marker. This prevents secrets captured from tool output from being forwarded
to worker models. Wired into `src/delegate_tool.rs` as the single gate before any worker call.

**Lease collision detection (`src/agent_lease.rs`, pre-commit hook):** Multi-agent
coordination via `.chump-locks/` lease files and the pre-commit hook
(`scripts/git-hooks/pre-commit` job 1) prevents one agent from silently overwriting another's
files. While this is primarily a coordination control, it also detects scenarios where an
injected command attempts to modify files claimed by a different session.

**Perception layer risk classification (`src/agent_loop/perception_layer.rs`,
`src/perception.rs`):** The perception layer classifies incoming prompts for risk indicators
including "destructive ops", "auth", and "external calls" before the main model call. Risk
indicators feed into tool approval heuristics. This is an informational layer — it does not
block execution but raises the heuristic risk score that operators see in approval UIs.

**Limitations:** Chump does not apply a semantic prompt-injection detector. Content arriving
via `read_url`, web search results, or file reads is forwarded to the model with minimal
sanitisation beyond the context firewall's secret redaction. A well-crafted injection in a
fetched document can influence the LLM's planned tool calls. Adversary mode helps for specific
known-bad patterns but requires operator-authored rules.

---

### 2.2 Data Poisoning

**Threat:** Adversarial data injected into memory, reflection, or the eval ground-truth corpus
causes the agent to learn incorrect behaviours or produce falsified research findings.

**Chump's mitigations:**

**Reflection DB validation (`src/reflection_db.rs`):** Reflection records are written by the
autonomy loop only after task completion. The schema enforces typed fields (`outcome_class`,
`priority`, `error_pattern`). Improvement targets are loaded into prompts via a priority+recency
ranking that disfavours sudden outliers. There is no open write-API for external data to inject
reflection records directly; the write path requires an authenticated session with DB access.

**Human-labeled ground truth requirement (`docs/process/RESEARCH_INTEGRITY.md`):** The Research
Integrity Directive requires that for any eval fixture where hallucination is the measured
outcome, the detection regex must be validated against ≥20 human-labeled examples before
results are cited. This prevents automated processes from poisoning the ground-truth corpus by
relabelling fixtures. The directive also prohibits citing results from Anthropic-only judge
panels (single-provider bias) and requires cross-family judge validation.

**Eval harness isolation (`src/eval_harness.rs`):** Eval cases and results are stored in
separate DB tables (`chump_eval_cases`, `chump_eval_runs`) with property-based checking. The
harness uses `INFRA-EXPERIMENT-CHECKPOINT` to log the exact harness call, making fabricated
results traceable.

**Task-class-aware lessons gating (EVAL-030):** The prompt assembler inspects incoming prompts
and suppresses the lessons block on trivial or short prompts (< 30 chars) and conditional-chain
prompts, reducing the blast radius of a poisoned improvement target reaching the model. Controlled
by `CHUMP_LESSONS_TASK_AWARE` (default ON).

**Limitations:** Memory entries written via `memory_store` tool calls are not verified for
accuracy before persistence. A sufficiently persuasive injected narrative could instruct the
agent to write false facts into memory, which would then propagate to future sessions via memory
recall. The `confidence` and `verified` fields on memory entries (`src/memory_db.rs`) exist but
are not currently enforced as a gate on recall.

---

### 2.3 Unauthorized Tool Use

**Threat:** The LLM calls a tool it should not call, or calls a permitted tool with dangerous
arguments.

**Chump's mitigations:**

**Tool approval list (`src/tool_policy.rs`, `CHUMP_TOOLS_ASK`):** Operators configure a
comma-separated list of tool names in `CHUMP_TOOLS_ASK`. When the agent is about to execute a
listed tool, it emits a `ToolApprovalRequest` event and blocks until a human resolves it via
Discord button, web UI card, or `POST /api/approve`. Resolutions are routed via
`src/approval_resolver.rs`. Timeout (default 60 s, configurable via
`CHUMP_APPROVAL_TIMEOUT_SECS`) defaults to deny. All decisions are written to
`tool_approval_audit` in `logs/chump.log`.

**CLI allowlist/blocklist (`src/cli_tool.rs`, `CHUMP_CLI_ALLOWLIST` / `CHUMP_CLI_BLOCKLIST`):**
The `run_cli` tool checks the command's first token against an operator-configured allowlist
(allow-only-listed) and blocklist (always-deny-listed). An empty allowlist allows any command;
a non-empty allowlist restricts to exactly those commands. `CHUMP_EXECUTIVE_MODE=1` disables
both for lab/self-improve profiles and is explicitly documented as inappropriate for
sponsor demos.

**Heuristic risk scoring (`src/cli_tool.rs::heuristic_risk`):** Every `run_cli` call is
classified as Low/Medium/High before execution. High triggers include `rm -rf /`, `sudo`,
`DROP TABLE`, `mkfs.`, `dd if=`, writes to `/dev/sd*`. Medium triggers include `rm -rf` (on
non-root paths), `chmod 777`, credential-like args. Risk level is surfaced in the approval UI
and written to the audit log.

**Static tool risk tiers (`src/tool_policy.rs::classify_tool_risk`):** Non-CLI tools are
classified by name: read-only tools are Low, reversible writes are Medium, destructive/network
tools are High. `CHUMP_AUTO_APPROVE_LOW_RISK=1` lets operators skip human approval for Low-tier
tools without loosening the policy for High-tier ones.

**Air-gap mode (`CHUMP_AIR_GAP_MODE=1`):** Disables network tools (`web_search`, `read_url`)
at registration time. Used in air-gapped pilot environments to prevent data exfiltration via
outbound HTTP.

**WASM sandboxed tools (`src/wasm_calc_tool.rs`, `src/wasm_text_tool.rs`):** Calculation and
text-processing operations run inside a wasmtime interpreter with no host filesystem or network
access by default. This is the only truly sandboxed execution tier.

**ACP permission gate (`src/acp_server.rs`):** When Chump runs under an ACP-capable editor
(Zed, JetBrains), write tools route through `acp_permission_gate(name, input)` before
execution, prompting the editor user interactively. Sticky `AllowAlways` decisions are cached
on the session entry.

---

### 2.4 Multi-Step Bypass (Orchestration-Layer Attacks)

**Threat:** A multi-turn sequence of individually-acceptable tool calls accumulates into an
overall harmful effect (e.g., read secrets, then encode them, then exfiltrate in a web request).
Also includes agent-coordination attacks: a rogue concurrent session modifies shared files
before a legitimate session commits.

**Chump's mitigations:**

**Pre-commit guards (`scripts/git-hooks/pre-commit`):** Six coordinated checks at every commit:
1. **Lease-collision guard** — refuses to commit a file claimed by a different live session,
   preventing cross-agent stomps.
2. **Stomp-warning** — non-blocking advisory when staged files have mtime older than 600 s,
   catching stale staging from other agents.
3. **gaps.yaml discipline** — rejects adds of `status: in_progress` / `claimed_by:` /
   `claimed_at:` to the gap registry, keeping claim state in `.chump-locks/` lease files where
   it can expire rather than persisting silently in git history.
4. **Gap-ID hijack guard** — rejects commits that change an existing gap's `title:` or
   `description:`, preventing silent ID reuse.
5. **Cargo-fmt auto-fix** — auto-formats and re-stages Rust files to prevent CI thrash.
6. **Cargo-check build guard** — refuses broken-compile commits.

**Gap-preflight check (`scripts/coord/gap-preflight.sh`):** Mandatory pre-work check that verifies a
gap is open and unclaimed before any agent writes code. Reads local lease files instantly (no
network) and exits 1 if the gap is done or live-claimed, preventing duplicate work.

**Speculative execution rollback (`src/speculative_execution.rs`):** Speculative tool branches
can be forked and rolled back. `CHUMP_SANDBOX_SPECULATION=1` routes sandboxable tools through
a worktree-isolation path so rollback can discard FS side-effects. Network/notification tools
(`git_push`, `notify`, `schedule`) are classified `never` — they are counted as speculation
leaks but cannot be reversed.

**Autonomy FSM (`src/autonomy_fsm.rs`, `src/autonomy_loop.rs`):** The autonomous execution
path uses a state machine with kill-switch support (`logs/pause`, `CHUMP_PAUSED=1`). Session
heartbeat checks prevent silent-agent loss (see INFRA-HEARTBEAT-WATCHER).

**Rate limits and concurrency caps:** `CHUMP_MAX_TOOL_IN_FLIGHT` (global concurrency cap),
per-tool sliding-window rate limits (`CHUMP_TOOL_RATE_LIMIT_*`), and per-tool circuit breakers
(trip after N consecutive failures, configurable via `CHUMP_TOOL_CIRCUIT_FAILURES`) limit the
rate at which a rogue model can perform side-effecting operations.

---

## 3. Threats Chump Does Not Mitigate (with Proposed Controls)

### 3.1 Supply Chain: Cargo Dependency Compromise

**Threat:** A dependency in `Cargo.lock` is compromised (typosquatted crate, maintainer
account takeover, malicious patch). Malicious code runs with full host-user privileges at
compile or runtime.

**Current state:** Chump does not run `cargo audit` in CI and has no `deny.toml` (cargo-deny
configuration). The pre-commit hook does not check for new dependencies. As of 2026-04-19,
no CVE scanner is integrated.

**Proposed user-side controls:**
- Add `cargo audit` to the CI workflow (`.github/workflows/`). Free via the
  [RustSec Advisory Database](https://rustsec.org/).
- Add `cargo deny check` with a `deny.toml` banning disallowed licenses and flagging yanked
  crates.
- Pin all dependencies to exact versions in `Cargo.lock` (already done — Cargo locks
  transitively) and add a policy against `cargo update` without a paired audit.
- For the MCP servers (`crates/mcp-servers/`), which are minimal and hand-rolled, the
  dependency surface is small (`serde`, `serde_json`, `tokio`, `anyhow`, `reqwest`). Audit
  these separately; they run as child processes but share the same user account.

---

### 3.2 Model-Level Jailbreaks

**Threat:** An adversary crafts a prompt that causes the underlying LLM to ignore system-prompt
constraints, execute arbitrary instructions, or reveal confidential system prompt contents.

**Current state:** Chump's controls (adversary mode, tool approval lists) operate at the
**orchestrator layer** — after the LLM has generated its response. If the LLM is jailbroken
into generating a harmful tool call, Chump's tool-level controls still apply (allowlist,
blocklist, adversary rules, approval gate). However, Chump has no mechanism to prevent the
model from generating a response that bypasses its own safety training.

**This is out of scope for Chump** — it is the model provider's responsibility to maintain
model-level alignment. Chump's posture is defence-in-depth: assume the model can be manipulated
and apply orchestrator-layer controls that remain independent of model behaviour.

**Proposed user-side controls:**
- Set `CHUMP_TOOLS_ASK=run_cli,write_file,git_push` (any destructive tools) so a jailbroken
  model still requires human approval before side effects land.
- Set `CHUMP_CLI_ALLOWLIST` to the minimal set of commands the use-case requires.
- Enable `CHUMP_ADVERSARY_ENABLED=1` with rules that block high-risk command patterns,
  providing a last-resort catch even if the approval step is bypassed by a model that
  generates a plausible "already approved" narrative.

---

### 3.3 Exfiltration via MCP (No Auth Layer)

**Threat:** The three first-party MCP servers (`chump-mcp-adb`, `chump-mcp-github`,
`chump-mcp-tavily`) have no authentication token on the stdio pipe. Any process that can
write to a server's stdin can invoke its tools. In the standard deployment this is the Chump
process (legitimate), but on a multi-user machine or a machine where a compromised process
inherits the file descriptor, an attacker can invoke MCP tools without the Chump orchestrator's
knowledge.

**Current state:** As documented in `docs/audits/SECURITY_MCP_AUDIT.md` (COMP-013), all three servers
use stdio transport exclusively — there is no TCP port to attack via DNS rebinding or port
scanning. The trust boundary is the parent-child pipe relationship. The servers do not validate
a bearer token because the original design assumes the parent process is trusted.

`chump-mcp-github` additionally has a repo allowlist (`CHUMP_GITHUB_REPOS`) but defaults to
"all repos allowed" when the env var is unset.

`chump-mcp-adb` has a shell-command blocklist (`ADB_SHELL_BLOCKLIST`) that is substring-based
and case-insensitive. As noted in COMP-013, the blocklist can potentially be evaded by
quoting/encoding tricks.

**Proposed user-side controls:**
- Set `CHUMP_GITHUB_REPOS` to an explicit allowlist of repositories. The current
  default-allow posture is a hardening gap.
- For `chump-mcp-adb`, limit use to scenarios where ADB device access is actually needed;
  do not start `chump-mcp-adb` as a background service on a shared machine.
- If future MCP servers are added and any introduces HTTP/SSE transport, a full re-audit is
  required per `docs/audits/SECURITY_MCP_AUDIT.md` (Recommended actions section).
- Monitor for file-descriptor leaks across process spawns when running Chump as a system
  service.

---

### 3.4 Credential Leakage from Ambient Stream

**Threat:** `.chump-locks/ambient.jsonl` records bash commands run by concurrent agents
(`event: bash_call`). Commands may include credential-like strings (API keys in env vars,
passwords in command args). The ambient log is world-readable by default.

**Current state:** The adversary alert emission in `src/adversary.rs::emit_ambient_alert` does
JSON-escape user-controlled content but does not redact secrets. Bash command strings are
written verbatim to `ambient.jsonl` by `scripts/dev/ambient-emit.sh` without passing through the
context firewall.

**Proposed user-side controls:**
- Set restrictive file permissions on `.chump-locks/` (`chmod 700`) on shared or
  multi-user machines.
- Avoid passing credentials directly in command arguments; prefer env-var injection via
  `--env` or shell environment so they do not appear in `ps` or `ambient.jsonl`.
- A future gap could pipe `ambient-emit.sh` through a secret-redaction pass analogous to
  `src/context_firewall.rs::sanitize`.

---

## 4. Out-of-Scope Threats

The following threats are real but are outside Chump's threat model. They require controls at
infrastructure, physical, or organisational layers that Chump does not control.

| Threat | Why Out of Scope |
|---|---|
| **Physical access to the host machine** | An attacker with physical access can read DB files, env vars, memory. OS-level disk encryption and physical security are required; Chump cannot compensate. |
| **Nation-state adversaries / zero-day exploits** | Chump is a local developer tool; nation-state threat actors are outside its intended adversary model. |
| **LLM provider data retention / training use** | Whether Anthropic or another provider trains on API traffic is governed by the provider's data use policy, not by Chump. Use the `messages` API with `anthropic-beta: no-training` header or an on-premise model to mitigate. |
| **OS-level privilege escalation** | Chump runs as a normal user process. Kernel exploits, container escapes, and SUID abuse are OS security scope. |
| **Side-channel attacks on the LLM API** | Timing attacks, model inversion, and prompt extraction from the API provider's infrastructure are out of scope. |
| **Compromised developer workstation** | If the machine running Chump is already fully compromised by malware, Chump's controls provide no meaningful protection. |
| **Git remote attacks** | Compromised `origin` remotes could serve malicious rebases. Chump trusts the git remote it is configured to use; verifying remote integrity requires commit signing and out-of-band key distribution. |
| **Clipboard or screen-reader exfiltration** | `src/screen_vision_tool.rs` and clipboard access are read-only from Chump's perspective; exfiltration via those channels by other processes is an OS isolation problem. |

---

## 5. NIST AI RMF Mapping

The [NIST AI Risk Management Framework (AI RMF 1.0)](https://www.nist.gov/system/files/documents/2023/01/26/NIST AI RMF 1.0.pdf)
organises AI risk management into four functions: GOVERN, MAP, MEASURE, and MANAGE. The mapping
below is brief and links each Chump control to the function it most directly addresses.

### GOVERN — Policies, accountability, culture

| Chump control | AI RMF alignment |
|---|---|
| `docs/process/RESEARCH_INTEGRITY.md` — binding directive for all agents on claim validity, eval methodology, and prohibited assertions | GOVERN 1.1 (Policies for AI risk) |
| `CLAUDE.md` mandatory pre-flight (gap-preflight + gap-claim + ambient check) | GOVERN 1.2 (Roles and responsibilities) |
| Pre-commit hooks (`scripts/git-hooks/pre-commit`) enforcing coordination discipline | GOVERN 2.2 (Accountability) |
| `docs/process/AGENT_COORDINATION.md` — documented multi-agent coordination protocol | GOVERN 4 (Organizational teams) |
| `docs/operations/TOOL_APPROVAL.md` trust ladder, pilot recipe for sponsor demos | GOVERN 6.1 (Policies for deployment contexts) |

### MAP — Categorise and contextualise risk

| Chump control | AI RMF alignment |
|---|---|
| Perception layer risk classification (`src/perception.rs`) — flags destructive ops, auth, external calls before main model call | MAP 1.6 (Identify risks in deployment) |
| `src/tool_policy.rs::classify_tool_risk` — static risk tiers for all tools | MAP 2.2 (Risk categories) |
| `src/cli_tool.rs::heuristic_risk` — input-dependent risk scoring for shell commands | MAP 2.3 (Risk likelihood) |
| `docs/architecture/POLICY-sandbox-tool-routing.md` — explicit classification of every tool as safe/sandboxed/never for speculative rollback | MAP 5 (Practitioner guidance) |
| `docs/audits/SECURITY_MCP_AUDIT.md` — per-server audit documenting trust boundary and residual risks | MAP 3.5 (Third-party risk) |

### MEASURE — Quantify and monitor risk

| Chump control | AI RMF alignment |
|---|---|
| `tool_approval_audit` log in `logs/chump.log`; `GET /api/tool-approval-audit` export | MEASURE 2.5 (Monitoring and auditing) |
| `src/tool_policy.rs::auto_approve_rate` — rolling 7-day auto-approval rate metric | MEASURE 2.6 (Risk tracking) |
| `src/tool_health_db.rs` + circuit-breaker state — tool failure metrics | MEASURE 2.7 (Incident metrics) |
| `src/eval_harness.rs` + `chump_eval_runs` DB — property-based regression detection | MEASURE 2.10 (Evaluation of AI outputs) |
| `docs/process/RESEARCH_INTEGRITY.md` methodology standards (n≥50, cross-family judge, A/A baseline) | MEASURE 2.11 (Evaluation methodology) |

### MANAGE — Respond and recover

| Chump control | AI RMF alignment |
|---|---|
| Kill switch (`logs/pause`, `CHUMP_PAUSED=1`) — immediate stop for autonomous loop | MANAGE 1.3 (Human override) |
| Tool approval gates (`CHUMP_TOOLS_ASK`) — human-in-the-loop before destructive tool execution | MANAGE 2.2 (Human oversight) |
| Adversary mode block action (`src/adversary.rs`, `action: block`) — real-time tool-call denial | MANAGE 2.4 (Incident response) |
| Speculative execution rollback (`src/speculative_execution.rs`) | MANAGE 3.1 (Response and recovery) |
| `scripts/ops/stale-pr-reaper.sh` — automatic cleanup of stale PRs from dead agent sessions | MANAGE 4.1 (Incident tracking and recovery) |
| `scripts/coord/gap-preflight.sh` — prevents duplicate work before it starts | MANAGE 4.2 (Residual risk reduction) |

---

## Revision History

| Version | Date | Author | Changes |
|---|---|---|---|
| 1.0 | 2026-04-19 | COMP-012 | Initial draft — full MAESTRO structure |
