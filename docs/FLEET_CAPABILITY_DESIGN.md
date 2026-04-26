---
doc_tag: decision-record
owner_gap:
last_audited: 2026-04-25
---

# Fleet capability schema (FLEET-009)

**Status:** shipped local-first 2026-04-24. Transport (NATS / WS) is a future
gap — deliberately deferred (see "Transport choice" below).

## Why structured capabilities

`fleet::FleetPeer` already has `capabilities: Vec<String>` — free-form tags
like `["rust", "git", "docker"]`. That works for human-readable status, but
it does not let an agent answer "**should I claim this work?**" because:

- "rust" tells you nothing about VRAM, throughput, or context length.
- A 4 GB Pi cannot run a 70B model just because it has the `"rust"` tag.
- Without numeric floors, fit-scoring is impossible — every agent claims
  every task or none.

`fleet_capability::AgentCapability` adds the four scalars that actually
matter when allocating LLM work:

| Field | Why it matters |
|---|---|
| `model_family`, `model_name` | Hard match — qwen-coder ≠ llama. |
| `vram_gb` | Hard floor — model won't load. |
| `inference_speed_tok_per_sec` | Soft floor — affects timeout budget. |
| `supported_task_classes` | Hard match — agent has been tested on this class. |
| `reliability_score` | Soft signal — past success rate, defaults `0.5`. |

## fit_score()

```
0.40 * task_class_match    (hard)
0.30 * reliability_score   (soft, [0,1])
0.20 * vram_headroom       (saturates at 2× floor)
0.10 * speed_headroom      (saturates at 2× floor)
```

Hard misses (model family, VRAM, class) short-circuit to `0.0`. The
`CLAIM_THRESHOLD = 0.5` means an agent must *either* be a class match with
average reliability *or* show meaningful headroom. Tunable; the constant
lives in `fleet_capability.rs`.

The acceptance test (`two_agents_only_one_claims`) demonstrates the
behavior: two agents, mismatched VRAM, only the larger one claims.

## Local-first persistence

Each agent writes its capability to:

```
.chump-locks/capabilities/<agent_id>.json
```

`publish_local()` writes atomically via tmp-file + rename. `read_all_local()`
returns every agent's capability, silently skipping malformed files (logged
to stderr). Same coordination idiom as the existing `.chump-locks/*.json`
lease files — peer agents see updates within filesystem latency.

## Transport choice (deferred — see strategy note)

The FLEET-009 description specifies `NATS topic "chump/agent-capabilities"`.
We are **not** wiring NATS in this PR. Reasons captured in the strategy note
(2026-04-24 conversation):

1. The deployed fleet (Mac ↔ Pixel "Mabel" ↔ cloud) already runs over
   Tailscale + SSH + WebSocket — not NATS.
2. NATS pays its dividends at scale that Chump's mesh has not reached
   (broker ops, JetStream durability, multi-subscriber fan-out beyond ~10
   peers).
3. Migrating local-first → WebSocket → NATS is a transport swap behind a
   future `FleetTransport` trait, **not** a schema rewrite. The
   `AgentCapability` JSON is the wire format; whatever pushes it is
   replaceable.

When the next FLEET gap (006 / 007) lands, it will define the trait and
wrap `publish_local` / `read_all_local` as the local-fs implementation.

## What this PR does NOT do

- **No transport layer.** Capabilities are fs-only this round.
- **No fleet_db migration.** The legacy `Vec<String>` `capabilities` on
  `FleetPeer` is left alone. A follow-up gap can either populate both or
  derive the legacy field from the structured one.
- **No reliability tracking.** `reliability_score` defaults to `0.5`; a
  separate gap (or COG-016 reflection-loop wiring) updates it from observed
  outcomes.

## Acceptance criteria mapping (FLEET-009)

| Criterion | Status |
|---|---|
| Capability schema defined and documented | ✅ `fleet_capability::AgentCapability` + this doc |
| Task requirement schema defined and documented | ✅ `fleet_capability::TaskRequirement` |
| `fit_score()` (≥ model_family, vram, task_class) | ✅ also includes speed + reliability |
| Agent publishes capability on startup (NATS topic) | ⚠️ deferred — local-fs publish only; NATS is a future gap |
| Filter work board by `fit_score >= 0.5` | ✅ `should_claim()` + `CLAIM_THRESHOLD` |
| Test: two agents, mismatched, only one claims | ✅ `two_agents_only_one_claims` |

The single deferred item is the NATS topic name. Captured here, called out
in the strategy note, and the schema is wire-ready when transport lands.
