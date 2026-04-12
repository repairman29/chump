# Top-tier vision: high-leverage capabilities

Long-term direction to push the Rust architecture into the absolute top tier of autonomous systems. This is **not** the current backlog—it is a vision document for when we are ready to invest in these capabilities.

---

## 1. In-process high-perf inference (mistral.rs)

Stop relying on external `ollama` or Python sidecars. Graft **mistral.rs** directly into the binary so the agent has native Rust control over the KV cache and VRAM.

**First slice (shipped, optional):** Cargo feature **`mistralrs-infer`** implements the `Provider` trait in-process; see [INFERENCE_PROFILES.md](INFERENCE_PROFILES.md) §2b. Production default on Mac remains vLLM-MLX HTTP until this path is battle-tested. **WP-1.4:** upstream-vs-Chump matrix, extended **`CHUMP_MISTRALRS_*`** env (ISQ 2–8, HF revision, prefix cache, MoQE, PagedAttention toggle, throughput logging), and compile-only CI — [MISTRALRS_CAPABILITY_MATRIX.md](MISTRALRS_CAPABILITY_MATRIX.md).

- **PagedAttention & ISQ:** In-situ quantization and optional PagedAttention are **partially exposed via env** when using the in-process backend (see matrix); further tuning (per-layer topology, `MemoryGpuConfig`, specific `IsqType` like MXFP4) remains **future** or **mistralrs serve** sidecar.
- **X-LoRA support:** Allow the agent to swap adapters dynamically depending on the task (e.g. loading a coding-specific LoRA when it detects a `work` round).

---

## 2. Kernel-level observability (Aya + eBPF)

Move past standard log-reading for self-healing. Use the **Aya** crate to load eBPF programs into the kernel.

- **System call tracing:** The agent can monitor its own file I/O and network requests at the kernel level. If a tool hangs or a network request is throttled, the agent sees the syscall failure immediately rather than waiting for a timeout.
- **Security sandboxing:** Use eBPF to enforce a strict security policy on any CLI tools it autonomously installs, killing any process that attempts to access unauthorized directories.

---

## 3. Managed browser sandboxing (Firecrawl API)

Generic `reqwest` or `curl` calls fail on modern JS-heavy sites. Integrate **Firecrawl's Browser Sandbox**.

- **Remote Playwright:** Instead of installing Chromium on the Pixel (Mabel), the agent triggers a managed browser session via API. It receives a markdown representation of the live DOM, navigates complex auth flows, and extracts structured data without the overhead of local browser rendering.
- **Live view debugging:** The agent can send the live preview URL to the Discord channel so you can watch it navigate in real time if it hits a CAPTCHA.

---

## 4. Stateless recursive task management

Implement the "Ralph Wiggum" pattern to solve context drift. Instead of one long conversation, the orchestrator breaks a goal into a `vec!` of discrete sub-tasks.

- **Ephemeral context:** Each sub-task runs in a clean-room environment. The agent is given only the files and logs relevant to *that* specific task.
- **Atomic commits:** Upon sub-task completion, the agent runs a localized test suite, commits the change to a feature branch, and *resets* its context for the next task. This prevents the hallucination spiral common in long-running agent sessions.

---

## 5. JIT WASM tool forging

Give the agent the ability to forge its own tools when existing CLI tools are missing.

- **Dynamic compilation:** The agent writes a specific Rust function (e.g. a custom parser for an obscure log format), compiles it to a `.wasm` module in-memory, and executes it using the `wasmtime` crate. This allows it to expand its capabilities without needing a full recompilation of the main orchestrator.

---

## Reference

[Rust vs Python for AI: Is Rig better than Langchain?](https://www.youtube.com/watch?v=cyZXVgzy7DA) — Explores the Rig library and why Rust is becoming the preferred language for high-performance, autonomous AI agents compared to traditional Python frameworks.
