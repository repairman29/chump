# ENV_VARS_RAW — Chump environment variable audit

Generated: 2026-05-08T17:28:16Z
Source: `grep -rn 'std::env::var\|env::var(' src/`

| Variable | File(s) | Context (comment above call, if any) |
|----------|---------|--------------------------------------|
| ANTHROPIC_API_KEY                                       | src/auth.rs:142, src/chump_init.rs:221, src/chump_init.rs:365 |                                          |
| CARGO_MANIFEST_DIR                                      | src/vector6_verify.rs:75, src/vector7_swarm_verify.rs:50     |                                          |
| CHUMP_A2A_CHANNEL_ID                                    | src/a2a_tool.rs:22, src/a2a_tool.rs:71, src/discord.rs:773   |                                          |
| CHUMP_A2A_PEER_USER_ID                                  | src/a2a_tool.rs:15, src/a2a_tool.rs:79, src/discord.rs:748, src/discord.rs:780, src/tool_routing.rs:351 |                                          |
| CHUMP_ACTIVATION_DISABLED                               | src/activation.rs:146                                        |                                          |
| CHUMP_ADAPTIVE_OUTCOME_WINDOW                           | src/precision_controller.rs:76                               |                                          |
| CHUMP_ADB_DEVICE                                        | src/screen_vision_tool.rs:18, src/screen_vision_tool.rs:85   |                                          |
| CHUMP_ADB_ENABLED                                       | src/screen_vision_tool.rs:15                                 |                                          |
| CHUMP_ADVERSARY_ENABLED                                 | src/adversary.rs:240                                         |                                          |
| CHUMP_ADVERSARY_MODEL                                   | src/adversary_llm.rs:119                                     |                                          |
| CHUMP_ADVERSARY_MODE                                    | src/adversary.rs:46                                          |                                          |
| CHUMP_AGENT_MAX_ITER                                    | src/agent_factory.rs:68                                      |                                          |
| CHUMP_AGENT_MODEL                                       | src/reflection_db.rs:309                                     |                                          |
| CHUMP_AIR_GAP_MODE                                      | src/env_flags.rs:21                                          |                                          |
| CHUMP_ALLOW_DISCORD_RUSTLS                              | src/main.rs:3970                                             |                                          |
| CHUMP_ALLOW_GAP_REWRITE                                 | src/gap_store.rs:504                                         |                                          |
| CHUMP_ALLOW_LOCAL_SSRF                                  | src/tool_middleware.rs:935                                   |                                          |
| CHUMP_ALLOW_RECYCLE                                     | src/gap_store.rs:487                                         |                                          |
| CHUMP_AMBIENT_IN_PROMPT                                 | src/agent_loop/prompt_assembler.rs:245                       |                                          |
| CHUMP_AMBIENT_LOG                                       | src/activation.rs:158, src/adversary.rs:255, src/agent_loop/prompt_assembler.rs:29, src/auth.rs:379, src/bin/bandit-replay.rs:43, src/blocker_detect.rs:187, src/dispatch.rs:422, src/operator_presence.rs:266, src/provider_cascade.rs:32 |                                          |
| CHUMP_AMBIENT_NATS                                      | src/adversary.rs:301, src/dispatch.rs:453                    |                                          |
| CHUMP_APPROVAL_TIMEOUT_SECS                             | src/approval_resolver.rs:36                                  |                                          |
| CHUMP_AUTH_MODE                                         | src/auth.rs:235, src/auth.rs:31                              |                                          |
| CHUMP_AUTONOMOUS_DAILY_COST_CAP_USD                     | src/operator_presence.rs:69                                  |                                          |
| CHUMP_AUTONOMOUS_DIGEST_PATH                            | src/operator_presence.rs:60                                  |                                          |
| CHUMP_AUTONOMY_ASSIGNEE                                 | src/main.rs:3824                                             |                                          |
| CHUMP_AUTONOMY_OWNER                                    | src/autonomy_loop.rs:380, src/task_db.rs:308                 |                                          |
| CHUMP_AUTO_APPROVE_LOW_RISK                             | src/tool_policy.rs:96                                        |                                          |
| CHUMP_AUTO_APPROVE_TOOLS                                | src/tool_policy.rs:48                                        |                                          |
| CHUMP_AUTO_PRIVACY                                      | src/provider_cascade.rs:795                                  |                                          |
| CHUMP_AUTO_PUBLISH                                      | src/git_tools.rs:260, src/system_prompt.rs:246, src/tool_routing.rs:247 |                                          |
| CHUMP_AUTO_PUSH                                         | src/system_prompt.rs:249                                     |                                          |
| CHUMP_BALANCED_THRESHOLD                                | src/precision_controller.rs:58                               |                                          |
| CHUMP_BANDIT_STRATEGY                                   | src/provider_cascade.rs:360                                  |                                          |
| CHUMP_BASE_BRANCH                                       | src/atomic_claim.rs:94                                       |                                          |
| CHUMP_BATTLE_BENCHMARK                                  | src/precision_controller.rs:610                              |                                          |
| CHUMP_BATTLE_LABEL                                      | src/main.rs:4091                                             |                                          |
| CHUMP_BATTLE_PRINT_METRICS                              | src/precision_controller.rs:746                              |                                          |
| CHUMP_BELIEF_TOOL_BUDGET                                | src/env_flags.rs:42                                          |                                          |
| CHUMP_BINARY_STALENESS_CHECK                            | src/version.rs:134                                           |                                          |
| CHUMP_BIN                                               | src/orchestrate.rs:68                                        |                                          |
| CHUMP_BLACKBOARD_BROADCAST_THRESHOLD                    | src/blackboard.rs:230                                        |                                          |
| CHUMP_BLACKBOARD_MAX_AGE_SECS                           | src/blackboard.rs:226                                        |                                          |
| CHUMP_BRAIN_AUTOLOAD                                    | src/context_assembly.rs:237                                  |                                          |
| CHUMP_BRAIN_PATH                                        | src/codebase_digest_tool.rs:16, src/config_validation.rs:12, src/context_assembly.rs:122, src/doctor.rs:318, src/memory_brain_tool.rs:59, src/onboard_repo_tool.rs:15, src/skills.rs:118, src/web_brain.rs:11, src/web_server.rs:827 |                                          |
| CHUMP_BROWSER_AUTOAPPROVE                               | src/browser_tool.rs:242, src/browser_tool.rs:41              |                                          |
| CHUMP_BYPASS_BLACKBOARD                                 | src/env_flags.rs:267                                         |                                          |
| CHUMP_BYPASS_CLOSED_PR_GUARD                            | src/gap_store.rs:434                                         |                                          |
| CHUMP_BYPASS_NEUROMOD                                   | src/env_flags.rs:245                                         |                                          |
| CHUMP_BYPASS_PERCEPTION                                 | src/env_flags.rs:226                                         |                                          |
| CHUMP_BYPASS_SPAWN_LESSONS                              | src/env_flags.rs:289                                         |                                          |
| CHUMP_CASCADE_ENABLED                                   | src/main.rs:4216, src/provider_cascade.rs:112, src/routes/health.rs:98, src/system_prompt.rs:156 |                                          |
| CHUMP_CASCADE_RETRY_AFTER_EXHAUSTED_S                   | src/provider_cascade.rs:815                                  |                                          |
| CHUMP_CASCADE_RPM_HEADROOM                              | src/provider_cascade.rs:118                                  |                                          |
| CHUMP_CASCADE_STRATEGY                                  | src/provider_cascade.rs:337                                  |                                          |
| CHUMP_CIRCUIT_COOLDOWN_SECS                             | src/local_openai.rs:608                                      |                                          |
| CHUMP_CIRCUIT_FAILURE_THRESHOLD                         | src/local_openai.rs:600                                      |                                          |
| CHUMP_CLI_ALLOWLIST                                     | src/cli_tool.rs:127                                          |                                          |
| CHUMP_CLI_BLOCKLIST                                     | src/cli_tool.rs:136                                          |                                          |
| CHUMP_CLI_TIMEOUT_SECS                                  | src/cli_tool.rs:145                                          |                                          |
| CHUMP_CLUSTER_MODE                                      | src/vector6_verify.rs:71                                     |                                          |
| CHUMP_COG027_GATE                                       | src/agent_loop/prompt_assembler.rs:79                        |                                          |
| CHUMP_COMPACT_ENABLED                                   | src/session_compact.rs:35                                    |                                          |
| CHUMP_COMPACT_KEEP_TURNS                                | src/session_compact.rs:48                                    |                                          |
| CHUMP_COMPACT_THRESHOLD                                 | src/session_compact.rs:41                                    |                                          |
| CHUMP_COMPLETION_MAX_TOKENS                             | src/env_flags.rs:199                                         |                                          |
| CHUMP_CONSCIOUSNESS_ENABLED                             | src/context_assembly.rs:156, src/context_assembly.rs:639     |                                          |
| CHUMP_CONTEXT_ENGINE                                    | src/context_engine.rs:193                                    |                                          |
| CHUMP_CONTEXT_HYBRID_MEMORY                             | src/context_window.rs:49                                     |                                          |
| CHUMP_CONTEXT_MAX_TOKENS                                | src/context_window.rs:13                                     |                                          |
| CHUMP_CONTEXT_MEMORY_SNIPPETS                           | src/context_window.rs:60                                     |                                          |
| CHUMP_CONTEXT_SUMMARY_THRESHOLD_AUTONOMY                | src/context_engine.rs:123                                    |                                          |
| CHUMP_CONTEXT_SUMMARY_THRESHOLD_LIGHT                   | src/context_engine.rs:102                                    |                                          |
| CHUMP_CONTEXT_SUMMARY_THRESHOLD_RESEARCH                | src/context_engine.rs:151                                    |                                          |
| CHUMP_CONTEXT_SUMMARY_THRESHOLD                         | src/context_engine.rs:69, src/context_window.rs:22           |                                          |
| CHUMP_CONTEXT_VERBATIM_TURNS                            | src/context_window.rs:39                                     |                                          |
| CHUMP_COS_WEEKLY_MAX_CHARS                              | src/context_assembly.rs:94                                   |                                          |
| CHUMP_CURRENT_ROUND_TYPE                                | src/provider_cascade.rs:417                                  |                                          |
| CHUMP_CURRENT_SLOT_CONTEXT_K                            | src/context_window.rs:26                                     |                                          |
| CHUMP_CURSOR_CLI                                        | src/system_prompt.rs:263                                     |                                          |
| CHUMP_DAILY_BUDGET                                      | src/fleet_health.rs:130, src/main.rs:2751                    |                                          |
| CHUMP_DB_PASSPHRASE                                     | src/db_pool.rs:692                                           |                                          |
| CHUMP_DEBUG_LOG_PATH                                    | src/memory_brain_tool.rs:261                                 |                                          |
| CHUMP_DEBUG_LOG                                         | src/discord.rs:21                                            |                                          |
| CHUMP_DELEGATE_CONCURRENT                               | src/delegate_tool.rs:44                                      |                                          |
| CHUMP_DELEGATE_MAX_PARALLEL                             | src/precision_controller.rs:240, src/precision_controller.rs:977 |                                          |
| CHUMP_DELEGATE_PREPROCESS_CHARS                         | src/tool_middleware.rs:1239                                  |                                          |
| CHUMP_DELEGATE_PREPROCESS                               | src/tool_middleware.rs:1232                                  |                                          |
| CHUMP_DELEGATE                                          | src/delegate_tool.rs:20                                      |                                          |
| CHUMP_DISABLE_ASK_JEFF                                  | src/ask_jeff_db.rs:86                                        |                                          |
| CHUMP_DISCORD_ENABLED                                   | src/main.rs:3949                                             |                                          |
| CHUMP_DISPATCH_BACKEND                                  | src/main.rs:1151                                             |                                          |
| CHUMP_DISPATCH_DEPTH                                    | src/execute_gap.rs:142                                       |                                          |
| CHUMP_DISPATCH_HANG_TIMEOUT_SECS                        | src/dispatch.rs:383                                          |                                          |
| CHUMP_DOCKER_IMAGE                                      | src/execution/docker.rs:36                                   |                                          |
| CHUMP_DOCKER_MOUNT                                      | src/execution/docker.rs:37                                   |                                          |
| CHUMP_DOCKER_NETWORK                                    | src/execution/docker.rs:39                                   |                                          |
| CHUMP_EMBED_CACHE_DIR                                   | src/embed_inprocess.rs:14                                    |                                          |
| CHUMP_EMBED_INPROCESS                                   | src/memory_tool.rs:40                                        |                                          |
| CHUMP_EMBED_URL                                         | src/doctor.rs:283, src/health_server.rs:20, src/memory_tool.rs:1143, src/memory_tool.rs:26, src/memory_tool.rs:36 |                                          |
| CHUMP_EVAL_WITH_JUDGE                                   | src/main.rs:4330, src/main.rs:4608                           |                                          |
| CHUMP_EXECUTION                                         | src/execution/mod.rs:96                                      |                                          |
| CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS                        | src/cli_tool.rs:182                                          |                                          |
| CHUMP_EXECUTIVE_MODE                                    | src/cli_tool.rs:168, src/config_validation.rs:23             |                                          |
| CHUMP_EXECUTIVE_TIMEOUT_SECS                            | src/cli_tool.rs:174                                          |                                          |
| CHUMP_EXPLOIT_THRESHOLD                                 | src/precision_controller.rs:51                               |                                          |
| CHUMP_EXPLORE_THRESHOLD                                 | src/precision_controller.rs:65                               |                                          |
| CHUMP_EXTRACT_BATCH                                     | src/episode_extractor.rs:52                                  |                                          |
| CHUMP_EXTRACT_FACT_CHARS                                | src/episode_extractor.rs:59                                  |                                          |
| CHUMP_FALLBACK_API_BASE                                 | src/delegate_tool.rs:77, src/memory_graph.rs:578, src/provider_cascade.rs:1389, src/provider_cascade.rs:1405, src/provider_cascade.rs:261 |                                          |
| CHUMP_FIX_CLIPPY_REPO                                   | src/pr_fix_clippy.rs:66                                      |                                          |
| CHUMP_FLAGS                                             | src/runtime_flags.rs:47                                      |                                          |
| CHUMP_FLEET_MERGE_APPROVE                               | src/fleet_tool.rs:404                                        |                                          |
| CHUMP_FLEET_PEER_ID                                     | src/fleet.rs:117                                             |                                          |
| CHUMP_FORCE_JSON_TOOLS                                  | src/local_openai.rs:1069                                     |                                          |
| CHUMP_FRUSTRATION_THRESHOLD                             | src/tool_middleware.rs:80                                    |                                          |
| CHUMP_GAP_ID                                            | src/agent_loop/prompt_assembler.rs:252                       |                                          |
| CHUMP_GEN_STUB_FILE                                     | src/gen.rs:112                                               |                                          |
| CHUMP_GH                                                | src/pr_fix_clippy.rs:29, src/pr_triage.rs:19                 |                                          |
| CHUMP_GITHUB_REPOS                                      | src/config_validation.rs:85, src/repo_allowlist.rs:8, src/system_prompt.rs:241 |                                          |
| CHUMP_GIT_AUTHOR_EMAIL                                  | src/git_tools.rs:82                                          |                                          |
| CHUMP_GIT_AUTHOR_NAME                                   | src/git_tools.rs:80                                          |                                          |
| CHUMP_GRAPH_MAX_HOPS                                    | src/memory_tool.rs:633                                       |                                          |
| CHUMP_HEALTH_PORT                                       | src/main.rs:3985, src/main.rs:4068                           |                                          |
| CHUMP_HEARTBEAT_DURATION                                | src/context_assembly.rs:605                                  |                                          |
| CHUMP_HEARTBEAT_ELAPSED                                 | src/context_assembly.rs:603                                  |                                          |
| CHUMP_HEARTBEAT_ROUND                                   | src/context_assembly.rs:601, src/main.rs:4136                |                                          |
| CHUMP_HEARTBEAT_TYPE                                    | src/context_assembly.rs:208, src/context_assembly.rs:602, src/context_assembly.rs:614, src/context_engine.rs:140, src/env_flags.rs:121, src/interrupt_notify.rs:18, src/main.rs:4085, src/system_prompt.rs:312 |                                          |
| CHUMP_HITL_PROACTIVE_DISABLED                           | src/hitl_escalation.rs:147                                   |                                          |
| CHUMP_HOME                                              | src/acp_server.rs:169, src/auth.rs:339, src/chump_init.rs:212, src/cli_tool.rs:338, src/diff_review_tool.rs:168, src/diff_review_tool.rs:193, src/discord.rs:166, src/doctor.rs:186, src/doctor.rs:533, src/git_tools.rs:17, src/git_tools.rs:37, src/plugin.rs:137, src/plugin.rs:231, src/plugin.rs:565, src/plugin.rs:602, src/plugin.rs:634, src/plugin.rs:654, src/plugin.rs:673, src/plugin.rs:698, src/repo_path.rs:170, src/repo_path.rs:188, src/repo_path.rs:274, src/repo_path.rs:365, src/repo_path.rs:397, src/repo_tools.rs:604, src/repo_tools.rs:648, src/repo_tools.rs:698, src/repo_tools.rs:777, src/repo_tools.rs:794, src/repo_tools.rs:815, src/tool_middleware.rs:1704, src/web_server.rs:1283 |                                          |
| CHUMP_INCLUDE_COS_WEEKLY                                | src/context_assembly.rs:48                                   |                                          |
| CHUMP_INFERENCE_BACKEND                                 | src/env_flags.rs:8, src/web_server.rs:2641, src/web_server.rs:2693 |                                          |
| CHUMP_INFERENCE_PERMITS                                 | src/provider_cascade.rs:1423                                 |                                          |
| CHUMP_INTERRUPT_NOTIFY_POLICY                           | src/interrupt_notify.rs:7                                    |                                          |
| CHUMP_LEASE_GATE                                        | src/tool_middleware.rs:500                                   |                                          |
| CHUMP_LESSONS_AT_SPAWN_ACK                              | src/agent_loop/prompt_assembler.rs:15                        |                                          |
| CHUMP_LESSONS_AT_SPAWN_N                                | src/reflection_db.rs:418                                     |                                          |
| CHUMP_LESSONS_DENY_FAMILIES                             | src/reflection_db.rs:329                                     |                                          |
| CHUMP_LESSONS_EMBEDDING_MODEL                           | src/lesson_embeddings.rs:56                                  |                                          |
| CHUMP_LESSONS_EMBEDDING_TIMEOUT_MS                      | src/lesson_embeddings.rs:57                                  |                                          |
| CHUMP_LESSONS_EMBEDDING_URL                             | src/lesson_embeddings.rs:54                                  |                                          |
| CHUMP_LESSONS_EMBEDDING                                 | src/lesson_embeddings.rs:40                                  |                                          |
| CHUMP_LESSONS_MIN_TIER                                  | src/reflection_db.rs:252                                     |                                          |
| CHUMP_LESSONS_OPT_IN_MODELS                             | src/reflection_db.rs:279                                     |                                          |
| CHUMP_LESSONS_SEMANTIC                                  | src/reflection_db.rs:642                                     |                                          |
| CHUMP_LESSONS_TASK_AWARE                                | src/reflection_db.rs:1280                                    |                                          |
| CHUMP_LESSON_QUALITY_THRESHOLD                          | src/reflection_db.rs:450                                     |                                          |
| CHUMP_LIGHT_CHAT_HISTORY_MESSAGES                       | src/env_flags.rs:160                                         |                                          |
| CHUMP_LIGHT_COMPLETION_MAX_TOKENS                       | src/env_flags.rs:207                                         |                                          |
| CHUMP_LIGHT_CONTEXT                                     | src/context_engine.rs:91, src/env_flags.rs:105, src/env_flags.rs:79 |                                          |
| CHUMP_LIGHT_INCLUDE_BRAIN_AUTOLOAD                      | src/env_flags.rs:149                                         |                                          |
| CHUMP_LIGHT_INCLUDE_STATE_DB                            | src/env_flags.rs:137                                         |                                          |
| CHUMP_LLM_RETRY_DELAYS_MS                               | src/local_openai.rs:584                                      |                                          |
| CHUMP_LOGPROBS_ENABLED                                  | src/local_openai.rs:1024, src/local_openai.rs:1431           |                                          |
| CHUMP_LOG_STRUCTURED                                    | src/chump_log.rs:28                                          |                                          |
| CHUMP_LOG_TIMING                                        | src/discord.rs:394, src/local_openai.rs:1204, src/local_openai.rs:1400, src/provider_cascade.rs:1031, src/provider_cascade.rs:1101, src/provider_cascade.rs:1264, src/provider_cascade.rs:1270, src/provider_cascade.rs:222, src/provider_cascade.rs:481, src/provider_cascade.rs:490, src/provider_cascade.rs:497, src/provider_cascade.rs:507, src/provider_cascade.rs:513, src/provider_cascade.rs:851, src/provider_cascade.rs:905, src/provider_cascade.rs:987 |                                          |
| CHUMP_MABEL                                             | src/context_assembly.rs:812, src/discord.rs:713, src/discord.rs:854, src/system_prompt.rs:122 |                                          |
| CHUMP_MAX_CONCURRENT_TURNS                              | src/discord.rs:309                                           |                                          |
| CHUMP_MAX_CONSECUTIVE_TOOL_FAILS                        | src/agent_loop/iteration_controller.rs:25                    |                                          |
| CHUMP_MAX_CONTEXT_MESSAGES                              | src/local_openai.rs:790                                      |                                          |
| CHUMP_MAX_ITERATIONS                                    | src/web_server.rs:2116                                       |                                          |
| CHUMP_MAX_MESSAGE_LEN                                   | src/limits.rs:8                                              |                                          |
| CHUMP_MAX_TOOL_ARGS_LEN                                 | src/limits.rs:16                                             |                                          |
| CHUMP_MCP_SERVERS_DIR                                   | src/mcp_bridge.rs:36                                         |                                          |
| CHUMP_MEMORY_DB_PATH                                    | src/db_pool.rs:16                                            |                                          |
| CHUMP_MEMORY_DECAY_RATE                                 | src/memory_db.rs:346                                         |                                          |
| CHUMP_MEMORY_LLM_SUMMARIZE                              | src/main.rs:3766, src/memory_db.rs:626                       |                                          |
| CHUMP_MEMORY_MMR_LAMBDA                                 | src/memory_tool.rs:425                                       |                                          |
| CHUMP_MEMORY_RERANK                                     | src/memory_tool.rs:397                                       |                                          |
| CHUMP_MEMORY_SUMMARIZE_MAX_CLUSTERS                     | src/memory_db.rs:452                                         |                                          |
| CHUMP_MEMORY_SUMMARIZE_MIN_AGE_DAYS                     | src/memory_db.rs:448                                         |                                          |
| CHUMP_MEMORY_SUMMARIZE_MIN_CLUSTER                      | src/memory_db.rs:443                                         |                                          |
| CHUMP_MISTRALRS_FORCE_CPU                               | src/mistralrs_provider.rs:174                                |                                          |
| CHUMP_MISTRALRS_HF_REVISION                             | src/mistralrs_provider.rs:136                                |                                          |
| CHUMP_MISTRALRS_ISQ_BITS                                | src/mistralrs_provider.rs:63                                 |                                          |
| CHUMP_MISTRALRS_LOGGING                                 | src/mistralrs_provider.rs:180                                |                                          |
| CHUMP_MISTRALRS_MODEL                                   | src/env_flags.rs:11, src/provider_cascade.rs:1318, src/provider_cascade.rs:1380, src/routes/health.rs:103, src/web_server.rs:2642, src/web_server.rs:2694 |                                          |
| CHUMP_MISTRALRS_MOQE                                    | src/mistralrs_provider.rs:150                                |                                          |
| CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA                      | src/mistralrs_provider.rs:105                                |                                          |
| CHUMP_MISTRALRS_PAGED_ATTN                              | src/mistralrs_provider.rs:157                                |                                          |
| CHUMP_MISTRALRS_PREFIX_CACHE_N                          | src/mistralrs_provider.rs:92                                 |                                          |
| CHUMP_MISTRALRS_STREAM_TEXT_DELTAS                      | src/mistralrs_provider.rs:199                                |                                          |
| CHUMP_MISTRALRS_THROUGHPUT_LOGGING                      | src/mistralrs_provider.rs:167                                |                                          |
| CHUMP_MODEL_PREFLIGHT_TIMEOUT_SECS                      | src/discord.rs:323                                           |                                          |
| CHUMP_MODEL_REQUEST_TIMEOUT_SECS                        | src/local_openai.rs:932                                      |                                          |
| CHUMP_MULTI_REPO_ENABLED                                | src/repo_path.rs:475, src/set_working_repo_tool.rs:13, src/system_prompt.rs:269 |                                          |
| CHUMP_NEUROMOD_ENABLED                                  | src/neuromodulation.rs:84                                    |                                          |
| CHUMP_NEUROMOD_NA_ALPHA                                 | src/neuromodulation.rs:175                                   |                                          |
| CHUMP_NEUROMOD_SERO_ALPHA                               | src/neuromodulation.rs:183                                   |                                          |
| CHUMP_NEUROMOD_TELEMETRY_PATH                           | src/neuromodulation.rs:136                                   |                                          |
| CHUMP_NOTIFY_FULLY_ARMORED                              | src/discord.rs:719                                           |                                          |
| CHUMP_NOTIFY_INTERRUPT_EXTRA                            | src/interrupt_notify.rs:44                                   |                                          |
| CHUMP_NUM_CTX_WARN                                      | src/local_openai.rs:560                                      |                                          |
| CHUMP_OAUTH_TOKEN_FILE                                  | src/auth.rs:154                                              |                                          |
| CHUMP_OLLAMA_KEEP_ALIVE                                 | src/local_openai.rs:1037, src/web_server.rs:2520             |                                          |
| CHUMP_OLLAMA_NUM_CTX                                    | src/local_openai.rs:1031                                     |                                          |
| CHUMP_OPENAI_CONNECT_TIMEOUT_SECS                       | src/local_openai.rs:937                                      |                                          |
| CHUMP_OPERATOR_ABSENCE_THRESHOLD_HOURS                  | src/operator_presence.rs:46                                  |                                          |
| CHUMP_OPERATOR_ACTIVITY_PATH                            | src/operator_presence.rs:54                                  |                                          |
| CHUMP_OPERATOR_LAST_SEEN_UNIX                           | src/operator_presence.rs:99                                  |                                          |
| CHUMP_ORCHESTRATE_STUB                                  | src/orchestrate.rs:123                                       |                                          |
| CHUMP_PAUSED                                            | src/chump_log.rs:76                                          |                                          |
| CHUMP_PEER_APPROVE_TOOLS                                | src/pending_peer_approval.rs:13                              |                                          |
| CHUMP_PERCEPTION_ENABLED                                | src/agent_loop/perception_layer.rs:12                        |                                          |
| CHUMP_PHASE_TIMING                                      | src/agent_loop/context.rs:167, src/agent_loop/context.rs:58  |                                          |
| CHUMP_PLAIN_COT                                         | src/local_openai.rs:165                                      |                                          |
| CHUMP_PLAN_MODE                                         | src/plan_mode.rs:70                                          |                                          |
| CHUMP_POLICY_ALLOW_UNVERIFIED                           | src/task_contract.rs:267                                     |                                          |
| CHUMP_POLICY_OVERRIDE_API                               | src/policy_override.rs:27, src/web_server.rs:2777            |                                          |
| CHUMP_POLICY_SKIP_APPROVAL                              | src/task_contract.rs:286                                     |                                          |
| CHUMP_POWERMETRICS_BIN                                  | src/telemetry_energy.rs:167                                  |                                          |
| CHUMP_PREFER_LARGE_CONTEXT                              | src/provider_cascade.rs:532                                  |                                          |
| CHUMP_PREWARM                                           | src/web_server.rs:2511                                       |                                          |
| CHUMP_PROBE_THRESHOLD                                   | src/autonomy_loop.rs:200                                     |                                          |
| CHUMP_PROFILE_KEY_PATH                                  | src/user_profile.rs:146                                      |                                          |
| CHUMP_PROJECT_MODE                                      | src/system_prompt.rs:287                                     |                                          |
| CHUMP_RATE_LIMIT_TURNS_PER_MIN                          | src/discord.rs:273                                           |                                          |
| CHUMP_READY_DM_USER_ID                                  | src/discord.rs:708, src/discord.rs:815, src/discord.rs:979, src/discord_dm.rs:26 |                                          |
| CHUMP_READ_FILE_HARD_CAP_CHARS                          | src/repo_tools.rs:205, src/repo_tools.rs:699                 |                                          |
| CHUMP_READ_FILE_MAX_CHARS                               | src/repo_tools.rs:210, src/repo_tools.rs:268, src/repo_tools.rs:649, src/repo_tools.rs:700 |                                          |
| CHUMP_REASONING_BUDGET_TOKENS                           | src/reasoning_mode.rs:152, src/reasoning_mode.rs:187         |                                          |
| CHUMP_REASONING_EFFORT                                  | src/reasoning_mode.rs:171                                    |                                          |
| CHUMP_REASONING_MODE                                    | src/reasoning_mode.rs:51                                     |                                          |
| CHUMP_REFLECTION_AB_WITH_LLM                            | src/main.rs:5128                                             |                                          |
| CHUMP_REFLECTION_INJECTION                              | src/reflection_db.rs:107                                     |                                          |
| CHUMP_REFLECTION_LLM                                    | src/reflection.rs:463                                        |                                          |
| CHUMP_REFLECTION_STRICT_SCOPE                           | src/reflection_db.rs:1073                                    |                                          |
| CHUMP_REMOTE                                            | src/atomic_claim.rs:93                                       |                                          |
| CHUMP_REPO_PROFILES                                     | src/repo_path.rs:447, src/repo_path.rs:473, src/repo_path.rs:68 |                                          |
| CHUMP_REPO_ROOT                                         | src/agent_loop/prompt_assembler.rs:25                        |                                          |
| CHUMP_REPO                                              | src/acp_server.rs:172, src/cli_tool.rs:337, src/diff_review_tool.rs:167, src/diff_review_tool.rs:192, src/doctor.rs:185, src/doctor.rs:532, src/git_tools.rs:36, src/repo_path.rs:171, src/repo_path.rs:187, src/repo_path.rs:273, src/repo_path.rs:364, src/repo_path.rs:396, src/repo_path.rs:476, src/repo_tools.rs:603, src/repo_tools.rs:647, src/repo_tools.rs:697, src/repo_tools.rs:745, src/repo_tools.rs:763, src/repo_tools.rs:776, src/repo_tools.rs:793, src/repo_tools.rs:814, src/repo_tools.rs:845, src/repo_tools.rs:874, src/sandbox_tool.rs:316, src/system_prompt.rs:224, src/tool_middleware.rs:1611, src/tool_middleware.rs:1705, src/web_server.rs:1281 |                                          |
| CHUMP_RESERVE_NO_AUTOSTAGE                              | src/main.rs:2006                                             |                                          |
| CHUMP_RESERVE_SCAN_OPEN_PRS                             | src/gap_store.rs:1025                                        |                                          |
| CHUMP_RESERVE_VERIFY_SLEEP_MS                           | src/gap_store.rs:775                                         |                                          |
| CHUMP_RESERVE_VERIFY                                    | src/gap_store.rs:771                                         |                                          |
| CHUMP_RETRIEVAL_RERANK_WEIGHTS                          | src/memory_db.rs:1114                                        |                                          |
| CHUMP_ROUND_PRIVACY                                     | src/provider_cascade.rs:1179, src/provider_cascade.rs:776    |                                          |
| CHUMP_RPC_JSONL_LOG                                     | src/rpc_mode.rs:83                                           |                                          |
| CHUMP_SANDBOX_ALLOWLIST                                 | src/sandbox_tool.rs:41                                       |                                          |
| CHUMP_SANDBOX_DISK_BUDGET_MB                            | src/sandbox_tool.rs:54                                       |                                          |
| CHUMP_SANDBOX_ENABLED                                   | src/sandbox_tool.rs:25                                       |                                          |
| CHUMP_SANDBOX_SPECULATION                               | src/speculative_execution.rs:228                             |                                          |
| CHUMP_SANDBOX_TIMEOUT_SECS                              | src/sandbox_tool.rs:31                                       |                                          |
| CHUMP_SCREEN_VISION_ENABLED                             | src/screen_vision_tool.rs:27                                 |                                          |
| CHUMP_SESSION_ENERGY_TOKENS                             | src/precision_controller.rs:309, src/precision_controller.rs:357 |                                          |
| CHUMP_SESSION_ENERGY_TOOLS                              | src/precision_controller.rs:313                              |                                          |
| CHUMP_SESSION_ID                                        | src/activation.rs:175, src/adversary.rs:259, src/ambient_stream.rs:79, src/blocker_detect.rs:191, src/briefing.rs:192, src/dispatch.rs:426, src/main.rs:1003, src/main.rs:1931, src/main.rs:2069, src/main.rs:2127, src/main.rs:870, src/main.rs:932, src/provider_cascade.rs:36 |                                          |
| CHUMP_SHIP_NO_AUTOSTAGE                                 | src/main.rs:2202                                             |                                          |
| CHUMP_SIMULATE_SEED                                     | src/main.rs:2981                                             |                                          |
| CHUMP_SKILL_REGISTRIES                                  | src/skill_hub.rs:338                                         |                                          |
| CHUMP_SKILL_SUGGEST_THRESHOLD                           | src/agent_loop/orchestrator.rs:332                           |                                          |
| CHUMP_SPAWN_MAX_PARALLEL                                | src/spawn_worker_tool.rs:31                                  |                                          |
| CHUMP_SPAWN_WORKERS_ENABLED                             | src/spawn_worker_tool.rs:25                                  |                                          |
| CHUMP_SSH_HOST                                          | src/execution/ssh.rs:40                                      |                                          |
| CHUMP_SSH_OPTIONS                                       | src/execution/ssh.rs:49                                      |                                          |
| CHUMP_SSH_PORT                                          | src/execution/ssh.rs:45                                      |                                          |
| CHUMP_SSH_USER                                          | src/execution/ssh.rs:41                                      |                                          |
| CHUMP_STACK_PROBE_TIMEOUT_SECS                          | src/routes/health.rs:88                                      |                                          |
| CHUMP_STREAM_HTTP                                       | src/local_openai.rs:1081                                     |                                          |
| CHUMP_SYSTEM_PROMPT                                     | src/system_prompt.rs:285                                     |                                          |
| CHUMP_TASK_DECOMPOSE_THRESHOLD                          | src/autonomy_loop.rs:191                                     |                                          |
| CHUMP_TASK_LEASE_TTL_SECS                               | src/task_db.rs:316                                           |                                          |
| CHUMP_TASK_STUCK_SECS                                   | src/main.rs:3557                                             |                                          |
| CHUMP_TEMPERATURE                                       | src/local_openai.rs:1012, src/mistralrs_provider.rs:306      |                                          |
| CHUMP_TEST_AWARE                                        | src/test_aware.rs:17                                         |                                          |
| CHUMP_THINKING_LOG_MAX_CHARS                            | src/thinking_strip.rs:14                                     |                                          |
| CHUMP_THINKING_XML                                      | src/env_flags.rs:173                                         |                                          |
| CHUMP_THINKING                                          | src/local_openai.rs:373, src/main.rs:4213, src/system_prompt.rs:153 |                                          |
| CHUMP_TOKEN_ANOMALY_FACTOR                              | src/cost_watch.rs:302                                        |                                          |
| CHUMP_TOKEN_ANOMALY_WEBHOOK                             | src/cost_watch.rs:402                                        |                                          |
| CHUMP_TOOLS_ASK                                         | src/browser_tool.rs:245, src/browser_tool.rs:49, src/fleet_tool.rs:410, src/tool_policy.rs:17 |                                          |
| CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS                        | src/tool_middleware.rs:39                                    |                                          |
| CHUMP_TOOL_CIRCUIT_FAILURES                             | src/tool_middleware.rs:31                                    |                                          |
| CHUMP_TOOL_ENV_ALLOWLIST                                | src/tool_middleware.rs:914                                   |                                          |
| CHUMP_TOOL_EXAMPLES                                     | src/system_prompt.rs:108                                     |                                          |
| CHUMP_TOOL_MAX_IN_FLIGHT                                | src/tool_middleware.rs:176                                   |                                          |
| CHUMP_TOOL_PROFILE                                      | src/env_flags.rs:315                                         |                                          |
| CHUMP_TOOL_RATE_LIMIT_MAX                               | src/tool_middleware.rs:234                                   |                                          |
| CHUMP_TOOL_RATE_LIMIT_TOOLS                             | src/tool_middleware.rs:220                                   |                                          |
| CHUMP_TOOL_RATE_LIMIT_WINDOW_SECS                       | src/tool_middleware.rs:242                                   |                                          |
| CHUMP_TOOL_ROUTING                                      | src/agent_loop/orchestrator.rs:209                           |                                          |
| CHUMP_TOOL_TIMEOUT_SECS                                 | src/tool_middleware.rs:985                                   |                                          |
| CHUMP_TOOL_TIMEOUT_SEC                                  | src/task_executor.rs:148                                     |                                          |
| CHUMP_TRACING_FILE                                      | src/tracing_init.rs:75                                       |                                          |
| CHUMP_TTS_DISABLE                                       | src/web_server.rs:435                                        |                                          |
| CHUMP_TTS_PIPER_MODEL                                   | src/web_server.rs:474                                        |                                          |
| CHUMP_VAPID_PRIVATE_KEY_FILE                            | src/web_push_send.rs:14                                      |                                          |
| CHUMP_VAPID_PUBLIC_KEY                                  | src/web_server.rs:1669                                       |                                          |
| CHUMP_VAPID_SUBJECT                                     | src/web_push_send.rs:120                                     |                                          |
| CHUMP_VERIFY_POSTCONDITIONS                             | src/tool_middleware.rs:781                                   |                                          |
| CHUMP_VERSION                                           | src/version.rs:19                                            |                                          |
| CHUMP_VISION_API_BASE                                   | src/screen_vision_tool.rs:42                                 |                                          |
| CHUMP_VISION_ENABLED                                    | src/acp_server.rs:2033, src/web_uploads.rs:140               |                                          |
| CHUMP_VISION_MAX_IMAGE_BYTES                            | src/acp_server.rs:2025                                       |                                          |
| CHUMP_VISION_MODEL                                      | src/screen_vision_tool.rs:33                                 |                                          |
| CHUMP_VISION_TIMEOUT_SECS                               | src/screen_vision_tool.rs:57                                 |                                          |
| CHUMP_WARM_SERVERS                                      | src/discord.rs:160                                           |                                          |
| CHUMP_WASM_FUEL_BUDGET                                  | src/wasm_runner.rs:53                                        |                                          |
| CHUMP_WASM_FUEL_ENABLED                                 | src/wasm_runner.rs:61                                        |                                          |
| CHUMP_WEBHOOK_SLACK                                     | src/health.rs:575                                            |                                          |
| CHUMP_WEBHOOK_TOKEN                                     | src/health.rs:574                                            |                                          |
| CHUMP_WEBHOOK_URL                                       | src/health.rs:567                                            |                                          |
| CHUMP_WEB_HTTP_TRACE                                    | src/env_flags.rs:54                                          |                                          |
| CHUMP_WEB_INJECT_COS                                    | src/context_assembly.rs:45                                   |                                          |
| CHUMP_WEB_PORT                                          | src/chump_init.rs:35, src/chump_init.rs:553, src/main.rs:3915 |                                          |
| CHUMP_WEB_PUSH_AUTONOMY                                 | src/web_push_send.rs:26                                      |                                          |
| CHUMP_WEB_STATIC_DIR                                    | src/routes/shared.rs:22, src/web_server.rs:129               |                                          |
| CHUMP_WEB_TOKEN                                         | src/routes/shared.rs:9, src/web_server.rs:116, src/web_server.rs:2873 |                                          |
| CHUMP_WORKER_API_BASE                                   | src/delegate_tool.rs:66, src/memory_graph.rs:566             |                                          |
| CHUMP_WORKER_MODEL                                      | src/delegate_tool.rs:72, src/memory_graph.rs:572             |                                          |
| CHUMP_WORKTREE_BASE                                     | src/atomic_claim.rs:90                                       |                                          |
| CHUMP_WORKTREE_ROOT                                     | src/repo_path.rs:247, src/repo_path.rs:398                   |                                          |
| CLAUDE_CODE_OAUTH_TOKEN                                 | src/auth.rs:146                                              |                                          |
| CLAUDE_SESSION_ID                                       | src/activation.rs:176, src/adversary.rs:260, src/ambient_stream.rs:84, src/blocker_detect.rs:192, src/briefing.rs:193, src/dispatch.rs:427, src/main.rs:1004, src/main.rs:1932, src/main.rs:2068, src/main.rs:2126, src/main.rs:871, src/main.rs:933, src/provider_cascade.rs:37 |                                          |
| DISCORD_TOKEN                                           | src/a2a_tool.rs:63, src/config_validation.rs:48, src/discord_dm.rs:19, src/main.rs:3991 |                                          |
| FLEET_029_AMBIENT_GLANCE_SKIP                           | src/main.rs:1901, src/main.rs:2044                           |                                          |
| FLEET_MODEL                                             | src/chump_init.rs:242, src/orchestrate.rs:20, src/orchestrate.rs:247 |                                          |
| GITHUB_TOKEN                                            | src/autonomy_loop.rs:542, src/config_validation.rs:82, src/git_tools.rs:29 |                                          |
| HOME                                                    | src/auth.rs:340, src/chump_init.rs:215, src/discord.rs:28, src/dispatch.rs:480, src/main.rs:1236, src/mcp_discovery.rs:126, src/mcp_discovery.rs:440, src/operator_presence.rs:41, src/operator_presence.rs:63, src/session_export.rs:148 |                                          |
| HOSTNAME                                                | src/fleet.rs:93                                              |                                          |
| HOST                                                    | src/fleet.rs:98                                              |                                          |
| INFERENCE_MESH_IPHONE_URL                               | src/cluster_mesh.rs:49                                       |                                          |
| INFERENCE_MESH_MAC_URL                                  | src/cluster_mesh.rs:42                                       |                                          |
| OPENAI_API_BASE                                         | src/adversary_llm.rs:173, src/chump_init.rs:222, src/delegate_tool.rs:62, src/delegate_tool.rs:69, src/discord.rs:339, src/discord.rs:366, src/doctor.rs:172, src/doctor.rs:239, src/health_server.rs:13, src/memory_graph.rs:562, src/memory_graph.rs:569, src/provider_cascade.rs:1164, src/provider_cascade.rs:1386, src/provider_cascade.rs:255, src/routes/health.rs:93, src/screen_vision_tool.rs:45, src/web_server.rs:2516, src/web_server.rs:2695 |                                          |
| OPENAI_API_KEY                                          | src/adversary_llm.rs:175, src/chump_init.rs:413, src/memory_graph.rs:558, src/provider_cascade.rs:102, src/routes/health.rs:52, src/screen_vision_tool.rs:53 |                                          |
| OPENAI_MODEL                                            | src/delegate_tool.rs:75, src/execute_gap.rs:412, src/execute_gap.rs:437, src/main.rs:4333, src/main.rs:4609, src/main.rs:4775, src/memory_graph.rs:575, src/model_overlay.rs:257, src/model_overlay.rs:457, src/orchestrate.rs:128, src/provider_cascade.rs:1369, src/provider_cascade.rs:1385, src/provider_cascade.rs:260, src/reflection_db.rs:310, src/routes/health.rs:97, src/screen_vision_tool.rs:36, src/web_server.rs:2518 |                                          |
| PATH                                                    | src/execution/docker.rs:181, src/mcp_discovery.rs:142, src/mcp_discovery.rs:328, src/mcp_discovery.rs:364, src/mcp_discovery.rs:390, src/recipe.rs:143 |                                          |
| SLACK_API_BASE                                          | src/slack.rs:51                                              |                                          |
| SLACK_APP_TOKEN                                         | src/slack.rs:123                                             |                                          |
| SLACK_BOT_TOKEN                                         | src/slack.rs:119                                             |                                          |
| TAVILY_API_KEY                                          | src/config_validation.rs:93                                  |                                          |
| TELEGRAM_API_BASE                                       | src/telegram.rs:39                                           |                                          |
| TELEGRAM_BOT_TOKEN                                      | src/telegram.rs:70                                           |                                          |
| TELEGRAM_POLL_TIMEOUT_SECS                              | src/telegram.rs:45                                           |                                          |
| USER                                                    | src/execution/ssh.rs:43                                      |                                          |
| XDG_CONFIG_HOME                                         | src/mcp_discovery.rs:115, src/mcp_discovery.rs:425, src/mcp_discovery.rs:439 |                                          |

## Summary
Total unique env vars referenced in src/: **337**
