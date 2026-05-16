# ACP Agent Registry Submission: Chump

## Description

This pull request submits Chump to the JetBrains ACP (Agent Client Protocol) Agent Registry.

**Agent:** Chump  
**Version:** 0.1.0  
**Repository:** https://github.com/repairman29/chump  
**Author:** Jeff Adkins (@repairman29)

## What is Chump?

Chump is a self-hosted Rust agent featuring:

- **Local-first inference** via Ollama, vLLM, or mistral.rs
- **Persistent memory** with SQLite + FTS5 + semantic recall
- **Full ACP compliance** (V1, V2, V2.1) for Zed and JetBrains IDEs
- **30+ tools** for repo operations, git, GitHub, web search, scheduling, etc.
- **Bounded autonomy** with task contracts and safe escalation
- **No cloud required** — runs entirely on your hardware

## ACP Specification Compliance

Chump implements the complete ACP specification:

### Core Methods (V1)
- ✅ initialize
- ✅ session/new, session/load, session/list
- ✅ session/prompt, session/cancel
- ✅ fs/read_text_file, fs/write_text_file
- ✅ terminal/* (create, output, wait_for_exit, kill, release)

### Extended Methods (V2)
- ✅ session/set_mode
- ✅ session/set_config_option
- ✅ session/list_permissions, session/clear_permission

### Middleware (V2.1)
- ✅ session/request_permission (outbound RPC)
- ✅ Cross-process session persistence

### Chump-Specific Extensions
- ✅ skills: true (procedural skills library)
- ✅ thinking: true (separate Thinking event stream)
- ✅ Full mixed-content prompt support (text + images + resources)

## Launch Command

```bash
chump --acp
```

Chump exposes a JSON-RPC server on stdin/stdout compatible with all ACP clients.

## Installation

### macOS (Homebrew)
```bash
brew tap repairman29/chump
brew install chump
chump init
```

### Linux
```bash
git clone https://github.com/repairman29/chump.git
cd chump
cargo build --release
./target/release/chump init
```

### Windows
Use Windows Subsystem for Linux 2 (WSL2) with the Linux installation method.

## Capabilities

| Capability | Status | Details |
|---|---|---|
| tools | ✅ | 30+ tools for coding tasks |
| streaming | ✅ | Real-time token streaming |
| modes | ✅ | Semantic modes (work, research, light) |
| permissions | ✅ | Sticky per-session permission caching |
| fs | ✅ | Filesystem delegation for remote/SSH |
| terminal | ✅ | Full shell process lifecycle |
| skills | ✅ | Procedural skills with Bradley-Terry evolution |
| thinking | ✅ | Separate Thinking event stream |
| mcpServers | ✅ | MCP server passthrough |

## Documentation

- **Main repo:** https://github.com/repairman29/chump
- **Website:** https://repairman29.github.io/chump/
- **ACP docs:** https://repairman29.github.io/chump/docs/architecture/ACP.md
- **Capability comparison:** https://repairman29.github.io/chump/docs/architecture/ACP_CAPABILITY_COMPARISON.md

## Files Included

- `agents/chump/agent.json` — Agent metadata with ACP configuration
- `agents/chump/icon.svg` — Chump icon for registry display

## Submission Checklist

- [x] Agent metadata includes all required fields
- [x] ACP launch command documented
- [x] Supported ACP versions specified (1.0, 2.0)
- [x] Tool capabilities enumerated
- [x] Installation instructions provided for macOS (brew), Linux, and Windows (WSL2)
- [x] Icon included (SVG format)
- [x] Repository and documentation links verified
- [x] License verified (MIT)

## Testing

Chump has been tested against:
- Zed (stable and preview builds)
- JetBrains IDEA (Community and Ultimate editions)
- Real-world usage in solo development and team settings

Full test coverage available in [CREDIBLE-057](https://github.com/repairman29/chump/issues/CREDIBLE-057).

## Notes

Chump is production-ready and has been in active use since v0.1.0 release (2026-04-16).

---

**Contact:** Jeff Adkins (@repairman29) — issues, questions, or requests can be filed at https://github.com/repairman29/chump/issues
