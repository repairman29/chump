---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Tool Index

_Chump maintains this. Update when you install, learn, or drop a tool. Run `./scripts/verify-toolkit.sh` to refresh installed status. Copy to `chump-brain/tools/_index.md` to use as your living index._

Last verified: (run verify-toolkit.sh to update)

## Native Tools (always available)

| Tool | Purpose | Notes |
|---|---|---|
| read_file | Read file in repo | Path under CHUMP_REPO. Use instead of cat. Large files (over CHUMP_READ_FILE_MAX_CHARS) get auto-summary + last 500 chars. |
| list_dir | List directory | Use instead of ls. |
| patch_file | Apply unified diff to one file | Single-file diff (`path` or `file_path`, `diff`). Use read_file first; context must match. On mismatch, tool returns recovery text with numbered excerpt. |
| write_file | Create/overwrite/append file | Use for new files or full rewrites; append mode when appropriate. |
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
| wasm_text | Sandboxed reverse / upper / lower | WASM. No host access. |
| git_commit | Commit | Always to chump/* branch. |
| git_push | Push | Always to chump/* branch. |
| gh_create_branch | Create branch | Via gh CLI. |
| gh_create_pr | Open PR | Via gh CLI. |
| gh_pr_checks | Check CI | Via gh CLI. |
| gh_list_issues | List issues | Filter by label/state. |
| github_repo_read | Read GitHub file | Via API. Repo must be in allowlist. |
| browser | Browse and screenshot web pages | V2 stateless: `navigate url=<URL>` returns title + first 500 chars of body (reqwest+scraper, no deps); `screenshot url=<URL>` shells to `chromium --headless=new` and writes PNG to `chump-brain/screenshots/`. Session-based actions (open/click/fill) are stubbed — V3 work. Requires `CHUMP_BROWSER_AUTOAPPROVE=1` **or** `browser` in `CHUMP_TOOLS_ASK`. |

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

## Extended Native Tools

Tools implemented in `src/tools/` that are always available unless gated by an env flag.

| Tool | Purpose | Gate | Notes |
|---|---|---|---|
| `ask_jeff` | Send async question to owner | — | Priority: `blocking` (waits), `curious` (queued), `fyi` (fire-and-forget). Writes to `chump_tasks`. |
| `checkpoint` | Conversation rollback snapshots | — | Actions: `create`, `list`, `rollback`, `delete`. Stored in SQLite; useful before risky multi-step ops. |
| `codebase_digest` | Compressed repo summary | — | Writes `brain/projects/{name}/digest.md`. Accepts `max_files`, `exclude_patterns`. |
| `complete_onboarding` | Save FTUE answers | — | One-time; saves 5 onboarding answers and marks setup complete. No-ops after first call. |
| `decompose_task` | Break task into subtasks | — | Cascade LLM decomposes goal into disjoint-file subtasks. Writes plan to `chump_tasks`. |
| `introspect` | Recent tool call history | — | Queries `chump_tool_health` ring buffer. Args: `limit`, `tool_name` filter. |
| `memory_graph_viz` | Inspect associative memory graph | — | Actions: `stats`, `export_dot`, `export_json`, `demo_queries`. Visualizes entity nodes + edges. |
| `message_peer` | Agent-to-agent messaging | — | Sends messages to peer Chump instances over Discord. Args: `peer_id`, `message`, `priority`. |
| `onboard_repo` | 9-step repo onboarding | — | Writes `brief.md` + `architecture.md` to `brain/projects/{name}/`. Requires repo in allowlist. |
| `repo_authorize` | Add repo to allowlist | — | Adds a repo path to `CHUMP_REPO_ALLOWLIST`. Required before `onboard_repo` or `github_repo_read`. |
| `repo_deauthorize` | Remove repo from allowlist | — | Removes a repo from the allowlist. |
| `run_battle_qa` | Run smoke / full battle QA | — | Runs battle QA suite from inside Chump. Args: `suite` (`smoke`\|`full`), `scenario_filter`. |
| `run_test` | Run cargo/npm/pnpm tests | — | Returns structured pass/fail summary. Detects runner from workspace. Args: `path`, `filter`. |
| `sandbox` | Shell command in isolated worktree | `CHUMP_SANDBOX_ENABLED=1` | Creates detached git worktree, runs command, returns stdout/stderr. Safe for risky ops. |
| `screen_vision` | Screenshot + vision query | `CHUMP_SCREEN_VISION_ENABLED=1` | Captures via `screencapture` (macOS) or ADB (Android). Passes image to vision model. |
| `session_search` | Cross-session memory search | — | FTS5 over `chump_web_messages`. Args: `query`, `limit`, `session_id` filter. |
| `set_working_repo` | Set active repo for multi-repo mode | `CHUMP_MULTI_REPO_ENABLED=1` | Sets process-scoped repo root. Persists for session duration. |
| `skill_hub` | Install skills from registries | — | Actions: `search`, `list_registries`, `install`, `install_url`, `index_info`. Fetches `SKILL.md` files. |
| `skill_manage` | Manage local skills | — | Actions: `list`, `view`, `create`, `patch`, `edit`, `delete`, `record_outcome`. Skills live in `brain/skills/`. |
| `spawn_worker` | Ephemeral sub-agent | `CHUMP_SPAWN_WORKERS_ENABLED=1` | Isolated git worktree + restricted tool set. Returns transcript. Args: `goal`, `worktree_path`. |
| `task_planner` | Write ordered multi-step plan | — | Writes plan into `chump_tasks` with dependencies. Args: `goal`, `steps[]`, `context`. |

## Per-Tool Notes

_Create a file for each tool as you learn it: `tools/ripgrep.md`, `tools/jq.md`, etc._
_Include: common flags, recipes, gotchas, and when to use vs alternatives._
