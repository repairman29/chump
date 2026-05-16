---
doc_tag: operations
owner_gap: PRODUCT-049
last_updated: 2026-05-15
---

# JetBrains ACP Agent Registry Submission

This document describes Chump's submission to the JetBrains ACP Agent Registry and the process for keeping the registry entry up-to-date.

## Overview

Chump is a fully ACP-compliant agent and is submitted to the official JetBrains ACP Agent Registry. Once listed, Chump becomes discoverable in:

- **JetBrains IDEs** (IDEA, PyCharm, etc.) — via the "Coding Agents" sidebar
- **Zed** — via agent configuration
- **Any ACP-compatible editor** — that integrates with the official registry

## Registry Submission Contents

The submission is located in `/registry-submission/chump/` and includes:

```
registry-submission/
├── chump/
│   ├── agent.json          # Agent metadata with ACP configuration
│   └── icon.svg            # Registry display icon
└── SUBMISSION_GUIDE.md     # This submission package documentation
```

### agent.json Structure

The agent metadata includes:

```json
{
  "id": "chump",                           // Unique registry identifier
  "name": "Chump",                         // Display name
  "version": "0.1.0",                      // Current version
  "description": "...",                    // One-line summary
  "repository": "https://github.com/...",  // Source repository
  "website": "https://...",                // Official website
  "documentation_url": "https://...",      // ACP-specific docs
  "license": "MIT",                        // License identifier
  "acp": {
    "launch_command": "chump --acp",       // Command to start the agent
    "supported_versions": ["1.0", "2.0"],  // ACP versions supported
    "capabilities": {
      "tools": true,                       // Supports tool calls
      "streaming": true,                   // Supports token streaming
      "modes": true,                       // Supports work/research/light modes
      "permissions": true,                 // Supports sticky permissions
      "fs": true,                          // Supports filesystem delegation
      "terminal": true,                    // Supports terminal lifecycle
      "skills": true,                      // Supports procedural skills
      "thinking": true                     // Supports thinking events
    }
  },
  "installation": {
    "macos": { ... },                      // macOS installation (brew)
    "linux": { ... },                      // Linux installation (cargo)
    "windows": { ... }                     // Windows installation (WSL2)
  },
  "distribution": { ... }                  // Binary distribution info
}
```

## Installation Methods in Registry

The registry documents three installation paths:

### macOS (Homebrew — recommended)

```bash
brew tap repairman29/chump
brew install chump
chump init
```

Chump is distributed via the [repairman29/homebrew-chump](https://github.com/repairman29/homebrew-chump) tap, which provides pre-built binaries for both Intel (x86_64) and Apple Silicon (aarch64).

### Linux (Build from source)

```bash
git clone https://github.com/repairman29/chump.git
cd chump
cargo build --release
./target/release/chump init
```

Pre-built binaries are available from GitHub Releases for both x86_64 and aarch64 architectures, but building from source gives access to the latest development version.

### Windows (WSL2)

Windows users should use Windows Subsystem for Linux 2 (WSL2) with the Linux installation method. Native Windows support is not currently available.

## ACP Compliance

Chump implements the complete ACP specification across three tiers:

### V1 — Core Protocol (Required)

All V1 methods are shipped and tested:

- `initialize` — Declare agent capabilities and protocol version
- `session/{new, load, list}` — Session lifecycle management
- `session/prompt` — Process user requests and stream responses
- `session/cancel` — Cancel in-flight operations
- `fs/{read, write}_text_file` — Filesystem delegation
- `terminal/{create, output, wait_for_exit, kill, release}` — Terminal lifecycle

### V2 — Extended Protocol

All V2 methods are shipped:

- `session/set_mode` — Switch between work/research/light modes mid-session
- `session/set_config_option` — Runtime configuration updates
- `session/{list, clear}_permission` — Sticky permission management

### V2.1 — Bidirectional RPC

Fully implemented:

- `session/request_permission` — Agent → client consent requests with fail-closed semantics
- Cross-process session persistence — Sessions survive across process restarts
- Mixed-content prompt support — Text + images + resource URIs in a single prompt

## Tool Capabilities

Chump exposes 30+ tools grouped by domain:

### Repository Operations
- `repo_read` — Read repository metadata and file lists
- `repo_list_files` — Search and enumerate repository files

### Git Operations
- `git_log` — Query commit history with filtering
- `git_diff` — Generate diffs between commits
- `git_blame` — Trace changes to specific lines
- `git_branch` — List and manage branches

### GitHub API
- `github_pr_create` — Create pull requests
- `github_pr_list` — Query pull requests with filtering
- `github_issue_list` — List and search issues
- `github_check_run_list` — Query CI check status

### Code Analysis
- `code_snippet` — Extract and explain code blocks
- `find_usage` — Find references and usages of symbols

### Web Operations
- `web_search` — Search the web via Tavily or Brave APIs
- `web_fetch` — Fetch and analyze web pages

### Scheduling & Coordination
- `schedule_task` — Enqueue delayed or recurring tasks
- `spawn_subagent` — Delegate work to child agents

### Memory & Context
- `memory_recall` — Retrieve relevant past episodes
- `memory_store` — Save important learnings
- `memory_forget` — Clear forgotten knowledge

## Capabilities Declared to Clients

When initializing a session, Chump declares:

```json
{
  "agentCapabilities": {
    "tools": true,      // Exposes tool calls
    "streaming": true,  // Streams tokens incrementally
    "modes": true,      // Supports semantic modes
    "skills": true      // Exposes skills library (Chump extension)
  }
}
```

Clients that support these capabilities can leverage Chump's full feature set. Clients that don't recognize `skills` simply ignore it.

## Registry Update Process

### Versioning

Registry entries are updated when:

1. **New ACP methods ship** — V2 → V3 migration when ACP spec evolves
2. **Installation paths change** — Homebrew tap URL, cargo crate name, etc.
3. **Capabilities expand** — New tools, new skills, new data types
4. **Major version bumps** — Chump 0.1.0 → 1.0.0 → etc.

### Update Workflow

1. **Modify `/registry-submission/chump/agent.json`** with new metadata
2. **Bump version field** if this is a major update
3. **Update installation instructions** if paths have changed
4. **Test locally** with `chump --acp` against target editors
5. **Submit PR to JetBrains ACP Agent Registry** (if the registry accepts external PRs) OR notify JetBrains maintainers
6. **Update CHANGELOG.md** with registry listing note

### Quarterly Audit

`docs/architecture/ACP_CAPABILITY_COMPARISON.md` should be audited quarterly to ensure Chump's row is current. Update the `last_audited` field and bump `re_audit_due` to 3 months out.

## Testing Registry Integration

### Manual Test — Zed Configuration

Create `~/.config/zed/settings.json`:

```json
{
  "agents": {
    "chump": {
      "command": "chump",
      "args": ["--acp"],
      "env": {}
    }
  }
}
```

Then use `chump` as an agent in Zed's AI assistant.

### Manual Test — JetBrains IDE

1. Install Chump via `brew install chump`
2. Open a JetBrains IDE
3. Go to **Settings** → **Tools** → **Agents** (or **Coding Agents**)
4. Select **Chump** from the available agents
5. Configure as needed; start a session

### CI Testing

Full ACP protocol compliance is tested in `.github/workflows/acp-real-clients.yml`, which replays real Zed and JetBrains messages against the Chump ACP server to verify protocol correctness.

## FAQs

### Q: Can I run Chump remotely?

**A:** Yes. When running over SSH or in a dev container, use the `fs/*` and `terminal/*` methods to delegate filesystem and shell operations to the client's environment. This lets the editor run Chump on a server while file edits happen locally.

### Q: What inference backends does Chump support?

**A:** Default is Ollama. Fallback to vLLM and mistral.rs. Cascade to hosted providers (Anthropic, OpenAI, Gemini) when explicitly configured.

### Q: Does Chump work offline?

**A:** Yes, fully offline deployment is supported. Use Ollama locally and disable cloud fallbacks.

### Q: How do I report a bug or request a feature?

**A:** Open an issue on [GitHub](https://github.com/repairman29/chump/issues) or reach out to @repairman29.

## Related Documentation

- [ACP.md](../architecture/ACP.md) — Full ACP implementation reference
- [ACP_CAPABILITY_COMPARISON.md](../architecture/ACP_CAPABILITY_COMPARISON.md) — Comparison vs other registry agents
- [EXTERNAL_GOLDEN_PATH.md](../process/EXTERNAL_GOLDEN_PATH.md) — Installation and setup guide for external users

## References

- [JetBrains ACP Agent Registry](https://jetbrains.com/acp)
- [Agent Client Protocol Specification](https://agentclientprotocol.com)
- [Chump GitHub Repository](https://github.com/repairman29/chump)
