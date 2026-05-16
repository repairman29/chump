# Chump ACP Registry Submission

This directory contains the metadata and files required to submit Chump to the JetBrains ACP (Agent Client Protocol) Agent Registry.

## Submission Contents

- **agent.json** — Agent metadata including ACP-specific fields, capabilities, and installation instructions
- **icon.svg** — Chump icon for the registry display
- **SUBMISSION_GUIDE.md** — This file

## What's Included

### ACP Specification Compliance

Chump implements the full ACP specification, including:

- **V1 methods:** Initialize, session/new, session/load, session/list, session/prompt, cancel
- **V2 methods:** session/set_mode, session/set_config_option, session/list_permissions, session/clear_permission
- **V2.1 middleware:** session/request_permission (outbound RPC for tool-call consent)
- **Cross-process persistence:** Sessions persist to disk and survive across process restarts
- **Rich content blocks:** Text, images, and resource URIs in mixed-content prompts
- **Terminal lifecycle:** Full terminal/create → terminal/release lifecycle with output polling
- **Thinking events:** Separate Thinking event stream for model reasoning tokens
- **Skills capability:** Procedural skills library exposed via ACP

### Launch Command

```bash
chump --acp
```

Chump listens for JSON-RPC messages on stdin and writes responses to stdout.

### Installation Methods

#### macOS (Homebrew — recommended)

```bash
brew tap repairman29/chump
brew install chump
chump init
```

#### Linux (build from source)

```bash
git clone https://github.com/repairman29/chump.git
cd chump
cargo build --release
./target/release/chump init
```

#### Windows

Use Windows Subsystem for Linux 2 (WSL2) with the Linux installation method.

### Supported Platforms

- **macOS:** aarch64 (Apple Silicon) and x86_64 (Intel)
- **Linux:** aarch64 (ARM64) and x86_64 (x86-64)
- **Windows:** WSL2 (no native Windows support)

### Tool Capabilities

Chump exposes the following capabilities via ACP:

| Capability | Supported | Details |
|---|---|---|
| **tools** | ✅ | 30+ tools for repo, git, GitHub, web search, scheduling, etc. |
| **streaming** | ✅ | Real-time token streaming for low-latency responses |
| **modes** | ✅ | Semantic modes (work, research, light) with different context strategies |
| **permissions** | ✅ | Sticky per-tool permission decisions cached per session |
| **fs** | ✅ | Filesystem read/write delegation for remote/SSH setups |
| **terminal** | ✅ | Full shell process lifecycle with output polling and process control |
| **skills** | ✅ | Procedural skills library with Bradley-Terry evolution |
| **thinking** | ✅ | Separate Thinking event stream for model reasoning (Qwen3, Claude) |
| **mcpServers** | ✅ | Passthrough support for client-declared MCP server configuration |

### Key Features

- **Self-hosted:** Runs entirely on your hardware (laptop, server, or cloud VM)
- **Local-first inference:** Default backend is Ollama, with fallback to vLLM and mistral.rs
- **No cloud required:** Works offline; fully air-gapped deployments supported
- **Persistent memory:** SQLite + FTS5 + embedding-based semantic recall
- **Bounded autonomy:** Task contracts and graduated escalation for safe agent behavior
- **30+ tools:** Repo read/write, git operations, GitHub API, web search, scheduling, sub-agent dispatch
- **Consciousness framework:** Surprise tracking, neuromodulation, belief state, precision controller

## Registry Information

- **Repository:** https://github.com/repairman29/chump
- **Website:** https://repairman29.github.io/chump/
- **Documentation:** https://repairman29.github.io/chump/docs/architecture/ACP.md
- **License:** MIT
- **Author:** Jeff Adkins (@repairman29)

## ACP Documentation

- [Agent Client Protocol Specification](https://agentclientprotocol.com)
- [Chump ACP Implementation](https://repairman29.github.io/chump/docs/architecture/ACP.md)
- [ACP Capability Comparison](https://repairman29.github.io/chump/docs/architecture/ACP_CAPABILITY_COMPARISON.md)

## Submission Status

- **Version submitted:** 0.1.0 (initial submission)
- **Submission date:** 2026-05-15
- **ACP versions supported:** 1.0, 2.0
- **Status:** Ready for JetBrains ACP Agent Registry inclusion

## Next Steps

To list Chump in the JetBrains ACP Agent Registry:

1. Fork the JetBrains ACP Agent Registry repository
2. Add the `registry-submission/chump/` directory contents to the registry
3. Submit a pull request with the agent metadata and icon
4. JetBrains will review and merge to make Chump discoverable in Zed, JetBrains IDEs, and other ACP clients

Once merged, Chump will appear in:
- JetBrains IDEs' "Coding Agents" sidebar
- Zed's agent configuration
- Any ACP-compatible editor integrating with the official registry
