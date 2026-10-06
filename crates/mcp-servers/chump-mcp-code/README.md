# chump-mcp-code

MCP server (JSON-RPC 2.0 over stdio, same shape as `chump-mcp-gaps`) that answers
symbol queries from a tree-sitter code index.

- **Indexer** — parses Rust (`.rs`), bash (`.sh`/`.bash`) and Python (`.py`) with the
  shared `chump-ast-crawler` tree-sitter extractor and stores top-level symbols in
  `.chump/code_index.db` (separate from `state.db`; override with `CHUMP_CODE_INDEX_DB`).
- **Incremental** — each file is stored with a content hash; unchanged files are skipped,
  deleted files are removed. `scripts/git-hooks/post-commit-code-index.sh` re-indexes only
  the files a commit touched.

## Usage

```bash
export CHUMP_REPO=/path/to/repo
chump-mcp-code index --all          # (re)index the whole repo
chump-mcp-code index --head         # index only the files changed by HEAD
chump-mcp-code index --files a.rs b.sh
chump-mcp-code                      # serve JSON-RPC on stdio (also: `serve`)
```

| Method / tool | Params | Description |
|---|---|---|
| `tools/list` | | List the tools below |
| `search_symbols` | `query`, `kind?`, `limit?` | Substring match on symbol name |
| `file_symbols` | `path` | Symbols indexed for one file |
| `index_stats` | | File / symbol counts and a per-language breakdown |
| `reindex` | `paths?` | Re-index the given repo-relative paths (default: everything) |
| `code.find_symbol` | `name`, `kind?` | **Phase 1.** Exact-name existence lookup |
| `code.callers_of` | `symbol`, `limit?` | **Phase 1.** Call sites of a symbol (definitions/comments excluded) |
| `code.gap_history` | `gap_id` | **Phase 1.** `open` / `done` / `reaped` / `never_existed` for a gap id |
| `code.trait_impls` | `trait`, `limit?` | **Phase 3.** Rust `impl Trait for Type` headers and Python subclasses |
| `code.symbol_history` | `symbol`, `limit?` | **Phase 3.** Commits that added/removed a symbol (git pickaxe), newest first |
| `code.dead_code_scan` | `reasons?`, `limit?` | **Phase 3.** Likely-dead code, each with a reason |

### Phase-1 response shapes

These answer *existence* questions explicitly (never an ambiguous empty list), to prevent the
"feature missing" misdiagnosis class (INFRA-1575).

```text
code.find_symbol -> { "symbol", "exists": bool, "count": n,
                      "matches": [ { "path", "name", "kind", "line", "language", "doc_first_line" } ] }
code.callers_of  -> { "symbol", "defined": bool, "count": n, "truncated": bool,
                      "callers": [ { "path", "line", "text", "in_symbol" } ] }
code.gap_history -> { "gap_id", "status": "open"|"done"|"reaped"|"never_existed", "title",
                      "shipped_pr": int|null, "closed_date": "YYYY-MM-DD"|null,
                      "reaped_date": "YYYY-MM-DD"|null }
```

`callers_of` is a textual call-pattern scan over indexed files (tree-sitter provides definitions,
not references). `gap_history` reads `.chump/state.db` (override `CHUMP_STATE_DB`); `reaped` means
the registry row is gone but a commit message in git history still mentions the gap id, so
`reaped_date` is that commit's date and `shipped_pr` is parsed from its trailing `(#N)`.

### Phase-3 response shapes

```text
code.trait_impls    -> { "trait", "defined": bool, "count": n, "truncated": bool,
                         "impls": [ { "path", "line", "type", "kind": "impl"|"subclass", "language" } ] }
code.symbol_history -> { "symbol", "count": n, "truncated": bool,
                         "first_seen": "YYYY-MM-DD"|null, "last_changed": "YYYY-MM-DD"|null,
                         "commits": [ { "sha", "date", "subject" } ] }       // newest first
code.dead_code_scan -> { "count": n, "total": n, "truncated": bool, "by_reason": { reason: n },
                         "findings": [ { "symbol", "file", "line", "location": "file:line",
                                         "reason", "kind" } ] }
```

`dead_code_scan` reasons: `no_callers` (an indexed `fn` whose name appears nowhere else in the
code files; `main`, `test*` and `tests/` are skipped), `no_emitters` (an event kind in
`docs/observability/EVENT_REGISTRY.yaml` that no code file mentions) and `registered_unused_route`
(a `.route("/path", ..)` whose path, up to the first parameter segment, nothing else references).
All three are textual heuristics: treat findings as leads to verify (for example with
`code.callers_of`), not proof. `trait_impls` sees single-line `impl` headers only.

Smoke tests: `scripts/ci/test-mcp-code-smoke.sh`, `scripts/ci/test-mcp-code-phase1.sh`,
`scripts/ci/test-mcp-code-phase3.sh`.
