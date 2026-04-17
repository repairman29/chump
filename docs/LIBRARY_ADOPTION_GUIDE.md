# Using Chump's libraries in your Rust agent

Chump ships (or is extracting) a set of focused crates you can depend on without running Chump itself. Each crate solves one engineering problem that comes up when you build a non-trivial Rust-based AI agent. This guide says which crate solves which problem and shows the minimal code to get started.

## The crates

| Crate | Problem it solves | Status |
|---|---|---|
| [`chump-agent-lease`](../crates/chump-agent-lease/) | Multiple agents edit the same repo in parallel; silent stomps cost hours | ✅ shipped |
| [`chump-mcp-lifecycle`](../crates/chump-mcp-lifecycle/) | MCP servers need per-session spawn + lifecycle + guaranteed reap | ✅ shipped |
| `chump-cognition` | ReAct is thin; your agent wants an active-inference-flavoured substrate | 🚧 extraction in progress |
| `chump-core` | Shared foundation types (Message, Tool, Session, Provider) | 🚧 planned |
| `chump-agent-matrix` | Runtime regression coverage that goes beyond unit tests | 🚧 planned |
| `chump-telemetry` | Energy/joules-per-query metrics on real hardware | 🚧 in-tree, extraction pending |

"In-tree, extraction pending" means the code works today inside the main `rust-agent` binary; the crate boundaries are being drawn so you can depend on just that piece without pulling in the whole agent.

---

## Problem 1 — multiple agents editing the same repo

**Symptom.** Two Claude sessions (or Claude + Cursor, or a bot + a human) both `git add` changes to `src/foo.rs` within minutes of each other. The second commit silently ships the first agent's in-flight work mixed with its own. You find out hours later when a feature you thought was done is half-implemented.

**The fix.** Before editing files, each agent claims the paths it's about to touch. Other agents see the claim and back off.

```toml
[dependencies]
chump-agent-lease = "0.1"
```

```rust
use chump_agent_lease::{claim_paths, release, DEFAULT_TTL_SECS};

fn main() -> anyhow::Result<()> {
    let lease = claim_paths(
        &["src/foo.rs", "src/bar/"],
        DEFAULT_TTL_SECS,
        "refactoring foo for FEAT-042",
    )?;
    // ... do your edits ...
    release(&lease)?;
    Ok(())
}
```

For long-running work, `claim_with_heartbeat` spawns a tokio task that refreshes the lease every N seconds. Set `CHUMP_SESSION_ID=cursor-alice-sprint-42` in your agent's env to give the session a stable name; otherwise a UUID is generated.

The whole protocol is cooperative — a malicious agent can ignore leases. For an enforcement floor, pair this with a git pre-commit hook (see `scripts/git-hooks/pre-commit` in the Chump repo) that rejects commits touching another session's claimed paths.

## Problem 2 — MCP servers need proper lifecycle

**Symptom.** You implement the [Model Context Protocol](https://modelcontextprotocol.io) naively — spawn a child process per `tools/call`, close stdin, wait for stdout, repeat. Simple MCP servers (calculators) work. Any server that does warm-up (embedding indexes, loaded models, DB connections) pays the warm-up cost every single call and your agent feels like cold molasses.

You also notice that on `session/cancel` or agent crash, MCP child processes don't always die. `ps aux | grep mcp-server` shows ghosts from last Tuesday.

**The fix.** Use persistent per-session children with a `Drop` cascade that guarantees reap.

```toml
[dependencies]
chump-mcp-lifecycle = "0.1"
```

```rust
use chump_mcp_lifecycle::SessionMcpPool;
use serde_json::json;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Spawn every MCP server your session needs. Tool metadata is pulled
    // from each server's `tools/list` response and indexed by tool name.
    let pool = SessionMcpPool::spawn_all(&[
        ("filesystem".into(), "mcp-server-filesystem".into(), vec!["--path=/".into()]),
        ("browser".into(), "mcp-server-browser".into(), vec![]),
    ]).await?;

    println!("spawned {} tools across {} servers",
             pool.tool_count(), pool.server_count());

    // Route a tool call to the server that owns the tool.
    let result = pool.call_tool("read_file", json!({"path": "README.md"})).await?;
    println!("{}", serde_json::to_string_pretty(&result)?);

    // Drop the pool → every child gets SIGKILL via the Drop cascade.
    // Or call `pool.shutdown().await` for a graceful version.
    Ok(())
}
```

Every `PersistentMcpServer` has `kill_on_drop(true)` set as a safety net plus a synchronous `start_kill()` in its `Drop`. Even if your process panics mid-session, the children die with it.

Hard cap at 16 children per pool (`MAX_SERVERS_PER_SESSION`) so a malicious client can't fork-bomb your host.

## Problem 3 — your agent needs a cognitive substrate beyond ReAct

**Status.** In-tree in `src/` as of 2026-04-17. Extraction to `chump-cognition` is tracked as M3 in [`RUST_AGENT_STANDARD_PLAN.md`](./RUST_AGENT_STANDARD_PLAN.md).

**The pitch.** ReAct is a two-step loop — think, act, think, act. Real agents benefit from richer internal state:

- **Neuromodulation** — scalar state (dopamine / noradrenaline / serotonin-like) that shifts temperature, top_p, and tool selection thresholds based on recent task outcomes.
- **Precision controller** — regime switching (Explore / Exploit / Balanced / Conservative) driven by recent surprisal EMA. An agent in a high-surprisal regime widens its search; an agent in a low-surprisal regime exploits.
- **Belief state** — task uncertainty estimation that gates when the agent asks for clarification vs plows ahead.
- **Surprise tracker** — tool-outcome prediction error; input to the precision controller.
- **Blackboard** — global-workspace shared salience buffer across modules.

Preview of the planned API (subject to change during extraction):

```rust
use chump_cognition::{Neuromodulation, PrecisionController, BeliefState};

let substrate = chump_cognition::substrate();
substrate.neuromod.record_turn_success();
substrate.belief.update(uncertainty_estimate);
let regime = substrate.precision.current_regime();
```

See [`docs/CONSCIOUSNESS_AB_RESULTS.md`](./CONSCIOUSNESS_AB_RESULTS.md) for A/B data on whether this actually helps.

## Problem 4 — provider routing by learned reward, not hand-config

**Status.** In-tree as `src/provider_bandit.rs`. Crate extraction TBD based on demand.

**The pitch.** A hand-configured cascade ("try Groq first, then Cerebras, then local") can't adapt to workload mix. `src/provider_bandit.rs` implements Thompson Sampling + UCB1 over slot names with composable reward (success + latency + tokens/sec).

```rust
// Today (in-tree):
use chump::provider_bandit::{BanditRouter, BanditStrategy};

let router = BanditRouter::new(
    vec!["groq".into(), "cerebras".into(), "local".into()],
    BanditStrategy::ThompsonSampling,
);
let pick = router.select().unwrap();
// ... run inference on `pick` ...
router.update(&pick, reward); // reward ∈ [0, 1]
```

If you want to use this from outside Chump today, copy `src/provider_bandit.rs` — it's dep-free (just `rand`). File an issue and we'll extract it as a crate.

## Problem 5 — runtime regressions unit tests can't catch

**Status.** In-tree as `scripts/dogfood-matrix.sh`. Scenario definitions ported into a Rust crate are planned as `chump-agent-matrix`.

**The pitch.** Your agent's `cargo test` is green. Meanwhile a production release crashes because `read_file` hit an MCP server lifecycle bug that only surfaces during a real agent turn. The matrix runs your agent end-to-end with real LLM calls and flags regressions before users see them.

## Problem 6 — energy per query, not just latency

**Status.** In-tree as `src/telemetry_energy.rs`. Crate extraction TBD.

**The pitch.** On a 24 GB MacBook running a 9 B 4-bit model, latency and tokens/sec are proxies. Joules-per-query is the real battery-life and thermal-budget metric. Chump's telemetry module ships a working `ApplePowermetricsMonitor` that reports joules, watts, temperature, and GPU utilization per monitoring window. OpenJarvis has the same trait shape but their NVIDIA monitor is a stub.

```rust
// Today (in-tree):
use chump::telemetry_energy::{auto_detect, EnergyMonitor};

let mut m = auto_detect();
m.start();
// ... run a query ...
let r = m.stop();
println!("{:.1} J over {:.1} s ({:.1} W peak, GPU {:.0}°C, util {:.0}%)",
         r.energy_joules, r.duration_secs,
         r.power_watts, r.gpu_temperature_c, r.gpu_utilization_pct);
```

---

## How to request a new extraction

If you want to depend on something that's still in-tree:

1. **File an issue** at `github.com/repairman29/chump/issues` with the module name + your use case.
2. **Or, even better, open a PR** that does the extraction. The pattern is documented in [`RUST_AGENT_STANDARD_PLAN.md`](./RUST_AGENT_STANDARD_PLAN.md): new crate under `crates/`, move the code, add a re-export shim at the old path so nothing else breaks, add to the workspace, ship.

Extraction priority is set by observed demand: modules three different users want become crates faster than modules one user wants.

## Versioning policy

Published crates follow semver strictly. Pre-1.0 (where we'll sit for a while) means minor bumps may break source compat, patch bumps never do. We document breaking changes in each crate's `CHANGELOG.md`.

## License

All Chump crates are MIT. Their dependencies are MIT or Apache-2.0. Safe to build proprietary code on.
