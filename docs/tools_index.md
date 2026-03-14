# Tool Index

_Chump maintains this. Update when you install, learn, or drop a tool. Run `./scripts/verify-toolkit.sh` to refresh installed status. Copy to `chump-brain/tools/_index.md` to use as your living index._

Last verified: (run verify-toolkit.sh to update)

## Native Tools (always available)

| Tool | Purpose | Notes |
|---|---|---|
| read_file | Read file in repo | Path under CHUMP_REPO. Use instead of cat. Large files (over CHUMP_READ_FILE_MAX_CHARS) get auto-summary + last 500 chars. |
| list_dir | List directory | Use instead of ls. |
| edit_file | Change specific text | Exact string match. Safer than write_file for edits. |
| write_file | Create/overwrite file | Use for new files or full rewrites. |
| memory | Store/recall facts | SQLite + FTS5. Keyword searchable. |
| web_search | Search the web | Tavily. Limited credits. One focused query. |
| read_url | Fetch and extract web page | Full page text; optional CSS selector. Use for docs/READMEs. |
| toolkit_status | Report installed CLI tools | Returns JSON from verify-toolkit.sh. Use before discovery. |
| task | Task queue | create/list/update/complete. Check at session start. |
| schedule | Set alarms | fire_at as 4h/2d/30m. Heartbeat runs due items first. |
| notify | DM the owner | When blocked or something is ready. |
| ego | Inner state | current_focus, mood, frustrations, recent_wins. |
| episode | Log events | summary + sentiment. Check recent at session start. |
| memory_brain | Wiki/notes | Persistent markdown files. This index is here. |
| delegate | Summarize, extract, classify, validate | Worker model. Saves main-model tokens. classify = routing; validate = quality guard. |
| diff_review | Self-review diff | Runs delegate with code-review prompt. Before commit. |
| calculator | Math | Basic arithmetic. |
| wasm_calc | Sandboxed math | WASM. No host access. |
| git_commit | Commit | Always to chump/* branch. |
| git_push | Push | Always to chump/* branch. |
| gh_create_branch | Create branch | Via gh CLI. |
| gh_create_pr | Open PR | Via gh CLI. |
| gh_pr_checks | Check CI | Via gh CLI. |
| gh_list_issues | List issues | Filter by label/state. |
| github_repo_read | Read GitHub file | Via API. Repo must be in allowlist. |

## CLI Tools (check with verify-toolkit.sh or toolkit_status)

| Tool | Binary | Category | Installed | One-liner |
|---|---|---|---|---|
| ripgrep | rg | search | ? | Fast code search, .gitignore-aware |
| fd | fd | search | ? | Fast file finder |
| tree | tree | search | ? | Directory tree visualization |
| tokei | tokei | search | ? | Code line counts by language |
| ast-grep | ast-grep | search | ? | Structural code search (AST) |
| cargo-nextest | cargo-nextest | quality | ? | Faster test runner, better output |
| cargo-audit | cargo-audit | quality | ? | Security advisory check on deps |
| cargo-outdated | cargo-outdated | quality | ? | Find outdated dependencies |
| cargo-deny | cargo-deny | quality | ? | License + advisory + dup check |
| cargo-tarpaulin | cargo-tarpaulin | quality | ? | Code coverage |
| cargo-expand | cargo-expand | quality | ? | Macro expansion viewer |
| jq | jq | data | ? | JSON processor — use instead of grep on JSON |
| yq | yq | data | ? | YAML/TOML processor |
| xsv | xsv | data | ? | CSV processor |
| sd | sd | data | ? | Better sed — intuitive find-replace |
| htmlq | htmlq | data | ? | jq for HTML — extract with CSS selectors |
| bottom | btm | system | ? | System monitor (CPU/mem/disk/net) |
| dust | dust | system | ? | Visual disk usage (better du) |
| procs | procs | system | ? | Better ps — find/filter/sort processes |
| xh | xh | network | ? | Better curl — HTTPie-compatible |
| dog | dog | network | ? | Better dig — DNS lookups |
| git-delta | delta | git | ? | Readable diffs — syntax highlighting |
| git-absorb | git-absorb | git | ? | Auto-fixup commits |
| gitleaks | gitleaks | git | ? | Scan for leaked secrets |
| pandoc | pandoc | docs | ? | Universal doc converter |
| mdbook | mdbook | docs | ? | Docs site from markdown |
| just | just | automation | ? | Command runner (better make) |
| watchexec | watchexec | automation | ? | Run commands on file change |
| hyperfine | hyperfine | automation | ? | Benchmark CLI commands |
| nushell | nu | automation | ? | Structured shell — tables not text |
| ollama | ollama | ai | ? | Run additional models locally |

## Per-Tool Notes

_Create a file for each tool as you learn it: `tools/ripgrep.md`, `tools/jq.md`, etc._
_Include: common flags, recipes, gotchas, and when to use vs alternatives._
