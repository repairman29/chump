# chump-ambient-cli

Schema-enforced, multi-writer, append-only structured telemetry for local-first apps. No collector. No daemon. No SaaS.

One JSONL file, one event per line, kind-discriminated, atomic-append safe. The schema registry is the gate — downstream tooling never has to defend against tag explosion because emit-time enforces the contract.

This crate was extracted from the [Chump fleet](https://github.com/repairman29/chump), where it has carried millions of multi-process events across dozens of concurrent worker sessions on a single laptop.

---

## Why this exists

Solo devs and local-first apps can't afford Datadog / Honeycomb / Sentry, and OpenTelemetry's collector is a brick. The Chump fleet needed structured telemetry that:

- runs on a laptop with no broker, no daemon, no DNS
- survives concurrent writers (dozens of agent processes appending at the same time)
- has a single, queryable, grep-able source of truth
- enforces schema **at emit time** so dashboards never see malformed events

The answer was 2,000 lines of Rust writing one file: `.chump-locks/ambient.jsonl`. This crate is that, lifted out.

---

## CLI

```bash
# Append a structured event
ambient emit cycle_end --field rc=0 --field used_ms=842 --gap INFRA-1234

# Tail recent events (raw JSONL)
ambient tail
ambient tail --lines 200 --kind cycle_end
ambient tail --path /custom/path/ambient.jsonl

# Discovery: walks up from CWD looking for .chump-locks/ambient.jsonl
# Override with CHUMP_AMBIENT_LOG.
```

Pipe `ambient tail` into `jq` for ad-hoc analysis:

```bash
ambient tail --lines 1000 | jq -r 'select(.kind=="cycle_end") | .used_ms' \
  | awk '{s+=$1; n++} END {print "avg:", s/n, "ms"}'
```

---

## Library

```rust
use chump_ambient_cli::ambient_emit::{emit, EmitArgs};

let args = EmitArgs {
    kind: "build_finished".into(),
    fields: vec![
        ("status".into(), "green".into()),
        ("duration_ms".into(), "12480".into()),
    ],
    ..Default::default()
};
emit(&args)?;
```

The `EmitArgs` struct also accepts `ambient_override: Option<PathBuf>` and `session_override: Option<String>` for tests and explicit-path callers.

---

## The shape of an event

```json
{"ts":"2026-05-22T22:14:31Z","session":"my-app-1779487071","worktree":"my-app","harness":"manual","event":"build_finished","status":"green","duration_ms":"12480"}
```

- `ts` — RFC3339 UTC, always injected
- `session` — resolves `CHUMP_SESSION_ID` > `CLAUDE_SESSION_ID` > worktree cache > auto-derived
- `worktree` — basename of repo root
- `harness` — `--harness` flag > `CHUMP_AGENT_HARNESS` env > `"unknown"`
- `event` — the positional `<kind>` argument
- everything else — your `--field key=value` pairs, order-preserved

---

## The differentiator: schema-at-emit-time

The Chump fleet runs `docs/observability/EVENT_REGISTRY.yaml` as the source of truth. Every `kind=X` is registered with its required fields. CI fails when a new emit site uses a kind not in the registry, or omits a required field.

This sounds like ceremony, but it is the entire point. It is why we don't need a typed schema language, a SaaS dashboard, or a query planner — `jq` and `grep` are enough because every line obeys the contract.

If you want to adopt this pattern, copy `EVENT_REGISTRY.yaml` from chump as a starting point, or write your own. The crate doesn't enforce a specific registry — it gives you the atomic-append substrate; the registry contract is your downstream choice.

---

## Multi-writer safety

POSIX guarantees atomic appends to an `O_APPEND` file descriptor when each write is under `PIPE_BUF` (4096 bytes). Events are sized for this — typical lines are 200-400 bytes including all extra fields, and the crate returns an error if you ever produce a line that approaches the cap.

A stress test in `tests/` spawns 8 threads × 50 emits and verifies the resulting 400 lines are each individually valid JSON, no interleaving. This is how the Chump fleet keeps dozens of concurrent worker processes' telemetry coherent on a single file.

---

## Environment

| Variable | Purpose |
|---|---|
| `CHUMP_AMBIENT_LOG` | Override the ambient log path. |
| `CHUMP_REPO_ROOT` | Override repo discovery (else `git rev-parse --show-toplevel`). |
| `CHUMP_SESSION_ID` | Override session ID (otherwise auto-resolved). |
| `CHUMP_AGENT_HARNESS` | Default harness name when `--harness` is not passed. |

---

## Install

```bash
cargo install --path crates/ambient-cli       # from a chump checkout
# or once published:
cargo install chump-ambient-cli
```

---

## License

MIT. See [LICENSE](../../LICENSE) at the repo root.
