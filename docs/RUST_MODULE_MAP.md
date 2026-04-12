# Rust module map

Map of `src/*.rs` and the `chump-tool-macro` crate to responsibility. Use this for the implementation section of the dossier and for navigating the codebase.

## Binary and entry

| Module | Responsibility |
|--------|----------------|
| `src/main.rs` | Entry point: load_dotenv, CLI flags (--check-config, --notify, --chump-due, --warm-probe, --web, --discord, --chump), dispatch to web_server, discord, or agent_loop. |

## Agent loop and context

| Module | Responsibility |
|--------|----------------|
| `agent_loop.rs` | Main agent loop: turn handling, tool dispatch, stream events. |
| `session.rs` | Session state and message history. |
| `context_assembly.rs` | Assemble system + round-filtered context (soul, brain, portfolio, playbook). |
| `context_window.rs` | Token window and summarization threshold. |
| `stream_events.rs` | Streaming event handling. |

## Provider and model

| Module | Responsibility |
|--------|----------------|
| `local_openai.rs` | OpenAI-compatible API client (single provider). |
| `streaming_provider.rs` | Streaming chat completion. |
| `provider_cascade.rs` | Multi-slot cascade: priority, fallbacks, warm_probe_all. |
| `provider_quality.rs` | Provider quality / sanity checks. |

## Discord

| Module | Responsibility |
|--------|----------------|
| `discord.rs` | Serenity client, message handling, @mention and DM routing. |
| `discord_dm.rs` | Send DM (e.g. notify, ready DM). |

## Web server and PWA

| Module | Responsibility |
|--------|----------------|
| `web_server.rs` | Axum router, API routes, static serving, CORS. |
| `web_sessions_db.rs` | Session CRUD for web UI. |
| `web_uploads.rs` | File upload and serve. |
| `web_brain.rs` | Brain API: research, watch, projects, briefing, ingest. |

## Tool infrastructure

| Module | Responsibility |
|--------|----------------|
| `tool_routing.rs` | Route tool name to tool implementation. |
| `tool_inventory.rs` | Tool registration (inventory). |
| `tool_middleware.rs` | Middleware (e.g. output trimming). |
| `tool_policy.rs` | Allow/deny/ask policy; risk heuristics. |
| `tool_health_db.rs` | Tool health / circuit state. |
| `toolkit_status_tool.rs` | Toolkit status tool implementation. |

## Repo and git tools

| Module | Responsibility |
|--------|----------------|
| `repo_tools.rs` | read_file, list_dir, write_file, patch_file. |
| `repo_path.rs` | CHUMP_REPO/CHUMP_HOME resolution, runtime_base. |
| `repo_allowlist.rs` | Repo allowlist for git/gh. |
| `repo_allowlist_tool.rs` | Repo allowlist tool. |
| `set_working_repo_tool.rs` | set_working_repo tool. |
| `onboard_repo_tool.rs` | onboard_repo tool. |
| `git_tools.rs` | git_* tools. |
| `gh_tools.rs` | gh_* CLI tools. |
| `github_tools.rs` | github_* API tools. |

## Memory and state

| Module | Responsibility |
|--------|----------------|
| `memory_tool.rs` | memory store/recall tool. |
| `memory_db.rs` | SQLite FTS5 memory; optional semantic RRF. |
| `memory_brain_tool.rs` | memory_brain wiki tool. |
| `state_db.rs` | chump_state DB. |
| `episode_db.rs` | chump_episodes. |
| `episode_tool.rs` | episode tool. |
| `task_db.rs` | chump_tasks. |
| `task_tool.rs` | task tool. |
| `schedule_db.rs` | chump_scheduled. |
| `schedule_tool.rs` | schedule tool. |
| `ego_tool.rs` | ego (inner state) tool. |

## Other tools

| Module | Responsibility |
|--------|----------------|
| `calc_tool.rs` | calculator. |
| `cli_tool.rs` | run_cli (allowlist/blocklist, timeout, cap). |
| `delegate_tool.rs` | delegate (summarize, extract, classify, validate). |
| `tavily_tool.rs` | web_search (Tavily). |
| `diff_review_tool.rs` | diff_review. |
| `battle_qa_tool.rs` | run_battle_qa. |
| `run_test_tool.rs` | run_test. |
| `test_aware.rs` | Test-aware editing support. |
| `spawn_worker_tool.rs` | spawn_worker. |
| `notify_tool.rs` | notify (DM owner). |
| `read_url_tool.rs` | read_url. |
| `codebase_digest_tool.rs` | codebase_digest. |
| `decompose_task_tool.rs` | decompose_task. |
| `introspect_tool.rs` | introspect. |
| `a2a_tool.rs` | message_peer (agent-to-agent). |
| `adb_tool.rs` | ADB tool (Pixel/Termux). |
| `ask_jeff_tool.rs` | ask_jeff. |
| `ask_jeff_db.rs` | ask_jeff persistence. |
| `wasm_calc_tool.rs` | wasm_calc. |
| `wasm_text_tool.rs` | wasm_text. |
| `wasm_runner.rs` | WASM runner (wasmtime CLI). |

## Infrastructure

| Module | Responsibility |
|--------|----------------|
| `db_pool.rs` | r2d2 SQLite pool. |
| `chump_log.rs` | Logging, redaction. |
| `limits.rs` | Message/tool input caps. |
| `approval_resolver.rs` | Tool approval request/resolution map. |
| `config_validation.rs` | validate_config at startup. |
| `version.rs` | chump_version(). |
| `health_server.rs` | Health HTTP server (CHUMP_HEALTH_PORT). |
| `file_watch.rs` | File watching. |
| `cost_tracker.rs` | Cost tracking. |

## Optional / feature-gated

| Module | Responsibility |
|--------|----------------|
| `embed_inprocess.rs` | In-process embeddings (feature `inprocess-embed`). |

## Proc-macro crate

| Crate / module | Responsibility |
|----------------|----------------|
| `chump-tool-macro` | Proc macro `#[chump_tool(name, description, schema)]` for Tool impl: expands to name, description, input_schema, execute. |
