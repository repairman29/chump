# A2A Layer 3d — Shared KV Scratchpad Seed Keys (INFRA-1761)

> v1 seed key set for the `chump_scratch` NATS KV bucket. Each entry documents
> the conflict policy, TTL, and prompt-injection role. Foundation slice 1/4
> of META-061 Layer 3d. Real NATS read/write impl + agent prompt injection
> + bash wrapper land in subsequent INFRA-1121 slices.

## Bucket

```
NATS KV bucket name: chump_scratch
History:             1   (CAS-friendly; no version retention)
Default TTL:         per-key (see table below)
Default replicas:    1   (single-region for v1; multi-region in Layer 5/6)
```

## Seed keys (v1)

| Key | Conflict Policy | TTL | Prompt Injection | Purpose |
|---|---|---|---|---|
| `main.head.sha` | **CASRequired** | 86400s | ✓ | Current canonical `origin/main` HEAD SHA. Used so parallel agents who all want to compare-against-main converge on the same target without each calling `git ls-remote`. |
| `fleet.size` | LastWriterWins | 300s | ✓ | Current worker count across the active fleet. Read at session-start to decide whether to scale up/down per INFRA-518. High-frequency churn; LWW is fine. |
| `pillar.focus` | LastWriterWins | 3600s | ✓ | Current pillar emphasis (e.g. `EFFECTIVE` or `ZERO-WASTE`). Operator-controlled; moves slowly. |
| `last_known_good.chump_binary` | **CASRequired** | 86400s | ✓ | Most-recently-verified `chump` build SHA. Used to roll back from a known-bad after a destructive op. Preserves linear history. |
| `red_letter.last_ts` | LastWriterWins | 86400s | ✓ | Last time `docs/RED_LETTER.md` was rewritten. Auto-doc agents skip the rewrite if this is fresh (< 12h old). |

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

## Prompt injection (slice 3/4)

When `prompt_inject: true`, the key's current value is included in the
agent's `--briefing` context at session start. Top-N (default 5) keys are
injected, capped at 500 tokens total. Operator can disable injection per
key via `prompt_inject: false` in the schema entry (or globally via
`CHUMP_SCRATCHPAD_INJECT=0` env once slice 3/4 ships).

The intent: drop the `git rev-parse origin/main` call count > 80% — every
agent that opens a session today re-discovers main HEAD via a fresh git
command; the scratchpad makes that one read-from-KV instead.

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

## What's NOT in this slice

This slice ships ONLY:
- The `ConflictPolicy` enum
- The `SeedKey` struct
- The 5 seed keys above (via `seed_keys()`)
- `bucket_name()`
- Stubbed `get` / `set` / `cas` returning `NotImplemented`

Subsequent slices (INFRA-1121 follow-ups):
- 2/4: NATS KV publish + read implementation backed by `chump_scratch`
- 3/4: Agent prompt injection into `--briefing` output (top-N keys)
- 4/4: `scripts/coord/scratch.sh get|set|cas <key> [value]` bash wrapper

## Related

- [META-061 A2A Roadmap](./A2A_ROADMAP.md) — the 6-layer plan this is layer 3d of
- [INFRA-1758 / INFRA-1759 / INFRA-1760](../gaps/) — sibling foundation slices
- [INFRA-1121](../gaps/INFRA-1121.yaml) — parent gap, m-effort umbrella
