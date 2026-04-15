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
