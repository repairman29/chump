# chump-cost-tracker

Tiny per-session cost visibility for LLM agents. Atomic counters for:

- Tavily web-search calls + credits
- Model completion request count
- Input + output token totals
- Per-provider breakdown (calls + estimated output tokens)

Plus optional session-budget warnings via two env vars:
- `CHUMP_SESSION_BUDGET_TAVILY` — credit limit
- `CHUMP_SESSION_BUDGET_REQUESTS` — request limit

When a counter exceeds the configured budget, the next `record_*` call returns a `BudgetWarning` so the orchestrator can inject the warning into the agent's next prompt.

## Why a separate crate

This is the lightest possible cost-attribution layer for any agent that talks to a paid LLM API. Pure std, atomic counters, ~115 LOC. Pair with a richer ledger (e.g. file-based JSONL) when you need per-call audit; this crate is for the always-on-cheap aggregate view.

Different from the Python `cost_ledger.py` shipped alongside in the parent `chump` repo:
- The Python ledger is per-call, file-backed, queryable via CLI
- This Rust crate is in-process, atomic, queried via function call
- Both have their place — use this one for the running tally inside the agent process

## Install

```bash
cargo add chump-cost-tracker
```

## Use

```rust
use chump_cost_tracker as cost;

cost::record_completion(/* requests */ 1, /* input_tokens */ 500, /* output_tokens */ 200);
cost::record_tavily(/* calls */ 1, /* credits */ 1);
cost::record_provider_call("anthropic", 250);

let summary = cost::current_summary();
println!("Spent: {} model requests, {} input tokens, {} output tokens",
    summary.model_requests, summary.model_input_tokens, summary.model_output_tokens);
```

## API

| symbol | what |
|--------|------|
| `record_completion(req, in, out)` | bump model request + token counters |
| `record_tavily(calls, credits)` | bump Tavily call + credit counters |
| `record_provider_call(name, est_tokens)` | bump per-provider counters |
| `current_summary() -> CostSummary` | snapshot of all counters |
| `reset()` | zero everything (test-only typically) |
| (TBD in v0.2) `BudgetWarning` returned when env-var thresholds exceeded |

## Status

- v0.1.0 — initial publish (extracted from the [`chump`](https://github.com/repairman29/chump) repo)

## License

MIT.

## Companion crates

- [`chump-agent-lease`](https://crates.io/crates/chump-agent-lease) — multi-agent file-coordination leases
- [`chump-cancel-registry`](https://crates.io/crates/chump-cancel-registry) — request-id-keyed CancellationToken store
- [`chump-perception`](https://crates.io/crates/chump-perception) — rule-based perception layer
- [`chump-mcp-lifecycle`](https://crates.io/crates/chump-mcp-lifecycle) — per-session MCP server lifecycle
- [`chump-tool-macro`](https://crates.io/crates/chump-tool-macro) — proc macro for declaring agent tools
