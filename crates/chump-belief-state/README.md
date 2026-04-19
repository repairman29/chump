# chump-belief-state

Per-tool reliability beliefs + task-level uncertainty for LLM agents, modeled as Beta(α, β) distributions and updated each turn via Bayesian inference.

The agent maintains:

- **Per-tool belief** — `ToolBelief { alpha, beta, latency_mean_ms, latency_var_ms }` per tool, updated on every call (success → α += 1, failure → β += 1, plus running latency stats)
- **Task-level belief** — `TaskBelief { confidence, ambiguity, trajectory_certainty }` updated each turn from perception + tool outcomes

These beliefs feed Expected Free Energy scoring (which tool to call next given current uncertainty), epistemic escalation (when to ask the user vs. retry), and trajectory replanning (when to abandon the current plan).

## Why a separate crate

The "agent maintains a typed belief about each tool's reliability and updates it Bayesian-style" pattern is generally useful — any agent framework that selects between multiple tools benefits from this. Pure data + math, no I/O, easy to wire into any orchestrator.

Part of the Synthetic Consciousness Framework (Section 2.1 of CHUMP_TO_COMPLEX.md in the parent repo) but the math itself is independent of the framework.

## Install

```bash
cargo add chump-belief-state
```

## Use

```rust
use chump_belief_state::{ToolBelief, TaskBelief};

// Per-tool: track reliability over time
let mut tb = ToolBelief::new();
tb.update(true, 50.0);  // call succeeded in 50ms
tb.update(true, 60.0);
tb.update(false, 200.0); // call failed
println!("p(success) ≈ {:.2}", tb.success_rate());

// Per-task: track agent's confidence in current trajectory
let task = TaskBelief {
    confidence: 0.7,
    ambiguity: 0.3,
    trajectory_certainty: 0.5,
};
println!("Should escalate: {}", task.should_escalate());
```

## API

| symbol | what |
|--------|------|
| `ToolBelief` | Beta(α, β) success belief + latency stats |
| `TaskBelief` | per-turn task uncertainty fields |
| `update(success, latency_ms)` | apply one observation |
| `success_rate() -> f64` | mean of the Beta posterior |
| `metrics_json() -> Value` | serialize for telemetry/blackboard |
| (free fns) | `record_*`, `current_*` for the global registry |

`Serialize`/`Deserialize` on both structs so they round-trip JSON freely.

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo, where it powers the agent loop's per-turn belief update and EFE-based tool selection)

## License

MIT.

## Companion crates

- [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) — multi-agent file-coordination leases
- [`chump-cancel-registry`](https://crates.io/crates/chump-cancel-registry) — request-id-keyed CancellationToken store
- [`chump-cost-tracker`](https://crates.io/crates/chump-cost-tracker) — per-provider call/token + budget warnings
- [`chump-perception`](https://crates.io/crates/chump-perception) — rule-based perception layer
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — per-session MCP server lifecycle
- [`chump-tool-macro`](https://crates.io/crates/chump-tool-macro) — proc macro for declaring agent tools
