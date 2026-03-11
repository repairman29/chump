# Chump Playbook — Knowing What to Reach For

The problem: Chump has 30+ CLI tools, 15+ native tools, and `run_cli` as a fallback. Without structure, he'll default to whatever the model saw most in training (`grep`, `curl`, `cat`) instead of the sharper tool. This doc defines the **decision architecture** — how Chump knows what to use when, and how that knowledge improves over time.

---

## The Three Layers

### Layer 1: The Routing Table (system prompt)

A compact **situation → tool** map injected into the system prompt. This is Chump's fast-path: pattern-match the task, pick the tool, no thinking required. Fits in ~800 tokens.

**Implementation:** `src/tool_routing.rs` detects installed CLI tools at startup (`which` calls, cached in `OnceLock`), generates a routing table string, and it is appended to the soul in `chump_system_prompt()`. Only installed tools are suggested; fallbacks (e.g. grep when rg missing) are included. Tool inventory is logged once per process via `log_tool_inventory()`.

### Layer 2: The Wiki (chump-brain/tools/)

Per-tool docs Chump writes and updates himself. When the routing table says "use X" but he hasn't used X recently, he reads his own notes. This is where flags, gotchas, and hard-won patterns live.

Seed from **docs/tools_index.md** (copy to `chump-brain/tools/_index.md`). Chump updates it when he installs, learns, or drops a tool. Per-tool notes: `tools/ripgrep.md`, `tools/jq.md`, etc.

### Layer 3: Memory (episode + memory store)

Past experience. "Last time I parsed cargo test output with grep it missed the compile error." Memory recall surfaces these when the situation matches. This layer is automatic — it grows as Chump works.

---

## Layer 1: The Routing Table (detail)

The routing table is **not** hardcoded in the soul string. At startup:

1. `tool_routing::tools()` runs (cached): runs `which` for each CLI binary (rg, fd, jq, cargo-nextest, etc.).
2. `routing_table()` builds a string with sections: SEARCH CODE, READ/EDIT CODE, TEST, QUALITY, GIT, DATA PROCESSING, WEB/RESEARCH, SYSTEM, TASK MANAGEMENT, SELF, RULES.
3. The system prompt builder appends this table after the brain block, so Chump always sees an accurate situation→tool map.

Rules in the table:
- Native tool > run_cli (when both can do it)
- Specialized CLI > generic (rg > grep, jq > grep on JSON, fd > find)
- Before complex CLI ops, check memory_brain tools/<name>.md

---

## Layer 2: The Wiki

Chump maintains per-tool notes in `chump-brain/tools/` (or `CHUMP_BRAIN_PATH/tools/`).

- **_index.md** — master list: tool, category, installed, one-liner. Update when you run `verify-toolkit.sh` or after discovery.
- **ripgrep.md, jq.md, cargo-nextest.md, ...** — usage patterns, flags, gotchas.

When to write:
1. First use of a new tool — write a brief note after using it.
2. Discovery rounds — when Chump installs a new tool, he writes the initial doc.
3. After a gotcha — if a tool behaves unexpectedly, update the doc (episode sentiment: frustrating).
4. Opportunity round prompt can say: "If you used a CLI tool in a way that surprised you, update memory_brain tools/<name>.md."

When to read:
- Complex operations (e.g. multi-step jq pipeline) → read tools/jq.md first.
- Unfamiliar tool (routing says "use ast-grep" but haven't used it in a while) → read tools/ast-grep.md.

---

## Layer 3: Memory (Automatic)

Tag tool-related learnings so recall surfaces them:
- Source: `chump_tools` or `chump_self`
- Content includes the tool name for keyword recall

---

## The Decision Flow

When Chump faces a task:

1. **MATCH** the task shape against the routing table (in system prompt) → e.g. "find where X is called" → rg via run_cli.
2. **CHECK** availability — routing table already filtered at startup; fallbacks shown if missing.
3. **RECALL** relevant memory (proactive recall).
4. **OPTIONALLY** read wiki for complex or unfamiliar operations.
5. **EXECUTE** with the best tool and flags.
6. **LEARN** from the result (store gotchas, update wiki if surprised).

---

## Summary

| Layer         | What            | When consulted              | Who maintains it | Update frequency      |
|---------------|-----------------|-----------------------------|------------------|------------------------|
| Routing table | Situation→tool  | Every tool call (in prompt) | Code (startup)   | Once per process start |
| Wiki          | Per-tool docs   | Complex/unfamiliar ops     | Chump            | Ongoing                |
| Memory        | Past experiences| Automatic (recall)         | Chump            | Every session          |
