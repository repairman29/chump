# CP-017: Harvest mission-engine choreographer → Chump gap-decompose pipeline

**Target:** Chump `chump gap decompose` (`src/main.rs:8010-8400`, `src/decompose_task_tool.rs`) — today calls the LLM every invocation with zero caching, no persistent prompt history, and no invalidation hooks. At fleet scale this is multiple LLM hits per gap when decompose is run, re-run, then `--apply` is issued.
**Arsenal match:** `repairman29/mission-engine-service` at commit `d50d055b6783911bc342c6159c163dc6c3a8487c` (main, 2026-05-23). Specifically the `AIQuestGenerator.generateQuest → recordQuestGeneration` loop in `src/services/AIQuestGenerator.js`, plus the `@supabase/supabase-js` persistence client in `src/utils/supabaseClient.js`.
**Recommended route:** **Vendoring**. Port the *pattern* — bounded per-entity profile cache + record-after-compute loop — into Chump-native stack (sqlite + state.db + the existing provider cascade). Do **not** vendor JS code; the JS implementation is in-memory `Map`-based and not durable. We re-implement the choreography in Rust.
**Status:** proposed (2026-05-23, INFRA-1849).

## The Target

`chump gap decompose <ID>` is one of Chump's hottest LLM calls. The flow today (`src/main.rs:8083-8232`):

1. Read parent gap from `state.db` via `store.get(gap_id)`.
2. Build a system prompt + user message containing `{id, domain, title, priority, effort, acceptance_criteria, notes, description}`.
3. Run the INFRA-1719 AST crawler over path hints in the description/notes; append `Structured codebase shape` block (~1.5K tokens) to the prompt.
4. `provider_cascade::build_provider().complete(messages, ...).await` — direct LLM call, no cache check, no dedupe.
5. Parse JSON array; optionally route through a `--verify` second pass (another LLM call).
6. Optionally `--apply` files the suggestions.

Every step from #2 onward is deterministic given the inputs. If the same gap (same description, same AC, same depends_on, same AST shape) is decomposed twice, we pay the LLM cost twice. At dispatch density, when an operator iterates on a gap (decompose → adjust description → decompose again), three of four LLM calls usually return materially identical slice proposals — the operator is iterating on the parent text, not the codebase.

The bottleneck is the absent cache layer. Mission-engine ships the pattern.

## The Arsenal Match — what mission-engine actually has (be honest)

The scout note for INFRA-1849 said "Supabase + Redis + LLM choreographer." Reading the repo directly, that is **not what ships**. The truth is narrower but still useful:

### Dependencies (`package.json`, verbatim, lines 17-21)

```json
"@supabase/supabase-js": "^2.87.0",
"express": "^4.18.2",
"cors": "^2.8.5",
"helmet": "^8.1.0",
"dotenv": "^17.2.3",
"winston": "^3.11.0"
```

No `redis`, no `openai`, no `anthropic`, no `langchain`. The Supabase client is wired (`src/utils/supabaseClient.js:7-13`) but `loadHistoricalData()` in `AIQuestGenerator.js:1064-1068` is an explicit stub — `// This would typically load from a database` — so persistence is aspirational, not shipped. The "AI" is in-memory heuristics (weights, learning vector, branching probabilities) computed in JS, not LLM-prompted.

### The shipped pattern that IS reusable — `AIQuestGenerator.generateQuest → recordQuestGeneration` loop

This is the choreographer worth harvesting. From `src/services/AIQuestGenerator.js`:

```javascript
// Lines 188-261 — generateQuest()
async generateQuest(context = {}) {
  const { playerId, /* … */ questHistory = [] } = context;

  // 1. cache lookup — per-player profile (in-memory Map)
  const playerProfile = this.analyzePlayerProfile(playerId, questHistory, recentActivity);
  // 2. compute — heuristic chain
  const questType = this.selectOptimalQuestType(playerProfile, context);
  const questStructure = await this.generateQuestStructure(questType, playerProfile, context);
  const objectives = this.generateAdaptiveObjectives(questStructure, playerProfile);
  // 3. record — write-back to memory + capped FIFO history
  this.recordQuestGeneration(quest, playerProfile);
  return quest;
}

// Lines 532-549 — recordQuestGeneration()
recordQuestGeneration(quest, playerProfile) {
  this.generationHistory.push({ /* full record */ });
  if (this.generationHistory.length > this.memoryCapacity) {
    this.generationHistory.shift();  // capped at 1000
  }
  this.updateSuccessMetrics(quest);
}
```

### Cache key composition — what makes two requests "the same"

`analyzePlayerProfile(playerId, questHistory, recentActivity)` at line 266 keys solely on `playerId`. Two requests are "same enough to share a profile" iff `playerId` matches. `questHistory` and `recentActivity` are folded **into** the profile, not into the key. There is no TTL.

This is the right key model for our use case **only if** we widen the key. For decompose, `playerId` analogue is `gap_id`, but a gap mutates — so we cannot key on `gap_id` alone. Composite key required (see "Pattern translation" below).

## Chump's current decompose flow

`src/main.rs:8010-8400` is the CLI surface. `src/decompose_task_tool.rs` is the same logic exposed as a Tool (axonerai::tool::Tool trait) for in-loop callers like `autonomy_loop`. Both bottleneck on `provider_cascade::build_provider().complete(...)`. Neither checks any cache; neither emits anything to `ambient.jsonl` about the call cost.

Existing cache wiring nearby: `.chump/github_cache.db` (PR/check-runs cache, INFRA-1081) — exactly the pattern we want, but scoped to GitHub state, not LLM outputs. We re-use the **idea** (sqlite cache + check-first-fallback-to-source), not the schema.

## Pattern translation

| mission-engine | Chump | Notes |
|---|---|---|
| `Map<playerId, profile>` (in-memory) | `.chump/decompose_cache.db` (sqlite) | persistence across process restarts |
| `playerId` key | `(gap_id, desc_hash, ac_hash, deps_hash, ast_shape_hash)` composite | hash-on-content invalidates on mutation |
| `memoryCapacity = 1000` FIFO shift | `CHUMP_DECOMPOSE_CACHE_MAX_ROWS` (default 5000) + LRU by `last_hit_ts` | sqlite trigger or check-on-read |
| `recordQuestGeneration` | `INSERT OR REPLACE INTO decompose_cache(...)` | write happens after LLM responds, before parse-error path |
| `loadHistoricalData()` stub | `CREATE TABLE IF NOT EXISTS decompose_cache` on first call | no migration choreography |
| Supabase persistence (aspirational) | `state.db` (already canonical) | unchanged — gap reads stay where they are |

## Rust refactor — `src/decompose_choreographer.rs`

### Public API (unchanged for callers)

`src/decompose.rs` stays as the public entry; its body delegates to `decompose_choreographer::decompose(parent: &Gap, opts: DecomposeOpts)`.

### Internal flow

```
1. Compute composite cache key.
   key = blake3(format!("{gap_id}|{desc_hash}|{ac_hash}|{deps_hash}|{ast_shape_hash}|{system_prompt_version}"))
2. SELECT response_json, cached_at FROM decompose_cache WHERE key = ?
3. If row exists AND age_s < CHUMP_DECOMPOSE_CACHE_TTL_S (default 86400):
     emit ambient kind=decompose_cache_hit
     UPDATE decompose_cache SET last_hit_ts=now() WHERE key=?
     return parsed slices
4. Else:
     emit ambient kind=decompose_cache_miss with reason=(no_row | ttl_expired | invalidated)
     call provider_cascade::build_provider().complete(...).await
     INSERT OR REPLACE INTO decompose_cache(key, gap_id, response_json, cached_at, last_hit_ts) ...
     return parsed slices
```

### Cache schema (decisive)

```
decompose_cache (
  key TEXT PRIMARY KEY,           -- blake3 composite
  gap_id TEXT NOT NULL,           -- for invalidation lookups
  response_json TEXT NOT NULL,    -- the parsed slice array, serialized
  cached_at INTEGER NOT NULL,     -- unix seconds, immutable
  last_hit_ts INTEGER NOT NULL,   -- for LRU eviction
  desc_hash BLOB NOT NULL,        -- redundant w/ key but indexed for invalidate-by-gap
  ac_hash BLOB NOT NULL,
  system_prompt_version TEXT NOT NULL
)
CREATE INDEX idx_decompose_cache_gap ON decompose_cache(gap_id);
CREATE INDEX idx_decompose_cache_last_hit ON decompose_cache(last_hit_ts);
```

### Invalidation strategy (decisive)

**Check-on-read, not SQLite trigger.** Trigger-on-`state.db` would require attaching `decompose_cache.db` to every state.db connection — coupling two stores. Instead: the lookup at step 2 *re-derives* `desc_hash`/`ac_hash` from the live `state.db` row and compares against the cached values. Mismatch → treat as miss, emit `kind=decompose_cache_miss reason=invalidated`, fall through to LLM, overwrite row.

This is O(1) per call (one hash, no extra query), keeps the two DBs decoupled, and makes invalidation correct-by-construction: if any of the key components changed in state.db, the recomputed key won't match the cached key and the row is logically dead even before we delete it.

LRU eviction runs lazily on insert when `COUNT(*) > CHUMP_DECOMPOSE_CACHE_MAX_ROWS`: `DELETE FROM decompose_cache WHERE key IN (SELECT key FROM decompose_cache ORDER BY last_hit_ts ASC LIMIT n)`.

## Ambient events (new, register in EVENT_REGISTRY.yaml)

```
kind: decompose_cache_hit
emitter: src/decompose_choreographer.rs (INFRA-1849, CP-017)
trigger: cache lookup returned a row whose composite key matched the
  live state.db-derived key, age_s < TTL.
fields_required: [ts, kind, gap_id, cache_age_s, cached_at, last_hit_ts]
effect_metric: decompose_llm_call_avoided_24h
consumers: [fleet-brief, scripts/dev/cache-hit-rate.sh]

kind: decompose_cache_miss
emitter: src/decompose_choreographer.rs (INFRA-1849, CP-017)
trigger: no row, ttl expired, or composite key mismatch from a
  description/AC mutation. Decompose then calls LLM and writes back.
fields_required: [ts, kind, gap_id, reason, prompt_tokens_est]
  # reason ∈ {no_row, ttl_expired, invalidated}
effect_metric: decompose_cache_hit_rate_24h (denominator)
consumers: [fleet-brief, operator-recall]
```

`prompt_tokens_est` is a cheap char/4 estimate computed on the user_msg before the LLM call; it lets `scripts/dev/api-cost-leaderboard.sh` attribute LLM spend back to specific gap decompositions.

## Smoke test — `scripts/ci/test-decompose-cache.sh`

Deterministic, offline, uses the **mock-anthropic** server harvested in CP-009:

1. `start_mock anthropic`; export `ANTHROPIC_API_URL` to the mock.
2. `chump gap reserve --domain INFRA --title "test-decompose-cache fixture"` → captures gap_id.
3. `chump gap set <id> --description "TestA" --ac "TestA-AC" --effort m`.
4. First call: `chump gap decompose <id> --json` → expect a slice array; assert `grep '"kind":"decompose_cache_miss"' .chump-locks/ambient.jsonl | tail -1` shows `reason=no_row`.
5. Second call: `chump gap decompose <id> --json` → expect identical slice array; assert `grep '"kind":"decompose_cache_hit"' .chump-locks/ambient.jsonl | tail -1`. Assert mock-anthropic request count delta = 0 between calls 1 and 2 (the mock exposes `GET /debug/request-count` per CP-009).
6. `chump gap set <id> --description "TestB"` → mutate.
7. Third call: assert `decompose_cache_miss reason=invalidated` and mock request count delta = 1.
8. Cleanup: `chump gap close <id>; stop_mock anthropic`.

## Convergence with INFRA-1719 (AST crawler)

INFRA-1719 (already merged, PR #2385) added the `Structured codebase shape` block to the decompose prompt. That block is deterministic-per-file-content, so its hash is the right input to `ast_shape_hash` in the composite cache key. Concretely: in `decompose_choreographer`, hash `shape.to_prompt_block(6*1024)` before it's appended to `user_msg`. When source files in the AST-touched set change, the shape hash changes, the composite key changes, the cache row goes cold — exactly the invalidation behavior we want for code-shape drift.

This makes the cache jointly invalidated by **either** gap text mutation **or** referenced-source mutation, which is the user's intuition for "stale decomposition."

## Vendoring lineage

Source: `repairman29/mission-engine-service` at commit `d50d055b6783911bc342c6159c163dc6c3a8487c`.
- Choreography pattern: `src/services/AIQuestGenerator.js:188-261` (`generateQuest`), `:532-549` (`recordQuestGeneration`).
- Bounded-cache idiom: `src/services/AIQuestGenerator.js:543-545` (FIFO shift at capacity).
- Persistence-client wiring (vendored *only* as inspiration for the table init pattern): `src/utils/supabaseClient.js:7-50`.

Comment to land in `src/decompose_choreographer.rs`:
```
// Vendored pattern from repairman29/mission-engine-service
// at commit d50d055b6783911bc342c6159c163dc6c3a8487c (CP-017).
// Pattern: per-entity profile cache + record-after-compute loop.
// Implementation is Chump-native (sqlite, blake3, ambient events);
// only the choreography shape is borrowed, not the JS code.
```

## Lineage / Risk

**Honesty surface.** The mission-engine source does NOT itself perform LLM caching, and it does NOT use Redis. The scout note for INFRA-1849 was optimistic. What is harvestable is the *shape* of the choreographer (cache → miss → compute → record), not a turnkey caching layer. This brief promotes the pattern to Chump's native stack rather than vendoring JS that wouldn't fit.

**Risks specific to this harvest:**

1. **Cache poisoning on bad LLM response.** If the LLM returns malformed JSON and we cache the raw response_json before parse-validation, we'd serve the bad string on the next hit. Mitigation: only `INSERT` after `serde_json::from_str::<Vec<SliceSuggestion>>` succeeds. Fail-closed.
2. **Stale cache on subtle description shifts.** Whitespace-only or punctuation edits would invalidate via desc_hash. Acceptable — cheaper to over-invalidate than to serve stale. Operator override via `chump gap decompose <id> --no-cache` flag (new) for cost-comparison runs.
3. **Multi-process write contention.** `.chump/decompose_cache.db` will be touched by parallel `chump gap decompose` calls. Use `PRAGMA journal_mode=WAL` like state.db/github_cache.db.
4. **Rebuild-from-scratch escape hatch.** `rm .chump/decompose_cache.db` is safe at any time; next call recreates. No migration choreography needed because cache is derived, not canonical.
