# CP-006: Vendor openclaw memory pattern → Chump memory_db

**Target:** Chump's cross-agent lesson propagation (INFRA-1765) + general agent memory needs a searchable schema with citations.
**Arsenal match:** `repairman29/openclaw` (commit `0205fad`, locally at `/Users/jeffadkins/Projects/Maclawd/`) — `src/memory/memory-schema.ts`, `extensions/memory-lancedb/index.ts`, `src/agents/tools/memory-tool.ts`.
**Recommended route:** Vendoring (Route 3). Rebuild the schema and tool surface in Rust against the existing `src/memory_db.rs` substrate; **defer the embeddings layer to v1** behind a feature flag that targets CP-001 (neural-farm) as the embedding home.
**Status:** proposed (2026-05-23, INFRA-1817; pairs with INFRA-1765).

## The Target

Chump already has a working FTS5 memory substrate at `src/memory_db.rs` (1500+ LOC, `chump_memory` table + `memory_fts` virtual table + BM25 reranker at lines 1046–1089). What it does **not** have:

1. **Citations with line refs.** `keyword_search()` returns the whole row's `content`; there is no path/line-range structure. INFRA-1765 needs to inject CI-failure lessons into a session briefing with a clickable source pointer.
2. **A `memory_search` tool surface.** `memory_tool.rs` exposes a brain-style "ask me something" agent; there's no narrow tool the way openclaw exposes `memory_search` / `memory_get` to the agent registry (per `src/agents/tools/memory-tool.ts:50-67`).
3. **A separated embeddings cache.** When CP-001 (neural-farm) lands, Chump will need a place to persist embeddings keyed by `(provider, model, hash)` so a cold-start session doesn't re-embed the corpus. openclaw's `embedding_cache` table (`memory-schema.ts:38-49`) is the exact primitive.
4. **`chump memory search` CLI.** The current substrate is callable from Rust only; an operator can't grep their own memory without writing a one-off binary.

INFRA-1765's substrate need: when a CI failure pattern lands in `memory_db`, the next session's `chump --briefing <GAP-ID>` should be able to return *"this pattern matched these 3 chunks from `docs/process/CLAUDE_GOTCHAS.md:42-58`"* — file + line refs are load-bearing.

## The Arsenal Match — openclaw memory architecture

### Chunk schema (`src/memory/memory-schema.ts:25-37`)

```sql
CREATE TABLE IF NOT EXISTS chunks (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'memory',
  start_line INTEGER NOT NULL,
  end_line INTEGER NOT NULL,
  hash TEXT NOT NULL,
  model TEXT NOT NULL,
  text TEXT NOT NULL,
  embedding TEXT NOT NULL,       -- JSON-serialized f32 array
  updated_at INTEGER NOT NULL
);
```

`id` is content-derived (`hash` of `path:start_line:end_line:text`), `embedding` stores the vector as a JSON string (portable; no `sqlite-vec` dependency required for retrieval-by-id), `model` records the embedder identity so a model swap invalidates cleanly. Indexed by `path` and `source` (`memory-schema.ts:79-80`).

### FTS virtual table layout (`memory-schema.ts:56-75`)

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
  text,
  id UNINDEXED,
  path UNINDEXED,
  source UNINDEXED,
  model UNINDEXED,
  start_line UNINDEXED,
  end_line UNINDEXED
);
```

`text` is the only tokenized column; everything else rides along as `UNINDEXED` payload so an FTS5 hit returns the full citation pointer in one query. This is the exact primitive Chump is missing — today `memory_fts` is `content='chump_memory'` content-less, requiring a JOIN to recover the row.

### Embeddings cache (`memory-schema.ts:38-49`)

```sql
CREATE TABLE IF NOT EXISTS <embedding_cache_table> (
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  provider_key TEXT NOT NULL,
  hash TEXT NOT NULL,            -- content hash
  embedding TEXT NOT NULL,       -- JSON
  dims INTEGER,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (provider, model, provider_key, hash)
);
```

The default OpenAI embedder is `text-embedding-3-small` at 1536 dims (`extensions/memory-lancedb/config.ts:53-56`). The LanceDB plugin (`extensions/memory-lancedb/index.ts:103-140`) is a *separate* vector store; the SQLite `embedding_cache` table is provider-agnostic and survives a vector-DB swap. Ollama is also supported (see `src/memory/embeddings-ollama.ts`), so the local-LLM path (Chump's mission) is precedented.

### Temporal decay (`src/memory/temporal-decay.ts:36-42`)

Exponential decay with configurable half-life: `score' = score * exp(-ln(2) * age_days / half_life_days)`. Disabled by default (`enabled: false`, half-life 30d). Dated memory paths (`memory/YYYY-MM-DD.md`) take their timestamp from the filename; evergreen roots (`MEMORY.md`, `memory/topic.md` without a date) are *exempt* from decay so persistent knowledge doesn't bleed out.

### Memory-tool API surface (`src/agents/tools/memory-tool.ts:40-99`)

Two tools register against the agent registry:

- `memory_search({ query, maxResults?, minScore? }) → { results: MemorySearchResult[], provider, model, fallback, citations, mode }` where `MemorySearchResult = { path, startLine, endLine, score, snippet, source, citation? }` (`src/memory/types.ts:3-11`). Citation format: `path#L42-L58` (built at `memory-tool.ts:161-167`).
- `memory_get({ path, from?, lines? }) → { text, path }` — narrow line-range read used after `memory_search` to pull just the cited lines, keeping the agent's context window small.

The recall plugin (`extensions/memory-lancedb/index.ts:546-572`) also wires an *automatic* `before_agent_start` hook that embeds the prompt and prepends top-K matching memories — formatted as `<relevant-memories>` with explicit anti-prompt-injection guardrails (`index.ts:204-240`).

## Chump's existing memory state

| Surface | Purpose | Searchable? | Citations? | Notes |
|---|---|---|---|---|
| `.chump/notes/` | per-gap operator notes | grep only | no | `SESSION-*-WRAP.md` files; markdown |
| `.chump-locks/ambient.jsonl` | event stream (`pr_stuck`, `silent_agent`, …) | grep / jq | no | append-only; rotated daily |
| `chump --briefing <GAP-ID>` | per-gap context bundle | bundled at call-time | no | `src/briefing.rs:104` reads YAML + recent edits |
| user auto-memory (`~/.claude/projects/.../memory/`) | session-spanning prefs | manual | no | hand-curated MEMORY.md + topic files |
| `chump_memory` (SQLite, `sessions/chump_memory.db`) | structured rows + FTS5 + BM25 rerank | yes (`memory_db::keyword_search`) | no | `src/memory_db.rs:989-1019`; no path/line refs |

**Capability gap (precise):**

1. **No path/line citations.** `MemoryRow` (line 13–23) carries `content`, `ts`, `source`, `confidence`, `verified`, `memory_type` — but no `path`, no `start_line`/`end_line`. Even when a memory *comes from* a doc, the row can't tell the reader where.
2. **No external embeddings cache.** Vector rerank is BM25-only (`rerank_memories` line 1046). When CP-001 lands, there is nowhere to persist `(provider, model, hash) → embedding`.
3. **No agent-tool surface.** A subagent can't issue `memory_search`; it has to call `memory_brain_tool` which is a wide brain interface, not a narrow citation-returning tool.
4. **No `chump memory search` CLI.** Operator has to write Rust to query their own memory.

## Rust port — `src/memory_db.rs` extension

### v0 schema (FTS-only, no embeddings)

Extend `chump_memory` *additively* (existing rows stay valid). Add a sibling `memory_chunks` table that mirrors openclaw's structure but reuses the existing FTS infra:

```rust
pub struct MemoryChunk {
    pub id: i64,
    pub content: String,
    pub source: String,        // ambient kind, briefing source, gap-yaml, or file path
    pub path: Option<String>,  // when chunk came from a file
    pub start_line: u32,
    pub end_line: u32,
    pub gap_id: Option<String>,
    pub session_id: String,
    pub embedding: Option<Vec<f32>>, // None at v0; populated at v1
    pub created_at: i64,
}
```

```sql
CREATE TABLE IF NOT EXISTS memory_chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content TEXT NOT NULL,
    source TEXT NOT NULL,
    path TEXT,
    start_line INTEGER NOT NULL DEFAULT 0,
    end_line INTEGER NOT NULL DEFAULT 0,
    gap_id TEXT,
    session_id TEXT NOT NULL,
    embedding BLOB,             -- f32[] serialized; NULL at v0
    embedding_model TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_chunks_gap ON memory_chunks(gap_id);
CREATE INDEX IF NOT EXISTS idx_memory_chunks_source ON memory_chunks(source);

CREATE VIRTUAL TABLE IF NOT EXISTS memory_chunks_fts USING fts5(
    content,
    id UNINDEXED,
    path UNINDEXED,
    source UNINDEXED,
    start_line UNINDEXED,
    end_line UNINDEXED,
    gap_id UNINDEXED,
    content='memory_chunks', content_rowid='id'
);
```

Triggers mirror lines 86–95 of the existing `memory_db.rs`. Citation format identical to openclaw: `path#L{start}-L{end}` (or `path#L{start}` when single-line).

### v1 schema (embeddings via CP-001 neural-farm)

Behind feature flag `CHUMP_MEMORY_EMBEDDINGS=1`. Add the openclaw cache table verbatim:

```sql
CREATE TABLE IF NOT EXISTS memory_embedding_cache (
    provider TEXT NOT NULL,        -- 'neural-farm', 'openai', 'ollama'
    model TEXT NOT NULL,           -- e.g. 'text-embedding-3-small', 'nomic-embed-text'
    provider_key TEXT NOT NULL,    -- routing key inside neural-farm
    hash TEXT NOT NULL,            -- sha256(content)
    embedding BLOB NOT NULL,       -- f32[] little-endian
    dims INTEGER,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (provider, model, provider_key, hash)
);
```

Vector retrieval lives in the `memory_chunks.embedding` column; the cache is the warm-restart store so a fresh session that re-embeds the corpus hits the cache 100% on its second pass.

**v0 vs v1 split rationale:** the citation gap (#1) is what INFRA-1765 actually needs to land. Embeddings (#2) only matter once CP-001 ships a stable embed endpoint — adding them now would force Chump to depend on an unfinished neural-farm primitive. v0 ships in days; v1 ships after CP-001 lands.

### CLI surface

```bash
chump memory search "ci failure rust clippy" \
    [--top-n 5] [--gap-id INFRA-1765] [--source ambient|notes|gap|file] [--json]
```

Default output:

```
1. [98%] docs/process/CLAUDE_GOTCHAS.md#L42-L58 (gap=INFRA-1673)
   "Run local CI before every push that touches Rust or scripts..."
2. [87%] .chump-locks/ambient.jsonl#L1284 (gap=INFRA-1832)
   "kind=preflight_bypassed reason=clippy dead_code..."
```

`--json` shape:

```json
{
  "results": [
    {
      "id": 42,
      "score": 0.98,
      "citation": "docs/process/CLAUDE_GOTCHAS.md#L42-L58",
      "path": "docs/process/CLAUDE_GOTCHAS.md",
      "start_line": 42, "end_line": 58,
      "snippet": "Run local CI before every push...",
      "source": "docs", "gap_id": "INFRA-1673"
    }
  ],
  "backend": "fts5",   // v1: "fts5+embedding"
  "model": null        // v1: "neural-farm:nomic-embed-text"
}
```

`chump memory ingest` + `chump memory forget` are out-of-scope for v0; ingestion is fleet-driven (CI failure observer writes via the existing `memory_db::insert_one` pattern with the new chunked variant).

## Smoke test spec — `scripts/ci/test-memory-search.sh`

1. Seed a synthetic corpus into a tmp `chump_memory.db`:
   - chunk A: "rust clippy dead_code violation" at `docs/A.md#L10-L20`
   - chunk B: "ci failure auth token expired" at `docs/B.md#L1-L5`
   - chunk C: "rust clippy unused import" at `docs/A.md#L40-L50`
2. Run `chump memory search "rust clippy" --top-n 5 --json`.
3. Assert deterministic ranking: A and C above B (BM25 hit on "rust clippy"), with full citations `docs/A.md#L10-L20` and `docs/A.md#L40-L50` present in the result.
4. Run `chump memory search "auth" --gap-id INFRA-1832 --json` → exit non-zero is OK (no match), but JSON shape must be valid and `results: []`.
5. Re-run query 2; assert byte-identical output (FTS5 ranking determinism check — guards against the rerank-weights-drift class precedented at `memory_db.rs:1112`).

Same shape as `scripts/ci/test-gap-audit-priorities.sh` — exits 0 on pass, non-zero with diff on fail.

## Vendoring lineage

```
src/memory_db.rs::memory_chunks*           // verbatim port of memory-schema.ts:25-37 + 56-75
src/memory_db.rs::memory_embedding_cache   // verbatim port of memory-schema.ts:38-49 (v1)
src/memory_db.rs::keyword_search_chunks    // adaptation of qmd-manager.ts search path
src/cli/memory.rs::cmd_memory_search       // adaptation of memory-tool.ts:40-99
```

Per-file citation in the implementation PR body:

> Vendored from openclaw `0205fad` (`https://github.com/repairman29/openclaw`):
> `src/memory/memory-schema.ts:1-96` → `src/memory_db.rs` (schema)
> `src/agents/tools/memory-tool.ts:1-242` → `src/cli/memory.rs` (CLI surface)
> Embeddings cache + temporal decay deferred to v1 (CP-001 dependency).

License check: openclaw is `repairman29`-owned; same operator as Chump. No external license cleanup needed.

## Convergence with INFRA-1765 + CP-001

- **INFRA-1765 (cross-agent lesson propagation):** the CI failure observer parses preflight bypass events from `ambient.jsonl`, chunks each `kind=preflight_bypassed` line, and inserts via `memory_chunks` with `source='ambient'` and `gap_id` populated. `chump --briefing <GAP-ID>` calls `keyword_search_chunks(domain_tags, limit=3)` and renders the citations under a `## Recent CI lessons` header.
- **CP-001 (neural-farm as Chump's inference gateway):** v1 wires the embedding call through `CHUMP_INFERENCE_ENDPOINT` (the openai-compat surface CP-001 spec'd). `memory_embedding_cache.provider = 'neural-farm'` and the dims default to whatever neural-farm advertises. No Anthropic-side embedding call ever needed.
- **memory_db.rs existing curation (`curate_all`):** v0 chunks participate in `expire_stale_memories` and `dedupe_exact_content` via the existing FTS triggers. No new curation policy needed — the chunk table inherits the proven hygiene.

## Lineage / Risk

- **Risk: TS → Rust translation drift.** openclaw uses `node:sqlite` synchronous API; Chump uses `rusqlite` + r2d2 pool. The schema is identical SQL so this is mechanical, but the `embedding TEXT` (JSON) → `embedding BLOB` (f32 little-endian) is a deliberate divergence — Rust handles binary cheaper than JSON parsing. Document the encoding choice in the schema comment.
- **Risk: chunk dedupe across gaps.** A single CI lesson may be inserted by multiple sessions; the existing `dedupe_exact_content` (`memory_db.rs:323`) collapses by `content` alone. With chunks carrying distinct `gap_id`, exact-dedupe would over-collapse. Fix: dedupe key becomes `(content, path, start_line, end_line)` for chunk rows; `chump_memory` (the old table) keeps current behavior.
- **Risk: neural-farm dormancy (CP-001 risk).** v1 depends on a primitive that's been quiet since 2026-02-28. Build v0 first; revisit v1 only after CP-001 surveys the repo's current state. v0 alone is enough to close INFRA-1765's substrate need.
- **Risk: cardinality blowup.** Naive chunking of `ambient.jsonl` (~1k events/day) would balloon the table. Mitigation: ingest only specific kinds (`pr_stuck`, `silent_agent`, `preflight_bypassed`, `fleet_wedge`) — the high-signal subset already gated through INFRA-1765's filter. v0 ships with that allowlist hardcoded.

## Two-sentence summary

**Chunk schema:** `memory_chunks(id, content, source, path, start_line, end_line, gap_id, session_id, embedding NULL@v0/BLOB@v1, created_at)` + `memory_chunks_fts` FTS5 mirror with `UNINDEXED` citation payload so a single hit returns `path#L42-L58` without a JOIN. **v0/v1 split:** v0 ships FTS5-only citations + `chump memory search` CLI + smoke test (closes INFRA-1765's substrate need in days, no external deps); v1 adds `memory_embedding_cache` + embedding column behind `CHUMP_MEMORY_EMBEDDINGS=1`, gated on CP-001 (neural-farm) landing.
