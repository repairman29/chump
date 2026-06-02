# A2A Layer 3d — Shared KV Scratchpad Seed Keys (INFRA-1121)

> v1 seed key set for the `chump_scratch` file-backed KV bucket. Each entry
> documents the conflict policy, TTL, and prompt-injection role.
>
> **Activation status:**
> - Slice 1/4 (INFRA-1761): ConflictPolicy enum + SeedKey struct + 5 seed keys — SHIPPED
> - Slice 2/4 (INFRA-1826): file-backed get/set/cas backend — SHIPPED
> - Slice 3/4 (INFRA-1121): agent prompt injection into `--briefing` + env-ordering test fix — **SHIPPED** (this PR)
> - Slice 4/4: `scripts/coord/scratch.sh` bash wrapper — open
>
> **Agent injection**: all 5 seed keys (where set) appear under
> `## Fleet Scratchpad (session-start snapshot)` in `chump --briefing <ID>`
> output. Disable globally with `CHUMP_SCRATCHPAD_INJECT=0`.

## Bucket

```
Backend:             .chump-locks/scratch/<key>.json (file-backed, slice 2/4)
Future backend:      NATS KV bucket chump_scratch (slice 3/4 of NATS migration)
History:             1   (CAS-friendly; no version retention)
Default TTL:         per-key (see table below)
Default replicas:    1   (single-region for v1; multi-region in Layer 5/6)
```

## Seed keys (v1)

| Key | Namespace | Conflict Policy | TTL | Prompt Injection | Purpose |
|---|---|---|---|---|---|
| `main.head.sha` | `chump_scratch` | **CASRequired** | 86400s | ✓ | Current canonical `origin/main` HEAD SHA. Used so parallel agents who all want to compare-against-main converge on the same target without each calling `git ls-remote`. |
| `fleet.size` | `chump_scratch` | LastWriterWins | 300s | ✓ | Current worker count across the active fleet. Read at session-start to decide whether to scale up/down per INFRA-518. High-frequency churn; LWW is fine. |
| `pillar.focus` | `chump_scratch` | LastWriterWins | 3600s | ✓ | Current pillar emphasis (e.g. `EFFECTIVE` or `ZERO-WASTE`). Operator-controlled; moves slowly. |
| `last_known_good.chump_binary` | `chump_scratch` | **CASRequired** | 86400s | ✓ | Most-recently-verified `chump` build SHA. Used to roll back from a known-bad after a destructive op. Preserves linear history. |
| `red_letter.last_ts` | `chump_scratch` | LastWriterWins | 86400s | ✓ | Last time `docs/RED_LETTER.md` was rewritten. Auto-doc agents skip the rewrite if this is fresh (< 12h old). |
| `ci.flake_classification` | `chump_scratch` | **CASRequired (on blob)** | 3600s | — | CI-audit curator's latest flake/logic-bug/missing-gate classification blob for the current trunk. CAS-on-blob: writer reads existing JSON blob, merges new findings, and CAS-writes back. Injected into CI-audit briefings only (not general session briefing) to keep token budget tight. |

## Conflict policies

- **`LastWriterWins`** — accept whatever value writes last. No CAS check.
  Suitable for high-frequency counters or pointers whose freshness matters
  more than write ordering. NEVER use for keys where two concurrent writers
  could each have a legitimate value (race → silent data loss).

- **`CASRequired`** — writer must read the current value, prepare a new
  one, and submit a compare-and-swap. On conflict, the write fails and the
  caller retries from a fresh read. Suitable for canonical-pointer keys
  where you want to preserve causal history.

- **`MergeWithFn`** — variant included in the enum but no v1 seed key
  uses it. Reserved for map-shaped values where two writers can each
  legitimately add disjoint sub-keys. A future use case: per-session
  capability rollup published by every Opus and merged into a global view.

## Prompt injection (SHIPPED — slice 3/4)

When `prompt_inject: true`, the key's current value is included in the
agent's `--briefing` context at session start. Top-N (default 5) keys are
injected, capped at 500 tokens total (2000 chars at ~4 chars/token).

Operator can disable injection globally with `CHUMP_SCRATCHPAD_INJECT=0`.
Individual keys can opt out via `prompt_inject: false` in the `SeedKey`
struct (requires a code change + re-ship).

The rendered section appears as:

```markdown
## Fleet Scratchpad (session-start snapshot)

- `main.head.sha` = "abc123..."
- `fleet.size` = 3
- `pillar.focus` = "EFFECTIVE"
```

The intent: drop the `git rev-parse origin/main` call count > 80% — every
agent that opens a session today re-discovers main HEAD via a fresh git
command; the scratchpad makes that one read-from-KV instead.

Implementation entry point: `src/briefing.rs::collect_scratchpad_context()`
calls `chump_coord::scratchpad::prompt_inject_snapshot(5)` via
`tokio::task::block_in_place` so it works from the sync `build_briefing_at`
function without blocking the executor thread.

## TTL semantics

- Keys with finite TTL expire `ttl_seconds` after their last write. The
  underlying NATS KV handles eviction.
- Entries marked `ttl=infinite` (none in v1) must carry an
  `operator_reviewed_at` timestamp; otherwise the write is rejected
  (`ScratchError::InfiniteTtlMissingReview`).
- The TTL is on the LATEST WRITE, not the original creation — write
  refreshes the TTL.

## Schema versioning

Today's schema is implicit (no version field on the bucket; readers
tolerate forward-compat by virtue of consuming `serde_json::Value`). Bump
to a versioned schema (`chump-scratch-v2`) when adding a required field;
readers should fall back gracefully for v1 entries during the migration
window.

## Shipped so far

- Slice 1/4 (INFRA-1761): ConflictPolicy enum + SeedKey struct + 5 seed keys
- Slice 2/4 (INFRA-1826): file-backed get/set/cas; `.chump-locks/scratch/` backend; TTL expiry
- Slice 3/4 (INFRA-1121): `prompt_inject_snapshot` + `collect_scratchpad_context` wired into `build_briefing_at`; env-ordering test race fixed with `#[serial]`

## Remaining work

- Slice 4/4: `scripts/coord/scratch.sh get|set|cas <key> [value]` bash wrapper
- NATS KV backend (swap file backend for real NATS KV `chump_scratch` bucket — currently file-only)
- `ci.flake_classification` writer in the CI-audit curator loop

## Related

- [META-061 A2A Roadmap](./A2A_ROADMAP.md) — the 6-layer plan this is layer 3d of
- [INFRA-1758 / INFRA-1759 / INFRA-1760](../gaps/) — sibling foundation slices
- [INFRA-1121](../gaps/INFRA-1121.yaml) — parent gap, m-effort umbrella
