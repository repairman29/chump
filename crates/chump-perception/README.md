# chump-perception

Structured perception layer for LLM agents. Runs rule-based extraction on raw user input and produces a typed `PerceivedInput` struct with:

- **Entities** — capitalized words, quoted strings, file paths, version numbers
- **Constraints** — "must", "before", "cannot", "exactly N" markers
- **Risk indicators** — destructive verbs ("delete", "force-push"), urgency words
- **Ambiguity score** (0.0 – 1.0) — heuristic over question count, entity scarcity, vague pronouns
- **Question count** — `?` density
- **Task type** — `Question`, `Action`, `Planning`, `Research`, `Meta`, `Unclear`

No LLM calls. Pure pattern-matching, ~100µs per call.

## Why a separate crate

The reference architecture pattern of "perceive → reason → act" is general. Any agent framework benefits from a structured pre-reasoning view of the input that downstream code can branch on (clarify when ambiguity > 0.7, refuse when risk > 0, choose tool budget by task_type, etc.). This crate ships that layer in isolation so it can be reused outside `chump`.

## Install

```bash
cargo add chump-perception
```

## Use

```rust
use chump_perception::{perceive, TaskType};

let p = perceive("delete src/foo.rs", /* needs_tools_hint */ true);
assert!(p.risk_indicators.iter().any(|r| r == "delete"));
assert_eq!(p.task_type, TaskType::Action);
assert!(p.ambiguity_level < 0.5);

let q = perceive("what was that thing?", false);
assert_eq!(q.task_type, TaskType::Question);
assert!(q.ambiguity_level > 0.5);
```

## API

| symbol | what |
|--------|------|
| `perceive(text, needs_tools_hint) -> PerceivedInput` | the main entry point |
| `PerceivedInput` | struct with all extracted fields |
| `TaskType` | enum: Question / Action / Planning / Research / Meta / Unclear |
| `context_summary(p) -> String` | one-line digest suitable for injection into a system prompt |

Implements `serde::Serialize` for both `PerceivedInput` and `TaskType` so they round-trip through JSON / blackboard / log.

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo, where it powers the agent-loop pre-reasoning step)
- 9 unit tests cover the major code paths (entity extraction, risk detection, ambiguity scoring, task classification)

## License

MIT.

## Companion crates

- [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) — multi-agent file-coordination leases
- [`chump-cancel-registry`](https://crates.io/crates/chump-cancel-registry) — request-id-keyed CancellationToken store
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — per-session MCP server lifecycle
- [`chump-tool-macro`](https://crates.io/crates/chump-tool-macro) — proc macro for declaring agent tools
