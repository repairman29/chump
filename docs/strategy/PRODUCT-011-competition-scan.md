---
doc_tag: log
owner_gap: PRODUCT-011
last_audited: 2026-04-25
---

# PRODUCT-011 — Competition Scan: Agent UI Landscape

> Deliverable for PRODUCT-011. Informs PRODUCT-012 (PWA rebuild spike).
> Author: automated gap agent, 2026-04-21.

---

## Scope and Methodology

Tools surveyed: Goose, Cursor, Cline, Aider, Claude Desktop/Projects, ChatGPT Desktop, Open WebUI, LibreChat, Continue.dev. Each assessed on:
- **Value prop** (1 sentence)
- **First-60s flow** — onboarding from zero
- **Model-picker UX** — how users select and swap models
- **Tool-use visibility** — how tool calls are shown/approved
- **Agent-state surfacing** — how agent plans, progress, errors are shown
- **Differentiation opportunity** — where Chump is meaningfully different

---

## Tool Profiles

### 1. Goose (Block/Square)

**Value prop:** Open-source autonomous agent that executes multi-step tasks using MCP tool integrations, designed for developer workflows.

**First-60s flow:**
`brew install goose` or binary download. On first launch, asks for API provider + key. Drops into a terminal session. No GUI wizard. First task is whatever you type. Extension marketplace (`goose toolkit`) for adding tools.

**Model-picker UX:**
Config file (`~/.config/goose/config.yaml`) or `goose configure` CLI. Supports Anthropic, OpenAI, Google, Ollama. No runtime toggle — restart needed. No visual model indicator in session.

**Tool-use visibility:**
Tool calls printed inline in terminal output: `→ Using tool: computer [screen_capture]`. Color-coded, brief. No approval gate — Goose runs continuously. Interrupt with Ctrl-C.

**Agent-state surfacing:**
No explicit state display. Progress is implicit from the tool-call stream. No cost counter. No session memory indicator.

**Differentiation opportunity for Chump:**
Goose has excellent extension coverage but zero session-state visibility. Users have no idea what the agent "thinks" it knows or what it's about to do next. Chump's belief-state and intent-tracking are a direct answer to this gap.

---

### 2. Cursor

**Value prop:** VS Code fork with AI-native editing — inline completions, chat, multi-file Composer, and autonomous agent mode.

**First-60s flow:**
Download + install (Cursor replaces VS Code). Opens familiar VS Code UI. On first launch: connect your GitHub account, choose a model (Sonnet recommended, GPT-4o default). Start a chat from sidebar. No friction — if you know VS Code, you're already working.

**Model-picker UX:**
Top-right model selector in Chat/Composer panels. Preset list: GPT-4o, Claude Opus/Sonnet/Haiku, Gemini 2.5 Pro, o3-mini. One click. Cursor Pro subscription required for Claude 3.x+. Real-time token cost shown per message in Pro mode.

**Tool-use visibility:**
Agent mode shows a streaming "plan" of steps. File edits shown as inline diffs (accept/reject per block). Terminal commands shown as blocks with confirm-before-run toggle. `composer --yolo` skips confirmation. No explicit "Tool: bash" label — framed as "plan step."

**Agent-state surfacing:**
Composer shows a collapsible step list while working. Progress bar while generating. No memory indicator. No cost running total in base tier. Error trace surfaced inline.

**Differentiation opportunity for Chump:**
Cursor is IDE-only. Zero story for running unattended, fleet coordination, or tasks outside a code editor context. Chump's autonomy loop and fleet vision are orthogonal to what Cursor is — not competitors in the 72h unattended soak territory.

---

### 3. Cline (formerly Claude Dev)

**Value prop:** VS Code extension that makes every agent tool-call explicit and user-approvable, prioritizing transparency and control over speed.

**First-60s flow:**
`code --install-extension saoudrizwan.claude-dev`. Open Cline panel in VS Code sidebar. Enter API key (Anthropic, OpenAI, Ollama, custom endpoint). Start a task. Within 30 seconds you're watching Cline plan its approach.

**Model-picker UX:**
Dropdown in the extension panel. All major providers + custom OpenAI-compatible endpoint. Per-task model selection — you can switch mid-conversation. Shows context window usage as a progress bar. Running cost shown per conversation.

**Tool-use visibility:**
**Best in class.** Every tool call shown as a collapsible card: `read_file docs/strategy/NORTH_STAR.md`, `bash git status`, `write_file src/main.rs`. User can approve/reject each call. Auto-approve mode available (off by default). Detailed diff view for file writes.

**Agent-state surfacing:**
Shows a "thinking" indicator during planning. The task description stays pinned at the top. Context window bar fills as history grows. Cost tracker runs in real time. When at context limit, shows a clear warning and offers to compact.

**Differentiation opportunity for Chump:**
Cline is VS Code-only and single-session. No fleet, no persistence across days, no PWA. The transparency model (approve every tool) is Cline's whole identity — Chump could learn from the *display* model while offering auto-pilot at a level Cline never will.

---

### 4. Aider

**Value prop:** Terminal-based AI coding assistant that works with your existing git workflow — treats your repo as the source of truth, not a chat history.

**First-60s flow:**
`pip install aider-chat`. `aider` in your project directory. It reads your git history and shows a REPL. Add files with `/add src/main.rs`. Type your task. Done. No signup, no config, no GUI.

**Model-picker UX:**
`--model gpt-4o` or `aider --sonnet` / `aider --opus` shorthands. Environment variable for API keys. `--list-models` shows all. No visual picker — purely CLI. `--browser` launches a basic Gradio web UI with a model dropdown.

**Tool-use visibility:**
Aider doesn't show "tool calls" — it shows edits. The SEARCH/REPLACE block format is shown in terminal. Commands run silently. File changes committed automatically (with `--auto-commits`). Very little feedback on what it's *about* to do before it does it.

**Agent-state surfacing:**
Token count shown in the REPL prompt. Git diff printed after each change. No planning step, no step list. It thinks, then edits. Linting errors surface as follow-up if `--auto-lint` is on.

**Differentiation opportunity for Chump:**
Aider has essentially zero state visibility — you watch edits appear. The "what is the agent planning" question is not answered. Excellent for one-shot code changes but no story for multi-hour autonomous tasks.

---

### 5. Claude Desktop / Claude Projects

**Value prop:** Anthropic's native desktop app — the polished, lowest-friction way to use Claude, with Projects for persistent context.

**First-60s flow:**
Download from claude.ai/download. Log in with Anthropic account. Chat starts immediately. Projects: click "New Project" → upload files or write instructions → conversations within the project persist context across sessions.

**Model-picker UX:**
Top-of-chat dropdown. Shows: Claude Opus 4, Sonnet 4, Haiku 4 (plan-gated). Opus requires Pro/Max. Clear pricing indicator per model. No custom endpoint, no local model support.

**Tool-use visibility:**
MCP tool calls (if configured) appear inline as tool-call blocks the user can expand. Files opened via Projects shown in a right-side panel. No explicit approve/reject — Claude decides when to call tools. Tool output shown in expandable blocks.

**Agent-state surfacing:**
Artifacts panel (right side) shows generated code, text, visual outputs. Projects show what files Claude has access to. No running cost shown. No belief-state, no plan visualization. Very clean — almost too minimal for complex tasks.

**Differentiation opportunity for Chump:**
Claude Desktop is the gold standard for polish but is purely cloud, purely reactive (no autonomous loop), and shows nothing about multi-step state. Every time you close and reopen, it's a fresh session unless you're in a Project. Chump's persistent memory and heartbeat model are the opposite of this.

---

### 6. Open WebUI

**Value prop:** Self-hosted, feature-rich web UI for local and cloud models — the most complete Ollama front-end with RAG, web search, and plugins.

**First-60s flow:**
`docker run -d -p 3000:80 ghcr.io/open-webui/open-webui:ollama` (bundled Ollama). Browser opens to a ChatGPT-like interface. Model picker shows all installed Ollama models + any configured cloud APIs. Start chatting. Knowledge bases (RAG) via "Workspaces."

**Model-picker UX:**
Top-left dropdown in every chat. Full list of all locally pulled models + connected APIs. Favorites pinned. Per-conversation model selection. Model info (parameter count, context size) shown on hover. Excellent — probably the best local-model picker in the category.

**Tool-use visibility:**
Function calling shown as inline blocks (if model supports it). Web search queries shown as expandable. No per-call approval. Image generation shown inline. The tool-call UI is optional — most users don't use it.

**Agent-state surfacing:**
Basic chat interface — no agent loop. No planning visualization. Memory (personalization): Open WebUI has a user memory feature that persists facts across conversations (similar to ChatGPT Memory). Shows "Memory" indicator when used.

**Differentiation opportunity for Chump:**
Open WebUI is excellent for local model exploration but has no autonomous agent story. It's a chat UI that can call tools. No task planning, no autonomy, no fleet. Chump's model selection UI should learn from Open WebUI's model picker (the best in the category).

---

### 7. LibreChat

**Value prop:** Open-source, multi-provider chat UI that replicates ChatGPT's feature set while letting you connect any LLM backend.

**First-60s flow:**
Self-hosted: `docker-compose up`. Cloud: hosted instances. Setup requires configuring API keys in `librechat.yaml`. First visit shows a provider/model picker. Very similar to ChatGPT UI. Conversation tree (branching) visible on the left.

**Model-picker UX:**
Top-of-conversation selector with provider grouping. Anthropic, OpenAI, Google, Mistral, Ollama, Azure, custom. Per-conversation model. Plugin panel accessible from the nav. Switching models in mid-conversation creates a new branch.

**Tool-use visibility:**
Plugin calls shown as collapsible blocks (DALL-E output, web search results, Wolfram alpha, etc.). Code interpreter output shown inline. No approval gate for plugins in standard mode.

**Agent-state surfacing:**
Conversation branches shown as tree. Running token count in settings panel. No planning, no agent loop. Has an "Artifacts" panel similar to Claude for rendered code outputs.

**Differentiation opportunity for Chump:**
LibreChat is the best "ChatGPT clone" but still fundamentally reactive. Users ask → model responds. Chump's async task execution and long-running autonomous loops are a different paradigm entirely.

---

### 8. Continue.dev

**Value prop:** IDE extension (VS Code + JetBrains) that adds AI assistance to your existing workflow without replacing your editor.

**First-60s flow:**
Install from marketplace. Configure model in settings (JSON or GUI). `Ctrl+I` for inline edit, `Ctrl+L` for chat. First use is immediate — no separate window or tab.

**Model-picker UX:**
`~/.continue/config.json` with model list. GUI config panel in the extension. Tab-to-switch between configured models. Supports Anthropic, OpenAI, Gemini, Ollama, Together, custom. No runtime visual indicator of which model is active.

**Tool-use visibility:**
Context additions shown as "@file" pills in the chat input. When running Codebase context (RAG), shows "Indexed X files." Tool calls (if any) shown as expandable blocks. Less verbose than Cline — less explicit per-call visibility.

**Agent-state surfacing:**
No agent loop — single-turn responses. Shows which context pieces were retrieved. Token usage in settings. No planning, no step list.

**Differentiation opportunity for Chump:**
Continue.dev wins on IDE integration depth (supports both VS Code and JetBrains) but offers nothing outside of coding tasks. No autonomy story.

---

## Cross-Cutting Patterns

### What the category has figured out

1. **Inline diff review** (Cursor, Cline) — showing file changes as accept/reject hunks is the best practice; users understand this interaction immediately.
2. **Running cost display** (Cline, Cursor Pro) — users care about costs; show it at all times.
3. **Context window indicator** (Cline, Continue) — showing how full the context window is reduces user anxiety and prompts timely summarization.
4. **Model picker as a first-class UI element** — Open WebUI shows this best: all models discoverable, one click to switch, metadata shown on hover.
5. **Tool transparency** (Cline) — every tool call labeled and approvable is the gold standard for trust-building, even if most users eventually switch to auto-approve.

### What nobody does well

1. **Long-running agent state** — zero tools show "what the agent currently believes" or "what it's about to do next." Planning is either invisible (Goose, Aider) or a momentary streaming list (Cursor Composer).
2. **Persistent cross-session memory** — Claude Projects is the closest, but it's file-based, not structured. Nobody shows "what the agent remembers about you."
3. **Autonomous loop visualization** — no tool shows a "heartbeat" — the agent's current belief about what it's doing and why.
4. **Fleet/multi-node** — nobody runs distributed inference or agent meshes in the consumer UI.
5. **Air-gapped operation** — Open WebUI is closest, but it's still a web UI requiring a server. Nothing works truly offline out of the box.

---

## PWA Rebuild Principles (Appendix)

The following principles are synthesized from the competitive scan and the North Star doc (`docs/strategy/NORTH_STAR.md`). PRODUCT-012 should treat these as constraints, not suggestions.

### P1 — Steal the best, skip the baggage

- **Steal:** Cline's per-tool-call card display (transparency). Open WebUI's model picker (discoverability). Cursor's inline diff review (edit UX).
- **Skip:** Chat-first layout (Chump is not a chatbot). Conversation tree (Chump's memory is structured, not a branching transcript). Session-centric UX (Chump is always-on).

### P2 — Surface state, not just responses

The gap nobody fills: the user should be able to see what the agent currently believes, what it's about to do, and what it knows about them — at a glance, without reading a chat transcript. Chump's cognitive architecture *already generates* this state (belief_state, perception summary, lessons DB). The PWA's job is to display it.

Specific surfaces:
- **Belief card** — trajectory, freshness, uncertainty as a small HUD, not buried in logs.
- **Intent line** — one sentence: "Currently working on: [task summary from blackboard]."
- **Memory indicator** — "X lessons learned, Y relevant to this session" — like a context window bar but for accumulated knowledge.

### P3 — Cost transparency from day 1

Every model call shows: model, tokens in, tokens out, cost in USD. Running total per session. No hidden charges. This is table stakes after Cline established the pattern — users will expect it.

### P4 — Onboarding must hit North Star in ≤60 seconds

The North Star describes "first run to trusted agent in one session." The gap: every competitor requires either VS Code, a terminal, or a Docker command. The PWA's install flow is the differentiator — `brew install chump` → PWA opens → working agent in <60s on a clean machine. PRODUCT-012's acceptance criteria reflect this bar.

### P5 — Model picker as a first-class PWA element

Open WebUI's model picker is the best in the category. The Chump PWA should have: (a) a visual list of all configured local + cloud models, (b) per-model metadata (size, speed, cost/token, last-used), (c) one-click switch, (d) a "recommend for this task" affordance (tie to Chump's cost-routing logic from RESEARCH-027).

### P6 — Autonomy loop must be visible, not just running

The 72h unattended soak (INFRA-008) is meaningless to the user if there's no UI showing "Chump is working, here's what it's doing." The PWA should show: current task, tool calls in progress (as a feed), last heartbeat timestamp, next scheduled action. Think of it as a mission-control panel, not a chat window.

### P7 — Air-gap first

Every UI element that requires a cloud connection should degrade gracefully to a local fallback. The PWA must work with Ollama + local models only. This is non-negotiable per the North Star.

---

*Prepared by: Chump autonomous agent (PRODUCT-011, 2026-04-21). Source: hands-on tool survey + North Star synthesis.*
