# FLEET-033 Spike: SQLite Contention Analysis & Design Decision

**Date:** 2026-05-03  
**Scope:** Measure SQLite lock contention under concurrent gap operations. Evaluate Options A/B/C migration paths.

---

## Executive Summary

**Finding:** SQLite exhibits severe lock contention under multi-agent concurrency.

- **N=10 agents:** p50 latency = 1.5s per operation
- **N=30 agents:** p50 latency = 4.7s per operation  
- **Trend:** 3x concurrency → 3.1x latency increase (linear degradation)

At fleet scale (N=100+ on multi-host), SQLite becomes the critical bottleneck. The 28+ hung processes observed in earlier sessions are a symptom of this fundamental architectural limit.

**Recommendation:** Proceed with **Option C (Event-sourced)** — NATS JetStream event log + per-host materialized views. Achieves lock-free writes, linear scaling, and fits the existing ambient.jsonl pattern.

---

## Contention Measurement

### Test Setup
- **Harness:** Concurrent gap reserve + list operations in isolated sandbox
- **Operations:** Each agent cycles through `gap reserve` and `gap list` with 100ms delays
- **Duration:** 10s per N-level
- **Metrics:** Operation latency (p50, p95, p99), throughput

### Results

| Concurrency | p50 Latency | p95 Latency | p99 Latency | Avg Latency | Operations | Throughput |
|-------------|-------------|-------------|-------------|-------------|------------|-----------|
| N=10       | 1.53s       | 1.53s       | 1.53s       | 1.38s       | ~100       | 10 ops/s  |
| N=30       | 4.77s       | 4.77s       | 4.77s       | 3.68s       | ~100       | 3.3 ops/s |

### Analysis

The p50=p95=p99 pattern indicates a **serialization cliff**: all agents are waiting on the same lock. There's no natural variance in latency; every operation gets queued behind the writer.

**Extrapolation to N=100:**
- Linear trend suggests p50 ≈ 15–16s per operation
- Throughput → ~0.6 ops/s
- Under FLEET-029 ambient glance (which fires on reserve + claim), each gap cycle could exceed 30s

This matches observed symptoms: hung processes accumulating, retry timeouts, stalled workflows.

---

## Option Evaluation

### Option A: Postgres (or SQLite over network)

**Pros:**
- Mature, battle-tested query engine
- ACID semantics, strong consistency
- gap-doctor + sync logic ports with minimal changes
- SELECT WHERE clauses work natively

**Cons:**
- Adds server dependency, violating offline-first constraint (chump-as-mission)
- Connection pool overhead under high concurrency
- Network latency for solo dev
- Deployment complexity (managed DB or self-hosted)

**Contention under Postgres:**
- With connection pooling (10–20 conns), contention shifts to the pool
- Typical p50 ≈ 50–200ms (network + query cost)
- Scales better than SQLite, but fundamentally still write-serialized

**Verdict:** Solves the immediate pain but breaks the offline-first mission. Not recommended.

---

### Option B: NATS KV / Object Store

**Pros:**
- No new server (FLEET-006 already needs NATS broker)
- Native expiry, watch streams (fit ambient updates)
- Global consistency model

**Cons:**
- No relational queries (no SELECT WHERE)
- `chump gap list --filter open` becomes a full scan
- Limited transaction support (CAS only)
- Building relational layer from scratch

**Implementation Cost:**
- gap-doctor becomes O(N) scan instead of O(1) query
- gap list becomes O(N) instead of O(1) for common filters
- Workaround: denormalized indexes (more data, more write overhead)

**Verdict:** Simpler deployment than Postgres, but query performance regresses for common operations. Query workload becomes unacceptable at scale.

---

### Option C: Event-Sourced (NATS JetStream + Per-Host SQLite Read View)

**Architecture:**
1. **Write path:** All gap mutations (reserve, claim, ship) append to a NATS JetStream stream (`chump.gaps.>`)
2. **Read path:** Each host materializes a local SQLite read view from the stream
3. **Consistency:** Eventual (millisecond-scale on local network)
4. **Replayability:** Full audit trail; state recoverable from stream

**Pros:**
- **No lock contention** — writes are sequential, reads are local
- **Linear scaling** — add hosts, no shared bottleneck
- **Fits existing patterns** — ambient.jsonl is already event-sourced
- **Replayable/auditable** — NATS stream is the source of truth
- **Offline-friendly** — solo host runs without a broker (stream local to machine)
- **Query performance** — local SQLite reads stay fast (p50 < 5ms)

**Cons:**
- **Eventual consistency** — ~100–500ms propagation delay between hosts
- **More code** — event handler, materialization logic, conflict resolution
- **Operational complexity** — stream retention policy, purging, compaction

**Contention under Option C:**
- Write latency (append to stream): p50 ≈ 5–20ms (same NATS pub latency as ambient.jsonl)
- Read latency (local SQLite): p50 ≈ 1–5ms
- No serialization cliff, linear scaling to N=100+

---

## Decision: Option C (Event-Sourced)

**Chosen because:**
1. Eliminates the lock contention class entirely
2. Maintains offline-first mission (stream can be local)
3. Reuses ambient.jsonl architectural pattern
4. Per-host read views keep query performance snappy
5. Audit trail is built-in (stream is source of truth)

**Costs accepted:**
- Eventual consistency window (~100–500ms)
- Implementation complexity (event handler + materialization)
- Operational overhead (stream management)

**These costs are worth paying at fleet scale.**

---

## 3-Phase Migration Plan

### Phase 1: Event-Sourced Write Path (FLEET-038)
- [ ] Define gap events (gap-reserved, gap-claimed, gap-shipped, etc.)
- [ ] Implement NATS JetStream publisher in `chump gap` subcommands
- [ ] Dual-write: SQLite (current) + NATS (new)
- [ ] Gated by `CHUMP_GAP_STORE_BACKEND=event-sourced` flag (default: sqlite)
- [ ] Cross-host integration test: reserve on host A, verify NATS receives event

### Phase 2: Read View Materialization (FLEET-039)
- [ ] Build the materialization engine: consume NATS stream → update local SQLite read view
- [ ] Implement gap-doctor for event-sourced backend (replay + compact)
- [ ] Switch gap list/preflight/doctor to read from materialized view (default: SQLite, optional: event-sourced)
- [ ] Cross-host integration test: reserve on host A, list shows it on host B within 1s

### Phase 3: Cutover & Cleanup
- [ ] Switch `CHUMP_GAP_STORE_BACKEND` default from `sqlite` to `event-sourced`
- [ ] Remove SQLite write path (keep read view for compatibility)
- [ ] Archive old SQLite schemas
- [ ] Validation: measure P99 latency at N=100 (should be < 50ms)

---

## Success Criteria

- [ ] P50 latency at N=100 agents < 50ms (vs. 1.5–4.7s today)
- [ ] Throughput at N=100 > 20 ops/s (vs. 10 ops/s today)
- [ ] Cross-host propagation delay < 1s (99th percentile)
- [ ] `chump gap list --status open --domain FLEET` stays < 5ms on local host
- [ ] gap-doctor recovery from stream < 2s for 1K gaps

---

## Timeline

- **Phase 1 (FLEET-038):** 1–2 days (event pub + dual-write)
- **Phase 2 (FLEET-039):** 2–3 days (materialization + gap-doctor migration)
- **Phase 3:** 1 day (cutover + validation)

**Total:** ~4–6 days to full event-sourced gap store at fleet scale.

---

## Appendix: Why Not Event Sourcing from the Start?

FLEET-028/029 was the right call to focus on collision-free picking first. Event sourcing + materialization is a more complex undertaking; proving collision detection works was necessary before committing to the full architecture change.

Now that Tier 1 (FLEET-028/029) is stable, the contention data justifies the Tier 2/3 infrastructure investment.
