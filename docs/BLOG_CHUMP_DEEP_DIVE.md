# Chump: A Local-First Autonomous Agent That Replaces OpenClaw Without the Baggage

**v2 (current project state)**

_Chump is a single Rust binary: Discord bot, CLI with tools, and long-term memory. It talks to any OpenAI-compatible endpoint—best with Apple’s MLX on Silicon—and idles under 20MB while your model server can stay cold until the first message. The project has evolved: **SQLite + FTS5 + RRF** for hybrid memory, **in-process embeddings** (no Python required), a **WASM calculator** (wasmtime, no host access), **orchestrator–worker** delegation (summarize, extract), **web search** (Tavily) with an **overnight heartbeat** for self-improvement, and a **menu bar app** to start/stop servers and Chump._

---

## 1. The OpenClaw Problem

OpenClaw showed the world that autonomous agents could live inside Slack and Discord, take natural language, and actually _do_ things: run commands, read repos, remember context. The demo was compelling. The stack was not.

### Node.js: bloat and cold starts

OpenClaw is Node.js. That means:

- **Memory:** A typical Node process idles in the hundreds of MB. Add V8, the dependency tree, gateway, channels, and agent state and you’re in **gigabytes** before you load an LLM or vector DB. On a 16GB MacBook that’s constant swap pressure and a machine that feels stuck.

- **Cold starts:** Module resolution and loading the agent stack (gateway, tools, providers) take **seconds** from process start to “ready to handle a message.” For a background bot or an on-demand CLI, that delay is unacceptable.

- **Single-threaded event loop:** CPU-bound work blocks the loop. You can push work to workers, but you’re still in JavaScript with no control over allocation spikes or layout.

### The real issue: the AI has your privileges

The structural problem isn’t just resource usage. **The agent’s tools run with the same privileges as the user.** There is no sandbox and no capability boundary. The LLM decides _what_ to run; the runtime runs it. One bad or malicious tool call can `rm -rf`, read `.env`, or pivot to other services. That’s the default deployment model, not a theoretical edge case.

So: **gigabytes of RAM**, **seconds to start**, and **no isolation**—the AI is effectively root on your machine. Chump is built to fix that triangle.

---

## 2. The Rust Foundation

Chump is a Rust application that uses [AxonerAI](https://github.com/Manojython/axonerai) for the agent loop: OpenAI-compatible API, tool dispatch, session persistence. No Node, no npm, no V8.

### Memory and startup

- **Footprint:** The Chump process (Discord bot or CLI) **idles under 20MB**. One static binary, no hidden caches or lazy module graphs. The model and embeddings live in _separate_ processes (or in-process when built with `--features inprocess-embed`), so you can size and restart them independently. The agent is no longer a second giant heap next to your 17GB model.

- **Startup:** From `cargo run` or `./run-best.sh` to “agent ready” is **negligible**—binary load, env read, HTTP client and tool registry. No module graph. The first _request_ can still wait on a cold model server (tens of seconds); the agent itself is ready in single-digit milliseconds. That makes “run Chump on demand” viable.

- **No GC:** Deterministic drop, no collector fighting the model server for memory or CPU.

- **Note:** Under 20MB and sub-10ms startup are **design targets** (not enforced or measured in CI).

### Safety and bounded execution

Rust gives memory safety and no data races. For an agent that parses model JSON and runs shell commands, Chump adds:

- **Structured tool input:** Every tool has a JSON schema; `serde` deserializes. Invalid or malicious payloads fail at the boundary instead of being passed to the shell. Malformed tool JSON is logged (tool name, parse error, args preview); the agent keeps validation and fallback. The calculator normalizes **string** params (e.g. `"3.14"`) because LLMs often send numbers as strings. Servers that support it get `tool_choice: "auto"` for structured tool-call output ([STRUCTURED_TOOL_OUTPUT.md](STRUCTURED_TOOL_OUTPUT.md)).

- **Timeouts and output caps:** Every CLI call is wrapped in `tokio::time::timeout` (default 60s) and stdout/stderr are truncated (e.g. 2500 chars). Runaway or spammy commands don’t hang the process or flood Discord.

- **Allowlist and blocklist:** `CHUMP_CLI_ALLOWLIST=git,cargo,pnpm` restricts to those executables (first token); `CHUMP_CLI_BLOCKLIST=rm,sudo` forbids others. So you can run a private “full CLI” Chump or a locked-down one for a shared server. **WASM tools** (see below) give strict isolation for specific capabilities—today **wasm_calc** runs in wasmtime with no filesystem or network.

### Trait-based, zero-cost extensibility

The agent is built on **traits** and a **tool registry**:

- **Provider:** `LocalOpenAIProvider` or OpenAI’s implements `axonerai::provider::Provider`. Swap local vs cloud via `OPENAI_API_BASE`; no code fork.

- **Tools:** Each capability implements `axonerai::tool::Tool`: `name()`, `description()`, `input_schema()`, `execute()`. The registry holds `Box<dyn Tool>`; the agent dispatches by name when the model returns tool calls. Tools are registered conditionally: **wasm_calc** when `wasmtime` is on PATH and `wasm/calculator.wasm` exists; **delegate** when `CHUMP_DELEGATE=1`; **web_search** when `TAVILY_API_KEY` is set.

- **Sessions:** `FileSessionManager` persists conversation per channel (Discord) or session (CLI). Pluggable; no hard-coded storage.

Example from the codebase (Discord agent build):

```rust
registry.register(Box::new(ChumpCalculator));
if wasm_calc_available() {
    registry.register(Box::new(WasmCalcTool));
}
if delegate_enabled() {
    registry.register(Box::new(DelegateTool));
}
if tavily_enabled() {
    registry.register(Box::new(TavilyTool));
}
registry.register(Box::new(CliTool::for_discord()));
registry.register(Box::new(CliToolAlias { name: "git".to_string(), inner: CliTool::for_discord() }));
registry.register(Box::new(CliToolAlias { name: "cargo".to_string(), inner: CliTool::for_discord() }));
registry.register(Box::new(MemoryTool::for_discord(channel_id)));
```

The model sees `run_cli`, `memory`, `calculator`, optional `wasm_calc`, `delegate`, `web_search`, `git`, `cargo`; each maps to a small, testable implementation.

---

## 3. Unleashing Mac MLX

Chump does not run inference. It talks to **any OpenAI-compatible HTTP API**. On Apple Silicon the recommended stack is **vLLM-MLX**: vLLM’s semantics (continuous batching, OpenAI routes) with Apple’s **MLX** backend so inference runs natively on the GPU and uses unified memory.

### Unified memory and MLX

On M-series Macs, CPU and GPU share RAM. MLX is built for that:

- **No PCIe copy:** Weights and activations stay in one address space. You can load a **30B 4-bit model (~17GB)** and still have headroom on a 24GB machine.

- **Efficient scheduling:** Apple’s stack schedules GPU work without the overhead of shipping buffers between CPU and discrete VRAM. You get better throughput and lower latency than typical llama.cpp/Ollama setups that weren’t designed for unified memory first.

### vLLM-MLX: continuous batching and prefix caching

- **Continuous batching:** Requests are batched as capacity frees up. A single-user bot or CLI doesn’t sit behind a queue of 8.

- **Prefix caching (KV cache reuse):** In agentic loops the system prompt and early turns are often identical (same persona, tools, channel history). vLLM caches KV state for that prefix and only computes new tokens. **Time To First Token (TTFT)** drops sharply on later turns—the model doesn’t re-process the whole conversation every time.

So: first message in a channel pays full context cost; later messages benefit from prefix cache and feel much snappier.

### Throughput, model choice, and fallback

The repo cites **21–87% better throughput** with vLLM-MLX vs llama.cpp/Ollama on the same hardware. Recommended setup: **4-bit DWQ 30B** (e.g. `mlx-community/Qwen3-30B-A3B-4bit-DWQ`). DWQ (data-dependent weight quantization) keeps quality high at 4-bit so 30B fits in ~17GB. You can run **30B only** (port 8000); delegate and heartbeat use the same endpoint. For a second model (e.g. 7B on 8001), set `CHUMP_WORKER_API_BASE=http://localhost:8001/v1` so the delegate worker uses the smaller model:

```bash
./serve-vllm-mlx.sh   # port 8000, first run downloads ~17GB
export OPENAI_API_BASE=http://localhost:8000/v1
export OPENAI_API_KEY=not-needed
export OPENAI_MODEL=default
./run-best.sh
```

If you don’t want Python/vLLM-MLX, Chump works with **Ollama** or any OpenAI-compatible server:

```bash
ollama pull qwen2.5:7b
./run-local.sh --chump "What's in this repo?"
```

Same agent; only base URL and model name change.

---

## 4. The “Secret Sauce” (What’s Implemented)

Beyond Rust + MLX, Chump ships several features that make it practical, safer, and more capable.

### Hybrid memory: SQLite + FTS5 + RRF, all local

Chump’s **long-term memory** prefers **SQLite** (`sessions/chump_memory.db`) with **FTS5** for keyword search; it migrates from `sessions/chump_memory.json` on first use and falls back to JSON when the DB isn’t available. Before each turn the agent calls `recall_for_context(&user_message, 10)` and injects “Relevant context from memory” above the user message.

- **Keyword:** FTS5 (when using SQLite) or in-memory word overlap (when using JSON). No external service.
- **Semantic:** When a **local embed server** is running (port 18765) or **in-process embeddings** are used, memories are embedded and stored in `sessions/chump_memory_embeddings.json`. Recall uses cosine similarity so “the upgrades we did” can retrieve “User set up 30B model on port 8000” with no shared words.
- **RRF (reciprocal rank fusion):** When **both** SQLite and embeddings are available, keyword (FTS5) and semantic results are merged with RRF so matches that appear in both lists rank higher. See [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md).

**In-process embeddings:** Build with `cargo build --features inprocess-embed` to use **fastembed** (all-MiniLM-L6-v2) inside the Rust process. No Python embed server required; leave `CHUMP_EMBED_URL` unset (or set `CHUMP_EMBED_INPROCESS=1` to prefer in-process when the URL is set). Model is downloaded on first use. That avoids OOM from running 30B + Python embed server on the same machine. See [SPECULATIVE_AND_EMBEDDINGS.md](SPECULATIVE_AND_EMBEDDINGS.md).

All local—no API keys for memory or embeddings (unless you add Tavily for web search).

### WASM tool sandbox: wasm_calc

Chump can run **sandboxed tools** as WebAssembly (WASI) via the **wasmtime** CLI. No filesystem or network is granted. The **wasm_calc** tool is registered when `wasmtime` is on PATH and `wasm/calculator.wasm` exists:

- Build the calculator: `cd wasm/calc-wasm && cargo build --release --target wasm32-wasi --bin calc-wasm` then copy the artifact to `wasm/calculator.wasm`.
- The runner (`src/wasm_runner.rs`) runs `wasmtime run --disable-cache <path>`; stdin gets the tool input (e.g. expression), stdout/stderr are captured and returned.

So the model can do arithmetic in a **zero-trust** environment; host `run_cli` remains for when the user explicitly requests shell commands. More WASM tools (e.g. read-only file reader) can be added following the same pattern. See [WASM_TOOLS.md](WASM_TOOLS.md).

### Orchestrator–worker: delegate tool

With `CHUMP_DELEGATE=1` the agent gets a **delegate** tool: the orchestrator (full Chump with tools and session) can hand off narrow subtasks to a **worker**—a single LLM completion with a fixed system prompt, no tools. The host runs the worker and returns the result as the tool output; the model never sees the state machine.

- **Task types:** `summarize` (text + optional max_sentences) and `extract` (text + optional instruction, e.g. “names and dates”). Each has a fixed worker prompt.
- **Worker model:** Set `CHUMP_WORKER_API_BASE` and/or `CHUMP_WORKER_MODEL` to point the worker at a smaller/faster model (e.g. 7B on port 8001). If unset, the worker uses `OPENAI_API_BASE` and `OPENAI_MODEL`.

That keeps the main turn short and saves tokens; you can run 30B for the orchestrator and 7B for the worker. See [ORCHESTRATOR_WORKER.md](ORCHESTRATOR_WORKER.md).

### Web search (Tavily) and overnight heartbeat

Set **`TAVILY_API_KEY`** in `.env` (get a key at tavily.com; limited credits/month). Chump then has a **web_search** tool for research and self-improvement—he’s prompted to look things up and store learnings in memory.

**Heartbeat:** Run `./scripts/heartbeat-learn.sh` for a set duration (default **8 hours**). Each round sends a self-improvement prompt; Chump uses web_search and stores what he learns in memory. Preflight ensures a model server is up (8000 or 8001); you can use warm-the-ovens so the server starts on demand. Logs go to `logs/heartbeat-learn.log`. Quick test: `HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-learn.sh` (2m, 15s interval). See [CHUMP_SERVICE.md](CHUMP_SERVICE.md) §4.

**Autonomy tiers:** Run `./scripts/run-autonomy-tests.sh` to validate tools (calc, memory), research (web_search), multi-step (search + store), and sustain (heartbeat round). Passing tiers **unlock** behavior: e.g. tier ≥3 enables delegate by default; tier ≥4 allows unattended 8h heartbeat. The script writes the highest tier passed to `logs/autonomy-tier.env`. See [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md).

### Warm-the-ovens: model on demand

With `CHUMP_WARM_SERVERS=1` the **first** message triggers `scripts/warm-the-ovens.sh`: if port 8000 isn’t up, it starts `serve-vllm-mlx.sh` in the background and waits for `GET /v1/models` → 200 (bot waits up to 90s). Later messages see the port up and skip the wait. So **Chump stays up in a few MB**; the heavy MLX process starts on first use and stays warm until you stop it or reboot. With launchd ([CHUMP_SERVICE.md](CHUMP_SERVICE.md)) you get “bot always on, model on demand.”

### CLI: allowlist, blocklist, timeout, and audit

`run_cli` runs one command per call via `sh -c` in the agent’s cwd. Timeout (60s), output cap (2500 chars), allowlist/blocklist (first token). Every message, reply, and CLI run is appended to **`logs/chump.log`** (timestamp, channel, user, command, exit code, output length)—a local audit trail without shipping data anywhere.

### Chump Menu (menu bar app)

The **Chump Menu** app (v1.1) lives in the macOS menu bar: start/stop vLLM-MLX on 8000 and 8001, start/stop the embed server, **Start Chump** / **Stop Chump** (Discord bot), and **Start heartbeat (8h learning)** / **Stop heartbeat**. Status refreshes (ports warm/cold, embed server); single-instance guard so only one Discord bot runs (no duplicate replies). Build with `./scripts/build-chump-menu.sh`; see [ChumpMenu/README.md](../ChumpMenu/README.md).

---

## Summary

| Concern             | OpenClaw (typical) | Chump                                                                  |
| ------------------- | ------------------ | ---------------------------------------------------------------------- |
| Runtime             | Node.js            | Rust                                                                   |
| Agent memory        | Gigabytes          | Under 20MB idle                                                        |
| Startup (agent)     | Seconds            | Negligible (ms)                                                        |
| Inference           | Various            | vLLM-MLX or any OpenAI-compatible                                      |
| Long-term memory    | Often cloud/API    | SQLite + FTS5 + RRF; optional in-process embeddings (fastembed)        |
| Tool isolation      | None (host = user) | Allowlist/blocklist, timeout, cap; **wasm_calc** (WASM, no FS/network) |
| Orchestrator–worker | N/A                | **delegate** (summarize, extract); optional worker model (8001)        |
| Web search          | Depends            | **web_search** (Tavily); optional, limited credits                     |
| Heartbeat           | N/A                | **heartbeat-learn.sh** (8h learning, configurable); autonomy tiers     |
| Audit               | Depends            | Append-only `logs/chump.log`                                           |
| Always on           | Heavy process      | Light process + warm-the-ovens; optional launchd                       |
| UI                  | Depends            | **Chump Menu** (start/stop servers, Chump, heartbeat)                  |

Chump is **not** a full drop-in for every OpenClaw feature (all channels, connectors, etc.). It’s a **local-first, minimal agent**: one binary, Discord + CLI, a growing set of tools (including WASM and delegate), and a design that prioritizes low footprint, fast startup, and real isolation where it matters. You run your own model (MLX recommended), your own embed path (Python server or in-process), and your own policy. No cloud lock-in for core behavior; optional Tavily for web search and heartbeat.

---

## Quick start

```bash
# 1. Clone and build
git clone <repo> && cd rust-agent
cargo build --release
# Optional: in-process embeddings (no Python embed server)
# cargo build --release --features inprocess-embed

# 2. Start the model (pick one)
./serve-vllm-mlx.sh                    # vLLM-MLX 30B on port 8000 (best)
# or: ollama serve && ollama pull qwen2.5:7b

# 3. Run the agent
export OPENAI_API_BASE=http://localhost:8000/v1   # or http://localhost:11434/v1 for Ollama
export OPENAI_API_KEY=not-needed
./run-best.sh "Explain recursion in one sentence."   # single-shot
./run-best.sh                                         # interactive REPL
./run-discord.sh                                      # Discord bot (DISCORD_TOKEN in .env)
```

Optional:

- **Semantic memory:** Python embed server — `pip install -r scripts/requirements-embed.txt` then `./scripts/start-embed-server.sh`; or build with `--features inprocess-embed` and leave `CHUMP_EMBED_URL` unset.
- **Delegate:** `export CHUMP_DELEGATE=1`; worker uses 8000 unless `CHUMP_WORKER_API_BASE` / `CHUMP_WORKER_MODEL` set.
- **Web search + heartbeat:** Add `TAVILY_API_KEY` to `.env`; run `./scripts/heartbeat-learn.sh` for 8h learning (or `HEARTBEAT_QUICK_TEST=1` for 2m).
- **Autonomy tests:** `./scripts/run-autonomy-tests.sh` (tiers 0–4).
- **Menu bar:** `./scripts/build-chump-menu.sh` → `ChumpMenu.app`.

The rest is in the code and the docs ([ROADMAP.md](ROADMAP.md), [CHUMP_SMART_MEMORY.md](CHUMP_SMART_MEMORY.md), [WASM_TOOLS.md](WASM_TOOLS.md), [ORCHESTRATOR_WORKER.md](ORCHESTRATOR_WORKER.md), [CHUMP_AUTONOMY_TESTS.md](CHUMP_AUTONOMY_TESTS.md)).
