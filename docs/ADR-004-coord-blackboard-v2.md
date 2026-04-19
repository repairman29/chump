# ADR-004: NATS KV Distributed Blackboard (Coordination v2)

**Status:** proposed  
**Date:** 2026-04-19  
**Context:** This ADR documents the target production architecture for multi-agent
coordination, following the v1 bash-level system shipped in `claude/coord-musher`
(PR #113). It is intentionally forward-looking — the bash system is correct in
architecture and sufficient for the current scale (≤5 agents). This document
records *what to build when we outgrow it*, not what to build today.

---

## The problem v1 solves (and where it strains)

The v1 system (`.chump-locks/*.json` + `ambient.jsonl` + `musher.sh`) addresses
the core stomp problem with:

- **Lease files** — session-scoped JSON files with gap_id and heartbeat timestamp
- **Ambient stream** — append-only event log (INTENT, DONE, STUCK, ALERT)
- **Musher dispatch** — classifies each gap as available/claimed/intended/conflict
- **Intent window** — broadcast INTENT, sleep 3s, then write lease

Known limitations of this design:

| Limitation | Impact | Threshold where it matters |
|---|---|---|
| 3-second sleep is a probabilistic race fix, not atomic | Two agents broadcasting INTENT in the same second still collide | > 3 concurrent sessions picking simultaneously |
| Lease TTL enforced by heartbeat-stale detection, not hard TTL | Stale lease holds a gap for up to 15 min after session dies | Any session crash |
| `musher.sh --pick` re-scans all state on every call | ~150ms bash startup × N agents = visible latency | > 10 calls/minute |
| File locking doesn't span machines | Agents on different hosts have separate `.chump-locks/` dirs | Multi-machine deployments |
| `ambient.jsonl` grows unbounded | Tail-300 misses events in high-traffic sessions | > 300 events/session |
| No real-time watchers | Agents poll; can't react to a lease drop < next poll cycle | Needs sub-second routing updates |

The v1 system is sound at 1–5 agents on a single machine. Phase 1 is triggered
when any of the above limits become observable in practice.

---

## Target architecture (v2)

### Core insight from the paper (April 2026)

The Blackboard architecture with NATS KV + JetStream eliminates the race conditions
in v1 by replacing probabilistic collision avoidance (sleep + re-check) with atomic
Compare-And-Swap (CAS) operations on distributed state. The key insight: instead of
"broadcast intent and hope no one grabbed it in 3 seconds," use "attempt to atomically
transition state from `open` to `claimed`; if the revision mismatches, someone else
won — pick a different gap."

---

## Component mapping: v1 → v2

```
v1 (bash + files)                  v2 (NATS native)
─────────────────────────────────  ──────────────────────────────────────
.chump-locks/<session>.json        NATS KV bucket: chump.leases
                                   key: lease.<session-id>
                                   TTL: enforced by NATS (not cron)
                                   Watcher: any agent subscribes to changes

.chump-locks/ambient.jsonl         NATS JetStream: CHUMP_EVENTS
                                   subjects: chump.events.*
                                   Persistent, replayable, 24h retention
                                   Multiple consumers, no tail-N limit

musher.sh (bash script)            musher-svc (Rust daemon)
                                   Subscribes to CHUMP_EVENTS
                                   Maintains in-memory dispatch table
                                   Responds to request/reply: chump.musher.*
                                   <10ms response vs. ~150ms bash startup

gap-claim.sh INTENT + sleep 3s     NATS KV CAS claim protocol (see below)
                                   Atomic, no sleep required

scripts/war-room.sh                war-room queries musher-svc via NATS
                                   (can run on any machine in the cluster)
```

---

## NATS KV bucket schema

### `chump.leases`

Replaces `.chump-locks/<session>.json`.

```
Key:   lease.<session-id>
Value: {
  "session_id": "...",
  "gap_id": "COG-016",
  "files": ["src/reflection.rs", "src/reflection_db.rs"],
  "worktree": ".claude/worktrees/cog-016-fix/",
  "purpose": "gap:COG-016",
  "taken_at": "2026-04-19T10:00:00Z"
}
TTL:   4 hours (enforced by NATS, not heartbeat-stale detection)
```

Differences from v1:
- TTL is hard — NATS deletes the key when it expires; no 15-minute stale window
- Watchers get notified instantly when a lease is created or deleted
- CAS revision prevents simultaneous writes

### `chump.gaps`

New bucket — the atomic claim layer that v1 was missing.

```
Key:   gap.<gap-id>
Value: {
  "status": "open" | "claimed" | "done",
  "session": "<session-id>",    // populated when claimed
  "ts": "2026-04-19T10:00:00Z"
}
```

The CAS claim protocol uses this bucket to provide atomic ownership transitions.

### `chump.agents`

Presence + heartbeat. Replaces heartbeat_at in lease files.

```
Key:   agent.<session-id>
Value: {
  "gap": "COG-016",
  "files": ["src/reflection.rs"],
  "worktree": ".claude/worktrees/cog-016-fix/",
  "ts": "2026-04-19T10:01:30Z"
}
TTL:   90 seconds (agent is considered dead if not refreshed)
```

An agent refreshes its key every 30s. When the key expires, musher-svc
automatically detects the agent as gone and re-opens the gap.

---

## JetStream stream schema

### `CHUMP_EVENTS`

Replaces `ambient.jsonl`. One stream, subject-filtered consumers.

```
Stream name:   CHUMP_EVENTS
Subjects:      chump.events.>
Retention:     24 hours (limits.age)
Max consumers: unbounded
Replicas:      1 (local dev) / 3 (prod cluster)
```

Subject taxonomy:

| Subject | Payload | Equivalent v1 event |
|---|---|---|
| `chump.events.intent` | `{session, gap, files, ts}` | `INTENT` in ambient.jsonl |
| `chump.events.done` | `{session, gap, commit, ts}` | `DONE` in ambient.jsonl |
| `chump.events.stuck` | `{session, gap, reason, ts}` | `STUCK` in ambient.jsonl |
| `chump.events.handoff` | `{session, gap, to, ts}` | `HANDOFF` in ambient.jsonl |
| `chump.events.alert` | `{session, kind, reason, ts}` | `ALERT` in ambient.jsonl |
| `chump.events.session_start` | `{session, worktree, ts}` | `session_start` |
| `chump.events.commit` | `{session, sha, gap, branch, ts}` | `commit` |
| `chump.events.file_edit` | `{session, path, ts}` | `file_edit` |

Consumers:
- **musher-svc**: ephemeral, push-based, real-time dispatch table updates
- **war-room**: ephemeral, pull-based, "last N minutes" view
- **audit log**: durable, `chump.events.>`, full replay

---

## CAS claim protocol (eliminates the sleep hack)

This replaces the `broadcast INTENT + sleep 3s + write lease` pattern in v1.

```
1. Agent reads chump.gaps.gap.<gap-id>
   → Gets (value, revision). If value.status != "open" → abort.

2. Agent publishes chump.events.intent with gap_id.
   (Other agents watching this subject know to pause on this gap.)

3. Agent CAS-updates chump.gaps.gap.<gap-id>:
   new_value = {"status": "claimed", "session": my_id, "ts": now}
   expected_revision = revision from step 1

   a. If SUCCESS (revision matched): atomic claim held.
      Agent writes chump.leases.lease.<my-session> and starts work.

   b. If REVISION MISMATCH: another agent claimed simultaneously.
      Agent reads the new state, sees who won, backs off, picks next gap.
      No sleep needed — the resolution is microseconds, not seconds.

4. Agent publishes chump.events.session_start and begins heartbeating
   chump.agents.agent.<my-session> every 30s.

5. On completion: agent CAS-updates chump.gaps.gap.<gap-id> to
   {"status": "done", "session": my_id, "ts": now, "commit": sha}
   and deletes chump.leases.lease.<my-session>.
```

This gives strict mutual exclusion with no sleep, no polling, and no probabilistic
collision window.

---

## The musher-svc Rust daemon

The musher-svc replaces `musher.sh` with a long-running async Rust process that
maintains an in-memory dispatch table and serves sub-10ms routing decisions.

### Responsibilities

1. **Subscribe** to `chump.events.>` (JetStream push consumer)
2. **Watch** `chump.leases` and `chump.gaps` KV buckets for key changes
3. **Maintain** in-memory gap dispatch table:
   - `HashMap<GapId, GapState>` where `GapState` is the classified status
   - Updated in O(1) on each event, not re-scanned from scratch
4. **Respond** to request/reply subjects:
   - `chump.musher.pick` → `{gap_id, priority, effort, title}`
   - `chump.musher.check.<gap-id>` → `{status, conflict_detail}`
   - `chump.musher.assign.<n>` → `[{slot, gap_id, priority, effort, title}]`
   - `chump.musher.status` → full classification table
5. **Detect** and **alert** on: `lease_overlap`, `silent_agent`, `edit_burst`

### Interface contract (unchanged from v1)

```rust
// Request: chump.musher.pick (empty payload)
// Response:
#[derive(Serialize, Deserialize)]
struct PickResponse {
    gap_id: String,
    priority: String,
    effort: String,
    title: String,
    reason: String,
}

// Request: chump.musher.check (gap-id in subject)
// Response:
#[derive(Serialize, Deserialize)]
struct CheckResponse {
    gap_id: String,
    status: GapAvailability,
    detail: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum GapAvailability {
    Available,
    Claimed { session: String },
    Intended { session: String, age_secs: u64 },
    Conflict { pr: Option<u32>, lease: Option<String> },
    UnmetDeps { deps: Vec<String> },
    XlEffort,
}
```

The bash scripts become thin NATS publish/subscribe wrappers once musher-svc
exists. `musher.sh --pick` becomes:

```bash
nats request chump.musher.pick '' | jq -r '.gap_id'
```

---

## Typestate FSM (Rust, for in-process agents)

For agents running as native Rust processes (e.g. the chump autonomy loop, not
Claude Code sessions), a typestate FSM provides compile-time coordination safety.

```rust
use std::marker::PhantomData;
use async_nats::Client as NatsClient;

// States are zero-sized types — they exist only at compile time.
pub struct Idle;
pub struct Intending { pub gap_id: String }
pub struct Claimed   { pub gap_id: String, pub lease_rev: u64 }
pub struct Working   { pub gap_id: String, pub files: Vec<String> }
pub struct Shipping;

pub struct Agent<S> {
    pub id: String,
    nats: NatsClient,
    _state: PhantomData<S>,
}

impl Agent<Idle> {
    /// Broadcast INTENT and begin the CAS claim sequence.
    /// Cannot call .start_work() from Idle — must pass through Claimed.
    pub async fn announce_intent(self, gap_id: String)
        -> Result<Agent<Intending>, CoordError>
    { ... }
}

impl Agent<Intending> {
    /// Atomic CAS claim. Returns Err(Conflict { winner }) if another agent won.
    pub async fn claim(self) -> Result<Agent<Claimed>, ConflictError> { ... }

    /// Bail out — no lease was written; revert to Idle.
    pub async fn abandon(self) -> Agent<Idle> { ... }
}

impl Agent<Claimed> {
    /// Lease is held. Register files and begin work.
    pub async fn start_work(self, files: Vec<String>) -> Agent<Working> { ... }
}

impl Agent<Working> {
    /// Heartbeat — refresh chump.agents key (call every 30s).
    pub async fn heartbeat(&self) -> Result<()> { ... }

    /// Work is done; open PR, mark gap done, release lease.
    pub async fn ship(self, commit: &str) -> Result<Agent<Idle>, ShipError> { ... }

    /// Got stuck — broadcast STUCK event, release lease, revert to Idle.
    pub async fn stuck(self, reason: &str) -> Agent<Idle> { ... }
}
```

The compiler enforces the state machine: `Agent<Idle>` has no `.heartbeat()` method.
`Agent<Working>` has no `.claim()` method. Coordination bugs become type errors.

---

## Migration plan

### Phase 0 — Current (today)
Bash-level system: `.chump-locks/` JSON files + `ambient.jsonl` + `musher.sh`.  
Sufficient for ≤5 concurrent agents on a single machine.

### Phase 1 — NATS additive (trigger: consistent stomps or multi-machine need)
1. Add `nats-server` to the local dev stack (single binary, embedded mode)
2. `broadcast.sh` publishes to both `ambient.jsonl` AND `chump.events.*`
3. Lease files remain authoritative; NATS events are additive (dual-write)
4. `war-room.sh` can optionally subscribe to NATS subjects for live updates
5. No Rust code changes required

Effort: S. No coordination regressions possible — v1 still the source of truth.

### Phase 2 — Musher service (trigger: musher.sh latency is noticeable)
1. Write `musher-svc` as a small Rust binary (target: ~500 lines)
2. `musher.sh` modes (`--pick`, `--check`) become NATS request/reply wrappers
3. Dispatch table held in memory by musher-svc — eliminates per-call file scans
4. Lease files and ambient.jsonl still used for persistence/replay

Effort: M.

### Phase 3 — NATS KV authoritative (trigger: Phase 2 stable for 1 week)
1. `gap-claim.sh` writes to `chump.gaps` KV with CAS (eliminates sleep hack)
2. `gap-preflight.sh` reads from `chump.gaps` KV (eliminates file scan)
3. Lease files become read-only compatibility layer, then deprecated
4. `ambient.jsonl` becomes a subscriber that persists JetStream to disk for debugging

Effort: M.

### Phase 4 — Full native FSM (trigger: autonomy loop needs sub-second coordination)
1. Implement typestate FSM in the Rust agent loop
2. All coordination via NATS; bash scripts are thin wrappers or removed
3. `musher-svc` alerts on `lease_overlap`, `silent_agent`, `edit_burst` in real time

Effort: L.

---

## What NOT to build before Phase 1

- **GEPA / genetic-Pareto prompt optimization** — research-grade, not infrastructure
- **Ambient sensing pipeline** (cameras, PIR, mmWave) — COMP-005 scope; cognitive
  layer must be validated first
- **TTSR (Time Traveling Streamed Rules)** — interesting technique from one project,
  not an established pattern; evaluate only after the eval harness (EVAL-023/024) proves
  the cognitive layer is net-positive
- **Multi-machine NATS cluster** (3-replica JetStream) — only needed if running
  agents across machines; overkill for a single M4

---

## Trigger conditions summary

| Phase | Build when |
|---|---|
| Phase 1 (NATS additive) | ≥ 2 confirmed stomps/week *despite* the bash system, OR need to run agents on 2+ machines |
| Phase 2 (musher-svc) | musher.sh startup cost is measurable in the drain loop, OR > 10 pick calls/min |
| Phase 3 (NATS KV authoritative) | CAS race condition confirmed in production (two agents claim same gap simultaneously past the 3s sleep) |
| Phase 4 (typestate FSM) | Autonomy loop agents need < 1s coordination latency, OR coordination bugs keep appearing at runtime that a type system would catch at compile time |

---

## References

- Paper: *Architectures for Ambient Perception and Neural Orchestration in Rust-Native
  AI Agents* (April 2026) — provided the NATS KV + CAS + typestate framing
- `scripts/musher.sh` — v1 dispatch algorithm (bash)
- `scripts/broadcast.sh` — v1 event emitter
- `scripts/gap-claim.sh` — v1 lease writer (INTENT + sleep + write)
- `scripts/gap-preflight.sh` — v1 preflight (lease + INTENT + PR conflict checks)
- `scripts/war-room.sh` — v1 situational awareness
- `docs/AGENT_COORDINATION.md` — full v1 coordination system spec
- NATS docs: https://docs.nats.io/nats-concepts/jetstream/key-value-store
- async-nats crate: https://docs.rs/async-nats
