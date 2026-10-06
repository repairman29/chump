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

Smoke tests: `scripts/ci/test-mcp-code-smoke.sh`, `scripts/ci/test-mcp-code-phase1.sh`.
