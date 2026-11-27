---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# IDE & Terminal Multi-Agent Workflows

**Audience:** Developers combining IDE agents (**Cursor**, **Zed**, **JetBrains**, **VS Code**) with terminal agents (**Claude Code**, **Codex CLI**, **OpenCode**, **Aider**, **goose**) against one shared git repository.

Chump is harness-agnostic: you do not have to replace your favorite editor or coding CLI to get collision-free file leases and pre-commit guardrails.

---

## 1. Golden Rules Across All Tools

1. **One `CHUMP_SESSION_ID` per concurrent agent:** Every IDE window or terminal worker must have its own session identity so `.chump-locks/<session>.json` accurately tracks who owns which paths. (`chump claim` generates a unique session ID and isolated worktree automatically.)
2. **Work inside claimed worktrees:** Keep your main checkout cleanly on `main` for reading/reviewing, and let each active task build and commit inside the linked worktree created by `chump claim <GAP-ID>`.
3. **Never bypass `chump hook`:** Do not run `git commit --no-verify` when `LeaseCollisionGuard` or `SecretPatternGuard` fires. Surface the conflict and narrow your file scope instead.

---

## 2. Side-by-Side Workflow Example (IDE + Terminal Agent)

Suppose you are editing frontend UI in **Cursor** or **Zed** while **Claude Code** or **OpenCode** refactors a Rust backend crate in a terminal:

```bash
# Terminal 1 — Claim backend scope for your CLI agent
chump gap reserve --domain INFRA --title "Add retry jitter to HTTP client" --effort s
chump claim INFRA-101 --role target --paths "crates/chump-http/**"
cd /tmp/chump-infra-101
claude   # or opencode / codex / aider

# Terminal 2 — Claim UI scope for your IDE session
chump gap reserve --domain PRODUCT --title "Update latency chart tooltip" --effort xs
chump claim PRODUCT-102 --role target --paths "web/site/**"
cursor /tmp/chump-product-102   # or zed / idea
```

Both sessions commit, run `chump preflight`, and ship independent PRs via `chump ship` without ever colliding on staged files or `HEAD`.

---

## 3. MCP Coordination Server (`chump-mcp-coord`)

For MCP-enabled editors (**Cursor**, **Zed**, **Claude Desktop**, **Windsurf**), `chump-mcp-coord` exposes Chump's coordination primitives directly over JSON-RPC stdio (`CHUMP_REPO=/path/to/repo`):

- `gap_preflight` — check whether a task ID is open and claimable
- `gap_claim_lease` — acquire a path lease from inside the editor chat
- `lease_list_active` — inspect which files sibling agents currently own
- `ambient_tail` — read recent `ambient.jsonl` coordination events

For full editor-native agent execution over the open Agent Client Protocol (**Zed** and **JetBrains IDEs**), launch `chump --acp` directly—see [Editor Integration (ACP)](../architecture/ACP.md).

---

## 4. Delegating Bounded Subtasks

When a parent IDE session delegates work to a background CLI agent or subagent:

1. **Single deliverable:** Specify one concrete goal, the exact `GAP-ID`, and the worktree directory.
2. **Explicit path boundary:** List the leased paths and forbid drive-by edits outside that list.
3. **Local verification command:** Require `chump preflight` (or exact `cargo test` / `pytest` / `npm test` commands) before reporting completion.
4. **Clean handback:** Return the branch name, commit SHA / PR URL, test summary, and remaining checklist items.

---

## 5. Session & Path Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHUMP_SESSION_ID` | Auto-generated per `chump claim` | Unique identifier for the current agent session's lease and `ambient.jsonl` events. |
| `CHUMP_HOME` | `~/.chump` (`%USERPROFILE%\.chump` on Windows) | Base directory for `config.toml`, OAuth token cache, and supervisor state. |
| `CHUMP_REPO` | Current git repository root | Explicit repository root override for MCP servers and background tools. |
| `CHUMP_LOCK_DIR` | `<repo>/.chump-locks` | Directory holding active lease JSON files (must match across all sessions in one repo). |
| `CHUMP_AMBIENT_LOG` | `<repo>/.chump-locks/ambient.jsonl` | Path to the append-only coordination event stream. |

---

## See Also

- [File Leases & Worktrees](AGENT_COORDINATION.md)
- [Editor Integration (ACP)](../architecture/ACP.md)
- [Shared Services](CANONICAL_SERVICES.md)
