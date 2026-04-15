# Dogfood Run Log

## Run 1 — T1.1: Replace `.expect()` in `src/policy_override.rs`

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Model** | Local 7B (via Ollama) |
| **Task** | T1.1 — Replace `.expect()` on mutex locks in policy_override.rs |
| **Score** | **FAIL** |
| **Duration** | ~27s (1 model call) |

### What happened

The model emitted text-format tool calls — the parser fix from `442c121` successfully detected the pattern. However two problems:

1. **Two calls on one line**: The model put `call run_cli with {...}; call write_file with {...}` on a single line separated by `;`. The parser processes line-by-line, so it tried to parse the entire line as one call. The JSON extraction failed because `{...}; call write_file...` is not valid JSON.

2. **Hallucinated file content**: Instead of reading `policy_override.rs` first, the model fabricated entirely new file content (a generic mutex example, not the actual file). This would have destroyed the file if the tool had executed.

### Result

`tool_calls_count: 0` — no tools were dispatched. The model got one turn, failed to execute any tools, and the turn completed.

### Findings for improvement

- **P1**: Parser should split on `;` before matching, or handle multiple calls per line.
- **P2**: 7B model needs stronger system prompt guidance: "Always read a file before writing it."
- **P3**: Consider adding a `read_before_write` guardrail in tool middleware that rejects `write_file` calls for paths not previously read in the session.
- **P4**: The duplicate `"call "` prefix on lines 238 and 244 of `agent_loop.rs` should be cleaned up (harmless but confusing).

---

## Run 2 — T1.1 (retry): CLI panic in policy_override.rs

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 — Replace `.expect()` on mutex locks |
| **Score** | **FAIL** (crash) |
| **Duration** | <1s |

### What happened

CLI mode (`--chump`) panicked at `policy_override.rs:110`: `cannot access a task-local storage value without setting it first`. The `RELAX_TOOLS` task-local was only initialized in the web path (`relax_scope`), not in CLI mode.

### Fix applied

Changed `.with()` to `.try_with().unwrap_or(false)` in `session_relax_active_for_tool()` (commit `eafb5e4`).

---

## Run 3 — T1.1 (retry): Tool approval timeout

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 via web API |
| **Score** | **FAIL** (timeout) |
| **Duration** | ~27s |

### What happened

Via the web API, tools were dispatched (`run_cli`, `write_file`) but blocked on human approval. Nobody clicked "approve" in the PWA, so both timed out. This is correct web behavior but wrong for dogfood.

### Fix applied

Added `CHUMP_AUTO_APPROVE_TOOLS` and `CHUMP_AUTO_APPROVE_LOW_RISK=1` to `dogfood-run.sh` (commit `87be6f1`).

---

## Run 4 — T1.1 (retry): bare `tool_name {json}` not parsed

| Field | Value |
|-------|-------|
| **Date** | 2026-04-15 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 |
| **Score** | **FAIL** (parser gap) |
| **Duration** | ~20s |

### What happened

Model output `read_file {"path": "src/policy_override.rs"}` — bare tool name + space + JSON. Parser only handled `tool_name({json})` (parens) and prefix patterns. No match.

### Fix applied

Added bare `tool_name {json}` pattern to parser (commit `87be6f1`).

---

## Run 5 — T1.1 (retry): Tools dispatching!

| Field | Value |
|-------|-------|
| **Date** | 2026-04-15 |
| **Model** | Qwen2.5-7B-Instruct-4bit |
| **Task** | T1.1 |
| **Score** | **PARTIAL** |
| **Duration** | ~30s (3 model calls, 324 tokens) |

### What happened

The agent loop is working:
1. Model called `read_file` — **dispatched and executed successfully**
2. Model read the file contents
3. Model generated a diff attempting to replace `.expect()` with `.map_err()`
4. But the diff wasn't properly structured as a `patch_file` tool call — it was output as raw text

### Remaining issues

- Model generates diffs as text rather than calling `patch_file` with structured JSON input
- Only targeted one `.expect()` instance (repeated same diff twice)
- Didn't add `?` operator after `.map_err()`

### Assessment

First successful multi-turn tool use in dogfood! The infrastructure is working. The 7B model just needs better prompting to use `patch_file` with the right input schema.
