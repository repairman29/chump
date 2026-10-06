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

Smoke test: `scripts/ci/test-mcp-code-smoke.sh`.
