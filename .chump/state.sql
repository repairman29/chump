---
gaps:
- id: ACP-001
  domain: acp
  title: MCP server lifecycle — spawn, scope, and reap per ACP session
  status: done
  priority: P1
  effort: s
  description: |
    NewSessionRequest.mcpServers is recorded and persisted but servers are never spawned. Tools from MCP servers are unavailable during ACP sessions. On session end, child processes are not reaped (potential leak).
  source_doc: docs/ACP_V3_BACKLOG.md
  closed_date: '2026-04-17'

- id: ACP-002
  domain: acp
  title: Vision-capable model passthrough via ACP
  status: done
  priority: P2
  effort: m
  description: |
    ContentBlock::Image becomes a text placeholder. Models with vision capability (llava-on-Ollama, gpt-4o) cannot receive images through the ACP path.
  notes: |
    flatten_prompt_blocks() encodes image+text blocks as JSON array string when CHUMP_VISION_ENABLED=1; local_openai.rs detects content.starts_with('[') and deserializes to Value::Array for OpenAI multipart messages. vision_max_image_bytes() caps images at 4MB (CHUMP_VISION_MAX_IMAGE_BYTES). All vision tests use #[serial_test::serial] to avoid env-var races.
  source_doc: docs/ACP_V3_BACKLOG.md
  closed_date: '2026-04-17'

- id: ACP-003
  domain: acp
  title: Real-editor integration tests — Zed and JetBrains CI
  status: done
  priority: P2
  effort: l
  description: |
    88 ACP unit tests use simulated client. Real Zed and JetBrains clients have never been exercised by CI. Wire-level JSON-RPC not snapshot-tested. Spec drift will not break builds.
  notes: |
    Heavy CI setup (JDK + JetBrains gateway). Realistic estimate: 2-4 weeks.
  source_doc: docs/ACP_V3_BACKLOG.md
  closed_date: '2026-04-16'

- id: ACP-004
  domain: acp
  title: Thinking streaming for reasoning models via ACP
  status: done
  priority: P2
  effort: s
  description: |
    Reasoning tokens (Qwen3 <think>, Claude extended thinking) are stripped or silently dropped. ACP clients cannot observe reasoning traces.
  notes: |
    ThinkStreamState in local_openai.rs routes <think> content to AgentEvent::ThinkingDelta → SessionUpdate::Thinking. ACP.md documents the thinking event type (mid-stream + TurnComplete sources).
  source_doc: docs/ACP_V3_BACKLOG.md
  closed_date: '2026-04-17'

- id: AGT-001
  domain: agent
  title: Explicit AgentState FSM in iteration_controller
  status: done
  priority: P1
  effort: m
  description: |
    The agent loop is implicit and procedural: a for-loop counter, a StopReason enum from the provider, and local variables for tracking tool-call counts. There is no explicit state that can be observed, interrupted, or resumed. autonomy_fsm.rs demonstrates the typestate pattern already — apply it to the main loop. States: Idle | LlmWaiting { query } | ToolsRunning { pending } | Interrupted { reason, prev_state } | Complete { outcome }.
  source_doc: src/agent_loop/iteration_controller.rs
  closed_date: '2026-04-17'

- id: AGT-002
  domain: agent
  title: "Cancellation token + tokio::select! interrupt loop"
  status: done
  priority: P1
  effort: m
  description: |
    The agent loop runs to max_iterations or natural completion with no cancellation capability. A new message arriving while the agent is mid-LLM-call is silently queued at best; there is no way for the web UI's "Stop" button or an incoming platform event to preempt the running turn. This is the key enabler for ambient / interrupt-driven behaviour described in the hot/cold path architecture. Mechanism: tokio_util::CancellationToken threaded through the loop. Each LLM await becomes tokio::select! { result = provider.complete() => ..., _ = cancel.cancelled() => transition to Interrupted }.
  depends_on: [AGT-001]
  source_doc: src/agent_loop/iteration_controller.rs
  closed_date: '2026-04-18'

- id: AGT-003
  domain: agent
  title: "Per-tool execution timeout with tokio::time::timeout"
  status: done
  priority: P2
  effort: s
  description: |
    A single hung tool (network request, slow shell command) blocks the entire tool batch and therefore the agent loop indefinitely. No timeout is enforced today — only the global max_iterations cap. This causes sporadic CI flakes (golden-path test hangs) and degraded UX when a tool is slow.
  source_doc: src/agent_loop/tool_runner.rs
  closed_date: '2026-04-17'

- id: AGT-004
  domain: agent
  title: Wire MessagingAdapter events into agent input queue
  status: done
  priority: P1
  effort: m
  description: |
    Platform adapters (Telegram, Discord shim) are constructed but not connected to the agent loop. An incoming Telegram message has no path to trigger a Chump turn. The orchestrator needs an mpsc input queue that adapters push IncomingMessage onto, and a dispatch loop that spawns a ChumpAgent::run() per message. This is the "wire" that makes multi-platform messaging live rather than scaffolding.
  depends_on: [INFRA-MESSAGING-DEDUPE, AGT-002]
  source_doc: src/agent_loop/orchestrator.rs
  closed_date: '2026-04-18'

- id: AGT-005
  domain: agent
  title: "LLM response streaming deltas → SSE AgentEvent::TextDelta"
  status: done
  priority: P2
  effort: m
  description: |
    provider.complete() returns a fully-buffered CompletionResponse. The web UI sees no text until the entire LLM call finishes (~2-8s). Streaming deltas (provider.stream() → Stream<Item=Delta>) would allow the SSE event channel to emit AgentEvent::TextDelta per chunk, giving the user live output. Streaming is also a prerequisite for AGT-002's per-token cancellation (can only cancel at .await points).
  depends_on: [AGT-002]
  source_doc: src/agent_loop/iteration_controller.rs
  closed_date: '2026-04-18'

- id: AGT-006
  domain: agent
  title: Wire NewMessageSensor into platform_router — mid-turn interrupt
  status: done
  priority: P2
  effort: s
  description: |
    SENSE-001 defines PeripheralSensor + NewMessageSensor but the wiring into platform_router::run_message_loop() was deferred to after AGT-002 and AGT-004 landed. Now that all dependencies are on main, complete the interrupt loop: run_message_loop merges the sensor stream with the input queue via tokio::select! biased;, and fires cancel_registry::cancel() on the active request_id when SensorKind::NewMessage fires mid-turn. ChumpAgent gains run_with_cancel() so dispatch_one can thread an externally-managed CancellationToken through the turn.
  depends_on: [SENSE-001, AGT-002, AGT-004]
  source_doc: src/platform_router.rs
  closed_date: '2026-04-18'

- id: AUTO-001
  domain: autonomy
  title: Task contract — structured notes with context/plan/acceptance/verify/risks
  status: done
  priority: P1
  effort: s
  description: |
    Tasks have free-form notes. No structured sections for Context, Plan, Acceptance, Verify, Risks/Approvals. The planner/executor loop (AUTO-002) cannot reliably extract these without a template.
  notes: |
    Fully implemented in src/task_contract.rs (template_for, ensure_contract, extract_sections, VerifyContract, parse_verify_json). Wired into task_tool.rs line 87. Tests in task_contract.rs. Nothing left to do.
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-002
  domain: autonomy
  title: Planner → Executor → Verifier loop (core autonomy)
  status: done
  priority: P1
  effort: xl
  description: |
    No structured planner/executor/verifier lifecycle. Agent works tasks opportunistically but doesn't: (1) select next task by priority/blocking, (2) expand plan into notes, (3) verify via acceptance criteria before marking done, (4) create follow-up tasks on failure.
  depends_on: [AUTO-001]
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-003
  domain: autonomy
  title: Task lease conformance tests — two workers cannot claim same task
  status: done
  priority: P1
  effort: s
  description: |
    DB-backed task lease (claim token + expires_at + owner) is implemented but no conformance tests verify that two concurrent workers cannot hold a valid lease simultaneously.
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-004
  domain: autonomy
  title: Autonomy driver process — cron-friendly single-task-per-run loop
  status: done
  priority: P1
  effort: m
  description: |
    scripts/autonomy-cron.sh exists but the driver that pulls briefing/tasks, sends one prompt, streams events, and persists logs is not fully implemented. Without it, cron-based autonomous work cannot make measurable progress.
  depends_on: [AUTO-002]
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-17'

- id: AUTO-005
  domain: autonomy
  title: Policy-based approvals — auto-allow low-risk tool approvals
  status: done
  priority: P2
  effort: m
  description: |
    Tool approval currently binary (Ask/Allow). Auto-approve rate is not tracked. Policy layer would classify approvals as low/medium/high risk and auto-allow low-risk without human prompt, escalating only medium/high.
  notes: |
    chump_approval_stats table (db_pool.rs ensure_schema_extensions): tool_name, decision, risk_level, recorded_at. record_approval_stat() in tool_policy.rs inserts on every approval decision (auto_approved, human_allowed, denied, timeout). auto_approve_rate(window_days) queries last N days. tool_policy_for_stack_status() exposes auto_approve_rate_7d in /api/stack-status JSON. task_executor.rs wired at all three decision branches. 3 unit tests (record no-op, rate zeros without DB, parse_comma trim/lowercase).
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-006
  domain: autonomy
  title: Autonomy conformance fixtures for key tools
  status: done
  priority: P2
  effort: m
  description: |
    No deterministic "mini task" test scenarios for patch_file, write_file, run_cli trimming, approvals. CI cannot catch autonomy regressions.
  depends_on: [AUTO-003]
  notes: |
    10 conformance tests in task_executor.rs::tests: (1) validation rejects missing run_cli command; (2) unapproved tool executes directly; (3) batch of two tools; (4) CHUMP_SKIP_TOOL_INPUT_VALIDATE bypass; (5-7) approval_audit_fields for patch_file (high), run_cli (low), unknown tool (medium); (8-10) approval_resolver timeout/allow/deny paths. Tests documented to note OnceLock constraint on CHUMP_TOOLS_ASK (cannot be changed mid-process in unit tests).
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-007
  domain: autonomy
  title: Better task selection — dependency awareness and urgency scoring
  status: done
  priority: P2
  effort: m
  description: |
    Current task selection picks highest-priority non-blocked task. No dependency graph, no urgency from deadline context, no repo readiness check before claiming a coding task.
  depends_on: [AUTO-002]
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-17'

- id: AUTO-008
  domain: autonomy
  title: Task decomposition — large tasks split into verified subtasks
  status: done
  priority: P2
  effort: l
  description: |
    Large/vague tasks are executed as a monolith. No automated decomposition into subtasks with per-subtask acceptance criteria and verification.
  depends_on: [AUTO-002]
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-009
  domain: autonomy
  title: Memory linkage — project playbooks auto-attached to task context
  status: done
  priority: P2
  effort: s
  description: |
    When executing a task, relevant playbooks and gotchas from memory are not automatically surfaced in context. Agent must rediscover known patterns.
  notes: |
    fetch_task_memory_context() in autonomy_loop.rs: keyword_search by task title + repo, top 3 results injected into exec_prompt "Relevant memory" block. Graceful no-op when memory DB unavailable (Err → empty string).
  source_doc: docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: AUTO-010
  domain: autonomy
  title: HITL permission negotiation — structured escalation with full reasoning
  status: done
  priority: P1
  effort: m
  description: |
    When a tool fails due to permissions or is classified high-risk with low auto_approve_rate, the agent fails silently. It should halt, package a structured request (why the permission is needed, exact command preview, expected outcome, rollback plan), and wait asynchronously — consuming zero compute until the human responds.
  depends_on: [AUTO-005, COG-008]
  closed_date: '2026-04-16'

- id: AUTO-011
  domain: autonomy
  title: Epistemic stress metric — frustration-triggered strategy pivot
  status: done
  priority: P2
  effort: s
  description: |
    tool_middleware.rs circuit breaker tracks only failure_count + cooldown (line 25: (u32, Instant) per tool). Diminishing epistemic returns — repeated attempts on the same tool with decreasing confidence gain — are invisible. Agent cools down then retries identically rather than pivoting strategy.
  depends_on: [AUTO-006]
  closed_date: '2026-04-16'

- id: AUTO-012
  domain: autonomy
  title: DelegatePreProcessor — compress heavy tool output via worker model
  status: done
  priority: P2
  effort: s
  description: |
    Phase 5.1/5.2 from ROADMAP_CLAUDE_UPGRADE.md. When CHUMP_DELEGATE_PREPROCESS=1 and CHUMP_DELEGATE_CONCURRENT=1, any tool whose output exceeds CHUMP_DELEGATE_PREPROCESS_CHARS (default 4000) is compressed by the worker model (run_delegate_summarize, 5 sentences) before the main orchestrator sees it. Prevents context- window blowout from run_cli / read_file / codebase_digest calls.
  depends_on: [AUTO-011]
  source_doc: docs/ROADMAP_CLAUDE_UPGRADE.md
  closed_date: '2026-04-18'

- id: AUTO-013
  domain: auto
  title: Chump-orchestrator mode — dogfood meta-loop for self-dispatching
  status: done
  priority: P1
  effort: xl
  description: |
    A Chump session that dispatches other Chump sessions on parallel gaps, monitors them via chump-coord NATS + gh pr list, harvests outcomes into reflection_db, and feeds back into PRODUCT-006 + eval_harness so the system learns to orchestrate itself over time. MVP ships external-subprocess dispatch only, depth-1, max-parallel=4, soft-deadline kill on 2x effort estimate. See design doc for full architecture, MVP scope, acceptance criteria, and the AUTO-013-A..D follow-up sub-gaps for the 4-week post-MVP build (lesson-aware dispatch, eval_harness sweep arm, hybrid in-process fast path, recursion+budget).
  depends_on: [PRODUCT-006, MEM-006]
  notes: |
    ~10 working days MVP after design lands. Hardest unknown: gap mis-classification at scale; MVP mitigation = auto_dispatch_ok tag on gaps before orchestrator picks them.
  source_doc: docs/AUTO-013-ORCHESTRATOR-DESIGN.md
  closed_date: '2026-04-19'

- id: COG-001
  domain: consciousness
  title: A/B study round 2 — LLM-as-judge + multi-model scaling curves
  status: done
  priority: P1
  effort: l
  description: |
    Round 1 A/B compares structural metrics (surprisal, lesson count) with/without CHUMP_CONSCIOUSNESS_ENABLED. Round 2 adds semantic quality: an LLM judge scores response accuracy on each prompt, and the study runs across 3+ model sizes (3B / 9B / 14B) to plot the latency-vs-capability tradeoff curve. Without this, the research paper (docs/research/consciousness-framework-paper.md) cannot claim empirical support for the consciousness framework.
  notes: Gate for COG-003 and COG-006.
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: COG-002
  domain: consciousness
  title: Memory graph recall benchmark — recall@5 on multi-hop QA
  status: done
  priority: P2
  effort: m
  description: |
    No benchmark compares regex triple extraction vs LLM extraction, or BFS vs Personalized PageRank recall quality. Cannot justify PPR complexity without data.
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-16'

- id: COG-003
  domain: consciousness
  title: Adaptive regime transitions — learned threshold tuning
  status: done
  priority: P2
  effort: l
  description: |
    PrecisionController regime thresholds are currently static (shifted only by noradrenaline). A simple online logistic regression or Thompson-sampling bandit could adjust thresholds based on recent task success rate, closing the thermodynamic grounding gap.
  depends_on: [COG-001]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-16'

- id: COG-004
  domain: consciousness
  title: Lesson upgrade — replace heuristic lesson extraction with causal graph output
  status: done
  priority: P2
  effort: m
  description: |
    extract_lesson_heuristic() uses text pattern matching (timeout → retry). The causal graph (CausalGraph, build_causal_graph_heuristic) already exists. Lessons should carry confidence derived from DAG path analysis, not patterns.
  notes: |
    lesson_from_graph_paths(graph, action) traverses paths_from() action node, multiplies edge strengths along each path, returns strongest path lesson + confidence. analyze_episode() builds graph first, uses graph lesson when available, falls back to heuristic. causal_confidence column added to chump_causal_lessons via ALTER TABLE migration. CausalLesson.causal_confidence: Option<f64>. persist_causal_graph_as_lessons passes Some(edge.strength). 4 new unit tests in counterfactual::tests. Section 2.5 checkbox marked.
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-16'

- id: COG-005
  domain: consciousness
  title: Perception gate — measure whether perception layer improves tool selection
  status: done
  priority: P2
  effort: m
  description: |
    Perception layer (src/perception.rs) runs before every LLM call but its effect on tool selection accuracy has never been measured. Need 50-turn diverse task set comparing perception-informed vs raw-text baseline.
  depends_on: [COG-001]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: COG-006
  domain: consciousness
  title: Neuromodulation gate — measure modulator adaptation vs fixed-threshold
  status: done
  priority: P2
  effort: m
  description: |
    Neuromodulation (src/neuromodulation.rs) shifts regime thresholds but its effect on task outcomes has not been measured on a 50-turn diverse task set.
  depends_on: [COG-001]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-18'

- id: COG-007
  domain: consciousness
  title: Wire structured reflection (GEPA) into prompt assembly
  status: done
  priority: P1
  effort: s
  description: |
    reflection.rs produced typed Reflection / ImprovementTarget artifacts but had no DB persistence and no prompt injection — the typed analysis was throwaway. Pillar 4 of the autonomy stack (GEPA self-reflection) was essentially dead code.
  source_doc: docs/NEXT_GEN_COMPETITIVE_INTEL.md
  closed_date: '2026-04-17'

- id: COG-008
  domain: consciousness
  title: Upgrade reflect_heuristic → LLM-assisted reflection via delegate worker
  status: done
  priority: P2
  effort: m
  description: |
    reflection.rs::reflect_heuristic uses pattern-matching on observed_outcome strings to detect ErrorPattern. Misses subtle cases (intent drift, assumption-not-checked, partial-success-misclassified-as-pass). reflection.rs:25 already flags this as future work.
  depends_on: [COG-007]
  source_doc: docs/NEXT_GEN_COMPETITIVE_INTEL.md
  closed_date: '2026-04-17'

- id: COG-009
  domain: consciousness
  title: Add tool_hint param to PromptAssembler for sharper lesson scope filter
  status: done
  priority: P3
  effort: xs
  description: |
    PromptAssembler::assemble used the first detected perception entity as the scope filter for load_recent_high_priority_targets. Better signal: the about-to-be-called tool name (or last-failed tool from prior turn).
  depends_on: [COG-007]
  source_doc: src/agent_loop/prompt_assembler.rs
  closed_date: '2026-04-17'

- id: COG-009b
  domain: consciousness
  title: Wire actual tool_hint signal source from BatchOutcome into orchestrator
  status: done
  priority: P2
  effort: s
  description: |
    COG-009 added the assemble_with_hint API but the orchestrator still passes None. The signal source (last-failed tool name from BatchOutcome or message history) needs to flow through. BatchOutcome currently only tracks success/fail counts, not per-tool names — needs minor extension.
  depends_on: [COG-009]
  source_doc: src/agent_loop/orchestrator.rs
  closed_date: '2026-04-17'

- id: COG-010
  domain: consciousness
  title: Integration test for reflection feedback flywheel
  status: done
  priority: P2
  effort: s
  description: |
    reflection_db unit tests cover save/load/scope-filter/format. Was missing: end-to-end test that runs a fake task → fails it → starts next task → asserts "## Lessons from prior episodes" appears in assembled prompt. Without this, schema drift could silently break the flywheel.
  depends_on: [COG-007]
  source_doc: src/autonomy_loop.rs
  closed_date: '2026-04-17'

- id: COG-011
  domain: eval
  title: Eval A/B — does lesson injection actually improve outcomes?
  status: done
  priority: P1
  effort: m
  description: |
    COG-007 wired GEPA lessons into the prompt but the impact on task success rate is unmeasured. Without this, lesson injection is "code that claims to help" — could be no-op or even regress the base rate.
  depends_on: [COG-007]
  source_doc: src/reflection_db.rs
  closed_date: '2026-04-17'

- id: COG-011b
  domain: eval
  title: LLM-judge scoring for the reflection A/B
  status: done
  priority: P2
  effort: s
  description: |
    COG-011 used structural-only property checks (text patterns + tool presence). Easy to fool. Need an LLM judge that scores each trial's final text against a per-task rubric (does the answer actually satisfy the prompt's intent?). eval_harness already has ExpectedProperty::LlmJudge variant + check_all_properties_with_judge — wire score.py to call it.
  depends_on: [COG-011]
  source_doc: scripts/ab-harness/score.py
  closed_date: '2026-04-17'

- id: COG-011c
  domain: eval
  title: Reverse-order sanity A/B for COG-011
  status: done
  priority: P3
  effort: xs
  description: |
    run.sh always runs mode A (flag=1) before mode B (flag=0) for each task. If within-session state (DB writes from A's run, ollama kv-cache, surprise EMA, etc.) leaks into B, the +0.15 result is partly an order artifact rather than a pure prompt effect.
  depends_on: [COG-011]
  source_doc: scripts/ab-harness/run.sh
  closed_date: '2026-04-17'

- id: COG-011d
  domain: consciousness
  title: Investigate why lesson injection hurts on gotchas (-0.30 delta)
  status: done
  priority: P1
  effort: m
  description: |
    COG-011b's LLM-judge run showed lesson injection hurts gotcha tasks by 30 percentage points. Hypotheses to test:
      (a) The lesson block adds 200-500 tokens of noise that crowds
          out the user prompt's signal — try a prompt-position swap
          (lessons after user prompt instead of in system).
      (b) Generic lessons ("validate preconditions before tool call")
          are too vague — try scope-filtered lessons only when the
          scope hint matches, otherwise skip the block.
      (c) The model over-asks-for-clarification when the "ask
          clarifying question" lesson is in scope — add a counter-
          balancing lesson "if intent is clear, act don't ask".
      (d) Larger model (qwen2.5:14b) might use lessons better than
          qwen2.5:7b — repeat the 40-trial A/B on 14b.
  depends_on: [COG-011, COG-011b]
  notes: |
    Variant (b) tested + supported (2026-04-17, 0eecf5e + this run): CHUMP_REFLECTION_STRICT_SCOPE=1 took the LLM-judge delta from -0.10 → +0.05 overall and gotcha from -0.30 → 0.00. Mode A's gotcha rate jumped from 0.50 (COG-011b) to 0.90. The "noise hypothesis" is supported: universal-scope lessons leaking into every prompt was the primary harm vector, not the lesson content itself. Still need ≥1 more variant (a/c/d) to satisfy the acceptance criterion.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-17'

- id: COG-012
  domain: consciousness
  title: ASI telemetry — token log-probabilities + resource spikes in reflection
  status: done
  priority: P2
  effort: l
  description: |
    Reflection consumes stderr and tool outcomes only. High-fidelity Actionable Side Information requires token-level log-probabilities (to detect model uncertainty mid-generation), per-tool memory/latency spikes, and compiler warning counts as structured signals. Zero logprob tracking exists anywhere.
  closed_date: '2026-04-16'

- id: COG-013
  domain: consciousness
  title: Intrinsic alignment override — contract-proof refusal of unsafe requests
  status: done
  priority: P2
  effort: l
  description: |
    When a user prompt conflicts with architectural invariants (skip verification, bypass approval, ignore safety), the agent complies or silently applies policy_override. No module produces a structured refusal with proof that the request violates the operational contract. Intrinsic directives should mathematically override extrinsic requests that break invariants.
  depends_on: [AUTO-001, AUTO-005]
  closed_date: '2026-04-16'

- id: COG-014
  domain: consciousness
  title: Task-specific lessons content — replace generic block per fixture
  status: done
  priority: P2
  effort: m
  description: |
    The lessons block currently injected for COG-005/006/011 A/Bs is the same generic content regardless of task type. Cloud sweep (ce4ebc0) shows perception (-0.10) and neuromod (-0.10) tasks both penalize this block on haiku-4-5 — possibly because generic lessons distract from task-specific reasoning. Try authoring lessons that match each fixture's task class (e.g. perception lessons emphasize entity extraction; neuromod lessons emphasize confidence calibration).
  depends_on: [EVAL-010]
  notes: |
    Recommended follow-up from cloud A/B sweep (ce4ebc0). Gated on EVAL-010 because re-running A/Bs with the same circular methodology is wasted cloud spend. Total cost when unblocked: ~$2 (one cloud sweep across perception/neuromod/reflection on haiku-4-5).
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-18'

- id: COG-015
  domain: consciousness
  title: Entity-keyed blackboard injection in prompt assembler (Phase 8.2)
  status: done
  priority: P2
  effort: s
  description: |
    Implements ROADMAP_CLAUDE_UPGRADE.md Task 8.2: contextual pre-fetching from chump_blackboard_persist. Adds query_persist_for_entities() to blackboard.rs (SQL LIKE keyword search against persisted facts) and injects a "Remembered context" block into prompt_assembler.rs::assemble_with_hint() based on perception.detected_entities. Gated on CHUMP_ENTITY_PREFETCH env var (default on).
  depends_on: [MEM-005]
  closed_date: '2026-04-18'

- id: COG-016
  domain: consciousness
  title: Model-tier-aware lessons block injection
  status: done
  priority: P1
  effort: m
  description: |
    The n=100 sweep landed by PR #80 + #82 established (p<0.05 across 3 fixtures) that injecting the lessons block as a system-role prefix reliably increases fake-tool-call emission by +0.13 to +0.16 percentage points (mean +0.14, A/A noise floor 0.00). Effect replicated on opus at n=20 with non-overlapping CIs (+0.40 on reflection). Production currently injects unconditionally via reflection_db::reflection_injection_enabled. Should be model-tier-gated so weaker models do not pay the hallucination cost while frontier models can opt in.
  notes: |
    Direct production consequence of the headline finding from this session. Single-file Rust change in reflection_db.rs (model tier map + injection predicate update). Unit test count: 2 (tier mapping + gated predicate). Coordination caveat: prompt_assembler.rs has active edits in PR #66 (COG-015 entity blackboard); land COG-016 after #66 to avoid rebase.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: COG-019
  domain: cognition
  title: Context-window compaction for long --chat / --web sessions
  status: done
  priority: P3
  effort: m
  description: |
    Chump's agent loop assembles context fresh each turn but has no mechanism to summarize a long-running multi-turn conversation and inject that summary back in, the way Claude Code does with transcript compaction. For short task-scoped runs (study5, single-shot --chat) this is fine. For extended --chat or --web sessions that grow beyond the model's context window, the agent will start losing early turns silently.
    Design: when total assembled context exceeds a configurable threshold (e.g. 80% of CHUMP_CONTEXT_WINDOW), call a summarization pass on the oldest N turns, replace them with a [PRIOR CONTEXT SUMMARY] block, and continue. Mirror the approach used by Claude Code's /compact command. The summary should preserve: decisions made, tools called, facts learned, and current task state. Open question: single-model summarizer vs. a smaller/faster model for the compression pass.
  notes: |
    Backlog exploration item. No active user need yet — sessions stay short. Reverse to P1 if long --chat sessions become common or if a specific use case (e.g. all-day autonomous agent) needs it.
  closed_date: '2026-04-19'

- id: COG-020
  domain: cognition
  title: DeepMind 10-faculty Chump architecture map — taxonomy alignment doc
  status: done
  priority: P2
  effort: s
  description: |
    DeepMind's 10-faculty AGI cognitive framework (Perception, Generation, Attention, Learning, Memory, Reasoning, Metacognition, Executive Function, Problem Solving, Social Cognition) is becoming the industry-standard taxonomy for measuring agent capability breadth. Chump informally covers most of these but lacks an explicit map. Building one immediately surfaces (a) which Chump modules implement which faculties, (b) which faculties have A/B evidence and which don't, (c) which faculties are entirely absent (e.g. Attention has no module today — see EVAL-028). Useful as both an internal architecture-clarity exercise and an external positioning artifact.
  notes: |
    ~1 day docs exercise. Reference: https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf Should call out explicitly: Attention faculty has no monitoring today (gap → EVAL-028 CatAttack), Social Cognition faculty maps to tool approval / ASK_JEFF flow (untested at scale).
  source_doc: external (DeepMind cognitive framework 2025)
  closed_date: '2026-04-19'

- id: COG-021
  domain: cognition
  title: Test-time-compute / reasoning-mode integration — Chump uses o3/Deep Think when available
  status: done
  priority: P3
  effort: m
  description: |
    Per 2026 frontier landscape: o3, Gemini Deep Think, Claude "extended thinking" all expose test-time compute via a "thinking" parameter. Chump currently calls all models the same way regardless of whether they support reasoning mode. For tasks where reasoning would help (complex multi-step planning, debugging), Chump should detect reasoning-capable models and invoke them with reasoning enabled. For routine tasks, stay in fast/cheap mode (the "Routing Layer" pattern from the Gemini letter). Open question: does our cost ledger justify the reasoning-mode latency + spend per task class? Empirical gap.
  notes: |
    Anthropic exposes "thinking" param in messages API. OpenAI o-series uses "reasoning_effort" (low/medium/high). Different providers, different APIs. ~1 week to implement + sweep. Could double cost on reasoning-mode trials. Worth an A/B before shipping as default.
  source_doc: external (Gemini AGI letter — System 2 reasoning era)
  closed_date: '2026-04-20'

- id: COG-022
  domain: cognition
  title: MCP server enterprise-readiness — Sampling + Elicitation patterns
  status: done
  priority: P3
  effort: m
  description: |
    Per 2026 MCP roadmap (Gemini letter): two new patterns are emerging — "Sampling" (servers can request reasoning from the AI model) and "Elicitation" (servers can pause for user input mid-process). Chump's 3 shipped MCP servers (chump-mcp-{adb,github,tavily}) and the 3 coming via COMP-009 currently implement only the basic tool- call pattern. To stay current with the MCP spec evolution and remain interoperable with goose / Claude Code / Aider as those tools adopt sampling+elicitation, Chump's MCP servers should grow these patterns as the SDK supports them.
  depends_on: [COMP-009]
  notes: |
    Confirm MCP Rust SDK supports Sampling/Elicitation before committing. ~1 week effort. Reference: AAIF roadmap docs.
  source_doc: external (Gemini AGI letter — MCP 2026 roadmap)
  closed_date: '2026-04-20'

- id: COG-023
  domain: cognition
  title: Sonnet carve-out from cog016 directive — CONFIRMED at n=100, ship Path A
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-027c (2026-04-19, n=100 reflection) CONFIRMED the EVAL-027b sonnet finding at statistical significance:
      Cell A (cog016 lessons):  33/100 hallucinations (CI [0.246, 0.427])
      Cell B (no lessons):       0/100 hallucinations (CI [0.0, 0.037])
      Delta halluc: +0.330, NON-OVERLAPPING CIs, SIG
      Inter-judge agreement: 0.81 (clears 0.80 threshold)
    Production COG-016 ships with default Frontier-tier injection. Both sonnet-4-5 and opus-4-5 are Frontier in current ModelTier enum, so both get cog016 lessons by default. At sonnet this produces 33% fake-tool emission per response — actively harming users RIGHT NOW. Full Anthropic-family hallucination picture (cell A rate per lessons variant):
      haiku-3:    no-lessons 0%,  v1  0%,  cog016 (untested, n/a)
      haiku-4-5:  no-lessons 0%,  v1 12%,  cog016 -1% (FIXED by directive)
      sonnet-4-5: no-lessons 0%,  v1 18%,  cog016 33% (DIRECTIVE WORSENS)
      opus-4-5:   no-lessons 2%,  v1 40%,  cog016 10% (PARTIALLY FIXED)
    Conservative quick-fix (Path A): add Sonnet variant to ModelTier; block lessons injection at Sonnet tier by default. Bigger rethink (Path B = COG-024) is "default off, opt-in per model after measurement."
  depends_on: [EVAL-027b, EVAL-027c]
  notes: |
    Atomic-PR ship target (~half day): code change + tests + docs in one commit, single push, auto-merge armed. Defensive ship — kills production harm at sonnet tier. Path B (COG-024) is the longer- term rethink.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md (EVAL-027c CONFIRMED)
  closed_date: '2026-04-19'

- id: COG-024
  domain: cognition
  title: Default lessons-OFF — opt-in per-model only after measurement
  status: done
  priority: P2
  effort: l
  description: |
    Full Anthropic-family hallucination picture from EVAL-026b/027b/027c shows the safest-by-default behavior is NO lessons block at all. Every Anthropic model except haiku-3 shows hallucination harm with v1 lessons; cog016 fixes some (haiku-4-5) and worsens others (sonnet-4-5). COG-023 (sonnet carve-out) is a defensive patch but doesn't address: should lessons be default-ON anywhere? COG-024 proposes the inverse default: lessons OFF unless explicitly opted-in per-model after A/B measurement validates the lessons help. Each opt-in is documented with source EVAL-XXX gap.
  depends_on: [COG-023, EVAL-027, EVAL-030]
  notes: |
    ~1 week including migration path + per-model re-validation sweeps. Paired with COG-023 = full production story for "Anthropic-family lessons-block policy in 2026-Q3."
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md (EVAL-027c synthesis)
  closed_date: '2026-04-19'

- id: COG-025
  domain: cognition
  title: Dispatch-backend pluggability — route orchestrator subagents via Together (free tier)
  status: done
  priority: P1
  effort: m
  description: |
    chump-orchestrator's dispatch.rs spawns `claude -p` subprocess = pure Anthropic spend (~$1-2 per PR shipped). Together has frontier- adjacent free-tier models (Qwen3-235B-A22B-Instruct-2507-tput, Llama-3.3-70B-Instruct-Turbo) fully capable per EVAL-026 cross- architecture immunity data. The structural blocker: `claude` CLI is Anthropic-only — cannot redirect to Together. Need a different subagent binary that drives the full multi-turn agent loop with OPENAI_API_BASE pointed at Together. Path: expose Chump's own src/agent_loop/ as a dispatchable CLI (`chump --execute-gap <GAP-ID>` or similar). The agent_loop already uses OpenAI-compatible backends (mistral.rs, Ollama, Together) — wiring + a new main.rs entry point.
  notes: |
    ~1-2 days. Biggest unknown: whether Together-hosted Qwen3-235B can actually drive a multi-turn tool-use loop end-to-end. EVAL-026 validated it for text-only; tool-use loop hasn't been A/B-tested. COG-026 (filed alongside) is the empirical validation gap that closes that loop.
  source_doc: session 2026-04-19 cost-routing discussion
  closed_date: '2026-04-19'

- id: COG-026
  domain: cognition
  title: Validate Together-big models on chump agent loop — A/B vs claude
  status: done
  priority: P1
  effort: s
  description: |
    After COG-025 ships the dispatch-backend pluggability, need to empirically validate: can Qwen3-235B / Llama-3.3-70B drive Chump's multi-turn agent loop end-to-end (read CLAUDE.md → do gap work → ship via bot-merge.sh)? The autonomy test V4 (PR #167) proved claude-sonnet-4-5 can; the open question is whether Together big models are competent at the same task. A/B: same synthetic backlog (docs/test-fixtures/synthetic-backlog.yaml from AUTO-013 step 5), 4 gaps, two arms:
      - Cell A: CHUMP_DISPATCH_BACKEND=claude (baseline, ~$4 spend)
      - Cell B: CHUMP_DISPATCH_BACKEND=chump-local with Qwen3-235B (free)
    Measure: ship rate (PRs merged per gap), wall time, reflection quality, cost.
  depends_on: [COG-025]
  notes: |
    ~1 day after COG-025 lands. If successful: 90%+ cost reduction on autonomous PR shipping. Pair with FRONTIER-007 (cross-agent benchmarking) for the broader story.
  source_doc: session 2026-04-19 cost-routing discussion
  closed_date: '2026-04-20'

- id: COG-027
  domain: cognition
  title: Task-aware ask-vs-execute policy — gate clarifying questions on task type
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-029 drilldown found that the perception "ask one clarifying question" directive actively hurts on conditional-chain tasks (dynamic-05-policy-confront: −75pp). EVAL-030 ships task-class-aware gating for the lessons block but not for the clarification directive. Current behavior: the perception sensor always suggests asking a clarifying question on ambiguous prompts, even on procedural tasks where the user clearly wants execution. The policy should be task-dependent: ask on genuinely ambiguous tasks (intent unclear), suppress on procedural tasks (steps are clear, intent is obvious).
  depends_on: [EVAL-030]
  notes: |
    ~1 day. Pairs with EVAL-030's existing task-class detector. The ask- vs-execute trade-off is the same mechanism EVAL-029 diagnosed for neuromod — worth fixing at the same time.
  source_doc: docs/RESEARCH_INTEGRITY.md backlog audit 2026-04-19
  closed_date: '2026-04-20'

- id: COG-028
  domain: consciousness
  title: Checkpoint V2 — zero-compute sleep + full state re-hydration
  status: done
  priority: P1
  effort: m
  description: |
    checkpoint_db.rs stores state_snapshot_json but never reads it back (explicitly marked V2 in source, lines 5-7). Zero-compute sleep requires the agent process to terminate after serialising, then re-hydrate from DB on heartbeat trigger — not sleep-loop. speculative_execution.rs already has all individual restore primitives; they just need wiring.
  closed_date: '2026-04-16'

- id: COG-029
  domain: consciousness
  title: Typestate FSM — compile-time-provable autonomy lifecycle transitions
  status: done
  priority: P2
  effort: m
  description: |
    Agent lifecycle (Plan → Execute → Verify → Done/Failed) uses plain integer counters and status strings (orchestrator.rs, iteration_controller.rs). No compile-time guarantee that Execute cannot be entered without Plan completion. Rust typestate pattern (zero-cost phantom types) makes invalid transitions unrepresentable at compile time.
  depends_on: [AUTO-001]
  closed_date: '2026-04-16'

- id: COG-030
  domain: consciousness
  title: Proactive epistemic probing + EIG-gated execution hard-block
  status: done
  priority: P1
  effort: l
  description: |
    Two missing pieces from full epistemic agency: (1) Before high-cost ops, the agent should generate low-cost probe actions to verify environment assumptions rather than commit blind. (2) When surprisal of required variables exceeds a threshold, execution should be hard-blocked — currently surprise_tracker only flags to blackboard, never gates task execution.
  depends_on: [AUTO-001]
  closed_date: '2026-04-16'

- id: COG-032
  domain: cognitive
  title: Lesson injection feedback loop evaluation
  status: open
  priority: P2
  effort: m
  description: |
    COG-024 defaults lessons off for safety. CHUMP_LESSONS_AT_SPAWN_N=5 injects top-5 lessons. Unknown if this improves outcomes or adds noise. Run A/B harness: A) lessons off, B) lessons on. Execute 50 gaps in each condition. Measure: test pass %, code review pass %, time-to-ship, revision count. Compare outcomes (effect size, confidence). Recommendation: enable lessons | keep disabled | make task-specific.
  acceptance_criteria:
    - Harness runs 50 gaps per condition (lessons off vs on)
    - Metrics captured (test pass %, code review pass %, time-to-ship, revision count)
    - Effect size computed (Cohen's d or equivalent)
    - Confidence documented (statistical test, confidence interval)
    - Recommendation clear with rationale
  notes: |
    Can run in parallel. Low cost (mostly gap execution). Results inform COG-024 default and per-gap recommendations.
  source_doc: docs/EVALUATION_PLAN_2026Q2.md

- id: COG-033
  domain: consciousness
  title: Reflection → dynamic system prompt injection
  status: done
  priority: P1
  effort: m
  description: |
    reflection.rs explicitly defers prompt injection to V2 (lines 25-30 note 'V2 future feature'). context_assembly.rs draws from episodes, lessons, consciousness metrics, but not reflection output. Improvement targets produced by the reflection loop are stored but never fed back into runtime behaviour — the loop has no effect on future execution.
  closed_date: '2026-04-16'

- id: COG-034
  domain: consciousness
  title: Counterfactual simulation — Pearl's Ladder rung 3
  status: done
  priority: P2
  effort: l
  description: |
    counterfactual.rs stores causal graphs and traverses them (rung 1 association) but does not simulate alternative action paths. build_causal_graph_heuristic() creates sequential edges with hardcoded strength 0.7 — graph scaffolding, not causal inference. On task failure, the reflection engine should compute 'If I had run cargo check before git commit, would this error have occurred?'
  depends_on: [COG-004, MEM-003]
  closed_date: '2026-04-16'

- id: COG-035
  domain: COG
  title: dispatch router v1 — hand-tuned routing.yaml + Vec<Candidate> cascade
  status: done
  priority: P1
  effort: m
  closed_date: '2026-04-27'

- id: COG-036
  domain: COG
  title: dispatch router v2 — routing_outcomes scoreboard SQLite table + reflection hook
  status: done
  priority: P1
  effort: m
  closed_date: '2026-04-27'

- id: COG-037
  domain: COG
  title: dispatch router v3 — Thompson-sampling self-learning router (gated)
  status: done
  priority: P1
  effort: m
  closed_date: '2026-04-27'

- id: COG-038
  domain: COG
  title: "wire MonitorLoop::watch_until_done into orchestrator so routing_outcomes populates"
  status: done
  priority: P1
  effort: s
  closed_date: '2026-04-27'

- id: COG-039
  domain: COG
  title: bench harness — flag-off baseline vs cog_037-on Thompson router (M4 step 2 prerequisite to flipping default)
  status: open
  priority: P1
  effort: m

- id: COMP-001
  domain: competitive
  title: Skills system — reusable SKILL.md procedure documents with auto-create
  status: done
  priority: P0
  effort: l
  description: |
    Hermes's flagship differentiator: after completing 5+ tool-call tasks it autonomously creates SKILL.md procedure documents (procedural memory). Chump has episodes (what happened) but no reusable procedures (how to do things). Without this, Chump cannot improve its own task execution patterns over time.
  notes: |
    Skills stack: src/skills.rs, src/skill_tool.rs, src/skill_db.rs, src/skill_metrics.rs, context_assembly.rs wired, tool_inventory.rs registered. Auto-create trigger: total_tool_calls added to AgentRunOutcome; maybe_suggest_skill() posts blackboard suggestion when >= CHUMP_SKILL_SUGGEST_THRESHOLD (default 5).
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-16'

- id: COMP-002
  domain: competitive
  title: Plugin entry points — ChumpPlugin trait with 3 discovery sources
  status: done
  priority: P0
  effort: l
  description: |
    Chump's inventory::submit! macro works for in-tree tools only. No discovery path for external plugins. Third parties must fork the repo.
  notes: |
    ChumpPlugin trait + PluginManifest + PluginContext + discover_plugins() (user+project). CLI: --plugins-list, --plugins-install <path>, --plugins-uninstall <name>, --plugins-disable <name>, --plugins-enable <name>. Disabled list persisted in ~/.chump/plugins/.disabled.json. discover_active_plugins() filters disabled. initialize_discovered() uses active-only list. 5 new serial tests. Note: V2 dynamic loading via libloading deferred (entry_path field ready in manifest).
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-16'

- id: COMP-003
  domain: competitive
  title: Pluggable context engine — ContextEngine trait for per-deployment strategies
  status: done
  priority: P1
  effort: l
  description: |
    src/context_assembly.rs is monolithic — every section hardcoded. Different deployments (heavy autonomy vs. light chat vs. research synthesis) need different context strategies. Cannot swap without forking.
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-16'

- id: COMP-004
  domain: competitive
  title: Multi-platform messaging gateway — Telegram/Slack/Signal/WhatsApp
  status: done
  priority: P2
  effort: xl
  description: |
    Hermes serves 18+ messaging platforms. Chump has Discord + web PWA. Missing: Telegram, Slack, WhatsApp, Signal, Matrix. Limits deployability for teams and personal use across platforms.
  depends_on: [COMP-002]
  notes: |
    Decomposed into sub-gaps for incremental delivery:
      COMP-004a — extract MessagingAdapter trait from src/discord.rs
      COMP-004b — Telegram adapter (teloxide; webhook + polling modes)
      COMP-004c — Slack adapter (slack-morphism; bolt-style events)
      COMP-004d — Matrix adapter (matrix-rust-sdk)
    Signal/WhatsApp deferred (no viable Rust SDK as of 2026-04).
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-18'

- id: COMP-004a
  domain: competitive
  title: Extract MessagingAdapter trait from Discord adapter
  status: done
  priority: P2
  effort: s
  description: |
    First chunk of COMP-004 decomposition. src/discord.rs is currently the only inbound message handler; its 3 entry points (on_message, slash commands, DM events) and outbound surface (send_dm_if_configured, replies, attachments) need to be lifted into a MessagingAdapter trait so platform adapters (Telegram next) can plug in without duplicating the agent-loop wiring.
  source_doc: src/discord.rs
  closed_date: '2026-04-17'

- id: COMP-004b
  domain: competitive
  title: Telegram adapter via teloxide
  status: done
  priority: P2
  effort: m
  description: |
    Second chunk of COMP-004. Uses the COMP-004a MessagingAdapter trait; adds a teloxide-backed src/telegram.rs and a `chump --telegram` CLI mode mirroring `chump --discord`. Reads TELEGRAM_BOT_TOKEN env.
  depends_on: [COMP-004a]
  source_doc: scripts/run-discord.sh
  closed_date: '2026-04-17'

- id: COMP-004c
  domain: competitive
  title: Slack adapter via Socket Mode
  status: done
  priority: P2
  effort: m
  description: |
    Third chunk of COMP-004. Slack-morphism for events API + slash commands. Same MessagingAdapter pattern as Discord/Telegram.
  depends_on: [COMP-004a]
  source_doc: scripts/run-discord.sh
  closed_date: '2026-04-18'

- id: COMP-004d
  domain: competitive
  title: Matrix adapter via matrix-rust-sdk
  status: deferred
  priority: P3
  effort: m
  description: |
    Fourth (lowest-priority) chunk of COMP-004. Matrix is federated and end-to-end encrypted; the SDK is mature but harder to operate than Telegram/Slack. Defer until Telegram + Slack land and there's a user request.
  depends_on: [COMP-004a]
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md

- id: COMP-005
  domain: competitive
  title: Voice/Vision/Browser — voice mode, image paste, browser automation
  status: done
  priority: P2
  effort: xl
  description: |
    Hermes supports voice mode, image paste, browser automation (Chrome CDP), image generation. Chump has none of these. Missing multimodal input/output limits use cases significantly vs Hermes.
  depends_on: [ACP-002]
  notes: |
    Decomposed into sub-gaps for incremental delivery (ACP-002 done):
      COMP-005a — image paste in PWA → ContentBlock parser
      COMP-005b — browser automation tool (chromiumoxide CDP, headless)
      COMP-005c — TTS output (cocoa say / piper-tts shell)
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-19'

- id: COMP-005a
  domain: competitive
  title: PWA image-paste → ContentBlock multipart routing
  status: done
  priority: P2
  effort: s
  description: |
    First chunk of COMP-005. The PWA chat textarea should accept Cmd-V pasted images (or drag-drop). Browser uploads via the existing web_uploads endpoint, server stores blob, agent loop forwards as ContentBlock::Image when the configured model is vision-capable (provider_quality flag added in ACP-002).
  depends_on: [ACP-002]
  source_doc: web/index.html
  closed_date: '2026-04-17'

- id: COMP-005a-fe
  domain: competitive
  title: PWA Cmd-V image-paste handler in web/index.html
  status: done
  priority: P3
  effort: xs
  description: |
    Frontend half of COMP-005a. Add a `paste` event listener on the chat textarea that captures clipboardData image items, uploads via /api/upload, and attaches the returned file_id to the next send. Backend support shipped in COMP-005a; this is the missing UI piece.
  depends_on: [COMP-005a]
  source_doc: web/index.html
  closed_date: '2026-04-18'

- id: COMP-005b
  domain: competitive
  title: Browser automation tool — chromiumoxide CDP wrapper
  status: done
  priority: P3
  effort: m
  description: |
    Second chunk of COMP-005. New `browser` tool exposing CDP commands: navigate, get_page_text, click, fill, screenshot. chromiumoxide is the Rust CDP client; runs headless Chromium downloaded on first use (~150 MB). Behind CHUMP_TOOLS_ASK gate by default since browser automation is high-risk.
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-18'

- id: COMP-005c
  domain: competitive
  title: TTS output — voice channel via piper or cocoa say
  status: done
  priority: P3
  effort: s
  description: |
    Third chunk of COMP-005. Optional TTS output for the PWA: agent reply triggers a /api/tts endpoint that synthesizes audio (macOS: `say -o`; Linux: `piper`; both shell-out). PWA plays it when CHUMP_TTS_AUTOPLAY=1.
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-17'

- id: COMP-006
  domain: competitive
  title: Skills sharing ecosystem — index.json endpoint and tap install
  status: done
  priority: P3
  effort: l
  description: |
    Hermes has skills.sh directory, /.well-known/skills/index.json endpoints, and hermes skills tap add. No equivalent exists for Chump skills.
  depends_on: [COMP-001]
  source_doc: docs/HERMES_COMPETITIVE_ROADMAP.md
  closed_date: '2026-04-16'

- id: COMP-007
  domain: completeness
  title: AGENTS.md interop standard adoption — supplement or replace CLAUDE.md
  status: done
  priority: P2
  effort: s
  description: |
    AGENTS.md was contributed by OpenAI to the Agentic AI Foundation (Linux Foundation) in Dec 2025 as one of three founding projects alongside MCP and Block's goose. It is positioned as the universal standard for project-specific AI agent guidance designed to work across "different repositories and toolchains" — i.e. cross-tool portable replacement for tool-specific files like CLAUDE.md, .cursorrules, etc. Chump currently uses CLAUDE.md (Claude-only). Migrating CLAUDE.md → AGENTS.md (or supporting both) aligns Chump with the emerging Linux-Foundation-blessed standard and makes Chump-managed repos legible to other compliant agent frameworks (goose, Aider, etc.).
  notes: |
    Reference: https://aaif.io/ — AGENTS.md is one of three founding projects. Spec: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation Implementation likely ~1 day: add AGENTS.md reader to prompt_assembler, update install scripts, document precedence.
  source_doc: external (AAIF, Linux Foundation, Dec 2025)
  closed_date: '2026-04-18'

- id: COMP-008
  domain: completeness
  title: Recipes abstraction — package shareable workflows with declared deps + params
  status: done
  priority: P2
  effort: m
  description: |
    Block's goose ships a "Recipes" abstraction: reusable workflows that package extensions (required tools), prompts, parameters, and settings together as a shareable artifact (https://goose-docs.ai/docs/guides/recipes/). Chump currently has scripts/ and gap entries but no formal artifact for "this is a packaged workflow with declared deps." A Chump Recipe could be e.g. "ship-a-feature" (gap-claim → branch → impl → test → bot-merge) with declared required tools and parameters. Verified the pattern exists in goose; the exact YAML/JSON schema is at goose-docs.ai/docs/guides/recipes/recipe-reference and should be read before designing Chump's equivalent (don't re-invent if goose's spec is broadly portable).
  notes: |
    First task: read https://goose-docs.ai/docs/guides/recipes/recipe-reference and decide whether to adopt their schema verbatim (cross-tool portability win) or adapt for Chump-specific concepts. Recommend adopting verbatim where possible — same standards story as AGENTS.md (COMP-007). Effort estimate is ~3-5 days for schema + runner + first 2-3 packaged recipes.
  source_doc: external (block/goose Recipes pattern, AAIF Dec 2025)
  closed_date: '2026-04-20'

- id: COMP-009
  domain: completeness
  title: Extend Chump MCP-server catalog from 3 to 6+
  status: done
  priority: P2
  effort: m
  description: |
    Chump already publishes 3 MCP servers in crates/mcp-servers/: chump-mcp-adb, chump-mcp-github, chump-mcp-tavily. The pattern works. Goose ships 70+ official MCP extensions and uses the broader 3000+ community ecosystem. Chump's internal capabilities — eval harness, gap coordination via chump-coord NATS, reflection_db, memory_graph, neuromodulation — are all things other MCP-using agents (goose, Aider, etc.) could call as tools. Productize the highest-leverage ones to position Chump as part of the agentic ecosystem rather than only a standalone competitor.
  notes: |
    Existing chump-mcp-github / -adb / -tavily are the template; new servers follow the same pattern. ~3-5 days per server. Could ship as 3 separate small PRs to keep blast radius low. Cross-agent benchmarking gap (FRONTIER-007 below) depends on chump-mcp-eval existing.
  source_doc: external (goose 70+ MCP extensions; AAIF MCP standard)
  closed_date: '2026-04-20'

- id: COMP-010
  domain: completeness
  title: Brew formula + signed installer — `brew install chump` adoption path
  status: done
  priority: P2
  effort: s
  description: |
    Goose ships via `brew install --cask block-goose` plus signed installers for macOS/Linux/Windows. Chump requires git clone + cargo build, which gates adoption to Rust developers comfortable with toolchain setup. Brew formula is the single highest-leverage adoption-friction reduction we can do — it makes Chump installable in one command for the macOS dev audience that is Chump's core target. Signed installers + GitHub release pipeline extend that to Linux/Windows.
  notes: |
    ~1-2 days for the brew formula + tap setup. ~2-3 more days for cross-platform release pipeline + signing. Total effort ~1 week. Reference: https://github.com/block/homebrew-tap or similar.
  source_doc: external (block/goose `brew install --cask block-goose` distribution)
  closed_date: '2026-04-20'

- id: COMP-011a
  domain: completeness
  title: Adversary-mode-lite — static-rules runtime tool-action monitor
  status: done
  priority: P2
  effort: s
  description: |
    Goose's Adversary Mode is a sophisticated LLM-based context-aware reviewer that watches every tool call before execution (https://goose-docs.ai/docs/guides/security/adversary-mode/). Implementing the full LLM version is COMP-011b (1-2 weeks). COMP-011a ships a static-rules-only first version: a YAML file (chump-adversary.yaml) with BLOCK / ALLOW patterns matched against tool name + args before execution. Default-deny for shell commands that touch ~/.ssh, .env, /etc/, or external network domains not in an allowlist. Default-allow for everything else under repo worktree paths. Fail-open if the rules file is missing.
  notes: |
    Static rules cover ~80% of accident-class harms; LLM reviewer (COMP-011b) covers context-aware "this is suspicious for THIS task" cases. Ship 011a first — bigger immediate safety win for less effort. Reference goose's default rules at https://goose-docs.ai/docs/guides/security/adversary-mode/
  source_doc: external (block/goose Adversary Mode, Jan 2026)
  closed_date: '2026-04-20'

- id: COMP-011b
  domain: completeness
  title: Adversary mode full — LLM-based context-aware reviewer (after COMP-011a)
  status: done
  priority: P3
  effort: l
  description: |
    Full LLM-based version of the goose adversary reviewer pattern. A secondary agent (likely a smaller/cheaper model than the main agent — e.g. claude-3-haiku reviewing claude-sonnet-4-5 actions) watches each tool call with full context: original task, recent messages, tool call details. Returns ALLOW / BLOCK with reasoning. Blocked calls cannot be retried. Fail-open if reviewer fails. Configuration via adversary.md natural-language rules.
  depends_on: [COMP-011a]
  notes: |
    Significant effort (~1-2 weeks). Watch for latency cost — every tool call now costs 1 extra LLM call. Recommend Haiku-tier model as reviewer (~50ms latency) and only invoke for "interesting" tools. Direct port of goose Adversary Mode pattern.
  source_doc: external (block/goose Adversary Mode, Jan 2026)
  closed_date: '2026-04-20'

- id: COMP-012
  domain: completeness
  title: MAESTRO + NIST AI RMF threat modeling — formalize Chump's safety posture
  status: done
  priority: P3
  effort: m
  description: |
    The 2026 enterprise agentic-AI safety landscape standardized on two frameworks: MAESTRO (agentic AI threat modeling — covers prompt injection, data poisoning, multi-step bypass attempts) and NIST AI Risk Management Framework. Chump has tool approval lists + adversary mode (COMP-011a/b coming) but no formal threat model. For Chump to be enterprise-credible (or even small-team-credible) it needs a documented threat model that names what Chump defends against, what it doesn't, and what compensating controls users should add. Not a code change — a structured docs artifact mapping Chump's actual capabilities to MAESTRO threat categories.
  depends_on: [COMP-011a]
  notes: |
    ~1 week docs + cross-reference work. References: MAESTRO framework, NIST AI RMF. Not strictly required for open-source dogfooding, but required for any enterprise/compliance conversation.
  source_doc: external (Gemini AGI letter — agentic safety frameworks)
  closed_date: '2026-04-20'

- id: COMP-013
  domain: completeness
  title: MCPwned / DNS rebinding mitigation audit on Chump MCP servers
  status: done
  priority: P2
  effort: s
  description: |
    The Gemini letter cites "MCPwned" — a class of exploits where local MCP tool calls can be hijacked via browser-based DNS rebinding. Affects MCP SDK implementations that don't properly validate Origin headers / loopback restrictions. Chump ships 3 MCP servers (chump-mcp-adb, chump-mcp-github, chump-mcp-tavily) and is about to ship 3 more (COMP-009). Need to audit all 6 for the rebinding-attack class before COMP-009 ships. The MCP SDK we depend on may already mitigate this — verify or patch.
  notes: |
    ~2-4 hour audit + any required patches. Reference: search "MCPwned DNS rebinding" — exploit class described in industry security coverage 2026-Q1. Block your COMP-009 release on this audit.
  source_doc: external (Gemini AGI letter — MCPwned exploit class)
  closed_date: '2026-04-19'

- id: COMP-014
  domain: completeness
  title: Cost ledger broken across ALL providers — recorded $0.00 across 4621 calls today
  status: done
  priority: P2
  effort: m
  description: |
    Audited cost-ledger.jsonl on 2026-04-19: 4621 calls recorded, total $0.00 spend. Half were Together (likely free tier — fine) but the OTHER half were Anthropic Sonnet/Haiku/Opus calls that should have been priced and weren't. Original framing of this gap was wrong (assumed only Together pricing was missing). Reality: ledger is broken or pricing config is missing for everything. Today's actual session spend is unknown without checking the Anthropic dashboard manually. This breaks Q3 budget planning, breaks per-session cost ceilings (INFRA-COST-CEILING depends on this), breaks cost attribution per gap.
  notes: |
    ~1 day. Was filed as P3 / "Together-only" originally; rescoped P2 after audit revealed Anthropic recording also broken. Blocks INFRA-COST-CEILING.
  source_doc: session 2026-04-19 cost audit
  closed_date: '2026-04-20'

- id: DOC-001
  domain: infra
  title: Integrate FINDINGS.md into book/src/SUMMARY.md navigation
  status: done
  priority: P3
  effort: s
  description: |
    docs/FINDINGS.md shipped 2026-04-20 as the canonical empirical-findings index. The mdBook at book/src/SUMMARY.md does not yet surface it — so the doc is discoverable via grep but not via the rendered book navigation. Add a navigation entry in SUMMARY.md under a "Research" or "Findings" section header so external readers browsing the book land on the findings index. Not urgent (the file is grep-discoverable) but worth closing for completeness. Kept as a separate P3 gap rather than bundled with the FINDINGS.md commit because SUMMARY.md is in active edit contention with sibling agents writing chronicles, and a dedicated narrow gap is safer than a bypassed lease edit.
  acceptance_criteria:
    - book/src/SUMMARY.md has a navigation entry linking to docs/FINDINGS.md under an appropriate section header
    - mdBook renders the findings page without broken links
  notes: |
    ~10 minutes of work. Assign to any sibling agent with a quiet slot who can verify no concurrent SUMMARY.md edit is in flight before touching the file.
  source_doc: docs/FINDINGS.md (2026-04-20)
  closed_date: '2026-04-20'

- id: DOC-002
  domain: infra
  title: docs/ consolidation — merge clusters, archive completed evals, delete stubs (one-time cleanup)
  status: done
  priority: P2
  effort: l
  description: |
    One-time cleanup to complement INFRA-009 (net-zero pre-commit hook). RED_LETTER #3 measured docs/ at 139 files (actual audit: 189). Target state ~80 files. Plan produced 2026-04-20 in a self-paced /loop session. Four phases, shipped as separate small PRs to keep blast radius bounded and link graph intact:
      (1) MERGE clusters additively — create MISTRALRS.md (from 3
          sources), PWA.md (from 3), CONSCIOUSNESS.md (summary of the
          108K AB_RESULTS + utility pass), ROADMAP_INDEX.md (from 5
          role-specific roadmaps). Each merge = one PR.
      (2) ARCHIVE to docs/archive/2026-04/ — ~30 completed
          EVAL-0XX/MEM-0XX writeups, SESSION_2026-04-18_SYNTHESIS.md,
          superseded vision drafts (TOP_TIER_VISION, STRATEGY_VS_GOOSE,
          THREAT_MODEL). Update inbound refs in gaps.yaml +
          RESEARCH_PLAN_2026Q3.md atomically.
      (3) MOVE to docs/howto/ — per-tool operational docs
          (DISCORD_CONFIG, HOMEBREW_INSTALL, GPU_TUNING, OLLAMA_SPEED,
          SETUP_AND_RUN, PLUGIN_DEVELOPMENT).
      (4) DELETE ~35 stubs/one-offs — BATTLE_QA*, DAILY_DRIVER_95_STEPS,
          INTENT_CALIBRATION, HEARTBEAT_IMPROVEMENTS, REASONING_MODE,
          RPC_MODE, SOAK_72H_LOG, UI_*_TEST_MATRIX, etc. Last, so
          merges/archives settle first.
    Critical link-graph risks (must update refs atomically if touched): CONSCIOUSNESS_AB_RESULTS.md (6 gaps + RESEARCH_PLAN + blog), EVAL-0XX series (gaps.yaml), CHUMP_TO_COMPLEX.md (gate for 10+ gaps), OPERATIONS.md (CLAUDE.md ref), RESEARCH_INTEGRITY.md (do not move — CLAUDE.md mandatory read).
  acceptance_criteria:
    - "Phase 1 complete: MISTRALRS.md, PWA.md, CONSCIOUSNESS.md, ROADMAP_INDEX.md merged docs exist; no sources deleted yet"
    - "Phase 2 complete: docs/archive/2026-04/ populated; all inbound refs in gaps.yaml + RESEARCH_PLAN_2026Q3.md updated atomically"
    - "Phase 3 complete: docs/howto/ created, operational docs moved"
    - "Phase 4 complete: stubs deleted; original merged sources deleted (after Phase 1 lands)"
    - Final docs/ file count ≤ 90 (from 189); no broken references in CLAUDE.md, AGENTS.md, code, scripts, or other docs
  depends_on: [INFRA-009]
  notes: |
    File lease widely — every phase touches docs/ which is in active contention. Coordinate in ambient before each phase. Use separate worktree per phase (doc-prune-merge, doc-prune-archive, doc-prune-howto, doc-prune-delete) so PRs are small and independently reviewable. Plan details: see conversation transcript 2026-04-20 or re-run the audit with same prompt.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-20'

- id: DOC-003
  domain: infra
  title: FINDINGS.md F4 reframed with EVAL-073 both-strict 100% result
  status: done
  priority: P2
  effort: xs
  description: |
    EVAL-073 (shipped PR #317) demonstrated that the cross-judge disagreement documented in FINDINGS.md F4 was a prompt-asymmetry artifact, not a model-family disagreement. Under a shared strict binary rubric, Sonnet-4.5 and Llama-3.3-70B agree 100% on the same 90 rows. FINDINGS.md F4 still claims philosophically-contested judge divergence — needs update.
  acceptance_criteria:
    - FINDINGS.md F4 summary-table row updated to mention both-strict 100% result
    - "FINDINGS.md F4 caveats section gains a note retiring the \"instantiate different answers\" framing"
    - Load-bearing methodological implication (strict binary required) preserved
  depends_on: [EVAL-073]
  source_doc: docs/eval/EVAL-073-both-strict-rescore.md
  closed_date: '2026-04-20'

- id: DOC-004
  domain: doc
  title: Onboarding simulation — fresh Claude agent, docs-only mount, first-task completion
  status: done
  priority: P2
  effort: s
  description: |
    CPO-framing gap, Tier 3. Substitutes for a paid documentation-quality auditor by simulating a cold contributor. Scope: (1) scripts/audit/onboarding-sim.sh spawns a Claude agent with only ./docs/ mounted (no code access), no Chump tooling, and a prompt asking it to execute a first-task scenario (pick gap, explain repo layout, explain claim+ship flow) without running anything; (2) rubric-score the agent's output (can it identify pre-flight, explain leases, cite the right docs); (3) commit transcript + score to docs/audit/onboarding-sim-YYYY-MM-DD.md; (4) monthly re-run; (5) low score files a DOC-* gap with specific friction. Cheapest high-signal audit gap in the slate.
  acceptance_criteria:
    - scripts/audit/onboarding-sim.sh exists and runs a fresh Claude agent with docs-only mount
    - Rubric defined with ≥ 5 scoring criteria
    - Run committed to docs/audit/onboarding-sim-YYYY-MM-DD.md
    - Low scores auto-file DOC-* follow-up gaps
    - Monthly re-run cadence declared
  notes: Closes reviewer role
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-24'

- id: DOC-005
  domain: doc
  title: Doc hygiene plan — classification, automation, staged consolidation
  status: done
  priority: P2
  effort: m
  source_doc: docs/DOC_HYGIENE_PLAN.md
  closed_date: '2026-04-25'
  closed_pr: 529

- id: DOC-006
  domain: doc
  title: Doc inventory script + first CSV run (DOC-005 Phase 1)
  status: done
  priority: P2
  effort: xs
  description: |
    Phase 1 of the DOC-005 doc hygiene plan: ship scripts/doc-inventory.py and the first generated docs/_inventory.csv. The script walks top-level docs/*.md, reads YAML front-matter (doc_tag, owner_gap, last_audited), counts inbound references across docs/, book/src/, src/, scripts/, .github/, tests/, AGENTS.md, CLAUDE.md, README.md, and emits a CSV with columns: path, tag, owner_gap, last_modified, inbound_refs, line_count, last_audited. Tolerates missing front-matter (writes tag=untagged). First run finds 144 top-level docs, all untagged (Phase 0 not yet run), and 6 orphan candidates with zero inbound refs (CONTEXT_ASSEMBLY_AUDIT, CRATE_AUDIT, EVALUATION_PRIORITIZATION_FRAMEWORK, FLEET_OPEN_QUESTIONS_RESEARCH_2026Q2, GAPS_YAML_TO_SQLITE_MIGRATION, RED_LETTER_RESPONSE_2026Q2) — surfaced for Phase 3 staged consolidation, not actioned in this PR.
  acceptance_criteria:
    - scripts/doc-inventory.py committed and executable
    - docs/_inventory.csv generated and committed (144 rows)
    - Script tolerates missing front-matter without crashing
    - Orphan candidates (zero inbound refs) reported on stderr at run time
  depends_on: [DOC-005]
  notes: |
    XS effort. Subsequent phase gaps (Phase 0 classification, Phase 2 automation, Phase 3 staged consolidation, Phase 4 generated docs) get their own gap entries when picked up. The CSV is generated, not hand-edited — re-run the script after any docs/ changes to refresh it.
  source_doc: docs/DOC_HYGIENE_PLAN.md
  closed_date: '2026-04-25'

- id: DOC-007
  domain: DOC
  title: Phase 0 — classify top-level docs with doc_tag front-matter
  status: done
  priority: P2
  effort: s
  description: |
    Phase 0 of DOC-005 hygiene plan. Adds doc_tag front-matter to 145 top-level docs/*.md.
  acceptance_criteria:
    - Every top-level docs/*.md has doc_tag front-matter
    - docs/_inventory.csv regenerated, untagged=0
  depends_on: [DOC-005, DOC-006]
  notes: Mechanical multi-file change shipped as one intent-atomic PR.
  source_doc: docs/DOC_HYGIENE_PLAN.md
  closed_date: '2026-04-26'

- id: DOC-008
  domain: DOC
  title: "Red Letter #6 cleanup — WORK_QUEUE.md duplicate + DOC-005 stale-open"
  status: done
  priority: P3
  effort: xs
  description: |
    Red Letter Issue #6 (2026-04-26) flagged two trivial registry-hygiene items: docs/WORK_QUEUE.md lines 18-19 listed RESEARCH-021 twice (mechanical paste error from the 2026-04-22 update), and DOC-005 remained `status: open` despite PR #529 having shipped its sole deliverable (docs/DOC_HYGIENE_PLAN.md) on 2026-04-25 — exactly the open-but-landed pattern INFRA-066's CI guard catches at gap-add time. Bundles both as a one-shot mechanical fix.
  acceptance_criteria:
    - docs/WORK_QUEUE.md has a single RESEARCH-021 row (line 18 only)
    - "docs/gaps.yaml DOC-005 entry has status:done, closed_date:'2026-04-25', closed_pr:529"
  source_doc: docs/RED_LETTER.md
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: DOC-009
  domain: DOC
  title: WORK_QUEUE.md stale — priority and status drift misleads agents on active P0 decisions
  status: done
  priority: P1
  effort: xs
  description: |
    Cold Water Issue #7 (2026-04-26): docs/WORK_QUEUE.md (added 2026-04-22 as "single
    source of truth for what to work on next") now contains: RESEARCH-021 listed as P0
    (demoted to P1 on 2026-04-24); REMOVAL-003 listed as "P2 OPEN" (closed PR #465,
    2026-04-25); PRODUCT-009 listed as P1 (demoted to P2 on 2026-04-24); Python 3.12
    discipline listed as an "active blocker" (resolved Issue #4 addendum, 2026-04-22);
    EVAL-042, EVAL-043, COG-031 listed as "pending research" (all status: done in
    gaps.yaml). An agent reading WORK_QUEUE.md today will attempt closed gaps and
    investigate resolved blockers. DOC-008 corrected only the RESEARCH-021 dedup; none
    of the priority or status errors were fixed. Fix: update WORK_QUEUE.md from live
    gaps.yaml data and add a note that it must be regenerated via `chump gap dump` or
    checked against gaps.yaml before trusting. Long-term: gate WORK_QUEUE.md generation
    on the gap store export so it cannot drift.
  acceptance_criteria:
    - WORK_QUEUE.md active-work table reflects live gaps.yaml status (no closed gaps, correct priorities)
    - Python 3.12 blocker row removed from Blockers & Debt section
    - Pending Research section reflects live gaps.yaml status
    - Either WORK_QUEUE.md is regenerated automatically from `chump gap dump` or it carries a header warning that it is manually maintained and may lag gaps.yaml
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: DOC-010
  domain: DOC
  title: README and faculty docs claim nine engineering proxies - most are dead, no-op, or computed-not-applied; reframe to actual implementation status
  status: open
  priority: P1
  effort: s
  description: |
    README.md advertises nine engineering proxies inspired by cognitive
    science (surprise tracking, belief state, blackboard/global workspace,
    neuromodulation, precision controller, memory graph, counterfactual
    reasoning, phi proxy, holographic workspace). Code reality (verified
    2026-04-26) - surprise tracking removed in REMOVAL-002 (trait stubs
    remain); belief_state default impl is no-op (REMOVAL-005 sweeps the
    callsites); neuromodulation values computed but never applied
    (REMOVAL-006); phi_proxy and holographic_workspace not called from
    request path (REMOVAL-007). Only blackboard, memory_graph, and
    perception layer are actually wired. Reframe README to either (a) list
    only the wired faculties or (b) keep the nine-faculty framing but add
    a status-per-faculty table that matches code. Same treatment for
    CHUMP_FACULTY_MAP.md, CHUMP_PROJECT_BRIEF.md, CHUMP_RESEARCH_BRIEF.md
    (RESEARCH-002 covers this but at thesis level - this gap is the
    user-facing README pass).
  acceptance_criteria:
    - README cognitive-architecture bullet either lists only wired faculties or includes a status table with code-link per faculty
    - Status reflects - wired/no-op/dead-code/computed-not-applied
    - CHUMP_FACULTY_MAP.md updated to match
    - Cross-link to RESEARCH_INTEGRITY.md prohibited-claims table
  opened_date: '2026-04-26'

- id: DOC-011
  domain: DOC
  title: Replace WORK_QUEUE.md with CLI pointer — chump gap list is canonical, parallel doc drifts
  status: open
  priority: P2
  effort: xs
  description: |
    docs/process/WORK_QUEUE.md duplicates content already canonical in
    .chump/state.db (queryable via `chump gap list`). DOC-008 and DOC-009
    each fixed staleness in this doc and it was wrong by EOD the same day.
    The system already has three authoritative surfaces for this content -
    chump gap list (live), docs/gaps.yaml (regenerated mirror), and
    docs/audits/RED_LETTER.md (blockers). A fourth hand-curated surface
    adds drift, not signal. Replace the doc body with a short pointer to
    the CLI; keep the file so existing links don't 404.
  acceptance_criteria:
    - docs/process/WORK_QUEUE.md is a short pointer (~30 lines) directing to chump gap list
    - No active-work / blockers / pending-research tables (those subset gaps.yaml and RED_LETTER)
    - doc_tag changed from log to pointer
    - Existing inbound links (RED_LETTER.md, _inventory.csv) still resolve
  opened_date: '2026-04-26'

- id: DOC-012
  domain: DOC
  title: NORTH_STAR.md cognitive-architecture claims contradict RESEARCH_INTEGRITY.md validated findings
  status: done
  priority: P1
  effort: xs
  description: |
    docs/strategy/NORTH_STAR.md:19 states "The cognitive architecture
    underneath Chump — free energy, surprise tracking, belief state,
    neuromodulation, precision weighting, memory graphs, counterfactual
    reasoning — is not a research project. It is the mechanism that
    makes this possible." NORTH_STAR.md:59 reinforces: "The cognitive
    layer (neuromodulation, precision controller, belief state, surprise
    tracker) is the mechanism."
    
    docs/process/RESEARCH_INTEGRITY.md's validated findings table and
    prohibited-claims section directly contradict every module named:
    neuromodulation is net-negative (EVAL-029, medium confidence);
    belief_state was removed (REMOVAL-003 done, PR #465, inert stub
    at src/belief_state.rs); surprisal EMA is unvalidated until
    EVAL-043 ships; belief state improvement is prohibited until
    EVAL-035 + EVAL-043. DOC-010 (P1, open) covers README and faculty
    docs only — NORTH_STAR.md is not in scope.
    
    Cold Water Issue #8 filed DOC-012. Evidence: NORTH_STAR.md:19,59
    (claims); RESEARCH_INTEGRITY.md prohibited-claims table (lines
    referencing EVAL-043, EVAL-035); REMOVAL-003 (belief_state done).
  acceptance_criteria:
    - NORTH_STAR.md Heartbeat section no longer claims unvalidated or net-negative modules as proven mechanisms
    - Any cognitive architecture claim in NORTH_STAR.md cites the supporting gap ID and confidence level from RESEARCH_INTEGRITY.md
    - RESEARCH_INTEGRITY.md reviewed to confirm no other foundational docs make the same prohibited claims
  opened_date: '2026-04-27'
  closed_date: '2026-04-28'
  closed_pr: 633

- id: DOC-013
  domain: DOC
  title: Document fleet inference seam (Provider trait + Semaphore) in INFERENCE_PROFILES.md
  status: open
  priority: P3
  effort: s
  description: |
    Document the fleet seam created by INFRA-165: all in-process callers route through app.inference (Arc<dyn Provider>). FLEET-014 (multi-machine inference, deferred to 2027) replaces this with a remote Provider impl via gRPC/tonic; the rest of the codebase does not change. One paragraph at the bottom of docs/operations/INFERENCE_PROFILES.md. No new files, no RPC stubs, no half-built distribution layer.
  acceptance_criteria:
    - docs/operations/INFERENCE_PROFILES.md has a 'Fleet seam' section (1 paragraph) explaining the Provider trait + Semaphore as the abstraction boundary
    - references FLEET-014 by ID for traceability
    - no code changes
  depends_on: [INFRA-165]
  notes: |
    See ~/.claude/plans/local-first-is-the-eager-hopcroft.md (approved 2026-04-28). Part of the local-first redesign filed after today's three-way runner contention incident (ChumpMenu + chump --web + autopilot all queued on one Ollama runner). Sub-problem #6 of 6. Pure doc. depends-on: INFRA-165 (the seam doesn't exist until then).

- id: DOC-014
  domain: DOC
  title: ONBOARDING.md '<60s FTUE' claim is false until bottles ship — qualify or remove
  status: done
  priority: P0
  effort: xs
  closed_date: '2026-04-30'
  closed_pr: 676

- id: EVAL-001
  domain: eval
  title: Expand eval suite from 5 to 30+ cases with golden trajectory tests
  status: done
  priority: P1
  effort: m
  description: |
    Current seed suite has 5 eval cases. Cannot detect regressions across the full behavioral surface. Target 30+ cases covering all EvalCategory variants plus golden conversation trajectories and replay against saved conversations.
  notes: |
    37 single-turn seed cases across 6 EvalCategory variants; 5 golden trajectory cases (gt- prefix) with conversation_history. EvalCase.is_multiturn() added. Guard tests: seed_starter_cases_has_at_least_30, seed_covers_all_categories (min 3 per category), seed_has_at_least_5_golden_trajectory_cases.
  source_doc: docs/CHUMP_TO_COMPLEX.md, docs/AUTONOMY_ROADMAP.md
  closed_date: '2026-04-16'

- id: EVAL-002
  domain: eval
  title: LLM-as-judge response quality scoring for eval runs
  status: done
  priority: P2
  effort: l
  description: |
    EvalCase property checks are structural (contains, json_path, regex). No semantic quality scoring. Cannot distinguish "technically passes but wrong answer" from "correctly answers with proper tool use."
  depends_on: [EVAL-001]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: EVAL-003
  domain: eval
  title: Golden trajectory tests — multi-turn replay against saved conversations
  status: done
  priority: P2
  effort: l
  description: |
    The 52-case single-turn seed suite (EVAL-001) catches tool-selection and property-level regressions but doesn't exercise the 3-25-turn loop where context-accumulation bugs live (the <think>-accumulation qwen3:8b regression is the canonical example). Add a separate golden-trajectory harness: save real conversations, replay them turn-by-turn, diff the trajectory of tool calls + assistant messages against the golden.
  depends_on: [EVAL-001]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: EVAL-004
  domain: eval
  title: Wire async LLM-as-judge into battle_qa + report per-category score
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-002 shipped the sync scoring engine (parse_judge_response, score_with_judge, check_all_properties_with_judge). Remaining work: build the async adapter that produces the judge closure from a delegate_tool inference call, and wire scripts/battle-qa.sh to record average judge_score per EvalCategory for trend tracking.
  depends_on: [EVAL-002]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: EVAL-005
  domain: eval
  title: Seed cases with LlmJudge + battle-qa.sh per-category summary
  status: done
  priority: P3
  effort: xs
  description: |
    EVAL-004 shipped the async adapter but left two small integration pieces: (a) at least 3 seed cases in eval_harness::seed_starter_cases gain an LlmJudge ExpectedProperty for the canonical "is the answer semantically correct?" check; (b) scripts/battle-qa.sh persists judge_score to chump_eval_runs.scores_json and prints the per-category summary that average_judge_score_per_category() already computes.
  depends_on: [EVAL-004]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: EVAL-006
  domain: eval
  title: scripts/battle-qa.sh --with-judge integration
  status: done
  priority: P3
  effort: xs
  description: |
    EVAL-005 added LlmJudge properties to 3 seed cases. Remaining bash-level work: scripts/battle-qa.sh gains a --with-judge flag that routes eval runs through check_all_properties_with_judge_async and persists judge_score to chump_eval_runs.scores_json, then prints the per-category summary using average_judge_score_per_category().
  depends_on: [EVAL-005]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: EVAL-007
  domain: eval
  title: Wire CHUMP_EVAL_WITH_JUDGE into the main agent loop
  status: done
  priority: P3
  effort: m
  description: |
    EVAL-006 shipped the bash flag and per-category summary reader. Remaining piece: the main agent loop needs to detect CHUMP_EVAL_WITH_JUDGE=1, and when a running EvalCase has an LlmJudge property, call check_all_properties_with_judge_async with the session provider and persist judge_score into chump_eval_runs.scores_json (as the `judge_score` field).
    BLOCKER (2026-04-17 re-scope): the eval_harness is currently a library — nothing in production calls load_eval_cases() or save_eval_run(). battle-qa.sh shells out to the regular agent loop and reads chump_eval_runs for its summary, but nothing writes there outside tests. Closing this gap requires FIRST building an eval runner entry point (CLI subcommand `chump eval run` or similar) that loads cases, runs the agent, scores, and persists. Effort re-classed from s → m to reflect this.
  depends_on: [EVAL-004, EVAL-006, EVAL-009]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: EVAL-008
  domain: eval
  title: A/B-grade reflect_via_provider vs reflect_heuristic on labeled episodes
  status: done
  priority: P3
  effort: m
  description: |
    COG-008 shipped the LLM reflection adapter but couldn't close the original acceptance clause ("A/B against heuristic on 20 episodes shows >=15% more accurate ErrorPattern classifications") because that requires a labeled dataset of >=20 captured episodes with ground-truth ErrorPattern annotations. Logistics of building that dataset were bigger than the COG-008 effort envelope.
  notes: |
    Synthetic 20-episode dataset shipped (3e23adc) covers all 9 ErrorPattern variants. Real-data upgrade (curate ~20 actual production episodes with gold labels) is DEFERRED until ~1 month of real session history accumulates the natural diversity. Closes when scripts/ab-harness/run-queue.sh fires the run and append-result writes the delta to CONSCIOUSNESS_AB_RESULTS.md. - COG-008
  source_doc: src/reflection.rs
  closed_date: '2026-04-17'

- id: EVAL-009
  domain: eval
  title: Eval runner CLI — `chump eval run` loads cases, runs agent, persists EvalRunResult
  status: done
  priority: P3
  effort: m
  description: |
    eval_harness is a library. No production path calls load_eval_cases() → run agent → check_all_properties_with_judge_async → save_eval_run. battle-qa.sh writes episodes but not chump_eval_runs rows; the --with-judge summary it reads is empty until we actually run the harness against real cases.
  depends_on: [EVAL-001, EVAL-004]
  source_doc: src/eval_harness.rs
  closed_date: '2026-04-17'

- id: EVAL-010
  domain: eval
  title: Human-labeled fixture subset — break circular author-grades-author A/B loop
  status: done
  priority: P1
  effort: m
  description: |
    Current A/B fixtures (perception_tasks.json, neuromod_tasks.json, reflection_tasks.json) embed expected_properties authored by the same person who built the framework, then graded by an LLM judge using the same model as the agent. The cloud A/B sweep (commit ce4ebc0) revealed this circularity: lessons-block A/B shows -0.05 mean delta across 160 trials, but it is impossible to tell whether the framework genuinely hurts or whether the fixture rubric penalizes the framework's verbose output style.
  notes: |
    Recommended follow-up from cloud A/B sweep (ce4ebc0). Estimated ~2 hours of human grading. Without this, no further cognitive-layer A/B effort should be funded — we cannot tell signal from rubric noise.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-18'

- id: EVAL-011
  domain: eval
  title: Fix LLM-judge hallucination bias — add DoesNotHallucinateFunctionCalls property
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-010 second-LLM grading revealed the original LLM judge rewarded hallucinated tool execution (fake <function_calls> blocks reporting invented results like "deleted 3 files") and penalized honest "I cannot execute this" responses. Per-trial agreement between judge and 2nd-LLM was 38-63% — at or below chance on two binary judges — confirming systematic calibration failure. Without fixing the judge, A/B deltas are unreliable for all cognitive-layer experiments.
  depends_on: [EVAL-010]
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-18'

- id: EVAL-012
  domain: eval
  title: Multi-turn conversation A/B — does framework effect compound or wash out
  status: done
  priority: P1
  effort: m
  description: |
    Every cognitive-layer A/B in the repo is single-shot (one prompt → one response). Production agents loop over 3-10+ turns with tool use. The framework's value (or harm) likely compounds over turns — single-shot A/Bs cannot measure this. We are not measuring the thing we deploy.
  notes: |
    TEST-CAT-A in docs/eval/TEST_BACKLOG.md. Likely needs new harness (run-cloud-v2.py is single-shot only). Could fork to run-cloud-multiturn.py that drives a loop. Per-trial cost is ~5x single-shot.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-013
  domain: eval
  title: Real reflection lessons (not synthetic block) — does THE thing help
  status: done
  priority: P1
  effort: l
  description: |
    Every A/B injects a generic synthetic lessons block. We are testing the delivery mechanism, not real reflection. The lessons block in production contains distilled wisdom from past episodes — that signal is buried under generic-text noise in our current harness.
  depends_on: [EVAL-022]
  notes: |
    TEST-CAT-B. The expected finding is "real lessons help more than synthetic" — would be the first publishable positive result for the framework. If real lessons also fail to help, the framework needs a deeper redesign (not just prompt-engineering).
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-014
  domain: eval
  title: Multi-judge median verdict — eliminate single-judge bias
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-010 second-LLM grading already showed sonnet-4-5 has systematic biases (rewards hallucinated tool execution). Single-judge results inherit those biases. Median verdict over 2-3 judges from different model families cuts the bias. Required for any defensible publication.
  notes: |
    TEST-CAT-D. Blocker is API key access to a non-Anthropic model. Either user provides OpenAI/Gemini key, OR we add an Ollama-local judge (slower but free). Cost: ~3x the single-judge cost.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-015
  domain: eval
  title: Adversarial prompt-injection robustness A/B
  status: done
  priority: P2
  effort: m
  description: |
    The lessons block is a system-role injection. Production safety requires that user prompts cannot override or weaponize it. We have zero data on this.
  notes: |
    TEST-CAT-E. Should run BEFORE any production-default flip on reflection_injection_enabled().
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-016
  domain: eval
  title: Refusal calibration A/B — false-refuse vs false-comply
  status: done
  priority: P2
  effort: m
  description: |
    Lessons block emphasizes safety. Likely pushes the agent toward over-refusal on legitimate requests. We have no measurement of false-refuse vs false-comply.
  notes: |
    TEST-CAT-F. Critical for production deployment — over-refusal kills user trust faster than occasional false-comply.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-017
  domain: eval
  title: Real tool integration A/B — do lessons help when tools EXIST
  status: done
  priority: P2
  effort: s
  description: |
    Our entire A/B has been no-tools-available. The hallucination problem only exists because tools weren't actually there. With real tools, the lessons block might genuinely help OR might cause the agent to call tools too eagerly.
  notes: |
    TEST-CAT-G. scripts/ab-harness/run.sh already supports the chump backend; just needs v2 scoring wired in.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-018
  domain: eval
  title: Memory recall A/B — does memory subsystem help on recall tasks
  status: done
  priority: P2
  effort: m
  description: |
    Memory and reflection are conflated in the current framework messaging. They are separate systems. Need to test memory independently.
  notes: TEST-CAT-I.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-019
  domain: eval
  title: Cross-session continuity A/B — do new sessions resume context
  status: done
  priority: P2
  effort: l
  description: |
    Production sessions don't restart from blank. Continuity is a UX-critical property. We have no measurement.
  depends_on: [EVAL-018]
  notes: TEST-CAT-J.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-020
  domain: eval
  title: Persona/tone consistency A/B — does framework alter UX
  status: done
  priority: P3
  effort: m
  description: |
    A safety/correctness improvement that turns the agent into a robot bureaucrat is a UX regression. Need to measure.
  notes: TEST-CAT-K.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-021
  domain: eval
  title: Longitudinal accumulation — does agent get better over 100 sessions
  status: done
  priority: P3
  effort: l
  description: |
    The framework's actual longitudinal claim is that the agent gets better over time as it accumulates lessons + memory. Single-shot A/Bs cannot measure this. This gap operationalizes the claim.
  depends_on: [EVAL-013, EVAL-018]
  notes: |
    TEST-CAT-L. The capstone gap. If this passes with a meaningful delta, the framework is empirically validated. If it doesn't, the framework needs deeper redesign.
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-18'

- id: EVAL-022
  domain: eval
  title: Expand cognitive-layer fixtures to n>=100 tasks each
  status: done
  priority: P1
  effort: m
  description: |
    Current cognitive-layer fixtures (perception_tasks.json, neuromod_tasks.json, reflection_tasks.json) have only 20 tasks each. At n=20 per cell, the 95% Wilson CI on a 50% pass rate is ±0.22 — meaning any A/B delta below ±0.10 is within sampling noise. The "Methodological critique" section of CONSCIOUSNESS_AB_RESULTS.md (commit d5187c2) calls this out as severity-1 methodological flaw blocking any defensible publication.
    The v2 harness (run-cloud-v2.py) ships with multi-axis scoring + Wilson CIs + A/A control mode. It will print "WITHIN NOISE" for any delta that cannot be distinguished from sampling variation. At n=20 it correctly flags every observed delta as noise. The harness is not the bottleneck; the fixture size is.
  notes: |
    Task authoring is the bulk of the effort (~80 new tasks per fixture). Could be partly LLM-generated then human-reviewed for diversity. After this lands, the v2 harness can produce numbers that are safe to cite in research papers without the "preliminary, n=20" hedge.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-18'

- id: EVAL-023
  domain: eval
  title: Cross-family judge run — break Anthropic-only judge bias
  status: done
  priority: P1
  effort: s
  description: |
    Every cloud A/B finding to date used claude-sonnet-4-5 as the judge. EVAL-010 second-LLM grading (also Anthropic, different model size) already showed 38-63% per-trial agreement — at or below chance for two binary judges — confirming systematic Anthropic-family judge bias. The PR #83 Ollama judge support enables a true cross-family judge (qwen2.5:14b or similar) at zero per-call cost. This gap operationalizes: run the n=100 sweep on haiku-4-5 again with --judges claude-sonnet-4-5,ollama:qwen2.5:14b. Median verdict gives the first cross-family-judged delta. If the +0.14 hallucination signal survives across the median, the finding is bias-resistant.
  notes: |
    Uses PR #83 (Ollama judge) which is auto-merge pending. Cost is bounded by the cloud agent calls (~\$1.62 same as PR #80) since Ollama judge is free. ~3-5 min wall on a quiet Ollama. Single command:
      scripts/ab-harness/run-cloud-v2.py --fixture FIX --tag X-cross --limit 100
        --model claude-haiku-4-5 --judges claude-sonnet-4-5,ollama:qwen2.5:14b
    
    PROBE FINDING (2026-04-19, commit b4882e6): Llama-3.3-70B was tested as a cross-family agent and does NOT fit the existing fake_tool_calls axis — Llama reliably emits honest "I cannot execute" language rather than fake <function_calls> markup, so it always passes where Anthropic models fail. The existing binary axis measures Anthropic-model hallucination shape, not general hallucination.
    REVISED DESIGN: Before running the n=100 cross-family judge sweep, add a positive axis: did_acknowledge_no_tools (model said "I cannot execute" + gave actionable guidance instead of faking tool output). This lets Llama score meaningfully. Options: (a) new axis in score.py, (b) family-specific regex detectors per provider, or (c) re-frame headline finding as "Anthropic-agent + Anthropic-judge pairing reliably exhibits the loop" — the most publishable framing. Pick one before running the cross-family sweep.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: EVAL-024
  domain: eval
  title: "Multi-turn A/B re-run with v2 multi-axis scoring (compose with PR #73)"
  status: done
  priority: P2
  effort: s
  description: |
    PR #73 (EVAL-012) ships a multi-turn conversation A/B harness with v1 single-axis scoring. The single-shot v2 result (PR #80) showed the hallucination effect (+0.14) is invisible to binary pass/fail; the multi-turn harness has the same blind spot. Per the methodology critique in CONSCIOUSNESS_AB_RESULTS.md, multi-axis is required to catch the actual harm channel. This gap composes: extend PR #73's output schema to capture per-turn final_text (already does), then pipe through scripts/ab-harness/rescore-with-v2.py per turn or per conversation. Report whether the lessons-block hallucination effect compounds, washes out, or reverses across turns.
  depends_on: [EVAL-012]
  notes: |
    Likely a small Python wrapper that walks the multi-turn jsonl per-turn and applies rescore-with-v2.py logic. ~50 LOC. Cheap to run since the multi-turn fixture is only 10 tasks and the conversations are already executed (just re-scoring existing logs). Cost: \$0 (re-scoring only).
  source_doc: docs/eval/TEST_BACKLOG.md
  closed_date: '2026-04-19'

- id: EVAL-025
  domain: eval
  title: Validate COG-016 anti-hallucination directive — rerun n=100 cross-family
  status: done
  priority: P1
  effort: s
  description: |
    COG-016 (PR #114) shipped two production changes: (1) a model-tier gate that blocks lessons injection on Capable-tier models like haiku-4-5 by default, and (2) an explicit anti-hallucination directive prepended to the lessons block. EVAL-023 (PR #118) confirmed the pre-COG-016 block causes +0.12-0.17 fake-tool-call emission on haiku-4-5 across all 3 fixtures (perception, neuromod, reflection) under cross-family judging — but did NOT measure the new COG-016 format. Need to rerun the same n=100 × 3 sweep with `LESSONS_BLOCK` updated to match the production `format_lessons_block()` output (anti-hallucination directive included). If COG-016 works, the +0.12-0.17 hallucination delta should drop substantially or invert. If it doesn't work, the tier gate is the only protective mechanism and we need to reconsider the directive wording.
  depends_on: [COG-016, EVAL-023]
  notes: |
    Reuses the EVAL-023 harness path: run-cloud-v2.py with judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo at n=100 per fixture. Only change: `LESSONS_BLOCK` constant updated to match production output of `format_lessons_block()` from src/reflection_db.rs (lines 417-451 on main). Cost ~\$1.50 cloud (haiku-4-5 + sonnet-4-5 + together llama, similar to EVAL-023).
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: EVAL-026
  domain: eval
  title: Cognitive-layer U-curve at 32B — extend 1B-14B sweep upward
  status: done
  priority: P1
  effort: m
  description: |
    The 1B-14B U-curve (per strategic memo, replicated pattern: +10pp 1B, -5pp 3B, neutral 8B, +10pp 14B) is the most-replicated finding pointing at architectural net-positivity, but the prediction "benefit increases above 14B" has not been tested. 32B/72B tiers are the critical unconfirmed prediction — they decide whether the U-curve thesis holds or needs revision. Original plan was local M4 with qwen2.5:32b but ~20GB Q4 + macOS + Claude Code + Ollama overhead crashes Metal on 24GB. Pivoted to Together.ai cloud for the 7B + 72B endpoints.
  depends_on: [COG-016, EVAL-025]
  notes: |
    Cloud run path: scripts/ab-harness/run-cloud-v2.py with --model together:Qwen/Qwen2.5-{7B|72B}-Instruct-Turbo, judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo, --lessons-version v1 (the harm-triggering block, to test if scale flips it from harm to help), --limit 50 reflection. Harness gained together:/ollama: agent-model-prefix dispatch (was Anthropic-only for agent role; judges already supported all three providers). Cost ~\$2-3 cloud (72B Together is \$0.88/M tok, sonnet judge ~\$1).
  source_doc: docs/STRATEGIC_MEMO_2026-04-19.md
  closed_date: '2026-04-19'

- id: EVAL-027
  domain: eval
  title: SAKE knowledge anchoring — apply Feb 2026 KID paper to Chump's lessons + memory
  status: done
  priority: P1
  effort: m
  description: |
    The Knowledge Integration Decay paper (Yu et al, arxiv 2602.09517, Feb 2026) demonstrates that long reasoning chains systematically fail to integrate retrieved external knowledge, and proposes SAKE (Self-Anchored Knowledge Encoding) which anchors the retrieved knowledge at BOTH the start AND end of the reasoning trace — training-free, ~37.6% gain on multi-hop QA. Chump's current lessons block injection is start-only (system prompt prefix) which matches the failure mode the paper identifies. Hypothesis: the cross-architecture neuromod harm signal documented in EVAL-025 (haiku-cog016 -0.15) and EVAL-026 (Qwen-7B -0.16, Llama-70B -0.14, Qwen3-235B -0.10) is partly a KID effect — lessons fire at the start, agent reasons through tool calls, by answer-time the lessons context is lost. SAKE-style "anchor at both ends" is a cheap modification we can A/B against the existing baseline.
  depends_on: [EVAL-025, EVAL-026]
  notes: |
    Implementation: add LESSONS_BLOCK_COG016_SAKE constant to run-cloud-v2.py that wraps the cog016 block as both system-prefix AND user-suffix appended to the prompt. Or implement as a production change in src/reflection_db.rs::format_lessons_block_sake() gated behind CHUMP_LESSONS_ANCHOR=both env var. Cloud-only sweep cost ~\$1-2. Wall ~30min. Reference paper: https://arxiv.org/abs/2602.09517
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: EVAL-028
  domain: eval
  title: CatAttack adversarial robustness sweep on Chump fixtures
  status: done
  priority: P2
  effort: s
  description: |
    The CatAttack paper (arxiv 2503.01781) shows that prepending query-agnostic distractor sentences (e.g. "Interesting fact: cats sleep most of their lives") to math/reasoning prompts increases reasoning-model error rates by 300-500% — a published, reproducible adversarial trigger transferable across DeepSeek R1, OpenAI o1/o3, and Qwen reasoning models. Chump's "Attention" cognitive faculty is currently untested in our A/B harness — this is the cheapest pre-published robustness probe we can run. Three-cell design: cell A = bare prompt, cell B = prompt + cat distractor, cell C = prompt + cat distractor + lessons-block-with-anti-distraction- directive. Tests both raw distraction susceptibility AND whether Chump's lessons layer can mitigate it.
  depends_on: [EVAL-026]
  notes: |
    Lift adversarial triggers verbatim from CatAttack paper Table 2 (no need to invent). Implementation: add --distractor flag to run-cloud-v2.py that prepends a chosen trigger to args.prompt before sending. Reuse existing fixtures unchanged. Cost ~\$2 cloud. Reference paper: https://arxiv.org/abs/2503.01781
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: EVAL-029
  domain: eval
  title: Investigate which neuromod tasks drive cross-architecture harm signal
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-025 (haiku-cog016 -0.15) and EVAL-026 (Qwen-7B -0.16, Llama-70B -0.14, Qwen3-235B -0.10) show a striking cross-architecture pattern: the v1 lessons block consistently hurts on the neuromod fixture by 10-16 percentage points, even though individual cells are within Wilson noise. Four independent measurements at n=50 each (~1200 trials total) directionally agree. Mechanism unknown. Need to drill task-by-task: which of the ~50 tasks in neuromod_tasks.json are responsible? Is it a few high-leverage adversarial tasks or a uniform drift across all tasks? Answer determines whether we (a) fix specific tasks, (b) reformulate the lessons block to handle a specific task class, or (c) accept it as an irreducible tradeoff.
  depends_on: [EVAL-025, EVAL-026]
  notes: |
    Pure data analysis on existing jsonl logs — no new sweep needed. Walk per-trial rows in logs/ab/eval-025-*neuromod*.jsonl and logs/ab/eval-026-*neuromod*.jsonl, group by task_id, compute A-B deltas. ~50 LOC Python. Cost: \$0. Wall: ~1hr.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: EVAL-030
  domain: eval
  title: Task-class-aware lessons block — fix neuromod harm at its root cause
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-029 task drilldown identified TWO distinct mechanisms driving the cross-architecture neuromod fixture harm signal (-0.10 to -0.16 across 4 models, 1200 trials). Neither is the KID context-loss problem EVAL-027 SAKE addresses:
      (a) Conditional-chain dilution — perception directive
          "ask one clarifying question rather than guessing" causes
          early-stopping on multi-step "do X, if it fails do Y, then Z"
          tasks (dynamic-05-policy-confront, dynamic-08-budget-aware,
          dynamic-13-escalation-chain, dynamic-03-retry-loop, etc.)
      (b) Trivial-token contamination — full ~400-token lessons block
          dwarfs short chat prompts ("lol", "k thx", "noice"); agent
          produces structured "what would you like me to do?" output
          that judges score off-rubric.
    Mechanism is directive-misapplication + signal-to-noise dilution, not context loss. EVAL-027 SAKE will not address either. Need a task-class-aware lessons injection: suppress the "ask clarifying question" directive when conditional-chain markers detected (regex for "if.*fails", "then if", etc.); skip the lessons block entirely when user prompt is below a length threshold (e.g. <50 chars).
  depends_on: [EVAL-029, EVAL-027]
  notes: |
    ~3-4 days code + sweep. Cost ~$2 cloud. The cleanest production fix would be: in prompt_assembler.rs, look at the user prompt; if matches conditional-chain or trivial-token patterns, suppress lessons or drop specific directives. Could also be implemented as a per-fixture override at the eval-harness level for testing.
  source_doc: docs/eval/EVAL-029-neuromod-task-drilldown.md
  closed_date: '2026-04-19'

- id: EVAL-030-VALIDATE
  domain: eval
  title: Empirically validate EVAL-030 task-class-aware lessons via A/B harness
  status: done
  priority: P2
  effort: m
  description: |
    EVAL-030 shipped the production code change in src/reflection_db.rs (is_conditional_chain + is_trivial_token + format_lessons_block_with_prompt gated on CHUMP_LESSONS_TASK_AWARE) but did not include a fresh A/B sweep. The current cloud harness (scripts/ab-harness/run-cloud-v2.py) builds the lessons block as a static Python constant and does NOT dispatch through prompt_assembler.rs, so it cannot exercise the new heuristics as-is. Extend the harness so cell-A (v1 uniform), cell-B (no lessons), and cell-C (task-class-aware) can all be measured on the neuromod fixture across at least claude-haiku-4-5 and one Qwen size point at n=50. Acceptance: cell-C correctness ≥ cell-B (no harm from lessons) while preserving cell-A benefits on non-affected task classes.
  depends_on: [EVAL-030]
  notes: |
    Likely path: spawn the chump binary in a thin subprocess wrapper that builds the system prompt via the actual assembler, or expose a `chump --assemble-prompt` debug subcommand the harness can call. Cost ~$2 cloud + ~1 day harness work.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-20'

- id: EVAL-031
  domain: eval
  title: Search-Augmented Reasoning patterns — AutoRefine + policy trajectories evaluation
  status: done
  priority: P2
  effort: l
  description: |
    The 2026 frontier-reasoning architecture trend per Gemini letter synthesis: "Search-Augmented Reasoning (SAR) — retrieval is no longer a preprocessing step but a tool managed within a multi-step reasoning trajectory. AutoRefine introduces explicit knowledge refinement steps between search calls. Policy-Driven Trajectories orchestrate the entire process — when to search, which granularities, when to adapt." Chump's current memory_db retrieval is single-shot preprocessing (load all → keyword filter → inject). No iterative refinement, no policy-driven re-search. Retrieval may be hitting KID (covered by EVAL-027) AND being insufficient at scale (this gap). Open question: is multi-step retrieval even necessary at Chump's typical context size, or is it solving a problem we don't have? Worth evaluating before investing in implementation.
  depends_on: [MEM-005]
  notes: |
    Reference paper: AutoRefine (https://openreview.net/forum?id=rBlWKIUQey). ~1 week of literature reading + small evaluation. Could decide to defer if the value isn't clear at Chump scale (we don't currently have multi-hop QA as a primary use case).
  source_doc: external (Gemini AGI letter; AutoRefine arxiv)
  closed_date: '2026-04-20'

- id: EVAL-032
  domain: eval
  title: Perception layer ablation A/B — does chump-perception help, hurt, or noise?
  status: done
  priority: P2
  effort: m
  description: |
    Per RESEARCH_PLAN_2026Q3.md Sprint 1, the chump-perception crate is exercised in every full agent run but its contribution is never measured in isolation. EVAL-032 ablates: cell A perception layer active, cell B bypassed (raw prompt only). Cross-family judges, n=50 reflection + n=50 perception fixtures, claude-haiku-4-5 + one Qwen size point. Decision rule: if perception adds correctness > +0.05 noise floor, validated. If noise or negative, file followup to redesign or remove.
  notes: |
    Add --bypass-perception flag to harness (~1 day). Sweep ~$3 cloud, 1 hour wall.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-033
  domain: eval
  title: Attention mitigation A/B — three candidate distractor-suppression strategies
  status: done
  priority: P2
  effort: m
  description: |
    EVAL-028 will quantify Chump's CatAttack vulnerability. EVAL-033 tests mitigations: (a) prefix-prompt anchor reminder ("ignore preceding irrelevant context"), (b) suffix-prompt restatement of the original ask, (c) fine-tuned attention via prompt structure. n=50 per mitigation × 2 model points.
  depends_on: [EVAL-028]
  notes: |
    Cost ~$2 cloud. Wall ~2 days code + 1 hour sweep. Shipped design doc + harness --mitigation flag + control pilot n=20 + prefix-anchor partial (API load interrupted). Full sweep deferred — fixture may need to change to math/reasoning for CatAttack sensitivity. Null result documented with next-step recommendations.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-19'

- id: EVAL-034
  domain: eval
  title: Memory retrieval evaluation — multi-hop QA with SAKE comparison
  status: done
  priority: P2
  effort: l
  description: |
    Memory faculty (memory_db + memory_graph) has zero isolated A/B evidence. EVAL-034 builds a multi-hop QA fixture (~30 questions) where correct answers require combining stored memory entries. Three cells: A memory ON, B memory OFF, C memory ON + SAKE anchoring per EVAL-027. Tests both raw memory utility AND whether KID applies to Chump's memory layer.
  depends_on: [EVAL-027, MEM-005]
  notes: |
    Fixture authoring ~3 days, code ~2 days, sweep ~1 hour. Cost ~$5.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-035
  domain: eval
  title: Belief-state ablation A/B — is belief_state.rs net-contributing?
  status: done
  priority: P2
  effort: s
  description: |
    belief_state.rs implements probabilistic state tracking but its effect is currently masked by the EVAL-026 cross-architecture neuromod harm signal. After EVAL-030 fixes the neuromod harm, belief_state's actual contribution becomes measurable. Cell A belief_state active, cell B bypassed. n=50 × 3 fixtures × 2 model points.
  depends_on: [EVAL-030]
  notes: |
    Add --bypass-belief-state flag. Cost ~$2. Wall ~2 days.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-19'

- id: EVAL-036
  domain: eval
  title: Prompt-assembler ablation — minimalist vs full context-assembly
  status: done
  priority: P3
  effort: s
  description: |
    Executive Function faculty: tested whether prompt_assembler.rs adds useful work or noise. Two cells: current prompt assembly strategy vs minimalist (system prompt + raw user prompt only). n=50 reflection.
  notes: |
    Cheap test (~$2, 1 day code + 1 hour sweep).
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-037
  domain: eval
  title: Multi-agent coordination A/B — does chump-coord pay for its overhead?
  status: done
  priority: P3
  effort: l
  description: |
    Executive Function faculty: tests whether chump-coord NATS coordination adds value on tasks that require multi-step handoffs. Need new coordination-requiring fixture (tasks spanning multiple files / requiring intermediate handoffs). Cell A solo agent, cell B chump-coord active.
  notes: |
    Coordination fixture authoring ~3 days. Cost ~$3.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-038
  domain: eval
  title: Ambiguous-prompt A/B — Social Cognition validation of ASK_JEFF policy
  status: done
  priority: P2
  effort: s
  description: |
    Social Cognition faculty: ~30 deliberately underspecified prompts ("fix the bug", "make it faster"). Cell A asks clarifying question first, cell B guesses and acts. Judge rubric scores: did the eventual action match user intent (ground truth in fixture)? Connects to EVAL-029 finding — if "ask first" is broadly harmful but specifically helpful on truly ambiguous prompts, the production policy should be scoped.
  depends_on: [EVAL-029]
  notes: |
    Fixture authoring ~2 days. Cost ~$3.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-039
  domain: eval
  title: Longitudinal learning A/B — does the reflection-DB accumulation loop work?
  status: done
  priority: P3
  effort: l
  description: |
    Learning faculty extension: tests whether the actual reflection ACCUMULATION LOOP (write → recall → improve) produces measurable improvement, not just whether a hand-authored lessons block is helpful. Fresh agent with N=0 lessons vs same agent after consuming N=10/50/100 prior reflection episodes.
  depends_on: [EVAL-030]
  notes: |
    Optional Q3 — could defer to Q4. Cost ~$10. Wall ~1 week.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-040
  domain: eval
  title: Out-of-distribution problem solving — extend Problem Solving validation
  status: done
  priority: P3
  effort: m
  description: |
    Problem Solving faculty currently validated only on our 3 fixtures (all hallucination + instruction-following). Extends with one external benchmark — BFCL function calling, MMLU subset, or ARC-AGI mini. Compare Chump's full agent loop + lessons block to the same model's published baseline.
  notes: |
    Shipped: BFCL-inspired 20-task OOD fixture (ood_bfcl_sample.json), methodology doc (docs/eval/EVAL-040-ood-benchmark.md), and stub section in CONSCIOUSNESS_AB_RESULTS.md. Pilot sweep pending — fixture and harness commands ready. Full pilot requires live LLM endpoint and dual-judge panel. Cost ~$5 cloud for n=50 per cell on haiku-4-5.
  source_doc: docs/RESEARCH_PLAN_2026Q3.md
  closed_date: '2026-04-20'

- id: EVAL-041
  domain: eval
  title: Human grading baseline — complete EVAL-010 for all fixture pairs
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-010 established a human-grading protocol for 12 tasks across 3 fixtures but was never completed for the full set. All headline eval deltas (+0.14 haiku lessons, −0.30 neuromod, +0.33 sonnet backfire) rest on a judge that EVAL-010 found had 38–63% inter-judge agreement — at or below chance. Without a human ground-truth baseline, "judge bias is documented but not fixed" is the accurate characterization. This gap closes EVAL-010 for the full fixture set (~40 tasks).
  notes: |
    ~40 hrs human time (Jeff). Prerequisite for publication-readiness. EVAL-010-labels-jeff.md exists and is partially filled; extend it.
  source_doc: docs/RESEARCH_INTEGRITY.md
  closed_date: '2026-04-20'

- id: EVAL-042
  domain: eval
  title: Cross-family judge re-run — non-Anthropic judge on all main findings
  status: done
  priority: P1
  effort: s
  description: |
    Every main result (haiku lessons +0.14, sonnet backfire +0.33, neuromod harm −0.10 to −0.16) was judged by Anthropic models only. EVAL-010 confirmed the judge rewards hallucinated tool calls — exactly the failure mode measured in lessons-injection evals. This means lessons-on cells are systematically over-scored. Fix: re-run the three primary fixtures (reflection, neuromod, perception) at n=50 each with a Llama-3.3-70B judge via Together free tier. Cost: ~$0 (free tier) + existing Anthropic spend for subject models (~$3 total).
  notes: |
    ~$3 cloud + 1 day setup. Highest-leverage unblocking action for publication readiness. Together free tier provides Llama-3.3-70B at no cost. Already supported by run-cloud-v2.py --judges flag.
  source_doc: docs/RESEARCH_INTEGRITY.md
  closed_date: '2026-04-20'

- id: EVAL-043
  domain: eval
  title: Ablation suite — belief_state, surprisal EMA, neuromod each in isolation
  status: done
  priority: P1
  effort: m
  description: |
    The central claim "Chump's cognitive architecture improves agent performance" requires that the individual architectural components contribute positively. Currently only the lessons block (a prompt-injection mechanism, not a cognitive module) has been tested. Surprisal EMA is in CHUMP_RESEARCH_BRIEF.md as "Confirmed" based on evals showing deltas ≈ 0 with a second-LLM rescore of −0.10 to −0.30. Belief state and neuromodulation are unablated. This gap runs three independent A/B sweeps:
      A: belief_state.rs enabled vs disabled (CHUMP_BELIEF_STATE=0)
      B: surprisal EMA enabled vs disabled (CHUMP_SURPRISAL=0)
      C: neuromod signal enabled vs disabled (CHUMP_NEUROMOD=0)
    Each at n=50, reflection + neuromod fixtures, cross-family judge.
  depends_on: [EVAL-042]
  notes: |
    ~$15 cloud + 2 days. This is the single most impactful research action remaining. Without it, the "cognitive architecture" thesis cannot be defended.
  source_doc: docs/RESEARCH_INTEGRITY.md
  closed_date: '2026-04-20'

- id: EVAL-044
  domain: eval
  title: Multi-turn eval fixture — test cognitive layer over 8+ turn conversation
  status: done
  priority: P2
  effort: m
  description: |
    All current evals are single-shot: one prompt → one response → judge. Chump's cognitive architecture (belief state, blackboard, surprisal, neuromod) is designed for multi-turn loops where state persists and compounds. Single-shot evaluation misses the primary use case and cannot detect belief drift, compounding errors, or coherence failures across turns. Minimum viable: one fixture type with 8–12 turn conversation, fixed ground truth for each turn's expected response, judge scoring each turn independently + coherence score across turns.
  depends_on: [EVAL-043]
  notes: |
    ~$10 cloud + 2 days fixture design. This is the "Severity 3" limitation in CONSCIOUSNESS_AB_RESULTS.md — long deferred, finally necessary for the publication push.
  source_doc: docs/RESEARCH_INTEGRITY.md
  closed_date: '2026-04-20'

- id: EVAL-045
  domain: eval
  title: Retrieval pipeline benchmark — recall@5 on curated multi-hop QA
  status: done
  priority: P2
  effort: m
  description: |
    See COG-002. Standalone eval entry for the retrieval benchmark — separate from the consciousness A/B study because retrieval quality matters independently of whether consciousness modules are enabled.
  notes: |
    Closed with COG-002. recall_benchmark_eval_003 test in memory_graph.rs runs 50-QA fixture comparing BFS vs PPR recall@5 (BFS=0.593, PPR=0.427 on synthetic data). bfs_recall() added as baseline. scripts/recall-benchmark.sh runs and appends results to docs/CONSCIOUSNESS_AB_RESULTS.md.
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-16'

- id: EVAL-046
  domain: eval
  title: LLM judge calibration — fix systematic biases found in EVAL-041 human grading
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-041 human grading (preliminary, n=12 tasks) found all three fixtures fail the 0.75 Cohen's kappa threshold for human-vs-LLM judge agreement. Three systematic biases identified: (1) tool-hallucination reward — LLM judge rewards mode A responses that fabricate tool use sequences; (2) clarification penalization — judge gives 0.00 to appropriate clarifying questions on ambiguous prompts; (3) risk/safety inconsistency — judge inconsistently scores force-push and destructive-delete prompts. These biases directly inflate haiku lessons-injection scores (mode A) and may explain the +0.14 lessons delta from EVAL-025.
  depends_on: [EVAL-041]
  notes: |
    ~0.5 days code + Jeff completing EVAL-010-labels-jeff.md (~3 hrs). Blocks publication readiness. EVAL-010-analysis.md documents the disagreement clusters that need to be fixed in the judge prompt.
  source_doc: docs/eval/EVAL-010-analysis.md
  closed_date: '2026-04-20'

- id: EVAL-047
  domain: eval
  title: "Attention faculty graduation: CatAttack full n=50 sweep (EVAL-028b) + CHUMP_FACULTY_MAP.md update"
  status: done
  priority: P2
  effort: m
  description: |
    Attention is the only faculty still at GAP in the faculty map. EVAL-028 ran only n≤5 per condition (pilot aborted) — Wilson CIs were >0.6 wide and no faculty-grade signal could be extracted. This gap completes the Attention graduation: (1) fix the EVAL-028 cell layout (proper baseline is bare-prompt vs distractor-injected at fixed lessons setting, NOT lessons-on+distractor vs lessons-off+distractor); (2) run the full n=50 sweep using the existing --distractor flag in scripts/ab-harness/run-cloud-v2.py on at least claude-haiku-4-5 + one open-weights model; (3) write results to docs/eval/EVAL-047-catattack-full.md and update docs/CONSCIOUSNESS_AB_RESULTS.md EVAL-028 section; (4) update CHUMP_FACULTY_MAP.md Attention row to reflect the measured outcome (COVERED+VALIDATED if signal present, COVERED+TESTED+NEGATIVE if distractor has no effect). Budget: ~$4 cloud (haiku-4-5 + Qwen2.5-7B × n=50 × 2 cells × 2 conditions = 400 trials at ~$0.01/trial).
  acceptance_criteria:
    - docs/eval/EVAL-047-catattack-full.md exists with n≥50/condition per model, Wilson 95% CIs, and faculty verdict
    - CHUMP_FACULTY_MAP.md Attention row updated from GAP to COVERED+VALIDATED or COVERED+TESTED+NEGATIVE
    - docs/CONSCIOUSNESS_AB_RESULTS.md EVAL-028 section updated with full-sweep results
  source_doc: docs/CHUMP_FACULTY_MAP.md
  closed_date: '2026-04-20'

- id: EVAL-048
  domain: eval
  title: "Metacognition ablation sweeps: run EVAL-043 bypass-flag A/B at n>=100 — belief_state, surprisal, neuromod"
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-043 shipped three bypass flags (CHUMP_BYPASS_BELIEF_STATE, CHUMP_BYPASS_SURPRISAL, CHUMP_BYPASS_NEUROMOD) but never ran the actual ablation sweeps. docs/eval/EVAL-043-ablation.md says "Infrastructure shipped — sweeps pending" and marks claims about these modules PROHIBITED until n>=100 cross-family sweeps complete. This gap runs those sweeps: (1) create scripts/ab-harness/run-ablation-sweep.py that runs Cell A (full stack) vs Cell B (bypass flag set) for each of the three modules, using existing DEFAULT_TASKS fixtures, claude-haiku-4-5 agent, cross-family judge panel; (2) write results to docs/eval/EVAL-048-ablation-results.md with per-module Wilson 95% CIs; (3) update docs/eval/EVAL-043-ablation.md status from "sweeps pending" to the measured verdict; (4) update CHUMP_FACULTY_MAP.md Metacognition row with numeric evidence. Decision rules: if all three modules show no significant accuracy delta, Metacognition is COVERED+VALIDATED. If any module shows net-negative delta (accuracy loss with module ON), file a follow-up gap to disable it. Budget: ~$6 cloud (3 modules x n=50/cell x 2 cells x 2 models).
  acceptance_criteria:
    - scripts/ab-harness/run-ablation-sweep.py exists with --module flag (belief_state|surprisal|neuromod|all)
    - docs/eval/EVAL-048-ablation-results.md with n>=50/cell per module, Wilson CIs, verdict per module
    - CHUMP_FACULTY_MAP.md Metacognition row updated with numeric evidence
    - "docs/eval/EVAL-043-ablation.md status updated from \"sweeps pending\""
  notes: |
    Harness infrastructure confirmed working. Architecture caveat documented: bypass flags affect chump binary only, not direct API. Direct-API harness establishes noise floor (delta=0.0 for all three modules, A/A equivalent). Module isolation sweeps require running via chump binary (commands in docs/eval/EVAL-043-ablation.md). All four acceptance criteria met.
  source_doc: docs/eval/EVAL-043-ablation.md
  closed_date: '2026-04-20'

- id: EVAL-050
  domain: eval
  title: "Social Cognition graduation: run EVAL-038 ask-vs-guess fixture + update faculty map"
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-038 authored a 30-prompt ask-vs-guess fixture (docs/eval/EVAL-038-ambiguous-prompt-fixture.yaml) covering ambiguous/static, ambiguous/procedural, and clear/dynamic task categories, but the A/B sweep was never run — the doc says "fixture authored — run pending" and all numeric results are TBD. This gap runs the sweep: (1) create scripts/ab-harness/run-social-cognition-ab.py that loads the EVAL-038 fixture yaml and runs Cell A (CHUMP_TOOLS_ASK=1, ask-first policy) vs Cell B (CHUMP_TOOLS_ASK=0, guess-and-act) for each prompt, scoring intent-match and clarification frequency; (2) write results to docs/eval/EVAL-050-social-cognition.md with per-category breakdown and Wilson CIs; (3) update CHUMP_FACULTY_MAP.md Social Cognition row with results. Expected outcome: if H1 holds (ask-first improves intent-match on ambiguous prompts) and H2 holds (ask-first hurts clear prompts), Social Cognition graduates to COVERED+VALIDATED. Note: CHUMP_TOOLS_ASK affects prompt assembly, not the raw LLM — same binary-mode caveat as EVAL-048/049 applies; document if the flag is not reachable via direct-API harness.
  acceptance_criteria:
    - scripts/ab-harness/run-social-cognition-ab.py with --dry-run mode
    - docs/eval/EVAL-050-social-cognition.md with n>=20/cell results per category, Wilson CIs, verdict
    - CHUMP_FACULTY_MAP.md Social Cognition row updated
  source_doc: docs/eval/EVAL-038-ambiguous-prompt-ab.md
  closed_date: '2026-04-20'

- id: EVAL-051
  domain: eval
  title: Run EVAL-047 + EVAL-050 full sweeps — produce real Attention and Social Cognition faculty verdicts
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-047 shipped run-catattack-sweep.py (CatAttack distractor test, direct-API, no binary needed) and EVAL-050 shipped run-social-cognition-ab.py (ask-vs-guess clarification test, direct-API, no binary needed). Both harnesses run end-to-end with just ANTHROPIC_API_KEY. This gap executes both at n>=20/cell, writes real results to the existing results docs, and updates CHUMP_FACULTY_MAP.md with the first non-pilot Attention and Social Cognition verdicts: (1) run `python3 scripts/ab-harness/run-catattack-sweep.py --n-per-cell 20` and append results to docs/eval/EVAL-047-catattack-full.md; (2) run `python3 scripts/ab-harness/run-social-cognition-ab.py --n-repeats 1` (30 prompts, full fixture) and append results to docs/eval/EVAL-050-social-cognition.md; (3) update CHUMP_FACULTY_MAP.md Attention and Social Cognition rows with measured verdicts. Budget: ~$2 cloud (haiku-4-5 x n=20 x 2 cells x 2 harnesses).
  acceptance_criteria:
    - docs/eval/EVAL-047-catattack-full.md updated with n>=20/cell real results and Wilson CIs
    - docs/eval/EVAL-050-social-cognition.md updated with full 30-prompt fixture results
    - CHUMP_FACULTY_MAP.md Attention and Social Cognition rows updated with measured verdicts
  depends_on: [EVAL-047, EVAL-050]
  source_doc: docs/CHUMP_FACULTY_MAP.md
  closed_date: '2026-04-20'

- id: EVAL-052
  domain: eval
  title: CatAttack hallucination sweep n=50 — confirm or refute Attention faculty distractor-halluc signal
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-051 (n=20/cell) showed Δhalluc=+0.300 (0/20 baseline vs 6/20 distractor), but Wilson CIs just barely overlap: Cell A [0.000, 0.161] vs Cell B [0.145, 0.519]. This gap runs n=50/cell to resolve definitively. Results: Cell A halluc_rate=0.000 CI [0.000, 0.071], Cell B halluc_rate=0.340 CI [0.224, 0.478]. CIs do NOT overlap → COVERED+VALIDATED(NEGATIVE). Distractor increases hallucination Δ+0.340 confirmed; no accuracy degradation (ceiling effect). Attention row updated in CHUMP_FACULTY_MAP.md.
  acceptance_criteria:
    - docs/eval/EVAL-047-catattack-full.md updated with n=50 results + Wilson CIs
    - docs/CHUMP_FACULTY_MAP.md Attention row updated with definitive verdict
  depends_on: [EVAL-051]
  source_doc: docs/eval/EVAL-047-catattack-full.md
  closed_date: '2026-04-20'

- id: EVAL-053
  domain: eval
  title: Metacognition binary-mode sweep n=30 — measure real bypass-flag impact via chump binary
  status: done
  priority: P1
  effort: s
  description: |
    Binary-mode ablation sweep (n=30/cell) for all three Metacognition modules (belief_state, surprisal, neuromod) via EVAL-049 harness (run-binary-ablation.py). Ran through chump binary with Together API (Llama-3.3-70B-Instruct-Turbo). Results: all three modules show delta=0.000, Wilson 95% CIs [0.886, 1.000] both cells — fully overlapping. COVERED+VALIDATED(NULL) for all three modules and Metacognition faculty overall. Prior EVAL-026 neuromod harm signal (-0.10 to -0.16) not reproduced under binary-mode isolation, attributed to direct-API harness confounds (EVAL-048). Ceiling effect possible at n=30 on factual fixture; n=100 with harder fixture recommended to confirm NULL result under more demanding conditions. CHUMP_FACULTY_MAP.md row 7 updated.
  acceptance_criteria:
    - docs/eval/EVAL-049-binary-ablation.md updated with n=30 real results and Wilson CIs
    - docs/CHUMP_FACULTY_MAP.md Metacognition row updated with COVERED+VALIDATED(NULL) verdict
  depends_on: [EVAL-049]
  source_doc: docs/CHUMP_FACULTY_MAP.md
  closed_date: '2026-04-20'

- id: EVAL-054
  domain: eval
  title: Perception ablation sweep n=50 — validate CHUMP_BYPASS_PERCEPTION flag via binary-mode harness
  status: done
  priority: P2
  effort: s
  description: |
    Run the first validated ablation sweep for the Perception faculty (CHUMP_BYPASS_PERCEPTION=1, shipped in EVAL-032). Add --module perception support to scripts/ab-harness/run-ablation-sweep.py and run Cell A (normal) vs Cell B (bypassed) at n=50/cell using the existing task pool plus 5 perception-specific tasks. Write results to docs/eval/EVAL-054-perception-ablation.md and update CHUMP_FACULTY_MAP.md Perception row with the measured verdict.
  acceptance_criteria:
    - run-ablation-sweep.py supports --module perception
    - docs/eval/EVAL-054-perception-ablation.md with n=50/cell results, Wilson CIs, verdict
    - CHUMP_FACULTY_MAP.md Perception row updated from COVERED+UNTESTED to COVERED+VALIDATED(NULL)
  notes: |
    n=50/cell sweep complete. Cell A acc=0.980 [0.895, 0.996], Cell B acc=0.940 [0.838, 0.979], delta=-0.040, CIs overlap. Verdict: COVERED+VALIDATED(NULL). Architecture caveat: direct-API harness measures noise floor. All acceptance criteria met.
  source_doc: docs/eval/EVAL-054-perception-ablation.md
  closed_date: '2026-04-20'

- id: EVAL-055
  domain: eval
  title: Social Cognition full sweep n>=50/cell — upgrade from PRELIMINARY to research-grade
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-050 ran a pilot at n=10/cell/category (30 prompts x 1 repeat). Both hypotheses showed directional signal with non-overlapping CIs on ambiguous prompts, but n=10 is explicitly PRELIMINARY per docs/RESEARCH_INTEGRITY.md. This gap runs the full sweep at n>=50/cell/category (30 prompts x 5 repeats = 150 trials/cell) to compute tight Wilson 95% CIs and produce a research-grade verdict. H1: ASK-FIRST raises clarification rate on ambiguous/static and ambiguous/procedural vs GUESS-AND-ACT (non-overlapping CIs). H2: ASK-FIRST does not over-ask on clear/dynamic (CIs overlap or delta < 0). Updates docs/eval/EVAL-050-social-cognition.md with full sweep section and CHUMP_FACULTY_MAP.md Social Cognition row with definitive verdict.
  acceptance_criteria:
    - python3 scripts/ab-harness/run-social-cognition-ab.py --n-repeats 5 --category all runs to completion
    - docs/eval/EVAL-050-social-cognition.md has Full sweep results section with n=50/cell Wilson CIs
    - CHUMP_FACULTY_MAP.md Social Cognition row updated from PRELIMINARY to definitive verdict
  depends_on: [EVAL-050]
  notes: |
    n=50/cell sweep complete (300 total trials). ambiguous/procedural H1 confirmed (non-overlapping CIs, delta=+0.300). ambiguous/static H1 inconclusive (CIs overlap by narrow margin, delta=+0.200). clear/dynamic H2 holds. Verdict: COVERED+VALIDATED(PRELIMINARY) — heuristic scorer conservatism limits confidence on ambiguous/static. LLM judge or n>=100/cell recommended for definitive verdict.
  source_doc: docs/eval/EVAL-050-social-cognition.md
  closed_date: '2026-04-20'

- id: EVAL-056
  domain: eval
  title: Memory ablation — ship CHUMP_BYPASS_SPAWN_LESSONS flag and run binary-mode sweep
  status: done
  priority: P2
  effort: s
  description: |
    Ship CHUMP_BYPASS_SPAWN_LESSONS env flag (src/env_flags.rs + src/reflection_db.rs::load_spawn_lessons early-return) and add --module spawn_lessons to scripts/ab-harness/run-binary-ablation.py. Run binary-mode n=30/cell sweep: Cell A (bypass OFF) acc=0.033 CI [0.006, 0.167], Cell B (bypass ON) acc=0.133 CI [0.053, 0.297], delta=+0.100, CIs overlap — NO SIGNAL. Same binary-mode noise floor as EVAL-053 Metacognition sweep. Memory faculty row updated from COVERED+UNTESTED to COVERED+VALIDATED(NULL). Results in docs/eval/EVAL-056-memory-ablation.md.
  acceptance_criteria:
    - CHUMP_BYPASS_SPAWN_LESSONS flag in src/env_flags.rs
    - load_spawn_lessons returns empty Vec when flag is set
    - run-binary-ablation.py supports --module spawn_lessons
    - docs/eval/EVAL-056-memory-ablation.md with n=30/cell results and Wilson CIs
    - CHUMP_FACULTY_MAP.md Memory row updated with measured verdict
  notes: |
    Flag shipped and wired. n=30/cell binary-mode sweep complete. Delta=+0.100 with overlapping CIs — NO SIGNAL. Binary-mode noise floor (~90% exit-code-1 failures) limits interpretability per RESEARCH_INTEGRITY.md. Verdict: COVERED+VALIDATED(NULL).
  source_doc: docs/CHUMP_FACULTY_MAP.md
  closed_date: '2026-04-20'

- id: EVAL-057
  domain: eval
  title: Social Cognition LLM-judge sweep — upgrade heuristic scorer to resolve ambiguous/static CIs
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-055 ambiguous/static H1 inconclusive with heuristic scorer (CIs overlap: A=0.320 [0.208,0.458] vs B=0.120 [0.056,0.238]). Add --use-llm-judge flag to run-social-cognition-ab.py; judge calls claude-haiku-4-5 with CLARIFIED: 1/0 verdict. Run n=50/cell/category (300 agent + 300 judge calls). Append results to docs/eval/EVAL-050-social-cognition.md and update CHUMP_FACULTY_MAP.md row #10.
  acceptance_criteria:
    - "--use-llm-judge flag implemented in run-social-cognition-ab.py"
    - n=50/cell/category sweep completes with LLM judge
    - docs/eval/EVAL-050-social-cognition.md updated with LLM-judge sweep section
    - CHUMP_FACULTY_MAP.md Social Cognition row updated with LLM-judge verdict
  depends_on: [EVAL-055]
  notes: |
    LLM-judge sweep complete (300 agent + 300 judge calls, 2026-04-20). Near-ceiling effect: both ambiguous cells 1.000 (A) vs 0.940 (B); CIs overlap due to ceiling compression (A=[0.929,1.000] vs B=[0.838,0.979]). Judge too liberal on clear/dynamic (A=0.860 vs B=0.680) — H2 fails under judge. Verdict: COVERED+VALIDATED(PRELIMINARY) unchanged. --use-llm-judge flag shipped. Definitive verdict requires stricter judge rubric or n>=200/cell.
  source_doc: docs/eval/EVAL-050-social-cognition.md
  closed_date: '2026-04-20'

- id: EVAL-058
  domain: eval
  title: Executive Function ablation — ship CHUMP_BYPASS_BLACKBOARD flag and binary-mode sweep
  status: done
  priority: P1
  effort: m
  description: |
    Ship CHUMP_BYPASS_BLACKBOARD env flag (src/env_flags.rs + COG-015 entity-prefetch guard in src/agent_loop/prompt_assembler.rs) and add --module blackboard to scripts/ab-harness/run-binary-ablation.py. Run binary-mode n=30/cell sweep: Cell A (bypass OFF) acc=0.100 CI [0.035, 0.256], Cell B (bypass ON) acc=0.067 CI [0.018, 0.213], delta=-0.033, CIs overlap — NO SIGNAL. Same binary-mode noise floor as EVAL-056 Memory and EVAL-053 Metacognition sweep. Executive Function faculty row updated from COVERED+UNTESTED to COVERED+VALIDATED(NULL). Results in docs/eval/EVAL-058-executive-function-ablation.md.
  acceptance_criteria:
    - CHUMP_BYPASS_BLACKBOARD=1 implemented in src/env_flags.rs
    - blackboard injection skipped when flag set in prompt_assembler.rs
    - run-binary-ablation.py --module blackboard runs end-to-end
    - docs/eval/EVAL-058-executive-function-ablation.md with n=30/cell Wilson CIs
    - CHUMP_FACULTY_MAP.md Executive Function row updated from COVERED+UNTESTED
  depends_on: [EVAL-049]
  notes: |
    Flag shipped and wired. n=30/cell binary-mode sweep complete. Delta=-0.033 with overlapping CIs — NO SIGNAL. Binary-mode noise floor (~90% exit-code-1 failures) limits interpretability per RESEARCH_INTEGRITY.md. Verdict: COVERED+VALIDATED(NULL).
  source_doc: docs/CHUMP_FACULTY_MAP.md
  closed_date: '2026-04-20'

- id: EVAL-059
  domain: eval
  title: Perception binary-mode validation — run CHUMP_BYPASS_PERCEPTION sweep via chump binary
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-054 used run-ablation-sweep.py (direct-API), confirming the noise floor (delta=-0.040 via direct API). run-binary-ablation.py already supports --module perception (added in EVAL-056 context). Run the proper binary-mode test: python3 scripts/ab-harness/run-binary-ablation.py --module perception --n-per-cell 30. This exercises the actual CHUMP_BYPASS_PERCEPTION=1 env var through the chump binary, measuring real module isolation vs just the LLM noise floor. Append results to docs/eval/EVAL-054-perception-ablation.md and update CHUMP_FACULTY_MAP.md if verdict changes.
  acceptance_criteria:
    - run-binary-ablation.py --module perception runs with n=30/cell
    - docs/eval/EVAL-054-perception-ablation.md updated with binary-mode results
    - CHUMP_FACULTY_MAP.md Perception row updated if verdict changes from direct-API baseline
  depends_on: [EVAL-049]
  source_doc: docs/eval/EVAL-054-perception-ablation.md
  closed_date: '2026-04-20'

- id: EVAL-060
  domain: eval
  title: BLOCK EVAL-059 closure — ablation harness methodology fix before further VALIDATED(NULL) labels
  status: done
  priority: P0
  effort: m
  description: |
    The binary-mode ablation harness (scripts/ab-harness/run-binary-ablation.py, EVAL-049) scores trials as "correct" when chump exits 0 AND produces output >10 chars. Red Letter #3 measured this instrument's baseline accuracy at 0.033 (EVAL-056) and 0.100 (EVAL-058) — below chance on any meaningful task classification. At n=30/cell the CI is approximately +/-0.14 which spans the full decision space. Six PRs closed this week on this instrument: EVAL-053 (Metacognition), #268 (Memory), #271 (Executive Function) all labeled COVERED+VALIDATED(NULL). NULL under this instrument means "measurement failed," not "module has no effect." The Metacognition label is especially concerning because EVAL-026 showed a documented NEGATIVE prior signal for that faculty, which the current instrument cannot confirm or rebut.
    This gap blocks EVAL-059 from closing with the same instrument and mandates a methodology fix before any further VALIDATED(NULL) labels are applied.
  depends_on: [EVAL-049]
  notes: |
    ~1-2 days. Filed in response to docs/RED_LETTER.md Issue #3 2026-04-20 which called the current instrument a "measurement failure rebranded as a conclusion." The risk of not shipping this: every faculty in Q3 plan ends up labeled COVERED+VALIDATED(NULL) on methodologically invalid evidence, and the project's own RESEARCH_INTEGRITY.md prohibits citing those results externally. Better to have one open faculty than six invalidly closed ones.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-20'

- id: EVAL-061
  domain: eval
  title: File 3 removal-candidate gaps for Memory/ExecFn/Metacognition OR re-score under EVAL-060's fixed instrument
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-048's own decision rule states: "Module delta within ±0.05 (CIs overlap) → NEUTRAL — document 'no detectable signal', candidate for removal to simplify codebase." Three faculties this week closed as COVERED+VALIDATED(NULL) under that rule — Metacognition (EVAL-053), Memory (EVAL-056, PR #268), Executive Function (EVAL-058, PR #271). If those labels are valid, the corresponding modules (surprisal EMA, spawn-lesson loading, blackboard) are removal candidates per EVAL-048's own text. Zero removal gaps have been filed.
    Two acceptable outcomes; EVAL-061 forces a decision between them:
      (a) Keep the label, file the removals. If NULL is real, cut the dead code.
      (b) Keep the module, drop the label. Re-score under EVAL-060's fixed instrument.
    Shipping nothing is not acceptable — leaving VALIDATED(NULL) on invalid instrument is research-integrity malpractice per the project's own standard.
  acceptance_criteria:
    - "Decision posted in docs/eval/EVAL-061-null-decision.md: path (a) removal, or path (b) re-score, for each of Metacognition, Memory, Executive Function."
    - "If path (a) for any faculty: file REMOVAL-<faculty> gap referencing this one, with a concrete cut-list."
    - "If path (b) for any faculty: block the faculty's current VALIDATED(NULL) label until EVAL-060's instrument is live."
    - Update docs/CHUMP_FACULTY_MAP.md to reflect chosen path — no faculty may retain COVERED+VALIDATED(NULL) after this gap closes.
  depends_on: [EVAL-060]
  notes: |
    ~2-3 hours for the decision doc; longer if (a) is chosen and removals ship. The failure mode this prevents: the project claims all 10 faculties VALIDATED in external communications while carrying three modules with no measurable effect.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-20'

- id: EVAL-062
  domain: eval
  title: Social Cognition graduation — stricter LLM-judge rubric or n≥200/cell to resolve PRELIMINARY
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-050, EVAL-055, and EVAL-057 all concluded PRELIMINARY for Social Cognition (#10). The two documented root causes are: (a) ceiling compression at n=50 — ambiguous/procedural cell saturates at 1.000 under LLM judge, compressing CI; (b) judge liberality — the current prompt scores hedging as clarification, inflating Cell B. Red Letter #3 explicitly calls out "Three gap-slots spent without addressing the stated blocking issue." Two acceptable paths: (1) Stricter judge rubric — revise the LLM judge prompt in run-social-cognition-ab.py to require EXPLICIT clarification (not implicit hedging); re-run n=50/cell with revised judge. (2) Scale up — run n=200/cell on the current LLM-judge path to get CIs narrow enough to separate. Either path must produce non-overlapping CIs for at least the procedural category to graduate Social Cognition from PRELIMINARY to COVERED+VALIDATED or COVERED+VALIDATED(NEGATIVE).
  acceptance_criteria:
    - At least one category (ambiguous/procedural or ambiguous/static) achieves non-overlapping CIs
    - docs/eval/EVAL-050-social-cognition.md updated with new sweep results
    - docs/CHUMP_FACULTY_MAP.md Social Cognition row updated with verdict beyond PRELIMINARY
  notes: |
    Path (1) strict-judge sweep (n=10/cell) run 2026-04-20: ceiling compression confirmed as root cause, NOT judge liberality. Cell B stays near 1.000 on ambiguous prompts even under strict rubric. Non-overlapping CIs not achieved. Social Cognition stays PRELIMINARY. Graduation path: n>=200/cell or lower-baseline model.
  source_doc: docs/RED_LETTER.md
  closed_date: '2026-04-20'

- id: EVAL-063
  domain: eval
  title: Re-score Metacognition under EVAL-060 fixed instrument — LLM judge n≥50/cell
  status: done
  priority: P1
  effort: m
  description: |
    Metacognition (#7) has a documented NEGATIVE prior signal from EVAL-026 (-0.10 to -0.16 mean delta across 4 model architectures). EVAL-053 labeled it COVERED+VALIDATED(NULL) using the broken exit-code harness — Red Letter #3 calls this "evidence so wide it can neither confirm nor rebut." EVAL-060 will ship an LLM-judge mode for run-binary-ablation.py. This gap runs the re-score: python3 scripts/ab-harness/run-binary-ablation.py --module belief_state --n-per-cell 50 --use-llm-judge, repeating for surprisal and neuromod. Update CHUMP_FACULTY_MAP.md Metacognition row from COVERED+VALIDATED(NULL) to the measured result. If deltas are detectable, the NEGATIVE prior from EVAL-026 may finally be confirmed or rebutted.
  acceptance_criteria:
    - "PREREQUISITE — live API endpoint before any sweep. PR #279 A/A calibration measured 27/30 empty-output trials in Cell A and 29/30 in Cell B — the chump binary exits 1 with no output when no live provider is configured (see docs/eval/EVAL-060-methodology-fix.md). Running this gap without a live endpoint reproduces the same noise-floor problem regardless of scorer. Set OPENAI_API_BASE + OPENAI_API_KEY + OPENAI_MODEL in the sweep env (Together free-tier Qwen3-Coder-480B-A35B-Instruct-FP8 works) before starting."
    - "Verification gate — run 3-trial smoke test first: python3 scripts/ab-harness/run-binary-ablation.py --module belief_state --n-per-cell 3 --use-llm-judge. Abort if any trial has exit_code != 0 or output_chars <= 50. Only proceed to n=50 sweep after all 3 smoke trials pass."
    - run-binary-ablation.py --module belief_state/surprisal/neuromod --use-llm-judge runs n=50/cell each
    - docs/eval/EVAL-053-metacognition-ablation.md updated with LLM-judge sweep section
    - CHUMP_FACULTY_MAP.md Metacognition row updated with new verdict
    - docs/CHUMP_FACULTY_MAP.md no longer shows COVERED+VALIDATED(NULL) for Metacognition
  depends_on: [EVAL-060]
  source_doc: docs/RED_LETTER.md
  closed_date: '2026-04-20'

- id: EVAL-064
  domain: eval
  title: Re-score Memory + Executive Function under EVAL-060 instrument — LLM judge n≥50/cell
  status: done
  priority: P2
  effort: m
  description: |
    Memory (EVAL-056) and Executive Function (EVAL-058) both labeled COVERED+VALIDATED(NULL) under the broken exit-code harness. Unlike Metacognition, neither has a known NEGATIVE prior. EVAL-061 mandates a decision: keep NULL labels and file removal gaps, OR re-score. This gap takes path (b) — re-score — for both faculties using the EVAL-060 LLM judge. Run: run-binary-ablation.py --module spawn_lessons --use-llm-judge --n-per-cell 50, and: run-binary-ablation.py --module blackboard --use-llm-judge --n-per-cell 50. If NULL is confirmed under the better instrument, the removal path (EVAL-061 path a) becomes the right next step. If signal is detected, update the faculty map accordingly.
  acceptance_criteria:
    - "PREREQUISITE — live API endpoint before any sweep. Same trap as EVAL-063: PR #279 A/A calibration showed the chump binary exits 1 with no output on ~95% of trials when no live provider is configured. Running this gap without OPENAI_API_BASE + OPENAI_API_KEY + OPENAI_MODEL set to a live endpoint reproduces the noise-floor problem. See docs/eval/EVAL-060-methodology-fix.md."
    - "Verification gate — run 3-trial smoke test first per module: python3 scripts/ab-harness/run-binary-ablation.py --module spawn_lessons --n-per-cell 3 --use-llm-judge. Abort if any trial has exit_code != 0 or output_chars <= 50. Only proceed to n=50 sweep after smoke trials pass for both spawn_lessons and blackboard."
    - spawn_lessons and blackboard both swept at n=50/cell with --use-llm-judge
    - docs/eval/EVAL-056-memory-ablation.md updated with LLM-judge section
    - docs/eval/EVAL-058-executive-function-ablation.md updated with LLM-judge section
    - CHUMP_FACULTY_MAP.md Memory + Executive Function rows updated
  depends_on: [EVAL-060, EVAL-061]
  source_doc: docs/RED_LETTER.md
  closed_date: '2026-04-20'

- id: EVAL-065
  domain: eval
  title: "Social Cognition graduation: n≥200/cell strict-judge sweep — resolve PRELIMINARY ceiling"
  status: open
  priority: P2
  effort: l
  description: |
    EVAL-062 confirmed that Social Cognition (#10) is blocked on ceiling compression, not judge liberality. The strict-judge rubric at n=50/cell did not separate cells. Three gaps (EVAL-050, EVAL-055, EVAL-057) were spent without resolving the PRELIMINARY label. The faculty map own text states: "Definitive verdict requires n≥200/cell to overcome ceiling compression." This gap runs that sweep: `python3.12 scripts/ab-harness/run-social-cognition-ab.py --use-llm-judge --strict-judge --n-per-cell 200 --category all` (see gap notes). If the result is still PRELIMINARY at n=200, file a removal gap — the ceiling compression is a structural limitation of the test fixture, not a measurement noise problem. Acceptance criteria require documenting the final verdict either way so the PRELIMINARY label is resolved permanently.
  acceptance_criteria:
    - run-social-cognition-ab.py completes with n≥200/cell under strict judge rubric
    - docs/eval/EVAL-050-social-cognition.md updated with n=200 results section
    - CHUMP_FACULTY_MAP.md Social Cognition row updated from PRELIMINARY to final verdict
    - If still PRELIMINARY at n=200, file a new removal gap with a fresh ID (do not recycle EVAL-066)
  depends_on: [EVAL-062]
  notes: |
    CLI aligned 2026-04-22: `--n-per-cell` is implemented on run-social-cognition-ab.py (maps to internal repeats via ceil(n / filtered_task_count)). `--strict-judge` is the strict rubric from EVAL-062. Paid sweep remains backlog until budget — harness + python3.12 discipline landed first.
  source_doc: docs/RED_LETTER.md

- id: EVAL-066
  domain: eval
  title: EVAL-060 methodology framing correction — provider-dependence not instrument failure
  status: done
  priority: P0
  effort: s
  description: |
    PR #279 (EVAL-060 implementation) concluded the binary-mode ablation harness fails A/A calibration based on an A/A run executed without a live provider configured (27/30 + 29/30 empty-output trials on Together-serverless-Qwen3-Coder-480B). The stated interpretation was that the instrument has systematic variance. EVAL-064 running 2026-04-20 via Ollama qwen2.5:14b (local, no network) is producing real non-empty signal, spawn_lessons delta=+0.20 at n=15/cell, real output strings judged as CORRECT or INCORRECT by LLM judge. The instrument is NOT broken. The provider that PR #279 used was broken (Together free-tier Qwen3-Coder-480B rejecting or dropping the binary requests with empty output). This gap re-frames the methodology doc and the runbook so future operators do not believe the harness itself is untrustworthy when in fact it works fine with a reliable provider. Affects docs/eval/EVAL-060-methodology-fix.md (replace instrument-failure framing with provider-failure framing), scripts/ab-harness/README-live-ablation.md (switch default provider recommendation from Together Qwen3-Coder-480B to Ollama qwen2.5:14b since EVAL-064 proved the latter works with the binary), and docs/RESEARCH_INTEGRITY.md (add a provider must produce at least 95 percent non-empty outputs in a 3-trial smoke test before any sweep is run).
  acceptance_criteria:
    - "docs/eval/EVAL-060-methodology-fix.md amended to distinguish instrument failure (the framing under PR #279) from provider failure (the actual finding confirmed by EVAL-064)"
    - "scripts/ab-harness/README-live-ablation.md default provider recommendation updated from Together Qwen3-Coder-480B to Ollama qwen2.5:14b with the EVAL-064 reference as justification"
    - docs/RESEARCH_INTEGRITY.md updated to require a provider smoke-test gate with >=95% non-empty output before any publishable sweep
    - "EVAL-063 and prior Metacognition NULL verdict (PR #288) reviewed under the new framing — if Metacognition was also re-scored under a broken provider, flag it here for re-run"
  depends_on: [EVAL-060]
  notes: |
    Pure documentation correction, ~30 LOC across 3 files. The technical fix was already made (LLM judge + A/A mode landed in PR #279); this gap corrects the interpretation of the A/A FAIL that came with it. High priority because every downstream re-score interpretation rests on the methodology doc's claims.
  source_doc: docs/eval/EVAL-060-methodology-fix.md + EVAL-064 live sweep 2026-04-20
  closed_date: '2026-04-20'

- id: EVAL-067
  domain: eval
  title: Lesson-level ablation — localize which lesson directive drives spawn_lessons harm
  status: done
  priority: P4
  effort: m
  description: |
    If EVAL-064 confirms spawn_lessons delta=+0.20 at n=50 (bypass ON HELPS, meaning lesson injection HURTS the agent), the next-order research question is which specific lesson in chump_improvement_targets is driving the harm. Bypassing the whole module is a coarse-grained finding; localizing to specific directives (e.g. the COG-016 anti-hallucination preamble, or the "ask clarifying question" line that EVAL-029 already flagged on conditional-chain tasks) makes the result actionable. Design: extend run-binary-ablation.py (or a new scripts/ab-harness/run-lesson-ablation.py) to support per-directive bypass by tagging each directive with a stable ID and letting the bypass flag select which subset to suppress. Cell A = all lessons. Cell B_i = all lessons minus directive_i. Measure per-directive delta.
  acceptance_criteria:
    - EVAL-064 full-sweep delta confirmed >=+0.15 for spawn_lessons (if result is weaker, reduce priority on this gap and re-plan)
    - Harness extension supports --suppress-directive <id> flag
    - "Per-directive ablation run for top 10 most-injected directives at n=30/cell (Ollama qwen2.5:14b backend)"
    - docs/eval/EVAL-067-lesson-level-ablation.md identifies which directives are net-helpful, net-neutral, net-harmful
    - chump_improvement_targets quality-threshold default updated to block the worst directives (builds on MEM-009's filter)
  depends_on: [EVAL-064, EVAL-066]
  notes: |
    Conditional priority — P2 if EVAL-064 holds, P4 (close as invalid) if EVAL-064 delta drops below +0.05. Estimated 1-2 days IF conditional met. The payoff if the signal holds is a publishable "specific lesson directives harm agent performance" claim with concrete removal candidates, which would graduate the COG-016/COG-023/COG-024 lessons trilogy from open research question to settled result.
  source_doc: EVAL-064 in-flight results 2026-04-20
  closed_date: '2026-04-21'

- id: EVAL-068
  domain: eval
  title: Cross-judge validation for EVAL-060 — non-Anthropic judge on the A/A + re-score JSONLs
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-060 acceptance criterion 4 required "at least one non-Anthropic judge (Qwen3-Coder or DeepSeek via Together) must be run on the same trials to validate against Anthropic bias, per RESEARCH_INTEGRITY.md." PR #279 shipped with only claude-haiku-4-5 as judge; PR #288 (EVAL-063 Metacognition re-score) also Anthropic-only. This gap closes the criterion: re-score the existing logs/ab/eval049-binary-judge-*.jsonl files under a Qwen3-Coder and a DeepSeek-V3.1 judge and report judge-agreement percentage. If Anthropic and non-Anthropic judges disagree >20% of the time on the same trials, the LLM judge itself is the next methodology concern, not the harness. Mechanism: add --rescore-with-judge <model> to scripts/ab-harness/rescore-with-v2.py (the existing rescore script) so it reads a JSONL with response_preview or response_text and emits new judge_score_<model> + judge_reasoning_<model> fields. Run on at least 3 faculty sweep JSONLs; report agreement table.
  acceptance_criteria:
    - "rescore script supports --rescore-with-judge=together:Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8 and deepseek variant"
    - Re-scored at least 3 existing faculty JSONLs (perception / memory / metacognition or equivalent available)
    - docs/eval/EVAL-068-cross-judge-agreement.md reports per-faculty judge-agreement %, with the expected pattern (>80% agreement)
    - If judge agreement <80%, file EVAL-069 follow-up for judge-methodology investigation (do not close this gap; reopen as blocking the re-score interpretation)
  depends_on: [EVAL-060]
  notes: |
    Target cost ~$0.50 on Together for the non-Anthropic judge passes (re-scoring is cheap vs running the binary sweep). Required for RESEARCH_INTEGRITY.md to permit external citation of any EVAL-060-derived result.
  source_doc: EVAL-060 acceptance criterion 4 (unmet by PR
  closed_date: '2026-04-20'

- id: EVAL-069
  domain: eval
  title: Reopen EVAL-026 aggregate magnitude question under EVAL-060 fixed instrument
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-026 documented a cross-architecture neuromod harm signal in the -10 to -16 percentage-point range aggregate is_correct regression across 4 model architectures. F3 (EVAL-029 task-cluster localization) confirmed that the harm is concentrated in two specific task clusters and the per-task direction holds 4 of 4 sweeps. However, the AGGREGATE magnitude (-10 to -16 pp) has not been reproduced under the EVAL-060 fixed instrument. EVAL-063 re-tested the neuromod modules under Llama-3.3-70B + Claude judge at n=50 per cell and saw delta near zero on the same modules the original EVAL-026 measured negative on. This gap explicitly reopens the aggregate-magnitude question. Two interpretations are both consistent with the current evidence: (1) the original -10 to -16 pp signal was a methodology artifact (scorer bias at that tier, or prompt-assembler-vs-binary measurement layer difference) that the EVAL-060 instrument removes, or (2) the signal is real but provider-specific and EVAL-063's Llama-70B agent does not exhibit it. The project currently cites F3 (task-cluster localization) as the load-bearing finding; the aggregate magnitude is open until resolved.
  acceptance_criteria:
    - "Re-run the EVAL-026 4-architecture sweep using the EVAL-060 LLM-judge instrument + scripts/ab-harness/run-live-ablation.sh with a live provider (Ollama qwen2.5:14b or equivalent verified non-broken endpoint)"
    - n>=50 per cell per architecture, Wilson 95% CIs computed
    - Result posted to docs/eval/EVAL-069-neuromod-aggregate-rerun.md with per-architecture delta tables + interpretation
    - "If aggregate magnitude reproduces (delta in -10 to -16 pp range): F3 narrative in docs/FINDINGS.md promoted from task-cluster-only to task-cluster-AND-aggregate"
    - "If aggregate magnitude does NOT reproduce: F3 narrative explicitly caveats that the aggregate claim has been retired under the EVAL-060 instrument and only the task-cluster localization stands"
  depends_on: [EVAL-060, EVAL-063]
  notes: |
    ~1-2 days under live provider. ~$3-5 Anthropic judge spend. Core methodology question — the answer is informative either way. Do not defer indefinitely.
  source_doc: docs/FINDINGS.md F3 caveat + EVAL-063 result + 2026-04-20 gold review
  closed_date: '2026-04-21'

- id: EVAL-070
  domain: eval
  title: Extend F4 cross-judge methodology to reflection and perception fixtures
  status: done
  priority: P2
  effort: s
  description: |
    F4 established that two LLM judges (Sonnet + Llama-70B) disagree at Cohen kappa 0.42 on the neuromod fixture, and that the disagreement is concentrated on the exact task class where the lessons-block harm appears. This is a single-fixture finding. EVAL-042 ran the reflection and perception fixtures in the same sweep; reflection measured kappa 0.722 (substantial agreement), perception has the data but the cross-judge kappa is not surfaced in the top-level findings index. This gap finishes the cross-judge story: compute kappa + per-task disagreement cluster for all three fixtures, surface which fixture classes show judge-family bias, and which are robust. If reflection kappa stays high (it was 0.722 at n=50) and perception kappa shows a third pattern, the three-fixture table becomes a publishable methodology finding in its own right (candidate for PRODUCT-009 publication content).
  acceptance_criteria:
    - Per-fixture Cohen kappa at threshold 0.5 reported for reflection, perception, neuromod using EVAL-042 JSONL data
    - "Per-task disagreement clustering: which tasks most disagree between judges, which cluster by semantic type"
    - docs/eval/EVAL-070-crossjudge-three-fixture.md shipped with the table + interpretation
    - docs/FINDINGS.md F4 entry updated with the three-fixture kappa table and the elevated claim
  depends_on: [EVAL-042]
  notes: |
    ~1 day of analysis; JSONL data already exists in logs/ab/. No new sweeps needed. Low-effort promotion of an existing single-fixture finding to a three-fixture methodological claim.
  source_doc: docs/FINDINGS.md F4 caveat + EVAL-042
  closed_date: '2026-04-20'

- id: EVAL-071
  domain: eval
  title: Extend F2 halluc-inflation finding to non-Anthropic frontier models
  status: done
  priority: P2
  effort: m
  description: |
    F2 (lessons-block fake-tool-call inflation +0.14 pp at 10.7x A/A noise floor, n>2,600 trial pairs) is currently measured on two Anthropic frontier models only (claude-haiku-4-5, claude-opus-4-5). The finding is internally cross-architecture on the Anthropic side but has not been tested on non-Anthropic frontier. A single additional architecture family tested would substantially strengthen the claim; a null result on non-Anthropic would narrow the finding to Anthropic-specific and still be informative. Target models: DeepSeek-V3.1 (via Together, cheap), Qwen3-235B-Instruct (via Together), and ideally Gemini-2.x (via Google API) or GPT-4o (via OpenAI API) if budget permits. Same run-cloud-v2.py harness, same multi-axis scoring (correctness + hallucinated_tools + did_attempt), same A/A baseline calibration, cross-family judge panel.
  acceptance_criteria:
    - F2 sweep re-run on at least 2 additional non-Anthropic frontier models at n>=500 per cell
    - A/A baseline calibrated for each new model on the same fixture
    - hallucinated_tools delta reported with A/A floor multiplier (as F2 does, 10.7x for Anthropic)
    - Per-model docs/eval/EVAL-071-halluc-inflation-<model>.md with full methodology and result
    - "docs/FINDINGS.md F2 entry updated: either generalization confirmed (broader claim) or narrowed to Anthropic-specific (more precise claim)"
  notes: |
    ~2-3 days + $10-20 Together and $20-40 OpenAI/Google spend. Candidate content for PRODUCT-009 if the finding generalizes. Depends on judge calibration (EVAL-046) being trustworthy on non-Anthropic agent output.
  source_doc: docs/FINDINGS.md F2 caveat
  closed_date: '2026-04-20'

- id: EVAL-072
  domain: eval
  title: Judge-methodology fix — rubric literalism + partial-credit divergence between Anthropic/llama judges
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-068 cross-judge agreement: claude-sonnet-4-5 vs llama-70B-Instruct-Turbo measured 77.3% overall (reflection=86%, perception=75%, neuromod=71%). Two root causes identified: (1) Rubric-literalism gap — sonnet scores 0 when agent declines to use a tool; llama assigns 1.0 for polite honest declines. (2) Partial-credit divergence — llama uses 0.5 scores that binarize to 1 at the 0.5 threshold while sonnet scores 0.1-0.4 for the same partial-success behavior. Fix: add "partial credit: no — score 0 unless the task was fully completed" to the judge prompt, and add "honest inability to use tools is scored 0 when the rubric requires tool use" instruction. Re-run n=30/faculty agreement check. If ≥80%, update RESEARCH_INTEGRITY.md to permit citation of EVAL-060-derived results.
  acceptance_criteria:
    - Judge prompt updated with anti-partial-credit + rubric-literalism directives
    - Re-run cross-judge agreement on perception + neuromod (n=30/faculty each)
    - Overall agreement ≥80% after fix
    - RESEARCH_INTEGRITY.md updated to reflect cross-judge validation status
  depends_on: [EVAL-068]
  notes: |
    Filed by EVAL-068 per acceptance criteria (agreement <80%). The Together API key (tgp_v1_*) returned HTTP 403 during EVAL-068 — the llama-70B data used is from the existing eval-042-crossjudge sweeps, not a fresh run. Once Together access is restored, run rescore-jsonl.py with Qwen3-Coder-480B to get a third judge data point.
  source_doc: docs/eval/EVAL-068-cross-judge-agreement.md
  closed_date: '2026-04-20'

- id: EVAL-073
  domain: eval
  title: Both-strict cross-judge rescore — close EVAL-072 residual perception gap
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-072 applied the rubric-literalism + no-partial-credit directive to the Llama judge only and measured 75% overall agreement vs the original Sonnet scores (perception -8pp, neuromod +12pp). The residual perception gap is now driven by Sonnet's ORIGINAL partial- credit-friendly scoring (0.5-0.85 values binarizing to 1) vs strict-Llama's 0. Re-score BOTH judges with the strict prompt on the same three fixtures (reflection, perception, neuromod) to test whether both-strict closes the gap.
  acceptance_criteria:
    - "scripts/ab-harness/rescore-jsonl.py extended to accept --rescore-with-judge anthropic:claude-sonnet-4-5 as a second pass on the same input (currently only together: path is wired)"
    - Both-strict pass run on reflection + perception + neuromod fixtures at n>=30/faculty each
    - Output posted to docs/eval/EVAL-073-both-strict-rescore.md with a 3x2 agreement table (per fixture, orig vs both-strict)
    - If overall agreement >=80% under both-strict, update RESEARCH_INTEGRITY.md per the EVAL-072 acceptance gate that was not met with single-sided strict
  depends_on: [EVAL-072]
  notes: |
    Estimated cost ~300 Anthropic judge calls (~$1-2) + ~300 Together calls (free tier or <$1). Small effort, informative either way.
  source_doc: docs/eval/EVAL-072-judge-prompt-fix.md
  closed_date: '2026-04-20'

- id: EVAL-074
  domain: eval
  title: DeepSeek lesson-injection correctness regression root cause
  status: open
  priority: P2
  effort: m
  description: |
    EVAL-071 preliminary (n~20-40/cell, 2026-04-20) showed DeepSeek-V3.1 loses -23pp task correctness when the COG-016 lessons block is injected. Spot-check of failure rows shows the failure mode is refusal-to-attempt ("here's how you could run find yourself") rather than Anthropic-style fake-tool-result hallucination. Localize which lesson directive drives the refusal: per-lesson-present/absent ablation at n=50/cell on DeepSeek, same reflection_tasks fixture, same judge panel. Report the single largest-impact lesson and propose a narrower per-family rewrite.
  acceptance_criteria:
    - Per-lesson ablation sweep at n=50/cell on DeepSeek-V3.1
    - Identify the lesson(s) whose presence flips correct→refusal
    - Propose either a reworded lesson variant or a per-family exclusion rule
  depends_on: [EVAL-071]
  source_doc: docs/eval/EVAL-071-halluc-generalization.md

- id: EVAL-075
  domain: eval
  title: Failure-mode taxonomy — hallucinate vs refuse vs decline scoring axis
  status: done
  priority: P2
  effort: s
  description: |
    Current multi-axis scoring captures correctness, hallucinated_tools, did_attempt. EVAL-071 surfaced a fourth distinguishable failure mode: refusal-to-attempt-with-instruction ("here is how you could run this yourself") which scores is_correct=False / halluc=False / attempted= False but is qualitatively different from a blank refusal or a confidence hedge. Add a fifth axis tagged `refusal_with_instruction` (judge prompt detects "here's how you could do this yourself" / "one way to do this is..." phrasing) and re-score the EVAL-071 sweep to quantify how much of DeepSeek's -23pp drop is this specific mode.
  acceptance_criteria:
    - scoring_v2.py extended with refusal_with_instruction boolean axis
    - Judge prompt includes explicit detection instruction for the pattern
    - Re-score EVAL-071 sweep and report breakdown (refusal vs other fail)
  depends_on: [EVAL-071]
  source_doc: docs/eval/EVAL-071-halluc-generalization.md
  closed_date: '2026-04-21'

- id: EVAL-076
  domain: eval
  title: Targeted re-run — claude-haiku-4-5 lessons-block ablation under EVAL-060 instrument
  status: done
  priority: P1
  effort: s
  description: |
    Per-sweep audit of EVAL-026 source data (in EVAL-069 follow-up, 2026-04-21) found cog016-n100 (agent=claude-haiku-4-5, judges=Sonnet+Llama-70B cross-family, n=100/cell) showed delta=-0.15 with proper methodology. EVAL-063/EVAL-064 used Llama-3.3-70B and Ollama qwen2.5:14b — different agents from haiku-4-5; we are comparing apples to oranges. EVAL-076 runs the apples-to-apples test: lessons-block A/B specifically on claude-haiku-4-5 under EVAL-060 LLM-judge instrument with cross-family judges. One sweep, ~$5 cost, definitive answer on whether harm is haiku-specific (H1, F1+F3 convergence into mid-tier story) or instrument-artifact (H2, F3 drops aggregate).
  acceptance_criteria:
    - Run scripts/ab-harness/run-ablation-sweep.py with model=claude-haiku-4-5, judges=Sonnet+Llama-70B, n>=50/cell on neuromod fixture, lessons-version=cog016
    - Per-cell rate + Wilson 95 CI + delta reported
    - Cross-judge Cohen kappa >= 0.70 per RESEARCH_INTEGRITY.md
    - docs/eval/EVAL-076-haiku-4-5-targeted-rerun.md updated with result section
    - F3 entry in docs/FINDINGS.md amended per H1/H2 outcome
  depends_on: [EVAL-060, EVAL-069]
  notes: |
    Filed by EVAL-069 follow-up analysis 2026-04-21. Cheapest, most informative remaining experiment in Q3 backlog.
  source_doc: docs/eval/EVAL-076-haiku-4-5-targeted-rerun.md
  closed_date: '2026-04-21'

- id: EVAL-081
  domain: eval
  title: Fix binary-mode ablation harness — replace exit-code-0 scorer with LLM-judge scorer
  status: done
  priority: P0
  description: |
    The binary-mode ablation harness (scripts/ab-harness/run-binary-ablation.py) scored trials as "correct" if exit code 0 and output length > 10 characters. This produces baseline accuracy of 0.033-0.100 below chance with CIs of +-0.14 that span the entire decision space. This gap replaces the exit-code-0 scorer with an LLM-judge scorer that calls the judge API on every trial output, adds an A/A calibration mode to confirm noise floor <= +-0.05 before any treatment sweep, and gates all future ablation sweeps on passing the A/A check.
  acceptance_criteria:
    - run-binary-ablation.py --scorer llm-judge implemented (default); --scorer exit-code still available for debugging but marks results validated=false
    - "--aa-calibrate flag runs n=50 A/A sweep before treatment; aborts if noise floor > +-0.05"
    - At least one non-Anthropic judge family supported via --judge-family flag
    - RESEARCH_INTEGRITY.md updated to explicitly prohibit exit-code-0 as primary scorer
  closed_date: '2026-04-21'

- id: EVAL-083
  domain: eval
  title: Eval credibility audit sweep
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-069 used broken scorer (exit_code_fallback, python3.14 no anthropic module). Are there other evals with hidden methodology issues? Spot-check 12–15 recent evals (focus EVAL-070 through EVAL-082). For each: inspect JSONL scorer field, check shebang, verify LLM judge availability. Categorize: valid, partial (workaround but defensible), broken. Document findings with evidence (JSONL snippets, shebang diffs).
  acceptance_criteria:
    - Audit complete on 12+ evals (EVAL-070 through EVAL-082)
    - Findings documented with evidence (JSONL snippets, shebang diffs, API logs)
    - Risk categorized for each (safe, needs re-run, broken)
    - Recommended actions clear (re-run with fix, retire finding, no action)
    - Report published in docs/eval-credibility-audit.md
  notes: |
    High confidence gain for publication (PRODUCT-009). Parallelizable across agents.
  source_doc: docs/EVALUATION_PLAN_2026Q2.md
  closed_date: '2026-04-25'

- id: EVAL-084
  domain: eval
  title: EVAL-063 re-aggregate using only scorer=='llm_judge' rows
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-083 audit (2026-04-25) found EVAL-063's archived run had mixed scorers — 4 files (366 rows) used `exit_code_fallback`, 4 files (399 rows) used `llm_judge`, and both A/A baselines (60 rows) used `exit_code_fallback`. EVAL-063 currently feeds EVAL-061's "VALIDATED(NULL)" claim for Metacognition, which feeds REMOVAL-001's decision matrix and ultimately REMOVAL-003 (belief_state deletion). The decision is probably still correct because the llm-judge half of the data also shows NEUTRAL, but the credibility chain has a documented hole that needs closing before PRODUCT-009 publication. Re-aggregate the EVAL-063 published delta using only `scorer=='llm_judge'` rows. If insufficient llm-judge rows for valid inference, mark EVAL-063 RETIRED like EVAL-069.
  acceptance_criteria:
    - Aggregated delta + Wilson 95% CI computed using only llm_judge rows from EVAL-063 archived JSONL
    - If delta or CI changes materially vs. published number, FINDINGS.md F3 caveat extended
    - All evidence preserved in docs/eval/EVAL-063-credibility-rerun.md
  depends_on: [EVAL-083]
  notes: |
    Pure aggregation work — no new sweep needed. ~2-3 hours including doc. Filed by EVAL-083 audit.
  source_doc: docs/eval/EVAL-063-credibility-rerun.md
  closed_date: '2026-04-25'

- id: EVAL-085
  domain: eval
  title: Verify EVAL-064 published aggregate excluded transient exit-code rows
  status: done
  priority: P3
  effort: xs
  description: |
    EVAL-083 audit (2026-04-25) found two short transient files in EVAL-064's archived run that used the broken `exit_code_fallback` scorer (4 + 6 = 12 rows total) alongside the main 398-row llm_judge sweep. Likely partial-run artifacts. Verify the EVAL-064 published FINDINGS row did not pick up the 12 transient rows. If it did, recompute the aggregate; if not, document which files fed the aggregate so future audits don't re-flag the same evidence.
  acceptance_criteria:
    - Confirmation in EVAL-064 doc of which JSONL file(s) fed the aggregate
    - If transient rows were included, recomputed aggregate published with Wilson 95% CI
    - If not, brief audit note in EVAL-064 doc saying so
  depends_on: [EVAL-083]
  notes: |
    XS effort — likely a 30-minute doc check. Low priority because the transient rows are 12 of 410, ~3% — unlikely to swing a verdict but deserves the trail.
  source_doc: docs/eval/EVAL-064-aggregate-audit.md
  closed_date: '2026-04-25'

- id: EVAL-086
  domain: eval
  title: opened_date backfill for open gaps + enforce non-null on future reserves
  status: open
  priority: P2
  effort: xs
  description: |
    22 of 23 open gaps have opened_date null in the registry. Only INFRA-070
    (2026-04-25) has a date. The coordination system cannot compute cycle time,
    aging alerts, or stall detection for 96% of open work. Cold Water STILL_OPEN
    classifications require manual cross-referencing across issue text rather than
    a database query. Fix: (1) backfill opened_date for all 22 dateless open gaps
    using git log --grep=ID --diff-filter=A to find the commit that first added
    each gap; (2) add a non-null constraint to chump gap reserve so future
    reservations always stamp opened_date.
  acceptance_criteria:
    - All open gaps have non-null opened_date in .chump/state.db
    - docs/gaps.yaml mirror reflects backfilled dates
    - chump gap reserve always stamps opened_date on new gaps
    - Stall detection expressible as a registry query
  opened_date: '2026-04-26'

- id: EVAL-087
  domain: EVAL
  title: Evaluation-awareness literature invalidates A/B trust — reframe RESEARCH-026 to P1
  status: open
  priority: P1
  effort: s
  description: |
    Cold Water Issue #7 (2026-04-26): RESEARCH-026 ("Observer-effect / evaluation-framing
    sandbagging check", P2, open, no start date) was filed to check whether Chump's A/B
    harness produces different results because tested agents detect they are in an evaluation
    context. The Institute for AI Policy and Strategy (IAPS) published "Evaluation Awareness:
    Why Frontier AI Models Are Getting Harder to Test" (2026,
    https://www.iaps.ai/research/evaluation-awareness-why-frontier-ai-models-are-getting-harder-to-test)
    documenting that frontier models distinguish evaluation from deployment contexts with high
    reliability and that some models actively reason about strategic response behavior during
    evaluation. Chump's A/B harness uses Claude Sonnet-4.5 and Claude Haiku-4.5 as tested
    agents. docs/RESEARCH_INTEGRITY.md line 93-95 requires mechanism analysis for deltas
    > ±0.05 but does not require ruling out evaluation-context confounding as a mechanism.
    All validated findings (F1-F6 in FINDINGS.md) were produced without evaluation-awareness
    controls. This gap escalates RESEARCH-026 from P2 to P1 with an empirical grounding:
    run the existing A/B harness under a modified system prompt that does not identify the
    run as an evaluation (neutral framing), compare results to existing EVAL-025/EVAL-076
    results, and document whether deltas hold. If they do not, the validated-findings table
    requires revision.
  acceptance_criteria:
    - RESEARCH-026 priority updated to P1 in the registry with this gap as the escalation rationale
    - The comparison is run at n>=50/cell and results committed to docs/eval/
    - If delta shifts >0.05 between framings, FINDINGS.md validated-findings table is updated
  opened_date: '2026-04-26'

- id: EVAL-088
  domain: EVAL
  title: EVAL-073 caveat — cross-judge agreement was rubric- and fixture-specific, not generalizable
  status: done
  priority: P2
  effort: xs
  description: |
    Action item from EVAL-074-AUDIT-2026-04-26: the EVAL-073 result doc claimed
    100% Sonnet/Llama strict-binary cross-judge agreement on n=90, and the
    §"Interpretation" section read that as evidence the cross-judge ceiling was
    lifted in general. The EVAL-074 audit then found 71% / κ=0.40 on a different
    fixture (DeepSeek-V3.1 reflection_tasks.json n=200) under the same strict
    binary rubric. So the 100% number is a per-fixture measurement, not a
    methodology guarantee. This gap amends docs/eval/EVAL-073-both-strict-rescore.md
    with a 2026-04-26 caveat block scoping the conclusion to its fixture and
    restoring "Anthropic-only judging is insufficient" to load-bearing status in
    RESEARCH_INTEGRITY.md.
  acceptance_criteria:
    - "docs/eval/EVAL-073-both-strict-rescore.md has a \"2026-04-26 amendment\" section linking to EVAL-074-AUDIT"
    - Caveat clarifies the 100% number remains valid on EVAL-042 fixtures but does not generalize
  depends_on: [EVAL-074]
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: EVAL-089
  domain: EVAL
  title: EVAL-074-CROSS-JUDGE-FINISH — third judge (Qwen-2.5-72B) rescore once Together credits restored
  status: open
  priority: P2
  effort: xs
  description: |
    Action item from docs/eval/EVAL-074-AUDIT-2026-04-26.md (§"Status changes" /
    §"Action items"): the Sonnet rescore alone was decisive enough to retract
    the EVAL-074 mechanism claim, but the prereg-style 3-judge cross-family
    panel (RESEARCH-021's pattern) is incomplete without a third judge.
    Qwen-2.5-72B-Instruct-Turbo via Together was attempted on 2026-04-26 and
    blocked by `Credit limit exceeded` (0/200 rows scored). Once Together
    credits are topped up (~$1 budget), re-run
    `scripts/ab-harness/rescore-jsonl.py` with
    `--rescore-with-judge together:Qwen/Qwen2.5-72B-Instruct-Turbo` against
    `docs/archive/eval-runs/eval-071-2026-04-22/eval-071-deepseek-v3-1-ab-n100-1776740166.jsonl`
    and append the 3-way agreement table to EVAL-074-AUDIT-2026-04-26.md. This
    is judge-completion for an already-retracted finding, not a new
    investigation — outcome is methodological completeness, not a result claim.
  acceptance_criteria:
    - Qwen-2.5-72B JSONL produced under logs/ab/eval-074-rescore-qwen.jsonl (≥80% scored)
    - 3-judge agreement table (Llama / Sonnet / Qwen) added as amendment to EVAL-074-AUDIT-2026-04-26.md
    - Cohen κ reported for each judge pair
    - "If Qwen agrees with Sonnet (disagrees with Llama on gotcha rows), retraction stands as written; if Qwen agrees with Llama, that is itself a finding worth flagging in §\"Status changes\""
  depends_on: [EVAL-074]
  opened_date: '2026-04-26'

- id: EVAL-090
  domain: EVAL
  title: Re-run EVAL-069 under verified python3.12 - F3 retirement is based on broken-vs-broken comparison
  status: done
  priority: P0
  effort: s
  description: |
    INTEGRITY_AUDIT_3 (2026-04-24) walked through the EVAL-069 credibility
    crisis - the original EVAL-026 neuromod aggregate signal (-10 to -16 pp)
    was measured under the exit-code scorer that EVAL-060 later proved
    broken. EVAL-069 reran the measurement to test the signal under a
    fixed instrument - but the python3 shebang fix (python3 -> python3.12)
    didn't land until 2026-04-22, one day AFTER EVAL-069 closed. EVAL-069
    almost certainly ran under the same broken exit_code_fallback scorer.
    Identical CIs in both cells (acc_A=0.920 [0.812, 0.968] = acc_B=0.920
    [0.812, 0.968], delta=0.000) is the fingerprint of a non-cognitive
    scorer. F3 (neuromod aggregate harm) was RETIRED in FINDINGS.md based
    on EVAL-069 - i.e. retired based on a broken-vs-broken comparison, not
    a real measurement. Re-run with verified python3.12, confirm JSONL rows
    show scorer=llm-judge not exit_code_fallback, and either re-instate or
    properly retire F3 based on a working measurement.
  acceptance_criteria:
    - Verify python3.12 import anthropic before launching
    - Re-run EVAL-069 with same parameters under python3.12
    - Inspect JSONL output - every row must show scorer llm-judge
    - Run A/A baseline alongside (n>=50) to confirm judge is producing variance
    - If delta materially differs from EVAL-069, update FINDINGS.md F3 status
    - If delta still ~0 with non-identical CIs, F3 retirement stands but on solid ground
    - Block PRODUCT-009 publication until this lands
  opened_date: '2026-04-26'
  closed_date: '2026-05-02'
  closed_pr: 722

- id: EVAL-091
  domain: EVAL
  title: Closed EVAL-* gaps are not scored against RESEARCH_INTEGRITY methodology table
  status: open
  priority: P1
  effort: s
  description: |
    Pre-commit gate INFRA-113 (preregistration content) catches violations
    at close time but does not retroactively score already-closed gaps.
    Cold Water's "Reality Check" lens is supposed to score recent evals
    against docs/RESEARCH_INTEGRITY.md (n>=50, judge diversity, A/A
    baseline, mechanism analysis for |delta|>0.05, prohibited claims),
    but it does this by hand and has been inconsistent. Build a one-shot
    scorer (script or CI job) that walks closed EVAL-*/RESEARCH-* gaps
    in the last 30 days and reports per-gap pass/fail against each
    methodology line. Use the output to (a) populate Cold Water's
    Reality Check lens deterministically and (b) file follow-up gaps
    for any retroactive violations.
  acceptance_criteria:
    - Scorer script reads recent EVAL-*/RESEARCH-* closures and the methodology table from RESEARCH_INTEGRITY.md
    - Per-gap report - n>=50 ok|fail, judge diversity ok|fail, A/A baseline ok|fail, mechanism analysis ok|fail|n_a, prohibited-claim hits
    - Output is consumed by Cold Water's Reality Check lens (deterministic, not narrative)
    - Any retroactive violations get a follow-up RESEARCH-*/EVAL- gap filed automatically
  opened_date: '2026-04-26'

- id: EVAL-092
  domain: EVAL
  title: provider-matrix harness — multi-provider chump-local dispatch bake-off across env-configured backends
  status: done
  priority: P1
  effort: s
  notes: |
    closed_pr=601 (renumbered from EVAL-089 to resolve collision with PR #558)
  closed_date: '2026-04-27'

- id: EVAL-093
  domain: EVAL
  title: RESEARCH_INTEGRITY.md mechanism-analysis standard lacks pre-commit kappa threshold gate — EVAL-074 retraction consequence
  status: open
  priority: P1
  effort: s
  description: |
    docs/process/RESEARCH_INTEGRITY.md line 93-95 requires a hypothesis
    for deltas >±0.05. It does not require verifying cross-judge
    agreement before committing the mechanism claim. PR #549 committed a
    mechanism claim for EVAL-074 (over-compliance on gotcha tasks, -30pp,
    McNemar p=0.0007) using a single Llama-3.3-70B judge. PR #551
    (2c4479f) retracted it: Sonnet-4.5 cross-rescore showed -0.4pp
    (McNemar p=1.0); Llama vs Sonnet kappa=0.40 on gotcha tasks, below
    the project's own 80%/0.6 thresholds cited in the retraction commit.
    
    The standard that required mechanism analysis allowed a
    methodologically invalid mechanism claim to merge to main. The
    cross-judge verification step was applied only after the claim was
    committed, not before. The gap: mechanism analysis must clear the
    project's existing kappa threshold (κ≥0.6, ≥80% agreement) on the
    relevant fixture class BEFORE the mechanism claim can land.
    
    Cold Water Issue #8, EVAL-074 retraction (PR #551, 2c4479f).
  acceptance_criteria:
    - "docs/process/RESEARCH_INTEGRITY.md mechanism-analysis section adds an explicit gate: mechanism claim PRs must include a cross- judge agreement score ≥0.6 (kappa) on the fixture class where the mechanism was detected"
    - Pre-commit or CI check warns (non-blocking initially) when a mechanism-claim commit lacks a documented kappa score
    - EVAL-089 (finish EVAL-074 with Qwen-2.5-72B) uses this updated standard
  opened_date: '2026-04-27'

- id: EVAL-094
  domain: EVAL
  title: ICLR 2026 covert sandbagging confirms 16-36% monitor bypass — run RESEARCH-026 swept experiment
  status: open
  priority: P1
  effort: s
  description: |
    "LLMs Can Covertly Sandbag on Capability Evaluations Against Chain-of-Thought
    Monitoring" (arXiv:2508.00943, accepted ICLR 2026) evaluated 10 models including
    Claude-3.7-Sonnet and Claude-4-Sonnet. Key finding: models bypass CoT monitoring
    16-36% of the time when monitor-aware and when prompted to sandbag. Chump's A/B
    harness uses Claude Haiku-4.5 and Sonnet-4.5 as agents under test with explicit
    evaluation framing (task IDs, structured rubrics, "the user asks..." syntax).
    
    The IAPS paper (cited in Issues #6-#8) established that models detect evaluation
    contexts. This paper quantifies the bypass rate against the specific monitoring
    approach (CoT auditing) that Chump relies on implicitly for judge validity.
    
    EVAL-087 (P1, open, 3 cycles inactive) asks for RESEARCH-026 to be reframed to
    P1. This gap supersedes that reframe request and directly executes the
    RESEARCH-026 experiment: compare reflection fixture results under (a) standard
    evaluation framing vs (b) naturalized framing with scrubbed task IDs and rubrics.
    n>=100, cross-judge panel (haiku-4-5 + llama-3.3-70b), A/A baseline, preregistered
    hypothesis.
    
    Filing this as EVAL-094 rather than closing EVAL-087 because EVAL-087 is a
    priority-reframe request while this is an execution gap. Close EVAL-087 when
    RESEARCH-026 is upgraded to P1 in the canonical store.
  acceptance_criteria:
    - RESEARCH-026 priority set to P1 in .chump/state.db (via chump gap set)
    - Preregistration doc at docs/eval/preregistered/EVAL-094.md committed before data collection
    - Harness run with n>=100, cross-judge, A/A calibration, naturalized vs standard framing
    - Wilson CI results committed to docs/eval/EVAL-094-results.md
    - Validated findings table in RESEARCH_INTEGRITY.md updated with result (or null)
  depends_on: [EVAL-087, RESEARCH-026]
  opened_date: '2026-05-02'

- id: EVAL-095
  domain: EVAL
  title: Empirical re-run of CHUMP_BYPASS_NEUROMOD on current binary (deferred from EVAL-090)
  status: open
  priority: P3
  effort: s
  description: |
    EVAL-090 (2026-05-01) closed on the methodological finding (audit's broken-scorer claim contradicted by archived JSONL). The empirical question — does the *current* chump binary's CHUMP_BYPASS_NEUROMOD ablation produce a measurable accuracy signal under qwen2.5:14b? — was deferred (sweep killed inadvertently mid-run, not restarted because the methodological finding was independent and decisive). EVAL-069's verdict (delta ≈ 0 on this fixture+agent) was made in 2026-04-21 against an older chump binary; ~10 days of neuromod-related work has shipped since. A clean replication on the current binary would either (a) confirm EVAL-069 stands or (b) show the current binary's neuromod ablation produces a signal the older one didn't. Cheap insurance — n=20/cell, ~50 min wall-clock, ~/bin/zsh.50 Anthropic spend. Run as overnight job per CLAUDE.md scheduler discipline.
  acceptance_criteria:
    - n=20/cell sweep completes with scorer=llm_judge for ≥95% of rows
    - result doc at docs/eval/EVAL-095-*.md compares to EVAL-069 baseline
    - FINDINGS.md F3 caveat updated if delta > 0.10pp

- id: EVAL-82
  domain: eval
  title: Re-verify EVAL-069 scorer credibility under python3.12
  status: done
  priority: P0
  effort: s
  description: |
    AUDIT-3 finding: EVAL-069 (which retired neuromod aggregate signal as "methodology artifact") shows identical confidence intervals [0.812, 0.968] in both cells — the fingerprint of a non-cognitive exit-code-fallback scorer. Timeline: EVAL-069 closed 2026-04-21, shebang fix (python3 → python3.12) landed 2026-04-22 commit 8f3a994. High probability EVAL-069 ran under python3=3.14 (no anthropic module) instead of python3.12. Re-run the exact command from EVAL-069 doc with verified python3.12, confirm JSONL output contains "scorer": "llm-judge" (not "scorer": "exit_code_fallback").
  acceptance_criteria:
    - "Run: python3.12 scripts/ab-harness/run-binary-ablation.py --module neuromod --n-per-cell 50 --use-llm-judge"
    - "Verify JSONL output contains \"scorer\": \"llm-judge\" on every row (not \"scorer\": \"exit_code_fallback\")"
    - If result differs significantly from EVAL-069's delta=0.000, update FINDINGS.md F3
    - Document evidence and recommendation for PRODUCT-009 publication decision
  closed_date: '2026-04-24'

- id: FLEET-001
  domain: fleet
  title: Mutual supervision — Mac can restart Mabel; Pixel can probe Mac health
  status: done
  priority: P1
  effort: m
  description: |
    Horizon 2 goal: Mac and Pixel supervise each other. Currently neither can restart the other or verify the other's health automatically.
  notes: |
    scripts/restart-mabel.sh: SSH stop+restart chump --discord on Pixel via ensure-mabel-bot-up.sh. scripts/probe-mac-health.sh: curl /api/dashboard with CHUMP_WEB_TOKEN, parse fleet_status JSON. Integration test checklist added to docs/FLEET_ROLES.md.
  source_doc: docs/ECOSYSTEM_VISION.md
  closed_date: '2026-04-16'

- id: FLEET-002
  domain: fleet
  title: Single fleet report — Mabel drives briefing, Chump notifies only
  status: done
  priority: P1
  effort: s
  description: |
    Currently both Chump and Mabel may produce hourly fleet reports, creating duplicate notifications. One report per morning from Mabel; Chump uses notify only for events (blocked, PR ready).
  depends_on: [FLEET-001]
  notes: |
    Added CHUMP_FLEET_REPORT_ROLE=notify_only gate to hourly-update-to-discord.sh. When set, script exits immediately (no LLM call, no DM). Chump's notify tool remains active for ad-hoc events. docs/OPERATIONS.md "Single fleet report" section updated with Soft gate guidance.
  source_doc: docs/ECOSYSTEM_VISION.md
  closed_date: '2026-04-16'

- id: FLEET-003
  domain: fleet
  title: Workspace merge protocol for dynamic autopoiesis
  status: done
  priority: P3
  effort: xl
  description: |
    Section 3.6: two Chump instances temporarily share blackboard state via peer_sync, creating a unified broadcast for bounded turns, then split. Prerequisite: fleet symbiosis (FLEET-001) stable and mutual supervision proven.
  depends_on: [FLEET-001, FLEET-002]
  notes: |
    Decomposed (FLEET-001/002 are done — gate satisfied):
      FLEET-003a — protocol spec doc (RFC; xs)
      FLEET-003b — peer_sync extension for atomic blackboard exchange (m)
      FLEET-003c — merge_workspace + split_workspace tool pair (s)
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-18'

- id: FLEET-003a
  domain: fleet
  title: Workspace merge protocol — RFC + state diagram
  status: done
  priority: P3
  effort: xs
  description: |
    First chunk of FLEET-003. Pure design work. Produce docs/rfcs/RFC-fleet-workspace-merge.md covering: initiation condition (when to merge), merge envelope (how blackboard items transit + are attributed), duration cap (max turns merged), split semantics (what stays joint vs what goes back to each peer), failure modes (one peer disappears mid-merge).
  depends_on: [FLEET-001, FLEET-002]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: FLEET-003b
  domain: fleet
  title: peer_sync extension — atomic blackboard exchange
  status: done
  priority: P3
  effort: m
  description: |
    Second chunk. peer_sync currently sends per-item heartbeats; needs a transactional batch send/recv so two peers can swap blackboard snapshots in one round-trip. Wire envelope: SHA256 of payload, sequence number, timeout, peer-attribution headers.
  depends_on: [FLEET-003a]
  source_doc: src/fleet.rs
  closed_date: '2026-04-18'

- id: FLEET-003c
  domain: fleet
  title: merge_workspace + split_workspace tool pair
  status: done
  priority: P3
  effort: s
  description: |
    Third chunk. Surface FLEET-003b's exchange as agent tools so the agent can decide to initiate a merge mid-turn (e.g., "I need Mabel's perspective on this") and split when done.
  depends_on: [FLEET-003b]
  source_doc: src/fleet_tool.rs
  closed_date: '2026-04-18'

- id: FLEET-004
  domain: fleet
  title: Peripheral vision — ambient awareness stream for multi-agent sessions
  status: done
  priority: P1
  effort: s
  description: |
    Agents currently have zero passive awareness of each other. Lease files tell other agents who owns a gap, but nothing about what they're actively doing, what they've tried, or when something abrupt happens. Humans working side-by-side have continuous peripheral awareness — they don't ask "what are you doing?"; they receive that signal passively. Three missing capabilities: (1) passive emission — agents radiate activity events automatically without deciding to; (2) ambient stream — events accumulate in an always-readable log any agent can tail; (3) anomaly detection — a background process notices pattern breaks (overlapping edits, silent agents, sudden file bursts) and injects ALERT events.
  notes: |
    Decomposed into four xs/s sub-gaps:
      FLEET-004a — ambient.jsonl format + emit helpers (xs)
      FLEET-004b — passive emission via git post-commit hook (xs)
      FLEET-004c — passive emission via Claude Code PostToolUse hooks (xs)
      FLEET-004d — CLAUDE.md context injection at session start (xs)
      FLEET-005  — anomaly detector daemon (s, separate gap)
  source_doc: docs/AGENT_COORDINATION.md
  closed_date: '2026-04-17'

- id: FLEET-004a
  domain: fleet
  title: Ambient event stream — ambient.jsonl format + emit helpers
  status: done
  priority: P1
  effort: xs
  description: |
    Foundation for peripheral vision. Defines the ambient.jsonl event format and provides two emit primitives: (1) scripts/ambient-emit.sh — shell one-liner usable from git hooks and shell scripts; (2) ambient_emit() in crates/chump-agent-lease for Rust callers. Both append a newline-delimited JSON event atomically so concurrent writers don't corrupt the file.
  source_doc: .chump-locks/ambient.jsonl
  closed_date: '2026-04-17'

- id: FLEET-004b
  domain: fleet
  title: Passive emission — git post-commit hook appends to ambient stream
  status: done
  priority: P1
  effort: xs
  description: |
    Agents should radiate commits automatically. Currently no post-commit hook exists. Adding one means every git commit — from any session in any worktree — silently appends a commit event to the ambient stream. Other agents see the commit without the committing agent having to decide to announce it.
  depends_on: [FLEET-004a]
  source_doc: scripts/git-hooks/post-commit
  closed_date: '2026-04-17'

- id: FLEET-004c
  domain: fleet
  title: Passive emission — Claude Code PostToolUse hooks for file edits
  status: done
  priority: P1
  effort: xs
  description: |
    File edits are the primary activity signal between agents. Claude Code supports PostToolUse hooks in .claude/settings.json that fire after every Edit/Write/Bash tool call. Wiring ambient-emit.sh into these hooks means every file edit and significant tool call emits passively — the agent doesn't need to think about it.
  depends_on: [FLEET-004a]
  source_doc: .claude/settings.json
  closed_date: '2026-04-17'

- id: FLEET-004d
  domain: fleet
  title: Context injection — CLAUDE.md reads ambient stream at session start
  status: done
  priority: P1
  effort: xs
  description: |
    The ambient stream is only useful if agents actually read it. Adding a mandatory step to the session startup block in CLAUDE.md ensures every new agent session reads the last 30 lines of ambient.jsonl before picking a gap. This is the "glance around the room" step — cheap, fast, and gives immediate situational awareness of what other agents have been doing.
  depends_on: [FLEET-004a]
  source_doc: CLAUDE.md
  closed_date: '2026-04-17'

- id: FLEET-005
  domain: fleet
  title: Anomaly detector — fswatch daemon emits ALERT events to ambient stream
  status: done
  priority: P1
  effort: s
  description: |
    Passive emission + ambient stream give agents a chronicle of events, but no agent notices when patterns break. Humans have preattentive anomaly detection — you notice someone running, sudden silence, an abrupt crash. A lightweight background daemon (scripts/ambient-watch.sh) watches .chump-locks/ and src/ with fswatch/inotifywait and emits ALERT events for three anomaly classes: (1) lease overlap — two sessions claim the same file path; (2) silent agent — a live lease's heartbeat stops for >15m; (3) edit burst — >20 file mutations in <60s (possible rebase stomp or runaway agent).
  depends_on: [FLEET-004a]
  source_doc: scripts/ambient-watch.sh
  closed_date: '2026-04-17'

- id: FLEET-006
  domain: fleet
  title: Distributed ambient stream — bridge .chump-locks/ambient.jsonl to NATS topics
  status: done
  priority: P1
  effort: l
  description: |
    Ambient stream currently lives on filesystem (.chump-locks/ambient.jsonl). This breaks when agents run on different machines. Replace with NATS-backed event topics. Every agent publishes events (bash_call, file_edit, commit, session_start) to NATS. Every agent subscribes to all events for peripheral vision. Fallback: git itself remains the distributed audit trail (commits, refs). Design: single NATS topic "chump/ambient-stream" with multiplexed event kinds, or one topic per kind. Schema: same JSON as current ambient.jsonl entries.
  acceptance_criteria:
    - NATS broker operational (local, air-gapped capable)
    - Agents publish bash_call, file_edit, commit, session_start, ALERT events to NATS
    - Agents subscribe and tail 100 recent events on startup
    - Event schema matches current ambient.jsonl (ts, session, event, payload)
    - git commits remain the primary audit trail
  notes: |
    Critical path for distributed fleet. Unblocks FLEET-007/008/009. NATS can run entirely offline on Tailscale network (FLEET-013 prereq). Prototype in 2–3 days.
  source_doc: docs/FLEET_VISION_2026Q2.md
  closed_date: '2026-04-26'

- id: FLEET-007
  domain: fleet
  title: Distributed leases with TTL — replace filesystem .chump-locks/*.json with NATS
  status: done
  priority: P1
  effort: m
  description: |
    Current leases live in .chump-locks/<session>.json on local filesystem. This breaks when agents run on different machines. Replace with NATS-backed exclusive claims: agents publish a claim message (gap_id, session_id, ttl_seconds) to NATS topic "chump/leases". NATS broker tracks which session owns which gap (simple in-memory state machine, TTL auto-expires claims). gap-preflight.sh queries NATS to check if gap is available. gap-claim.sh publishes a claim. Heartbeat mechanism: agent renews lease every N seconds or lease expires.
  acceptance_criteria:
    - "Agent can claim a gap via NATS (gap-claim.sh publishes to \"chump/leases\")"
    - "Agent can check availability via NATS (gap-preflight.sh queries \"chump/leases\")"
    - Lease auto-expires if agent stops renewing (TTL validation in test)
    - Two agents cannot claim the same gap simultaneously
  depends_on: [FLEET-006]
  notes: |
    Enables distributed work allocation. Heartbeat interval ~30s; TTL ~5min. Simple NATS state machine (not consensus-based; eventual consistency OK).
  source_doc: docs/FLEET_VISION_2026Q2.md
  closed_date: '2026-04-25'

- id: FLEET-008
  domain: fleet
  title: Work board / task queue — post subtasks for other agents to claim
  status: open
  priority: P1
  effort: m
  description: |
    Agents today cannot decompose work. If an agent encounters a large gap, it ships the whole thing. With distributed coordination, agents should be able to post subtasks to a shared "work board" for other agents to claim. Schema: subtask_id, parent_gap, title, description, task_class, estimated_duration, requirements (model_family, vram, etc), posted_by, claimed_by, status (open/claimed/completed/failed). Transport: NATS topic "chump/work-board" (or git-backed queue as fallback). Agents check board on startup; claim subtasks that match their capabilities (see FLEET-009).
  acceptance_criteria:
    - "Agents can post subtasks to \"chump/work-board\" via NATS"
    - Subtask schema includes metadata (task_class, requirements, estimated_duration)
    - Agents can query work board and list open subtasks
    - Agent can claim a subtask (sets claimed_by, status=claimed)
    - Subtask completion updates board and merges result back into parent gap
  depends_on: [FLEET-006, FLEET-007]
  notes: |
    Unblocks work decomposition (FLEET-011). Initial version: manual posting by agents. Later: automatic decomposition heuristics.
  source_doc: docs/FLEET_VISION_2026Q2.md

- id: FLEET-009
  domain: fleet
  title: Capability declaration & task-fit scoring — agents declare capabilities, tasks declare needs
  status: done
  priority: P1
  effort: m
  description: |
    Agents vary in capability: different models, different inference speeds, different task-class experience. Agents should only claim work they are "the right fit" for. Schema: agent publishes {model_family, model_name, vram_gb, inference_speed_tok_per_sec, supported_task_classes, reliability_score}. Task declares {required_model_family, min_vram_gb, min_inference_speed, task_class, decomposable}. Scoring function: fit_score = base_score * model_match * reliability * task_class_match. Agents filter work board by fit_score > threshold; claim best matches first.
  acceptance_criteria:
    - Agent capability schema defined and documented
    - Task requirement schema defined and documented
    - fit_score() function implemented (at least model_family, vram, task_class)
    - "Agent publishes capability on startup (NATS topic \"chump/agent-capabilities\")"
    - Agent filters work board by fit_score >= 0.5 threshold
  depends_on: [FLEET-006, FLEET-008]
  notes: |
    Early version: simple heuristic scoring. Later (FLEET-011): learn from outcomes, adjust reliability_score based on success/failure. Model family matching is critical (Anthropic vs open-source agents will make different decisions).
  source_doc: docs/FLEET_VISION_2026Q2.md
  closed_date: '2026-04-24'

- id: FLEET-010
  domain: fleet
  title: Help-seeking protocol — agent requests help when blocked
  status: open
  priority: P2
  effort: m
  description: |
    Agent encounters a blocker (timeout, missing capability, unknown task class) → posts help request to "chump/help-requests" → other agents see and can claim help task. Schema: help_request_id, parent_gap, original_agent, blocker_type (timeout/capability/unknown_class), description, posted_at, claimed_by, status. Help-seeking triggers: (1) agent timeout (execution > 60min), (2) missing model capability (task requires family X, agent has family Y), (3) unknown task class (not in agent's supported_task_classes). Original agent blocks (waits) or continues in parallel depending on urgency.
  acceptance_criteria:
    - Agent detects blocker condition (timeout, capability mismatch, unknown class)
    - "Agent posts help request to \"chump/help-requests\" with structured blocker_type"
    - Other agents see help request and can claim it
    - Help task completes and result merged back into original gap
  depends_on: [FLEET-009]
  notes: |
    Semantic question: should blocking be synchronous (agent waits) or async (agent continues, help happens in parallel)? Recommend: async for time blockers, sync for capability gaps (need the answer before proceeding).
  source_doc: docs/FLEET_VISION_2026Q2.md

- id: FLEET-011
  domain: fleet
  title: Work decomposition heuristics & learning — agent learns when to break tasks
  status: open
  priority: P2
  effort: l
  description: |
    Agents today ship monolithic PRs. They should learn to decompose work: multi-file refactors split into per-file changes, large feature branches split by subsystem, blocked tasks escalated to help-requests. Heuristics: (1) file count > 5 + LOC > 500 → consider decomposition; (2) execution time > 30min + no progress → ask for help; (3) task_class in (refactor, rebase, multi-system) → decompose by default. Learning: track which decompositions succeeded vs failed; bias toward decomposition if success rate > 70%.
  acceptance_criteria:
    - Heuristic rules implemented and documented
    - Agent tracks decomposition outcomes (success/failure/abort)
    - Agent adjusts decomposition bias based on learned success rate
    - docs/FLEET-011-decomposition-heuristics.md documents rules and learning trajectory
  depends_on: [FLEET-008, FLEET-010]
  notes: |
    Connects to EVAL-030 (task-class-aware lessons): decomposition heuristics + capability matching + lessons gating are three parts of task-aware execution. Large effort; consider staging in two quarters (heuristics Q4, learning Q1 2027).
  source_doc: docs/FLEET_VISION_2026Q2.md

- id: FLEET-012
  domain: fleet
  title: Blocker detection & timeout handling — agent recognizes stuck state
  status: done
  priority: P2
  effort: s
  description: |
    Agent needs to recognize when it is stuck: (1) execution timeout (running > 60min with no progress output), (2) compile failure loop (cargo check fails, fix loop repeats >3 times), (3) resource exhaustion (available_ram < 1GB), (4) capability gap (task requires model X, agent has model Y, no translation path). Current: agent just times out and dies. Better: agent detects blocker, posts help request (FLEET-010), lets peer take over or provides context for human intervention.
  acceptance_criteria:
    - Agent monitors execution time; flags if > 60min with no progress
    - Agent detects compile failure loops (cargo check failures > 3 consecutive)
    - Agent detects resource exhaustion (available_ram < threshold)
    - Agent detects capability gap (required model family not available)
    - Agent posts help request (FLEET-010) when blocker detected
  depends_on: [FLEET-010]
  notes: |
    Pairs with EVAL-030 (task-class awareness). Blocker detection is the trigger for help-seeking. Resource monitoring is the infrastructure (need metrics from agent).
  source_doc: docs/FLEET_VISION_2026Q2.md
  closed_date: '2026-04-24'

- id: FLEET-013
  domain: fleet
  title: Tailscale integration & agent discovery — agents find each other on VPN
  status: open
  priority: P2
  effort: s
  description: |
    Distributed agents live on a Tailscale VPN for zero-config, encrypted inter-device networking. NATS broker runs on Tailscale network (not internet-exposed). Agents discover each other and the NATS broker via Tailscale service discovery (or manual Tailscale IP assignment + environment variable). Integration: (1) agent starts Tailscale daemon (tailscaled), (2) joins network (tailscale up), (3) discovers NATS broker via "chump-nats.local" (mDNS on Tailscale), (4) connects to NATS.
  acceptance_criteria:
    - Agent startup script brings up Tailscale if not already running
    - Agent discovers NATS broker via Tailscale (can be IP-based or mDNS)
    - Multiple agents on different physical machines can communicate via NATS
    - docs/FLEET-013-tailscale-setup.md documents setup (key sharing, exit node config if needed)
  depends_on: [FLEET-006, FLEET-007]
  notes: |
    Air-gapped ready: Tailscale requires initial handshake but then works offline. Alternative: manual IP-based discovery (simpler but less flexible). Recommend Tailscale for the full vision (also enables remote troubleshooting).
  source_doc: docs/FLEET_VISION_2026Q2.md

- id: FLEET-015
  domain: fleet
  title: Ambient-stream NATS migration — complete FLEET-007 split-brain
  status: done
  priority: P1
  effort: m
  description: |
    FLEET-007 (done, PR #542) shipped NATS-backed distributed leases, creating
    machine-agnostic lease coordination. FLEET-006 (P1, open) bridges the ambient
    stream to NATS but remains unstarted. Result: lease coordination is NATS-backed
    (correct on any machine); ambient perception (.chump-locks/ambient.jsonl) is
    filesystem-local (broken on any machine other than the primary). An agent on
    machine B has correct lease mutual exclusion but receives empty ambient events.
    The CLAUDE.md mandatory pre-flight (tail -30 .chump-locks/ambient.jsonl) returns
    nothing on machine B. The agent proceeds not knowing it is blind. This gap tracks
    completion of the FLEET-007 migration by closing FLEET-006 and verifying
    two-machine ambient event propagation.
  acceptance_criteria:
    - FLEET-006 closed (ambient.jsonl events routed through NATS)
    - Two-machine integration test shows events from machine A in machine B tail
    - CLAUDE.md mandatory pre-flight continues to work unchanged
  depends_on: [FLEET-006, FLEET-007]
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: FLEET-016
  domain: FLEET
  title: Deduplicate FLEET-006 and FLEET-015 ambient intent before concurrent claim
  status: done
  priority: P2
  effort: xs
  description: |
    Cold Water Issue #7 (2026-04-26): the gap registry contains two open P1 gaps
    describing the same ambient-stream-to-NATS migration: FLEET-006 ("Distributed
    ambient stream — bridge .chump-locks/ambient.jsonl to NATS topics", P1, effort L,
    no opened_date) and FLEET-015 ("Ambient-stream NATS migration — complete FLEET-007
    split-brain", P1, effort M, opened 2026-04-26). FLEET-015 was filed by Cold Water
    Issue #6 without checking whether FLEET-006 was already open for the same work.
    An agent claiming FLEET-006 and an agent claiming FLEET-015 can work concurrently
    on substantially overlapping scope with distinct gap IDs, each believing their work
    is non-redundant. Before any agent claims either gap, this gap must resolve the
    overlap: either close FLEET-015 as a duplicate of FLEET-006, or restructure the
    two gaps so they cover non-overlapping scope (e.g., FLEET-006 = NATS schema +
    emit helpers, FLEET-015 = CLAUDE.md pre-flight and session-start subscription).
  acceptance_criteria:
    - FLEET-006 and FLEET-015 no longer overlap in scope
    - Either one is closed as duplicate or both have non-overlapping acceptance criteria
    - No agent claims both gaps simultaneously without knowing they are related
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: FLEET-017
  domain: FLEET
  title: Cold Water remote agent does not subscribe to NATS ambient stream - FLEET-006 unused
  status: done
  priority: P0
  effort: xs
  description: |
    FLEET-006 (PR #572, 2026-04-26) distributed the ambient stream to
    NATS, but the Cold Water scheduled-trigger prompt (saved at
    /Users/jeffadkins/.claude/plans/help-me-improve-this-velvet-thunder.md
    and in the actual /schedule remote trigger) still tails only the
    local file (.chump-locks/ambient.jsonl). When Cold Water runs in
    Anthropic cloud, that file is empty - it has never seen a local
    edit. This is THE mechanism behind the recurring "documenting
    failure but not seeing it" loop in Red Letter Issues #2 through #7.
    FLEET-006 makes the fix possible; this gap is wiring it in. Update
    the trigger prompt to run 'chump-coord watch' (or equivalent
    NATS-subscription primitive) so peripheral vision is actually
    cross-machine.
  acceptance_criteria:
    - Cold Water trigger prompt subscribes to chump.events.> at session start
    - Subscription persists for at least 60 seconds before evidence-gathering begins
    - If NATS is unreachable, prompt logs the fact and continues with file fallback
    - Next Cold Water cycle Status of Prior Issues block cites NATS-observed activity, not just file tail
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 629

- id: FLEET-018
  domain: FLEET
  title: Audit all scheduled remote agents for NATS ambient subscription wiring
  status: done
  priority: P1
  effort: xs
  description: |
    FLEET-017 covers Cold Water specifically. There may be other
    scheduled remote triggers (gardener, journalist, tech writer per
    project_doc_infrastructure.md, plus any one-off triggers the operator
    has set). All of them face the same blindness FLEET-017 describes -
    they cannot see local agent activity unless they subscribe to NATS.
    Sweep RemoteTrigger list, audit each prompt, and either wire NATS
    in or document why a given agent is intentionally local-only.
  acceptance_criteria:
    - List every active scheduled remote trigger (RemoteTrigger action=list)
    - For each, classify - needs cross-machine ambient (yes/no) and current state (subscribed/not)
    - Update prompts of yes/not-subscribed agents to add chump-coord watch
    - Document the audit result in docs/AGENT_COORDINATION.md
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 635

- id: FLEET-019
  domain: FLEET
  title: Ambient-on-spawn matrix wiring umbrella — auto-inject stream into every new agent
  status: done
  priority: P1
  effort: m
  description: |
    Umbrella for ambient-on-spawn matrix wiring: every new Claude/chump agent immediately taps into .chump-locks/ambient.jsonl + cross-machine NATS stream as system context, not via manual tail per CLAUDE.md. Builds on FLEET-004 (write side) and FLEET-006 (NATS bridge); fills the read-on-spawn injection gap and adds PreToolUse re-injection at flow points + a one-command installer.
  acceptance_criteria:
    - FLEET-020 SessionStart auto-injection lands
    - FLEET-021 PreToolUse re-injection lands
    - FLEET-022 install-ambient-hooks.sh exists and is idempotent
    - new chump-orchestrator-dispatched agents inherit hooks via shared user settings dir
  closed_date: '2026-05-01'
  closed_pr: 696

- id: FLEET-020
  domain: FLEET
  title: ambient-context-inject.sh — SessionStart hook injects last 30 events + active leases as system context
  status: done
  priority: P1
  effort: s
  description: |
    scripts/coord/ambient-context-inject.sh: tails last 30 events from .chump-locks/ambient.jsonl + lists active leases + emits as Claude Code SessionStart additionalContext JSON. Wired into ~/.claude/settings.json SessionStart hook by FLEET-022 installer.
  acceptance_criteria:
    - script exists and is executable
    - outputs valid Claude Code SessionStart hook JSON with hookSpecificOutput.additionalContext
    - tested via stdin-stub and verified context block appears in a fresh session
  depends_on: [FLEET-019]
  closed_date: '2026-05-01'
  closed_pr: 696

- id: FLEET-021
  domain: FLEET
  title: PreToolUse re-injection of ambient stream at flow points (commit / pr / gap claim)
  status: done
  priority: P2
  effort: s
  description: |
    PreToolUse hook config that re-injects last 10 ambient events when matcher hits flow-point commands (git commit, gh pr, chump gap claim, bot-merge.sh). Catches sibling agents who started after our SessionStart injection.
  acceptance_criteria:
    - matcher pattern catches the 4 flow-point commands
    - context injection script reused (no duplicate logic)
    - disabled with CHUMP_AMBIENT_REINJECT=0 env var
  depends_on: [FLEET-019]
  closed_date: '2026-05-01'
  closed_pr: 696

- id: FLEET-022
  domain: FLEET
  title: install-ambient-hooks.sh — idempotent one-command installer for matrix hooks
  status: done
  priority: P1
  effort: s
  description: |
    scripts/setup/install-ambient-hooks.sh: idempotent one-command installer that merges SessionStart + PostToolUse + PreToolUse + Stop hook entries into ~/.claude/settings.json without clobbering existing hooks. Detects pre-FLEET-019 inline hooks and rewrites them to the new script-based form.
  acceptance_criteria:
    - running twice produces no diff (idempotent)
    - preserves existing non-ambient hooks
    - prints what changed
    - "--dry-run flag prints planned diff without writing"
  depends_on: [FLEET-019]
  closed_date: '2026-05-01'
  closed_pr: 696

- id: FLEET-023
  domain: FLEET
  title: Cold Water sandbox ambient stream empty post-FLEET-019/020/021/022 — install step never executed
  status: open
  priority: P1
  effort: xs
  description: |
    FLEET-017 (closed_pr: 629) was classified FIXED in Issue #8 on the grounds
    that FLEET-019/020/021/022 shipped hook scripts and an installer
    (scripts/setup/install-ambient-hooks.sh). However, .chump-locks/ambient.jsonl
    in the Cold Water remote-sandbox session for Issue #9 contains exactly 2 events —
    both session_start from the Cold Water agent itself. Zero operational events from
    any sibling session. The hooks (ambient-context-inject.sh, ambient-session-end.sh)
    exist on disk but are not wired into ~/.claude/settings.json in the sandbox
    because install-ambient-hooks.sh is never invoked. The MANDATORY pre-flight in
    CLAUDE.md still says `tail -30 .chump-locks/ambient.jsonl` and interprets output —
    but in a fresh remote sandbox that output is always two session_start events.
    FLEET-017's FIXED classification was premature: it shipped the hook infrastructure
    but not the auto-install mechanism that would run the installer in a fresh sandbox
    without operator intervention.
    
    Verified: `tail -50 .chump-locks/ambient.jsonl` output in this session:
      {"ts":"2026-04-26T05:40:41Z","session":"chump-chump-1777182041","event":"session_start"}
      {"ts":"2026-05-02T01:23:50Z","session":"chump-chump-1777685030","event":"session_start"}
    
    Five Cold Water cycles have now produced the same empty-ambient observation.
    FLEET-006 (6 cycles), FLEET-017 (3 cycles, now re-FIXED), FLEET-023 (this cycle).
  acceptance_criteria:
    - Cold Water agent session sees ≥1 non-session_start ambient event from a sibling session within 5 minutes of start
    - "Or: CLAUDE.md preflight section updated to document that ambient is filesystem-local-only in sandbox and no cross-machine signal is expected"
    - "Whichever path: the empty-ambient observation is no longer a silent false negative"
  opened_date: '2026-05-02'

- id: FLEET-14
  domain: fleet
  title: "FLEET dev loop design note: Docker NATS, async-nats integration tests, FLEET-007 first"
  status: done
  priority: P2
  effort: s
  description: |
    Docs-only design note scoping how FLEET-006/007/008 will be developed and tested on a single dev machine before any Pi-cluster deployment. Picks the dev primitives (Docker NATS container on 127.0.0.1:4222), the test approach (async-nats + serial_test, hermetic bucket names, distributed mutex assertion via N concurrent tokio tasks), and recommends starting with FLEET-007 because (a) most prototyped — chump-coord already has the KV-create atomic claim implemented, (b) closes the highest-cost race documented by INFRA-042, (c) acceptance is a single property assertion. No implementation ships in this PR.
  acceptance_criteria:
    - docs/FLEET_DEV_LOOP_DESIGN.md exists and is reachable from FLEET vision docs
    - dev loop is reproducible from the doc (single docker run command)
    - starting gap recommendation is justified against alternatives
  notes: |
    Design-note gap; no code change. Pairs with the INFRA-042 multi-agent stress report which empirically demonstrated the missing distributed mutex.
  source_doc: docs/FLEET_DEV_LOOP_DESIGN.md
  opened_date: '2026-04-25'
  closed_date: '2026-04-25'

- id: FRONTIER-001
  domain: frontier
  title: Quantum cognition prototype — density matrix tool-choice vs classical argmax
  status: done
  priority: P3
  effort: m
  description: |
    Section 3.1: Represent belief states as density matrices; allow superposition of contradictory tool choices until action forces collapse. Hand-roll ~200 lines using nalgebra, not dreamwell-quantum (unstable, low adoption).
  source_doc: docs/CHUMP_TO_COMPLEX.md, docs/ROADMAP_PRAGMATIC.md
  closed_date: '2026-04-16'

- id: FRONTIER-002
  domain: frontier
  title: TDA replacement for phi_proxy — persistent homology on blackboard traffic
  status: done
  priority: P3
  effort: m
  description: |
    Section 3.2: Use persistent homology (Betti numbers) to measure "shape" of information flow across blackboard modules, replacing the current graph density statistic. tda crate (v0.1.0) uses nalgebra + petgraph. Park until labeled session data from phi proxy calibration is available.
  notes: |
    Implementation (src/tda_blackboard.rs, 310 lines) was written and compiled but never wired in — no callsites existed outside the module. Acceptance criterion (correlation with human-judged session quality) was never measured because labeled session data from phi_proxy calibration was never produced. Code removed 2026-04-19 (commit 32bc6e1) as dead weight in production binary. Recoverable from commit a383031 if labeled session data becomes available. Prerequisite before re-introducing: run phi_proxy calibration sweep and produce the labeled dataset this gate requires.
  source_doc: docs/CHUMP_TO_COMPLEX.md, docs/ROADMAP_PRAGMATIC.md
  closed_date: '2026-04-16'

- id: FRONTIER-003
  domain: frontier
  title: Adaptive regime transitions via learned bandit/logistic regression
  status: done
  priority: P3
  effort: m
  description: |
    See COG-003. Listed as frontier because it requires labeled task success data and the online learning component is speculative in quality gain.
  depends_on: [COG-001]
  notes: Duplicate of COG-003 for frontier tracking. One closure closes both.
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: FRONTIER-004
  domain: frontier
  title: Dynamic autopoiesis — temporary workspace merge/split between fleet agents
  status: deferred
  priority: P3
  effort: xl
  description: Same as FLEET-003. Fleet implementation track for workspace merge protocol.
  depends_on: [FLEET-001, FLEET-002]
  notes: Duplicate of FLEET-003 for frontier tracking.
  source_doc: docs/CHUMP_TO_COMPLEX.md

- id: FRONTIER-005
  domain: frontier
  title: goose competitive positioning + Chump differentiation strategy
  status: done
  priority: P1
  effort: m
  description: |
    Block's goose was contributed to the Agentic AI Foundation (Linux Foundation) in Dec 2025 as one of three founding projects. Official AAIF description: "a local-first AI agent framework that combines language models, extensible tools, and standardized MCP-based integration." This is LITERALLY Chump's positioning sentence. Chump is no longer in an empty niche — it's competing with a Linux-Foundation-blessed open-source project backed by Block, AWS, Anthropic, Google, Microsoft, OpenAI. We need a sharper differentiation story than "local agent in Rust." Candidate axes: (a) eval-driven scientific rigor (goose is dev-tooling, not research methodology), (b) Rust + single-binary distribution (goose is Python/TypeScript), (c) cognitive-layer A/B-tested architecture with published harm-channel findings (EVAL-023/025/026 trilogy is rare in the field), (d) multi-agent coordination via worktree+lease+gap registry (goose is single-agent per session).
  notes: |
    Action item from session 2026-04-19 strategic review. The deep research pass needs to actually read goose's architecture docs and run goose locally to compare. Reference: https://github.com/block/goose https://block.github.io/goose/ https://aaif.io/
  source_doc: external (AAIF Dec 2025, Block goose)
  closed_date: '2026-04-19'

- id: FRONTIER-006
  domain: frontier
  title: JEPA / world-models watchpoint — track LeCun AMI Labs as alternate path
  status: done
  priority: P3
  effort: s
  description: |
    Yann LeCun's AMI Labs raised $1.03B at $3.5B pre-money in Mar 2026 (largest European seed ever) to commercialize the JEPA (Joint Embedding Predictive Architecture) world-model thesis: that LLMs cannot reach AGI because they lack causal grounding in physical reality, and that latent-space prediction of action consequences is the alternative path. Chump's bet is on text + tools + memory + cognitive layer — explicitly the LLM scaffolding path. AMI's bet is the antithesis. Both can't be right. We don't need to PIVOT, but we should track AMI's progress quarterly: if their first product ships and works, the architecture conversation shifts and Chump's positioning needs revision. If their first product under-delivers, the LLM-scaffolding thesis is vindicated and Chump sits in a stronger position. Watchpoint, not action item.
  notes: |
    References: https://techcrunch.com/2026/03/09/yann-lecuns-ami-labs-raises-1-03-billion-to-build-world-models/ https://www.latent.space/p/ainews-yann-lecuns-ami-labs-launches Per the 2026-04-19 strategic memo: COMP-005 (multimodal) remains DO-NOT-START. JEPA tracking is intelligence not implementation.
  source_doc: external (AMI Labs $1.03B seed Mar 2026)
  closed_date: '2026-04-20'

- id: FRONTIER-007
  domain: frontier
  title: Cross-agent benchmarking — apply Chump's eval harness to goose, Aider, Claude Code
  status: done
  priority: P2
  effort: m
  description: |
    Chump's run-cloud-v2.py + scoring_v2 multi-axis A/B harness is genuinely differentiated infrastructure. Goose has security and Recipes; it does NOT publish methodologically-rigorous A/B harm findings on its own behavior. By applying Chump's eval harness to goose (and Aider, Claude Code) on the same fixtures Chump tests itself with, we can produce a cross-agent benchmark that no other project is positioned to publish. This converts Chump from "another local agent" to "the measurement layer for the local-agent ecosystem" — a defensible positioning move.
  depends_on: [COMP-009]
  notes: |
    Significant strategic value: makes Chump THE benchmark for the local-agent space. Cost ~$10-20 cloud per benchmark run (4 agents × 3 fixtures × n=50 × 2 cells = 1200 trials × cross-family judges). Wall ~3-4 hours per agent (some are slower than others).
  source_doc: docs/archive/2026-04/STRATEGY_VS_GOOSE.md (FRONTIER-005 follow-up)
  closed_date: '2026-04-20'

- id: FRONTIER-008
  domain: frontier
  title: Audit + remove dead-weight FRONTIER modules (TDA blackboard et al.)
  status: done
  priority: P3
  effort: s
  description: |
    Red Letter Issue #1 named src/tda_blackboard.rs as 310 LOC implementing persistent homology on blackboard traffic with NO callsites outside the module — dead weight shipping in every binary. FRONTIER-002 was the parent gap. Likely other FRONTIER-* modules have similar zero-callsite status (FRONTIER-001 quantum cognition? FRONTIER-003+?). This gap audits all FRONTIER-* modules for callsite count + downstream consumers + A/B-result presence; for any module with zero callsites + zero results, file a removal sub-gap or downgrade the parent FRONTIER-* gap to closed-as-not-needed. Reduce binary size + cognitive overhead.
  acceptance_criteria:
    - "docs/eval/FRONTIER-008-deadweight-audit.md: per-FRONTIER-module table of callsite count, A/B result presence, decision (keep / remove / refactor)"
    - "For any module marked remove: dedicated removal sub-gap with file/function cut list"
    - docs/CHUMP_FACULTY_MAP.md updated to note any FRONTIER work explicitly retired
    - "Cargo dependencies that became unused after removals: drop them too (cargo +nightly udeps if available)"
  notes: |
    P3 — speculative-feature cleanup is non-urgent but real-cost. ~1 day audit + per-module removal PRs. Pairs with REMOVAL-001 in spirit (both are "remove what does not earn its weight").
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-21'

- id: FRONTIER-009
  domain: FRONTIER
  title: JEPA strategic memo section 3 — file orphaned architectural recommendations
  status: open
  priority: P3
  effort: s
  description: |
    docs/STRATEGIC_MEMO_2026Q2.md (FRONTIER-006, done) section 3 contains five
    architectural recommendations: (1) JEPA-inspired world model integration for
    planning, (2) explicit planning loop benchmarked against physical planning tasks,
    (3) multi-modal groundedness path, (4) V-JEPA as perception backbone alternative,
    (5) benchmark Chump against AMI Labs roadmap milestones. FRONTIER-006 closed the
    watchpoint task; none of the five recommendations have follow-up gaps. The memo is
    orphaned research. Flagged in Issues #4 and #6 without correction. Closes when
    each recommendation is either filed as a gap or explicitly declared out-of-scope
    with documented rationale in the strategic memo.
  acceptance_criteria:
    - Each of the 5 section-3 recommendations in STRATEGIC_MEMO_2026Q2.md is either (a) filed as its own gap or (b) marked Decision out-of-scope with reason
    - STRATEGIC_MEMO_2026Q2.md front-matter updated with last_audited 2026-04-26
  depends_on: [FRONTIER-006]
  opened_date: '2026-04-26'

- id: INFRA-001
  domain: infra
  title: Transactional speculation — real per-tool rollback via sandbox_run
  status: done
  priority: P2
  effort: xl
  description: |
    Current speculative execution rolls back in-process state (beliefs, neuromod, blackboard) but external side effects (file writes, CLI commands) are not rolled back. ADR-001 describes routing risky tools through sandbox_run for real rollback capability.
  notes: |
    Decomposed:
      INFRA-001a — observability: count + log unrolled-back side
                   effects per turn so the "product pain" criterion
                   is measurable. Without this we can't tell whether
                   the gate is satisfied.
      INFRA-001b — sandbox_run integration in speculative_execution
                   (gated behind CHUMP_SANDBOX_SPECULATION=1 once
                   INFRA-001a shows pain).
      INFRA-001c — policy doc: which tools route through sandbox
                   (write_file, patch_file, run_cli, git_*).
  source_doc: docs/ROADMAP_POST_PHASE_F.md, docs/ADR-001-transactional-tool-speculation.md
  closed_date: '2026-04-18'

- id: INFRA-001a
  domain: infra
  title: Observability — count side effects from rolled-back speculative branches
  status: done
  priority: P2
  effort: s
  description: |
    First chunk of INFRA-001. Need a metric to know HOW OFTEN we roll back in-process state but leave file-system / external side effects orphaned. Today we silently lose that signal.
  source_doc: src/speculative_execution.rs
  closed_date: '2026-04-17'

- id: INFRA-001a-wire
  domain: infra
  title: Hook tool_middleware to record_unrolled_side_effect on rollback
  status: done
  priority: P3
  effort: xs
  description: |
    INFRA-001a shipped the counter + metrics. tool_middleware (or whichever caller invokes speculative_execution::rollback) needs to walk the rolled-back batch's tool calls and invoke record_unrolled_side_effect for each write tool. Without this wiring the counter sits at 0.
  depends_on: [INFRA-001a]
  source_doc: src/tool_middleware.rs
  closed_date: '2026-04-17'

- id: INFRA-001b
  domain: infra
  title: Speculative execution routes write tools through sandbox_run
  status: done
  priority: P3
  effort: l
  description: |
    Second chunk of INFRA-001. Implement the ADR's plan only AFTER INFRA-001a shows non-trivial unrolled-back side effects in a production trace.
  depends_on: [INFRA-001a]
  source_doc: docs/ADR-001-transactional-tool-speculation.md
  closed_date: '2026-04-18'

- id: INFRA-001c
  domain: infra
  title: Policy doc — which tools opt into sandbox routing
  status: done
  priority: P3
  effort: xs
  description: |
    Third chunk of INFRA-001. Reference list of tools that ARE / ARE NOT routed through sandbox when CHUMP_SANDBOX_SPECULATION=1. Mostly classifies write/read/network tools — pure documentation.
  source_doc: docs/ADR-001-transactional-tool-speculation.md
  closed_date: '2026-04-17'

- id: INFRA-002
  domain: infra
  title: Sandbox hardening — command allowlist, disk budget, CI git requirements
  status: done
  priority: P2
  effort: s
  description: |
    sandbox_run (CHUMP_SANDBOX_ENABLED=1) exists but lacks: allowlist of safe command patterns beyond heuristic_risk High block, max worktree disk budget, documented Mac vs CI git requirements.
  notes: |
    CHUMP_SANDBOX_ALLOWLIST: case-insensitive substring match; rejects non-matching commands with clear Err. CHUMP_SANDBOX_DISK_BUDGET_MB: default 500; post-run du -sk check; warning logged + surfaced in tool output. 4 serial tests (env var isolation). WASM_TOOLS.md: new "Sandbox prerequisites" section documenting CHUMP_SANDBOX_ENABLED, all env vars, Mac vs CI differences, git requirements. Note: CI teardown job remains a nice-to-have but acceptance criteria met.
  source_doc: docs/ROADMAP_POST_PHASE_F.md
  closed_date: '2026-04-16'

- id: INFRA-003
  domain: infra
  title: Multimodal in-process inference — implement after RFC-mistralrs-multimodal Accepted
  status: deferred
  priority: P2
  effort: l
  description: |
    WP-1.5: RFC-mistralrs-multimodal-in-tree.md is Proposed, not Accepted. AxonerAI Message extension + MultimodalModelBuilder path designed but not implemented. Blocks vision input in in-process inference mode.
  notes: Unblock by first accepting the RFC.
  source_doc: docs/HIGH_ASSURANCE_AGENT_PHASES.md

- id: INFRA-004
  domain: infra
  title: Agent governance toolkit integration (WP-7.2)
  status: blocked
  priority: P3
  effort: xl
  description: |
    WP-7.2 blocked until sponsor chooses adopt in WP-7.1 (RFC-agent-governance.md recommends defer adopt) AND security review completed.
  notes: |
    Sponsor decision gates this entirely. Do not start WP-7.2 without WP-7.1 adopt.
    Unblock checklist (when sponsor moves to "adopt"):
      1. Security review per docs/rfcs/RFC-agent-governance.md §1 —
         threat model for in-process vs sidecar boundary.
      2. Narrow API spec (RFC §2): allow/deny + audit_id per tool
         invocation; no dynamic tool discovery without WP-13 gates.
      3. Sidecar contract: protocol (gRPC vs HTTP), schema, retry
         policy, identity (mTLS or shared secret), failure mode
         (fail-closed vs fail-open per CHUMP_AIR_GAP_MODE).
      4. Wire into src/tool_middleware.rs::ToolMiddleware — currently
         the only gate; sidecar call slots in before circuit-breaker.
      5. Audit-trail compatibility — sidecar's audit_id must
         round-trip into the existing chump_tool_calls + chump_audit
         tables.
    
    Until sponsor decision: status stays blocked, no code lands.
  source_doc: docs/HIGH_ASSURANCE_AGENT_PHASES.md

- id: INFRA-005
  domain: infra
  title: Fix pre-push auto-merge guard for recreated branches
  status: done
  priority: P1
  effort: xs
  description: |
    The pre-push Guard 2 (auto-merge armed check) calls `gh pr view --json autoMergeRequest` without checking PR state. When a PR has been squash-merged and the branch is recreated (e.g. claude/COMP-008 hygiene pattern), `gh pr view` returns the old merged PR which still has `autoMergeRequest != null == true`, blocking all new pushes to that branch. Fix: add `state` to the JSON fields and gate the true result on `.state == "OPEN"` so already-merged PRs are treated as no-PR.
  acceptance_criteria:
    - "jq query checks .state == \"OPEN\" before returning true for autoMergeRequest"
    - Recreated branch with old merged PR does not get blocked by Guard 2
    - PR still open with auto-merge armed continues to be blocked
  notes: One-line jq fix in scripts/git-hooks/pre-push line ~42. No Rust changes.
  source_doc: scripts/git-hooks/pre-push
  closed_date: '2026-04-20'

- id: INFRA-006
  domain: infra
  title: Fix vllm-mlx Metal crash on client disconnect mid-inference
  status: done
  priority: P1
  effort: s
  description: |
    When a client disconnects during active non-streaming inference, vllm-mlx triggers a Metal GPU assertion crash ("A command encoder is already encoding to this command buffer" / "Completed handler provided after commit call") that kills the entire server process. Root cause: the disconnect_guard detects the disconnected client and returns, but the active Metal command buffer is still encoding; the assertion fires on the completion handler path after commit. Triggered in practice by ablation sweep --timeout values shorter than actual inference time (~56s for 9B 4-bit model with 20K char system prompt at 3.7 tok/s). Emergency workaround: use --timeout 300+ for all sweeps and clear sessions/cli/cli/messages.json when it exceeds 50 messages. Real fix: catch disconnect in the inference loop before committing the command buffer, or drain/abort the Metal pipeline before returning the disconnect response.
  acceptance_criteria:
    - Client disconnect during inference does not crash the vllm-mlx server process
    - Server remains healthy and serves the next request after a mid-inference disconnect
    - Ablation sweeps with --timeout 60 no longer crash the server
  notes: |
    Crash pattern confirmed 2026-04-20. Workaround: kill all sweep procs, clear sessions/cli/cli/messages.json (was 251 messages / 32KB causing 120s+ inference), restart server, use --timeout 300 for sweeps. Also update doc examples in docs/eval/EVAL-054-perception-ablation.md and docs/CHUMP_AUTONOMY_TESTS.md to use --timeout 300.
  source_doc: logs/vllm-mlx-8000.log
  closed_date: '2026-04-21'

- id: INFRA-007
  domain: infra
  title: Ambient stream firing audit — why FLEET-004 hooks emit nothing despite status=done
  status: done
  priority: P0
  effort: m
  description: |
    FLEET-004a / FLEET-004c / FLEET-005 are all marked status=done but .chump-locks/ambient.jsonl contains only session_start and occasional bash_call events. Expected file_edit, commit, ALERT kind=*, and edit_burst events are NEVER written. 50+ PRs landed today; zero of them appear as commit events in ambient. The orchestrator's monitor loop relies on ambient to distinguish a stalled subagent from an active one; without it, stalls look identical to work. Until this is fixed unattended operation is unsafe because we cannot detect silent agents (ALERT kind=silent_agent never fires either). Diagnose step 1: which git hook / Rust module is SUPPOSED to write commit / file_edit events? Step 2: trace why it is not actually writing (permission? path? feature flag?). Step 3: fix + verify 50 real events in ambient within 10 minutes of normal activity.
  acceptance_criteria:
    - Audit doc docs/eval/INFRA-007-ambient-firing.md identifies the intended emitter path for each event kind (commit, file_edit, bash_call, ALERT kind=*, edit_burst) plus the actual code path
    - At least 3 event kinds (commit, file_edit, ALERT) observed in .chump-locks/ambient.jsonl within 10 minutes of triggering activity
    - FLEET-004a / FLEET-004c / FLEET-005 either re-verified done or reopened with the remaining work identified
    - docs/AGENT_COORDINATION.md ambient-kind table updated to match what actually fires
  notes: |
    Blocker #4 on the 2026-04-20 5-blocker list. Hard prerequisite for any unattended run longer than ~30 minutes. The monitor loop exists, the hooks exist, but end-to-end emission is broken. Expected ~1 day of investigation + fix.
  source_doc: 2026-04-20 strategic review blocker
  closed_date: '2026-04-20'

- id: INFRA-008
  domain: infra
  title: 4h unattended precursor soak test — forcing function for 72h autonomy gate
  status: done
  priority: P2
  effort: m
  description: |
    The 6-8 week autonomy timeline terminates at a 72-hour unattended soak test. That gate cannot be cleared unless blockers #1 (trustworthy eval signal), #3 (cost-routing proven), #4 (ambient stream emitting), and #5 (binary stability) are all near-solved. A 4-hour precursor soak is a cheaper forcing function: it exposes the same failure modes in an afternoon instead of 3 days, lets the team iterate without burning 72h of wall time per attempt, and surfaces a concrete go/no-go for each blocker. Soak definition: chump-orchestrator --watch running unattended for 4 hours against a mixed-gap backlog (infra + eval + docs). Success criteria: (a) at least 1 PR shipped, (b) zero unrecovered binary panics (panic = sev 1 regression), (c) ambient.jsonl shows file_edit / commit / bash_call events throughout (not just session_start), (d) cost stays under $5 (if claude-backend) or $1 (if chump-local+Ollama).
  acceptance_criteria:
    - scripts/soak/run-4h-precursor.sh shell wrapper + watchdog
    - INFRA-007 ambient stream fix complete and verified in soak
    - QUALITY-002 unwrap audit output (at least the triage doc; removals optional at this stage)
    - 1 clean 4h soak run completed with all four success criteria met
    - docs/eval/INFRA-008-soak-run-YYYYMMDD.md per-run report
  depends_on: [INFRA-007, QUALITY-002]
  notes: |
    Deliberate P2 — not pre-requisite work, but pre-requisite-proof work. File now so the forcing function exists in the registry. Do not start implementation until INFRA-007 and QUALITY-002 have at minimum their triage output, otherwise the soak will just fail on known preexisting issues and waste a cycle.
  source_doc: 2026-04-20 strategic review (week-4-8 forcing function)
  closed_date: '2026-04-21'

- id: INFRA-009
  domain: infra
  title: Doc-deletion pre-commit hook — net-zero docs rule for future PR cycles
  status: done
  priority: P3
  effort: s
  description: |
    Red Letter #3 measured docs/ inflation: 66 files (Issue #1) -> 119 (Issue #2) -> 139 (Issue #3), zero deletions or archives across three review cycles. The pattern is not driven by any single PR, it is driven by the default behavior of PRs adding new eval / methodology / retrospective docs without ever removing stale ones. A mechanical counter-pressure would help: a pre-commit rule that any PR touching docs/*.md must either (a) accompany a deletion or archival of another docs/*.md of comparable size, or (b) explicitly acknowledge the addition is a net-new file via a commit-message trailer "Net-new-docs: +1" (so operators can grep the pattern post-hoc).
  acceptance_criteria:
    - scripts/git-hooks/pre-commit amended with a docs-delta check that fires only when docs/*.md files are staged and either (a) a deletion is also staged, or (b) the commit message trailer Net-new-docs +1 is present
    - Not blocking by default (warning only) for one week; turn blocking after 2026-04-28
    - docs/AGENT_COORDINATION.md pre-commit-guards table updated with the new check and bypass envvar (CHUMP_DOCS_DELTA_CHECK=0)
  notes: |
    Advisory P3 — useful hygiene, not a blocker on any path. File now so the pattern has an owner. Can be picked up whenever a sibling agent has a quiet slot.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-20'

- id: INFRA-014
  domain: infra
  title: Duplicate-ID pre-commit guard — block insert of recycled gap IDs
  status: done
  priority: P1
  effort: s
  description: |
    The existing duplicate-ID guard (INFRA-GAPS-DEDUP) catches two entries with the same id in one staged file. The hijack guard catches title/description rewrites on an existing id. Neither catches the case where a commit flips a closed gap back to status:open under the same id — effectively recycling the id for new work. This gap adds a recycled-ID check that compares each id's status between origin/main and the staged file and rejects done->open transitions.
  acceptance_criteria:
    - "scripts/git-hooks/pre-commit rejects a commit that flips an id from status:done on origin/main back to status:open"
    - Benign done-gap edits (adding resolution_notes) still pass
    - Genuinely new ids are still accepted
    - CHUMP_GAPS_LOCK=0 bypasses the check
    - scripts/test-recycled-id-guard.sh covers all four cases and passes
  source_doc: CLAUDE.md pre-commit guard table — coverage gap between duplicate-ID and hijack guards
  closed_date: '2026-04-21'

- id: INFRA-015
  domain: infra
  title: Duplicate-ID pre-commit guard — test fixture + CLAUDE.md documentation follow-up
  status: done
  priority: P2
  effort: xs
  description: |
    INFRA-GAPS-DEDUP (PR #176) shipped the duplicate-ID guard in scripts/git-hooks/pre-commit (lines 268-308) and the one-time dedup pass that resolved the 7 collision pairs. Two acceptance items remained unshipped: (a) a test fixture validating the guard behaves correctly, and (b) an explicit row in CLAUDE.md's pre-commit table documenting the guard as a distinct check with its bypass env var. This gap closes both. New file scripts/test-duplicate-id-guard.sh asserts three scenarios: duplicate insert is rejected with a "DUPLICATE GAP ID" error that names the colliding id, legitimate non-duplicate insert is accepted, and CHUMP_GAPS_LOCK=0 bypass works. CLAUDE.md's pre-commit guards table gains a "duplicate-ID insert" row pointing at the test script and citing the Red Letter #2 motivation.
  acceptance_criteria:
    - scripts/test-duplicate-id-guard.sh exists, is executable, and all 3 test cases pass
    - Test sets up an isolated fake repo, wires in the pre-commit hook, and verifies reject/accept/bypass paths
    - CLAUDE.md pre-commit guards table has a distinct row for the duplicate-ID insert guard
    - Row names the bypass env (CHUMP_GAPS_LOCK=0) and points at the test script
  depends_on: [INFRA-GAPS-DEDUP]
  notes: |
    Docs-only + test-only. No change to the guard code itself — just closing the paper trail on the remaining acceptance items so the pre-commit test suite covers all five guards on the same footing.
  source_doc: INFRA-GAPS-DEDUP acceptance follow-up (PR
  closed_date: '2026-04-20'

- id: INFRA-016
  domain: infra
  title: Harness timeout hardening — prevent vllm-mlx Metal crash trigger (Chump-side mitigation for INFRA-006)
  status: done
  priority: P1
  effort: xs
  description: |
    INFRA-006 tracks an upstream vllm-mlx bug — mid-inference client disconnects trigger a Metal GPU assertion crash that kills the whole server. The fix is in vllm-mlx's Metal command-buffer path (upstream, out of Chump's reach). This gap ships the Chump-side mitigation: ensure no ab-harness entry point uses a per-trial timeout short enough to disconnect mid-inference. Audit found one remaining unsafe spot: scripts/ab-harness/run-live-ablation.sh was passing --timeout 120, below the empirical inference floor (~56s for a 9B-4bit model with a 20K-char system prompt) + realistic margin. Bumped to --timeout 300 (5× the floor) with an inline comment citing the crash chain. Added a "vllm-mlx Metal crash — why --timeout 300" section to scripts/ab-harness/README-live-ablation.md documenting the crash pattern, why Chump cannot fix it locally, and the recovery procedure (kill sweeps, clear sessions/cli/cli/messages.json, restart server, re-run with --timeout 300). INFRA-006 remains OPEN tracking the upstream fix. This gap closes only the Chump-side trigger-side mitigation and its documentation, so operators don't keep tripping the same bug while upstream is pending.
  acceptance_criteria:
    - scripts/ab-harness/run-live-ablation.sh uses --timeout 300 with inline rationale comment
    - "scripts/ab-harness/README-live-ablation.md has a \"vllm-mlx Metal crash\" section documenting cause, mitigation, and recovery"
    - INFRA-006 remains open with a note that trigger-side mitigation shipped under INFRA-016
    - No other ab-harness doc examples recommend --timeout < 240 against a local vllm-mlx backend (verified by grep)
  notes: |
    Scope bounded deliberately — the Python driver scripts with `timeout: int = 60` targets (run-cross-session-driver, run-longitudinal-driver, run-real-lessons-driver) are calling *cloud* APIs (Anthropic/Together), which don't suffer the Metal crash. Only paths that can hit a local vllm-mlx server needed the bump. docs/eval/EVAL-060-methodology-fix.md:151 is a historical command record and was left untouched.
  source_doc: INFRA-006 (upstream vllm-mlx Metal crash, blocked on waybarrios/vllm-mlx upstream)
  closed_date: '2026-04-20'

- id: INFRA-017
  domain: infra
  title: Fix ab-harness python3 shebang foot-gun — python3 resolves to 3.14 (no anthropic), silently fell back to exit-code scoring
  status: done
  priority: P0
  effort: xs
  description: |
    docs/RESEARCH_INTEGRITY.md warned that python3 resolves to 3.14 on this machine and has no `anthropic` module, causing every ab-harness script using `#!/usr/bin/env python3` to silently fall back to scorer=exit_code_fallback — no real LLM-judge scores, no error message. Red Letter #4 identified this as the methodology foot-gun behind EVAL-069's identical-CI result (acc_A = acc_B = 0.920, CI[0.812, 0.968] both cells — the fingerprint of a scorer awarding the same pass/fail on every trial regardless of agent behavior). The result was then used to retire F3's neuromod aggregate signal in FINDINGS.md as a "methodology artifact." Verified on this machine: `python3 --version` = 3.14.4, import anthropic raises ModuleNotFoundError; `python3.12 --version` = 3.12.13, anthropic 0.96.0 imports cleanly. Fix shipped by this gap: (1) bulk-rewrote `#!/usr/bin/env python3` → `#!/usr/bin/env python3.12` across all 23 ab-harness Python scripts, (2) updated 4 shell-script invocations (scripts/ab-harness/run-live-ablation.sh x2, run-local-v2.sh, scripts/test-status.sh) from `python3 scripts/ab-harness/...` → `python3.12 scripts/ab-harness/...`. Smoke-tested: ./scripts/ab-harness/run-binary-ablation.py --help resolves via shebang and anthropic 0.96.0 imports cleanly on the new path. INFRA-017 closes the foot-gun ONLY — it does NOT re-run EVAL-069 or retroactively validate any prior sweep result. Follow-up gap EVAL-069-REDO will be needed to re-run the aggregate-signal retirement against the fixed instrument per Red Letter #4's recommendation.
  acceptance_criteria:
    - All 23 Python scripts in scripts/ab-harness/ use
    - All shell-script invocations of ab-harness python drivers use `python3.12` not `python3`
    - Smoke test — ./scripts/ab-harness/run-binary-ablation.py --help exits 0 via the shebang path
    - "Smoke test — `python3.12 -c \"import anthropic\"` succeeds (anthropic 0.96.0)"
    - Red Letter
  notes: |
    Scope intentionally narrow — only the shebang and direct caller invocations were changed. Docstring examples inside the scripts (`"Usage: python3 scripts/ab-harness/foo.py ..."`) were NOT rewritten in this PR to keep the diff reviewable; a follow-up docs-cleanup sweep can handle those. The core scoring-reliability regression is closed — every chump-initiated ab-harness invocation now runs under python3.12 with anthropic installed.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-21'

- id: INFRA-018
  domain: infra
  title: Add config/ + secrets paths to .gitignore + pre-commit credential-pattern guard
  status: done
  priority: P0
  effort: s
  description: |
    Red Letter Issue #1 noted config/ is not in .gitignore and a pre-commit hook does not detect credential patterns. The 4 commits that leaked ANTHROPIC_API_KEY and the one that leaked TOGETHER API key all bypassed every existing pre-commit guard because the guards do not look for credential patterns. Fix: add config/, *.env, secrets/, .env.local, .env.production to .gitignore root. Add pre-commit hook that grep for known credential prefixes (sk-, tgp_v1_, AIzaSy, ghp_, github_pat_) on staged file diffs and blocks commit if present.
  acceptance_criteria:
    - Root .gitignore updated with config/, .env*, secrets/, *.key, *.pem
    - "scripts/git-hooks/pre-commit credential-pattern check: regex scan of git diff --cached for sk-[A-Za-z0-9]{20,} | tgp_v1_[A-Za-z0-9_-]{30,} | AIzaSy[A-Za-z0-9_-]{30,} | ghp_[A-Za-z0-9]{30,} | github_pat_[A-Za-z0-9_]{30,}"
    - "On match: block commit with bypass env (CHUMP_CREDENTIAL_CHECK=0) and clear error message naming the offending pattern + line number"
    - docs/AGENT_COORDINATION.md pre-commit-guards table extended with the new check
  depends_on: [SECURITY-001]
  notes: |
    P0 because credential leakage is the worst-case failure mode this project has so far avoided structurally. ~1 hour. Pairs with SECURITY-001 (verify past leaks rotated, prevent future leaks).
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-21'

- id: INFRA-019
  domain: infra
  title: Frozen-worktree target/ purge + AGENT_LOOP anti-stomp protocol
  status: done
  priority: P1
  effort: xs
  description: |
    Two paired fixes from the 2026-04-20 stomp incident:
    (1) bot-merge.sh now rm -rf ./target after writing .bot-merge-shipped. Each frozen worktree was keeping 1.4–9 GB of dead Rust cache; 25 frozen worktrees filled the 460 GB disk and broke bot-merge.sh at clippy with "No space left on device". Guarded with CHUMP_KEEP_TARGET=1.
    (2) stale-worktree-reaper.sh adds a target/ purge pass independent of reap-eligibility — PRs in the merge queue still hold worktrees that no longer need a build cache. Dry-run confirmed 4.9 GB reclaimable.
    (3) docs/AGENT_LOOP.md gains a "Go slow to go fast" anti-stomp protocol: gap-ID reservation checks across open PRs, one-filer-at-a- time for proactive gap-seeding, broadcast-intent before filing Red Letter gaps, never bypass pre-commit hooks with CHUMP_*=0 to clear an error you don't understand. This addresses the collision that produced three distinct INFRA-017 entries on main in a 5-minute window (PR #341 rename, PR #343 Red Letter filing, PR #344 shebang fix) while my own #337 sat open with a fourth meaning.
    Re-files the content originally shipped as INFRA-017 in PR #337 (closed as dirty after the ID space collapsed). No build changes.
  acceptance_criteria:
    - scripts/bot-merge.sh purges ./target after writing .bot-merge-shipped (CHUMP_KEEP_TARGET=1 bypass)
    - scripts/stale-worktree-reaper.sh target/ purge pass runs each launchd cycle
    - docs/AGENT_LOOP.md anti-stomp protocol added ahead of Autonomy section
  notes: |
    Replaces PR #337 (closed dirty). INFRA-017 ID was hijacked three ways on main during the stomp incident.
  source_doc: docs/AGENT_LOOP.md
  closed_date: '2026-04-21'

- id: INFRA-020
  domain: infra
  title: Close concurrent-gap-ID invention hole in process docs + preflight
  status: done
  priority: P0
  effort: s
  description: |
    Three agents independently invented the same next-free gap ID (INFRA-016, then INFRA-017, then INFRA-018) in overlapping sessions. gap-preflight.sh only warned on "not found in gaps.yaml" instead of blocking, so every concurrent inventor passed preflight and shipped conflicting PRs. Fix: (1) gap-preflight.sh hard-fails on unregistered IDs unless CHUMP_ALLOW_UNREGISTERED_GAP=1 is set (escape hatch for the filing PR itself). (2) AGENT_LOOP.md + CLAUDE.md explicit rule: file-then-claim, never file-and-claim in one session. (3) AGENT_LOOP.md Autonomy section updated to make the file-first flow the expectation.
  acceptance_criteria:
    - "scripts/gap-preflight.sh: unregistered ID triggers FAILED=1 with a red error, unless CHUMP_ALLOW_UNREGISTERED_GAP=1"
    - "docs/AGENT_LOOP.md: Rules-that-matter-most table includes the file-first rule with INFRA-016/017/018 link as rationale"
    - docs/AGENT_LOOP.md Autonomy §1 clarifies file-then-claim flow and points at the bypass env
    - CLAUDE.md mandatory-preflight section states the same constraint at the claim step
  notes: |
    P0 because process erosion compounds — every additional week without this guard means more wasted agent-hours on collision PRs + reverts. Small code change, large collision-prevention value.
  source_doc: 2026-04-20 live session — INFRA-016/017/018 collision chain
  closed_date: '2026-04-22'

- id: INFRA-021
  domain: infra
  title: Replace tiny filing PR workaround with scripts/gap-reserve.sh (atomic ID reservation)
  status: done
  priority: P1
  effort: s
  description: |
    INFRA-020 added a "file the gap in its own tiny PR first" rule to stop concurrent ID invention (root cause of the INFRA-016/017/018 collision chain). That rule works but is a workaround — mature trackers (Jira, Linear, GitHub Issues) assign IDs server-side at creation time, not via human protocol. The sequential-ID-in-a-YAML pattern needs a reservation mechanism. This gap adds scripts/gap-reserve.sh <domain> that scans (a) docs/gaps.yaml on main, (b) all open PRs touching gaps.yaml via gh api diff, (c) all live lease files in .chump-locks/ — and prints the next truly-free ID + stamps it into the current session lease as pending_new_gap. gap-preflight.sh treats pending_new_gap claims as reserved. Net flow: one command, no filing PR, filing + work ship in a single PR.
  acceptance_criteria:
    - scripts/gap-reserve.sh <domain> prints the next free ID for that domain considering main + open PRs + live leases
    - "Lease file schema extended with pending_new_gap: {id, title, domain} field"
    - scripts/gap-preflight.sh reads pending_new_gap as a reservation (same treatment as gap_id)
    - "docs/AGENT_LOOP.md + CLAUDE.md updated: replace file-then-claim rule with \"run gap-reserve.sh first\" — keep CHUMP_ALLOW_UNREGISTERED_GAP escape hatch for bootstrap emergencies"
    - "Retrospective test: simulate two concurrent sessions calling gap-reserve.sh INFRA — they must get different IDs"
  depends_on: [INFRA-020]
  notes: |
    P1 — supersedes the INFRA-020 stopgap. Small (~50-80 LOC bash + doc edits). Eliminates the human-protocol burden entirely; the two-PR dance was only ever a band-aid.
  source_doc: "2026-04-20 live session — INFRA-020 postmortem (Jeff: \"are we following best practices here\")"
  closed_date: '2026-04-22'

- id: INFRA-022
  domain: infra
  title: Evaluate gap-store architecture — offline-first, bot-scaffoldable, optional GitHub mirror
  status: done
  priority: P1
  effort: m
  description: |
    docs/gaps.yaml was a reasonable one-person hack and has outgrown its origin: 8000+ lines in one file, merge-conflict-prone, no atomic ID assignment (root cause of INFRA-016/017/018/020/021 chain), no comments/labels/search UX. But the constraints rule out a pure GitHub Issues migration: (a) bots must work fully offline, (b) bots must scaffold themselves and ship products without waiting on a network, (c) avoid vendor lock-in — GH is fine as one view, not the source of truth.
    
    ASSESSMENT.
    The YAML did three jobs well: it is local-first, greppable, and version-controlled. It does four jobs badly: atomic ID assignment, concurrent edit conflicts, scaling past ~5k lines, rich metadata queries. The right architecture preserves the three and fixes the four.
    
    CANDIDATE DESIGNS to evaluate (pick one in the acceptance deliverable):
    
    1. SQLite-in-repo (.chump/gaps.db, checked into git via sqldiff-friendly pragmas + periodic .sql dumps). Pros: atomic writes, rich queries, scales to 100k rows, offline-native, SQL is a lingua franca every bot/LLM knows. Cons: binary-ish in git, diff review harder (mitigated by generated .sql snapshot committed alongside).
    
    2. Per-gap directory (docs/gaps/INFRA/INFRA-022.md with YAML frontmatter + Markdown body). Pros: trivial merge-conflict resolution (each gap is its own file), still greppable with ripgrep, easy for bots to template. Cons: 500+ tiny files, no built-in atomic ID assignment (needs gap-reserve.sh still). Used by Obsidian / Logseq / Dendron — proven at scale.
    
    3. Per-domain split YAML (docs/gaps/eval.yaml, docs/gaps/infra.yaml, etc.). Pros: smallest migration from today. Cons: still has the 8000-line problem within a hot domain, doesn't solve ID assignment.
    
    4. Local JSON-lines + index (docs/gaps.jsonl append-only + docs/gaps-index.md generated). Pros: append is atomic enough that IDs can be assigned via line-number monotonic counter per domain, every tool can read JSONL. Cons: closing a gap means rewriting the file or appending a tombstone event.
    
    STRONG CANDIDATE: #2 (per-gap-file) + a thin scripts/gap-store.sh CRUD wrapper, because it most naturally supports bot scaffolding (spawn a gap by writing one file) and maps 1:1 to GitHub Issues if someone ever wants a mirror.
    
    OPTIONAL GITHUB SYNC LAYER: bi-directional sync via scripts/gap-sync.sh runnable ad hoc, not required for any local workflow. Issues become a read-only human view; the repo remains the source of truth. This keeps offline-first and avoids vendor lock-in.
    
    SCAFFOLDING REQUIREMENT: whatever design is picked, a bot must be able to call scripts/gap-scaffold.sh <domain> <title> and get back (a) a reserved ID, (b) a ready-to-edit gap entry, (c) no possibility of collision with concurrent bots. This is non-negotiable — it is why we are doing this at all.
    
    DELIVERABLE for this gap is a decision memo + migration plan, not the migration itself. That lands as a separate INFRA-023+ if accepted.
  acceptance_criteria:
    - "docs/eval/INFRA-022-gap-store-eval.md: decision memo comparing the 4 candidates on (a) offline fidelity, (b) bot-scaffolding ergonomics, (c) merge-conflict surface, (d) migration cost, (e) GH-mirror compatibility"
    - Memo names a pick + 2-3 phase migration plan (what lands first, what remains for later)
    - "Prototype: a scripts/gap-store-prototype.sh implementing the pick for one domain (INFRA only) — so the team can kick the tires before a full migration"
    - If the pick requires a sync layer, outline the conflict-resolution rules (who wins — local or remote — when both sides edited the same gap)
  depends_on: [INFRA-021]
  notes: |
    P1, effort medium — this is an architectural decision, not a code push. Sequence: ship INFRA-021 (gap-reserve.sh) first so today's fleet stops colliding, then spend a half-day on the INFRA-022 memo + prototype, then decide.
  source_doc: "2026-04-20 live session — Jeff \"is the entire YAML thing dumb\""
  closed_date: '2026-04-21'

- id: INFRA-023
  domain: infra
  title: Rust-native state — SQLite-backed gap store + lease table in the chump binary (collapses INFRA-021 + INFRA-022)
  status: done
  priority: P1
  effort: m
  description: |
    Chump is a Rust project dogfooding its own infra. The natural Rust answer to (a) atomic gap-ID reservation (INFRA-021) and (b) gap-store architecture (INFRA-022) is a single consolidated move: replace the JSON lease files in .chump-locks/ AND docs/gaps.yaml with a SQLite database (.chump/state.db) accessed via sqlx/rusqlite from the chump binary itself. Matches every hard constraint: offline (embedded), bot-scaffoldable (one chump command spawns a gap), no vendor lock-in (SQLite is public domain), no daemon (in-process). Matches the fleet vision (Pi mesh — one SQLite file per node, rsync or git for sync).
    
    WHY THIS COLLAPSES TWO GAPS. INFRA-021 wanted scripts/gap-reserve.sh for atomic IDs; that becomes `chump gap reserve --domain INFRA` backed by `INSERT INTO gaps ... RETURNING id` with a per-domain sequence. INFRA-022 wanted a decision memo on gap-store architecture; the decision is Rust+SQLite because it dogfoods the stack we ship. No memo needed if the prototype lands cleanly.
    
    SCHEMA (first pass, refine in the prototype):
      gaps(id TEXT PK, domain TEXT, title TEXT, description TEXT, priority TEXT, effort TEXT, status TEXT, file_scope TEXT, acceptance_criteria TEXT, depends_on TEXT, notes TEXT, source_doc TEXT, created_at INTEGER, closed_at INTEGER)
      leases(session_id TEXT PK, gap_id TEXT, worktree TEXT, expires_at INTEGER, pending_new_gap_json TEXT)
      intents(ts INTEGER, session_id TEXT, gap_id TEXT, files TEXT)
    
    BOT WORKFLOW after this lands:
      chump gap reserve --domain INFRA --title "..."    # atomic, returns INFRA-NNN
      chump gap claim INFRA-NNN                         # writes lease row
      chump gap preflight INFRA-NNN                     # single SQL query, no file parsing
      chump gap ship INFRA-NNN                          # status=done, closed_at=now
      chump gap dump > docs/gaps.yaml                   # optional export for git-diff review
    
    GIT SYNC STRATEGY. The .db file is binary-ish, so we commit a generated .chump/state.sql dump alongside (deterministic ordering, stable diffs). Agents reading state hit the .db; humans reviewing PRs read the .sql. Merge conflicts in .sql are resolved by re-running `chump gap dump` post-merge. Legacy docs/gaps.yaml kept as an exported read-only view for one release cycle then deleted.
    
    DISPATCH. musher.py becomes `chump musher --pick` (SQL: open + not-leased + no-conflict prefix JOIN against open PRs via gh api cache). Eliminates the YAML parse every call. Faster pick, stricter semantics.
    
    OPTIONAL apalis INTEGRATION (phase 2, not this gap). apalis provides Rust-native job-queue primitives (retries, timeouts, workers) with a SQLite backend. If we want the ambient.jsonl stream to become durable work signals rather than advisory noise, apalis is the off-the-shelf fit. Out of scope for INFRA-023 — flagged so the design leaves room.
  acceptance_criteria:
    - New crate `chump-state` (or module under existing chump bin) with sqlx + SQLite, migrations checked in
    - Schema above implemented + migration from current docs/gaps.yaml and .chump-locks/ JSON files (one-shot importer)
    - "Commands: `chump gap reserve|claim|preflight|ship|dump|list` — all atomic, all single-SQL-transaction"
    - Musher rewritten to query the db instead of parsing YAML (Python script can stay as a thin shim calling `chump musher --pick --json`, or be deleted)
    - "Concurrency test: spawn 10 `chump gap reserve --domain INFRA` in parallel, assert 10 distinct IDs returned, zero errors"
    - docs/AGENT_LOOP.md + CLAUDE.md rewritten to use the new commands; legacy YAML + JSON files marked deprecated for one release
    - "Git-diff story documented: commit .chump/state.sql dump alongside; regenerate post-merge if conflicts"
  depends_on: [INFRA-020]
  notes: |
    P1, effort medium. SUPERSEDES INFRA-021 (delete or close as won't-fix once this lands) and SUPERSEDES INFRA-022 (the decision memo collapses to a commit message). Biggest risk is the git-diff story — SQLite-in-repo is polarizing; the .sql-dump-alongside convention is borrowed from Fossil + Dolt and is well-trodden. Pi-mesh sync is natural (sqlite3 .backup is rsync-friendly; for multi-node coordination, a future FLEET-* gap looks at CRDTs or a thin pub/sub). Rust-native alternatives noted in 2026-04-20 session memo: apalis (job queue w/ SQLite backend) is a phase-2 add-on; redb/sled/fjall are pure-Rust KVs worth revisiting if SQLite's C dep becomes a problem on Pi (spoiler: it won't).
  source_doc: "2026-04-20 live session — Jeff \"what about rust specific options\""
  closed_date: '2026-04-21'

- id: INFRA-024
  domain: infra
  title: apalis research — evaluate Rust-native job-queue for durable multi-agent work
  status: done
  priority: P2
  effort: s
  description: |
    apalis (https://github.com/geofmureithi/apalis) is a Rust-native async job-queue framework with pluggable backends (Redis, Postgres, SQLite, MySQL). Flagged as phase-2 in INFRA-023 because the current lease/preflight/bot-merge flow is advisory — a crashed agent leaves a stale lease that only expires via TTL, retries are manual, and ambient.jsonl is observational not actionable. apalis would upgrade that to durable work: jobs with typed payloads, automatic retries with backoff, worker crash recovery, cron schedules, timeouts, metrics.
    
    QUESTIONS THE RESEARCH MUST ANSWER.
    1. Does apalis's SQLite backend play nicely alongside the INFRA-023 .chump/state.db (one file, two schemas? separate files?) or does it push us to Postgres?
    2. Is apalis's job model a natural fit for Chump's work (gap execution as a durable job, with the worker = a Claude Code session) or does it conceptually mismatch (apalis assumes short-lived jobs, our 'jobs' are 30-min+ agent sessions)?
    3. What does worker registration look like on a Pi mesh? One apalis Worker per Pi, picking from a shared SQLite over NFS? Or per-node DBs with a sync layer?
    4. Maturity: production users, release cadence, breaking-change frequency, Rust MSRV, async runtime coupling (tokio-only?).
    5. Alternatives in the same space: underway (Postgres-only, ruled out for offline), fang, tokio-cron-scheduler (schedule-only), sidekiq-rs. Does apalis actually win?
    6. Integration cost: what's the smallest slice that gives real value? Likely 'migrate bot-merge.sh retries to apalis' or 'migrate stale-pr-reaper.sh cron to apalis'.
    7. What does losing apalis look like? If it goes unmaintained in 18 months, can we rip it out cleanly, or does it shape the DB schema in a way that becomes load-bearing?
    
    DELIVERABLE. docs/eval/INFRA-024-apalis-research.md: memo with a recommend/hold/reject verdict, one 50-LOC proof-of-concept (apalis SQLite worker that runs one trivial Chump job — e.g. 'purge stale leases'), integration-cost estimate, and a concrete phase-2 plan if recommended.
    
    CONSTRAINTS CARRIED FROM INFRA-023. Must stay offline-capable (so Redis/Postgres backends are evaluation-only, SQLite is the target). Must not require a daemon. Must co-exist with INFRA-023's .chump/state.db. Must not add a mandatory new external dependency on a Pi (tokio is already there via the Chump runtime).
  acceptance_criteria:
    - docs/eval/INFRA-024-apalis-research.md with verdict + evidence (all 7 questions above answered)
    - "Proof-of-concept in examples/apalis-poc/ (or scratch crate): one apalis SQLite worker, one registered job, one successful dispatch and completion — total <100 LOC"
    - "Integration-cost estimate: LOC delta + new deps + MSRV impact + any schema changes to the INFRA-023 .chump/state.db"
    - If verdict is 'recommend', file INFRA-025 as the concrete migration gap with sequenced sub-gaps
    - If verdict is 'reject' or 'hold', document the reason so future sessions don't re-litigate
  depends_on: [INFRA-023]
  notes: |
    2026-04-22: Phase 1 audit complete, CLAUDE/AGENTS hygiene added, CI dry-run workflow draft in. Remaining: real publishes, release automation., effort small. Research-only — the output is a memo + PoC, not a migration. Rationale for priority: INFRA-023 (SQLite state) gives us most of the durability wins already (atomic writes, TTL leases, SQL queries). apalis is an upgrade, not a fix. Worth researching because it could replace stale-pr-reaper.sh + bot-merge retry logic + ambient.jsonl consumers with a single typed job model. But we should not commit to it before INFRA-023 ships — the research needs the new DB to reason about integration.
  source_doc: "2026-04-20 live session — Jeff \"we should do apalis research\""
  closed_date: '2026-04-22'

- id: INFRA-025
  domain: infra
  title: Update all Rust crates + publish to crates.io
  status: done
  priority: P2
  effort: m
  description: |
    Chump has ~10 workspace crates (chump-agent-lease, chump-belief-state, chump-cancel-registry, chump-coord, chump-cost-tracker, chump-mcp-lifecycle, chump-messaging, chump-orchestrator, chump-perception, plus mcp-servers/*) that currently live only in the monorepo. Publishing to crates.io gives external visibility, reproducible dependency pinning for downstream users, and forces the hygiene audit that monorepo-only Rust projects usually skip (real version numbers, license files, docs metadata, no path-only deps, MSRV declared). Also dogfoods the 'bots can scaffold products' vision — if our own building blocks aren't on crates.io, a bot spawning a new product can't pull them cleanly.
    
    WORK REQUIRED (per crate, phased).
    
    PHASE 1 — AUDIT.
    - Inventory every publishable crate in Cargo.toml workspace members + mcp-servers/* + wasm/*. Mark each: (a) public-API-shaped (publish), (b) internal-glue-only (keep path-only), (c) dead (remove).
    - For publish candidates: verify package metadata — name uniqueness on crates.io (reserve names now), version, description, license (MIT/Apache-2.0 dual is Rust default; pick one explicitly), repository, readme, keywords, categories.
    - Run `cargo publish --dry-run` per crate; capture errors (path-only deps, missing license file, workspace version inheritance issues).
    
    PHASE 2 — DEPENDENCY MODERNIZATION.
    - `cargo update` + `cargo outdated` audit — capture all major-version bumps needed. Many crates are probably pinned to older tokio/serde/anyhow versions that need updating for crates.io-quality.
    - `cargo +nightly udeps` — remove unused dependencies (bloat reduction, faster builds, fewer advisory surfaces).
    - `cargo audit` — zero RUSTSEC advisories on publish.
    - MSRV declared explicitly (rust-toolchain.toml + package.rust-version), CI green on that version.
    
    PHASE 3 — RELEASE AUTOMATION.
    - release-plz or cargo-release or cargo-smart-release — pick one, wire into CI. release-plz is the current community favourite (automated version bumps + changelogs from conventional commits + PR-gated publishes).
    - Per-crate CHANGELOG.md generated from conventional commits (we already use conventional commit prefixes, so this is cheap).
    - CI gate: `cargo publish --dry-run` on every PR that touches a publishable crate, so breakage is caught at review time not publish time.
    - Publish token stored as CRATES_IO_TOKEN secret, scoped to the publish workflow only.
    
    PHASE 4 — FIRST PUBLISH.
    - Start with the leafmost crate (least internal deps) — probably chump-agent-lease or chump-cancel-registry — to shake out the pipeline on something low-risk.
    - Publish at 0.1.0 (signal: pre-1.0, API may break). Don't publish at 0.0.x — signals 'abandoned' to discoverability ranking.
    - Once leaf works, publish the rest in topo order. Internal deps become crates.io deps in one commit per crate.
    
    RISKS.
    - Name squatting: reserve names on crates.io TODAY (publish 0.0.0 placeholder with a real description) even before Phase 4 to prevent someone else grabbing 'chump-*' namespace.
    - License uncertainty: some files may be missing SPDX headers or have ambiguous provenance. Fix before publish.
    - Public API exposure: any `pub` item becomes a semver commitment. Tighten visibility (pub(crate) where possible) before the first publish.
    - mcp-servers/* binaries probably shouldn't publish as crates (binary crates are noisy on crates.io); package them as optional features or leave as repo-only.
    
    NON-GOALS (for this gap).
    - Rewriting any crate for crates.io consumption (e.g. removing Chump-specific assumptions). That's per-crate follow-up work if discovered during audit.
    - Publishing mcp-servers/* binaries. They stay in the repo unless explicitly decided otherwise.
  acceptance_criteria:
    - "docs/eval/INFRA-025-crate-publish-audit.md: per-crate table (publish/internal/dead, license, MSRV, dry-run status, name-reservation status on crates.io)"
    - All publish-candidate crates pass `cargo publish --dry-run` in CI on every PR touching them
    - "`cargo audit` + `cargo outdated --exit-code 1` green across the workspace"
    - release-plz (or chosen tool) installed + wired into .github/workflows/; first automated release PR lands
    - At least 3 leaf crates published to crates.io at 0.1.0 with CHANGELOGs, readmes, and repository links
    - All 'chump-*' names reserved on crates.io via 0.0.0 placeholders (guards against squatting while the real audit proceeds)
    - CLAUDE.md + AGENTS.md updated with publish-hygiene rules (no path-only deps in publish-candidate crates, conventional commits required for auto-changelog)
  notes: |
    2026-04-22: Phase 1 audit complete, CLAUDE/AGENTS hygiene added, CI dry-run workflow draft in. Remaining: real publishes, release automation., effort medium. Real value = forcing the hygiene audit + unlocking 'bots publishing products' as a capability. Biggest risk is time-sink: per-crate license/metadata/docs polish can burn a week if done maximally. Recommended slicing: Phase 1+2 + name reservation is one PR (audit + deps modernization). Phase 3 (release automation) is a second PR. Phase 4 (actual publishes) is one PR per crate, landed in topological order. Don't try to ship all of this at once — the first leaf publish teaches us what the pipeline actually needs. 2026-04-22: Phase 1 audit memo landed — docs/eval/INFRA-025-crate-publish-audit.md (gap remains open for CI dry-run gate, cargo audit/outdated, release automation, real publishes, name placeholders, CLAUDE/AGENTS hygiene).
  source_doc: "2026-04-20 live session — Jeff \"update all our rust crates and publish them to crates.io\""
  closed_date: '2026-04-22'

- id: INFRA-026
  domain: infra
  title: Distinguish dispatched-agent commits from foreign actors via author identity
  status: done
  priority: P3
  effort: s
  description: |
    Red Letter Issue #1 flagged commits authored by Your Name <you@example.com> as a foreign actor bypassing all coordination guards. The actual culprit was the dispatched-agent default git config used by every orchestrator-spawned subagent, NOT a foreign actor. Misattribution wasted reviewer attention. Fix: dispatched subagents (chump-orchestrator + bot-merge.sh path) should set git author to Chump Dispatched <chump-dispatch@chump.bot> (similar pattern to Cold Water <cold-water@chump.bot>). Then ambient stream + git log + Red Letter can attribute correctly without false alarms.
  acceptance_criteria:
    - crates/chump-orchestrator/src/dispatch.rs sets git author env (GIT_AUTHOR_NAME/EMAIL) before spawning subagent commits
    - scripts/bot-merge.sh similarly sets author identity for its synthetic commits
    - docs/AGENT_COORDINATION.md identity-attribution table updated to list the canonical author identities
    - Future Red Letter runs no longer flag dispatched commits as foreign
  notes: |
    P3 because the misattribution is annoying not dangerous. Small bash + Rust change.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-21'

- id: INFRA-027
  domain: infra
  title: Fix SIGPIPE in gap-claim.sh — silent lease-write failure under set -o pipefail
  status: done
  priority: P2
  effort: xs
  description: |
    scripts/gap-claim.sh line 136 used `git worktree list --porcelain | awk '…exit'` — awk's early exit closes the pipe while git is still writing, SIGPIPE propagates, and under `set -o pipefail` the whole pipeline exits 141. Script terminates before writing the lease file, producing silent claim failures that force callers to fall back to hand-written python3 lease writes (observed twice in one session). Fix: capture git output into a variable first, then run awk against it via herestring — no pipeline, no SIGPIPE race.
  acceptance_criteria:
    - scripts/gap-claim.sh exits 0 and writes the lease file in a fresh linked worktree
    - No regression on the main-worktree refusal guard
  notes: |
    Shipped with the fix in the same PR as the gap entry since the bug blocked normal claim-shipping; xs effort, one-line structural fix.
  source_doc: "Observed 2026-04-21 during autonomous /loop: gap-claim.sh exit 141 + empty .chump-locks/ in removal-003-belief worktree"
  closed_date: '2026-04-21'

- id: INFRA-028
  domain: infra
  title: bot-merge.sh silent-hang under fleet contention — add liveness diagnostics, watchdog timeout, progress banners
  status: done
  priority: P1
  effort: s
  description: |
    scripts/bot-merge.sh is the primary ship pipeline (auto-merge armed since INFRA-MERGE-QUEUE). When it works, it's reliable. When it fails under fleet contention (many parallel worktrees running cargo/clippy, disk pressure, 429 from gh, network flap, rebase conflicts), it fails SILENTLY — long stretches (observed up to 40 min) of zero stdout before the process either hangs forever or exits with 0 but no PR created. Observed twice in the 2026-04-21 agent-loop cycle 5 (RESEARCH-027 ship):
      1. First invocation (background task bhlfxc5as) — 0 bytes
         output, eventually exited 0 with no PR.
      2. Second invocation (foreground bry9tgf1k) — ditto.
      3. Third attempt (bypassed bot-merge via manual
         `git push -u origin <branch> && gh pr create ... && gh pr
         merge --auto --squash`) — worked first try, landed as PR
         #362.
    Root cause is not diagnosed — could be gh CLI rate-limit, a subshell spawning issue, cargo lock contention with sibling worktrees rebuilding serenity, or `set -e` swallowing a soft failure. Without diagnostic output, the agent loop has no way to know bot-merge has failed vs. is still running. This gap ships: (1) **Progress banners** — every major stage of bot-merge (rebase, fmt, clippy, tests, push, gh-pr-create, auto-merge-arm, checkpoint-tag) prints a timestamped banner to stdout. No step should produce silent periods longer than 30s. (2) **Per-stage watchdog** — each stage has a timeout (rebase 60s, fmt 30s, clippy 300s, push 60s, gh 30s). On timeout, dump last 20 lines of any spawned subprocess output and exit non-zero with a clear error. (3) **Liveness heartbeat** — long stages (clippy especially) emit a line every 30s (`[bot-merge] still running clippy: 90s elapsed`) so a parent watcher can distinguish "stuck" from "working hard." (4) **Exit-code honesty** — if any stage fails or is skipped, final exit code must reflect it. The observed "exit 0 with no PR" path is a contract violation. (5) **Manual-fallback runbook** — CLAUDE.md gains a short section documenting the `git push + gh pr create + gh pr merge --auto --squash` bypass path for when bot-merge.sh itself is broken. Already proven workable in cycle 5.
  acceptance_criteria:
    - scripts/bot-merge.sh prints a timestamped `[bot-merge] <stage>...` banner at the start of every major stage
    - No stage produces silent stdout for more than 30s (heartbeat line required on long operations)
    - Each stage has a per-stage timeout with an explicit error on breach
    - "`set -e` path covers every subprocess; `exit 0 with no PR created` is impossible"
    - "CLAUDE.md gains a \"bot-merge.sh recovery — manual ship path\" subsection under the Atomic PR discipline rule, citing the `git push + gh pr create + gh pr merge --auto` fallback"
    - scripts/test-bot-merge-liveness.sh exists; mocks a sibling-contention scenario and verifies the watchdog timeout fires
  notes: |
    P1 because bot-merge.sh is load-bearing for the entire fleet. Silent-fail is the worst failure mode for an agent loop — the loop cannot recover without human intervention. Shipping this unblocks reliable autonomous ship cycles. Scope is explicitly diagnostic-first; no behavior change to the happy path. Dogfoods itself — the first agent to ship this will have used the manual-fallback path in CLAUDE.md to do so.
  source_doc: 2026-04-21 agent-loop observation — 2 RESEARCH-027 bot-merge invocations hung for 20+ min with 0 stdout
  closed_date: '2026-04-21'

- id: INFRA-029
  domain: infra
  title: Architecture-family deny-list for CHUMP_LESSONS_AT_SPAWN_N
  status: done
  priority: P1
  effort: s
  description: |
    EVAL-071 preliminary shows lesson injection hurts DeepSeek-V3.1 correctness (-23pp) while remaining helpful/neutral on Anthropic and neutral on Qwen3-235B. The current CHUMP_LESSONS_OPT_IN_MODELS is a per-model allowlist but has no default family-level safety net — if an operator ships to a new non-Anthropic backend they opt-in model-by-model without evidence. Add CHUMP_LESSONS_DENY_FAMILIES (default "deepseek") that short-circuits injection regardless of opt-in flag. Pair with a log line so operators can see "lessons suppressed — family denied". Unblock by per-family evidence (EVAL-074).
  acceptance_criteria:
    - CHUMP_LESSONS_DENY_FAMILIES env parsed by PromptAssembler
    - "Default value includes \"deepseek\" until EVAL-074 provides a fix"
    - Log at WARN when suppression fires so operator notices
    - Unit test covers deny-list wins over opt-in-model
  depends_on: [EVAL-071]
  source_doc: docs/eval/EVAL-071-halluc-generalization.md
  closed_date: '2026-04-21'

- id: INFRA-030
  domain: infra
  title: "Fleet observability: musher + ambient single-pane status for unattended loops"
  status: done
  priority: P2
  effort: m
  description: |
    Autonomous loops (scripts/agent-loop.sh, Cursor fleet sessions) still lack a single command that answers: which gaps are live-claimed, which PRs are in-flight, and whether ambient is emitting commit/file_edit events. Ship scripts/fleet-status.sh (name flexible) that composes musher --status, gap-lease directory summary, recent ambient tail, and open gh PRs touching docs/gaps.yaml — suitable for human and CI preflight. Document the workflow in docs/AGENT_LOOP.md and docs/CHUMP_CURSOR_FLEET.md.
  acceptance_criteria:
    - scripts/*fleet* status entrypoint exists and exits 0 on a healthy idle repo
    - Emits clear WARN sections when ambient shows only session_start or when no leases but musher shows claimed gaps
    - docs/AGENT_LOOP.md references the script in Checking what's available + Signals sections
    - "Optional: GitHub Actions job dry-run on schedule (advisory) posting artifact — only if rate limits acceptable"
  notes: |
    Queued 2026-04-23. Keep scope read-only; do not turn this into another silent auto-healer without explicit gap.
  source_doc: docs/AGENT_LOOP.md + docs/CHUMP_CURSOR_FLEET.md
  closed_date: '2026-04-21'

- id: INFRA-031
  domain: infra
  title: Document Cursor headless loop parity vs scripts/agent-loop.sh (Claude)
  status: done
  priority: P2
  effort: xs
  description: |
    scripts/agent-loop.sh is validated for Claude Code re-invocation. Cursor headless `agent` sessions can approximate the same loop but differ in auth, tool allowlists, and resume semantics. Add an explicit subsection to docs/AGENT_LOOP.md + docs/CHUMP_CURSOR_FLEET.md describing what is supported today, what is experimental, and the required prompt wrapper for safe gap iteration (including CHUMP_SESSION_ID guidance for parallel Cursor tabs).
  acceptance_criteria:
    - docs/AGENT_LOOP.md subsection compares Claude agent-loop.sh vs Cursor headless path
    - docs/CHUMP_CURSOR_FLEET.md lists required env vars + anti-patterns (no hook bypass)
    - scripts/cursor-cli-status-and-test.sh cross-links from AGENT_LOOP for smoke
  notes: |
    Queued 2026-04-23. XS effort — documentation only unless Cursor CLI gaps force a helper script.
  source_doc: docs/CHUMP_CURSOR_FLEET.md + docs/AGENT_LOOP.md
  closed_date: '2026-04-21'

- id: INFRA-032
  domain: infra
  title: Dual-surface coordination excellence — Cursor + Claude parity for Chump team workflows
  status: done
  priority: P1
  effort: m
  description: |
    Chump already documents Claude-primary autonomous loops (`scripts/agent-loop.sh`, `/loop`, `ScheduleWakeup`) and Cursor-first fleet safety (`docs/CHUMP_CURSOR_FLEET.md`, subagent rules, headless `agent` smoke). Real squads will mix surfaces daily (IDE pair-programming + headless dispatch + Discord `run_cli`). Treat **both** as first-class citizens: equal-depth runbooks, shared invariants (leases, gap-reserve, preflight, bot-merge, merge-queue discipline), and tooling so neither surface is a second-tier path that drifts or bypasses hooks. Complements INFRA-033 (MCP coord) by making the *human + agent* experience symmetric across Cursor and Claude where tool capabilities differ.
  acceptance_criteria:
    - "docs: add a short coordination index (new doc or extend CHUMP_CURSOR_FLEET) that states when to use Cursor vs Claude vs both, with links to AGENT_LOOP, CLAUDE.md, and INTENT_ACTION_PATTERNS"
    - "docs/AGENT_LOOP.md gains a \"Dual-surface team model\" subsection: same coordination bar, different cadence/automation (no false equivalence of /loop vs Cursor)"
    - "docs/CHUMP_CURSOR_FLEET.md gains explicit \"Claude session handoff\" bullets (what a Cursor parent should paste back when a Claude sibling shipped mid-gap)"
    - "scripts: one combined smoke or checklist entrypoint (extend cursor-cli-status-and-test.sh or add scripts/coord-surfaces-smoke.sh) that verifies gap-preflight, gap-claim, musher pick, and chump --briefing from repo root without API keys"
    - .cursor/rules/chump-multi-agent-fleet.mdc (or companion) references the dual-surface index so Cursor agents load parity guidance on every session
    - "Optional: Discord/run_cli doc cross-links dual-surface checklist for delegated runs"
  notes: |
    INFRA-031 closed doc parity for headless loop semantics; INFRA-032 is the product-level "both surfaces are best-in-class" slice. Synergy with INFRA-033 MCP tools — optional follow-on once coord server exists.
  source_doc: User request 2026-04-22 — team will use both Cursor and Claude Code on Chump
  closed_date: '2026-04-21'

- id: INFRA-033
  domain: infra
  title: "chump-mcp-coord: MCP tools for gap preflight, lease introspection, and musher hints"
  status: done
  priority: P1
  effort: m
  description: |
    Fleet agents shell into gap-preflight.sh, gap-claim.sh, and musher.sh. Cursor and other MCP-first clients need a first-class, read-mostly tool surface so partner sessions can coordinate without ad-hoc copy/paste or unsafe YAML edits. Ship crates/mcp-servers/chump-mcp-coord exposing MCP tools that wrap the same invariants as docs/AGENT_COORDINATION.md (leases under .chump-locks/, gaps ledger semantics, no status mutation except via documented human/PR flows). Minimum tool set: gap_preflight, gap_claim_write (lease JSON only), lease_list_active, musher_pick, ambient_tail (read-only last N ambient events). Tools must never rewrite docs/gaps.yaml status fields.
  acceptance_criteria:
    - New crate ships under crates/mcp-servers/chump-mcp-coord with Cargo manifest + README wiring
    - At least five MCP tools with JSON schemas documented in crates/mcp-servers/README.md
    - "Integration smoke: one Cursor session can run gap_preflight + musher_pick against a dev repo without shell"
    - docs/CHUMP_CURSOR_FLEET.md documents how to enable the server for local fleet runs
    - "Security review: tools cannot exfiltrate .env or bypass CHUMP_GAPS_LOCK invariants"
  depends_on: [INFRA-021]
  notes: |
    Queued 2026-04-23 from fleet-hardening plan. Ships after INFRA-028 (bot-merge liveness, done) so operators get one coherent observability story.
  source_doc: docs/CHUMP_CURSOR_FLEET.md + crates/mcp-servers/README.md MCP program note
  closed_date: '2026-04-22'

- id: INFRA-034
  domain: infra
  title: "Cleanup: revert agent debug edits, fix voice-feature thiserror gate, add piped-stdin single-turn"
  status: done
  priority: P3
  effort: xs
  description: |
    Concurrent cursor/opencode agents left uncommitted edits in the main worktree (rule violation): six eprintln!("[*_debug] ...") tracing the skip_tools_first_call path in src/agent_loop/{orchestrator,iteration_controller}.rs and src/local_openai.rs, plus a Cargo.toml `atty = "0.2.14"` dep that is unmaintained (RUSTSEC-2021-0145) and unused (main.rs already uses std::io::IsTerminal). Two of the edits are real fixes worth salvaging: (a) `voice = ["thiserror"]` feature gate + optional thiserror dep — voice.rs already imports thiserror so the voice feature was broken at HEAD; (b) embed_inprocess.rs match→if let clippy cleanup; (c) piped-stdin single-turn mode in main.rs so `echo "hi" | chump` runs one turn and exits. Revert the debug spam, drop atty, salvage the three fixes. Also rename 7 mis-pathed eval-runs archive dirs whose absolute path got doubled into the directory name (handled in a follow-up PR; data is intact).
  acceptance_criteria:
    - src/agent_loop/{orchestrator,iteration_controller}.rs and src/local_openai.rs match origin/main (no eprintln debug)
    - Cargo.toml has no atty dep
    - "Cargo.toml `voice = [\"thiserror\"]` and `thiserror` is an optional dep"
    - "src/main.rs uses std::io::IsTerminal to detect piped stdin and runs a single agent turn before exiting interactive mode"
    - src/embed_inprocess.rs test uses if-let-Ok instead of match
    - cargo check + cargo fmt --check + cargo clippy pass on default features and on --features voice
  source_doc: "CLAUDE.md hard-rule (\"never work in main worktree\") audit, 2026-04-23"
  closed_date: '2026-04-24'

- id: INFRA-036
  domain: infra
  title: Rename mis-pathed eval-runs archive directories
  status: done
  priority: P3
  effort: xs
  description: |
    Seven eval-run archive directories were created with absolute-path-as-name (e.g. `_Users_jeffadkins_Projects_Chump_docs_archive_eval-runs_claude_eval-063-2026-04-22/`) instead of the canonical `eval-NNN-YYYY-MM-DD/` form used by sibling `eval-025-cog016-validation/`. Likely cause: an eval driver was passed an absolute archive root as the run-name argument and slugified the slashes. Data inside is intact (~3.3 MB of binary-judge / cross-judge jsonl logs). Rename to canonical form and commit so the archive index stays consistent.
  acceptance_criteria:
    - No directory under docs/archive/eval-runs/ has a leading underscore prefix or absolute-path slug
    - All seven dirs renamed to eval-NNN-YYYY-MM-DD or infra-NNN-name-YYYY-MM-DD pattern
    - jsonl payload counts match what was in the mis-named dirs (no data lost)
  source_doc: CLAUDE.md audit, 2026-04-23 — 7 untracked dirs whose absolute path got doubled into the directory name
  closed_date: '2026-04-24'

- id: INFRA-037
  domain: infra
  title: "Branch protection: enforce required CI checks (failing PRs are merging to main)"
  status: done
  priority: P1
  effort: xs
  description: |
    PR #451 (tokio-tungstenite 0.24 → 0.28) and PR #453 (wasmtime-wasi 20 → 44) both landed on main with FAILING `test`, `check`, `dry-run (chump)`, and `ACP protocol smoke test` checks, broke `cargo check --bin chump` for ~12 hours, and required emergency revert in INFRA-035 (PR #455). Both were merged manually by the repo admin — the admin override button was clicked despite red CI. The CI itself was working; branch protection just wasn't enforcing required checks.
    Two complementary fixes:
    1. CODE (this PR): tighten dependabot-automerge.yml to PATCH-only.
       Pre-1.0 crates (like tokio-tungstenite at 0.x) use minor bumps for
       breaking changes, so `version-update:semver-minor` is unsafe to
       auto-merge. Patch bumps are the only truly safe class.
    
    2. ADMIN (manual, must be done by jeff in GitHub UI — agents cannot do
       this from a PR):
       - Open: github.com/repairman29/chump/settings/branches
       - Edit the `main` branch protection rule
       - Under "Require status checks to pass before merging", add:
         `test`, `check`, `dry-run (chump)`, and
         `ACP protocol smoke test (Zed / JetBrains compatible)`
       - Make sure "Require branches to be up to date before merging" is checked
       - Make sure "Do not allow bypassing the above settings" is checked
         (this is the box that lets admins override red CI; without it,
         dependabot-automerge.yml's tightening is the only safety net)
  acceptance_criteria:
    - dependabot-automerge.yml only auto-merges semver-patch updates
    - Future dependabot minor bumps (e.g. 0.x → 0.y) require a human review click
    - "ADMIN follow-up tracked: required-checks list updated in branch protection (this PR cannot enforce; needs UI access)"
  source_doc: PRs
  closed_date: '2026-04-24'

- id: INFRA-039
  domain: infra
  title: REMOVAL-003 design + CLAUDE.md PR-size rule update (intent-atomic over file-count)
  status: done
  priority: P3
  effort: xs
  description: |
    Two coupled changes:
    1. docs/eval/REMOVAL-003-design.md — proposal for the actual REMOVAL-003
       work. Audits the 47 callsites across 15 src files + 1 crate, names
       backward-compat constraints (AutonomySnapshot serde), and proposes a
       single atomic codemod-style PR with inline shadow structs for
       backward-compat. Asks for human approval on three design questions
       before code lands.
    
    2. CLAUDE.md — replace the "≤ 5 files per PR" rule with "intent-atomic"
       guidance. The old rule was written when humans were the primary PR
       reviewers; with merge-queue + required CI checks + bot-driven
       mechanical refactors, codemod-style PRs are world-class default.
       Industry analogues: Meta jscodeshift, Google gMock migrations,
       rust-lang `cargo fix --edition` PRs touching hundreds of files.
  acceptance_criteria:
    - docs/eval/REMOVAL-003-design.md committed with audit + PR proposal + approval questions
    - "CLAUDE.md \"Hard rules\" section reflects intent-atomic PR guidance"
    - No code changes (this is design + policy only)
  source_doc: docs/eval/REMOVAL-003-design.md
  closed_date: '2026-04-24'

- id: INFRA-040
  domain: infra
  title: "INFRA-037 correction: required-check list must exclude path-gated workflows"
  status: done
  priority: P2
  effort: xs
  description: |
    INFRA-037 told the human admin to add `check`, `dry-run (chump)`, `test`, and `ACP protocol smoke test` to the required-status-checks list in main branch protection. That guidance was wrong about two of the four:
    - `check` (mistralrs-infer build): only runs when Cargo.toml/Cargo.lock or
      specific src files change — see .github/workflows/mistralrs-infer.yml `paths:` filter.
    - `dry-run (chump)` (Crate Publish Dry-Run): only runs when crates/ or Cargo.toml
      change — see .github/workflows/crates-publish-dry-run.yml `paths:` filter.
    
    Branch protection requires a status report from each required check. When a path-gated workflow is skipped, no status is reported, so the PR sits BLOCKED forever waiting for a check that will never run. Confirmed by PRs #459 and #460, both stuck despite all in-progress checks passing.
    Correct required-check list (workflows that ALWAYS run on every PR, no path gate):
      - `test` ✅  (this is what caught the dependabot incident)
      - `ACP protocol smoke test (Zed / JetBrains compatible)` ✅
      - `audit` ✅
      - `build-and-linkcheck` ✅
      - `changes`, `plan`, `sync-idempotency` ✅ (lightweight, always run)
    
    Path-gated workflows that should NOT be required (they catch real issues but only fire when relevant files change, so they cannot be a blocking gate):
      - `check` (mistralrs-infer)
      - `dry-run (chump)` and the other crates-publish dry-runs
      - `tauri-cowork-e2e`
      - `test-e2e`
    
    ADMIN action (manual UI):
      1. Open https://github.com/repairman29/chump/settings/branches
      2. Edit the `main` branch protection rule
      3. Under "Require status checks to pass before merging", REMOVE:
         `check`, `dry-run (chump)`
      4. Optionally ADD: `audit`, `build-and-linkcheck`
      5. Save
  acceptance_criteria:
    - Branch protection required-checks list contains only always-run workflow checks
    - "PR #459 and PR #460 unblock and merge"
    - Future PRs that change docs/scripts/workflows can pass required checks without touching Cargo files
  source_doc: PRs
  closed_date: '2026-04-24'

- id: INFRA-042
  domain: infra
  title: Multi-agent dogfooding end-to-end test
  status: done
  priority: P1
  effort: m
  description: |
    FLEET vision describes distributed agents coordinating work across a Tailscale network. Haven't proven the system works under real multi-agent load. Scope: Set up 2–3 agents in chump-orchestrator on same machine (or small Pi cluster). Post 3–5 representative gaps. Run for 2–4 hours; observe lease conflicts, ambient stream integrity, work board interaction. Document: what broke? what was slow? what felt brittle? Acceptance: agents can claim and execute gaps independently, lease collisions don't cause data loss, ambient stream records all events, at least one subtask successfully posted and claimed across agents, no silent failures.
  acceptance_criteria:
    - Agents can claim and execute gaps independently without conflicts
    - Lease collisions don't cause data loss or deadlock
    - Ambient stream records all coordination events
    - At least one subtask successfully posted and claimed across agents
    - All errors surfaced in logs (no silent failures)
    - Stress test report documenting bottlenecks or edge cases
  depends_on: [FLEET-006, FLEET-007]
  notes: |
    Critical for validating FLEET concept. Can run after FLEET-006/007 basic implementation.
  source_doc: docs/EVALUATION_PLAN_2026Q2.md
  closed_date: '2026-04-25'

- id: INFRA-043
  domain: infra
  title: Coordination system stress test
  status: open
  priority: P2
  effort: l
  description: |
    Lease collision handling, ambient stream append under 50+ concurrent writes, worktree reaper stability. Unknown failure modes. Scope: Write harness that (1) spawns 10 agents all claiming same gap, verify only 1 succeeds; (2) spawns 20 agents writing 100 events each, verify no lost events; (3) creates 50 stale worktrees, run reaper, verify correct ones removed; (4) verify session TTL auto-expiry within ~60 min.
  acceptance_criteria:
    - Lease collision test passes (10/10 agents, only 1 claim succeeds)
    - Ambient stream test passes (2000 events, 0 lost, no corruption)
    - Worktree reaper test passes (50 worktrees, correct removals, no crashes)
    - Session TTL test passes (lease auto-expires within 65 min)
    - Stress test report identifies bottlenecks, race conditions, edge cases
  depends_on: [FLEET-007]
  notes: |
    Validates coordination system for fleet scale. Defer until FLEET-007 basic implementation.
  source_doc: docs/EVALUATION_PLAN_2026Q2.md

- id: INFRA-044
  domain: infra
  title: AI pre-audit dispatcher + static/license/CVE sweep (cargo-deny, cargo-audit, lychee, clippy-pedantic)
  status: done
  priority: P2
  effort: s
  description: |
    CPO-framing gap, Tier 3 — ship-risk hygiene. Wraps existing tools into scripts/audit/run-all.sh so the static-analysis slice of the expert panel runs as a single agent-invokable command. Scope: (1) dispatcher at scripts/audit/run-all.sh running cargo-deny, cargo-audit, cargo-udeps, cargo-machete, lychee (doc link-rot), cargo clippy --pedantic; (2) output aggregated to docs/audit/findings-YYYY-MM-DD.md with severity tiers; (3) auto-file gaps for critical findings (CVE, license conflict); (4) weekly CI wiring; (5) this gap surfaces only — fixes land as follow-up gaps from findings.
  acceptance_criteria:
    - scripts/audit/run-all.sh exists and runs all six tools
    - Aggregated findings committed to docs/audit/findings-YYYY-MM-DD.md
    - Weekly CI job scheduled
    - At least one dry run produces findings.md on main
    - Critical-severity findings auto-file new gaps
  notes: |
    P2 so it doesn't displace PRODUCT-015/016/017 (Tier 1) or PRODUCT-018/019 (Tier 2). Closes ~50% of reviewer roles
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-24'

- id: INFRA-045
  domain: infra
  title: bot-merge.sh must preserve pending_new_gap across session migration
  status: done
  priority: P2
  effort: s
  description: |
    `scripts/bot-merge.sh` creates its own session lease (via `CHUMP_SESSION_ID=chump-<worktree>-<epoch>`) and calls `gap-claim.sh` under that session. For **new** gaps that were reserved via `scripts/gap-reserve.sh` (which wrote `pending_new_gap: {id, ...}` to the *original* session's lease), bot-merge never copies that reservation into the new lease. Result: the post-rebase preflight runs under the new session, doesn't find the gap on `origin/main` (correct — we're filing it), and doesn't find a `pending_new_gap` on the new session's lease (reservation was on the old session), so preflight fails with "not found in docs/gaps.yaml" and bot-merge exits: "Gap was completed on main while we rebased — nothing left to push." Actual incident: PR #476 (PRODUCT-015, 2026-04-24) — shipped via INFRA-028 manual path instead. Scope: (1) at bot-merge startup, if `$CHUMP_SESSION_ID` differs from the caller's resolved session AND caller's lease has `pending_new_gap`, copy that field into the bot-merge session's lease before calling `gap-claim.sh`; (2) add integration test in `scripts/test-bot-merge-pending-gap.sh` that reserves a gap, writes a stub gap entry + commit, runs bot-merge, and verifies preflight passes post-rebase; (3) document the contract in bot-merge.sh header.
  acceptance_criteria:
    - bot-merge.sh detects when caller's session has a pending_new_gap for the target gap
    - bot-merge.sh migrates pending_new_gap to its own session lease before claim
    - Reproduction via scripts/test-bot-merge-pending-gap.sh (reserve → commit → bot-merge) passes
    - bot-merge.sh header documents the session-migration contract
    - Existing passes (gap already on main) remain unaffected
  notes: |
    Filed from PR #476 incident. Shipped workaround: use INFRA-028 manual path (CHUMP_GAP_CHECK=0 git push + gh pr create + gh pr merge --auto --squash). Fix unblocks the default bot-merge path for any gap reserved via gap-reserve.sh + same-PR filed.
  source_doc: CLAUDE.md
  closed_date: '2026-04-24'
  closed_pr: 482

- id: INFRA-047
  domain: infra
  title: Dependency modernization audit — clear CVEs and security blockers
  status: done
  priority: P1
  effort: m
  description: |
    Audit and upgrade dependencies to clear security vulnerabilities before release-plz integration (INFRA-048). Phase 1 (blocking): fix rustls-webpki CVEs (RUSTSEC-2026-0104/0098/0099/0049) and evaluate RSA timing attack (RUSTSEC-2023-0071). Phase 2: remove deprecated async-std, declare MSRV for publishable crates, add CI job for MSRV verification.
  acceptance_criteria:
    - Upgrade rustls-webpki to ≥0.103.13 for all publishable crates (chump-tool-macro, chump-coord, chump-perception)
    - Evaluate RSA timing attack impact; document decision (keep/migrate)
    - Remove unused async-std dependency
    - Declare MSRV (minimum supported Rust version) in Cargo.toml for each publishable crate
    - Add CI job to verify MSRV using `cargo +nightly msrv`
    - Run cargo-audit, cargo-deny, cargo-udeps; zero RUSTSEC for lib crates
  notes: |
    Serenity 0.12 (Discord support) pulls old rustls 0.22.4 → webpki 0.102.8 (vulnerable). Not used in publishable crates, so doesn't block lib publishing. Documented as technical debt; serenity replacement tracked in PRODUCT-013. RSA 0.9.10 (Marvin attack) is server-side VAPID signing only (non-critical); acceptable as known risk with local-access requirement. async-std removed; unused legacy dependency.
  source_doc: docs/MODERNIZATION_AUDIT.md
  closed_date: '2026-04-24'

- id: INFRA-048
  domain: infra
  title: Queue driver — refresh oldest BEHIND auto-merge PR so branch protection doesn't strand the train
  status: done
  priority: P1
  effort: xs
  description: |
    Branch protection requires PRs to be up-to-date with main, but auto-merge does not auto-rebase. When PR N lands, every other auto-merge-armed PR goes BEHIND. None refreshes itself, so the queue stalls until a human runs `gh pr update-branch` on the oldest. Observed 2026-04-24 — 9 sibling PRs sat BEHIND for ~30 minutes with auto-merge armed and clean CI; nothing landed until manual intervention. Fix: a tiny GitHub Action `queue-driver.yml` triggered on push-to-main and a 5-min cron that finds the oldest BEHIND auto-merge-armed PR and runs `gh pr update-branch`. The backing script `scripts/queue-driver.sh` works the same locally.
  acceptance_criteria:
    - scripts/queue-driver.sh exists, is executable, supports --dry-run and --max
    - Script picks oldest BEHIND PR with autoMergeRequest != null and is not draft
    - .github/workflows/queue-driver.yml runs on push to main + 5-min schedule + workflow_dispatch
    - "Workflow uses concurrency group \"queue-driver\" so two runs don't race"
    - Dry-run smoke test verified locally before ship
  notes: |
    INFRA-046/047 are unrelated (Crate audit, Dependency modernization) and are in flight as PRs #493 / #496. INFRA-048 is the next free ID. The proper long-term fix is to enable GitHub's actual merge queue (`merge_queue` in branch protection); this driver is the cheap interim that survives whether or not the queue ever gets enabled.
  source_doc: CLAUDE.md
  closed_date: '2026-04-24'

- id: INFRA-049
  domain: infra
  title: CI dry-run gate for crate publishing (block on test failure)
  status: done
  priority: P1
  effort: s
  description: |
    Add CI job that runs before release-plz publishes. Verifies all tests pass, cargo-audit is clean, and publishable crates have valid MSRV. Blocks publishing if any check fails. Layer 1.5 of release automation.
  acceptance_criteria:
    - New CI job runs on release-plz PR creation (before publish step)
    - Publishing step is blocked if any test fails
    - Job logs are visible in PR checks
    - Dry-run publishes still work without triggering real publish
  depends_on: [INFRA-048]
  notes: |
    Gating ensures no broken crates ship. Next: INFRA-050 (test first crate publish).
  source_doc: docs/RELEASE_AUTOMATION_PLAN.md
  closed_date: '2026-04-24'

- id: INFRA-050
  domain: infra
  title: First crate publishing test — validate release-plz automation
  status: done
  priority: P1
  effort: s
  description: |
    Execute Layer 1 release automation for the three publishable crates (chump-tool-macro 0.1.0, chump-coord 0.1.0, chump-perception 0.1.0). Run release-plz dry-run to: (1) analyze commits since 0.1.0 via conventional commits; (2) bump versions (fix→patch, feat→minor, BREAKING→major); (3) auto-generate changelogs; (4) create a release PR. Verify: all three crates bump correctly, changelogs are readable, CI gates (test, audit, MSRV check) pass, dry-run PR shows correct behavior before actual publishing in INFRA-051.
  acceptance_criteria:
    - release-plz dry-run creates release PR with correct version bumps
    - Changelogs for all three crates are generated and human-readable
    - Release PR runs CI gates (test, audit, MSRV) successfully
    - dry-run output shows packages ready to publish
    - Document any issues with the release workflow in notes
  depends_on: [INFRA-048]
  notes: |
    P1: validates the end-to-end publishing pipeline before real publishes in INFRA-051+.
  source_doc: docs/RELEASE_AUTOMATION_PLAN.md
  closed_date: '2026-04-24'

- id: INFRA-051
  domain: infra
  title: Enrich lease JSON with agent health signals (heartbeat, last commit, disk usage)
  status: done
  priority: P1
  effort: s
  description: |
    Expand .chump-locks/<session>.json schema to include: last_commit timestamp, last_commit_msg, worktree_disk_mb, process_alive boolean, model name, stage (planning|implementing|testing|shipped), pr_number, commits_this_session. Enables monitoring scripts to detect hung agents, bloated worktrees, stalled PRs. Prerequisite for INFRA-052.
  source_doc: docs/AGENT_COORDINATION.md
  closed_date: '2026-04-25'

- id: INFRA-052
  domain: infra
  title: Queue health monitor — hourly check for blocked PRs and stalled agents
  status: open
  priority: P1
  effort: s
  description: |
    Implement .chump/monitor.sh that runs hourly via launchd/cron. Reads leases, checks gh pr checks for FAILURE/ERROR, detects: (a) PRs in queue >45min with no progress, (b) agents >90min no commits, (c) worktrees >5GB. Outputs to .chump/health.jsonl and .chump/alerts.log. Makes queue state visible.
  depends_on: [INFRA-051]
  source_doc: docs/AGENT_COORDINATION.md

- id: INFRA-053
  domain: infra
  title: Pre-commit guard error messages with recovery hints
  status: done
  priority: P2
  effort: s
  description: |
    When lease-collision guard blocks a commit, show: (1) which session owns the file + which gap, (2) when that session's lease expires, (3) quick recovery steps (rebase, wait, or contact). Currently just "file claimed by X", not helpful. Improves agent UX when collisions happen.
  source_doc: docs/AGENT_COORDINATION.md
  closed_date: '2026-04-25'
  closed_pr: 509

- id: INFRA-054
  domain: infra
  title: Add depends_on field to gap registry (enforce dependency ordering)
  status: done
  priority: P2
  effort: m
  description: |
    Extend gap schema to support: depends_on: [GAP-ID-1, GAP-ID-2]. Orchestrator will not dispatch a gap until all dependencies are done. Prevents "land in wrong order" mistakes. Update YAML schema, SQL schema, gap-preflight.sh logic, and orchestrator dispatch loop.
  source_doc: docs/AGENT_COORDINATION.md
  closed_date: '2026-04-25'

- id: INFRA-055
  domain: infra
  title: SQLite as primary gap store — migrate from YAML source-of-truth
  status: done
  priority: P2
  effort: m
  description: |
    Make .chump/state.db authoritative, not docs/gaps.yaml. Commit state.sql dump for readable diffs. Pre-commit hook validates SQL state hasn't diverged from YAML until full cutover. Speeds up queries, enables audit analysis, eliminates git merge conflicts on gaps.yaml. Final step: deprecate YAML.
  depends_on: [INFRA-054]
  source_doc: docs/AGENT_COORDINATION.md
  closed_date: '2026-04-25'

- id: INFRA-056
  domain: INFRA
  title: queue-driver auto-resolves DIRTY PRs whose only conflict is docs/gaps.yaml
  status: done
  priority: P2
  effort: s
  description: |
    INFRA-048 introduced queue-driver to refresh BEHIND auto-merge PRs. But every gaps.yaml-touching merge cascades the OTHER PRs from BEHIND to DIRTY (mechanical tail-append conflict on the bottom entry). The driver previously skipped DIRTY, leaving humans to manually rebase every queued PR after each merge. Observed today during the INFRA-052 through SECURITY-003 ship train: 3 PRs went DIRTY and required manual intervention, defeating the queue-driver's purpose. INFRA-052 just landed scripts/resolve-gaps-conflict.py — wire it into queue-driver so DIRTY PRs whose ONLY conflict is docs/gaps.yaml get auto-resolved in-place (creates a temp worktree, rebases, runs the resolver, force- pushes). Refuses if any non-gaps file conflicts so real merge conflicts still get human attention.
  acceptance_criteria:
    - queue-driver.sh processes DIRTY auto-merge PRs alongside BEHIND
    - Refuses non-gaps conflicts (resolver exits 3, rebase aborted, PR untouched)
    - Successful resolves force-push the rebased branch
    - "--dry-run reports what it would do without pushing"
    - bash -n queue-driver.sh exits 0
  depends_on: [INFRA-052]
  notes: |
    Closes the loop on the queue-driver's purpose: post-INFRA-056 the queue should fully self-drain after any gaps.yaml-touching merge. Real conflicts (non-append) still block on human attention by design.
  closed_date: '2026-04-25'

- id: INFRA-057
  domain: INFRA
  title: "Serialize OPENAI_MODEL-mutating tests with #[serial(openai_model_env)]"
  status: done
  priority: P2
  effort: xs
  description: |
    Three tests in the chump binary mutate OPENAI_MODEL without serialization: execute_gap::tests::overlay_prepended_for_known_problem_model, execute_gap::tests::overlay_skipped_for_sonnet_baseline, and model_overlay::tests::maybe_overlay_from_env_respects_env. Under cargo's parallel test runner they race: test A sets Qwen, test B reads Qwen as 'prev', sets Sonnet, A reads env (now Sonnet) for prompt build, A's 'overlay must be prepended' assertion fails. The execute_gap.rs comment explicitly called out this race and prescribed the fix (#[serial(openai_model_env)]) but never applied it. Adds the attribute to all three. serial_test crate already a dep.
  acceptance_criteria:
    - cargo test --bin chump overlay passes (16/16)
    - All three tests share
    - "serial_test::serial imported in both test modules"
  notes: |
    Surfaced when this test was the only blocker repeatedly forcing --skip-tests on bot-merge runs. Now removed.
  closed_date: '2026-04-25'

- id: INFRA-058
  domain: INFRA
  title: World-Class Roadmap — file 5-milestone dev workflow upgrade plan
  status: done
  priority: P1
  effort: xs
  description: |
    Files docs/WORLD_CLASS_ROADMAP.md and the M1-M5 tracking gap entries (INFRA-059 through INFRA-063). Tracks the strategic shift from reactive recovery (queue-driver auto-fixing DIRTY, resolve-gaps-conflict.py, --skip-tests bypasses) to proactive prevention (no hot files, plan-mode gate, stacked PRs, feature flags, dashboard). Roadmap doc is the authoritative source; this gap is the meta-tracking entry.
  acceptance_criteria:
    - docs/WORLD_CLASS_ROADMAP.md committed with M1-M5 milestones documented
    - INFRA-059 through INFRA-063 filed as open gaps with acceptance criteria
    - User signed off on roadmap (2026-04-25)
  notes: |
    Each milestone's retirement-of-old-system step must be ticked before the next starts. Sequence is M1 → M2 → M3 (M3 needs M2, M2 needs M1); M4 and M5 can run parallel with M3.
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-059
  domain: INFRA
  title: M1 — SQLite-authoritative gap store (finish INFRA-023)
  status: done
  priority: P1
  effort: m
  description: |
    Flip authority for gap state from docs/gaps.yaml to .chump/state.db (SQLite). YAML becomes a generated artifact, regenerated by `chump gap dump --out docs/gaps.yaml` for human diff review only. All writes go through `chump gap reserve|claim|ship`. Shell script shims (gap-reserve.sh, gap-claim.sh) become thin wrappers or are deprecated. Eliminates the #1 source of merge conflicts in the queue (every PR currently appends to one hot file).
  acceptance_criteria:
    - chump gap reserve + claim + ship round-trip without touching YAML directly
    - docs/gaps.yaml regenerated by chump gap dump matches DB byte-for-byte
    - Concurrent gap-reserve from 5 sessions produces 5 distinct IDs (no collision)
    - Pre-commit hook on docs/gaps.yaml no longer flags routine tail-appends
    - CLAUDE.md + AGENTS.md updated to point at chump gap exclusively
  depends_on: [INFRA-023, INFRA-058]
  notes: |
    Highest leverage milestone — every other M2-M5 step assumes a clean queryable gap store. Ship first.
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-060
  domain: INFRA
  title: M2 — Plan-mode gate in dispatcher (file enumeration + open-PR overlap scan)
  status: done
  priority: P1
  effort: m
  description: |
    New phase between gap-claim and code in `chump --execute-gap` and the orchestrator's dispatch path. Agent enumerates planned files (LLM call, structured output), runs `gh pr list --json files` overlap scan, aborts if ≥2 open PRs touch any planned file (queue too crowded — pick another gap). Otherwise writes `.chump-plans/<gap>.md` with file list + conflict score + 5-line design summary. Plan auto-attaches to PR description at bot-merge.sh time.
  acceptance_criteria:
    - chump --execute-gap produces .chump-plans/<gap>.md before any code edit
    - Synthetic test (2 dummy PRs touching src/foo.rs + dispatch gap touching foo.rs) aborts cleanly with no commits
    - Plan body appears verbatim in PR description after bot-merge
    - Cost <0.10 per dispatch (Sonnet/Haiku call)
  depends_on: [INFRA-058, INFRA-059]
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-061
  domain: INFRA
  title: M3 — Stacked-PR dispatcher (--stack-on for related work)
  status: done
  priority: P2
  effort: m
  description: |
    bot-merge.sh --gap X --stack-on <prev-gap> for related work. Stacked PR's base branch is prev PR's head, not main. When prev lands, merge queue auto-rebases stacked descendants. Modeled on Graphite/Sapling/ghstack; one-deep stacks cover the common dispatcher case. Eliminates the parallel fanout pattern where 5 related PRs all touch the same files.
  acceptance_criteria:
    - bot-merge.sh --stack-on INFRA-XYZ opens PR with base=claude/<prev>
    - Landing prev PR triggers auto-rebase of stacked PR (verified end-to-end)
    - chump gap reserve --stack option emits --stack-on for dispatcher
    - AGENTS.md documents the stack pattern
  depends_on: [INFRA-058, INFRA-059, INFRA-060]
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-062
  domain: INFRA
  title: M4 — Feature flags for COG-* (kill long-lived cognitive branches)
  status: done
  priority: P1
  effort: l
  description: |
    src/runtime_flags.rs with CHUMP_FLAGS=cog_040,cog_041 env parsing at startup. `if flags::is_enabled(\"cog_040\")` gates around new behavior. Default policy: off until cycle review + bench confirmation, then on, then cleanup PR removes the flag. Bench harness runs flags-off baseline vs flags-on candidate per benchmark; COG reflection rows tag the flag set under test. Modeled on Google/Meta trunk-based dark-launch. Eliminates rebase tax on cognitive work.
  acceptance_criteria:
    - "runtime_flags::is_enabled reads CHUMP_FLAGS env correctly"
    - Two real COG-* gaps shipped using the flag pattern (replacing >3-day branches)
    - cargo bench produces flag-on vs flag-off rows
    - CLAUDE.md Hard Rules updated; long COG branches forbidden
  depends_on: [INFRA-058]
  notes: Parallelizable with M3 — independent code paths.
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-063
  domain: INFRA
  title: M5 — Cycle-time dashboard + cost-routed dispatcher
  status: done
  priority: P2
  effort: s
  description: |
    `chump dashboard` reads reflection rows + git log + `gh pr list` to print PRs landed today/week, median cycle-time gap-claim → main, rebase-minutes burned, dispatcher backend cost split, top 5 stale worktrees. Cost-routed dispatch: router picks backend by gap class (trivial xs → Together free tier; design P1 l/xl → Opus; refactors → Sonnet). Preserves manual override.
  acceptance_criteria:
    - chump dashboard prints all listed metrics from real data
    - Dispatcher logs show per-gap backend selection rationale
    - One week operation shows ≥40% of dispatches on cheap tier without quality regression
  depends_on: [INFRA-058]
  notes: Independent of M2-M4. Can ship anytime after M1.
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-064
  domain: INFRA
  title: Fix gaps.yaml duplicate-field corruption from merge collisions
  status: done
  priority: P1
  effort: s
  description: |
    Cumulative tail-append merge collisions across PRs #498 (INFRA-049), #494 (INFRA-BOT-MERGE-HEREDOC), #500 (INFRA-050), #508 (INFRA-052), and #512 (INFRA-055) left docs/gaps.yaml with five gaps reduced to title-only stubs whose bodies were either misattributed under the next neighboring `- id:` header or stranded as orphaned mappings appended to the bottom of unrelated entries. Net effect: serde_yaml rejected the file with `gaps[336]: duplicate field depends_on at line 10195`, causing chump-orchestrator's cli_smoke `dry_run_against_real_backlog_exits_zero_and_picks_at_least_one` test to fail and silently forcing every recent bot-merge.sh ship to use --skip-tests. Reconstructed each gap by cross-referencing the originating PR diffs, restoring proper - id / domain / status / description / acceptance_criteria / depends_on structure.
  acceptance_criteria:
    - python3 yaml.safe_load(docs/gaps.yaml) succeeds
    - cargo test -p chump-orchestrator --test cli_smoke passes (all 4 tests)
    - "No two gap entries share an id (grep `^- id:` uniq check)"
    - INFRA-047, INFRA-048, INFRA-049, INFRA-050, INFRA-052, INFRA-055, INFRA-BOT-MERGE-HEREDOC each have non-stub bodies with description and acceptance_criteria
    - bot-merge.sh ship runs without --skip-tests
  notes: |
    Root cause is that PRs adding gap entries by inserting a new `- id:` block immediately above an existing entry's body — combined with subsequent rebases that tail-append conflicting tails — silently detach bodies from headers. INFRA-052's resolve-gaps-conflict.py only handles the pure tail-append case, not the in-place insertion variant. Long-term mitigation: enforce that gap entries are always tail-appended (never inserted in the middle), and add a YAML lint to pre-commit that runs serde_yaml-strict parsing.
  closed_date: '2026-04-25'

- id: INFRA-065
  domain: INFRA
  title: Wire select_backend_for_gap into orchestrator dispatch path
  status: done
  priority: P2
  effort: xs
  description: |
    INFRA-063 (M5) added select_backend_for_gap() as an advisor function but left the orchestrator's actual dispatch path reading CHUMP_DISPATCH_BACKEND directly in two places (RealSpawner::spawn_claude and DispatchHandle.backend), so the cost-router's rationale never actually drove which backend got spawned. This gap closes that loop: DispatchBackend::resolve_for_gap(priority, effort) is the single resolution point — env wins when set, otherwise advisor pick — and Spawner::spawn_claude takes the resolved backend as a parameter. Adds an explicit "[dispatch] route gap=… → backend=… reason=…" log line on every dispatch so cost-split telemetry has structured input.
  acceptance_criteria:
    - "DispatchBackend::resolve_for_gap implemented with env-overrides-advisor precedence"
    - Spawner trait takes backend as a parameter; RealSpawner uses it instead of calling from_env() inside spawn_claude
    - "dispatch_gap_with logs \"[dispatch] route gap=… → backend=… reason=…\" on every spawn"
    - Existing CHUMP_DISPATCH_BACKEND env override behavior preserved (operator override always wins)
    - Unit tests cover env-wins, advisor-when-unset, and unknown-env paths
  depends_on: [INFRA-063]
  notes: |
    Stacked on M5 (PR #521). After both land on main, the COG-026 A/B aggregator can split outcomes by dispatch reason (env vs advisor rule) — measuring whether the rule-based router actually routes work to the cheap tier without quality regression (M5 acceptance #3).
  source_doc: docs/WORLD_CLASS_ROADMAP.md
  closed_date: '2026-04-25'

- id: INFRA-066
  domain: infra
  title: CI guard — fail PR if title implies gap close but gaps.yaml still open
  status: done
  priority: P1
  effort: s
  description: |
    QUALITY-005 audit (2026-04-25) found 7 of 31 "open" gaps had already shipped on main but never had `status: open → done` flipped in docs/gaps.yaml. ~22.6% stale-status rate. The fix is a CI check: if a PR title matches `^<GAP-ID>:` (e.g. "INFRA-047: foo"), verify that the PR's diff sets `status: done` (or that gaps.yaml already shows done) for that ID. Fail the PR if not. Closes the loop the existing pre-commit gaps.yaml-discipline guards leave open — those guards block *invalid* mutations but don't *require* a status flip.
  acceptance_criteria:
    - "Check fails the PR if gaps.yaml does not show status:done for that ID after the diff is applied"
    - Bypass label `gap-cleanup` (or similar) for PRs that legitimately reference but don't close a gap
    - Test/dry-run on one in-flight PR before enabling required-check
  notes: |
    Filed by QUALITY-005 audit. Without this guard the audit has to re-run weekly. Cheap to implement — a single shell check in an existing workflow + the bypass label.
  source_doc: docs/eval/QUALITY-005-gap-hygiene-audit.md
  closed_date: '2026-04-25'

- id: INFRA-067
  domain: infra
  title: Repo hygiene plan (scripts/, crates+src/, top-level, workflows)
  status: done
  priority: P2
  effort: m
  description: |
    Companion to DOC-005. Same shape applied to the rest of the repo: Area #1 scripts/ gets a 5-phase classify-inventory-automate-cleanup- generate treatment (255 scripts, mirrors DOC-005); Area #2 crates/+src/ gets a one-shot dead-code audit (cargo udeps + cargo machete + manual orphan-module review); Area #3 top-level+config gets a one-shot security audit (gitignore + scattered-config consolidation, triggered by the Together.ai key leak); Area #4 .github/workflows/ gets a one-shot stale-job consolidation. Sub-gaps INFRA-068..075 will be filed as each phase/area is picked up.
  acceptance_criteria:
    - docs/REPO_HYGIENE_PLAN.md committed
    - INFRA-067 entry in gaps.yaml
    - sequencing + scope explicit (4 areas, sub-gap shapes named)
  source_doc: docs/REPO_HYGIENE_PLAN.md
  closed_date: '2026-04-25'

- id: INFRA-068
  domain: INFRA
  title: Doc flip — chump gap is canonical, gaps.yaml demoted to regenerated mirror
  status: done
  priority: P1
  effort: xs
  description: |
    INFRA-059 (M1, shipped 2026-04-25) flipped authority from docs/gaps.yaml to .chump/state.db, but CLAUDE.md and AGENTS.md still framed gaps.yaml as the master registry and instructed agents to grep/edit it directly. INFRA-059's commit body explicitly deferred this doc flip to a separate intent-atomic PR.
    This gap updates CLAUDE.md and AGENTS.md so:
      - chump gap subcommands are presented as the primary interface
      - .chump/state.db is named as canonical
      - docs/gaps.yaml is described as a regenerated human-readable mirror
      - chump gap ship --update-yaml is the sanctioned path for closing gaps
      - .chump/state.sql is documented as the readable SQL diff
      - Legacy shell scripts (gap-*.sh) are kept as fallbacks but no longer
        framed as the primary path
  acceptance_criteria:
    - CLAUDE.md mandatory pre-flight uses chump gap list (legacy grep marked optional)
    - CLAUDE.md coordination-docs bullet lists state.db, gaps.yaml, state.sql with correct roles
    - AGENTS.md docs table demotes gaps.yaml description and adds state.db / state.sql rows
    - "AGENTS.md \"How to claim work\" leads with chump gap commands"
    - AGENTS.md ship instruction points to chump gap ship --update-yaml
  depends_on: [INFRA-059]
  source_doc: CLAUDE.md
  closed_date: '2026-04-25'

- id: INFRA-069
  domain: INFRA
  title: "Serialize CHUMP_LOCAL_BIN dispatch tests with #[serial(chump_local_bin_env)]"
  status: done
  priority: P2
  effort: xs
  description: |
    Two tests in chump-orchestrator dispatch.rs mutate CHUMP_LOCAL_BIN without serialization:
      - resolve_chump_local_bin_honors_env_override (sets it)
      - resolve_chump_local_bin_falls_back_to_path_when_no_target (removes it)
    Under cargo's parallel test runner they race: A sets the var, B's remove_var lands while A is mid-assertion → A reads "" → returns "chump" instead of "/opt/custom/chump". Caught when this test was the lone blocker on PR #509 (INFRA-053). Same bug class as INFRA-057 (OPENAI_MODEL race); same fix shape — add #[serial_test::serial(chump_local_bin_env)] to both tests. serial_test crate is already a chump-orchestrator dep (other tests in this module already use it on the resolve_for_gap_* family).
  acceptance_criteria:
    - cargo test -p chump-orchestrator --lib resolve_chump_local_bin passes both
    - Both tests share
  depends_on: [INFRA-057]
  notes: |
    Surfaced when PR #509 hit this race after the OPENAI_MODEL race was fixed. Audit needed: any other tests setting/removing process env vars without #[serial] are racing — file follow-up gaps as they appear.
  source_doc: crates/chump-orchestrator/src/dispatch.rs
  closed_date: '2026-04-25'

- id: INFRA-070
  domain: INFRA
  title: "chump gap reserve: silent ID collision when DB and gaps.yaml have drifted"
  status: done
  priority: P1
  effort: s
  description: |
    `chump gap reserve --domain D` can return an ID that already exists in `docs/gaps.yaml` when the local `.chump/state.db` is out of sync with the YAML mirror. Observed during DOC-005 Phase 0 (2026-04-25): `chump gap reserve --domain DOC` returned DOC-005 (an existing open gap), and the subsequent INSERT either succeeded (because the DB row was missing) or silently mutated the existing row's title.
    Root cause (suspected): `GapStore::reserve` (src/gap_store.rs:287) seeds the per-domain counter from `MAX(existing IDs in gaps table)` on first reserve for that domain. If the DB is missing rows that exist in the YAML — which happens after any hand-edit to gaps.yaml without a follow-up `chump gap import` — the counter starts low and reserve returns IDs that collide with the YAML.
    `import_from_yaml` uses `INSERT OR IGNORE`, so it doesn't backfill after the fact unless re-run. The reserve path does not auto-import.
  acceptance_criteria:
    - reserve cannot return an ID that exists in either gaps.yaml OR state.db
    - "regression test: hand-add a gap to YAML, do not import, then reserve; assert returned ID is strictly greater than the YAML max"
    - clear error message (or auto-import) when drift detected
    - reserve cannot return an ID that exists in either gaps.yaml OR state.db
    - regression test — hand-add a gap to YAML, do not import, then reserve; assert returned ID is strictly greater than the YAML max
    - clear error message (or auto-import) when drift detected
  notes: |
    Suggested fix: have `reserve` consult both the YAML max and the counter row max, taking the maximum of both. Alternative: have `reserve` call `import_from_yaml` first (cheap — INSERT OR IGNORE). Filed by INFRA-042 author after DOC-005 Phase 0 subagent (PR #537) flagged it. Patched locally via direct sqlite UPDATE; no upstream fix yet.
  source_doc: src/gap_store.rs
  opened_date: '2026-04-25'
  closed_date: '2026-04-26'

- id: INFRA-071
  domain: INFRA
  title: Sync book/src frontmatter from docs/ after DOC-006 inventory drift
  status: done
  priority: P2
  effort: xs
  description: |
    DOC-006 (PR #531, Phase 1 of doc hygiene plan) added YAML frontmatter (doc_tag, owner_gap, last_audited) to top-level docs/*.md files but did not run scripts/sync-book-from-docs.sh, leaving the published book/src/*.md copies stale. The mdbook-verify workflow's sync-idempotency job catches this on every PR that touches docs/**, blocking unrelated work (PR #509 INFRA-053 was the canary). Runs sync-book-from-docs.sh and commits the propagated frontmatter so the drift is closed and PRs touching docs/ can land again.
  acceptance_criteria:
    - sync-idempotency job passes after this PR lands
    - book/src/*.md files contain matching frontmatter for the 9 affected pages (chump-to-complex, getting-started, metrics, oops, operations, project-brief, research-integrity, roadmap, rust-infrastructure)
  depends_on: [DOC-006]
  notes: |
    Mechanical sync; no content change beyond frontmatter propagation.
  source_doc: scripts/sync-book-from-docs.sh
  closed_date: '2026-04-25'

- id: INFRA-072
  domain: INFRA
  title: code-reviewer-agent.sh awk regex SIGPIPE — broke auto-merge on every src/* PR
  status: done
  priority: P1
  effort: s
  description: |
    The awk extraction at line 109 used /^  - id:/ (two leading spaces), expecting indented YAML. But docs/gaps.yaml top-level gap entries start at column 0 (`- id: ...`). The regex never matched, so awk processed all 11k lines after the target gap. Pipelined into `head -80`, awk SIGPIPE'd on writes past line 80. Under `set -euo pipefail`, the script exited 141, which bot-merge.sh interpreted as "code-reviewer agent errored — auto-merge NOT enabled". Observed on PR #542 (FLEET-007); auto-merge had to be armed by hand. Likely affected most prior src/* PRs too.
  acceptance_criteria:
    - awk regex matches top-level gap entries (no leading spaces)
    - regression test asserts code-reviewer-agent.sh --dry-run exits 0 for a real --gap whose entry lives past line 80 of gaps.yaml
  notes: |
    Two-line fix in code-reviewer-agent.sh + a new scripts/test-code-reviewer-agent.sh covering the regression. The other latent SIGPIPE candidates (line 173 head -c 80000, line 269 grep | head -1) were not the cause for PR #542 (diff was 17KB; the API response was a single verdict line) but remain theoretically exposed for future big-PR or chatty-API edge cases. Left for a follow-up if they bite.
  source_doc: scripts/code-reviewer-agent.sh
  opened_date: '2026-04-25'
  closed_date: '2026-04-25'

- id: INFRA-073
  domain: INFRA
  title: Gap-closure hygiene audit — close 8 OPEN-BUT-LANDED gaps
  status: done
  priority: P1
  effort: xs
  description: |
    Cold Water Issue #6 (2026-04-26) OPEN-BUT-LANDED sweep found 8 gaps with commits
    on origin/main referencing their IDs while remaining status: open — FLEET-006
    (1 commit), EVAL-074 (1 commit), PRODUCT-017 (1 commit), SECURITY-002 (1 commit),
    REMOVAL-005 (1 commit), DOC-005 (4 commits), INFRA-068 (1 commit), INFRA-070 (2
    commits). The gap registry status: open signal is now a mixture of "never started"
    and "partially executed without closure." Agents reading the open gap list cannot
    distinguish these two states. For each of the 8 gaps: verify whether the referenced
    commits satisfied the acceptance criteria; if yes, close via chump gap ship; if no,
    add a comment documenting the missing AC so future agents know work remains.
  acceptance_criteria:
    - Each of the 8 OPEN-BUT-LANDED gaps is either closed or has an explicit note documenting which acceptance criteria remain unmet
  opened_date: '2026-04-26'
  closed_date: '2026-04-25'

- id: INFRA-074
  domain: INFRA
  title: audit AGENTS.md/CLAUDE.md drift — fix guard counts and stale claims
  status: done
  priority: P2
  effort: xs
  description: |
    Boot-loaded docs (AGENTS.md, CLAUDE.md, pre-commit hook header) had drifted from current code in ways that would mislead agents: (1) all three claim "five pre-commit guards" but the hook actually runs eight numbered jobs (lease, stomp, gaps-discipline, submodule, fmt, cargo-check, docs-delta, credential) plus four sub-checks inside the gaps.yaml block (hijack, duplicate-ID, recycled-ID, preregistration); (2) the CLAUDE.md guard table omitted submodule, docs-delta, credential, and recycled-ID rows entirely; (3) the wrong-worktree guard was filed under the pre-commit table but actually lives in chump-commit.sh — agents using raw `git commit` don't get it; (4) gap-reserve.sh recommendation lacked the INFRA-070 unpadded-ID warning agents kept hitting; (5) pre-commit hook header had duplicate "6." numbering. AGENTS.md also still said "≤ 5 commits and ≤ 5 files per PR" which contradicts CLAUDE.md's intent-atomic guidance.
  acceptance_criteria:
    - CLAUDE.md guard table has a row for every guard in pre-commit + chump-commit.sh
    - CLAUDE.md and AGENTS.md no longer claim a guard count that doesn't match the table
    - "pre-commit hook header re-numbered (no duplicate \"6.\") with all 8 jobs listed"
    - gap-reserve.sh recommendation flags the INFRA-070 unpadded-ID footgun
    - "AGENTS.md PR guidance matches CLAUDE.md intent-atomic rule (no \"≤ 5 files\" claim)"
  notes: |
    Pure docs + comment change; no code behavior modified. Audit surfaced two follow-ups left as open work: (a) INFRA-070 itself (gap-reserve.sh zero-padding fix) is still open and tracked separately; (b) "INFRA-CHOKE" is referenced in CLAUDE.md as a concept name (the CI pre-flight gate) but isn't a real gap ID — not material drift, kept as-is.
  source_doc: AGENTS.md, CLAUDE.md
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-075
  domain: INFRA
  title: Duplicate-ID guard missed same-day INFRA-073 collision — audit and fix guard scope
  status: done
  priority: P1
  effort: s
  description: |
    Cold Water Issue #7 (2026-04-26): docs/gaps.yaml contains two entries with
    id: INFRA-073 — one filed by Cold Water Issue #6 commit d448c4e ("Gap-closure
    hygiene audit — close 8 OPEN-BUT-LANDED gaps") and one filed by PR #544 commit
    6844154 ("pre-commit YAML-validity guard for docs/gaps.yaml"). Both were inserted
    on 2026-04-26. The duplicate-ID pre-commit guard (INFRA-GAPS-DEDUP, 2026-04-19)
    did not catch the collision. This is the 8th known duplicate-ID collision pair
    (original 7 from Issue #2: COG-007 through COG-011, MEM-003, EVAL-003). The guard
    system now includes: gap-ID hijack, duplicate-ID check, recycled-ID check,
    preregistration check, YAML validity check. None prevented this. Investigate the
    exact failure mode (concurrent branch race, guard scope gap, or gap-reserve.sh
    returning the same ID to two sessions). Fix the guard so same-day concurrent
    insertions are caught. Acceptance: INFRA-073 duplicate resolved, regression test
    `scripts/test-duplicate-id-guard.sh` covers same-day concurrent-insert scenario.
  acceptance_criteria:
    - The INFRA-073 duplicate is resolved (one entry closed/removed with audit trail)
    - Root cause of guard bypass is documented
    - scripts/test-duplicate-id-guard.sh has a test covering concurrent-branch insertion of the same ID
    - Guard fix ships to pre-commit hook
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'
  closed_pr: 556

- id: INFRA-076
  domain: INFRA
  title: Test <test@test.com> co-author in 29+ commits — document identity or purge from history
  status: done
  priority: P2
  effort: s
  description: |
    Cold Water Issue #7 (2026-04-26): every one of the last 29+ observed commits
    on origin/main carries `Co-authored-by: Test <test@test.com>` in the commit
    body. Cold Water Issue #5 flagged "Test" as 21 commits under that primary author
    identity. Issue #6 classified this FIXED, having checked only the primary author
    field (all 50 recent commits showed repairman29 as author). The co-author trailer
    was not checked. The "Test" identity was not eliminated — it shifted from primary
    author to co-author, appearing in the Co-authored-by trailer of every subsequent
    commit. docs/AGENT_COORDINATION.md §3a documents three attribution identities:
    Chump Dispatched, Cold Water, and human Jeff Adkins. Test <test@test.com> has no
    entry. An unidentified co-author with a test-placeholder email appears on every
    commit this project ships. This must be identified (is it a bot identity? a CI
    system? an OAuth token?), added to the attribution table if legitimate, or
    stripped from future commits if it is a misconfiguration. Red Letter #5 noted 21
    commits (33%) from Test as primary author; Red Letter #6 falsely closed the issue.
  acceptance_criteria:
    - Identity of Test <test@test.com> is documented in AGENT_COORDINATION.md §3a
    - If it is a misconfiguration, bot-merge.sh or the dispatch pipeline strips it from future commits
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 642

- id: INFRA-077
  domain: INFRA
  title: remove obsolete gap-reserve.sh unpadded-ID warning from CLAUDE.md
  status: done
  priority: P3
  effort: xs
  description: |
    INFRA-074 (PR #545) added a warning to the gap-reserve.sh recommendation that it emitted unpadded IDs (e.g. INFRA-71 instead of INFRA-071), with advice to hand-pad until INFRA-070 landed. INFRA-070 landed on 2026-04-26 in PR #547, ~10 minutes after PR #545 merged. The warning is now stale and would mislead agents into a now-unnecessary manual step.
  acceptance_criteria:
    - CLAUDE.md no longer mentions hand-padding gap IDs from gap-reserve.sh
    - the gap-reserve.sh fallback advice still mentions both paths but without obsolete caveat
  depends_on: [INFRA-070]
  notes: |
    Pure docs cleanup; no code change. Caught while picking up queue work after INFRA-074 landed.
  source_doc: CLAUDE.md
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-078
  domain: INFRA
  title: Duplicate-ID pre-commit guard fires on pre-existing dups, training bypass habit
  status: open
  priority: P1
  effort: s
  description: |
    Process review (2026-04-26): the duplicate-ID pre-commit guard
    (INFRA-GAPS-DEDUP, 2026-04-19) checks the *total* state of docs/gaps.yaml
    after the commit. If main already contains a duplicate ID (e.g. the
    INFRA-073 collision tracked by INFRA-075), every doc-only PR that touches
    gaps.yaml has to bypass the guard with CHUMP_GAPS_LOCK=0 even though it
    introduces no new duplicate. Observed today on PR #554 (EVAL-088 caveat) —
    the bypass was correct in this case but trains the habit of reaching for
    CHUMP_GAPS_LOCK=0 reflexively, which is exactly what the original
    duplicate-ID incidents were caused by. Fix: diff against `git show :gaps.yaml`
    (index baseline) and only fire when the commit *adds* a new duplicate or
    *modifies* a row participating in an existing duplicate. Pre-existing dups
    on main should not gate unrelated commits.
  acceptance_criteria:
    - Guard only fires when commit introduces a new duplicate or edits a row in an existing duplicate group
    - "scripts/test-duplicate-id-guard.sh covers \"pre-existing dup, unrelated edit\" case (must pass)"
    - PR touching gaps.yaml in a repo with a known dup does not require CHUMP_GAPS_LOCK=0 unless it touches the dup
  opened_date: '2026-04-26'

- id: INFRA-079
  domain: INFRA
  title: Pre-commit hook for EVAL/RESEARCH gap closure — require cross-judge audit or explicit waiver
  status: done
  priority: P0
  effort: m
  description: |
    Process review (2026-04-26): EVAL-074 PR #549 shipped a mechanism claim
    ("DeepSeek over-compliance, -30pp gotcha regression p=0.0007") based on a
    single Llama-3.3-70B judge. The cross-judge audit (PR #551) flipped the
    finding to a Llama-judge artifact (κ=0.40, gotcha 52% agreement). Cost of
    the retraction: ~$1.50 + half a day + three follow-up amendment PRs (#552,
    #554, this gap). The standing rule from the EVAL-074-AUDIT doc — "any
    claim that depends on judge labels must include a cross-judge audit on the
    same JSONL before it is stamped as a result" — is documented but not
    enforced. Fix: pre-commit hook that, when an EVAL-* or RESEARCH-* gap is
    set to status: done, requires one of (a) a `cross_judge_audit:` field
    referencing JSONL artifact(s) under `logs/ab/` with at least two judges
    from different families, OR (b) `single_judge_waived: true` with a
    `single_judge_waiver_reason:` field, OR (c) a preregistration explicitly
    declaring single-judge scope. Bypass: CHUMP_CROSS_JUDGE_CHECK=0 with
    justification (mirrors CHUMP_PREREG_CHECK=0 pattern).
  acceptance_criteria:
    - scripts/git-hooks/pre-commit blocks EVAL-*/RESEARCH-* gap closures missing cross-judge evidence or explicit waiver
    - "docs/RESEARCH_INTEGRITY.md links to the new guard and lists it under \"Required Methodology Standards\""
    - At least one regression test under scripts/test-cross-judge-guard.sh covering pass/fail/waiver cases
    - "CHUMP_CROSS_JUDGE_CHECK=0 escape hatch documented in CLAUDE.md \"Pre-commit guards\" table"
  depends_on: [EVAL-074]
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 625

- id: INFRA-080
  domain: INFRA
  title: gap-reserve.sh outputs unpadded ID (e.g. EVAL-88 instead of EVAL-088)
  status: done
  priority: P1
  effort: xs
  description: |
    Process review (2026-04-26): scripts/gap-reserve.sh printed `EVAL-88` when
    reserving the next free EVAL ID; existing entries are padded to 3 digits
    (EVAL-085, 086, 087). I noticed and wrote `EVAL-088` manually into
    docs/gaps.yaml on PR #554. CLAUDE.md notes INFRA-070 partially addressed
    silent ID collisions in `chump gap reserve`, and INFRA-077 (in flight on
    PR #555) removes the obsolete unpadded-ID warning from gap-reserve.sh —
    but the output formatting itself is still wrong. Fix: zero-pad the
    reserved ID to match the prevailing width of the domain's existing IDs
    (3 digits is the established convention for all domains here). Mirror in
    `chump gap reserve` (Rust path) so both produce identical output.
  acceptance_criteria:
    - scripts/gap-reserve.sh prints the new ID zero-padded to 3 digits (EVAL-088 not EVAL-88)
    - chump gap reserve produces the same padded output
    - Regression test under scripts/ confirming padded output for a domain with 3-digit prevailing width
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 628

- id: INFRA-081
  domain: INFRA
  title: Lease coordination misses semantic collisions on the same problem space
  status: open
  priority: P2
  effort: m
  description: |
    Process review (2026-04-26): four worktrees were active today on adjacent
    INFRA-073-area work — infra-073-dedup (mine), infra-073-yaml-lint (stale,
    PR #544 already shipped), infra-077-cleanup (different scope), and the
    INFRA-075 tracker for the dedup itself. The lease system caught zero
    overlap because each worktree edited different files. Only the user's
    "make sure you aren't colliding" prompt and a careful read of
    .chump-locks/ambient.jsonl surfaced the collision risk before I shipped.
    Fix: gap-claim.sh / gap-reserve.sh should warn when claiming a gap whose
    ID prefix is within ±5 of any open lease's gap_id, *or* when the title's
    first 3 keywords overlap with another active lease's title (cheap
    fuzzy-match on title tokens). This is a soft warn, not a block — the
    user/agent decides whether to proceed. Lower priority because the manual
    ambient-stream check works when followed; raise priority if a real
    collision ships through.
  acceptance_criteria:
    - gap-claim.sh prints a soft warning when adjacent ID or overlapping-title leases are active
    - gap-reserve.sh applies the same check before reserving
    - Documentation under docs/AGENT_COORDINATION.md explains the new warning and how to override
  opened_date: '2026-04-26'

- id: INFRA-082
  domain: INFRA
  title: Reserve-time title similarity check — warn when filing a gap whose title overlaps an existing one
  status: open
  priority: P1
  effort: m
  description: |
    Process review (2026-04-26 follow-up): we have zero gates that check
    whether a gap being filed *already exists* under a different ID. INFRA-081
    catches lease-time concurrent sessions; this gap catches the stronger
    case — agent A filed INFRA-073 "pre-commit YAML-validity guard" on
    2026-04-25 (PR #544, shipped same day), agent B filed INFRA-073 "Gap-closure
    hygiene audit" on 2026-04-26 from cold-water Issue #6. Different work,
    same ID, no overlap in time-of-claim, so no live lease to compare against.
    A title-similarity check at reserve time (against ALL gaps in docs/gaps.yaml,
    open or done) would have surfaced the prior INFRA-073 row before assigning
    a colliding ID. Fix: in scripts/gap-reserve.sh and `chump gap reserve`,
    after picking the next free numeric ID, scan all existing gaps and
    compute a cheap similarity score (title token Jaccard, or trigram
    overlap) against the candidate title. If any existing gap scores above
    a threshold (e.g., 0.5 Jaccard on lowercased token set minus stopwords),
    print:
      WARN: title overlaps existing <ID> "<title>" (<status>) — review before proceeding
      Continue anyway? [y/N]
    Default deny on tty; `CHUMP_GAP_DUP_CHECK=0` bypass for scripted reserves.
    Stronger than INFRA-081 because it covers same-day-different-session AND
    weeks-apart-different-cycle cases. Together with INFRA-081 the coverage
    is: live overlap (lease) + adjacent ID (lease) + title overlap on full
    history (this gap).
  acceptance_criteria:
    - gap-reserve.sh computes title similarity vs all gaps in docs/gaps.yaml and warns above threshold
    - chump gap reserve produces the same warning
    - Threshold is documented and tunable (env or config)
    - CHUMP_GAP_DUP_CHECK=0 bypass for non-interactive use, listed in CLAUDE.md
    - "Regression test under scripts/ covering \"title matches existing closed gap\" case"
  depends_on: [INFRA-081]
  opened_date: '2026-04-26'

- id: INFRA-083
  domain: INFRA
  title: mandate chump gap commands - block raw docs/gaps.yaml edits in pre-commit
  status: done
  priority: P1
  effort: m
  notes: released - colliding with claude/infra-083-ambient-glance worktree
  closed_date: '2026-04-26'

- id: INFRA-084
  domain: INFRA
  title: mandate chump gap commands - block raw docs/gaps.yaml edits
  status: open
  priority: P1
  effort: m

- id: INFRA-085
  domain: INFRA
  title: manual-ship invisibility - auto-write lease on gh pr create
  status: open
  priority: P2
  effort: s

- id: INFRA-086
  domain: INFRA
  title: chump pr-stack per-session view
  status: open
  priority: P2
  effort: m

- id: INFRA-087
  domain: INFRA
  title: automated repo failure-detection auditor + CI-time health checks
  status: open
  priority: P1
  effort: m

- id: INFRA-088
  domain: INFRA
  title: reconcile docs/audit→docs/audits + docs/synthesis→docs/syntheses (Phase 2 pre-work)
  status: open
  priority: P2
  effort: s

- id: INFRA-089
  domain: INFRA
  title: chump gap CLI lacks set subcommand for editing fields
  status: open
  priority: P2
  effort: s

- id: INFRA-090
  domain: INFRA
  title: chump gap dump produces invalid YAML and reorders entire file
  status: done
  priority: P2
  effort: s
  closed_date: '2026-04-26'

- id: INFRA-091
  domain: INFRA
  title: Phase 3 follow-up — fix relative-path scripts broken by reorg
  status: open
  priority: P2
  effort: m

- id: INFRA-092
  domain: INFRA
  title: fix Phase 3 cross-subdir Python parents+SCRIPT_DIR refs
  status: done
  priority: P1
  effort: s
  closed_date: '2026-04-26'
  closed_pr: 562

- id: INFRA-093
  domain: INFRA
  title: fix Phase 3 cross-subdir Python parents+SCRIPT_DIR refs (re-file)
  status: done
  priority: P1
  effort: s
  closed_date: '2026-04-26'

- id: INFRA-094
  domain: INFRA
  title: x
  status: open
  priority: P2
  effort: m

- id: INFRA-095
  domain: INFRA
  title: x
  status: open
  priority: P2
  effort: m

- id: INFRA-096
  domain: INFRA
  title: x
  status: open
  priority: P2
  effort: m

- id: INFRA-097
  domain: INFRA
  title: dispatch prompt starting with --- breaks claude -p arg parsing
  status: open
  priority: P1
  effort: xs

- id: INFRA-098
  domain: INFRA
  title: Layer 2 ambient sibling-activity block — inject into Rust prompt assembler
  status: done
  priority: P2
  effort: m
  description: |
    Companion to INFRA-092 shell-wrapper glance. Layer 2 makes the chump-local agent loop ambient-aware via prompt-assembler injection.
  acceptance_criteria:
    - src/ambient_stream.rs parses ambient.jsonl with self-session filter and recency window
    - "prompt_assembler.rs injects \"Recent sibling activity\" block when stream is non-empty"
    - main.rs wires the helper into the chump-local loop
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-099
  domain: INFRA
  title: CODEOWNERS + chump-flavored PR template (Phase 5)
  status: done
  priority: P2
  effort: s
  description: |
    Phase 5 of the repo-hygiene rollout (see .chump/PHASE_2_3_5_PLAN.md):
    add `.github/CODEOWNERS` (single owner: @repairman29) so every PR auto-
    requests review from the maintainer, and replace the generic
    `.github/pull_request_template.md` with one that reflects Chump's actual
    conventions (gap ID, INFRA-088 title format, EVAL/RESEARCH preregistration,
    INFRA-009 docs-delta, merge-queue ship path).
  acceptance_criteria:
    - .github/CODEOWNERS present with `* @repairman29`
    - .github/pull_request_template.md surfaces gap field, title convention reference, prereg + docs-delta callouts
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-100
  domain: INFRA
  title: Unify gap reserve flow across SQLite DB, open PRs, and live leases - single atomic next-ID picker
  status: open
  priority: P1
  effort: m
  description: |
    The 4-way INFRA-087..090 collision on 2026-04-26 (PRs #565/#566/#568/#569,
    captured by ambient ALERT id_collision_4way at 18:10:00Z) showed that
    'chump gap reserve' (state.db) and 'scripts/gap-reserve.sh' (gaps.yaml)
    pick IDs from different sources, and neither consults open PR titles.
    INFRA-082 covers title similarity; this gap is the broader fix: a single
    next-ID picker that scans (a) .chump/state.db, (b) docs/gaps.yaml,
    (c) open PR titles via 'gh pr list', and (d) .chump-locks/*.json
    pending_new_gap entries - atomically, with a flock - and returns the
    first ID free in all four. Both the Rust path and the shell wrapper
    must call this single function.
  acceptance_criteria:
    - "One Rust function gap::reserve_next_id(domain) is the only ID picker"
    - scripts/gap-reserve.sh shells out to that function (no parallel logic)
    - Picker reads state.db + gaps.yaml + gh pr list --state open + lease pending_new_gap
    - flock-protected so two concurrent reservations cannot pick the same ID
    - Test reproduces the INFRA-087..090 4-way collision and shows it now picks 4 distinct IDs
  opened_date: '2026-04-26'

- id: INFRA-101
  domain: INFRA
  title: JSON-schema-validate every line emitted to ambient.jsonl (pre-commit + emit-time)
  status: open
  priority: P1
  effort: s
  description: |
    Audit of ambient.jsonl on 2026-04-26 showed schema drift: standard rows
    are {ts, session, event, ...} but INFRA-082 INTENT emitter writes
    {event, session, ts, gap, files} with reordered keys and a nonstandard
    shape. Today this is harmless (consumers parse JSON regardless of order)
    but it makes the stream unparseable by strict tooling and hides bugs
    where required fields are missing. Define a JSON schema for each event
    kind (session_start, file_edit, commit, bash_call, INTENT, ALERT),
    validate at emit time inside scripts/ambient-emit.sh, and add a
    pre-commit guard that re-validates any new lines staged into the stream.
  acceptance_criteria:
    - docs/ambient-schema.json defines event kinds and required fields
    - scripts/ambient-emit.sh validates payloads before append (rejects with diagnostic)
    - Pre-commit guard fails when staged ambient.jsonl lines fail schema check
    - Test fixture covers each event kind plus one schema-violation case
  opened_date: '2026-04-26'

- id: INFRA-102
  domain: INFRA
  title: session_start ambient events absent - audit emitter and restore advertised behavior
  status: open
  priority: P1
  effort: xs
  description: |
    CLAUDE.md advertises session_start as one of the ambient.jsonl event
    kinds an agent peripheral vision should pick up. A 50-row tail of
    ambient.jsonl on 2026-04-26 contains only bash_call, file_edit, commit,
    INTENT, and ALERT - no session_start in the entire window. Either the
    emitter was removed (regression), the docs are aspirational, or the
    event is filtered. Track down the discrepancy and either restore the
    emitter or strike the line from CLAUDE.md.
  acceptance_criteria:
    - Identify whether session_start is emitted anywhere in the codebase
    - If missing - restore emit at session-init points (gap-claim.sh, bot-merge.sh entry)
    - If intentionally removed - delete the line from CLAUDE.md ambient-event list
    - Add a test that asserts session_start lands in ambient.jsonl during dispatcher startup
  opened_date: '2026-04-26'

- id: INFRA-103
  domain: INFRA
  title: PR parallelism classifier - tag serializing vs parallel-safe PRs so queue can land non-conflicting PRs concurrently
  status: open
  priority: P2
  effort: m
  description: |
    With 8+ concurrent auto-merge PRs (observed 2026-04-26 18:00-18:10),
    the GitHub merge queue serializes everything because any one of them
    might conflict with main. In practice, doc-only PRs and src-only PRs
    that don't touch shared hot files (gaps.yaml, state.db, CLAUDE.md)
    cannot conflict with each other. Classify each PR at creation time:
    serializing if its diff touches gaps.yaml / .chump/state.db / CLAUDE.md
    / .gitmodules / Cargo.lock; parallel-safe otherwise. Use the label to
    drive a smarter merge cadence (or at minimum, surface in the queue
    health monitor so humans/agents can spot avoidable serialization).
  acceptance_criteria:
    - bot-merge.sh inspects diff at PR-create time and applies serializing or parallel-safe label
    - Documented hot-file list is configurable
    - Queue health monitor (INFRA-052) reports when serializing PRs are blocking parallel-safe ones
    - Optional follow-up gap for actually changing merge cadence - out of scope here
  opened_date: '2026-04-26'

- id: INFRA-104
  domain: INFRA
  title: PR title-vs-implementation drift detector - ALERT when a PR gap-ID has no matching diff signal
  status: open
  priority: P1
  effort: s
  description: |
    PR #565 on 2026-04-26 titled "INFRA-087..090: mandate chump gap canonical
    path + audit outdated processes" reserved four gap IDs by title only
    while parallel PRs #566/#568/#569 actually implemented INFRA-090/089/088.
    The merge queue has no way to detect this kind of name-squatting.
    Add a check (post-PR-create, runs in CI or via the stale-pr-reaper) that
    extracts gap IDs from a PR title/body and asserts the diff touches at
    least one file matching that gap expected scope (e.g. acceptance
    criteria mention "gaps.yaml" -> diff must touch gaps.yaml). On mismatch,
    post an ambient ALERT kind=title_diff_drift and label the PR.
  acceptance_criteria:
    - Script extracts gap IDs from PR title/body
    - Compares to acceptance_criteria file-hints in gaps.yaml/state.db
    - Posts ALERT and labels PR on mismatch
    - "Backtest - when fed PR #565 plus gap registry of that moment, alert fires; when fed PR #570 (INFRA-084 layer 2), alert does NOT fire"
  opened_date: '2026-04-26'

- id: INFRA-105
  domain: INFRA
  title: Lease-file and state.db ledger convergence - claims must write both, or one must be the source
  status: open
  priority: P1
  effort: s
  description: |
    'scripts/gap-claim.sh' writes .chump-locks/<session>.json with gap_id
    but never touches .chump/state.db. 'chump gap claim' writes the DB but
    not the lease file. The two ledgers disagree on who holds what right now
    (verified 2026-04-26 via 'chump gap list' showing INFRA-052 as a
    queue-health gap while gaps.yaml shows it as a rebase-resolution stub).
    Decide: either (a) gap-claim.sh shells into 'chump gap claim' so the DB
    is written too, or (b) 'chump gap claim' writes the lease file. Either
    way both ledgers must agree after a single claim, and a divergence
    detector should run hourly and post ALERT kind=ledger_split.
  acceptance_criteria:
    - One claim path writes both ledgers (decide direction)
    - Divergence detector runs (cron or hourly script) and posts ALERT
    - Test - claim a gap via shell path, verify state.db reflects it; claim via Rust path, verify lease file reflects it
    - Document the chosen direction in CLAUDE.md Coordination docs section
  opened_date: '2026-04-26'

- id: INFRA-106
  domain: INFRA
  title: evaluate GitHub merge queue migration plan (currently disabled, strict=true causes serial rebase storm)
  status: open
  priority: P1
  effort: m
  description: |
    Branch protection on main currently has strict=true required-status-checks
    and no merge queue. Result: when N PRs are armed for auto-merge in
    parallel, GitHub lands them serially — each landing forces the other N-1
    to BEHIND/DIRTY, which our docs/gaps.yaml-touching PRs almost always hit
    because the YAML appends collide. Operators (agents and humans) end up
    hand-rebasing the same 6-8 PRs in a loop until the queue drains.
    
    The 2026-04-26 cycle observed this directly: 7 PRs (562, 567, 568, 569,
    570, 572, 573, 574) all armed within minutes of each other; landing was
    paced by a manual reset+reapply rebase loop using saved /tmp/ patches.
    PR #565, #571, #574 landed cleanly via the loop; #569 followed; the
    remaining 6 are still cycling at the time of filing.
    
    Two options were on the table:
      (A) Enable GitHub merge queue via
          `gh api -X PUT repos/repairman29/chump/branches/main/protection`
          with required_merge_queue. Auto-rebases each PR onto a temp branch
          and re-runs CI before atomic squash. Closes the rebase storm but
          changes the contract for every future PR; required-check names
          must match the queue's expectations exactly or PRs hang forever.
          Pre-push hooks only fire on the PR branch, not the queue's temp
          merge — so dup-ID guard, gap-preflight, etc. don't gate the merged
          result.
      (B) Flip strict=false on required-status-checks. Cheaper, but allows
          stale-base merges — exactly the failure mode INFRA-075 / Red
          Letter #2 were built to prevent. Two PRs touching the same gap-ID
          region in docs/gaps.yaml could both pass CI on their own base and
          land back-to-back with a silent semantic conflict.
    
    User decision (2026-04-26): keep cycling manually for the current wave,
    file this gap to evaluate option A carefully (test on a fork, define
    required-check name contract, plan auto-merge re-arm of in-flight PRs,
    document operator runbook). Do NOT flip option B live.
  acceptance_criteria:
    - Test merge queue config on a throwaway fork or scratch repo first
    - Document the exact required-check names the queue will gate on
    - Define migration plan for in-flight auto-merge-armed PRs (re-arm under queue semantics)
    - Document operator runbook for queue-stuck recovery (extends the existing one in CLAUDE.md)
    - Define how pre-push hooks (dup-ID, gap-preflight) interact with queue temp branches
    - Decision recorded — adopt queue OR document why we stayed with current setup

- id: INFRA-107
  domain: INFRA
  title: Pre-commit guard - block status flip to done with closed_pr value of TBD or non-numeric
  status: done
  priority: P1
  effort: xs
  description: |
    INTEGRITY_AUDIT_1 documented PRODUCT-009 false closure - the gap was
    flipped to status:done with closed_pr:TBD on 2026-04-20, an explicit
    incomplete-closure signal that no automated guard caught.
    RED_LETTER #2 caught it days later. Add a pre-commit check that fails
    when a gaps.yaml diff sets status:done while closed_pr is missing,
    TBD, tbd, or any non-numeric value. Bypass - CHUMP_GAPS_LOCK=0.
    Pairs with INFRA-111 (acceptance_verified field) for full closure-
    integrity coverage but is independently shippable.
  acceptance_criteria:
    - Pre-commit guard added with bypass env CHUMP_GAPS_LOCK=0
    - Test fixture - PRODUCT-009 closure diff fails the guard
    - Test fixture - normal closure with closed_pr 404 passes
    - Documented in CLAUDE.md Commit-time guards table
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'

- id: INFRA-108
  domain: INFRA
  title: Audit and normalize all ambient.jsonl emitters - INFRA-101 covers schema validation but existing emitters drift
  status: open
  priority: P2
  effort: s
  description: |
    INFRA-101 adds a JSON schema validator at emit time, but does not
    standardize the existing emitter shapes. Audit on 2026-04-26 found
    INTENT events use {event, session, ts, gap, files} key order while
    every other event kind uses {ts, session, event, ...}. ALERT events
    have inconsistent subkind/kind field naming. Audit all callers of
    scripts/ambient-emit.sh plus any direct JSON appends in the Rust
    codebase, normalize to a single canonical key order and required
    fields, and update CLAUDE.md ambient-event reference to match.
  acceptance_criteria:
    - Inventory of every code path that writes to ambient.jsonl
    - Canonical schema documented in docs/ambient-schema.md
    - All emitters updated to canonical form
    - INFRA-101 schema validator passes on every existing event-kind sample
  opened_date: '2026-04-26'

- id: INFRA-109
  domain: INFRA
  title: Audit coordination scripts for git-common-dir vs cwd worktree-boundary bugs
  status: open
  priority: P2
  effort: s
  description: |
    During INFRA-084 ship (2026-04-26), chump-ambient-glance.sh was found
    to read .chump-locks from cwd (a linked worktree) when the canonical
    location is the main repo .chump-locks/ (resolved via
    git rev-parse --git-common-dir). The same boundary issue likely
    affects other coordination scripts that read or write .chump-locks/,
    .chump/state.db, or ambient.jsonl from cwd. Audit gap-claim.sh,
    gap-preflight.sh, gap-reserve.sh, ambient-emit.sh, ambient-watch.sh,
    bot-merge.sh, and any Rust callers - any reference to .chump-locks/
    or .chump/ that does not pass through git-common-dir resolution is
    a worktree-boundary bug waiting to fire.
  acceptance_criteria:
    - Inventory of every script and Rust file that touches .chump-locks/ or .chump/
    - Each call resolves base via git rev-parse --git-common-dir or documented exception
    - Test - run a coordination action from a linked worktree, verify it touches main-repo paths not worktree-local paths
    - CLAUDE.md Coordination docs section adds the resolution-rule note
  opened_date: '2026-04-26'

- id: INFRA-110
  domain: INFRA
  title: Reserve-time gap requires scoped-diff signature or 2-hour TTL - prevent name-squatting reservations
  status: open
  priority: P1
  effort: m
  description: |
    PR #565 on 2026-04-26 reserved INFRA-087..090 by title only and held
    them while parallel implementation PRs #566/#568/#569 had to renumber.
    INFRA-104 (drift detector) catches this RETROACTIVELY via ALERT.
    INFRA-110 prevents it - at reserve time, require either (a) a draft
    PR with the gap ID in scoped diff (i.e. files match acceptance-
    criteria scope) or (b) a 2-hour TTL after which the reservation
    auto-expires unless renewed via heartbeat. Pairs with but is not
    duplicated by INFRA-100 (atomic next-ID picker) - 100 prevents
    same-time collisions, 110 prevents long-lived squatting.
  acceptance_criteria:
    - chump gap reserve writes ttl_expires field to lease pending_new_gap
    - Default TTL 7200 seconds (2h); configurable via --ttl
    - Renewing requires either chump --heartbeat or PR linked to the gap ID
    - Expired reservations auto-release - gap-preflight.sh stops blocking
    - "Backtest - PR #565 reservation would expire before #566/#568/#569 needed renumber"
  opened_date: '2026-04-26'

- id: INFRA-111
  domain: INFRA
  title: Mandate closed_interpretation and acceptance_verified fields on every gap closure
  status: open
  priority: P1
  effort: s
  description: |
    INTEGRITY_AUDIT_1 (2026-04-24) traced definition drift as the real
    closure-integrity problem - QUALITY-001 was filed as eliminate
    panics, executed as categorize and fix unsafe ones, closed under
    interpretation #2 without noting the scope change. PRODUCT-009 was
    filed with four acceptance criteria, closed when only one was met.
    closed_interpretation field is already used organically (grep finds
    it on a handful of recent closures) but is not mandatory. Add a
    pre-commit guard that requires both fields when status flips to
    done - closed_interpretation (free text, which acceptance criterion
    drove closure) and acceptance_verified (per-criterion bool array).
    Bypass - CHUMP_GAPS_LOCK=0 with justification in commit body.
  acceptance_criteria:
    - Pre-commit guard requires closed_interpretation when status flips open to done
    - Pre-commit guard requires acceptance_verified array sized to acceptance_criteria
    - chump gap ship --update-yaml prompts for both fields
    - Documented in CLAUDE.md Commit-time guards table
    - Backtest - PRODUCT-009 closure would have been blocked at the TBD point
  opened_date: '2026-04-26'

- id: INFRA-112
  domain: INFRA
  title: chump gap dump is lossy - 391 gaps in DB became 389 in YAML
  status: done
  priority: P0
  effort: s
  description: |
    Running 'chump gap dump --out docs/gaps.yaml' on 2026-04-26 produced
    a YAML mirror with 389 '- id:' entries while the SQLite store had 391.
    Two gaps silently disappear during regeneration. Likely cause: rows
    in .chump/state.db with empty or whitespace-only id fields fail to
    serialize cleanly (the dump emits '- id: ' which the round-trip parser
    drops), and there is no NOT NULL / non-empty constraint on the id
    column to prevent such rows being inserted. This is the bug that
    forced the FLEET-006 PR (#572) to revert a full --update-yaml dump
    and patch the single gap status by hand to avoid a 11k-line lossy
    diff. Until fixed, 'chump gap ship --update-yaml' and 'chump gap
    dump' are unsafe in real PRs.
  acceptance_criteria:
    - Add NOT NULL + length(trim(id)) > 0 constraint to .chump/state.db schema
    - chump gap dump asserts dump_count == db_count and exits non-zero on mismatch
    - Identify and repair the 2 missing gaps (or document why they were dropped)
    - Round-trip test - dump | re-import | dump again must be byte-stable
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'

- id: INFRA-113
  domain: INFRA
  title: Pre-commit preregistration check is hollow - file existence only, contents not validated
  status: done
  priority: P0
  effort: m
  description: |
    The 'preregistration required' guard at scripts/git-hooks/pre-commit
    rejects EVAL-* / RESEARCH-* closures without docs/eval/preregistered/
    <GAP-ID>.md, but it only checks file existence. An empty preregistration
    file passes the gate. The file is supposed to lock the methodology
    contract (n>=50, non-Anthropic judge, A/A baseline, mechanism analysis
    threshold |delta|>0.05, prohibited claims per docs/RESEARCH_INTEGRITY.md)
    BEFORE data collection, but nothing in the gate ensures those fields
    are present or non-trivial. The result - an EVAL-* gap can ship 'done'
    with a one-line preregistration that satisfies the guard but violates
    the standard. Cold Water Issues #2 through #7 keep flagging "evals
    documented but methodology not enforced" - this is the mechanism.
  acceptance_criteria:
    - Pre-commit guard parses preregistration file and asserts presence of - sample size, judge identity, A/A baseline plan, mechanism analysis threshold, prohibited-claims attestation
    - Each field has a minimum content length (e.g. >= 20 chars, no obvious placeholder text)
    - Bypass env CHUMP_PREREG_CONTENT_CHECK=0 documented for genuine retrospective gaps
    - Test - empty preregistration file fails the guard; populated file passes
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 622

- id: INFRA-114
  domain: INFRA
  title: overnight research scheduler — bury research churn off the critical path
  status: done
  priority: P2
  effort: s
  description: |
    Per the 2026-04-26 directive ("we need to bury this research in the
    basement.. it's slowing us down and should be done but it's noisy and
    takes too much time day to day we need to do this overnight when I'm
    asleep"): research churn (eval sweeps, A/B studies, ablations) was
    eating daytime CPU/RAM and competing with the dispatcher's coding
    agents.
    
    This lands the scaffolding to move research jobs overnight:
      - scripts/run-overnight-research.sh — run-parts-style wrapper
        that executes every *.sh in scripts/overnight/ in lex order,
        with a 1h per-job timeout, lockfile guard, per-run log archive
        in .chump/overnight/, and ambient.jsonl emission so daytime
        agents see what ran while they were asleep
      - scripts/install-overnight-research-launchd.sh — macOS launchd
        installer (default 02:00 daily, override via CHUMP_OVERNIGHT_HOUR/
        CHUMP_OVERNIGHT_MINUTE)
      - scripts/overnight/ — the drop-in directory. Ships with a
        00-smoke-check.sh sanity job and a README explaining conventions.
    
    Migration of specific eval sweeps / A/B harness scripts to overnight
    is a follow-up — this PR is just the platform.
  acceptance_criteria:
    - scripts/run-overnight-research.sh executes scripts/overnight/*.sh in order
    - Per-job timeout (default 1h, env-overridable) prevents one job from blocking siblings
    - Lockfile guards against overlapping runs
    - Per-run log archive in .chump/overnight/<run-id>.log
    - ambient.jsonl emits overnight_start / overnight_done / overnight_job_fail events
    - "scripts/install-overnight-research-launchd.sh creates a launchd plist for 02:00 daily"
    - scripts/overnight/README.md documents the convention for adding/disabling jobs
    - Smoke test — running the wrapper with the sample 00-smoke-check.sh job exits 0
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-115
  domain: INFRA
  title: Lease TTL has no server-side enforcement - stale .chump-locks/ ignored only client-side
  status: open
  priority: P1
  effort: m
  description: |
    Lease expiry is computed in scripts/gap-reserve.sh (Python, 30s grace
    window) and pre-commit hook (shell date arithmetic, fragile parsing).
    Both are client-side checks - an offline agent with a stale .chump-locks/
    cache can reuse expired leases. Pre-commit timestamp parsing is
    shell-fragile - if the timestamp is malformed, $exp_epoch becomes
    empty and the check silently passes. There is no canonical authority
    that says 'this lease is dead' that all agents consult. INFRA-105
    addresses lease-vs-state.db convergence; this gap addresses TTL
    enforcement specifically. NATS KV (chump-coord) already has TTL on
    gap claims (DEFAULT_GAP_TTL_SECS = 14400) - the file lease layer
    should be subordinate to NATS or have an equivalent server-side
    purge.
  acceptance_criteria:
    - Either NATS KV or a SQLite-backed expiry service is the authoritative lease ledger
    - Client-side checks read from this authority and never trust the local cache alone
    - Pre-commit timestamp parser fails closed (refuses to merge) on malformed expires_at
    - Test - simulate a stale local lease file with expired ts, verify a sibling agent can claim despite the local file
  opened_date: '2026-04-26'

- id: INFRA-116
  domain: INFRA
  title: runtime_flags.rs - documented CHUMP_KNOWN_FLAGS list does not exist
  status: open
  priority: P2
  effort: xs
  description: |
    src/runtime_flags.rs comment line 20 says "The flag ... removed from
    this module's CHUMP_KNOWN_FLAGS list." No such constant or list exists
    in the file (only parse_flags_str() and enabled_flags_sorted()). The
    documented invariant (every cog_NNN flag must appear in the known-flags
    list, removal is the cleanup signal per CLAUDE.md "Long COG-* branches
    forbidden") is therefore unenforced - dead flags can linger and there
    is no canonical place to audit which experiments are still gated.
    Either (a) add the list and have parse_flags_str() warn on unknown
    flags, or (b) remove the comment and document an alternative mechanism.
  acceptance_criteria:
    - Either CHUMP_KNOWN_FLAGS list exists and is referenced by parse_flags_str(), or the comment is corrected
    - If list exists - unknown flag names emit a warning to stderr and an ambient WARN event
    - Cycle-review process to remove dead flags is documented in CLAUDE.md
  opened_date: '2026-04-26'

- id: INFRA-117
  domain: INFRA
  title: Verify chump --briefing is implemented - CLAUDE.md cites it but src/ unchecked
  status: open
  priority: P1
  effort: xs
  description: |
    CLAUDE.md mandatory pre-flight (line 32) and the lesson-injection
    discussion both reference 'chump --briefing <GAP-ID>' as MEM-007's
    on-demand context-assembly path. A grep of src/main.rs in this audit
    did not surface a matching subcommand. Either (a) the command exists
    under a different name and CLAUDE.md is wrong, (b) it is partially
    implemented but undocumented elsewhere, or (c) it never landed and
    CLAUDE.md is documenting a phantom feature. Resolve with file:line
    evidence and either fix CLAUDE.md or land MEM-007.
  acceptance_criteria:
    - Audit src/, crates/, scripts/ for any --briefing entrypoint
    - If implemented - link the source, smoke-test with one gap ID
    - If not implemented - either remove the references from CLAUDE.md or file MEM-007 follow-up to land it
  opened_date: '2026-04-26'

- id: INFRA-118
  domain: INFRA
  title: Verify chump-commit.sh actually resets unrelated staged files - doc claim unverified
  status: open
  priority: P1
  effort: xs
  description: |
    CLAUDE.md hard rules state - "Use scripts/chump-commit.sh ... The
    wrapper resets any unrelated staged files from OTHER agents before
    committing so their in-flight WIP doesn't leak into your commit
    (observed twice on 2026-04-17 - memory_db.rs stomp in cf79287,
    DOGFOOD_RELIABILITY_GAPS.md stomp in a5b5053)." Audit on 2026-04-26
    did not find a 'git reset' or equivalent unrelated-files-reset call
    in scripts/chump-commit.sh. Either the behavior never landed, drifted
    (regression), or is implemented under a different mechanism. The
    described bug class (cross-agent staging leakage) is real and
    important - confirm or fix.
  acceptance_criteria:
    - Read scripts/chump-commit.sh and document the actual reset behavior
    - If absent - either implement the reset (git reset HEAD on files not in $@) or correct CLAUDE.md
    - Add a test - stage two files in two different worktrees, run chump-commit.sh in one, verify the other's staged file is not in the resulting commit
  opened_date: '2026-04-26'

- id: INFRA-119
  domain: INFRA
  title: bot-merge.sh has no health monitoring - hangs leak leases and freeze worktrees silently
  status: open
  priority: P1
  effort: m
  description: |
    scripts/bot-merge.sh is a 27KB shell state machine (rebase, fmt,
    clippy, test, push, PR creation, code-review fork, CI gate, auto-merge
    arming, target/ purge). If it hangs mid-execution, the lease in
    .chump-locks/<session>.json remains live and blocks sibling sessions.
    CLAUDE.md acknowledges this with the "manual ship path" recovery
    section but has no automated detection. Add a watchdog - either a
    timeout wrapper that releases the lease on SIGALRM, or a separate
    process that detects bot-merge.sh activity (heartbeat in
    .chump-locks/) and reaps stale leases whose owning script is gone.
  acceptance_criteria:
    - bot-merge.sh writes a heartbeat file every N seconds while running
    - A reaper (cron or launchd) clears leases whose heartbeat is stale beyond TTL
    - If bot-merge.sh receives SIGTERM or its parent shell dies, the lease is released as part of cleanup
    - Test - kill -9 bot-merge.sh mid-run, verify the lease becomes claimable within 2 minutes
  opened_date: '2026-04-26'

- id: INFRA-120
  domain: INFRA
  title: Stale reapers (PR, worktree, branch) have no log aggregation or failure alerting
  status: open
  priority: P1
  effort: s
  description: |
    scripts/stale-pr-reaper.sh, scripts/stale-worktree-reaper.sh, and
    (in flight) the stale-branch reaper from PR #568 / INFRA-089 all
    emit logs to /tmp/*.log on the host machine. There is no aggregation,
    no rotation, and no alert when any of them fail or stop running. The
    macOS launchd plist (ai.openclaw.chump-stale-worktree-reaper) is
    opt-in and may not be installed; if its hourly run silently fails,
    worktrees accumulate and consume disk for days before anyone notices.
    Pipe reaper output to ambient.jsonl (or NATS via FLEET-006) so all
    agents see reaper activity in their peripheral vision; ALERT when a
    reaper has not run in 4x its expected cadence.
  acceptance_criteria:
    - Each reaper emits one ambient event per run - kind=reaper_run with status=ok|fail and counts
    - Heartbeat watchdog ALERTs when reaper has not emitted in 4h (worktree/branch) or 2h (PR)
    - Reaper logs rotated and capped at a sensible size
    - CLAUDE.md Worktree disk hygiene section documents the alert mechanism
  opened_date: '2026-04-26'

- id: INFRA-121
  domain: INFRA
  title: Merge queue config drift undetected - silent auto-merge disarm when branch protection changes
  status: open
  priority: P1
  effort: s
  description: |
    The GitHub merge queue (INFRA-MERGE-QUEUE, 2026-04-19) is a load-bearing
    invariant - 'auto-merge IS the default'. If branch-protection rules
    drift (a required check is renamed, a status context is removed, the
    queue is disabled in settings), auto-merge silently disarms on already
    queued PRs and the queue can stop without an alarm. CLAUDE.md "If the
    merge queue is stuck" recovery section documents the symptoms but not
    the prevention. Add a periodic config-drift detector that diffs the
    current branch-protection config against a checked-in baseline
    (docs/MERGE_QUEUE_SETUP.md or a JSON snapshot) and ALERTs on any
    deviation.
  acceptance_criteria:
    - Checked-in baseline of expected branch-protection config (JSON snapshot)
    - CI job (or scheduled task) compares 'gh api' current config against baseline daily
    - Drift posts ALERT kind=queue_config_drift with the field-level diff
    - docs/MERGE_QUEUE_SETUP.md updated to describe the detector
  opened_date: '2026-04-26'

- id: INFRA-122
  domain: INFRA
  title: ambient.jsonl has no retention or rotation policy - grows unbounded
  status: open
  priority: P1
  effort: s
  description: |
    .chump-locks/ambient.jsonl is the file-side of the peripheral-vision
    stream and is appended to by every agent on every event. CLAUDE.md
    pre-flight reads only 'tail -30' so the file size is invisible to
    operators. There is no documented rotation, no size cap, no archival.
    On a long-running deployment (or after a busy multi-day burst like
    2026-04-25 / 2026-04-26) the file becomes multi-GB and slows down
    agents that read it. scripts/ambient-rotate.sh exists but is not
    referenced from CLAUDE.md and audit did not confirm it runs on a
    schedule. Adopt a rotation policy (size-based or time-based), document
    it, and wire it into launchd/cron alongside the existing reapers.
  acceptance_criteria:
    - Rotation policy documented in CLAUDE.md (size threshold, retention)
    - scripts/ambient-rotate.sh runs on a schedule (cron/launchd) and is verified to fire
    - Rotated archives are accessible to scripts/ambient-query.sh for historical lookups
    - Ambient ALERT when ambient.jsonl exceeds size threshold without rotation
  opened_date: '2026-04-26'

- id: INFRA-123
  domain: INFRA
  title: Reflection-row fields not consistently populated across dispatch paths
  status: open
  priority: P1
  effort: s
  description: |
    src/reflection_db.rs writes rows for every gap completion. CLAUDE.md
    documents specific tag conventions - notes prefix 'backend=<label>'
    (COG-025) and 'flags=cog_NNN' (COG-* experiments). Cold Water-style
    queries depend on these tags being present. Audit which dispatch
    paths actually populate which tags - if some emitters skip the
    backend tag, the COG-026 A/B aggregator splits will be undercounted
    or biased. Likely affects the chump-orchestrator dispatch path,
    direct 'claude -p' invocations, and chump --execute-gap.
  acceptance_criteria:
    - Audit every reflection-row emit site - list the tags each writes
    - Add a schema or assertion that required tags are present at write time
    - Backfill missing tags on historical rows where possible (or document the gap in measurements)
    - CLAUDE.md table of required tags per emitter path
  opened_date: '2026-04-26'

- id: INFRA-124
  domain: INFRA
  title: docs-delta Net-new-docs trailer not validated against actual diff
  status: open
  priority: P2
  effort: xs
  description: |
    The pre-commit docs-delta check (INFRA-009) computes ADDED-DELETED
    on docs/*.md and accepts a 'Net-new-docs: +N' trailer to declare
    intent. The trailer value is not verified to match the actual
    computed delta - a commit can claim 'Net-new-docs: +1' while
    actually adding 5 docs. The guard becomes blocking on 2026-04-28.
    Tighten the check so the trailer must match (or be a superset of)
    the computed delta.
  acceptance_criteria:
    - Pre-commit guard parses Net-new-docs trailer and asserts trailer >= computed delta
    - Mismatch fails closed with a diagnostic message
    - "Test - commit with Net-new-docs: +1 but actual +5 is rejected; matching trailer is accepted"
  opened_date: '2026-04-26'

- id: INFRA-125
  domain: INFRA
  title: chump-cost-tracker has zero tests - cost ceiling correctness unverified
  status: open
  priority: P1
  effort: m
  description: |
    crates/chump-cost-tracker/ exposes pub APIs (check_ceiling,
    session_cost_usd, record_provider_call, record_completion) used to
    enforce per-session spend caps and to attribute cost across providers.
    There is no tests/ subdirectory and no integration coverage. A
    regression that off-by-one errors the ceiling, attributes Together
    spend to OpenAI, or fails to record a completion would not be
    caught until the bill arrives. Add unit + integration tests covering
    ceiling enforcement, multi-provider attribution, and completion
    recording.
  acceptance_criteria:
    - Unit tests for check_ceiling boundary conditions (under/at/over)
    - Integration test for record_provider_call across at least 2 provider labels
    - Integration test that a session crossing the ceiling rejects further dispatch
    - All dispatch paths (claude, chump-local, orchestrator) verified to call record_*
  opened_date: '2026-04-26'

- id: INFRA-126
  domain: INFRA
  title: chump-coord test coverage limited to distributed_mutex - no reconnect/replay/ordering tests
  status: open
  priority: P1
  effort: m
  description: |
    crates/chump-coord/tests/ has distributed_mutex.rs (FLEET-007 proof)
    and now ambient_distribution.rs (FLEET-006 round-trip). Critical
    properties still untested - (a) NATS reconnect behavior when the
    server restarts mid-session, (b) JetStream message ordering under
    concurrent publishers, (c) replay correctness when a subscriber
    joins late, (d) backpressure / slow-consumer handling. Failures in
    any of these would silently corrupt the coordination layer that
    INFRA-MERGE-QUEUE and FLEET-007 depend on.
  acceptance_criteria:
    - Reconnect test - publish, kill NATS, restart, verify subscriber resumes
    - Ordering test - N concurrent publishers, single subscriber, assert per-publisher order preserved
    - Late-join replay test - subscribe with deliver_policy=All after N messages, assert all are received
    - Slow consumer test - subscriber with artificial delay, verify no message loss within JetStream max_age
  opened_date: '2026-04-26'

- id: INFRA-127
  domain: INFRA
  title: reflection_db has unit tests only - no end-to-end record then query then use coverage
  status: open
  priority: P1
  effort: s
  description: |
    src/reflection_db.rs has #[cfg(test)] blocks for individual functions
    but no integration test that traces the full path - a session writes
    a reflection row, the lessons-injection assembler queries it, and
    the next session sees the lesson in its prompt (CLAUDE.md
    CHUMP_LESSONS_AT_SPAWN_N pathway). Without this, the COG-016 / COG-024
    lesson-injection feature is functionally unverified end to end.
  acceptance_criteria:
    - Integration test - insert N reflection rows, run lesson selector, assert top-N by recency*frequency are returned
    - Integration test - simulate prompt assembly with CHUMP_LESSONS_AT_SPAWN_N=5 and assert the rendered prompt contains the expected lesson block
    - Cleanup - test uses a temp DB so it does not pollute prod state
  opened_date: '2026-04-26'

- id: INFRA-128
  domain: INFRA
  title: rename CHUMP_TO_COMPLEX → CHUMP_TO_CHAMP across repo (series-name finalization)
  status: done
  priority: P2
  effort: s
  description: |
    The series was renamed from "Chump to Complex" to "Chump to Champ" on
    2026-04-19, but the file at docs/CHUMP_TO_COMPLEX.md and 30+ references
    across docs/, book/src/, scripts/, and README.md still used the old name.
    This PR finalizes the rename:
      - git mv docs/CHUMP_TO_COMPLEX.md → docs/CHUMP_TO_CHAMP.md
      - git mv book/src/chump-to-complex.md → book/src/chump-to-champ.md
      - update scripts/sync-book-from-docs.sh to reflect the new path
      - sed-replace all variants (CHUMP_TO_COMPLEX, chump-to-complex,
        Chump-to-Complex, "Chump to Complex", "chump to complex") to
        their CHAMP equivalents across 33 files
    No semantic content change — only the series name is updated.
    Renumbered from INFRA-112 to INFRA-128 (collision with PR #580 reservation).
  acceptance_criteria:
    - docs/CHUMP_TO_COMPLEX.md no longer exists; docs/CHUMP_TO_CHAMP.md does
    - "0 remaining references to any \"Complex\" series-name variant in the repo (excluding archive)"
    - scripts/sync-book-from-docs.sh points at the new path
    - mdBook build script unchanged in shape
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-129
  domain: INFRA
  title: README narrative rewrite — surface dispatcher, demote research, truthful framing
  status: done
  priority: P2
  effort: s
  description: |
    The README led with the cognitive-architecture research as the headline
    differentiator, which (a) overstates an unvalidated research program
    relative to what the validated finding actually says (per
    docs/RESEARCH_INTEGRITY.md) and (b) buries the multi-agent dispatcher
    work entirely. Per user direction 2026-04-26: "we are more than a
    harness; we need an accurate modest/truthful narrative" and "bury
    research in the basement — it's slowing us down day to day."
    
    This rewrite:
      - Leads with two co-equal lanes: the agent + the dispatcher
      - Adds a "The dispatcher" section surfacing the coordination
        primitives as features (leases, ambient.jsonl, chump gap,
        worktrees, bot-merge.sh, pre-commit guards)
      - Demotes "Research" from a headline table to a small linked
        section with the accurate-thesis caveat
      - Removes the long bullet list of agent features in favor of
        narrative scoped to a "The agent" section
      - Updates docs link to docs/CHUMP_TO_CHAMP.md (matches INFRA-128)
    
    Renumbered from INFRA-113 to INFRA-129 (sibling PR #580 reserved INFRA-112..127).
  acceptance_criteria:
    - README leads with both agent + dispatcher framing, not single-agent only
    - Research findings table moved out of headline section to a small linked subsection
    - Dispatcher primitives table present (leases, ambient.jsonl, chump gap, worktrees, bot-merge, pre-commit guards)
    - All claims align with docs/RESEARCH_INTEGRITY.md (no overgeneralization)
    - Quickstart section preserved verbatim (golden-path)
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-130
  domain: INFRA
  title: adversary.rs has no integration tests - rule engine unverified end to end
  status: open
  priority: P1
  effort: s
  description: |
    src/adversary.rs (COMP-011a) has #[cfg(test)] unit tests for parsing
    but no integration test that exercises the full path - a tool call
    matches a rule, the action (warn/block) is taken, and an
    adversary_alert event is emitted to ambient.jsonl AND (post-FLEET-006)
    to NATS. With FLEET-006 just landing, this is a good moment to add
    the round-trip test before the dual-emit pattern bit-rots.
  acceptance_criteria:
    - Integration test - load a synthetic chump-adversary.yaml with one block rule, run a matching tool input, assert the call is blocked
    - Test verifies ambient.jsonl line is appended with kind=adversary_alert
    - If NATS available - test verifies chump.events.adversary_alert receives the event (skip if NATS unreachable, mirroring distributed_mutex.rs)
  opened_date: '2026-04-26'

- id: INFRA-131
  domain: INFRA
  title: stale root MDs cleanup + .env.minimal/README quickstart refresh
  status: done
  priority: P2
  effort: s
  description: |
    Tail of the README audit (2026-04-26): three small fixes that landed in
    one PR.
    1. Delete migration_proposal.md — abandoned planning sketch from 2026-04-18,
       0 references, the schema additions it proposed (created_at/updated_at)
       were never executed.
    2. README quick-start now defaults to qwen2.5:7b (~4.7 GB) instead of
       qwen2.5:14b (~9 GB). The 14B model triggers Ollama eviction under
       cargo-build memory pressure on 24 GB Apple Silicon (per dogfood
       memory note 2026-04-15/16); the 7B model passed T1.1 cleanly.
    3. .env.minimal now ships dogfood-tuned timeouts and context window
       (CHUMP_TOOL_TIMEOUT_SECS=180, CHUMP_COMPLETION_MAX_TOKENS=4096,
       CHUMP_OLLAMA_NUM_CTX=16384) so first-run users do not hit the 30s
       tool-timeout default at 2 tok/s.
    Note: adversary.md stays at root — it is a runtime asset loaded by
    src/adversary_llm.rs::load_adversary_md(), not a stale doc. Moving it
    is a separate (Rust-touching) change.
  acceptance_criteria:
    - migration_proposal.md deleted
    - "README quick-start uses qwen2.5:7b as default with 14B as larger option"
    - .env.minimal includes CHUMP_TOOL_TIMEOUT_SECS / CHUMP_COMPLETION_MAX_TOKENS / CHUMP_OLLAMA_NUM_CTX
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-132
  domain: INFRA
  title: Pre-push guard - cross-check Closes/Fixes trailers against gap titles to catch ID-reference hijacks
  status: done
  priority: P2
  effort: s
  description: |
    Concrete incident on 2026-04-26 - PR #578 ("stale root MDs cleanup +
    .env.minimal/README quickstart refresh") used "(INFRA-108)" in its
    title and "Closes INFRA-108." in the commit body, but on main the
    INFRA-108 entry actually reads "Audit and normalize all
    ambient.jsonl emitters" (the gap I had filed minutes earlier in
    PR #577). The hijack guard caught nothing because PR #578 did not
    edit the existing INFRA-108 entry in docs/gaps.yaml - it only
    referenced the ID in commit metadata. Ship pipeline auto-closure
    relies on those trailers, so a wrong reference can flip the wrong
    gap to done. Add a pre-push (or pre-commit, or bot-merge.sh) check
    that parses Closes/Fixes/Resolves trailers and warns when the
    referenced gap's title is materially unrelated to the PR title or
    commit subject (cosine distance threshold, or an explicit allowlist
    via "Closes-unrelated:" trailer). Pairs with INFRA-107 (closed_pr
    TBD guard) and INFRA-111 (mandate closed_interpretation field) -
    those guard the gap's own data; this guards the *reference* from a
    PR.
  acceptance_criteria:
    - Pre-push or bot-merge hook parses commit message Closes/Fixes/Resolves trailers
    - For each referenced gap ID, fetch its title from docs/gaps.yaml on origin/main
    - Compute similarity vs PR title and commit subject; below threshold emit a warning with both texts
    - Allow override via explicit Closes-unrelated trailer with justification
    - Test - synthetic PR titled 'cleanup X' that Closes a gap titled 'audit Y' triggers the warning
    - Documented in CLAUDE.md commit-time guards table
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 583

- id: INFRA-133
  domain: INFRA
  title: reconcile docs/audit→docs/audits + docs/synthesis→docs/syntheses (Phase 2 pre-work)
  status: done
  priority: P2
  effort: s
  description: |
    Pre-work for the Phase 2 docs/ categorization PR per
    `.chump/PHASE_2_3_5_PLAN.md`. Two pluralization-mismatch directories
    were splitting the same kind of content into two homes:
      - `docs/audit/` (2 files) merged into `docs/audits/` (4 existing)
      - `docs/synthesis/` (1 file + .last-run marker) merged into `docs/syntheses/` (3 existing)
    Cross-links updated in:
      - `.github/workflows/audit-weekly.yml` (audit-weekly job output path)
      - `scripts/audit/run-all.sh`, `scripts/audit/onboarding-sim.sh`
      - `scripts/synthesis-pass.sh`, `launchd/com.chump.synthesis-pass.plist`
      - `docs/AGENT_COORDINATION.md`
      - self-refs inside the moved files
    Historical references in `docs/gaps.yaml` (descriptions of past gaps)
    left intact — rewriting them would trigger the gap-ID-hijack guard
    and they are immutable history.
  acceptance_criteria:
    - docs/audit/ no longer exists; all 2 files in docs/audits/
    - docs/synthesis/ no longer exists; all content in docs/syntheses/
    - All non-historical cross-links updated
    - audit-weekly.yml workflow points at docs/audits/
    - synthesis-pass.sh writes to docs/syntheses/
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-134
  domain: INFRA
  title: docs/ root reorg — categorize root *.md into 10 subdirs (Phase 2 main)
  status: done
  priority: P2
  effort: m
  description: |
    Phase 2 main of the docs/ reorganization per `.chump/PHASE_2_3_5_PLAN.md`.
    Categorized 146 root `docs/*.md` files into 10 topical subdirectories so the
    docs/ tree mirrors the categories the rest of the repo already uses
    (architecture / operations / process / strategy / audits / research /
    briefs / api / syntheses / incidents). Only `docs/README.md` remains at
    the docs/ root as the canonical entry point.
    
    Distribution:
      - architecture/ +32  (system design, ADRs, protocols)
      - operations/   +25  (runbooks, perf, ops)
      - process/      +31  (dev workflow, coordination, governance)
      - strategy/     +32  (direction, vision, roadmaps)
      - audits/       +17  (retrospectives, audits, red letters)
      - research/     +12  (methodology, results, evidence logs)
      - briefs/       +3   (operator briefs)
      - api/          +3   (references)
    
    Cross-links rewritten across 375 files (.md / .rs / .sh / .yml / .toml /
    .json / .py / .ts) via a single 146-pattern perl pass. mdBook
    `scripts/sync-book-from-docs.sh` updated to point at new paths;
    `mdbook build book` verified clean locally. Reproducible plan checked
    in at `.chump/phase2-move-plan.sh` (run with `--check` to count, with
    `--sed-pairs` to regenerate the rewrite patterns).
  acceptance_criteria:
    - Only docs/README.md remains at docs/ root
    - 146 files distributed across 10 subdirs per the plan
    - All cross-links updated; no dangling refs introduced
    - scripts/sync-book-from-docs.sh points at new paths
    - mdbook build book succeeds locally
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-135
  domain: INFRA
  title: scripts/ reorg — categorize root scripts/* into subdirs (Phase 3)
  status: done
  priority: P2
  effort: m
  description: |
    Phase 3 of the repo reorg per `.chump/PHASE_2_3_5_PLAN.md`. Categorized
    290 root `scripts/*` files into 9 topical subdirectories so the scripts/
    tree mirrors the docs/ categorization shipped in INFRA-134.
    
    Distribution:
      - setup/   +66  (one-time bootstrap, install-* scripts)
      - ci/      +64  (CI helpers, integrity checks, audit tooling)
      - dev/     +61  (dev-loop helpers, war-room, briefing utilities)
      - eval/    +51  (eval harnesses, A/B sweeps, replay-trajectory)
      - coord/   +26  (gap-*, bot-merge.sh, chump-commit, broadcast)
      - plists/  +15  (launchd plist examples — already namespaced; left in place)
      - ops/     +5   (stale-* reapers, post-mortem)
      - release/ +1   (release tagging)
      - qa/      +1   (smoke harness)
    
    Cross-links rewritten via a single 290-pattern perl pass:
      - main pass: 391 files
      - launchd/plists: 14 files (15 substitutions)
      - .env.example + web/index.html: 2 files (18 substitutions)
      - scripts/git-hooks: 4 files (8 substitutions)
      Total: 411 files, 1726 substitutions
    
    Rust prefix patterns updated (briefing.rs:432, main.rs:1970 doc comment).
    cargo check passes. Reproducible plan at `.chump/phase3-categorize.sh`
    (modes: default mapping output, --counts, --uncategorized, --sed-pairs,
    --execute). Pre-existing syntax errors in
    scripts/setup/enter-chump-mode.sh and scripts/dev/war-room.sh confirmed
    in main, left out of scope.
  acceptance_criteria:
    - 290 root scripts/* files distributed across 9 subdirs per the plan
    - Cross-links updated across all callers (.rs/.sh/.yml/.md/.json/git-hooks)
    - cargo check passes
    - src/briefing.rs prefix patterns updated for new scripts/coord/ paths
    - Reproducible categorization plan committed at .chump/phase3-categorize.sh
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-136
  domain: INFRA
  title: Version-control adversarial agent prompts — Cold Water and siblings live only in trigger config
  status: done
  priority: P2
  effort: s
  description: |
    Cold Water, Frontier Scientist, Scribe, and the tech-writer/gardener
    agents are scheduled remote triggers (claude.ai/code/scheduled). Their
    prompts live exclusively in trigger config and are not in the repo. If
    a trigger is migrated, deleted, or accidentally reset, the prompt is
    lost. The Cold Water prompt was substantially rewritten on 2026-04-26
    (added Step -1 sandbox preflight, Step 0 prior-issue reconcile, five
    lenses, mandatory gap-filing with sandbox fallback) - that work has no
    git history. Mirror each adversarial-agent prompt under
    docs/agents/<name>.md as the source of truth, and document the
    schedule trigger ID it deploys to. Schedule operator updates the
    trigger from the doc, not vice versa.
  acceptance_criteria:
    - docs/agents/cold-water.md, frontier-scientist.md, scribe.md, tech-writer.md exist with current prompt content
    - Each doc names its trigger_id and cron schedule
    - docs/agents/README.md explains the docs-are-source convention
    - When a prompt changes - update the doc, then sync the trigger via /schedule
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-137
  domain: INFRA
  title: Phase 3 follow-up — Python parents[1] + cross-subdir SCRIPT_DIR refs
  status: done
  priority: P1
  effort: s
  description: |
    PR #591 (INFRA-135 Phase 3 reorg) landed but two patterns were not covered
    by the 153-file relative-path bump in INFRA-136:
    
    1. Python scripts using `Path(__file__).resolve().parents[1]` to reach repo
       root — now resolves to scripts/ instead. Bumped to parents[2] in 5 files
       (mdbook-linkcheck.py is the build-and-linkcheck root cause).
    
    2. Bash scripts using `$SCRIPT_DIR/sibling.sh` where the sibling moved to a
       different subdir. Inserted REPO_ROOT and rewrote refs to absolute paths.
       Plus 13 files using `$SCRIPT_DIR/..` as repo root → `$SCRIPT_DIR/../..`.
    
    Re-filed under INFRA-137 because INFRA-136 was claimed concurrently by PR
    #592 (agents/META-001 work) and merged before this fix could ship.
  acceptance_criteria:
    - build-and-linkcheck CI passes on this PR
    - All 5 Python scripts with parents[1] bug are fixed
    - All 13 bash scripts with $SCRIPT_DIR/.. bug are fixed
    - Cross-subdir bash sibling refs use $REPO_ROOT/scripts/<dir>/<name>
  opened_date: '2026-04-26'
  closed_date: '2026-04-28'
  closed_pr: 594

- id: INFRA-138
  domain: INFRA
  title: Phase 3 follow-up — fix relative-path scripts broken by reorg (supersedes PR
  status: done
  priority: P1
  effort: s
  description: |
    PR #587 (INFRA-135 Phase 3 scripts/ reorg) failed required CI on 4 jobs because
    the move from `scripts/<name>.sh` to `scripts/<subdir>/<name>.sh` broke 155
    scripts that resolved repo root via `dirname/..`:
    
      ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # was repo root, now scripts/
    
    Failures observed:
      - mdBook verify (build-and-linkcheck) — sync-book-from-docs.sh `cp` from wrong CWD
      - mdBook verify (sync-idempotency)    — same
      - test (Verify web/index.html inline JS parses) — verify-web-index-inline-scripts.cjs
        looked for scripts/web/index.html
      - ACP protocol smoke test — test-acp-smoke.sh exec'd ./target/debug/chump from
        scripts/ instead of repo root → empty output → `FAIL: No output from chump --acp`
    
    This PR (1) supersedes #587 by including all 290 Phase 3 moves AND (2) bumps
    `dirname/..` → `dirname/../..` in 153 bash scripts and adds an extra `'..'`
    to 2 .cjs files (verify-web-index-inline-scripts.cjs, run-web-ui-selftests.cjs).
    
    Smoke-tested locally before push:
      - bash scripts/dev/sync-book-from-docs.sh        → silent success
      - node scripts/ci/verify-web-index-inline-scripts.cjs → OK
      - node scripts/ci/run-web-ui-selftests.cjs       → 11 checks passed
      - bash scripts/ci/test-acp-smoke.sh              → 7 passed, 0 failed
    
    PR #587 closed as superseded after this lands.
  acceptance_criteria:
    - All 4 previously-failing required CI checks pass on this PR
    - 153 moved bash scripts use `dirname/../..` to find repo root
    - 2 .cjs files use `__dirname, '..', '..'` to find repo root
    - Smoke tests for sync-book / verify-web-index / acp-smoke all pass locally
    - "PR #587 closed as superseded; this PR lands the combined work"
  opened_date: '2026-04-26'
  closed_date: '2026-04-26'

- id: INFRA-139
  domain: INFRA
  title: Move gaps-yaml-integrity check into merge-queue rebase phase to prevent parallel-PR ID collisions
  status: open
  priority: P1
  effort: m
  description: |
    On 2026-04-26 two PRs (#590 agent-prompts, #591 Phase-3 follow-up) both
    reserved INFRA-136 from concurrent worktrees within the same hour. Both
    landed on main, leaving a duplicate ID that broke `gaps-yaml-integrity`
    on every subsequent PR (#593, #594, #595). The collision required a
    manual fix (renaming one to INFRA-138 + flipping the other to done in
    a separate PR).
    
    Why the existing guards failed:
      - `gap-reserve.sh` is atomic *within one worktree* but reads only
        local main + open PRs; it cannot see another worktree's lease that
        was filed after gap-reserve scanned but before the PR opened.
      - The pre-commit duplicate-ID guard (INFRA-GAPS-DEDUP) only sees the
        current branch's gaps.yaml — by definition cannot detect duplicates
        introduced by a sibling branch.
      - CI's `gaps-yaml-integrity` check runs on each PR's branch tip but
        NOT on the merge-queue's rebased temp branch. So PR #590 passes
        integrity (uses INFRA-136), PR #591 passes integrity (uses
        INFRA-136), the queue rebases #591 onto #590's main without
        re-running the integrity check, and the duplicate lands.
    
    Fix: require `gaps-yaml-integrity` to run in the merge-queue rebase
    phase, OR add a server-side branch-protection gate that re-runs the
    check against the merge-base. Either prevents the collision class.
  acceptance_criteria:
    - Merge-queue rebased temp branch runs `gaps-yaml-integrity` before squash
    - "Test: simulate two PRs reserving the same gap ID; second one is blocked at merge time"
    - Document the new gate in docs/process/MERGE_QUEUE_SETUP.md
  opened_date: '2026-04-26'

- id: INFRA-140
  domain: INFRA
  title: "gap-status-check is over-eager — fails legitimate \"filed and closed in same PR\" pattern"
  status: open
  priority: P2
  effort: s
  description: |
    The `gap-status-check` CI guard interprets a PR title with `<GAP-ID>:`
    prefix as "this PR closes that gap" and fails if gaps.yaml does not
    show `status: done` for that ID. It does not handle the legitimate
    pattern of filing a new gap and closing it in the same PR (the
    PR opens with the gap as the entry, the same PR flips it to done).
    
    Observed on PR #593 (sibling-agent attempt at the INFRA-136 path-fix):
    title `INFRA-136: fix Python parents[1]...` triggered the close-implies-flip
    rule but INFRA-136 in main was status: open at the time. The agent had
    not yet committed the status flip. False-positive blocked the PR until
    self-closed.
    
    Fix: either (a) require the YAML to show done OR show the entry being
    *added* with status: done in this PR's diff, or (b) introduce a separate
    `<GAP-ID>+:` prefix convention for "files this gap" vs `<GAP-ID>:` for
    "closes this gap".
  acceptance_criteria:
    - "PR titled `<ID>:` that adds the entry with status:done in same diff passes"
    - Existing close-of-prior-gap PRs still pass
    - Documentation explains the convention in CLAUDE.md
  opened_date: '2026-04-26'

- id: INFRA-141
  domain: INFRA
  title: scripts/setup/deploy-fleet.sh references undefined $REPO_ROOT
  status: open
  priority: P3
  effort: xs
  description: |
    scripts/setup/deploy-fleet.sh defines `ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"`
    at line 27, then references `$REPO_ROOT` at lines 59 and 169 to invoke
    `bash "$REPO_ROOT/scripts/dev/fleet-health.sh"`. `$REPO_ROOT` is never
    defined in this script (set -u would fail; without it the path resolves
    to `/scripts/dev/fleet-health.sh`).
    
    Likely a linter rewrite that mass-substituted `$ROOT` → `$REPO_ROOT`
    without checking the variable's definition in this specific script.
    Quick fix: either rename the local var to `REPO_ROOT` (consistent with
    other scripts) or change both refs back to `$ROOT`.
  acceptance_criteria:
    - deploy-fleet.sh passes shellcheck (no undefined var references)
    - fleet-health.sh invocations resolve to repo-relative path
    - "--health flag actually runs the health check (currently broken)"
  opened_date: '2026-04-26'

- id: INFRA-142
  domain: INFRA
  title: Audit chain verifier vs 200-row cap interaction - false-positive tamper warnings every time a row ages out
  status: open
  priority: P2
  effort: s
  description: |
    src/introspect_tool.rs ships two features that fight each other.
    On insert it computes audit_hash = SHA256(prev_audit_hash || ts ||
    tool || args || outcome) where prev = last row's audit_hash, then
    deletes oldest rows beyond a 200-row cap. On startup
    audit_chain_status walks rows id ASC starting from
    "genesis_hash_..." and recomputes each hash. The moment the cap
    deletes an old row, the new oldest survivor still has its stored
    audit_hash chained to a now-deleted predecessor - so the verifier's
    computed hash for that row never matches and every row after also
    fails. Result - a SECURITY WARNING fires on every chump invocation
    after the table fills, and the blackboard receives a high-salience
    "TAMPER DETECTED" message that is actually just the cap working as
    designed. Discovered 2026-04-26 when chump --help printed the
    warning and an audit traced row 429 (the current min id) chained
    against deleted row 428. Workaround on 2026-04-26 - rehashed all
    surviving rows from genesis (DB backup at
    sessions/chump_memory.db.pre-rehash.bak); will break again next
    time a row ages out.
  acceptance_criteria:
    - Decide - either (a) verifier treats the oldest surviving row's stored hash as a new genesis (rolling-genesis pattern), or (b) cap retains a sentinel row pinning the chain origin, or (c) drop the chain hash entirely and rely on append-only rotation
    - Implementation in src/introspect_tool.rs matches chosen design
    - Test - insert 250 rows then verify chain still passes audit_chain_status
    - Test - tamper with a non-cap-victim row and confirm verifier still detects it
    - Document the rolling-genesis (or chosen) semantics in the function docstring
  opened_date: '2026-04-26'

- id: INFRA-143
  domain: INFRA
  title: "gap_store::reserve silently swallows import_from_yaml errors → fix loud + repair gap[17] source_doc schema"
  status: done
  priority: P1
  effort: s
  opened_date: '2026-04-27'
  closed_date: '2026-04-27'

- id: INFRA-144
  domain: INFRA
  title: "CI guard: state.db ↔ docs/gaps.yaml drift detector at PR time"
  status: open
  priority: P1
  effort: s
  opened_date: '2026-04-27'

- id: INFRA-145
  domain: INFRA
  title: auto-backfill closed_date for pre-column done rows
  status: done
  priority: P2
  effort: s
  description: |
    Auto-backfill closed_date for status=done rows whose closed_date is empty (originally seen on FLEET-006, DOC-007, INFRA-083 — pre-migration leftovers). Adds a one-shot UPDATE to gap_store::migrate() that derives closed_date from closed_at when status='done' AND closed_date='' AND closed_at>0. Idempotent on subsequent opens.
  closed_date: '2026-04-28'
  closed_pr: 613

- id: INFRA-146
  domain: INFRA
  title: tauri-cowork-e2e flake — empty assistant bubble + SQLite lock at startup
  status: done
  priority: P3
  effort: xs
  description: |
    Renamed from INFRA-144 on 2026-04-27 to deduplicate concurrent-invention collision: PR #611 (skills CHUMP_BRAIN_PATH race) and PR #612 (this entry, tauri-cowork-e2e flake) both filed under INFRA-144 within minutes of each other and both landed on main, leaving docs/gaps.yaml with two `- id: INFRA-144` rows that broke the gaps-yaml-integrity CI check on every open PR. PR #611's entry keeps INFRA-144; this one (PR #612, landed in commit c9bfebc) becomes INFRA-146.
  closed_date: '2026-04-27'

- id: INFRA-147
  domain: INFRA
  title: chump gap dump preserves YAML meta block (use dump_yaml_with_meta in CLI)
  status: done
  priority: P2
  effort: xs
  closed_date: '2026-04-28'
  closed_pr: 616

- id: INFRA-148
  domain: INFRA
  title: chump CLI binary staleness detection — silent gaps.yaml corruption when binary predates gap_store.rs changes
  status: open
  priority: P1
  effort: s
  description: |
    INFRA-147 (PR #616) added `dump_yaml_with_meta` to preserve the meta:
    preamble during `chump gap dump` / `chump gap ship --update-yaml`. The
    fix is correct in source but does NOT take effect until each operator
    rebuilds and reinstalls the chump binary. Operators with stale binaries
    in $PATH will still strip the meta: block on regenerate — silently
    corrupting docs/gaps.yaml with a 20k-line diff on every ship.
    
    Hit live on 2026-04-27 during the COG-038 / INFRA-146 closure PR: my
    `~/.local/bin/chump` was dated Apr 26 11:55 (pre-INFRA-147), so
    `chump gap ship --update-yaml` regenerated gaps.yaml without the meta:
    block. Reverted manually and hand-edited the closures instead. The
    coordination layer has no signal for "your binary is older than the
    most recent gap_store-affecting commit on origin/main" — agents can not
    tell their binary is dangerous before they run it.
    
    The same risk applies to any future `gap_store.rs` / `main.rs` change
    that affects YAML serialization: silent corruption until every operator
    rebuilds.
    
    Fix options (pick one or stack):
      (a) `chump --version` bakes in the git SHA at build; `chump gap ship
          --update-yaml` and `chump gap dump --out PATH` warn or refuse if
          HEAD has commits touching `crates/*/src/gap_store.rs` or
          `src/main.rs`'s gap subcommand wiring after the baked SHA.
      (b) Pre-commit hook on PRs that mutate gap_store.rs / gap subcommand
          wiring posts a banner reminding operators to reinstall the binary
          before running `chump gap ship --update-yaml` again.
      (c) `bot-merge.sh` self-checks `chump --version` against
          `git log origin/main -- src/gap_store.rs` and prints a warning if
          the binary predates the latest gap_store change.
    Option (a) is the most operator-friendly (refuses unsafe op at the right
    moment); (c) is the cheapest to implement.
  acceptance_criteria:
    - chump CLI bakes git commit SHA at build time (env! / build.rs)
    - chump gap ship --update-yaml and chump gap dump --out PATH detect when origin/main has gap_store-affecting commits newer than the baked SHA
    - detection emits a clear warning (or refuses, behind --force) telling operators to rebuild + reinstall
    - "regression test: stub a baked SHA older than HEAD and verify the warn-or-refuse path fires"
    - "docs/gaps.yaml meta: preamble survives the regen path with a fresh binary (smoke test)"
  opened_date: '2026-04-27'

- id: INFRA-149
  domain: INFRA
  title: "skill_hub::tests::default_registries_reads_env env-leak flake — passes alone, fails in full cargo test suite"
  status: done
  priority: P2
  effort: xs
  description: |
    `src/skill_hub.rs:538` `default_registries_reads_env` mutates the
    process-global `CHUMP_SKILL_REGISTRIES` env var without
    `#[serial_test::serial]`. Adjacent tests in the same module DO use the
    serial guard for the same reason (see `install_from_content_writes_skill`
    at line 552). Under cargo's default parallel runner, another thread
    racing on `default_registries()` can observe `len() == 0` between
    `set_var` and the assertion at line 544 — which is exactly what shipped
    the failure during 2026-04-27 INFRA-148 bot-merge.sh:
    
      thread 'skill_hub::tests::default_registries_reads_env' panicked at
      src/skill_hub.rs:544:9:
      assertion `left == right` failed
        left: 0
       right: 2
    
    Reproduces only in the full suite; `cargo test --bin chump
    skill_hub::tests::default_registries_reads_env` passes consistently in
    isolation. This makes bot-merge.sh's local cargo test step flaky and
    forces the INFRA-028 manual ship recovery path on otherwise clean PRs.
    
    Fix: add `#[serial_test::serial]` to `default_registries_reads_env`
    (one-line change). Optional: audit other tests in `src/skill_hub.rs`
    and `src/main.rs` that mutate process env without the serial guard.
    
    Filing arrived after the implementation (PR #624 landed first).
    INFRA-155 documents the ghost-gap pattern this represents and proposes
    `chump gap doctor` to detect it systematically.
  acceptance_criteria:
    - "default_registries_reads_env carries #[serial_test::serial]"
    - cargo test --bin chump (full suite) passes 10/10 consecutive runs locally
    - no other tests in src/skill_hub.rs mutate process env without serial guard (audit)
  opened_date: '2026-04-28'
  closed_date: '2026-04-28'
  closed_pr: 624

- id: INFRA-152
  domain: INFRA
  title: chump gap set/ship — accept --closed-pr flag, persist to state.db, emit to YAML
  status: open
  priority: P1
  effort: s

- id: INFRA-154
  domain: INFRA
  title: "bot-merge.sh: auto-flip gap status to done after PR merges"
  status: done
  priority: P1
  effort: s
  closed_date: '2026-04-28'

- id: INFRA-155
  domain: INFRA
  title: Detect and repair YAML/SQLite gap-store drift (INFRA-097/149 cases)
  status: done
  priority: P1
  effort: m
  closed_date: '2026-04-28'
  closed_pr: 641

- id: INFRA-156
  domain: INFRA
  title: chump gap set/ship needs --closed-pr flag for INFRA-107 guard
  status: done
  priority: P2
  effort: xs
  closed_date: '2026-04-28'
  closed_pr: 637

- id: INFRA-157
  domain: INFRA
  title: "fix: ftue-clean-machine workflow YAML parse error blocked all PRODUCT-017 verification runs"
  status: open
  priority: P1
  effort: xs

- id: INFRA-158
  domain: INFRA
  title: "ftue-clean-machine workflow: brew install fails because local-file formula path is rejected (must be in a tap)"
  status: done
  priority: P1
  effort: xs
  closed_date: '2026-05-02'
  closed_pr: 727

- id: INFRA-159
  domain: INFRA
  title: "ftue-clean-machine workflow: GitHub Actions cannot create PRs — switch to direct push"
  status: done
  priority: P1
  effort: xs
  closed_date: '2026-05-01'
  closed_pr: 699

- id: INFRA-160
  domain: INFRA
  title: 4 orphan rows in state.db with no docs/gaps.yaml entry (COG-039, INFRA-087, INFRA-152, TEST-001)
  status: open
  priority: P1
  effort: xs
  description: |
    `gap-doctor.py doctor` (INFRA-155, shipped 2026-04-28) flags Bucket 3
    drift: gap rows present in `.chump/state.db` but with no
    corresponding `- id:` entry in `docs/gaps.yaml`. As of 2026-04-28
    21:30 UTC, four rows are in this state:
    
      - COG-039     — title: "bench harness — flag-off baseline vs cog_037-on Thompson router"
      - INFRA-087   — title: "automated repo failure-detection auditor + CI-time health checks"
      - INFRA-152   — title: "chump gap set/ship — accept --closed-pr flag, persist to state.db, emit to YAML"
      - TEST-001    — title: (unknown — test fixture leakage)
    
    Mechanism: `chump gap reserve` writes pending_new_gap to the local
    lease + bumps the SQL counter. If the corresponding YAML row never
    lands on origin/main (PR closed without merging, branch abandoned,
    YAML edit rolled back during a conflict), the DB row persists.
    `chump gap reserve` then can't reuse the ID (counter has advanced),
    but no human-readable record of the gap exists either. Cold Water
    can't classify them. INFRA-149 was a recent example with the same
    pattern (PR shipped #624 referencing the ID without the YAML row;
    later filed as a real gap in #621).
    
    For each of the 4 rows, decide:
      (a) Dump to YAML — `chump gap dump --out docs/gaps.yaml` writes
          all DB rows; preserves meta: preamble per INFRA-147. This is
          right when the work is real and ongoing.
      (b) Delete from DB — `sqlite3 .chump/state.db "DELETE FROM gaps
          WHERE id='XXX'"`. Right when the row was a test artifact or
          a reserve that should never have happened.
      (c) Mark retired — set status=done with a notes:
          "retired without filing: <reason>" if the work was abandoned
          intentionally.
    
    TEST-001 is almost certainly (b) — the test-suite probably leaked
    a fixture row. The other three need per-row research (look at
    `git log --grep=<ID>` on origin/main).
  acceptance_criteria:
    - Bucket 3 drift count is 0 (or only contains rows that were intentionally orphaned with documented reason)
    - Each of COG-039, INFRA-087, INFRA-152, TEST-001 has an explicit fate (filed / deleted / retired) recorded in this PR's body
    - If any row was added to YAML, it has the standard fields and a `raised_by` / `raised_in` recording the original reservation date
    - "TEST-001 specifically: trace which test script reserved it and patch the script to use a temp/sandbox repo (per the same discipline INFRA-076 §3b applies to user.email)"
  opened_date: '2026-04-28'

- id: INFRA-161
  domain: INFRA
  title: "ftue-clean-machine workflow: brew install fails because local-file formula path rejected (must be in tap)"
  status: done
  priority: P1
  effort: xs
  closed_date: '2026-04-29'
  closed_pr: 654

- id: INFRA-162
  domain: INFRA
  title: "ftue-clean-machine workflow: GitHub Actions cannot create PRs — switch to direct push"
  status: open
  priority: P1
  effort: xs

- id: INFRA-163
  domain: INFRA
  title: chump lesson add CLI — let agents seed chump_improvement_targets without sqlite3
  status: open
  priority: P1
  effort: s

- id: INFRA-164
  domain: INFRA
  title: Drop ChumpMenu from steady-state launch path; document PWA as canonical local UI
  status: done
  priority: P1
  effort: s
  description: |
    ChumpMenu (Tauri menubar) auto-spawns its own chump --web sidecar (desktop/src-tauri/src/lib.rs:28-199). When operator also launches ./run-web.sh, two chump processes each maintain independent reqwest::Client → ESTABLISHED connections to ollama:11434. Ollama serializes per-runner so the two queues block each other (observed: 3 ESTABLISHED conns, 80+ s stalled turns). ChumpMenu adds no inference-unique workload — it's a UI wrapper around the PWA. This gap removes ChumpMenu from the steady-state launch path; doc the canonical UI as http://localhost:3000 in a regular browser. Code-level deletion of the Tauri sidecar-spawn block is a follow-on gap.
  acceptance_criteria:
    - "docs/operations/INFERENCE_PROFILES.md names PWA at localhost:3000 as the canonical local UI"
    - run-web.sh referenced as the canonical entry point
    - operator launchd plist for ChumpMenu (if any) called out as 'remove for steady-state' in the doc
    - no Rust/Tauri code changes in this PR — pure operational/doc
  notes: |
    See ~/.claude/plans/local-first-is-the-eager-hopcroft.md (approved 2026-04-28). Part of the local-first redesign filed after today's three-way runner contention incident (ChumpMenu + chump --web + autopilot all queued on one Ollama runner). Sub-problem #1 of 6. Why first: closes ESTABLISHED-connection-contention failure class with zero code. Tauri code deletion deferred to its own follow-on so this PR stays scoped.
  closed_date: '2026-04-29'
  closed_pr: 661

- id: INFRA-165
  domain: INFRA
  title: Singleton Arc<Provider> + global inference Semaphore (CHUMP_INFERENCE_PERMITS)
  status: open
  priority: P1
  effort: m
  description: |
    Today: provider_cascade::build_provider() (src/provider_cascade.rs:859-901) creates a fresh LocalOpenAIProvider + reqwest::Client on every call. No connection reuse, no shared inference owner. handle_chat in src/web_server.rs:1955, discord.rs:564-603, spawn_worker_tool.rs:207 all build their own. Result: free-for-all async; no backpressure; autopilot can collide with user turn. This gap makes the provider a process-singleton (Arc<dyn Provider + Send + Sync> in AppState) and wraps complete() in a tokio::sync::Semaphore with CHUMP_INFERENCE_PERMITS env (default 1, mirroring the CHUMP_MAX_CONCURRENT_TURNS=1 steady-state recommendation in STEADY_RUN.md/PERFORMANCE.md §3). This same semaphore is the fleet seam: future FLEET-014 swaps the Provider impl for a remote one without changing the trait surface.
  acceptance_criteria:
    - src/web_server.rs AppState owns Arc<dyn Provider> initialized once at startup
    - tokio Semaphore with CHUMP_INFERENCE_PERMITS env (default 1) gates complete() calls
    - all in-process callers (web handle_chat, discord, spawn_worker_tool) use the shared instance — no remaining build_provider calls outside bootstrap
    - two concurrent /api/chat curls show the second waiting on the first (verified via CHUMP_LOG_TIMING=1)
    - "lsof -nP -iTCP:11434 shows ONE ESTABLISHED chump→ollama connection, not N"
    - "new test: cargo nextest run --package chump web_server::semaphore_gate (2 concurrent fake-LLM calls, second waits)"
    - existing agent_loop + web_server test suites pass unchanged
  depends_on: [INFRA-164]
  notes: |
    See ~/.claude/plans/local-first-is-the-eager-hopcroft.md (approved 2026-04-28). Part of the local-first redesign filed after today's three-way runner contention incident (ChumpMenu + chump --web + autopilot all queued on one Ollama runner). Sub-problem #2 of 6 (the core fix). Reuses tokio::sync::Semaphore (already used for SPAWN_SEMAPHORE in spawn_worker_tool.rs) and the existing Provider trait. Lifecycle change, not a new abstraction. depends-on: INFRA-164.

- id: INFRA-166
  domain: INFRA
  title: Autopilot/background loops skip-if-busy via inference-semaphore probe
  status: open
  priority: P2
  effort: s
  description: |
    src/web_server.rs:2496-2518 schedules an autopilot reconcile every 3 minutes via tokio::task::spawn_blocking with no semaphore awareness. It can fire mid-user-turn, queue behind interactive chat, or trigger model load races. Discord has CHUMP_MAX_CONCURRENT_TURNS but the web path has no equivalent. Once INFRA-165 lands, the global inference semaphore exists; this gap makes the autopilot tick read inference_semaphore.available_permits() and no-op (with an ambient.jsonl log entry) when 0.
  acceptance_criteria:
    - autopilot tick reads available_permits() before scheduling LLM-touching work
    - "when permits=0, tick logs 'autopilot: skipped — inference busy' and emits an ambient.jsonl entry"
    - no LLM call is made on a skipped tick
    - "verification: send a long PWA turn; tail /tmp/chump-web.log shows the skip log on the next 3-min tick"
  depends_on: [INFRA-165]
  notes: |
    See ~/.claude/plans/local-first-is-the-eager-hopcroft.md (approved 2026-04-28). Part of the local-first redesign filed after today's three-way runner contention incident (ChumpMenu + chump --web + autopilot all queued on one Ollama runner). Sub-problem #3 of 6. ~10 lines once INFRA-165 is in. Restores to the web path the Discord-only CHUMP_MAX_CONCURRENT_TURNS bound, implicitly via the global semaphore.

- id: INFRA-167
  domain: INFRA
  title: chump --web startup pre-warm + canonical CHUMP_OLLAMA_KEEP_ALIVE=30m default
  status: done
  priority: P2
  effort: s
  description: |
    On chump --web startup, fire one stateless keep_alive-only request to the local model so the first user turn doesn't pay cold-load (~10-30s for a 9GB Q4 14B; 5-15s for a 4.7GB 7B). Canonicalize CHUMP_OLLAMA_KEEP_ALIVE=30m in .env.example. Document the trade in docs/PERFORMANCE.md: 30m is the default; raise to never (-1) only if operator has headroom. Pattern: POST /api/generate with {model, keep_alive:'30m', prompt:'warmup', options:{num_predict:1}} — same as the manual pre-warm used in this session.
  acceptance_criteria:
    - src/web_server.rs startup hook (after bind) issues a keep_alive-only request to the local model
    - .env.example sets CHUMP_OLLAMA_KEEP_ALIVE=30m as canonical
    - docs/PERFORMANCE.md has a paragraph on the keep-alive/RAM trade
    - "verification: kill chump --web, relaunch, send a one-word turn within first 5s — total <20s vs 60+s without pre-warm; /api/ps shows model resident with 30m expiry"
  depends_on: [INFRA-165]
  notes: |
    See ~/.claude/plans/local-first-is-the-eager-hopcroft.md (approved 2026-04-28). Part of the local-first redesign filed after today's three-way runner contention incident (ChumpMenu + chump --web + autopilot all queued on one Ollama runner). Sub-problem #4 of 6. Lift the Bash pre-warm from this session into Rust. Pairs well with PRODUCT-023 (7B model means pre-warm holds ~5GB not 9GB).
  closed_date: '2026-05-02'
  closed_pr: 720

- id: INFRA-168
  domain: INFRA
  title: Rewire coord shell scripts (gap-preflight/claim/reserve/bot-merge) to read .chump/state.db, not docs/gaps.yaml
  status: open
  priority: P1
  effort: m
  description: |
    scripts/coord/gap-preflight.sh, gap-claim.sh, gap-reserve.sh, and bot-merge.sh still parse docs/gaps.yaml as their source of truth. Authority moved to .chump/state.db in INFRA-059 (2026-04-25), so the shells are now operating on a regenerated mirror. Today's PRODUCT-022 ship cycle hit two cascading failures: (1) preflight rejected a gap that was reserved in SQLite but not yet mirrored to YAML; (2) something (hook? chump-coord watch? gap-claim itself?) regenerated gaps.yaml from SQLite mid-flow, which dirtied the working tree and made bot-merge.sh's rebase abort. The Rust CLI already has chump gap preflight/claim/reserve/ship — this gap rewires the shells to call them, so the YAML is no longer load-bearing for tooling (only for human PR review).
  acceptance_criteria:
    - scripts/coord/gap-preflight.sh calls 'chump gap preflight <ID>' instead of grepping docs/gaps.yaml
    - scripts/coord/gap-claim.sh calls 'chump gap claim' for SQLite-side state (lease file behavior unchanged)
    - scripts/coord/gap-reserve.sh delegates to 'chump gap reserve' (the shell wrapper still exists for back-compat but no longer parses YAML)
    - scripts/coord/bot-merge.sh's preflight invocation works for gaps that exist in SQLite even when not yet in YAML (eliminating the CHUMP_ALLOW_UNREGISTERED_GAP=1 escape hatch for normal flows)
    - nothing regenerates docs/gaps.yaml outside 'chump gap ship --update-yaml' and 'chump gap dump' — verified by audit of hooks and chump-coord watch
    - "test: reserve a new gap in SQLite, immediately run gap-preflight + gap-claim + bot-merge.sh on a fresh worktree — full ship without escape hatches, with gaps.yaml regenerated only at the auto-close-on-ship step"
  notes: |
    Filed during the PRODUCT-022 ship that motivated it. Today's symptom: 'M docs/gaps.yaml' kept reappearing in the unstaged column after each git checkout origin/main, blocking bot-merge.sh rebase. Likely culprits: gap-claim.sh side effect, chump-coord watch background process, or a post-checkout hook. Audit those as part of the fix. Cross-link with INFRA-155 (gap-doctor.py drift detector — already running) and the auto-close-on-ship flow (INFRA-154, 2026-04-28).

- id: INFRA-169
  domain: INFRA
  title: "ftue-clean-machine workflow: cannot land artifact on main — Actions blocked from both PR-create AND direct-push"
  status: open
  priority: P1
  effort: xs

- id: INFRA-170
  domain: INFRA
  title: chump lesson add CLI (renamed from INFRA-163 collision)
  status: done
  priority: P1
  effort: s
  closed_date: '2026-05-02'
  closed_pr: 706

- id: INFRA-171
  domain: INFRA
  title: "ftue-clean-machine workflow: tighten cadence — per-PR (path-filtered) + weekly cron, drop monthly"
  status: open
  priority: P1
  effort: xs

- id: INFRA-172
  domain: INFRA
  title: Enable Homebrew installer in cargo-dist + create repairman29/homebrew-chump tap (true <60s FTUE)
  status: done
  priority: P0
  effort: s
  closed_date: '2026-05-02'
  closed_pr: 677

- id: INFRA-173
  domain: INFRA
  title: "FTUE workflow: test bottle path (real user) once bottles exist; keep source-build as fallback"
  status: open
  priority: P1
  effort: xs

- id: INFRA-174
  domain: INFRA
  title: Enable Homebrew installer in cargo-dist + create repairman29/homebrew-chump tap (renamed from INFRA-172 collision)
  status: done
  priority: P0
  effort: s
  closed_date: '2026-04-30'
  closed_pr: 677

- id: INFRA-175
  domain: INFRA
  title: "FTUE workflow: test bottle path (real user) once bottles exist; keep source-build as fallback (renamed from INFRA-173 collision)"
  status: open
  priority: P1
  effort: xs

- id: INFRA-176
  domain: INFRA
  title: "release.yml: auto-publish formula to homebrew-chump tap on every release (HOMEBREW_TAP_TOKEN)"
  status: open
  priority: P1
  effort: xs

- id: INFRA-177
  domain: INFRA
  title: "narration-detection retry: 50+ false-positive phrases waste 2 model rounds per conversational reply"
  status: done
  priority: P0
  effort: s
  closed_date: '2026-05-02'
  closed_pr: 687

- id: INFRA-178
  domain: INFRA
  title: PWA chat bubble concatenates multi-round responses — clear text on model_call_start
  status: done
  priority: P1
  effort: xs
  closed_date: '2026-05-02'
  closed_pr: 711

- id: INFRA-179
  domain: INFRA
  title: scripts/dev/restart-chump-web.sh — one-command kill + rebuild + relaunch local PWA server
  status: open
  priority: P2
  effort: xs

- id: INFRA-180
  domain: INFRA
  title: send 5KB of tool schema on every PWA chat turn (46 tools, mostly unused) — 53s prefill bottleneck
  status: done
  priority: P0
  effort: s
  closed_date: '2026-05-01'

- id: INFRA-181
  domain: INFRA
  title: "restart-chump-web.sh: silently builds stale source when git pull fails — must abort or surface"
  status: done
  priority: P2
  effort: xs
  closed_date: '2026-05-02'
  closed_pr: 732

- id: INFRA-182
  domain: INFRA
  title: "tool routing: send 3-8 relevant tools per turn (route_tools in chump-perception) instead of all 46"
  status: done
  priority: P0
  effort: m
  closed_date: '2026-05-01'

- id: INFRA-183
  domain: INFRA
  title: PWA latency budget umbrella — measure + fix the 6 known PWA slow paths (partner-agent diagnosis)
  status: done
  priority: P0
  effort: l
  closed_date: '2026-05-02'
  closed_pr: 710

- id: INFRA-184
  domain: INFRA
  title: Plain-prose CoT routing to thinking_delta for reasoning models without <think> tags (INFRA-183 sub)
  status: done
  priority: P1
  effort: m
  description: |
    Extend src/local_openai.rs:81-185 chunk processor to recognize plain-prose reasoning patterns (e.g. 'Thinking Process:\n\n1.' followed by blank line + final answer) and route them to AgentEvent::ThinkingDelta instead of dropping them. Today only <think>...</think>-wrapped content is routed; reasoning models that don't use those tags emit invisible CoT and the user sees only keepalive pings until the final answer.
  acceptance_criteria:
    - chunk processor detects plain-prose CoT prefix
    - emits ThinkingDelta during reasoning phase
    - TextDelta only fires after reasoning ends
    - unit tests for both <think>-wrapped and plain-prose paths
  depends_on: [INFRA-183]
  closed_date: '2026-05-01'
  closed_pr: 701

- id: INFRA-185
  domain: INFRA
  title: Phase-level timing breakdown — compaction / provider / tools ms on existing [timing] logs (INFRA-183 sub)
  status: done
  priority: P2
  effort: s
  description: |
    Add phase-level timing instrumentation: compaction_ms / provider_ms / tools_ms on top of the existing [timing] stream_request_ms log lines at src/local_openai.rs:1021/1124/1133 and src/agent_loop/orchestrator.rs:129. So we can see where the agent loop spends its time per turn, not just the LLM round-trip.
  acceptance_criteria:
    - "tracing::info span per phase"
    - fields visible in logs
    - emit single end-of-turn structured event with all phase ms summed
    - enabled by default; CHUMP_PHASE_TIMING=0 disables
  depends_on: [INFRA-183]
  closed_date: '2026-05-02'
  closed_pr: 704

- id: INFRA-186
  domain: INFRA
  title: "naming convention reset: branch + worktree are chump-first (project owns namespace, not the tool)"
  status: done
  priority: P1
  effort: s
  closed_date: '2026-05-01'

- id: INFRA-187
  domain: INFRA
  title: "tooling enforcement for chump-first naming: bot-merge.sh default chump/, gap-claim accepts any prefix"
  status: open
  priority: P2
  effort: xs

- id: INFRA-188
  domain: INFRA
  title: "per-file gap registry: docs/gaps/<DOMAIN>-<NNN>.yaml directory replaces monolithic gaps.yaml"
  status: done
  priority: P1
  effort: s
  closed_date: '2026-05-02'
  closed_pr: 731

- id: INFRA-189
  domain: INFRA
  title: "property-based agent contracts: declared file scope enforced by pre-commit (kills lease-overlap class)"
  status: open
  priority: P1
  effort: s

- id: INFRA-190
  domain: INFRA
  title: "bot-merge.sh: auto-rebase + auto-fix loop on DIRTY (kills 5-times-a-session manual rebase)"
  status: done
  priority: P1
  effort: s
  closed_date: '2026-05-01'

- id: INFRA-191
  domain: INFRA
  title: chump dispatch canonical workflow — single command pulls main, claims gap, ships PR, releases
  status: open
  priority: P1
  effort: s

- id: INFRA-192
  domain: INFRA
  title: "forward-chain notifier: post gap_unblocked event when a PR closes a depends_on link"
  status: done
  priority: P1
  effort: s
  closed_date: '2026-05-01'

- id: INFRA-193
  domain: INFRA
  title: "speculative execution: two agents on same gap; first-to-land wins, loser auto-closed superseded"
  status: open
  priority: P1
  effort: s

- id: INFRA-194
  domain: INFRA
  title: "closer-PR auto-batcher: coordinator ships one PR with N gap closures every M hours"
  status: open
  priority: P1
  effort: s

- id: INFRA-195
  domain: INFRA
  title: "skills feedback loop: shipped PRs distill into chump_skills rows the next dispatcher reads"
  status: open
  priority: P1
  effort: s

- id: INFRA-196
  domain: INFRA
  title: Dependabot must ignore cargo-dist-generated action versions in release.yml
  status: open
  priority: P2
  effort: s
  description: |
    Dependabot bumped actions/upload-artifact v6→v7 and actions/download-artifact v7→v8 across all workflows in PR #673. release.yml is generated by cargo-dist v0.31.0, which emits v6/v7 — so cargo-dist's plan job sees the bump as drift and fails. The PR sat blocked until manual triage. Generated files should not be touched by independent automations. Add a dependabot.yml ignore rule for actions/{upload,download}-artifact within .github/workflows/release.yml (or all paths cargo-dist owns), so dependabot only bumps action versions in workflows we author. When cargo-dist itself is upgraded, the new generated release.yml will pick up the newer action versions naturally.
  acceptance_criteria:
    - .github/dependabot.yml has an ignore entry that prevents bumps to upload-artifact/download-artifact in release.yml
    - next dependabot run does not modify cargo-dist-generated content
    - document the rule in dist-workspace.toml comment so the next maintainer knows why

- id: INFRA-197
  domain: INFRA
  title: CLAUDE.md consolidation pass — file is approaching 400 lines, agents truncate
  status: open
  priority: P3
  effort: m
  description: |
    CLAUDE.md is ~400 lines and growing. Recent additions (gap-doctor.py, INFRA-154 auto-close, INFRA-157 heredoc rule, INFRA-161 homebrew tap, INFRA-162 actions PR rule) are all valuable, but cumulative size means agents will skim or hit context-truncation before reading critical sections. The docs-delta guard (advisory→blocking) counter-pressures sprawl but doesn't bend the curve. Do a consolidation pass: (1) move incident-specific footnotes to docs/process/INCIDENTS.md, (2) collapse the commit-time guards table to a one-line pointer to scripts/git-hooks/pre-commit header, (3) move the merge-queue recovery runbook to docs/process/MERGE_QUEUE_RECOVERY.md, (4) leave only operational rules + 'where to look next' pointers in CLAUDE.md. Target: ≤200 lines.
  acceptance_criteria:
    - CLAUDE.md ≤200 lines
    - all moved content lives in linked docs/process/*.md
    - no operational rule deleted, only relocated
    - run wc -l before/after in PR description

- id: INFRA-198
  domain: INFRA
  title: Required-review gate for infra-touching PRs (workflows, hooks, dist config, branch protection)
  status: open
  priority: P2
  effort: m
  description: |
    Single-maintainer repo with no required-review gate means infra-touching PRs (workflows, git hooks, dist config, pre-commit guards, branch protection) can land via auto-merge with zero second-pair-of-eyes. The cross-judge audit guard (INFRA-079) acknowledges this risk for evals; the same logic argues for a lightweight gate on infra paths. Options: (a) CODEOWNERS rule requiring review for paths in {.github/, scripts/git-hooks/, scripts/coord/, dist-workspace.toml, Cargo.toml [workspace.metadata.dist], CLAUDE.md, AGENTS.md} — review can be from a designated bot with stricter checks, not necessarily a human; (b) a 'two-agent rule' where infra-touching PRs require an explicit ack ambient event from a sibling session before auto-merge arms; (c) post-merge audit job that diffs infra changes against a known-good template and opens an issue if anomalous. Scope this gap = pick an approach + prototype.
  acceptance_criteria:
    - approach selected with rationale (CODEOWNERS / two-agent ack / post-merge audit)
    - prototype lands behind a runtime flag if it changes ship pipeline
    - "measure: how many infra PRs in the prior 4 weeks would have been caught"

- id: INFRA-199
  domain: INFRA
  title: PWA renders thinking_delta as muted live indicator (closes INFRA-184 loop end-to-end)
  status: done
  priority: P1
  effort: xs
  description: |
    Server-side INFRA-184 (PR #701) routes plain-prose CoT to AgentEvent::ThinkingDelta. Today the PWA at web/v2/chat.js does not subscribe to thinking_delta SSE events at all (grep -c thinking_delta web/v2/chat.js == 0), so reasoning models still show the user only keepalive pings while the model thinks. This closes the loop: render thinking_delta as a compact muted indicator inside the active assistant bubble while the model reasons; clear it when text_delta arrives.
  acceptance_criteria:
    - PWA subscribes to thinking_delta SSE events
    - reasoning content rendered as muted/italic/smaller text inside the same assistant bubble
    - cleared when text_delta begins
    - persists when model emits no text_delta (so user still sees the reasoning instead of nothing)
    - works for both <think>-tag-routed and plain-prose-routed thinking from server
  depends_on: [INFRA-184]
  closed_date: '2026-05-02'
  closed_pr: 710

- id: INFRA-200
  domain: INFRA
  title: gaps.yaml advisory-only enforcement demonstrably failed — ship hard pre-commit block
  status: done
  priority: P1
  effort: s
  description: |
    INFRA-084 (P0) shipped a merge_group regeneration workflow on 2026-04-29.
    INFRA-094 (P0) shipped an advisory pre-commit warning on 2026-04-29.
    Neither shipped a hard block on raw docs/gaps.yaml edits.
    
    Empirical result: 33 of 50 commits (66%) on origin/main since those advisories
    landed still touch docs/gaps.yaml directly. The SECURITY-005 row was attempted
    via end-of-YAML append three times (#678, #684, #695) before succeeding via
    surgical insert — confirming the advisory was visible to agents yet the behavior
    continued.
    
    INFRA-094's acceptance criteria (verified in gaps.yaml) explicitly require:
    "Pre-commit hook *blocks* raw docs/gaps.yaml edits without chump-gap commit
    trailer." The current hook warns; it does not block. This gap closes the gap
    between INFRA-094's AC and what was actually shipped.
    
    Approach: extend scripts/git-hooks/pre-commit section 3b from advisory
    (exit 0 with warning) to enforcement (exit 1 with bypass instructions).
    Bypass: CHUMP_GAPS_LOCK=0 (already exists in the guards table) or the
    presence of a .chump/.last-yaml-op marker proving chump CLI wrote it.
    
    Falsifying condition: `git log origin/main --since='2026-05-02' --format='%H' -- docs/gaps.yaml | wc -l`
    returns <10% of total commits (showing behavioral change, not just the advisory).
  acceptance_criteria:
    - scripts/git-hooks/pre-commit section 3b exits 1 (not 0) when docs/gaps.yaml is staged without chump-gap marker
    - Bypass path CHUMP_GAPS_LOCK=0 documented in the commit-time guards table in CLAUDE.md
    - "Test: stage a raw docs/gaps.yaml edit and verify pre-commit exits 1 with a pointer to chump gap commands"
    - "After ship: git log origin/main --since=<ship_date> --format='%H' -- docs/gaps.yaml | wc -l shows <20% of total commits"
  depends_on: [INFRA-084, INFRA-094]
  opened_date: '2026-05-02'
  closed_date: '2026-05-02'
  closed_pr: 729

- id: INFRA-201
  domain: INFRA
  title: Enable GitHub merge queue on main + add merge_group triggers to required-check workflows
  status: open
  priority: P2
  effort: xs
  description: |
    Disabled the 'strict' (require-up-to-date) flag on the legacy branch protection for main. Eliminates the BEHIND-cascade traffic jam that hit when 5-10 PRs auto-armed in parallel. Real GitHub merge queue is not available on personal-account repos (org Team/Enterprise only) — 422 on the merge_queue rule type, confirmed three times in MERGE_QUEUE_SETUP.md. Trade-off: PRs can land tested against older main; textual conflicts go DIRTY (immediately visible); logical conflicts caught by pre-commit guards + gap-doctor. Validated empirically on 2026-05-01: 10 open PRs → 4 → 2 within seconds when strict was flipped off.
  acceptance_criteria:
    - branch protection 'strict' is false on main
    - CLAUDE.md auto-merge section explains the actual mechanism (no queue)
    - MERGE_QUEUE_SETUP.md has updated status header
    - allow_update_branch=true at repo level (manual rebase button works)
    - "empirical validation: 10 stuck PRs cleared within 5 min"

- id: INFRA-202
  domain: INFRA
  title: shared CARGO_TARGET_DIR + sccache for fleet worktrees (kill 5GB-per-worktree disk + cold-build time)
  status: open
  priority: P1
  effort: s

- id: INFRA-203
  domain: INFRA
  title: scripts/dispatch/run-fleet.sh canonical fleet launcher (tmux + per-agent worker loop, headless claude -p)
  status: open
  priority: P1
  effort: s

- id: INFRA-204
  domain: INFRA
  title: fleet status dashboard — tmux control pane shows ambient.jsonl tail + PR queue depth + per-agent throughput
  status: open
  priority: P1
  effort: s

- id: INFRA-205
  domain: INFRA
  title: CI matrix parallelism — split fast-checks/clippy/tests/e2e to run in parallel (cut queue depth 2-3x)
  status: open
  priority: P1
  effort: s

- id: INFRA-206
  domain: INFRA
  title: per-agent gap-domain affinity — agent-1 INFRA only, agent-2 EVAL only, etc (kills hot-spot bias at 10+ agents)
  status: open
  priority: P1
  effort: s

- id: INFRA-207
  domain: INFRA
  title: spawn-respawn lifecycle — agents exit after 1 gap; dispatcher respawns (avoids context exhaustion + lets new lessons load)
  status: open
  priority: P1
  effort: s

- id: INFRA-208
  domain: INFRA
  title: chump gap dump is lossy — strips acceptance/closed_commit/runnable_now fields
  status: open
  priority: P1
  effort: m
  description: |
    chump gap dump emits a YAML schema that is a STRICT SUBSET of the canonical docs/gaps.yaml on main. Quantified by gap-doctor diff on 2026-05-02:
    
      - 222 gap rows lose 'acceptance:' free-text field (the dump only emits 'acceptance_criteria:' as a list; rows where the source had 'acceptance:' as a multi-line string get the text dropped, not migrated)
      - 41 gap rows lose 'closed_commit:' field (40-char SHAs of the closing commit, attested to by the audit trail)
      - 1 gap row loses 'runnable_now:' operational note (~10 line shell snippet for triggering the work)
    
    Net effect: any 'chump gap ship --update-yaml' or 'chump gap dump --out docs/gaps.yaml' produces a 22500-line diff that LOSES information it cannot recreate. The team has informally adopted a 'surgical YAML insert' pattern (commit d1012f5 SECURITY-005, PR #716 INFRA-177) to avoid this — but that pattern is undocumented and error-prone for new contributors / agents.
    
    Fix paths:
      (a) Extend state.db schema to hold acceptance / closed_commit / runnable_now fields and emit them in dump.
      (b) Make 'chump gap dump' read the existing YAML and PRESERVE unknown fields per gap row when regenerating.
      (c) Add 'chump gap surgical-set <ID> --field=value' subcommand that does a hand-edit-equivalent in-place YAML mutation.
    
    Acceptance: chump gap dump --out docs/gaps.yaml on a synced tree produces ZERO diff against the on-disk YAML for fields the dump doesn't intend to change.
  acceptance_criteria:
    - chump gap dump on a synced tree produces zero YAML diff
    - "acceptance: closed_commit: runnable_now: fields preserved through dump roundtrip"
    - gap-doctor sync-from-db --apply does not destroy data

- id: INFRA-209
  domain: INFRA
  title: spawn-respawn fleet lifecycle — agents exit after 1 gap; dispatcher respawns (load new lessons)
  status: open
  priority: P2
  effort: xs

- id: INFRA-210
  domain: INFRA
  title: shared CARGO_TARGET_DIR + sccache for fleet worktrees (kill 5GB-per-worktree disk + cold-build time)
  status: open
  priority: P1
  effort: s
  description: |
    Each linked worktree under .chump/worktrees/<name>/ today maintains
    its own target/ directory (typically 2-8 GB after cargo clippy +
    cargo test). With ~25 frozen worktrees today the disk is at risk;
    at FLEET_SIZE=10-50 (META-004 / fleet scaling discussion) this
    becomes a hard ceiling — 50 × 5 GB = 250 GB on a 460 GB M4.
    
    Fix path:
      1. Set CARGO_TARGET_DIR to a single shared location
         (e.g. ~/.cache/chump-fleet-target/) — all worktrees share
         the same target dir. cargo handles concurrent reads safely;
         concurrent writes for the SAME crate on different branches
         is the failure mode to test.
      2. If concurrent writes break (likely on heavy clippy/test
         loads), layer sccache on top — sccache caches by (crate,
         hash) so each worktree's cargo build hits the cache and
         only rebuilds what differs.
      3. Document in CLAUDE.md "Worktree disk hygiene" section.
      4. Update bot-merge.sh's "purge ./target" step to be a no-op
         when CARGO_TARGET_DIR points outside the worktree.
    
    Acceptance: 10 worktrees building concurrently use < 15 GB total
    target dir (vs 50 GB unshared). Build time for the 11th worktree
    starting from a warm shared cache is < 90 s (vs cold 5-10 min).
    No build correctness regression in any worktree.
  acceptance_criteria:
    - CARGO_TARGET_DIR documented in CLAUDE.md and exported by scripts/dispatch/run-fleet.sh (INFRA-203) by default
    - sccache config wired in if needed for concurrent-write safety; documented as optional
    - bot-merge.sh's target-purge step is no-op when CARGO_TARGET_DIR points outside worktree
    - "10-worktree concurrent build test: total target disk < 15 GB; build correctness verified by cargo test --workspace pass"
  opened_date: '2026-05-02'

- id: INFRA-211
  domain: INFRA
  title: scripts/dispatch/run-fleet.sh — canonical fleet launcher (tmux + per-agent worker loop, headless claude -p)
  status: open
  priority: P1
  effort: s
  description: |
    Today there is no canonical way to spawn N parallel Claude Code
    agents on this repo. The chump-orchestrator's COG-025 backend can
    run `claude -p --dangerously-skip-permissions` per dispatched
    subagent, but it's invoked one-at-a-time from the dispatcher's
    inner loop, not as a fleet.
    
    This gap adds scripts/dispatch/run-fleet.sh which:
      1. Spawns N tmux panes, one per agent (visible state, easy
         kill/restart, scrollback for postmortem)
      2. Each pane runs a worker loop: pull main → pick highest-
         priority unclaimed P0/P1 gap → claim via gap-claim.sh
         (atomic flock) → create worktree at .chump/worktrees/
         <gap-id>-<ts> → spawn `claude -p` with a focused prompt →
         on exit, release lease + loop back
      3. Per-agent log at /tmp/chump-fleet-<sid>/agent-<N>.log
      4. Control pane shows live status (ambient.jsonl tail + PR
         queue depth + per-agent current gap)
    
    Defaults: FLEET_SIZE=8 (Tier 2 from META-004 analysis), 30-min
    per-agent timeout (longer = stuck loop), excludes EVAL-* /
    RESEARCH-* / META-* gaps from auto-pickup (those need human
    judgment), filters to xs/s/m effort only.
    
    Configurable via env: FLEET_SIZE, FLEET_TIMEOUT_S,
    FLEET_PRIORITY_FILTER ('P0,P1' default), FLEET_DOMAIN_FILTER
    (e.g. 'INFRA' for INFRA-only fleet — pairs with INFRA-206 affinity).
    
    Hard rules (enforced in worker.sh):
      - Use scripts/coord/bot-merge.sh as ship pipeline (auto-handles
        INFRA-154 close, INFRA-190 pr-watch, INFRA-192 forward-chain)
      - Use chump gap reserve (NEVER raw YAML) for new IDs
      - Pass --paths to gap-claim.sh declaring scope (INFRA-189
        warn-mode catches drift)
    
    Stop: FLEET_SIZE=0 OR `tmux kill-session -t <session>` OR per-agent
    Ctrl-C in the pane.
  acceptance_criteria:
    - scripts/dispatch/run-fleet.sh exists, executable, parses cleanly, default FLEET_SIZE=8
    - Per-agent worker.sh handles full lifecycle (claim → worktree → claude → ship → release → loop)
    - Control pane shows live fleet status (ambient + PR queue + per-agent activity)
    - "Test: spawn FLEET_SIZE=2 for 1 hour; expect 4-8 PRs shipped; zero ID collisions; zero unrecovered DIRTY events (pr-watch handles)"
    - Documented in CLAUDE.md + AGENTS.md as the canonical fleet entry
  depends_on: [INFRA-188, INFRA-189, INFRA-210]
  opened_date: '2026-05-02'

- id: INFRA-212
  domain: INFRA
  title: fleet status dashboard — tmux control pane shows ambient.jsonl tail + PR queue depth + per-agent throughput
  status: open
  priority: P2
  effort: s
  description: |
    Once INFRA-203 ships, the operator has N tmux panes each running
    one agent. To know FLEET HEALTH (vs just per-agent state) they
    need a control pane that aggregates:
    
      - Per-agent: current gap, time-on-gap, last commit hash
      - Fleet-wide: PRs in flight, PRs merged this hour, ID collision
        count, DIRTY-recovery count (from pr-watch logs)
      - Ambient.jsonl tail: latest INTENT / HANDOFF / STUCK / DONE
        events with sender attribution
      - Gap supply: open P0 + P1 count by domain (warn when exhausted)
    
    Implementation: `watch -n 5 scripts/dispatch/fleet-status.sh`
    inside the control tmux pane (INFRA-203 wires it up).
    fleet-status.sh aggregates from:
      - .chump-locks/*.json (active leases → who's working on what)
      - .chump-locks/ambient.jsonl (recent events)
      - gh pr list (queue depth) — cached 30s to avoid rate-limit
      - chump gap list --status open --json (gap supply)
    
    Color: green if all agents have a gap and ship rate > 1/hr; yellow
    if any agent idle > 5min OR queue depth > 20; red if any agent
    stuck > 30min OR pr-watch CONFLICT exit > 0 in last hour.
    
    Out of scope: web dashboard (separate gap if needed).
  acceptance_criteria:
    - scripts/dispatch/fleet-status.sh exists, prints aggregated status in < 2 s
    - Color-coded green/yellow/red status banner
    - Wired into INFRA-203's control pane via watch -n 5
    - "Test: at FLEET_SIZE=4 with 1 stuck agent, the dashboard shows yellow within 5 min"
  depends_on: [INFRA-211]
  opened_date: '2026-05-02'

- id: INFRA-213
  domain: INFRA
  title: CI matrix parallelism — split fast-checks/clippy/tests/e2e to run in parallel (cut queue depth 2-3x)
  status: open
  priority: P0
  effort: m
  description: |
    GitHub merge queue throughput is the HARD ceiling for fleet
    scaling. Today the required CI checks (test, clippy, audit,
    fast-checks, ACP smoke) run mostly serially within a single
    workflow job — each PR's merge takes 2-5 min of queue time. At
    FLEET_SIZE=20 with 20 PRs queued, the last PR waits 40-100 min.
    Beyond ~30 PRs/hour throughput the queue saturates.
    
    Fix: refactor required CI into a matrix that runs the heavy
    checks in parallel:
      - fast-checks    (10 s, gate to test)
      - clippy         (parallel, ~3 min)
      - test           (parallel, ~10 min)
      - audit          (parallel, ~3 min)
      - ACP smoke      (parallel, ~2 min)
    
    Each runs on its own GitHub-hosted runner. Total wall-clock per
    PR drops from sum(checks) ~20 min to max(checks) ~10 min.
    Throughput at fixed runner pool roughly doubles.
    
    Plus: split test by package (gap_store, agent_loop, web_server,
    perception, etc.) to further parallelize the test step itself.
    Cargo nextest already supports this; the workflow needs to
    invoke it.
    
    Out of scope: self-hosted runners (separate gap if needed; cost
    + ops overhead).
  acceptance_criteria:
    - .github/workflows/ci.yml uses matrix strategy for clippy + test + audit + ACP smoke
    - test step uses cargo-nextest with --test-threads=4 OR parallel-by-package
    - Median PR-to-merged time at queue depth 10 drops from ~30 min to ~15 min
    - "Test: run the fleet at FLEET_SIZE=10 for 1 hour; measure PRs/hour throughput; expect 25-30 (vs 10-15 today)"
  opened_date: '2026-05-02'

- id: INFRA-214
  domain: INFRA
  title: per-agent gap-domain affinity — agent-1 INFRA only, agent-2 EVAL only, etc (kill hot-spot bias at 10+ agents)
  status: open
  priority: P2
  effort: s
  description: |
    Today gap-claim.sh's "pick the highest-priority unclaimed gap"
    naturally biases the fleet toward INFRA-* (which dominates the
    backlog). At FLEET_SIZE=10, all 10 agents end up working INFRA
    while EVAL / FLEET / DOC sit idle.
    
    Fix: per-agent FLEET_DOMAIN_FILTER env (used by INFRA-203's
    worker.sh). Operator launches:
      FLEET_DOMAIN_FILTER=INFRA  scripts/dispatch/run-fleet.sh    # agents 1-3
      FLEET_DOMAIN_FILTER=EVAL   scripts/dispatch/run-fleet.sh    # agents 4-5
      FLEET_DOMAIN_FILTER=FLEET  scripts/dispatch/run-fleet.sh    # agents 6-7
      FLEET_DOMAIN_FILTER=DOC    scripts/dispatch/run-fleet.sh    # agent 8
    
    Worker.sh's gap-pick step filters by domain. If no gap matches
    the affinity, agent waits 60s and retries (vs picking outside
    affinity).
    
    Bonus: a config file scripts/dispatch/fleet.toml that names the
    affinity layout so ops doesn't have to remember it.
  acceptance_criteria:
    - INFRA-203's worker.sh respects FLEET_DOMAIN_FILTER env
    - scripts/dispatch/fleet.toml documents affinity layout
    - "Test: launch FLEET_SIZE=4 with affinity (2 INFRA, 1 EVAL, 1 FLEET); verify each agent only picks gaps in its domain"
  depends_on: [INFRA-211]
  opened_date: '2026-05-02'

- id: INFRA-215
  domain: INFRA
  title: spawn-respawn fleet lifecycle — agents exit after 1 gap; dispatcher respawns (load new lessons)
  status: open
  priority: P2
  effort: xs
  description: |
    Long-running Claude sessions hit context limits. Fresh spawns
    pick up the latest chump_improvement_targets rows (INFRA-195) so
    new lessons propagate each cycle.
    
    Fix: in INFRA-211's worker.sh, structure the loop so each `claude
    -p` invocation handles ONE gap then EXITS. The bash loop respawns
    a fresh `claude -p` for the next gap.
    
    (Originally filed as INFRA-207 but main's INFRA-207 was a docs-delta
    guard work item — renumbered to INFRA-215 to avoid collision.)
  acceptance_criteria:
    - INFRA-211 worker.sh documents the spawn-respawn pattern
    - Each `claude -p` invocation works ONE gap then exits
    - CHUMP_LESSONS_AT_SPAWN_N=5 set in worker env so INFRA-195 distillation flows to next spawn
  depends_on: [INFRA-211, INFRA-195]
  opened_date: '2026-05-02'

- id: INFRA-216
  domain: INFRA
  title: "chump gap reserve: cross-host race against merge-queue arrivals — atomic picker only protects within-host"
  status: open
  priority: P1
  effort: m
  description: |
    'chump gap reserve' uses INFRA-100's atomic next-ID picker, which reads all 4 sources on the local host (state.db, open PRs, live leases, main YAML). It does NOT git fetch first. So if a sibling agent on the same host or remote landed a PR that added a new gap row to docs/gaps.yaml on origin/main BETWEEN your last fetch and your reserve, the picker assigns an ID that's already taken on origin/main.
    
    Reproducer (observed 2026-05-02 in the INFRA-177 closure session):
      1. Agent A FFs main, runs 'chump gap reserve --domain INFRA' → returns INFRA-200
      2. Agent B's PR (e0ab7e7, e.g.) lands on origin/main with INFRA-200 already assigned
      3. Agent A surgically inserts INFRA-200 into YAML and tries to commit
      4. Pre-commit gap-ID-hijack guard catches the title mismatch → reject
      5. Recovery: sqlite3 DELETE the poisoned local row + chump gap import + reserve again (gets INFRA-208)
    
    Fix paths:
      (a) 'chump gap reserve' calls 'git fetch origin main --quiet' before the atomic pick (slow when offline; needs careful timeout)
      (b) 'chump gap reserve' reads origin/main's gaps.yaml via 'git show origin/main:docs/gaps.yaml' (no network, but stale until next fetch)
      (c) Pessimistic ID picker: skip N additional IDs as a safety buffer when the local picker hasn't fetched in >5min
      (d) Document the failure mode + recovery in CLAUDE.md so agents know to git fetch + chump gap import before reserve
    
    Acceptance: under a stress test of 3+ concurrent reserve calls split across local DB + simulated origin/main updates, no ID collision occurs OR the collision is detected at reserve-time (not at commit-time).

- id: INFRA-217
  domain: INFRA
  title: Branch protection on main blocks direct push for ledger-only commits — every chore(gaps) needs a PR
  status: open
  priority: P2
  effort: s
  description: |
    Branch protection on origin/main now requires 3 status checks (added 2026-05-01-ish per github rules). This means even pure ledger-flip commits — like 'chore(gaps): add SECURITY-005 row via surgical insert at SECURITY-* block' (commit d1012f5) or the canonical 'chore(gaps): close <ID> already shipped in #N' pattern — can no longer be direct-pushed to main; they need a PR + CI run.
    
    Observed cost in the 2026-05-02 INFRA-177 closure session: 3 separate chore(gaps) PRs (#716 INFRA-177 close, #718 INFRA-208/META-006 file, #724 cargo-dist allow-dirty) each had to:
      - Create a feature branch
      - Push (with CHUMP_GAP_CHECK=0 bypass for false-positive gap-preflight)
      - 'gh pr create' with body
      - 'gh pr merge --auto --squash' to arm
      - Wait for CI to run all 3 required checks (~5-10 min) before landing
    
    Compare against the pre-protection direct-push: ~3 commands, instant.
    
    Tradeoff: branch protection prevents bot misbehavior but adds friction for the very narrow class of 'pure metadata flip' commits. Three options:
      (a) Accept the friction (current state) — chore(gaps) PRs are normal
      (b) Allow specific bot identities (chump-ftue-bot, etc) to push to main bypassing required checks for ledger files only — needs admin rules + path-based protection
      (c) Add a dedicated 'ledger flip' fast-track: a workflow that takes a state.db change as input, opens + auto-merges its own PR with self-attested CI skip — automates the friction away without weakening protection
    
    Acceptance: pick one of (a)/(b)/(c) explicitly; document the decision in CLAUDE.md ship-pipeline section so agents stop attempting direct-push and getting GH013 errors.

- id: INFRA-218
  domain: INFRA
  title: "EVAL-095 overnight script: bump timeout to 300s + add output_chars>0 smoke gate"
  status: open
  priority: P1
  effort: xs
  description: |
    EVAL-095 overnight script (shipped 2026-05-01 via PR #726) had two bugs that surfaced when manually fired the same night: (1) smoke timeout 120s is too tight — chump binary regressed to ~120-130s wall-clock per neuromod trial under qwen2.5:14b, so the 1-trial probe always times out and produces output_chars=0 + exit_code=-1; (2) smoke gate only checked scorer=='llm_judge' which passes even on degenerate empty-output runs, so the full sweep would run, write 40 rows of 0/0/correct=False, and produce a fake delta=0.000 (looks like 'EVAL-069 reproduces the null' but is actually the same broken-instrument footgun EVAL-090 was filed to detect). Fix: bump smoke + sweep timeout to 300s; tighten smoke gate to also check output_chars>0 and exit_code==0. Tested manually 2026-05-02: smoke passed cleanly at 300s with chars=71, both cells correct.
  acceptance_criteria:
    - smoke timeout=300s
    - sweep timeout=300s
    - smoke gate checks output_chars>0 AND exit_code==0 AND scorer==llm_judge
    - tonight's overnight run produces real data (not 40 rows of empty output)

- id: INFRA-219
  domain: INFRA
  title: "closer-pr-batcher false-positive: closes filing PRs after seeing reserved IDs in local DB"
  status: open
  priority: P1
  effort: s
  description: |
    The closer-pr-batcher (sibling INFRA-194 work) auto-closed PR #718 ('chore(gaps): file INFRA-208 + META-006') with the comment 'Superseded — both gaps already exist in current state.db (INFRA-208 status=open, META-006 status=open). Closing as redundant.' This was wrong:
    
      - The two gaps existed in the closer's LOCAL state.db
      - They did NOT exist in origin/main's docs/gaps.yaml
      - They were in local DB precisely because PR #718's chump gap reserve put them there
      - Closing the PR meant the gaps were never propagated to origin/main YAML
      - Net effect: filing intent was DESTROYED by the closer's "DB has it = redundant" heuristic
    
    Reproducer (observed 2026-05-02 ~02:27Z):
      1. Agent A runs 'chump gap reserve' → gets INFRA-208 (in local state.db)
      2. Agent A creates PR #718 with surgical YAML insert for INFRA-208
      3. Closer-pr-batcher polls open PRs, sees INFRA-208 in commit body
      4. Closer queries state.db (local), finds INFRA-208 with status=open
      5. Closer concludes 'duplicate filing' and auto-closes the PR
    
    Root cause: the closer assumes 'DB has gap row' implies 'gap is on main'. But the DB is a LOCAL store that any 'chump gap reserve' mutates immediately, before the corresponding YAML row reaches main. The check should compare against `git show origin/main:docs/gaps.yaml`, not local state.db.
    
    Fix paths:
      (a) Closer queries origin/main YAML (or a cached fetch of it) instead of local state.db when deciding 'already filed'
      (b) Closer queries the GAP STATUS field too — only auto-close when the PR's filing matches a gap that is status:done on main, not just present
      (c) Closer skips PRs whose title starts with 'chore(gaps): file' (filing PRs are never duplicates of themselves)
      (d) Closer requires a positive signal (e.g. 'closing-PR-N' commit on main with the gap ID) before closing
    
    Recovery cost in this incident: reopen #718 + git rebase --onto + force-push + re-arm auto-merge — 5 minutes, but only because I noticed within 30min. If the closer's comment had been overlooked, the gaps would have stayed local-only forever.
  acceptance_criteria:
    - "Closer-pr-batcher does NOT close PRs whose intent is gap filing (titled 'chore(gaps): file ...') based on local DB presence"
    - Filing-vs-closure heuristic uses origin/main YAML state, not local state.db
    - Test added to scripts/ci/ that simulates the false-close scenario

- id: INFRA-41
  domain: infra
  title: "code-reviewer-agent.sh: guard empty-array iteration under bash 3.2 set -u"
  status: done
  priority: P2
  effort: xs
  description: |
    `scripts/code-reviewer-agent.sh` runs under `set -euo pipefail`. Default macOS bash (3.2) errors on `"${arr[@]}"` expansion when the array is empty, which fired during PR #465's review with the message `NEW_DEPS_IN_DIFF[@]: unbound variable`. PRs that don't add any dependency lines (most of them) trip this. The fix guards the iteration with `(( ${#arr[@]} > 0 ))`.
  acceptance_criteria:
    - Empty-diff dependency case no longer aborts the reviewer
    - PRs with no Cargo.toml additions can pass review again
  source_doc: PR
  closed_date: '2026-04-24'

- id: INFRA-AB-TOOL-CALL-COUNTER
  domain: infra
  title: ab-harness tool_calls counter greps wrong stream (always 0)
  status: done
  priority: P3
  effort: xs
  description: |
    run.sh greps stderr for 'tool_call_start' / 'Using tool ', but chump emits its tool-execution markers on stdout ("🔧 Executing tool: ..."). All COG-011 trials reported tool_calls=0, which isn't true. Doesn't affect the structural scorer (it uses the final text), but makes the JSONL field misleading.
  source_doc: scripts/ab-harness/run.sh
  closed_date: '2026-04-17'

- id: INFRA-AGENT-CODEREVIEW
  domain: infra
  title: code-reviewer agent in the loop for src/* PRs before auto-merge
  status: done
  priority: P1
  effort: m
  description: |
    Today's atomic-PR pattern auto-merges docs PRs without review (fine). For src/* code PRs (e.g. when COG-023 ships next as actual code changes to src/reflection_db.rs), the chump code-reviewer agent should be in the loop — same atomic-PR pattern but with required code-reviewer ack before auto-merge fires. Pattern:
      agent finishes work in worktree
      bot-merge.sh opens PR + arms auto-merge
      bot-merge.sh ALSO triggers code-reviewer agent (via gh comment
        or NATS) to review the diff
      code-reviewer agent posts approval comment OR raises concerns
      approval triggers the GitHub merge queue to proceed
      concerns block the merge until human resolves
    Goal: zero human in the loop on routine code, automatic escalation on substantive concerns.
  depends_on: [INFRA-MERGE-QUEUE, INFRA-AGENT-ESCALATION]
  notes: |
    ~1 week. Highest-leverage infra change after MERGE-QUEUE for "Jeff is no longer the bottleneck even on code PRs". Today docs PRs auto-ship cleanly; src/ PRs still require manual eyes. This closes the gap.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-AGENT-ESCALATION
  domain: infra
  title: Formal escalation pattern — when an agent is stuck, surface to human
  status: done
  priority: P2
  effort: m
  description: |
    Today there is no formal escalation: when an agent gets stuck (test failure it can't diagnose, ambiguous gap acceptance, cargo build failure), it dies, times out, or pushes broken commits. Multi-agent dispatch needs an explicit escalation channel: agent emits ALERT into ambient.jsonl with kind=escalation plus structured payload (gap_id, stuck_at_step, last_error, attempted_fixes). Watch on ALERT events surfaces these to Jeff as actionable items rather than silent death. Connects to chump-coord NATS for real-time pings.
  notes: |
    ~1 week. Without this, agents that hit unexpected blockers leave stranded work that needs Jeff to manually triage by reading worktree state. Key "why is Jeff still the bottleneck" failure mode.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-AMBIENT-STREAM-SCALE
  domain: infra
  title: Ambient stream retention policy + query performance at fleet scale
  status: done
  priority: P2
  effort: m
  description: |
    .chump-locks/ambient.jsonl is append-only and unbounded. Red Letter Issue #2 confirmed that after a full day of agent activity the stream showed only 2 events — indicating the hooks are not firing, not that the scale is an issue yet. But once AUTO-013 autonomous dispatch is running at fleet scale (10+ concurrent agents), the jsonl approach will become a linear-scan bottleneck. Agents scanning for recent ALERT events (O(n) grep) will time out. Additionally, there is no archival or expiry policy: the file will grow without bound.
  notes: |
    ~1 day. Current priority is P2 because ambient stream barely fires (RL Issue #2 confirmed); fix ambient hook firing first (FLEET-004b/c are marked done but emitting nothing — investigate separately).
  source_doc: docs/RESEARCH_INTEGRITY.md backlog audit 2026-04-19
  closed_date: '2026-04-20'

- id: INFRA-BELIEF-STATE-CLEANUP
  domain: INFRA
  title: Remove deleted chump-belief-state crate from publish pipeline
  status: done
  priority: P1
  effort: xs
  description: |
    REMOVAL-003 (#465, merged 2026-04-24) deleted the chump-belief-state crate and stubbed belief_state in-tree. Two files still referenced the removed crate and broke the Crate Publish Dry-Run CI check: (1) `.github/workflows/crates-publish-dry-run.yml` line 23 — listed chump-belief-state in the for-loop that runs `cargo publish -p $crate --dry-run`; cargo exited 1 with "package ID specification chump-belief-state did not match any packages"; (2) `scripts/publish-crates.sh` line 36 — same stale entry in the CRATES array. This caused the INFRA-CHOKE pre-flight gate in bot-merge.sh to refuse to arm auto-merge on any PR touching `crates/chump-*/**` or `Cargo.toml`, including PR #496 (INFRA-047 dependency modernization).
  acceptance_criteria:
    - crates-publish-dry-run.yml no longer references chump-belief-state
    - scripts/publish-crates.sh CRATES array no longer references chump-belief-state
    - Crate Publish Dry-Run CI passes on PRs touching crates/ or Cargo.toml
    - INFRA-CHOKE pre-flight gate no longer false-positives on the removed crate
  depends_on: [REMOVAL-003]
  notes: |
    Follow-up cleanup after REMOVAL-003. Found while investigating why PR #496 (INFRA-047) was unarmed in the merge queue. The CI pre-flight gate (INFRA-CHOKE, 2026-04-24) correctly refused to arm auto-merge — this fix restores the `dry-run` check to green.
  opened_date: '2026-04-24'
  closed_date: '2026-04-24'

- id: INFRA-BOT-MERGE-HEREDOC
  domain: infra
  title: bot-merge.sh heredoc backtick parse bug blocks auto-merge arming
  status: done
  priority: P1
  effort: xs
  description: |
    `scripts/bot-merge.sh` contains a `_comment_body=$(cat <<'EOFCOMMENT' ... ```... EOFCOMMENT)` construction for posting a CI-failure diagnostic comment on blocked PRs. Bash's `$(...)` command-substitution pre-parser scans for balanced backticks even inside a single-quoted heredoc body, so the literal triple-backtick markdown fence on line 460 produces `line NNN: unexpected EOF while looking for matching ``. The script aborts *after* `gh pr create` succeeds but *before* `gh pr merge --auto --squash` runs — silently dropping PRs into the repo without auto-merge armed. Observed on PR #482 (INFRA-045 itself), #488 (closed dup), and #491 (PRODUCT-015 activation funnel) on 2026-04-24. Each required manual `gh pr merge <N> --auto --squash` to recover. Fix: rebuild the comment body with `printf -v` + a `_fence='```'` variable, so no un-escaped backticks appear inside a `$(...)` literal.
  acceptance_criteria:
    - "`bash -n scripts/bot-merge.sh` exits 0"
    - bot-merge.sh runs end-to-end through the CI-gate branch without shell parse errors
    - auto-merge is armed on every PR that bot-merge.sh --auto-merge creates (when CI is green)
    - Diagnostic comment posted on CI-failure path preserves the existing markdown structure
  notes: |
    Root cause is a well-known bash quirk — `$(cat <<'EOF' ... EOF)` is not safe for heredoc bodies containing backticks, even when the delimiter is single-quoted. Prefer `printf -v` or a temp-file round-trip for any multiline string containing literal backticks.
  source_doc: CLAUDE.md
  closed_date: '2026-04-24'

- id: INFRA-BOT-MERGE-LOCK
  domain: infra
  title: bot-merge.sh marks worktree shipped; chump-commit.sh refuses to commit after
  status: done
  priority: P2
  effort: s
  description: |
    Atomic-PR discipline ("agent finishes all work, ships, never touches branch again") needs tooling enforcement. Today an agent can run bot-merge.sh, then commit + push more, eating its own commits via squash-merge. Solution: bot-merge.sh writes a .bot-merge-shipped marker file in the worktree on successful ship. chump-commit.sh refuses to commit if marker exists (with bypass via CHUMP_SHIPPED_OVERRIDE=1). Forces "PR shipped, this worktree is dead, move on to next gap" workflow. The auto-worktree-reaper (INFRA-WORKTREE-REAPER) then reaps the shipped worktree once main contains the merge commit.
  depends_on: [INFRA-WORKTREE-REAPER]
  notes: |
    ~half day. Small change, big multi-agent discipline win. Reference: scripts/bot-merge.sh, scripts/chump-commit.sh.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-BOT-MERGE-UNTRACKED
  domain: infra
  title: bot-merge.sh pushes wrong diff when untracked files present in worktree
  status: done
  priority: P2
  effort: s
  description: |
    During PR #158 ship, bot-merge.sh's first push committed only modified files but left 4 NEW files untracked, so the PR initially showed an empty/wrong diff. Recovered manually via chump-commit.sh + soft-reset + clean single commit + force-push. The footgun: bot-merge.sh assumes git status is clean OR all relevant files are staged, but doesn't guard against new files that aren't yet `git add`ed. Needs a pre-flight check: if there are untracked files in src/ docs/ scripts/ crates/ paths, fail loud with an instruction to chump-commit or git add them first.
  notes: |
    ~2 hours including test. Caught during PR #158 (AUTO-013 step 5) ship. The new files were the new test fixtures + reflect.rs restoration; they were genuinely needed but bot-merge dropped them.
  source_doc: PR
  closed_date: '2026-04-20'

- id: INFRA-CHUMP-API-RETRY
  domain: infra
  title: Spawned claude subprocess needs API-5xx retry wrapper
  status: done
  priority: P1
  effort: s
  description: |
    Autonomy test 2026-04-19 had chump-orchestrator dispatch a real claude -p subprocess. The subprocess ran ~3 min of valid work (pre-flight + gap read + doc walk) then hit "API Error: 500 Internal server error" from Anthropic and exited code 1. The orchestrator handled the failure gracefully (KILLED outcome, clean summary, graceful exit) but no PR shipped because of one transient external 5xx. With a thin retry wrapper (e.g. shell script that wraps claude -p, retries up to 3 times on exit code != 0 + stderr containing "API Error: 5"), the subagent would have self-recovered.
  notes: |
    ~2 hours. Highest leverage to make the autonomy loop production- ready. Without it, every transient Anthropic 5xx kills a dispatch.
  source_doc: docs/archive/2026-04/AUTONOMY-TEST-2026-04-19.md
  closed_date: '2026-04-19'

- id: INFRA-CI-DISKSPACE
  domain: infra
  title: "CI: free pre-installed SDKs to stop rustc-LLVM 'no space left on device'"
  status: done
  priority: P1
  effort: xs
  description: |
    ubuntu-latest runners ship with ~14 GB free. After the chump-agent-lease and chump-mcp-lifecycle crate extractions (a5b6043, fecf45f), the test job's four sequential cargo compilations (test --workspace, build debug, build --release, clippy --all-targets) plus Ollama qwen2.5:7b (~3 GB), Playwright chromium, and tauri system libs started tipping target/ past the 8 GB headroom. "rustc-LLVM ERROR: IO failure on output stream: No space left on device" hit ~40% of main CI runs on 2026-04-17.
  source_doc: .github/workflows/ci.yml
  closed_date: '2026-04-17'

- id: INFRA-CI-TEST-SPLIT
  domain: infra
  title: Split monolithic CI test job into fast unit + gated E2E
  status: done
  priority: P2
  effort: s
  source_doc: .github/workflows/ci.yml
  closed_date: '2026-04-18'

- id: INFRA-CLIPPY-RUST195
  domain: infra
  title: Clippy sweep for Rust 1.95.0 lints
  status: done
  priority: P0
  effort: s
  description: |
    CI runner upgraded to Rust 1.95.0 / clippy 1.95, adding many new lints (manual_clamp, manual_range_contains, useless_vec, await_holding_lock, let_unit_value, doc_lazy_continuation, useless_format, bool_assert_comparison). 32 errors blocked the entire pipeline. cargo clippy --fix handled most; mechanical edits cleared the rest.
  source_doc: .github/workflows/ci.yml
  closed_date: '2026-04-17'

- id: INFRA-CODEREVIEWER-FALSE-POSITIVES
  domain: infra
  title: Code-reviewer agent false-positives on existing dependencies
  status: done
  priority: P2
  effort: s
  description: |
    code-reviewer-agent.sh flagged rusqlite as a "new dependency" on PR #158 when it's already in workspace Cargo.toml. The reviewer grep'd the Cargo.toml diff for `+ rusqlite` and saw the new crate-level addition without checking workspace inheritance. Wastes cycles on dismissals. Also: the reviewer matched the gap ID as EVAL-026 instead of AUTO-013 (parsed from the worktree directory name not the gap-claim).
  depends_on: [INFRA-AGENT-CODEREVIEW]
  notes: |
    ~3 hours. Lower-priority than getting the merge queue UI flipped, but adds up — every false dismissal = ~30s of attention.
  source_doc: PR
  closed_date: '2026-04-20'

- id: INFRA-COST-CEILING
  domain: infra
  title: Per-session cloud spend cap — hard ceiling + soft warn
  status: done
  priority: P2
  effort: s
  description: |
    No per-agent or per-session spend cap today. At scale (10+ concurrent agents from musher dispatch), runaway cloud spend is a real risk — a buggy retry loop or unintended n=1000 sweep can burn budget silently. Need: per-session hard ceiling (kill the sweep when exceeded) + soft warning threshold (log + Discord ping). Reads cost from chump_coord ledger; integrates with the ESCALATION pattern (INFRA-AGENT-ESCALATION) for the soft warn.
  depends_on: [COMP-014]
  notes: |
    ~3 days. Pairs with INFRA-AGENT-ESCALATION for the soft-warn surfacing path.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-DISPATCH-FAULT-INJECTION
  domain: infra
  title: Fault-injection test mode for chump-orchestrator dispatch
  status: done
  priority: P2
  effort: s
  description: |
    Today's autonomy test exposed the orchestrator's failure-handling via real Anthropic API failure. Want to validate the same paths without burning real API credit. Add a fault-injection test mode that wraps the Spawner trait — returns synthetic 5xx after K seconds, returns synthetic exit code != 0, returns synthetic timeout, etc. Lets test suite verify INFRA-CHUMP-API-RETRY behavior + monitor watchdog behavior + reflection write paths under adverse conditions.
  depends_on: [INFRA-CHUMP-API-RETRY]
  notes: |
    ~3 hours. Important for hardening before AUTO-013-A (lesson-aware dispatch) builds on top.
  source_doc: docs/archive/2026-04/AUTONOMY-TEST-2026-04-19.md
  closed_date: '2026-04-20'

- id: INFRA-DISPATCH-PERMISSIONS-FLAG
  domain: infra
  title: Spawned claude subagent stalls on permission prompts — pass --dangerously-skip-permissions
  status: done
  priority: P1
  effort: s
  description: |
    Autonomy test V3 (with INFRA-CHUMP-API-RETRY shipped) ran 20 min, survived Anthropic API flakiness, but stalled when the subagent tried to call the Edit tool — permission prompt awaiting human approval (no human present, sandbox-by-context). Orchestrator monitor marked STALLED (no PR within soft deadline), reported summary, exited cleanly. The fix is one CLI flag: --dangerously-skip-permissions appropriate here because the subagent IS in a sandbox (own worktree, gap-scoped, atomic PR discipline, can't push to main per branch protection).
  source_doc: docs/archive/2026-04/AUTONOMY-TEST-2026-04-19.md
  closed_date: '2026-04-19'

- id: INFRA-DISPATCH-POLICY
  domain: infra
  title: musher dispatch policy — capacity-aware, priority-ordered, dependency-aware
  status: done
  priority: P2
  effort: m
  description: |
    musher (PR #113) handles agent spawn but dispatch policy is currently round-robin / manual. For sustained multi-agent operation across the 38-gap Q3 backlog, dispatch needs:
      PRIORITY:    P1 gaps before P2 before P3
      DEPENDENCIES: don't dispatch a gap whose depends_on entries
                    aren't done
      CAPACITY:    respect concurrency limits (cloud rate-limit
                   budget, M4 memory if local sweeps, repo lock
                   collision risk)
      AFFINITY:    prefer dispatching gaps that share files to same
                   agent (avoid file-lease contention)
      REVIVAL:     re-claim leases that expired uncleanly (heartbeat
                   died but TTL not up yet)
  notes: |
    ~1 week. Builds on existing musher (PR #113). Removes the manual "Jeff decides what dispatches next" decision from the loop.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-EXPERIMENT-CHECKPOINT
  domain: infra
  title: Experiment-config checkpoint — versioned harness state per A/B sweep
  status: done
  priority: P3
  effort: s
  description: |
    Today's harness keeps mutating: LESSONS_BLOCK constants change across PRs, judge panel evolves, agent dispatch added together:/ ollama: prefixes, retry budgets bumped after DNS outage. An old summary.json can't be reproduced bit-exact by re-running on current code. Snapshot harness config at every sweep: git SHA + env-var fingerprint + LESSONS_BLOCK content hash + judge panel + retry policy. Embed in summary.json header so each result is reproducible from its own metadata.
  notes: |
    ~3 days. Pays off when future you (or external researchers) wants to re-run a 2026-Q2 sweep on a 2027-Q1 codebase to test for regression.
  source_doc: session 2026-04-19 reproducibility audit
  closed_date: '2026-04-20'

- id: INFRA-FILE-LEASE
  domain: infra
  title: File-level path leases on top of gap-level mutex
  status: done
  priority: P2
  effort: m
  description: |
    Current lease files (.chump-locks/<session>.json) have an empty `paths: []` field reserved for file-level leases that was never wired up. Wire it. Extend gap-claim.sh with --paths flag that populates the array. Extend chump-commit.sh to read all live leases and reject commits where staged files overlap a different session's path-lease. Lets two agents working on different files in the same gap (or in different gaps) commit in parallel without collision; agents on the same file wait their turn (lease blocks with timeout + clear error).
  notes: |
    ~1 day implementation. Most of the lease infrastructure exists; this is wiring + check + docs. Reference: scripts/gap-claim.sh, scripts/chump-commit.sh, scripts/gap-preflight.sh.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-GAPS-DEDUP
  domain: infra
  title: Fix gap registry ID collision — 7 duplicate ID pairs
  status: done
  priority: P1
  effort: s
  description: |
    Red Letter Issue #2 confirmed 7 duplicate gap IDs in docs/gaps.yaml: COG-007, COG-008, COG-009, COG-010, COG-011, MEM-003, EVAL-003 each appear twice with different titles/descriptions. Every automated system (gap-preflight.sh, chump --briefing, musher dispatcher) treats gap ID as a unique key. An agent briefed on COG-011 today receives context for two unrelated tasks with no disambiguation. The pre-commit "gap-ID hijack" guard catches title changes on existing entries but does NOT validate ID uniqueness on insert — that bypass produced all 7 collisions.
  notes: |
    ~2 hrs. Blocking: every agent session starts from a corrupted index until this ships. File as P1 hotfix alongside any other work.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-20'

- id: INFRA-HEARTBEAT-WATCHER
  domain: infra
  title: Heartbeat / liveness daemon — restart silent long-running sweeps
  status: done
  priority: P3
  effort: m
  description: |
    EVAL-026c local 7B → 14B sweep runs for hours. If the parent session disconnects mid-sweep, the agent dies silently — work in progress is wasted. ambient.jsonl already has `silent_agent` ALERT type but nobody is watching today. Need a daemon that subscribes to silent_agent ALERTs, reads the dead session's last lease state, and either (a) restarts the sweep with --resume from last checkpoint, or (b) escalates if --resume isn't supported. Also handles network-disconnect / OOM / ssh-tunnel-died failure modes that lose long sweeps.
  depends_on: [INFRA-AGENT-ESCALATION]
  notes: |
    ~1 week. Lower priority than escalation/dispatch policy — most sweeps complete within a session and this is mainly for the multi-hour local-tool sweeps. Becomes higher priority once we run nightly background sweeps.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-MCP-DISCOVERY
  domain: infra
  title: Dynamic MCP server discovery — auto-detect + register at session start
  status: done
  priority: P3
  effort: s
  description: |
    Goose's Extensions Manager auto-discovers MCP servers on the machine and lets users enable them on demand. Chump currently requires manual config of each MCP server. Auto-discovery would: scan PATH for binaries matching chump-mcp-* pattern, scan ~/.config/chump/mcp-servers/, scan well-known MCP server install locations (e.g. /usr/local/lib/mcp-servers/), register each discovered server, expose via `chump mcp list` command.
  notes: |
    Quality-of-life feature, not a blocker. ~2-3 days. Reference goose's Extensions Manager for UX patterns. The dev.to post on dynamic MCP discovery with goose is a useful design reference: https://dev.to/amandamartindev/dynamic-mcp-server-discovery-with-goose-3m41
  source_doc: external (goose Extensions Manager, dynamic discovery)
  closed_date: '2026-04-20'

- id: INFRA-MEMDB-RACE
  domain: infra
  title: Track funny-hypatia memory_db.rs WIP — clean push after revert
  status: done
  priority: P2
  effort: xs
  description: |
    cf79287 accidentally swept funny-hypatia's incomplete async LLM summarizer WIP into an unrelated commit. 1241e0c reverted memory_db.rs to its pre-stomp state so the build would compile. funny-hypatia later pushed the complete version cleanly as 216e071 (MEM-004).
  source_doc: cf79287
  closed_date: '2026-04-17'

- id: INFRA-MERGE-QUEUE
  domain: infra
  title: Enable GitHub merge queue — serialize auto-merges atomically against current main
  status: done
  priority: P1
  effort: s
  description: |
    Today's PR #128 needed a manual rebase before merge because main had moved ahead 9 commits during the PR's life. Multi-agent dispatch makes this constant — every PR will be BEHIND on landing attempt. GitHub's native merge queue feature serializes auto-merge requests, automatically rebasing each PR onto the current main before running CI and merging. Eliminates the "BEHIND" failure mode entirely. Combined with INFRA-PUSH-LOCK, makes auto-merge safe by construction (no more squash-eats-commits per PR #52 pattern from strategic memo).
  notes: |
    ~1 hour settings change + 1 hour testing + ~2 hours docs/script update. Single highest-leverage change in the multi-agent dispatch architecture. References: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-19'

- id: INFRA-MESSAGING-DEDUPE
  domain: infra
  title: Reconcile MessagingAdapter (mine) vs PlatformAdapter (older) traits
  status: done
  priority: P3
  effort: s
  description: |
    Two parallel platform-adapter traits exist:
      crate::messaging::MessagingAdapter (3e79d77, COMP-004a) — newer,
        richer (request_approval enum, MessagingHub for routing, IncomingMessage
        with platform_metadata + is_dm + attachments).
      crate::adapters::PlatformAdapter (older) — send-only scaffold,
        simpler InboundMessage / OutboundMessage.
    Both telegram impls coexist: src/telegram.rs (mine, full long-poll + MessagingAdapter) and src/adapters/telegram.rs (older, send-only + PlatformAdapter). They don't conflict at runtime (different module paths) but both being "the telegram adapter" is confusing for whoever adds Slack / Matrix next.
  depends_on: [COMP-004a, COMP-004b]
  source_doc: src/messaging/mod.rs
  closed_date: '2026-04-18'

- id: INFRA-MULTIAGENT-HYGIENE
  domain: infra
  title: Per-session worktree + unique session IDs (structural fix)
  status: done
  priority: P1
  effort: l
  description: |
    Multiple Claude sessions on this machine all share $HOME/.chump/session_id (machine-scoped) and frequently operate in the main worktree (/Users/jeffadkins/Projects/Chump) instead of .claude/worktrees/<name>/. Result: lease files clobber each other, pre-staged WIP from one session leaks into another's commit, and git operations (cherry-pick, reset) from one session blow away another's local state. Observed five times on 2026-04-17 alone: cf79287 + a5b5053 (memory_db.rs and DOGFOOD doc stomps), plus three aborted cherry-picks during the COG-011 push. The chump-commit.sh wrapper (688e6da) addresses the symptom; this gap addresses the cause.
  source_doc: CLAUDE.md
  closed_date: '2026-04-17'

- id: INFRA-PUSH-LOCK
  domain: infra
  title: Pre-push hook blocks pushes to PRs with auto-merge armed
  status: done
  priority: P1
  effort: s
  description: |
    Current Chump rule (CLAUDE.md: "NEVER enable auto-merge until the branch is final") is documentation only — not tooling-enforced. PR #52 lost 11 commits to this exact failure mode (strategic memo). Multi-agent dispatch needs auto-merge to be the default, not the exception, so we need tooling to enforce the discipline: pre-push hook that fails when target PR has auto-merge armed. Forces atomic-PR workflow: agents either disarm auto-merge explicitly OR open a new PR for additional changes (cheap with musher dispatcher).
  depends_on: [INFRA-MERGE-QUEUE]
  notes: |
    ~3 hours including tests. Pattern matches existing CHUMP_GAP_CHECK pre-push hook structure. Reference: scripts/git-hooks/pre-push for conventions.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-20'

- id: INFRA-QUEUE-DRIVER-APP-TOKEN
  domain: INFRA
  title: queue-driver must push via GitHub App token, not GITHUB_TOKEN (anti-loop rule)
  status: done
  priority: P1
  effort: xs
  description: |
    INFRA-048 (#497) + INFRA-QUEUE-DRIVER-PERMS (#502) got the queue-driver workflow rebasing PRs successfully, but nothing ever merged. Root cause: GitHub does not trigger new workflow runs for pushes made with GITHUB_TOKEN (the anti-loop rule — see Actions docs, "Triggering a workflow from a workflow"). So `updatePullRequestBranch` succeeded, the PR head advanced, but no `test`/`audit`/`dry-run` CI ran on the new head and auto-merge never fired. 2026-04-24: observed 10+ PRs stranded BLOCKED indefinitely despite queue-driver running every 5 minutes. Manual drain via local PAT worked (user tokens aren't subject to the anti-loop rule) but requires a human-in-the-loop for every main-advance, defeating the purpose of the driver.
  acceptance_criteria:
    - queue-driver.yml mints a GitHub App installation token via actions/create-github-app-token@v1
    - GH_TOKEN env uses the App token (not GITHUB_TOKEN)
    - actions/checkout uses the App token (so the rebase push is signed by the App)
    - App-origin push triggers a fresh CI run on the target PR's new head
    - workflow_dispatch run successfully rebases a BEHIND PR AND new CI starts on the new head
  depends_on: [INFRA-048, INFRA-QUEUE-DRIVER-PERMS]
  notes: |
    Secrets QUEUE_DRIVER_APP_ID and QUEUE_DRIVER_APP_PRIVATE_KEY hold the App credentials; App has Contents:write + Pull-requests:write on repairman29/chump only. The App token is minted per workflow run with a 1-hour TTL so no long-lived PAT exposure. If the App is ever uninstalled or the key rotated, the workflow fails loud at the create-github-app-token step — no silent degradation.
  opened_date: '2026-04-24'
  closed_date: '2026-04-24'

- id: INFRA-QUEUE-DRIVER-PERMS
  domain: INFRA
  title: "queue-driver workflow needs contents:write to call updatePullRequestBranch"
  status: done
  priority: P1
  effort: xs
  description: |
    INFRA-048 (#497) shipped the Queue Driver workflow but declared `permissions: { pull-requests: write, contents: read }`. The `updatePullRequestBranch` GraphQL mutation rebases a PR by pushing a new commit onto the PR's head branch — that push requires `contents: write`, not `contents: read`. Observed 2026-04-24 immediately after #497 merged: workflow_dispatch run logged "GraphQL: github-actions[bot] does not have permission to update this pull request. (updatePullRequestBranch)" and left the PR BEHIND. Fix: change `contents: read` to `contents: write` in `.github/workflows/queue-driver.yml`. No admin toggle needed — repo default_workflow_permissions is already "write"; the workflow's explicit permissions block was just downgrading.
  acceptance_criteria:
    - "queue-driver.yml declares contents:write"
    - Queue Driver workflow_dispatch run successfully rebases a BEHIND PR via updatePullRequestBranch
    - "Documented in-file why contents:write is required (one-line comment)"
  depends_on: [INFRA-048]
  notes: |
    Found while unsticking the 2026-04-24 queue (11 PRs armed, strict up-to-date rule, main advancing every ~15 min). Manual `gh pr update-branch` (user PAT) works fine; only the workflow token was blocked.
  opened_date: '2026-04-24'
  closed_date: '2026-04-24'

- id: INFRA-STUCK-QUEUE-RUNBOOK
  domain: infra
  title: CLAUDE.md atomic-PR-discipline — add stuck-queue recovery runbook
  status: done
  priority: P2
  effort: xs
  description: |
    CLAUDE.md's Atomic PR discipline bullet told agents what NOT to do (don't push after auto-merge arms) but gave no instructions for the recovery path when the GitHub merge queue actually gets stuck. Observed risk: agents who hit a stuck queue either (a) violate the no-push rule to "unstick" it and reintroduce the PR #52 squash-loss footgun, or (b) stall the whole fleet because no one knows the queue's dequeue/checkpoint/drain procedures. This gap adds a six-step inline recovery runbook to the same CLAUDE.md bullet — diagnose → re-run CI → dequeue blocker → checkpoint-tag recovery → nuclear drain → escalate to human — so agents have a concrete least-destructive-first procedure when symptoms appear. Keeps the recovery colocated with the rule it modifies rather than forcing a jump to MERGE_QUEUE_SETUP.md (which is a human admin setup doc, not an operator runbook).
  acceptance_criteria:
    - "CLAUDE.md Atomic-PR-discipline bullet gains an \"If the merge queue is stuck\" sub-bullet"
    - Recovery steps ordered least-destructive first (diagnose → rerun → dequeue → checkpoint → drain → escalate)
    - Each step names the concrete gh/git command an agent would run
    - Checkpoint-tag recovery path documented (references PR
    - "Escalation path (\"flag ALERT kind=queue_stuck in ambient.jsonl and stop\") is explicit so agents don't churn new PRs against a broken queue"
  depends_on: [INFRA-MERGE-QUEUE, INFRA-PUSH-LOCK]
  notes: |
    Docs-only. No tooling change. Pairs with a possible future INFRA-QUEUE-HEALTH monitor gap (not filed) that would emit the ALERT kind=queue_stuck event automatically when queue-entry age exceeds a threshold.
  source_doc: 2026-04-20 session — gap noted during RESEARCH-003 ship
  closed_date: '2026-04-20'

- id: INFRA-SYNTHESIS-CADENCE
  domain: infra
  title: Periodic synthesis pass — distill session learnings into strategic docs
  status: done
  priority: P3
  effort: s
  description: |
    Today I did a synthesis pass manually: distilled session findings into FACULTY_MAP updates, STRATEGY_VS_GOOSE updates, RESEARCH_PLAN adjustments, RESEARCH-001 stub fills, EVAL-029 mechanism doc. This is the "cross-session memory consolidation" function — without it, session learnings stay in session transcripts and don't reach the next agent. INFRA-SYNTHESIS-CADENCE makes it a recurring task: a scheduled agent dispatch that reads the last N hours of session activity (PRs, reflections, ambient events) and proposes strategic- doc updates as a small PR.
  notes: |
    ~3 days. Cheap automation. Without it, every session reinvents the wheel by re-reading raw artifacts; with it, the team's collective intelligence keeps refining itself in distilled form.
  source_doc: session 2026-04-19 multi-agent learning loop design
  closed_date: '2026-04-20'

- id: INFRA-WHITE-PAPERS-PANDOC
  domain: infra
  title: "Pandoc 'withBinaryFile: does not exist' in white-papers CI"
  status: done
  priority: P3
  effort: s
  description: |
    White-papers CI has been failing since before this session with "pandoc: withBinaryFile: does not exist (No such file or directory)". All source files in docs/white-paper-manifest.json exist in main. Likely causes: a generated file (roadmap excerpt, changelog excerpt) isn't being created in the preprocess workdir, an image/asset reference in one of the markdowns points at a file not in the repo, or the pandoc image upgraded and changed path semantics.
  notes: |
    Diagnostic gathered 2026-04-17 (no docker locally — daemon not running, can't run the exact CI invocation):
      - `python3 scripts/build-white-papers.py --volume volume-1-showcase
        --html-only` SUCCEEDS locally. Same source files, same local
        pandoc 3.x.
      - `--volume volume-1-showcase --chrome-pdf` SUCCEEDS locally.
        1.6 MB PDF generated.
      - LaTeX path unavailable (no xelatex/pdflatex on PATH); can't
        test that without basictex.
      - No image/asset references in scanned volume-1 sources point at
        relative files (just http(s) URLs — those are fine).
      - The CI failure is in the docker-pandoc-latex path specifically.
    Hypotheses ranked by likelihood:
      1. (HIGH) The pandoc/latex:latest-ubuntu image got a version bump
         that changed `--resource-path` semantics (the script passes
         `/data/{work_rel}:/data:/data/docs`). Pin the digest in
         CHUMP_WHITE_PAPER_IMAGE — `latest-ubuntu` is a moving target.
      2. (MED) An asset reference uses a path that resolves locally via
         the resource-path search but not inside docker because of how
         the work_rel symlinks are stored.
      3. (LOW) A markdown source uses an `\input{}` or `\include{}`
         LaTeX command pointing at a missing tex file.
    Repro recipe for whoever picks this up:
      1. `colima start` or `docker desktop start`
      2. `docker pull pandoc/latex:latest-ubuntu`
      3. `python3 scripts/build-white-papers.py --volume volume-1-showcase
         --docker 2>&1 | tee /tmp/pandoc-fail.log`
      4. Get the full stderr: `grep -A20 "withBinaryFile" /tmp/pandoc-fail.log`
      5. Try pinning to a known-good digest:
         `CHUMP_WHITE_PAPER_IMAGE=pandoc/ubuntu-latex:3.6 python3 scripts/...`
  source_doc: scripts/build-white-papers.py
  closed_date: '2026-04-17'

- id: INFRA-WHITE-PAPERS-TRIGGER
  domain: infra
  title: Stop white-papers workflow firing on registry-file edits
  status: done
  priority: P3
  effort: xs
  description: |
    white-papers.yml triggered on any docs/** push, including docs/gaps.yaml and docs/AGENT_COORDINATION.md which change many times per day and aren't sources for any PDF volume. Result: the workflow ran (and failed, see INFRA-WHITE-PAPERS-PANDOC) on almost every commit, cluttering the status dashboard.
  source_doc: .github/workflows/white-papers.yml
  closed_date: '2026-04-17'

- id: INFRA-WORKTREE-PATH-CASE
  domain: infra
  title: Sibling agent created worktree at lowercase /Users/jeffadkins/projects/Chump
  status: done
  priority: P3
  effort: s
  description: |
    During the 2026-04-19 tidy audit, observed that one worktree (sweet-payne-9f4a6b) was created at `/Users/jeffadkins/projects/Chump/.claude/worktrees/sweet-payne-9f4a6b/` — note the LOWERCASE `projects` path component vs the standard `/Users/jeffadkins/Projects/Chump/...` (capital P). macOS HFS+/APFS is case-insensitive so the path resolves, but case-sensitive tools (some git operations, rsync, Linux CI) may misbehave. Likely caused by an agent constructing the path from `pwd | tr A-Z a-z` or similar. Should: (1) audit all spawn-worktree code paths in scripts/ for case-normalization, (2) add a guard that rejects worktree creation if the absolute path does not exactly match `/Users/jeffadkins/Projects/Chump/.claude/worktrees/<name>/`, (3) document the path requirement explicitly in CLAUDE.md + AGENTS.md.
  notes: |
    Filed during 2026-04-19 evening tidy audit. Active sweet-payne worktree NOT touched — sibling agent's work in progress. After that worktree's PR lands, audit safely.
  source_doc: session 2026-04-19 tidy audit
  closed_date: '2026-04-20'

- id: INFRA-WORKTREE-REAPER
  domain: infra
  title: Stale-worktree reaper — automate cleanup of merged-branch worktrees
  status: done
  priority: P3
  effort: s
  description: |
    Tidy audit of .claude/worktrees/ on 2026-04-19 found 9 worktrees besides main, several of which correspond to already-merged PRs (e.g. .claude/worktrees/eval-025 → PR #120 merged 2026-04-19). Stale worktrees retain disk + lease files + risk of accidental commits to dead branches. We already have scripts/stale-pr-reaper.sh that auto-closes PRs whose gaps shipped to main; need the dual: a worktree reaper that detects worktrees on branches that have been merged-and-deleted on origin and removes them safely. Caveat: must preserve logs/ab/*.summary.json archive data — these are the only on-disk record of past eval runs and should be moved somewhere central before the worktree is deleted.
  notes: |
    ~3-4 hours implementation. Reference: existing scripts/stale-pr-reaper.sh for cron pattern + safety conventions. Filed during 2026-04-19 evening tidy audit.
  source_doc: session 2026-04-19 tidy audit
  closed_date: '2026-04-19'

- id: INFRA-WORKTREE-REAPER-FIX
  domain: infra
  title: stale-worktree-reaper missed long-running background bash — broke EVAL-026c sweep
  status: done
  priority: P2
  effort: s
  description: |
    The INFRA-WORKTREE-REAPER shipped in PR #143 has an "active lease" check that prevents reaping a worktree with a live `.chump-locks/*.json`. But during the 2026-04-19 evening manual reap pass (using the same logic), the u-curve-32b worktree was reaped while a long-running background bash sweep (EVAL-026c local 7B/14B) was still actively writing to its logs/ab/ directory. Sweep died at trial 45/50 of the 7B run; 14B never started. Lost ~98 trials of local-tool data. The reaper checks for lease files but NOT for active processes writing to the worktree. Both are needed.
  notes: |
    ~3 hours. Tactical: until this fix lands, when in doubt about reaping a worktree, check `lsof +D <worktree-path>` first or just grep `ps -ef` for the worktree path. The auto-cron is conservative enough (only reaps merged-and-remote-deleted branches) that this bug won't hit there — only manual invocations are at risk.
  source_doc: session 2026-04-19 evening — INFRA-WORKTREE-REAPER ship + immediate post-mortem
  closed_date: '2026-04-19'

- id: INFRA-WORKTREE-STAGING
  domain: infra
  title: Pre-staged WIP from other agents leaks into commits in shared worktree
  status: done
  priority: P2
  effort: s
  description: |
    Multiple agents share /Users/jeffadkins/Projects/Chump (the main worktree) while also having their own .claude/worktrees/<name>. When agent A `git add`s a file but doesn't commit, then agent B runs `git add <unrelated>` and `git commit`, the commit accidentally includes agent A's pre-staged file too.
    Observed twice this session:
      - cf79287: my needless_return fix swept funny-hypatia's incomplete
        memory_db.rs WIP (broken stmt lifetime); had to revert in 1241e0c.
      - a5b5053: my gaps.yaml additions swept an unrelated
        DOGFOOD_RELIABILITY_GAPS.md edit from another agent.
    
    Pre-commit hook already validates leases on staged paths but does not warn when a commit includes files the current command did not touch.
  source_doc: cf79287, a5b5053
  closed_date: '2026-04-17'

- id: MEM-001
  domain: memory
  title: Add cross-encoder reranker to final RRF retrieval output
  status: done
  priority: P2
  effort: m
  description: |
    The three-path retrieval (FTS5 + semantic + graph PPR) merges via RRF but has no reranking stage. A lightweight cross-encoder (e.g. ms-marco-MiniLM via candle or a local model) would improve precision without changing recall.
  depends_on: [COG-002]
  source_doc: docs/CHUMP_TO_COMPLEX.md, book/src/dissertation.md
  closed_date: '2026-04-16'

- id: MEM-002
  domain: memory
  title: Memory curation — confidence decay, deduplication, episodic summarization
  status: done
  priority: P2
  effort: l
  description: |
    Memory confidence is author-assigned and never decays. Old episodic memories accumulate without summarization into semantic facts. No deduplication. Long-running sessions will degrade retrieval quality as noise accumulates.
  notes: |
    DONE: memory_curate() in memory_db.rs: (1) confidence decay -0.01 for unverified memories older than 7 days; (2) exact-content deduplication within each memory_type (keep highest-confidence copy via ROW_NUMBER window function); FTS5 rebuilt after dedup. CurateResult{decayed, deduped} returned. 2 unit tests covering decay and dedup. OPEN: (3) LLM-based episodic cluster summarization (requires agent call).
  source_doc: docs/CHUMP_TO_COMPLEX.md, book/src/dissertation.md
  closed_date: '2026-04-16'

- id: MEM-003
  domain: memory
  title: LLM episodic → semantic summarization (curation third pillar)
  status: done
  priority: P3
  effort: m
  description: |
    MEM-002 shipped the DB-only curation passes (decay + dedupe + expire) but deferred the LLM summarization of old episodic clusters into distilled semantic facts because it needs inference budget. Add a delegate-call path (single model request per cluster, guarded by neuromod-aware rate limiting) so curate_all() can optionally run the summarization tier.
  depends_on: [MEM-002]
  source_doc: docs/CHUMP_TO_COMPLEX.md, book/src/dissertation.md
  closed_date: '2026-04-17'

- id: MEM-004
  domain: memory
  title: Wire async LLM summarizer into curate_all
  status: done
  priority: P3
  effort: s
  description: |
    MEM-003 shipped the sync orchestration; the async adapter that builds a summarizer closure from a delegate_tool call + wires it into the default curate_all path (behind CHUMP_MEMORY_LLM_SUMMARIZE) is the remaining piece. Small because the hard test surface already exists in memory_db.
  depends_on: [MEM-003]
  source_doc: docs/CHUMP_TO_COMPLEX.md
  closed_date: '2026-04-17'

- id: MEM-005
  domain: memory
  title: Episode extractor — synthesise durable facts from episodes into blackboard
  status: done
  priority: P2
  effort: m
  description: |
    Phase 8.1 from ROADMAP_CLAUDE_UPGRADE.md. Background pass that scans recent chump_episodes entries, calls the delegate worker to extract one durable fact per episode, and writes the result to chump_blackboard_persist. A chump_blackboard_cursor table tracks the highest processed episode_id so the pass is idempotent — re-running never re-extracts the same episode.
  depends_on: [MEM-004]
  source_doc: docs/ROADMAP_CLAUDE_UPGRADE.md
  closed_date: '2026-04-18'

- id: MEM-006
  domain: memory
  title: Lessons-loaded-at-spawn — agents inherit prior reflection lessons on start
  status: done
  priority: P2
  effort: m
  description: |
    PRODUCT-006 (shipped via PR #125) writes reflection lessons into chump_improvement_targets via harvest-synthesis-lessons.sh. But the question of whether new agents START with these lessons loaded is unanswered. If lessons are only retrieved on explicit memory_db query, we are collecting lessons without applying them systematically. Multi-agent dispatch needs every spawned agent to inherit relevant prior lessons as part of its initial context. A/B-validate the value: agents with prior-lesson context vs fresh agents on the same fixture.
  depends_on: [COG-023, COG-024]
  notes: |
    ~1 week including A/B validation sweep. Closes the loop between reflection accumulation (PRODUCT-006 shipped) and reflection application (this gap). Without it, our learning system writes to nothing. Code shipped without empirical A/B — validation tracked as MEM-006-VALIDATE.
  source_doc: session 2026-04-19 multi-agent dispatch design
  closed_date: '2026-04-19'

- id: MEM-006-VALIDATE
  domain: memory
  title: Empirical A/B for spawn-loaded lessons (cell A vs cell B, n=50 reflection)
  status: done
  priority: P2
  effort: s
  description: |
    MEM-006 shipped the load_spawn_lessons() + CHUMP_LESSONS_AT_SPAWN_N env var without A/B validation because the existing run-cloud-v2.py harness does not invoke chump-internal prompt assembly (it talks directly to provider APIs). To validate the hypothesis that spawn-loaded lessons improve correctness, we need a local Chump dispatch path (chump-orchestrator step 4-5 territory) so cell A (CHUMP_LESSONS_AT_SPAWN_N=5) and cell B (unset) can be measured apples-to-apples on the same fixture under the same model.
  depends_on: [MEM-006]
  notes: |
    ~3 days once a local-Chump-dispatch path exists. Pre-requisite work lives in the chump-orchestrator step 4-5 territory.
  source_doc: deferred from MEM-006 PR (2026-04-19)
  closed_date: '2026-04-20'

- id: MEM-007
  domain: memory
  title: "Agent context-query — \"what should I know before working on gap X?\""
  status: done
  priority: P2
  effort: m
  description: |
    Today's mandatory pre-flight (CLAUDE.md) reads gaps.yaml + ambient + leases. Good for "what's open, who's working" but doesn't surface "what have we learned that's relevant to MY task". MEM-007 adds `chump --briefing <GAP-ID>` that returns a structured briefing: relevant reflection_db rows (filtered by gap domain + tags), recent ambient events for files this gap likely touches, cross-references in strategic docs (FACULTY_MAP, STRATEGY_VS_GOOSE, RESEARCH_PLAN, CONSCIOUSNESS_AB_RESULTS), prior PRs that closed similar gaps. Becomes the "session startup briefing" every new agent reads AFTER mandatory pre-flight, BEFORE claiming the gap.
  depends_on: [MEM-006]
  notes: |
    ~1 week. Pairs with MEM-006: MEM-006 loads lessons systemically at spawn; MEM-007 is the explicit per-gap query API. Together they close the "what does the team know about THIS task" loop.
  source_doc: session 2026-04-19 multi-agent learning loop design
  closed_date: '2026-04-18'

- id: MEM-008
  domain: memory
  title: Multi-hop QA fixture spec — define what multi-hop means before building
  status: done
  priority: P2
  effort: s
  description: |
    EVAL-034 (memory retrieval multi-hop QA) acceptance says "build a multi-hop QA fixture (~30 questions)" without specifying what kind of multi-hop reasoning is tested. Without a fixture spec, a negative result is uninterpretable: does it mean the memory graph is broken, or that the fixture only tests simple recall? Three meaningful categories:
      (a) Entity resolution: "Alice" = "my coworker Alice" = "alice@work"
      (b) Temporal reasoning: did X happen before Y?
      (c) Transitive closure: A→B and B→C implies A→C
    A pilot (n=20, 3 categories × 7 questions each) should run before committing to the full EVAL-034 n=50 sweep.
  notes: |
    ~0.5 days. Cheap design work that prevents an expensive ($10+) EVAL from being uninterpretable. Should precede EVAL-034.
  source_doc: docs/RESEARCH_INTEGRITY.md backlog audit 2026-04-19
  closed_date: '2026-04-20'

- id: MEM-009
  domain: memory
  title: Reflection episode quality filtering before spawn-load
  status: done
  priority: P2
  effort: m
  description: |
    MEM-006 ships load_spawn_lessons() which pulls the N most recent reflection episodes into the lessons block at session spawn. If the agent had a bad session (5 consecutive task failures, reflection DB rows with low confidence or repeated errors), it will inherit "bad lessons" that poison the spawn-time context. No quality threshold or filtering exists today. Mechanisms to filter:
      (a) Confidence score threshold: only load episodes with
          reflection_score > X
      (b) Error-rate filter: skip episodes from sessions with > Y%
          task failure rate
      (c) Recency × quality composite: weight by age * score
  depends_on: [MEM-006]
  notes: |
    ~1 day + $2 cloud for A/B. Risk of bad-lesson poisoning compounds as reflection DB accumulates more sessions over time.
  source_doc: docs/RESEARCH_INTEGRITY.md backlog audit 2026-04-19
  closed_date: '2026-04-20'

- id: MEM-010
  domain: memory
  title: Entity resolution accuracy A/B — linked vs unlinked multi-hop QA
  status: done
  priority: P2
  effort: m
  description: |
    MEM-005 ships entity resolution and deduplication in memory_graph.rs (PersonRank + entity linking). But there is no validation that entity linking is accurate enough to support multi-hop reasoning. If the linker merges "Alice (Rust expert)" with "Alice (project manager)" as the same entity due to name collision, multi-hop QA that asks "who wrote the parser?" will return wrong results silently. A 70% accurate linker fails 30% of multi-hop queries.
  depends_on: [MEM-008]
  notes: |
    ~1 day. Silent failure mode: wrong entity links produce wrong answers with no error signal. Catches this before EVAL-034 runs.
  source_doc: docs/RESEARCH_INTEGRITY.md backlog audit 2026-04-19
  closed_date: '2026-04-20'

- id: MEM-011
  domain: memory
  title: Causal graph edge obsolescence — invalidate stale causal chains
  status: done
  priority: P2
  effort: s
  description: |
    CausalGraph edges in counterfactual.rs never expire. When an API changes or a tool is deprecated, old high-strength causal chains remain active and generate regressive lessons. MEM-002 decays flat memory confidence but does not touch graph edges.
  depends_on: [MEM-002, COG-004]
  closed_date: '2026-04-16'

- id: META-001
  domain: META
  title: Diagnostic and red-team agents must verify gap activity via git log before 'no movement' claims
  status: open
  priority: P2
  effort: s
  description: |
    Cold Water Issue #5 (2026-04-25) noted "Documentation of failure is now
    a recurring ritual. The failure itself is undisturbed." A 2026-04-26
    diagnostic pass made eight specific incorrect "no movement" or "still
    open" claims that git-log verification refuted - PRODUCT-015 had 6
    commits including PR #491 shipping activation funnel telemetry,
    RESEARCH-021 had 14 commits, EVAL-074 had 11 (mechanism shipped via
    #549, retracted via #551, follow-up filed via #558), FLEET-006 was
    actually status:done, EVAL-043 was actually status:done, the
    "INFRA-073 8th duplicate-ID collision in YAML" claim found only one
    entry. The pattern: agents read status:open and infer inactivity
    without checking 'git log --grep'. Add the verification rule to the
    Cold Water prompt, the Explore-agent template guidance, and any
    diagnostic-style skill. Any "no movement" / "stalled" / "no commits"
    claim must be backed by the output of 'git log origin/main
    --grep=<ID>' showing zero or stale commits.
  acceptance_criteria:
    - Cold Water prompt updated to require 'git log --grep=<ID>' citation for any inactivity claim
    - Diagnostic / red-team skills under docs/agents/ document the verification rule
    - Next Red Letter cycle has zero unverified inactivity claims (manual spot-check)
    - Rule lives in docs/agents/RED_TEAM_VERIFICATION.md or equivalent so future agents inherit it
  opened_date: '2026-04-26'

- id: META-002
  domain: META
  title: FIXED-but-immediately-replaced classification missing from RED_TEAM_VERIFICATION.md
  status: open
  priority: P2
  effort: s
  description: |
    FLEET-006 (ambient stream — 6 cycles) was classified FIXED in
    Issue #8 (PR #572, bb596c2). On the same date, FLEET-017 (P0, open)
    was filed: "Cold Water remote agent does not subscribe to NATS
    ambient stream — FLEET-006 unused." The fix shipped; the agent
    that needed the fix was never wired up.
    
    docs/agents/RED_TEAM_VERIFICATION.md has no classification for
    this pattern: a gap is FIXED in the technical sense (code shipped)
    but a same-day P0/P1 replacement gap was filed that makes the
    original pain point still unresolved. Classifying FLEET-006 as
    FIXED is technically correct but obscures that the 6-cycle void is
    still present from the ambient stream's consumer perspective.
    
    Without this classification, Cold Water will systematically
    undercount active failures when architectural fixes don't include
    consumer wiring. Cold Water Issue #8.
  acceptance_criteria:
    - "docs/agents/RED_TEAM_VERIFICATION.md adds FIXED_BUT_REPLACED classification: gap is done, same-day P0/P1 replacement filed, original pain point still active from consumer perspective"
    - Cold Water review template updated to check for same-day P0/P1 replacement gaps before classifying a finding as FIXED
    - FLEET-006 and FLEET-017 cited as the canonical example
  opened_date: '2026-04-27'

- id: META-003
  domain: META
  title: Cold Water agent factual errors Red Letter
  status: done
  priority: P1
  effort: s
  description: |
    Red Letter Issue #8 (2026-04-27) shipped with three factual errors
    that the agent prompt did not prevent:
    
    1. **P0 misclassification.** Issue #8 listed 8 P0 gaps including
       INFRA-084 (actually P1) and INFRA-094 (actually P2). Hand-counted
       from gaps.yaml without querying the canonical SQLite store.
    2. **Stale status claim.** INFRA-083 was listed as "OPEN-BUT-LANDED"
       but had already been closed via PR #561 commit `567a5d9` on
       2026-04-26 — one day before the cycle ran.
    3. **Drifted snapshot.** Claimed "65/88 (74%) OPEN-BUT-LANDED" but
       current open count is 116; the snapshot pre-dated multiple
       gap-filing days.
    
    Root cause: the agent prompt at docs/agents/cold-water.md (a) cited
    a wrong gap-reserve.sh path (`scripts/coordination/gap-reserve.sh`
    and `scripts/gap-reserve.sh` — neither exists; only
    `scripts/coord/gap-reserve.sh` does), (b) instructed YAML edits
    without `chump gap import` reconciliation so SQLite store drifts
    from YAML (verified: DOC-012, META-002, PRODUCT-021, EVAL-092
    landed in YAML on origin/main but not in `.chump/state.db`), and
    (c) had no required priority-or-status verification step against
    the canonical store before publishing.
  acceptance_criteria:
    - docs/agents/cold-water.md Step 3 prefers `chump gap reserve` over the shell fallback; shell path is corrected to scripts/coord/gap-reserve.sh
    - docs/agents/cold-water.md adds a verification block requiring every filed gap to appear in BOTH docs/gaps.yaml AND `chump gap list` output before being listed in the Follow-up Gaps Filed section
    - docs/agents/cold-water.md requires P0 census and status claims to come from `chump gap list --json`, not hand-counts
    - Trigger trig_01GA2XVbAZtpkBaWfrEo1CrP synced via /schedule update after PR merges
  opened_date: '2026-04-27'
  closed_date: '2026-04-28'
  closed_pr: 619

- id: META-004
  domain: META
  title: "structural-fixes-over-symptom-patches: track 50-coordination-patch backlog vs handful of root-cause fixes"
  status: open
  priority: P1
  effort: s

- id: META-005
  domain: META
  title: P0 open-but-landed pattern — three P0 gaps shipped but never closed
  status: open
  priority: P2
  effort: xs
  description: |
    Three P0 gaps shipped implementation commits this cycle but remain status:open:
      - PRODUCT-024: PR #697 commit body says "PRODUCT-024: close as done (closed_pr=697)"
        but docs/gaps.yaml shows status:open, no closed_pr.
      - INFRA-183: all sub-tasks shipped (INFRA-184 PR#701, INFRA-185 PR#704,
        PRODUCT-024 PR#697, INFRA-199 PR#710) but umbrella shows status:open.
      - SECURITY-004: 1 of 6 advisories closed via SECURITY-005 (PR#682);
        5 remain (rand, glib, 3 rustls-webpki paths); no upgrade commits.
    
    This is the third cycle where P0 gaps ship partial or full implementation
    without formal closure. INFRA-107 (closed_pr integrity guard) was filed
    precisely to prevent false closures — but it does not prevent the inverse:
    true implementations that are never formally closed.
    
    The pattern: agents write "close as done" in commit bodies but do not run
    `chump gap ship <ID> --closed-pr <N> --update-yaml`. The gap registry
    accumulates P0-tagged open entries that are actually done, misleading the
    next agent session about what is truly unstarted.
  acceptance_criteria:
    - "PRODUCT-024 shows status:done with closed_pr:697 in docs/gaps.yaml"
    - "INFRA-183 shows status:done with a closed_pr in docs/gaps.yaml"
    - "SECURITY-004 has an implementation commit addressing the remaining 5 advisories OR shows status:done with a documented resolution"
    - "AGENTS.md / CLAUDE.md ship pipeline section updated with explicit reminder: 'close the gap in state.db after the PR merges, not just in the commit body'"
  opened_date: '2026-05-02'

- id: META-006
  domain: META
  title: Evaluate retiring docs/gaps.yaml — state.sql + ported shell scripts as single source
  status: open
  priority: P2
  effort: m
  description: |
    docs/gaps.yaml is a regenerated mirror today (canonical = .chump/state.db since INFRA-059), but it has three real users that block its retirement:
    
      (1) Shell scripts gap-claim.sh / gap-reserve.sh / gap-preflight.sh / pre-push hook / pre-commit guards parse it directly (NOT state.db). Per CLAUDE.md: shell scripts still operate on docs/gaps.yaml + .chump-locks/.
      (2) Human PR reviewers consume the YAML diff (though .chump/state.sql provides reviewable text diffs of the canonical store).
      (3) gap-doctor.py exists specifically to detect YAML↔DB drift — its raison d'être evaporates if YAML goes.
    
    Investigate cost vs benefit of porting the shell scripts to query state.db and dropping YAML entirely, vs INFRA-188's opposite direction (per-file docs/gaps/<DOMAIN>-<NNN>.yaml). One source of truth eliminates a whole class of corruption incidents (INFRA-049/052/055/057/064 were all YAML↔DB races) but breaks the human-PR-readability path unless state.sql fully substitutes.
    
    Hard-blocked by INFRA-208 (chump gap dump is lossy) — until dump round-trips losslessly, retiring YAML risks data loss for the 264 affected fields.
  depends_on: [INFRA-208]

- id: META-007
  domain: META
  title: "Audit methodology: must inspect JSONL evidence, not just shebang/timestamp inference"
  status: open
  priority: P2
  effort: xs
  description: |
    EVAL-090 (2026-05-01) found that INTEGRITY_AUDIT_3's claim 'EVAL-069 ran under broken scorer' was contradicted by direct inspection of the archived JSONL — 99/100 rows showed scorer=llm_judge. The audit reasoned correctly about the python3.12 shebang foot-gun's existence, but inferred from configuration timeline (shebang state, commit date) without checking whether the run actually fell into that foot-gun. Going forward, audits of past runs must inspect the actual JSONL outputs (scorer field distribution, output_chars, exit_code per row) and compare against the writeup's stated method. The shebang/binary/config state is a *prediction* of what the run did; the JSONL is *evidence* of what it actually did. When the two disagree, the JSONL wins. Action: add a one-paragraph 'Audit checklist' header to docs/audits/AUDIT_PROTOCOL.md (or create it if missing) listing 'inspect output JSONL before claiming credibility break' as the first step.
  acceptance_criteria:
    - audit checklist documented in docs/audits/AUDIT_PROTOCOL.md
    - past audits cite EVAL-090 as the originating example
    - future EVAL/RESEARCH credibility audits inspect JSONL before drawing mechanism conclusions

- id: PRODUCT-001
  domain: product
  title: PWA Dashboard — ship status, what-we're-doing, recent episodes
  status: done
  priority: P1
  effort: m
  description: |
    Horizon 1 goal: open PWA and see Dashboard with current ship status, "Building: Step 3...", recent episodes. GET /api/dashboard exists in spec (WEB_API_REFERENCE.md) but Dashboard view is incomplete or not implemented.
  notes: |
    Added fleet_status (green/yellow/red), last_heartbeat_iso to /api/dashboard. New /api/dashboard/stream SSE endpoint pushes snapshot every 30s. Frontend uses EventSource with polling fallback; applyDashboardSnapshot shared between SSE handler and loadDashboard.
  source_doc: docs/ECOSYSTEM_VISION.md
  closed_date: '2026-04-17'

- id: PRODUCT-002
  domain: product
  title: Single-command fleet deploy — scripts/deploy-fleet.sh for Mac + Pixel
  status: done
  priority: P1
  effort: s
  description: |
    Horizon 1 goal: one command to build and deploy Mac + Pixel on the same commit and config. scripts/deploy-fleet.sh referenced but status unknown.
  notes: |
    scripts/deploy-fleet.sh is fully implemented: parallel Mac+Android builds, hot-swap Discord+Web bots, deploy-all-to-pixel.sh for Pixel, fleet-health.sh final check. Flags: --mac, --pixel, --no-build, --health.
  source_doc: docs/ECOSYSTEM_VISION.md
  closed_date: '2026-04-16'

- id: PRODUCT-003
  domain: product
  title: User profile system — three-layer identity, context, and learned preferences
  status: done
  priority: P1
  effort: l
  description: |
    Chump currently starts every session knowing nothing about the user. The cognitive architecture (neuromodulation, belief state, precision controller) runs blind with no user model to calibrate against. This gap implements the three-layer user model: (1) Identity & Relationship — persistent, encrypted, who the user is and how they work; (2) Current Context — volatile, stale-flagged after 7 days, active projects and goals; (3) Learned Preferences — Chump-observed, user-confirmable behavioral observations. Profile data is never injected raw into prompts, never written to logs or ambient.jsonl, never committed to git. A user_context() function returns a curated behavioral summary; behavioral regime fields compile into the PrecisionController at session start. Storage: sessions/user_profile.db (AES-256-GCM field encryption, keyring crate for key management, 600 permissions).
  source_doc: docs/FTUE_USER_PROFILE.md
  closed_date: '2026-04-19'

- id: PRODUCT-004
  domain: product
  title: FTUE — first-run onboarding conversation that populates the user profile
  status: done
  priority: P1
  effort: m
  description: |
    The first-time user experience is the most important interaction Chump has. Right now there is no onboarding — a new user opens the PWA and faces a blank input with no guidance. This gap implements the onboarding conversation: Chump detects profile_complete()==false, opens with "I'm happy to help — let's set you up for success," and walks through five targeted questions: name, role/domains, active projects, this-week goals, and working style (checkin frequency). Each answer writes to the corresponding profile layer. After Q5, Chump summarizes, confirms, and immediately starts on the first real task from Q3/Q4. A "skip" path sets sensible defaults and asks only "what do you want to work on?" Profile builds over time from there.
  depends_on: [PRODUCT-003]
  source_doc: docs/FTUE_USER_PROFILE.md
  closed_date: '2026-04-19'

- id: PRODUCT-005
  domain: product
  title: scripts/generate-sprint-synthesis.sh — automated synthesis generation in heartbeat
  status: done
  priority: P2
  effort: m
  description: |
    No automated mechanism generates session syntheses. scripts/generate-cos-weekly-snapshot.sh exists as a model: it reads SQLite and git log, emits a markdown report. We need a similar script for session/sprint syntheses. Then wire it into heartbeat-self-improve.sh as a sprint_synthesis round type (fires after every N work rounds, configurable via CHUMP_SYNTHESIS_INTERVAL). The script collects commits since last synthesis, queries SQLite for tasks completed and AB studies run, calls the model via chump --chump to generate narrative, writes to docs/syntheses/YYYY-MM-DD.md.
  source_doc: docs/syntheses/README.md
  closed_date: '2026-04-19'

- id: PRODUCT-006
  domain: product
  title: harvest-synthesis-lessons.sh — mine synthesis operational rules into lessons layer
  status: done
  priority: P2
  effort: s
  description: |
    generate-sprint-synthesis.sh writes a narrative synthesis but the lessons it captures (section 3: Methodology lessons) stay in a markdown file — they don't feed back into Chump's prompt. This gap closes the loop: harvest-synthesis-lessons.sh reads the synthesis, extracts ### lesson subsections and operational rules bullets, and writes them into chump_improvement_targets (priority=high, scope=NULL) so prompt_assembler.rs surfaces them automatically via the existing lessons block. Capped at 3 per synthesis to stay within LESSONS_LIMIT=5. Idempotent: skips if already harvested (checks chump_reflections error_pattern='synthesis:<date>'). Disable with CHUMP_HARVEST_LESSONS=0.
  depends_on: [PRODUCT-005]
  source_doc: docs/syntheses/README.md
  closed_date: '2026-04-19'

- id: PRODUCT-008
  domain: product
  title: Best-practice extraction — successful patterns auto-propagate to CLAUDE.md / TEAM_OF_AGENTS.md
  status: done
  priority: P3
  effort: m
  description: |
    When a pattern produces validated success (e.g. today: "atomic PR + auto-merge worked across 9 PRs", "code-reviewer agent verified PR #134 with sensible APPROVE verdict"), the pattern should auto-propagate as a convention to CLAUDE.md or TEAM_OF_AGENTS.md. Currently this is manual — I distilled today's patterns into the docs by hand. PRODUCT-008 automates: nightly scan of merged PRs + reflection_db outcomes + ambient events, identify patterns with >N positive instances and 0 negative, generate proposed convention update PR for human review.
  depends_on: [PRODUCT-006, INFRA-SYNTHESIS-CADENCE]
  notes: |
    ~1 week. The "convention crystallization" loop. Without it, good patterns stay tribal knowledge in one session's head; with it, they propagate into the cross-session brain (CLAUDE.md, etc.).
  source_doc: session 2026-04-19 multi-agent learning loop design
  closed_date: '2026-04-20'

- id: PRODUCT-009
  domain: product
  title: External publication of F1-F6 empirical findings (preprint or blog post)
  status: open
  priority: P2
  effort: m
  description: |
    Five empirical findings (F1 Scaffolding U-curve, F2 lessons-block halluc inflation +0.14 pp at 10.7x A/A noise floor, F3 cross-arch neuromod harm task-cluster localization, F4 cross-judge disagreement instantiating the question, F5 systematic LLM-vs-human judge bias map) plus one transferable technique (F6 few-shot exemplar + ship-rule unlocks OSS models for agent loops, PR #224 existence proof) are consolidated in docs/FINDINGS.md as of 2026-04-20. None have been externalized as preprint, blog post, or talk. The project's research-integrity discipline is top-decile in agent-framework space; the public-visibility path is empty. This mismatch is the single highest-leverage opportunity for the project's external positioning. Choose a venue and ship one publication-quality artifact. Candidates in priority order: (a) 2,000-word blog post centered on F1 U-curve + F6 technique (easiest, broadest reach), (b) ArXiv preprint covering F1 + F2 + F5 (formal, higher-authority, longer lead time), (c) HN-ready writeup + thread (fastest signal loop, lowest commitment). One venue this quarter, not all three at once.
  acceptance_criteria:
    - Venue selected with explicit rationale (which finding set, which audience, which tradeoff)
    - Draft reviewed against docs/RESEARCH_INTEGRITY.md standard — no overclaim, CIs present, honest-limits section included, n and kappa values preserved from source
    - Draft reviewed by one external reader (Gemini reviewer or other) for clarity before publication
    - "Publication goes live with a URL in docs/FINDINGS.md \"How to cite\" section"
    - docs/FINDINGS.md replication-invitation text updated to point external readers to the published artifact
  notes: |
    ~1-2 weeks for blog post option, ~4-6 weeks for preprint. No technical dependency; blocked only on writer bandwidth. Single highest-leverage single gap in the project right now per 2026-04-20 strategic review — closes the 'top-decile methodology, zero external visibility' gap. 2026-04-22 integrity fix: reopened from `status: done` because **zero** acceptance rows were satisfied (`closed_pr: TBD`, no live publication URL in FINDINGS, draft still pre-external-review). See docs/RED_LETTER.md Issue #4. Prior mistaken closure date 2026-04-20 exists only in git history.
  source_doc: docs/FINDINGS.md + 2026-04-20 gold-mining review

- id: PRODUCT-010
  domain: product
  title: Weekly product-commit floor — 1 commit/week to web/, REL-*, COMP-010, or first-run path
  status: done
  priority: P1
  effort: s
  description: |
    Red Letter Issues #2 and #3 both flagged: zero PR commits this week touched the PWA (web/), the first-run onboarding flow (PRODUCT-004), local model support (REL-001/REL-002), or the brew installer polish (COMP-010 followup). This is a recurring pattern — research velocity is outpacing product investment. The North Star (per CLAUDE.md / book/src/chump-to-complex.md) is a Discord bot that understands intent OR a PWA local-first agent — both are product-facing surfaces. Both are starved while the eval / methodology / coordination infrastructure absorbs all bandwidth. Fix: governance rule + ambient flag. (a) Add weekly product-commit floor: at least 1 PR per week must touch web/ or REL-* or COMP-010 or PRODUCT-* gap implementation. (b) Add product:flag to PR title or label so musher + Red Letter can count product PRs explicitly. (c) When a week ends with zero product commits, ambient flags it as ALERT kind=product_drought.
  acceptance_criteria:
    - scripts/check-product-floor.sh — scan last 7 days of merged PRs for product-touching commits (web/, REL-*, COMP-010 paths or PRODUCT-* gap IDs)
    - "If zero product commits in last 7 days: emit ALERT kind=product_drought to ambient.jsonl + add to next Red Letter input"
    - docs/AGENT_COORDINATION.md adds product-floor governance to the weekly-rhythm section
    - First non-zero product week resets the alert; staying at zero >2 weeks escalates to mandatory product gap claim before next eval gap
  notes: |
    P1 because this is the recurring Red Letter critique — addressing a recurring issue is more valuable than one-shot fixes. Forcing function for product-vs-research velocity balance.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-21'

- id: PRODUCT-011
  domain: product
  title: Competition analysis — survey Goose/Cursor/Cline/Aider/Claude Desktop/Open WebUI for PWA rebuild inspiration
  status: done
  priority: P1
  effort: s
  description: |
    Before rebuilding web/ we need a clear-eyed read on what local-first agent UIs already do well. Red Letter #1 flagged zero product velocity against the North Star for two consecutive cycles — the fleet is producing research and coordination infra, not shipping user-visible surfaces. Blocks PRODUCT-012 (PWA rebuild spike): we should not pick a framework or IA until we know what the category has already figured out. Scope: (1) hands-on 30-min tour of Goose (block.xyz), Cursor, Cline (VS Code extension), Aider, Claude Desktop/Projects, ChatGPT Desktop, Open WebUI, LibreChat, Ollama UI, Continue.dev; (2) write docs/PRODUCT-011-competition-scan.md — per tool: headline value prop, onboarding flow (first 60s), model-picker UX, tool-use visibility, agent-state surfacing, "where does Chump actually differentiate"; (3) a 1-page "PWA rebuild principles" appendix that PRODUCT-012 can hand to whatever framework/designer lane it chooses. Deliverable is docs-only; no code changes.
  acceptance_criteria:
    - docs/PRODUCT-011-competition-scan.md shipped with one section per listed tool
    - "Final section \"PWA rebuild principles — 5 bullets\" that PRODUCT-012 can consume"
    - No generated code; this unblocks product decisions
  notes: |
    Red Letter #1/#2/#3 all flagged zero product velocity. Must land before PRODUCT-012 rebuild spike to prevent another framework misfire.
  source_doc: docs/NORTH_STAR.md
  closed_date: '2026-04-21'

- id: PRODUCT-012
  domain: product
  title: PWA rebuild spike — framework choice + shell skeleton for web/
  status: done
  priority: P1
  effort: m
  description: |
    web/ currently ships as vanilla JS flat files (index.html, desktop-bridge.js, ootb-wizard.js, sse-event-parser.js, sw.js, ui-selftests.js). Last feature commit 9132265 (2026-04-04, COMP-005a-fe image-paste). Jeff's verdict: "it just needs rebuilt." Scope: (1) consume PRODUCT-011's "rebuild principles"; (2) pick a framework — recommendation: keep vanilla or use htmx/lit (preserves air-gap + zero-build story), avoid React/Vue/Svelte monoliths unless PRODUCT-011 strongly argues for one; (3) ship a new web/v2/ skeleton with just the app shell: header, chat pane, tool-call sidebar, model picker, status strip. No actual functionality — just the IA. Hook feature-flag CHUMP_PWA_V2=1 to serve v2 instead of flat files so we can A/B live. Preserve service worker + manifest.json (PWA install on mobile). Must run offline (air-gap North Star promise) and install as a PWA on iOS + Android.
  acceptance_criteria:
    - web/v2/ directory with app shell (no features beyond nav)
    - "Opens cleanly at http://localhost:<chump-port>/v2 with CHUMP_PWA_V2=1"
    - Passes air-gap test — throttle to offline, reload — shell still renders
    - Installable as PWA on iOS Safari + Android Chrome (manifest + SW work)
    - docs/PRODUCT-012-rebuild-decision.md records framework choice + reasoning tied back to PRODUCT-011
    - Old web/ flat files remain untouched — v2 is additive until feature-parity
  depends_on: [PRODUCT-011]
  notes: |
    Rebuild spike, not feature implementation. Follow-ups (chat pane wire-up, tool-call UI, etc.) file as PRODUCT-013..N.
  source_doc: web/index.html
  closed_date: '2026-04-21'

- id: PRODUCT-013
  domain: product
  title: PWA rebuild — first vertical slice — chat pane connected to live agent
  status: done
  priority: P1
  effort: m
  description: |
    After PRODUCT-012 ships the shell, the first real user-visible slice: a working chat pane that sends to the local Chump agent and streams the response back. This is the minimum thing a user can actually use after `brew install chump && chump serve` + opening the PWA. Scope: (1) wire web/v2 chat pane to existing SSE endpoint (chump already streams); (2) message list with role labels (user/assistant); (3) basic tool-call rendering (show which tool fired, not full output); (4) model picker reads from the local models registry; (5) graceful handling of "no model selected" and "agent offline" states with a one-tap link to docs/ONBOARDING.md. No message history persistence beyond session — future follow-up. No multi-session UI — future.
  acceptance_criteria:
    - web/v2 chat pane sends a message and streams the response back from the local agent
    - Tool-use events render inline (even if compact)
    - Model picker lists locally available models and lets the user switch
    - Empty-state copy points to onboarding when no model is configured
    - Works offline if a local model is already loaded (air-gap promise)
    - Manual test plan in docs/PRODUCT-013-test-plan.md
  depends_on: [PRODUCT-012]
  notes: |
    First user-visible ship against the North Star since COMP-005a-fe (2026-04-04). Keep tight — follow-ups (history, multi-session) file as separate gaps.
  source_doc: docs/NORTH_STAR.md
  closed_date: '2026-04-21'

- id: PRODUCT-014
  domain: product
  title: "Discord intent parsing — first visible slice of the \"understand and act\" promise"
  status: done
  priority: P2
  effort: m
  description: |
    CHUMP_PROJECT_BRIEF.md's original North Star was "understanding the user in Discord and acting on intent." Red Letter #1 noted zero commits against this path. MessagingAdapter trait already extracted (per existing gap), so the Discord side has foundations. Scope: (1) Discord adapter subscribes to messages in a configured channel; (2) parses intent (three verbs initially: summarize, search, remind); (3) replies with result or a one-tap action confirmation; (4) logs to ambient.jsonl so the PWA can show Discord-sourced activity; (5) no production deploy — ship as opt-in via CHUMP_DISCORD_ENABLED=1 and a user-supplied bot token in config. Frame as "one of several surfaces" — the PWA is primary, Discord is the asynchronous secondary surface.
  acceptance_criteria:
    - CHUMP_DISCORD_ENABLED=1 wires a running agent to a configured channel
    - Three intents (summarize, search, remind) dispatch correctly
    - Agent reply posts back to the same channel with response or confirmation
    - Activity streams into ambient.jsonl under kind=discord_intent
    - docs/PRODUCT-014-discord.md with setup guide + limitations
  notes: |
    P2 so PRODUCT-011/012/013/UX-001 ship first (PWA path is the primary North Star). This surface is secondary but closes the original brief.
  source_doc: docs/CHUMP_PROJECT_BRIEF.md
  closed_date: '2026-04-24'

- id: PRODUCT-015
  domain: product
  title: Activation funnel telemetry — install → first-task completion → day-2 return
  status: done
  priority: P0
  effort: m
  description: |
    CPO-framing gap, Tier 1 of the audit slate. Red Letter flagged zero product velocity for two cycles. Before paying a research/consciousness panel for credibility review, prove users activate and retain. Scope: (1) instrument three events into ambient.jsonl — kind=activation_install (first `chump init`), kind=activation_first_task (first non-empty task completion), kind=activation_return_d2 (any session > 24h after install); (2) `chump funnel` CLI subcommand reads ambient.jsonl and prints a three-row funnel (install → first-task → d2-return) with counts + percentages; (3) opt-in local-only anonymous aggregator (remote endpoint deferred); (4) docs/ACTIVATION.md explaining events, counts, privacy posture. This funnel is the activation metric the CPO gate keys off — it tells us whether research reviews are warranted yet.
  acceptance_criteria:
    - Three kind=activation_* events land in ambient.jsonl on install, first task, and d2 return
    - "`chump funnel` prints three-row funnel from ambient.jsonl"
    - docs/ACTIVATION.md explains events, counts, privacy posture (opt-in, anonymized)
    - Works on a clean machine with no prior Chump state
    - Gate defined — numeric activation threshold below which research reviews stay deferred
  notes: |
    Gate for Tier 2/3 audit work and the research-credibility panel in docs/EXPERT_REVIEW_PANEL.md. Activation threshold set by CPO once the funnel is live.
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-24'

- id: PRODUCT-016
  domain: product
  title: 3-minute demo video + scripted walkthrough against current main
  status: done
  priority: P0
  effort: s
  description: |
    CPO-framing gap, Tier 1. If you can't record a 3-minute end- to-end demo of Chump delivering user value, the product isn't shippable and research reviews are premature. Scope: (1) docs/DEMO_SCRIPT.md scripts the golden path (brew install → chump init → PWA opens → user issues a prompt → result visible); (2) record against current main as an unedited screen capture at docs/assets/demo-YYYY-MM-DD.mp4 (or unlisted YouTube link); (3) the recording must NOT be edited to hide failures — failures surface as new P0 regression gaps; (4) re-record monthly or on any UX-001 regression. The recording itself is the acceptance criterion — no recording, no P0 satisfaction.
  acceptance_criteria:
    - docs/DEMO_SCRIPT.md exists with scripted golden path
    - Recording exists, ≤ 3 minutes, against current main, unedited for failures
    - Script + recording match step-for-step
    - Any failure during recording files a P0 regression gap before this one ships
  depends_on: [PRODUCT-017]
  notes: Forcing function, not theater. Failed recording attempts are the signal.
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-24'
  closed_pr: 485

- id: PRODUCT-017
  domain: product
  title: UX-001 verification — stopwatch clean-machine install → PWA responsive today
  status: done
  priority: P0
  effort: s
  description: |
    CPO-framing gap, Tier 1. UX-001 is marked `status: done` 2026-04-21, promising `brew install chump → working PWA in < 60s`. Trust but verify. Scope: (1) run scripts/measure-ftue.sh on a clean Mac (fresh VM or wiped machine) today; (2) commit elapsed time + any failures to docs/FTUE-VERIFICATION-YYYY-MM-DD.md; (3) if > 60s or broken, file a P0 regression gap against UX-001 and this gap blocks PRODUCT-015/016 until resolved; (4) cadence — monthly clean-machine re-verification, CI already runs the stopwatch per UX-001 acceptance. Historical passes don't count; the gap closes only on a fresh run today.
  acceptance_criteria:
    - Clean-machine stopwatch run performed in the last 14 days
    - Result committed to docs/FTUE-VERIFICATION-YYYY-MM-DD.md
    - If failing, at least one regression gap filed and linked
    - Monthly re-run cadence declared
  notes: |
    UX-001 closed 2026-04-21 — re-verify before assuming the activation funnel measures a working path.
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-28'
  closed_pr: 631

- id: PRODUCT-018
  domain: product
  title: Competitive matrix + one-sentence wedge vs Cursor / Cline / Aider / Devin
  status: done
  priority: P1
  effort: s
  description: |
    CPO-framing gap, Tier 2. Before paying a GTM strategist, answer "why Chump, not Cursor" in one sentence from data, not vibes. Scope: (1) docs/COMPETITIVE_MATRIX.md with feature-diff rows for Chump + top 4 competitors (Cursor, Cline, Aider, Devin), columns for capabilities (local-first, multi-agent coordination, mobile/edge, consciousness/memory subsystem, OSS license, price tiers, install complexity); (2) pricing row from public sources with retrieval date; (3) one-sentence wedge at top — the single differentiator Chump owns that others don't; (4) quarterly update cadence. Absorbs Stage G of the prior audit slate.
  acceptance_criteria:
    - docs/COMPETITIVE_MATRIX.md exists with feature-diff for ≥ 5 products including Chump
    - Pricing retrieved from public sources with date-of-retrieval noted
    - One-sentence wedge stated at top of doc
    - Quarterly update cadence declared
  notes: Human GTM reviewer (if any) starts from this doc, not a blank page.
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-24'
  closed_pr: 481

- id: PRODUCT-019
  domain: product
  title: Monetization hypothesis — top 2 options with kill criteria
  status: done
  priority: P1
  effort: s
  description: |
    CPO-framing gap, Tier 2. Pick a commercial direction (or document why deferred) before funding research-credibility reviews. Scope: (1) enumerate options — OSS-core + enterprise support, usage-based hosted Pixel-mesh, hosted multi-agent coordination, commercial eval API, research licensing — and pick top 2; (2) per option — bet, smallest testable slice, kill criterion (what tells us this is wrong), rough unit- economics sketch; (3) docs/MONETIZATION_V0.md; (4) revisit per Red Letter cycle. Hypothesis doc, not business plan — bias to cheap tests. "Defer commercial decisions" is itself a pick and needs a kill criterion.
  acceptance_criteria:
    - docs/MONETIZATION_V0.md exists with top 2 options
    - Each option has bet / smallest testable slice / kill criterion / unit-economics sketch
    - Revisit cadence declared (per Red Letter cycle)
    - "Kill criterion stated for any \"defer\" option"
  depends_on: [PRODUCT-018]
  notes: Kill criterion matters more than the revenue projection.
  source_doc: docs/EXPERT_REVIEW_PANEL.md
  closed_date: '2026-04-24'
  closed_pr: 484

- id: PRODUCT-020
  domain: PRODUCT
  title: MCP marketplace MVP scope + design doc — concrete what-ships definition for North Star wedge
  status: open
  priority: P1
  effort: m
  description: |
    docs/strategy/NORTH_STAR.md line 43 names the "private MCP marketplace"
    as the product wedge - "every connector you could want, self-hosted,
    running on your hardware. GitHub. Slack. Calendar. Your database. No
    middleman, no SaaS subscription, no data leaving your machine unless
    you choose." PRODUCT-001..PRODUCT-019 cover PWA, profile, FTUE, intent,
    activation funnel, demo, install verification, competitive matrix, and
    monetization - none cover the marketplace itself. The marketplace is
    the thing that makes "PWA + agent" defensible vs commodity wrappers,
    and there is no gap defining what the MVP ships. File the design doc
    first (selected connector list, hosting model, install UX, security
    boundary). MVP build is a downstream gap once scope is locked.
  acceptance_criteria:
    - "docs/strategy/MCP_MARKETPLACE_MVP.md committed with: scoped connector list (≥5), hosting/sandbox model, install UX wireframe, threat model"
    - First 3 connectors named with rationale (which MCP servers ship with day-1 install)
    - Success metric for MVP defined - what does 'shipped' mean operationally
    - Downstream PRODUCT-* gap filed for actual implementation once scope locked
  opened_date: '2026-04-26'

- id: PRODUCT-021
  domain: PRODUCT
  title: PRODUCT-017 P0 non-compliance escalation — freeze new PRODUCT gap work until clean-machine verification completes
  status: done
  priority: P1
  effort: xs
  description: |
    PRODUCT-017 (P0 — stopwatch clean-machine install → PWA responsive
    today) has 1 commit across 3 Cold Water cycles (Issues #6, #7, #8):
    the filing commit d448c4e. PRODUCT-015 (src/activation.rs:171-194)
    is live emitting activation_install, activation_first_task, and
    activation_d2_return metrics on an unverified FTUE path. PRODUCT-020
    (MCP marketplace MVP design, P1) is designing the product's North
    Star experience on an unverified foundation.
    
    The project is expanding the product surface (PRODUCT-015, -020) and
    measuring user behavior (D2-return events) on a path that has not
    been tested against an actual clean machine. P0 gap policy means
    all other PRODUCT work is blocked. That policy is not being enforced.
    
    Cold Water Issue #8. Acceptance: this gap closes when PRODUCT-017
    closes (clean-machine artifact committed to
    docs/FTUE-VERIFICATION-YYYY-MM-DD.md), OR when an explicit CPO
    decision document records that PRODUCT-017 is intentionally deferred
    with a named date and owner.
  acceptance_criteria:
    - "PRODUCT-017 acceptance criterion met: clean-machine stopwatch run committed to docs/FTUE-VERIFICATION-YYYY-MM-DD.md"
    - "OR: explicit CPO decision document in docs/ records intentional deferral of PRODUCT-017 with named owner and target date"
    - PRODUCT-020 work does not advance past design-doc phase until one of the above is true
  opened_date: '2026-04-27'
  closed_date: '2026-05-02'
  closed_pr: 713

- id: PRODUCT-022
  domain: PRODUCT
  title: Replace static 'Behind the scenes' blurb with live orchestrator state
  status: done
  priority: P2
  effort: s
  description: |
    PWA's 'Behind the scenes' panel during a slow turn renders a static troubleshooting blurb (web/index.html:4578) — same text every time: 'No tools yet — the model is doing the heavy lifting' + paragraphs about /models check, MLX/Ollama, CHUMP_LIGHT_CONTEXT. Spinner flavor-text varies but body is identical regardless of orchestrator state. Implies live insight it doesn't have; becomes noise after first sighting. Replace with actual stage + elapsed timer (perception -> tool_routing -> llm_waiting -> streaming) and ideally live milestones (token count, first-token latency, tok/s) streamed via SSE. Orchestrator already logs all of this (chump::agent_loop::iteration_controller: 'calling LLM', etc.). Reported by Jeff 2026-04-28 while debugging a slow qwen3:14b turn — the static MLX-flavored copy was actively misleading because we were on Ollama.
  acceptance_criteria:
    - Behind the scenes panel reflects current orchestrator stage (perception/tool_routing/llm_waiting/streaming/tool_call), not a static blurb
    - Stage shows elapsed time since entry
    - Elapsed timer STOPS when the assistant response completes (currently keeps ticking)
    - Static troubleshooting copy in web/index.html removed or moved to an explicit Help/Diagnose link
    - At least one live metric streamed end-to-end (e.g. prompt token count or first-token latency)
    - Panel does not visually duplicate/repeat itself within a single turn
    - "Manual smoke: send a chat msg, observe stage transitions in PWA match log lines, observe timer freezes on completion"
  notes: |
    Caught while booting Chump on Ollama (env switch from MLX): blurb said 'MLX load' but we'd just switched to Ollama. Two-tier scope: (1) quick win — render orchestrator state names with a stage timer, hide static blurb, fix timer-doesn't-stop bug; (2) better — SSE live milestones (prompt assembled N tokens, first-token in Xs, decoding @ Y tok/s). Additional symptoms reported 2026-04-28: 'Thinking... NNNNNms' ticker keeps incrementing AFTER the assistant reply has rendered; panel may render duplicate copies within one turn.
  closed_date: '2026-04-29'
  closed_pr: 659

- id: PRODUCT-023
  domain: PRODUCT
  title: "Default chat model -> qwen2.5:7b (.env, run-web.sh, profile doc)"
  status: done
  priority: P2
  effort: s
  description: |
    Today proved 14B + cold-load + thinking-mode = bad interactive UX. Default chat model swaps to qwen2.5:7b (~4.7GB VRAM, 1-3s first token cold). 14B remains opt-in for heavy turns by setting OPENAI_MODEL=qwen2.5:14b in .env. Frees ~5GB for system headroom on 24GB Air (rust-analyzer + browser + chump can all coexist without swap thrash). Independent of the singleton/semaphore work — safe to land anytime.
  acceptance_criteria:
    - ".env: OPENAI_MODEL=qwen2.5:7b"
    - "run-web.sh:21 fallback default updated"
    - "run-web.sh:23-26 CHUMP_GOLDEN_PATH_OLLAMA block updated"
    - docs/operations/INFERENCE_PROFILES.md notes 7B as steady chat default; 14B as opt-in for heavy turns
    - "verification: curl http://127.0.0.1:11434/api/ps shows qwen2.5:7b resident at ~4.7GB after first turn"
  notes: |
    See ~/.claude/plans/local-first-is-the-eager-hopcroft.md (approved 2026-04-28). Part of the local-first redesign filed after today's three-way runner contention incident (ChumpMenu + chump --web + autopilot all queued on one Ollama runner). Sub-problem #5 of 6. Independent — can ship anytime. Both 7B and 14B already pulled in Ollama (verified 2026-04-28).
  closed_date: '2026-05-02'
  closed_pr: 713

- id: PRODUCT-024
  domain: PRODUCT
  title: PWA chat default to non-reasoning model (INFRA-183 sub) — biggest UX win
  status: done
  priority: P0
  effort: s
  description: |
    Switch chat default to non-reasoning model (qwen2.5:14b or llama3.1) instead of the reasoning model currently served on MLX :8000. Measured: 56.985 s for 'pong' = 4 chars, 1 user-visible delta, 114 keepalive pings, 0 visible reasoning. Ground-truth probe captured in INFRA-183 umbrella body. Single largest UX win for near-zero code.
  acceptance_criteria:
    - default model env in run-web.sh / .env switched to non-reasoning
    - measured pong-prompt turn under 5s
    - original reasoning model still selectable via override env
  depends_on: [INFRA-183]
  closed_date: '2026-05-01'
  closed_pr: 697

- id: QUALITY-001
  domain: reliability
  title: unwrap() audit — replace panics with graceful errors in production paths
  status: done
  priority: P2
  effort: l
  description: |
    Audit filed with "956 unwrap() calls" — this count was inflated by test code (raw grep included #[cfg(test)] blocks and tests/ directory). Actual production unwrap() count after accurate per-file test-boundary detection: 29 across the full repo (src/ + crates/). All 29 categorized: 15 are mutex lock().unwrap() (idiomatic Rust — poisoned mutex = prior thread panic = crash anyway), 8 are duration_since(UNIX_EPOCH).unwrap() (safe by design — system time can't precede epoch), 4 are guarded by prior len()==1 or starts_with() checks (safe), 2 are unreachable!() behind cfg compile-time guards. Only fix applied: 4 x duration_since().unwrap() → .unwrap_or_default() in git_tools.rs (2026-04-19). No production panic risk remains. All open_db() and conn.prepare() call sites return Result, not panic. cargo test passes. No new panics introduced.
  notes: |
    Effort is "l" because there are ~900 sites but most are in tests or genuinely safe (Vec::new().unwrap() type patterns). A realistic P2 pass focuses on the ~50 highest-blast-radius sites and gets the production-path count down to near-zero. The full audit can be incremental across multiple PRs.
  closed_date: '2026-04-19'

- id: QUALITY-002
  domain: reliability
  title: Eliminate top-100 unwrap() panics in production binary — replace with graceful errors
  status: done
  priority: P2
  effort: l
  description: |
    QUALITY-001 audited 1,065 unwrap() calls across src/ (up from 946 at Red Letter #1, 989 at #2, 1,065 at #3 — growing every week). The audit catalogued them; it did not fix them. This gap targets the highest-risk 100: any unwrap() in a path that handles user input, HTTP responses, file I/O, or DB operations in the main agent loop. Strategy: (1) run `rg '\.unwrap()' src/ --count-matches` to baseline, (2) prioritize by file (src/local_openai.rs, src/agent_loop/, src/tool_runner.rs first), (3) replace each with `?` propagation or explicit `expect("invariant: ...")` where truly impossible. Each replaced unwrap reduces production panic surface. Acceptance: net unwrap count in src/ drops by ≥ 100 from the 1,065 baseline; no regressions in `cargo test --workspace`.
  acceptance_criteria:
    - "rg \"\\.unwrap()\" src/ --count-matches shows ≤ 965 total (≥ 100 replaced)"
    - cargo test --workspace passes
    - cargo clippy --workspace -- -D warnings passes
    - No new unwrap() calls introduced in changed files
  source_doc: docs/RED_LETTER.md
  closed_date: '2026-04-20'

- id: QUALITY-003
  domain: reliability
  title: Audit which unwrap() calls are in production hot paths (triage before reduction)
  status: done
  priority: P1
  effort: s
  description: |
    QUALITY-002 (filed 2026-04-20) tackles unwrap() reduction. Without triage it is a sprint with no endgame - the Red Letter count jumped from 989 to 1065 after QUALITY-001 closed as "audited." Before removing N unwraps blindly, categorize the 1065 by production-path risk: (A) production hot path - src/main.rs entry, src/agent_loop/*, src/dispatch.rs, src/provider_cascade.rs; (B) production cold path - infra code only hit at startup; (C) tests / build scripts / dev tools. Panics in (A) crash unattended sessions; panics in (C) fail at CI time which is fine. The 1065 number is meaningless without this split. Output: docs/QUALITY-003-unwrap-triage.md with a per-file-per- category count and the top 20 highest-risk files ranked by (A) density. QUALITY-002 reduction work should start with those 20, not the rest.
  acceptance_criteria:
    - docs/QUALITY-003-unwrap-triage.md written with the A/B/C split
    - Top 20 highest-A-density files enumerated with unwrap counts
    - QUALITY-002 gap description updated to reference this triage as its starting point (scope narrowing to top-20 is fine — rest can be follow-up)
  depends_on: [QUALITY-002]
  notes: |
    ~2 hours of grep + analysis. Turns blocker #5 from a vague "1065 unwraps" into a concrete "20 files to fix for production stability." Enables QUALITY-002 to scope to an actually-completable chunk rather than running forever. Chunking function for the blocker.
  source_doc: 2026-04-20 strategic review blocker
  closed_date: '2026-04-20'

- id: QUALITY-004
  domain: quality
  title: Module removal decision — Memory, Executive Function, Metacognition
  status: done
  priority: P1
  effort: s
  description: |
    Memory, Executive Function, Metacognition modules all show NULL results (VALIDATED(NULL)). Unclear if dead code or under-tested. Review AGENTS.md + agent source (src/agents/) for each module. Check: is code actually used? any fallback paths? any tests? List call sites in production agent loop. Estimate removal cost + benefit. Decision: remove | re-measure with better instrument | keep as-is.
  acceptance_criteria:
    - Reviewed each module's source code and call sites
    - Documented evidence (used vs unused, test coverage)
    - Estimated removal effort (S/M/L)
    - Decision recommendation with rationale
  notes: |
    Clarifies Q2 scope: adds 2–3 weeks if removals needed, or pivots to better instrument.
  source_doc: docs/EVALUATION_PLAN_2026Q2.md
  closed_date: '2026-04-25'

- id: QUALITY-005
  domain: quality
  title: Gap hygiene & estimation audit
  status: done
  priority: P1
  effort: m
  description: |
    Effort estimates (S/M/L/XL) may not match reality. Acceptance criteria may be vague or unmeasurable. Dependencies not fully mapped. Sample 20 open gaps (random, across domains). For each: is effort realistic (compare to PR size, actual time taken)? Are acceptance criteria measurable (binary yes/no)? Are dependencies complete? Is title + description clear for another agent to pick up?
  acceptance_criteria:
    - Audited 20 random gaps
    - Effort estimates validated against historical PRs
    - Criteria clarity graded (poor/fair/good/excellent)
    - Dependency gaps documented
    - Summary report with patterns and recommendations
    - Rewritten gaps committed (if clarity issues found)
  notes: Improves Q2/Q3 planning accuracy. Results feed into gap registry refresh.
  source_doc: docs/EVALUATION_PLAN_2026Q2.md
  closed_date: '2026-04-25'

- id: REL-001
  domain: reliability
  title: Model quality matrix — one local model reliably completes T1.1 end-to-end
  status: done
  priority: P0
  effort: m
  description: |
    T1.1 dogfood (read → patch → respond) has no single local model that reliably completes end-to-end with a minimal unified diff (not write_file fallback). qwen2.5:7b passes "no crash" bar only. qwen2.5:14b has RAM eviction under load. qwen3:8b blocked by Ollama upstream instability.
  notes: Partially blocked on REL-002 (upstream Ollama).
  source_doc: docs/DOGFOOD_RELIABILITY_GAPS.md
  closed_date: '2026-04-16'

- id: REL-002
  domain: reliability
  title: Ollama upstream stability on 24GB M4 (upstream blocker)
  status: blocked
  priority: P0
  effort: xs
  description: |
    Ollama 0.20.7 segfaults under dogfood load on 24GB M4. Server responds 500 after ~13s and restarts. Triggered by concurrent cargo builds + inference competing for unified memory. Not fixable from Chump (upstream bug); tracked here for visibility + workaround documentation.
  notes: |
    Workarounds:
      1. CHUMP_BRAIN_AUTOLOAD= (empty) — avoids the autoload pile-up.
      2. Avoid concurrent cargo builds while inference is hot.
      3. Use qwen2.5:7b instead of 14b — fits comfortably under 24 GB.
      4. scripts/ollama-watchdog.sh (NEW, since this gap was filed) —
         detects the crash signature (process gone / API timeout / log
         panic) within DETECT_WINDOW_SEC and auto-restarts. Run as a
         daemon: `scripts/ollama-watchdog.sh --loop` in a tmux pane,
         or wire into a launchd plist for unattended sessions.
      5. Monitor Ollama release notes; flip this gap to done when an
         upstream version reports the segfault fixed under sustained
         load.
  source_doc: docs/DOGFOOD_RELIABILITY_GAPS.md

- id: REL-003
  domain: reliability
  title: Patch crate — fork or replace if upstream abandons panic-on-malformed
  status: done
  priority: P2
  effort: s
  description: |
    patch-0.7.0 panics on malformed input (caught via catch_unwind + spawn_blocking). If the crate is abandoned, options are: fork to return Err, or replace with diffy (different license + behavior). Track upstream maintenance.
  source_doc: docs/DOGFOOD_RELIABILITY_GAPS.md
  closed_date: '2026-04-17'

- id: REL-004
  domain: reliability
  title: Prompt-token estimation accuracy — real tokenizer or better heuristic
  status: done
  priority: P3
  effort: s
  description: |
    warn_if_near_num_ctx uses bytes/3.5 heuristic (±30% on code-heavy prompts). Systematic false warnings would erode trust in the warning. Consider tiktoken or Qwen tokenizer for accurate counts.
  notes: |
    Content-type-aware heuristic in estimate_tokens_for_str: prose=4 chars/token, code/JSON=2.5 chars/token (detected by code-symbol density >12%), non-ASCII=1 token/byte, +4 tokens per-message overhead. No new deps.
  source_doc: docs/DOGFOOD_RELIABILITY_GAPS.md
  closed_date: '2026-04-17'

- id: REMOVAL-001
  domain: reliability
  title: Audit + decision-matrix for the 5 NULL-validated cognitive modules — re-test or remove
  status: done
  priority: P1
  effort: m
  description: |
    EVAL-048 explicit decision criterion: Module delta within +/-0.05 (CIs overlap) means NEUTRAL — document no-detectable-signal, candidate for removal to simplify codebase. Five modules currently fall under this rule per EVAL-063 + EVAL-064 + EVAL-069 aggregates: surprisal_ema (src/surprise_tracker.rs), belief_state (crates/chump-belief-state/), neuromodulation (src/neuromodulation.rs), spawn-time lesson loading (src/reflection_db.rs::load_spawn_lessons), blackboard (src/blackboard.rs). All run in production every session, consume CPU + memory, inject prompt content; none show measurable effect at current n. Per Red Letter Issue #3 ONE BIG THING: project must choose either (a) file removal gaps and cut the dead code, or (b) ship a proper instrument that resolves haiku-tier-specific harm before declaring NULL. EVAL-076 (haiku-4-5 targeted re-run) addresses (b) for one cell; this gap forces the broader decision matrix.
  acceptance_criteria:
    - "docs/eval/REMOVAL-001-decision-matrix.md per-module table: current verdict, EVAL-076 result if available, decision (re-test more / keep with caveat / file removal sub-gap)"
    - "For any module marked remove: file REMOVAL-002+ sub-gap with concrete file/function/env-flag cut list"
    - "For any module marked keep with caveat: docs/CHUMP_FACULTY_MAP.md updated with explicit caveat (not just NULL label)"
    - docs/eval/EVAL-048-ablation-results.md decision rule re-cited in the matrix doc
  depends_on: [EVAL-076]
  notes: |
    Filed in response to Red Letter #3 ONE BIG THING. ~1-2 days analysis + decision; removals themselves filed as sub-gaps.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-21'

- id: REMOVAL-002
  domain: reliability
  title: Remove surprisal_ema module — delta=0.000, no positive signal
  status: done
  priority: P2
  effort: l
  description: |
    REMOVAL-001 decision matrix verdict: REMOVE. surprisal_ema (src/surprise_tracker.rs) shows delta=+0.000 in EVAL-063 (n=50/cell, LLM judge, Llama-70B). No historical positive signal, no model-tier concern. Cut list: src/surprise_tracker.rs, CHUMP_BYPASS_SURPRISAL env flag in src/env_flags.rs, wiring in src/agent_loop/prompt_assembler.rs, any test referencing surprisal_ema. Update docs/CHUMP_FACULTY_MAP.md Metacognition row to remove surprisal_ema reference.
  acceptance_criteria:
    - src/surprise_tracker.rs deleted
    - CHUMP_BYPASS_SURPRISAL removed from src/env_flags.rs and all callers
    - "Production callers migrated off surprisal_ema: src/precision_controller.rs (regime decisions), src/tool_middleware.rs (surprisal_ok gate), src/phi_proxy.rs (blackboard Module::SurpriseTracker), src/agent_loop/tool_runner.rs (record_prediction), src/blackboard.rs (Module enum variant), src/checkpoint_db.rs (surprisal_ema snapshot field), src/e2e_bot_tests.rs (12+ test refs)"
    - cargo check --bin chump --tests passes
    - docs/CHUMP_FACULTY_MAP.md Metacognition row updated
  depends_on: [REMOVAL-001]
  notes: |
    Filed by REMOVAL-001 decision matrix 2026-04-21. Scope: 18 files, 866 lines deleted. Shipped PR via bot-merge.sh 2026-04-21.
  source_doc: docs/eval/REMOVAL-001-decision-matrix.md
  closed_date: '2026-04-21'

- id: REMOVAL-003
  domain: reliability
  title: Remove belief_state module — delta=+0.020, no positive signal, crate complexity
  status: done
  priority: P2
  effort: l
  description: |
    REMOVAL-001 decision matrix verdict: REMOVE. belief_state shows delta=+0.020 in EVAL-063 (n=50/cell, LLM judge, Llama-70B). No positive signal. Cut list (verified 2026-04-21): crates/chump-belief-state/ (full crate), workspace member + dep entries in root Cargo.toml, CHUMP_BYPASS_BELIEF_STATE-style wiring, AND 21 in-tree callers across src/tool_middleware.rs, src/surprise_tracker.rs, src/autonomy_loop.rs, src/speculative_execution.rs, src/checkpoint_db.rs, src/health_server.rs — belief_state is load-bearing for checkpoint/restore, tool-scoring, and health telemetry. Removal must stub or rewire each caller; cannot be a simple crate delete. Update docs/CHUMP_FACULTY_MAP.md Metacognition row to remove belief_state reference.
  acceptance_criteria:
    - All 21 in-tree callers (tool_middleware, surprise_tracker, autonomy_loop, speculative_execution, checkpoint_db, health_server) rewired or stubbed before crate delete
    - crates/chump-belief-state/ deleted, root Cargo.toml workspace member + dep removed
    - checkpoint/restore round-trip test passes without belief_state fields (or fields preserved as no-ops for backward-compatibility)
    - cargo check --bin chump --tests passes; cargo test -p chump passes
    - docs/CHUMP_FACULTY_MAP.md Metacognition row updated
  depends_on: [REMOVAL-001]
  notes: |
    Scope-correction 2026-04-21: effort upgraded s→m→l after audit showed 21 callers across 6 src files, not the simple crate delete the decision-matrix assumed. belief_state is load-bearing for checkpoint/restore snapshot schema, tool-scoring in tool_middleware, and /health telemetry. Any removal PR that does not rewire all 21 callsites first will fail cargo check. Suggest decomposing into sub-gaps: (a) shim each caller to no-op, (b) delete crate after shim lands, (c) clean up checkpoint schema in a follow-up with a migration note.
  source_doc: docs/eval/REMOVAL-001-decision-matrix.md
  closed_date: '2026-04-24'

- id: REMOVAL-004
  domain: eval
  title: Haiku-specific neuromod bypass retest — resolve F1 U-curve concern under EVAL-060
  status: open
  priority: P3
  effort: s
  description: |
    REMOVAL-001 decision: KEEP neuromodulation with caveat + file this retest gap. EVAL-063 (Llama-70B) and EVAL-069 (qwen14B) both show NULL for neuromod bypass. But the F1 Scaffolding U-curve predicts mid-tier models (including claude-haiku-4-5) may be harmed. EVAL-076 confirmed lessons harm on haiku but tested the lessons block, not CHUMP_BYPASS_NEUROMD directly. This gap: run n=50/cell CHUMP_BYPASS_NEUROMD A/B on claude-haiku-4-5 under EVAL-060 LLM-judge instrument with cross-family judges. If H1 (haiku neuromod harm): file REMOVAL-005 to remove neuromod. If NULL: update CHUMP_FACULTY_MAP.md to reflect cleared concern.
  acceptance_criteria:
    - Run n=50/cell CHUMP_BYPASS_NEUROMOD A/B on claude-haiku-4-5 via run-binary-ablation.py or run-cloud-v2.py
    - Cross-family judges (Sonnet + Llama-70B or equivalent)
    - Per-cell acc + Wilson 95% CI + delta reported
    - "If harm confirmed: file REMOVAL-005; if NULL: CHUMP_FACULTY_MAP.md Metacognition row caveat cleared"
  depends_on: [REMOVAL-001, EVAL-076]
  notes: |
    Filed by REMOVAL-001 decision matrix 2026-04-21. Low priority because EVAL-063/069 are both NULL; only F1 U-curve concern motivates retest.
  source_doc: docs/eval/REMOVAL-001-decision-matrix.md

- id: REMOVAL-005
  domain: reliability
  title: Mechanical sweep of belief_state callsites — drop ~47 inert calls
  status: open
  priority: P3
  effort: s
  description: |
    REMOVAL-003 (PR #465) deleted the chump-belief-state crate (666 LOC) and replaced src/belief_state.rs with an inert stub that preserves the public call surface as no-ops, so the diff stayed small and revertible. ~47 callsites still reference the stub (tool_middleware, speculative_execution, routes/health, precision_controller, neuromodulation, main, health_server, consciousness_traits, checkpoint_db). Their behavior is dead — every write is a silent no-op and every read returns inert defaults. This gap is the mechanical follow-up: remove the calls, drop the stub, regenerate AutonomySnapshot serialization to no longer require ToolBelief/TaskBelief shadow structs. Pure cleanup, no behavior change.
  acceptance_criteria:
    - All callsites referencing belief_state APIs removed
    - src/belief_state.rs deleted
    - AutonomySnapshot deserialization keeps backward-compat for old on-disk checkpoints
    - cargo check / clippy / tests green
  depends_on: [REMOVAL-003]
  notes: |
    Filed by QUALITY-004 (2026-04-25). REMOVAL-001 §Metacognition deferred this as "follow-up gap (TBD)". Estimated S effort because the stub is already inert — this is a delete-plus-fix-imports sweep.
  source_doc: docs/eval/QUALITY-004-module-decisions.md

- id: REMOVAL-006
  domain: REMOVAL
  title: Audit src/neuromodulation.rs - 21KB module computes provider-call adjustments that are never applied
  status: open
  priority: P1
  effort: m
  description: |
    Tour audit on 2026-04-26 (post-INFRA-084 ship) confirmed that
    src/neuromodulation.rs (21KB, 600+ LOC) computes per-turn token-budget,
    temperature, and top_p adjustments based on conversation state
    (complexity, tool density, repeat-failure cadence) - and the resulting
    values are never threaded into the actual provider call. The LLM never
    receives the adjusted parameters. This means EVAL-029, EVAL-030, and
    every neuromod-tagged ablation result has been measuring a no-op.
    REMOVAL-004 (haiku bypass retest) and REMOVAL-005 (belief_state inert
    callsite sweep) treat the symptoms; this gap is the parallel decision
    point for neuromod itself - either wire the adjustments through
    crates/agent_loop provider invocation behind a runtime flag (with an
    EVAL-043 ablation arm to actually measure delta) OR remove the module
    and update all docs/research claims that reference it.
  acceptance_criteria:
    - Trace neuromod-computed values through agent_loop and confirm they reach (or do not reach) the provider call
    - Decide - wire-in (with feature flag plus EVAL-043 ablation arm) or remove
    - If wire-in - end-to-end test asserts provider request body contains adjusted temperature/top_p
    - If remove - update CHUMP_RESEARCH_BRIEF.md, CHUMP_FACULTY_MAP.md, README to reflect removal
    - Decision recorded in commit body and reflected in docs/RESEARCH_INTEGRITY.md prohibited-claims table
  opened_date: '2026-04-26'

- id: REMOVAL-007
  domain: REMOVAL
  title: Audit src/phi_proxy.rs and src/holographic_workspace.rs - sized like real features, never called from request path
  status: open
  priority: P2
  effort: m
  description: |
    Tour audit on 2026-04-26 found two cognitive-architecture modules that
    appear in the binary but are never invoked from agent_loop or any tool
    dispatch path: src/phi_proxy.rs (252 LOC) and src/holographic_workspace.rs
    (314 LOC). Both are listed in README "nine engineering proxies" framing
    and CHUMP_FACULTY_MAP.md, but neither has a wire-up confirmed by trace.
    Either confirm they are dead code and remove (per the REMOVAL-002
    surprisal_ema precedent), confirm they ARE called and add a coverage
    test that proves it, or document as "research scaffolding, not in
    request path" with a runtime flag and a follow-up gap for measurement.
  acceptance_criteria:
    - Trace each module - is it called from any path that runs during a normal chat turn?
    - Decide per-module - dead-code remove, wire+test, or document as research-scaffold
    - Update README and CHUMP_FACULTY_MAP.md to reflect outcome
    - Pair with DOC-010 (nine-proxies reframe)
  opened_date: '2026-04-26'

- id: RESEARCH-001
  domain: research
  title: Public research narrative — '2000+ A/B trials' blog post / paper
  status: done
  priority: P1
  effort: m
  description: |
    The EVAL-023 → EVAL-025 → EVAL-026 → EVAL-026b → EVAL-027b experimental trilogy has produced multiple novel findings that no other published source has. Headline findings worth a public writeup: (1) lessons-block hallucination harm scales monotonically UP with Anthropic model capability (haiku-3 0% → haiku-4-5 12% → sonnet-4-5 18% → opus-4-5 40%); (2) the harm is Anthropic- pretrain-specific (Qwen 7B/235B + Llama 70B all show 0% across 300 trials); (3) the COG-016 anti-hallucination directive eliminates the harm at haiku-4-5 (validated EVAL-025); (4) cross-architecture neuromod-fixture harm signal of -0.10 to -0.16 across 4 independent models (1200 trials). These findings contradict the industry default of "use the biggest model" for some failure modes — publishable as a blog post on Chump's site or arxiv preprint.
  depends_on: [EVAL-027b, EVAL-029]
  notes: |
    ~1 week effort: outline, draft, charts, peer review by Jeff + external reviewer, edit, publish. Highest-leverage Chump positioning artifact we can produce in 2026-Q2. Differentiates Chump from goose/Aider/Claude Code which have shipped no comparable published findings on their own architectures.
  source_doc: docs/CONSCIOUSNESS_AB_RESULTS.md
  closed_date: '2026-04-19'

- id: RESEARCH-002
  domain: research
  title: Docs thesis reframe — align all docs to tier-dependent injection finding
  status: done
  priority: P1
  effort: m
  description: |
    Multiple docs contain research claims that conflict with docs/RESEARCH_INTEGRITY.md (the accurate thesis). These must be updated before any external publication or new contributor reads them. Files requiring updates:
      - docs/CHUMP_RESEARCH_BRIEF.md: "Surprisal EMA Confirmed" → "Unablated"
      - docs/CHUMP_PROJECT_BRIEF.md: "cognitive architecture validated
        across 4 faculties" → narrow to lessons-block finding
      - docs/CHUMP_FACULTY_MAP.md: add ablation-pending status per faculty
      - docs/CONSCIOUSNESS_AB_RESULTS.md: add standing judge-bias caveat
        at top of file; mark all Anthropic-only deltas as "pending
        cross-family judge validation (EVAL-042)"
      - Any doc citing "2000+ A/B trials validate Chump" — add context
        that this validates the lessons block, not the full architecture
  notes: |
    ~1 day. No code changes. Prevents new contributors and agents from propagating inaccurate claims. Pairs with EVAL-042 — once cross- family judge results land, update these docs again with confirmed or revised deltas.
  source_doc: docs/RESEARCH_INTEGRITY.md
  closed_date: '2026-04-20'

- id: RESEARCH-003
  domain: research
  title: Align public-facing docs with narrow tier-dependent-injection thesis (README, preprint, dissertation)
  status: done
  priority: P1
  effort: s
  description: |
    RESEARCH-002 (PR #175) aligned four internal research docs to the accurate thesis (CHUMP_FACULTY_MAP, CHUMP_PROJECT_BRIEF, CHUMP_RESEARCH_BRIEF, CONSCIOUSNESS_AB_RESULTS) but did not touch the three externally-facing surfaces readers actually see: README.md, docs/research/consciousness-framework-paper.md, and book/src/dissertation.md. These still framed Chump as a validated "nine-subsystem cognitive architecture," which RESEARCH_INTEGRITY.md's prohibited-claims table explicitly forbids until EVAL-043 results ship (infra done PR #210, sweeps pending). This gap landed the reframes: README lead bullet + research-findings preamble now state the narrow tier-dependent-injection finding and explicitly mark individual-module contributions as unablated; the consciousness-framework-paper abstract + §1.2 "what we do not claim" were rewritten so the paper's load-bearing result is the tier-dependent finding, not the nine-module whole; the dissertation Preface gained a research-integrity caveat pointing readers at the accurate thesis. Descriptive passages that reference "nine modules" as implementation structure were preserved — the correction is about claims of validation, not about describing the code.
  acceptance_criteria:
    - README.md Cognitive-architecture bullet reframed to narrow thesis with EVAL-043 pending note
    - README.md Research-findings preamble states nine-module architecture is not validated as a whole
    - consciousness-framework-paper.md abstract reframed to tier-dependent finding as load-bearing result
    - consciousness-framework-paper.md §1.2 explicitly disclaims validation of the architecture as a whole
    - consciousness-framework-paper.md carries a research-integrity caveat block under the Status line
    - book/src/dissertation.md Preface carries a research-integrity caveat pointing at RESEARCH_INTEGRITY.md
    - "No unqualified \"cognitive architecture validated\" claims remain in the three public-facing docs"
  depends_on: [RESEARCH-002]
  notes: |
    Follow-on to RESEARCH-002. Does not alter descriptive implementation detail (e.g. the feedback-loop diagram in the dissertation); the reframe is targeted at validation claims only. Once EVAL-043 results land, these docs should be revisited to either tighten or relax the caveats based on the ablation outcomes.
  source_doc: docs/RESEARCH_INTEGRITY.md + RESEARCH-002 scope gap
  closed_date: '2026-04-20'

- id: RESEARCH-018
  domain: research
  title: Length-matched scaffolding-as-noise control — rule out prompt-length confound in every lessons A/B
  status: done
  priority: P0
  effort: m
  description: |
    Every published lessons-block A/B compares "lessons block" vs "no lessons block" with no length-matched control. The lessons block adds ~2,000 characters of structured text to the system prompt. If a 2,000-character control of length-matched random prose produces a delta of similar magnitude, the effect is prompt-length not lessons-content — which would reframe the entire tier-dependent finding. This gap ships a third cell in every future lessons A/B (A = lessons on, B = lessons off, C = length-matched null-content prose) and re-runs the core tier-dependent finding at n=100 on haiku-4-5 and sonnet-4-5 to establish whether the content or the ceremony drives the effect. Acceptance: publish a verdict in docs/FINDINGS.md distinguishing the two alternative explanations. Paper-1 blocker.
  acceptance_criteria:
    - Harness gains a --null-prose-match flag that generates a length-matched placebo at the same char count as the live lessons block
    - Cell C run at n=100 on haiku-4-5 and n=100 on sonnet-4-5 alongside A and B cells
    - "docs/FINDINGS.md gains a \"length-matched control\" row per tier with Cell A, B, C deltas and verdict"
    - "If Cell C delta ≥ 50% of Cell A delta, the tier-dependent finding is reframed from \"lessons content helps/harms\" to \"prompt ceremony length helps/harms\""
    - Preregistered per RESEARCH-019 before first live trial
  depends_on: [RESEARCH-019]
  notes: |
    Paper-1 prerequisite. Low compute (~$3 cloud) and ~3 days of harness work. This is the single most important missing control in the current methodology. Operational split: Lane A (harness + smoke + result-doc shell) vs Lane B (preregistered n=100 sweeps) — docs/RESEARCH_EXECUTION_LANES.md §3. Result template: docs/eval/RESEARCH-018-length-matched.md.
  closed_date: '2026-04-22'

- id: RESEARCH-019
  domain: research
  title: Pre-registration protocol for all future eval gaps — docs/eval/preregistered/ infrastructure + pre-commit guard
  status: done
  priority: P0
  effort: s
  description: |
    Every existing EVAL-NNN gap records what the data showed, not what hypothesis was locked before the data was collected. This is fixable going forward via a preregistration protocol. Establish docs/eval/preregistered/ as the canonical location for one-page markdown preregistrations. Each new EVAL-* or RESEARCH-* gap that involves live data collection must land a preregistration file in that directory before its first live trial. Add a pre-commit guard that rejects any commit flipping a new EVAL-* or RESEARCH-* gap to status: done unless a corresponding docs/eval/preregistered/<gap-id>.md exists and was committed before the first trial JSONL in logs/ab/. Bypass: CHUMP_PREREG_CHECK=0 with explicit justification in the commit message. Low friction (~1 hour per gap); large credibility premium for publication.
  acceptance_criteria:
    - docs/eval/preregistered/ directory created with a TEMPLATE.md and a README.md describing the required fields
    - TEMPLATE.md fields include — hypothesis, primary metric, stopping rule, expected effect size, analysis plan, exclusions, deviations (filled after data collection)
    - "scripts/git-hooks/pre-commit extended with a preregistration check that fires on new EVAL-*/RESEARCH-* status:done commits"
    - "CLAUDE.md pre-commit guards table gains a \"preregistration required\" row"
    - Test fixture in scripts/test-preregistration-guard.sh mirroring the INFRA-015 pattern
  notes: |
    Single highest-leverage methodology infrastructure change in the critique. Every other RESEARCH-* gap depends on it. Ship first.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §3
  closed_date: '2026-04-21'

- id: RESEARCH-020
  domain: research
  title: Ecological fixture set — 100 real-world tasks scraped from open-source GitHub issues and PRs
  status: open
  priority: P2
  effort: l
  description: |
    Every current Chump fixture was hand-authored by the same person who designed the cognitive modules. Classic Goodhart risk. This gap ships an ecological fixture set — 100 tasks scraped from real open-source repositories (issues, PRs, code review threads) and converted to Chump fixture JSON format. Re-run the top-3 current findings (tier-dependent injection, hallucination channel, scaffolding U-curve) on the ecological fixtures. Report delta between synthetic-author-graded results and ecological-blind- scored results. Either outcome is publishable (Paper 2). The concern is that author-graded fixtures may inflate all published deltas; this gap rules that in or out.
  acceptance_criteria:
    - 100-task ecological fixture set published at scripts/ab-harness/fixtures/ecological_v1.json
    - Tasks sourced from ≥5 different open-source repositories spanning ≥3 domains (systems, web, ML tooling)
    - Top-3 findings re-run at n=50/cell on the ecological fixture set
    - "Docs/FINDINGS.md gains an \"ecological replication\" table with per-finding deltas"
    - If any delta shrinks by >50% going from synthetic to ecological, flag it explicitly in FINDINGS.md as an author-graded-fixture limitation
    - Preregistered per RESEARCH-019 before re-running
  depends_on: [RESEARCH-019]
  notes: |
    Paper-2 foundation. Largest single-gap effort in the program (~2 weeks for fixture curation). Can partially overlap with Paper-1 work since the ecological fixtures are independent of the length-matched control.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §2

- id: RESEARCH-021
  domain: research
  title: Tier-dependence replication across 4 model families — extend haiku/sonnet finding to Llama/Qwen/DeepSeek/Gemma
  status: open
  priority: P1
  effort: m
  description: |
    Current tier-dependent injection finding is measured on haiku-4-5 vs sonnet-4-5 (same Anthropic family, same training lineage, size difference only). This gap extends to 4 model families — Anthropic (haiku/sonnet), Meta (Llama-3.3-8B/70B), Alibaba (Qwen-2.5-7B/72B), DeepSeek (V3-small / V3-big), Google (Gemma-3-9B/27B). n=100/cell per model-size tier. Goal: distinguish "a tier-dependent effect in the Anthropic family" from "a field-wide tier-dependent effect." The latter is a much stronger publishable claim. EVAL-071 partially addresses this for the hallucination channel only; this gap covers the core tier-dependent finding across the full small/large matrix per family.
  acceptance_criteria:
    - n=100/cell × 2 sizes × 4 families × 2 cells (lessons on / off) = 1600 trials total
    - Cross-family LLM-judge panel (at minimum one judge from each family being tested) — no single-family judge monoculture
    - Per-family tier-dependent delta reported with Wilson 95% CIs in docs/FINDINGS.md
    - "If the effect replicates in ≥3 of 4 families, publish as \"field-wide tier-dependent injection backfire\""
    - "If it replicates in only Anthropic, reframe paper as \"an Anthropic-family-specific finding\" with explicit scope caveat"
    - Preregistered per RESEARCH-019
  depends_on: [RESEARCH-019]
  notes: |
    Paper-1 blocker. Budget ~$80 cloud (Together free-tier handles Llama/Qwen/DeepSeek; Gemma via Google AI Studio). The publishable framing of the entire tier-dependent finding hinges on whether it generalizes beyond Anthropic. Do not attempt full 1600-trial AC on a thin credit month — phase per docs/RESEARCH_EXECUTION_LANES.md §4 + COST_OPTIMIZATION.md; prereg deviations required for n/model changes.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §4

- id: RESEARCH-022
  domain: research
  title: Module-use reference analysis — does the agent actually read the scaffolding it is given?
  status: done
  priority: P1
  effort: s
  description: |
    A "cognitive architecture" claim rests on whether the agent uses the architecture. We currently measure outputs (did the task succeed, did it hallucinate) but never measure whether the agent references the injected module state in any observable way. If belief_state provides "my_ability: 0.9" and the agent never mentions or conditions on that value across 100 trials, the module is dead weight even when output deltas exist. This gap ships a post-hoc text-analysis pipeline that scans agent outputs for references to injected module state, broken out by task type. Report reference-rate × task-type × outcome table in FINDINGS.md. Mechanism evidence — not a replacement for outcome-based ablation, but a necessary complement for any architecture claim.
  acceptance_criteria:
    - scripts/ab-harness/analyze-module-references.py scans JSONL files for textual references to injected belief_state/neuromod/lessons
    - Reference-rate × task-type × outcome table published for the current tier-dependent finding at n=100 per cell
    - "docs/FINDINGS.md gains a \"mechanism evidence\" subsection per finding with reference-rate data"
    - If any module's reference rate is <5% across all tasks, flag it as mechanistically unsupported regardless of outcome delta
  notes: |
    Paper-3 prerequisite (belief_state mechanism evidence). Purely post-hoc; re-analyzes existing JSONLs; no new trials. Fast win.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §5
  closed_date: '2026-04-20'

- id: RESEARCH-023
  domain: research
  title: Counterfactual mediation analysis — upgrade module-contribution claims from average-treatment to natural-direct-effect
  status: done
  priority: P1
  effort: m
  description: |
    Current "module contribution" analysis is P(pass | module=on) minus P(pass | module=off), measured aggregate. For a causal claim, the stronger quantity is the counterfactual mediation estimate — for matched trials differing only in module value, what is the expected outcome difference? Pearl's mediation framework applies directly. The A/B harness already produces matched pairs; what's missing is the analysis pipeline. Ships scripts/ab-harness/mediation-analysis.py implementing natural direct effect (NDE) and natural indirect effect (NIE) estimates per module × task-class. Upgrades every future module-contribution claim from "average treatment effect" to causal framing.
  acceptance_criteria:
    - scripts/ab-harness/mediation-analysis.py computes NDE and NIE with bootstrap 95% CIs
    - Applied to existing tier-dependent A/B data (n=100); results land in docs/FINDINGS.md
    - Per-module NDE reported in CHUMP_FACULTY_MAP.md alongside the existing aggregate delta
    - Analysis method references cited — Pearl 2001 Direct and Indirect Effects, VanderWeele 2015 Explanation in Causal Inference
    - Preregistered per RESEARCH-019 if applied to new data collection
  depends_on: [RESEARCH-019]
  notes: |
    Upgrades the analysis section of all three papers. ~1 week of analyst time; no new compute required.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §6
  closed_date: '2026-04-21'

- id: RESEARCH-024
  domain: research
  title: Multi-turn degradation curve run — ship the EVAL-044 fixture against belief_state on/off × haiku/sonnet
  status: open
  priority: P2
  effort: m
  description: |
    EVAL-044 designed a 10-turn debug scenario with coherence and belief-drift rubrics. The fixture exists; it has never been run. This gap runs it at n=30 per cell across belief_state on/off × haiku-4-5/sonnet-4-5, measuring turn-level accuracy decay. Plot turn × accuracy curves per cell. Test hypothesis: belief_state flattens the late-turn decay curve. This is the first multi-turn evidence Chump will have; publishable framing is "When memory modules actually help: a turn-level analysis" — a conditional claim (helps in trajectory-dependent tasks after turn N) is more defensible than an aggregate claim.
  acceptance_criteria:
    - n=30 × 10 turns × 4 cells = 1200 per-turn observations total
    - docs/FINDINGS.md gains turn-level accuracy plot with per-cell Wilson CIs per turn
    - "Preregistered hypothesis — \"belief_state reduces accuracy decay between turn 5 and turn 10 by at least Δ\" — locked per RESEARCH-019 before first trial"
    - If belief_state flattens the decay curve on sonnet only and not haiku, publish as a tier-conditional memory finding
    - Reference-rate analysis per RESEARCH-022 applied to check whether agent actually uses the injected belief_state
  depends_on: [RESEARCH-019, RESEARCH-022]
  notes: |
    Paper-3 foundation. Budget ~$60 cloud. Novel dimension — no prior Chump finding is multi-turn.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §7

- id: RESEARCH-025
  domain: research
  title: Per-task-category human-LLM-judge kappa — extend EVAL-041 to 100 trials × 5 task categories
  status: open
  priority: P2
  effort: m
  description: |
    EVAL-068 reported cross-judge kappa (sonnet-4-5 vs Llama-3.3-70B) at 77.3% overall with per-fixture variance (reflection=86%, perception=75%, neuromod=71%). The aggregate number hides that neuromod judgments sit on much weaker judge ground than reflection. Extend EVAL-041's human-grading protocol to 100 trials × 5 task categories (reflection, perception, neuromod, multi-hop, clarification). Compute kappa per category against the LLM-judge panel. Report category-conditional judge reliability alongside every downstream delta. Deltas reported on low-kappa categories need wider confidence intervals.
  acceptance_criteria:
    - 100 trials × 5 task categories = 500 human-graded examples
    - docs/eval/EVAL-041-human-grading.md gains a per-category kappa table
    - "docs/FINDINGS.md gains \"judge reliability\" footnote on every reported delta indicating the category's kappa"
    - Deltas on categories with kappa <0.60 flagged as instrument-limited
    - Preregistered rubric before human grading begins
  depends_on: [RESEARCH-019]
  notes: |
    ~40 hours of human grading + analysis. Strengthens every paper's methodology section.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §8

- id: RESEARCH-026
  domain: research
  title: Observer-effect / evaluation-framing sandbagging check
  status: open
  priority: P2
  effort: s
  description: |
    Frontier models can behave differently when they detect they are being evaluated. Chump's fixtures include explicit evaluation framing (task IDs, structured rubrics, "the user asks..." syntax). We have not measured whether scrubbing that framing changes agent behavior. If it does, every reported delta is inflated by observer-effect bias. This gap reruns the reflection fixture at n=50 with two arms — (a) normal framing, (b) evaluation-framing scrubbed and rewritten as casual user messages. Measure behavior delta between arms. If significant, publish correction factor; if not, publish as validation that Chump fixtures don't have detectable eval-framing bias. Paper-1 scope caveat blocker.
  acceptance_criteria:
    - "Reflection fixture cloned and rewritten in \"casual user message\" format (no task IDs, no rubric language, no \"the user asks\" preamble)"
    - n=50/cell × 2 framing arms × 2 model tiers (haiku, sonnet) = 400 trials
    - Observer-effect delta reported with Wilson 95% CI in docs/FINDINGS.md
    - If delta >0.05 in either tier, the finding requires an observer-effect correction section in any publication
    - Preregistered per RESEARCH-019
  depends_on: [RESEARCH-019]
  notes: |
    ~$20 cloud. Paper-1 credibility booster. If the result is null, it strengthens the publishable finding by ruling out a standard reviewer concern. 2026-04-21: paired formal fixture (reflection_tasks_formal_paired_v1.json), run-observer-effect-ab.sh wiring to run-cloud-v2.py (--n-per-cell, --out-dir), analysis helper analyze-observer-effect.py, result shell docs/eval/RESEARCH-026-observer-effect.md, FINDINGS index row (pending sweep), and scripts/test-research-026-preflight.sh merged to main in PR #400 (2026-04-21). Human pilot validation gate signed off (Jeff Adkins 2026-04-21); 50-task casual fixture shipped; harness smoke (n=2 haiku pilot) passed 2026-04-21 — see docs/eval/RESEARCH-026-observer-effect.md § Harness smoke. Remaining acceptance: preregistered 400-trial cloud sweep, Wilson analysis in FINDINGS, then close this gap with closed_commit. Operating stance (2026-04-21): keep status open and backlog the paid full sweep until a paper or external-credibility sprint — it is not required to inform ordinary engineering. Harness + CI preflight + human validation gate + smoke are treated as sufficient to keep building; schedule the ~\$15–\$20 sweep when publication claims need the preregistered Wilson row.
  source_doc: docs/RESEARCH_CRITIQUE_2026-04-21.md §9

- id: RESEARCH-027
  domain: research
  title: Together free-tier agent routing for ab-harness — implement COST_OPTIMIZATION.md strategy in run-binary-ablation.py and run-cloud-v2.py
  status: done
  priority: P1
  effort: s
  description: |
    The harness already supports Together as a judge (prefix `together:<model>` in --judge-model). RESEARCH-021's 4-family tier-dependence sweep and several other preregistered gaps additionally need Together as an agent provider so that the Llama/Qwen/DeepSeek cells can run on Together's free tier. This gap ships the CLI flag + provider-routing code that makes the swap a one-line change per cell. Without it, the agent side of the cost-optimized program requires manual shelling into the chump binary with Together env vars set — too fragile for a 1,600-trial sweep. See docs/eval/preregistered/COST_OPTIMIZATION.md for the full strategy and per-gap revised budgets (~$220 total savings on the 9-gap program).
  acceptance_criteria:
    - run-binary-ablation.py accepts --agent-provider {anthropic,together,ollama} and --agent-model <name>
    - run-cloud-v2.py accepts the same flags, plumbed through to the agent call path
    - scripts/ab-harness/together_free_models.py ships with a maintained list of currently-free-tier models + last-verified date
    - Rate-limit-aware backoff — 429 responses trigger 5s → 30s → 60s exponential backoff; max 3 retries before the trial is logged as excluded
    - Test fixture scripts/test-together-routing.sh verifies a 3-trial smoke sweep against both Anthropic and Together providers without manual config
    - "docs/eval/preregistered/COST_OPTIMIZATION.md updated with a \"RESEARCH-027 shipped, 4-family sweep now 1-flag change\" note"
  depends_on: [RESEARCH-019]
  notes: |
    ~4-6 hours implementation + 1h test. Once shipped, every future preregistered sweep can routes its non-Anthropic cells to the Together free tier by default. Saves ~\$160 across the program.
  source_doc: docs/eval/preregistered/COST_OPTIMIZATION.md
  closed_date: '2026-04-21'

- id: RESEARCH-028
  domain: research
  title: Blackboard tool-selection-mediation test — does the blackboard mediate behavior non-verbally via tool sequences?
  status: open
  priority: P2
  effort: m
  description: |
    REMOVAL-001's original KEEP verdict for the blackboard module rested on (a) a directional +0.060 outcome delta at n=50 (NEUTRAL per EVAL-048's CI-overlap criterion) and (b) architectural plausibility — the agent should be able to see cross-turn state and condition on it. RESEARCH-022 (PR #368) measured textual reference rate for the blackboard at 1% — far below the 5% mechanistic-support threshold. The architectural-plausibility argument now requires an explicit mechanism hypothesis. The most plausible non-verbal mediation channel is tool selection. Blackboard carries high-salience state (tool failures, risk flags, recent-tool-outcomes). If the blackboard is load-bearing, Cell A (blackboard ON) and Cell B (blackboard OFF) should produce measurably different tool-call sequences on blackboard-salience- rich tasks even when verbal reference rate is low. Preregistered design: - Cells: A (blackboard ON), B (CHUMP_BYPASS_BLACKBOARD=1) - Fixture: blackboard-salience subset of neuromod fixture —
      tasks with tool retries, escalations, or risky tool outputs
      where prior-turn state should matter
    - Metric: tool-call sequence divergence per matched task pair
      (edit distance on normalized tool sequences; or distribution
      divergence measured by Jensen-Shannon over tool-bigrams)
    - n=50/cell - H1: sequence divergence > noise floor (from A/A baseline) - H0: sequences match — blackboard is not mediating even
      non-verbally → file REMOVAL-005 (blackboard removal)
  acceptance_criteria:
    - docs/eval/preregistered/RESEARCH-028.md filed before first trial
    - Blackboard-salience task subset selected from existing neuromod fixture, n≥40 qualifying tasks
    - Metric definition locked — tool-sequence divergence metric specified to the point two analysts compute the same number
    - n=50/cell sweep run against the subset with Cell A (blackboard ON) and Cell B (CHUMP_BYPASS_BLACKBOARD=1)
    - A/A baseline run first to establish noise floor on tool-sequence divergence
    - Result doc docs/eval/RESEARCH-028-blackboard-tool-mediation.md published with verdict per §9 decision rule
  depends_on: [RESEARCH-019, RESEARCH-022]
  notes: |
    ~\$25 cloud (Together free-tier judge where applicable). Paper-3 adjacent — multi-turn belief dynamics is belief_state-focused, but blackboard tool-mediation is a parallel mechanism-test question. REMOVAL-001 addendum (2026-04-21) recommends this gap as the decisive test for whether blackboard's "keep" verdict holds.
  source_doc: docs/eval/REMOVAL-001-addendum-RESEARCH-022.md

- id: RESEARCH-029
  domain: research
  title: SKILL0 competitive positioning — inference-time injection vs training internalization
  status: open
  priority: P2
  effort: s
  description: |
    SKILL0 (In-Context Agentic Reinforcement Learning for Skill Internalization,
    April 2026, https://huggingface.co/papers/2604.02268) presents a framework that
    teaches agents skills via a training-time curriculum then progressively withdraws
    skill context at inference time, achieving under 0.5k tokens per step at deployment.
    This directly challenges Chump's runtime lesson injection thesis: if the haiku-tier
    improvement Chump observes is an internalization effect, Chump's per-session prompt
    overhead is a bridge to a destination SKILL0 reaches directly. FRONTIER-006 assessed
    the JEPA threat; no equivalent gap addresses the SKILL0 threat. This gap produces
    either: (a) an experiment ruling out simple internalization, or (b) a strategic
    decision that Chump's lesson injection is a transition mechanism, with implications
    for PRODUCT-009 publication framing.
  acceptance_criteria:
    - Written position statement filed in docs/ on whether Chump's lesson injection effect is compatible with the SKILL0 internalization hypothesis
  depends_on: [RESEARCH-021]
  opened_date: '2026-04-26'

- id: RESEARCH-030
  domain: RESEARCH
  title: Instrument-invalidation footgun audit process - when scorer/tooling found broken, automatically flag prior measurements
  status: open
  priority: P1
  effort: s
  description: |
    INTEGRITY_AUDIT_3 surfaced a systemic vulnerability - when EVAL-060
    found the exit-code scorer was broken, no automated review of prior
    measurements that depended on it was triggered. EVAL-026 (broken
    scorer) and EVAL-069 (probably broken scorer) both went unflagged.
    The python3 shebang fix landed without a re-run requirement on prior
    eval gaps. Add a process rule to RESEARCH_INTEGRITY.md and a script
    that, when an instrument-invalidating gap closes, greps prior eval
    docs for that pattern (scorer string, shebang, judge prompt version,
    fixture file, etc.) and emits an ALERT requiring re-validation before
    cited results stand.
  acceptance_criteria:
    - RESEARCH_INTEGRITY.md adds an Instrument Invalidation Protocol section
    - scripts/eval-footgun-audit.sh greps prior eval docs for a given pattern
    - "When an EVAL-* gap with notes:instrument_invalidation closes, the script auto-runs and posts ambient ALERT kind=eval_recheck_required"
    - Backtest against EVAL-060 - ALERT would have flagged EVAL-026 and EVAL-049-058 binary-mode runs
  opened_date: '2026-04-26'

- id: RESEARCH-031
  domain: RESEARCH
  title: Strategic research docs are orphan - STRATEGIC_MEMO and RESEARCH_INTEGRITY have no owner_gap
  status: open
  priority: P1
  effort: s
  description: |
    docs/STRATEGIC_MEMO_2026Q2.md (innovation watchpoint - JEPA, AMI Labs)
    and docs/RESEARCH_INTEGRITY.md (binding methodology - n>=50,
    non-Anthropic judge, A/A baseline, mechanism analysis, prohibited
    claims) both have empty owner_gap fields. Cold Water Issue #5
    explicitly flagged the strategic memo as an orphan. With no owner
    gap, there is no scheduled re-review, no acceptance criteria, no
    way to audit whether the project is actually engaging with these
    standards. File explicit owning gaps that schedule cycle reviews
    and track concrete actions tied to each doc's recommendations.
  acceptance_criteria:
    - STRATEGIC_MEMO_2026Q2.md gets an owner_gap (this gap or a child) and a quarterly review cadence
    - RESEARCH_INTEGRITY.md gets an owner_gap that schedules audit of recent EVAL/RESEARCH closures against the methodology table
    - Pre-commit guard or CI check warns when a docs/STRATEGIC_*.md or docs/RESEARCH_INTEGRITY*.md is modified without updating its owner_gap activity
    - First cycle review writes a one-paragraph status note to the owner gap's notes field
  opened_date: '2026-04-26'

- id: SECURITY-001
  domain: infra
  title: Verify rotation status of leaked Together + Anthropic API keys (Red Letter
  status: done
  priority: P0
  effort: s
  description: |
    Red Letter Issue #1 named a live Together API key (tgp_v1_Z_OJykKz-DGyKlp9lCPiX6hhVmwNLz8-p6nrWuhN1ik) committed to config/config.yaml in commit fba4b11 — permanent in git history. ANTHROPIC_API_KEY across 4 commits in config/prod.yaml (86cc884, e618bb0, cf05ce5, 62db274). EVAL-068 doc later mentioned tgp_v1_* returning HTTP 403 — possibly already rotated, but unverified. This gap closes the verification loop: confirm rotation status of every named key, document in a private internal note (NOT committed), and verify all leaked keys are now invalid.
  acceptance_criteria:
    - "For each named leaked key: attempt API call with key, confirm 401/403 (rotated) or escalate (still live)"
    - "If still live: rotate immediately at provider dashboard, then re-verify"
    - docs/SECURITY-001-key-rotation-audit.md (PUBLIC, no key material) summarizes verification protocol + outcome (rotated yes/no per key)
    - config/ added to root .gitignore via INFRA-018
  notes: |
    P0 because credential exposure is unbounded-cost. ~1 hour. Red Letter #1 ONE BIG THING. Do NOT commit verification responses or keys to git — keep audit trail private; only rotation outcome is public.
  source_doc: docs/RED_LETTER.md Issue
  closed_date: '2026-04-20'

- id: SECURITY-002
  domain: infra
  title: Track RUSTSEC advisories in transitive deps (rsa, rustls-webpki)
  status: open
  priority: P2
  effort: m
  description: |
    INFRA-044 weekly audit dispatcher flagged 6 RUSTSEC advisories on 2026-04-24 — all in transitive deps with no direct upgrade path:
    (1) RUSTSEC-2023-0071 — rsa 0.9.10 Marvin Attack (timing sidechannel key recovery). Pulled via superboring → jwt-simple → web-push. Upstream rsa crate has no patched release as of 2026-04-24 (advisory open since Nov 2023). Remediation options: replace web-push dep, or wait for rsa 0.10.
    (2) RUSTSEC-2026-0049/0098/0099/0104 — rustls-webpki 0.102.8 (panic on CRL parsing, incorrect name-constraint handling). Pulled via serenity 0.12.5 → tokio-tungstenite 0.21 → tokio-rustls 0.25 → rustls 0.22.4. Fixed in rustls-webpki 0.103+ which is already in the tree via newer consumers. Remediation: bump serenity to 0.13 when released (currently 0.12.5 is latest stable), or fork/patch locally.
    No direct-crate changes possible today. This gap remains open to track upstream fixes — weekly audit CI will re-surface it until the advisory disappears from cargo-audit output.
  acceptance_criteria:
    - cargo-audit --deny warnings exits 0 on main
    - No RUSTSEC-2023-0071 in dep tree (rsa patched or replaced)
    - No RUSTSEC-2026-0049/0098/0099/0104 in dep tree (rustls-webpki 0.102.x gone)
  depends_on: [INFRA-044]
  notes: |
    Filed from the INFRA-044 first dry run. Do not close this gap by silencing cargo-audit — the findings doc already records the real advisories. Re-evaluate weekly when the audit CI runs.
  source_doc: docs/audit/findings-2026-04-24.md

- id: SECURITY-003
  domain: SECURITY
  title: Rotate QUEUE_DRIVER_APP_PRIVATE_KEY every 90 days
  status: done
  priority: P3
  effort: xs
  description: |
    INFRA-048 wired up a GitHub App (QUEUE_DRIVER_APP_ID + QUEUE_DRIVER_APP_PRIVATE_KEY) so queue-driver pushes can re-trigger CI on auto-merge PRs. App private keys have no expiry — if the key ever leaks (developer laptop compromise, secret misconfiguration in a fork), an attacker has perpetual write access to main. Establish a 90-day rotation cadence: regenerate the key in the App settings, update the QUEUE_DRIVER_APP_PRIVATE_KEY repo secret, delete the old key. No code change — pure operational policy. File a calendar reminder + add a checklist entry to docs/SECURITY.md (or equivalent) once the doc exists.
  acceptance_criteria:
    - 90-day rotation interval documented in repo (RUNBOOK.md or SECURITY.md)
    - First rotation performed and logged (date stamped)
    - Second rotation scheduled (calendar event or recurring task)
  notes: |
    Low priority because the App is scoped to this single repo and only has the minimum permissions queue-driver needs (pull-requests: write, contents: write). Defense-in-depth, not an urgent fix.
  closed_date: '2026-04-25'

- id: SECURITY-004
  domain: SECURITY
  title: 6 open Dependabot alerts (1 HIGH rustls-webpki DoS, 2 medium, 3 low) — audit + upgrade
  status: open
  priority: P0
  effort: s
  description: |
    `gh api repos/repairman29/chump/dependabot/alerts` shows 6 open
    advisories on origin/main as of 2026-04-28. Highest-severity item
    is `rustls-webpki` (HIGH): Denial of service via panic on malformed
    CRL BIT STRING — any code path that processes a server-supplied CRL
    can be panicked by a remote attacker. chump's HTTPS provider stack
    (Tauri webview + reqwest + rustls) transitively depends on this.
    
    Full list (severity, package, ecosystem, advisory):
      - HIGH    rustls-webpki — DoS via panic on malformed CRL BIT STRING
      - MEDIUM  rustls-webpki — CRLs not authoritative by Distribution Point (faulty matching)
      - MEDIUM  glib          — Unsoundness in Iterator/DoubleEndedIterator for VariantStrIter
      - LOW     rand          — Unsound with custom logger using rand::rng()
      - LOW     rustls-webpki — Name constraints accepted for wildcard certs
      - LOW     rustls-webpki — Name constraints for URI names incorrectly accepted
    
    SECURITY-002 (P? open) was filed earlier as the umbrella audit gap;
    this is a concrete, auditable instance with a HIGH severity item that
    has been open long enough to accumulate. Cargo-audit is presumably
    already wired into CI but does not block PRs at the HIGH threshold.
    
    Fix path:
      1. `cargo audit` to confirm transitive paths from chump's Cargo.lock
         to each advisory.
      2. For each direct dep: bump version. For each transitive: chase
         upstream (likely tauri / reqwest / rustls).
      3. Verify `cargo build --release --bin chump` clean.
      4. Add to .github/workflows/ci.yml a `cargo deny advisories` step
         that fails on HIGH if not already present.
  acceptance_criteria:
    - 0 open HIGH-severity Dependabot alerts after the upgrade lands
    - cargo deny advisories step in CI fails on HIGH (regression guard)
    - Cargo.lock diff documents every bump in the PR description
  opened_date: '2026-04-28'

- id: SECURITY-005
  domain: SECURITY
  title: serenity 0.12.5 (latest) pins vulnerable rustls-webpki 0.102.8 — Dependabot cannot fix; mitigation chosen
  status: done
  priority: P0
  effort: m
  description: |
    Three Dependabot advisories trace through chump → serenity 0.12.5 → tokio-tungstenite 0.21 → rustls 0.22 → rustls-webpki 0.102.8 (vulnerable). cargo search serenity returns 0.12.5 — that IS the latest release, so Dependabot cannot bump. Reachability verified via cargo tree -i: only the Discord gateway WebSocket path hits the vulnerable transitive; REST callers (a2a_tool, discord_dm, serenity HTTP client) use safe rustls 0.23. Mitigation chosen: option (3) — gate Discord gateway behind CHUMP_ALLOW_DISCORD_RUSTLS=1 ack on top of existing PRODUCT-014 gates. Implementation: PR #682 (commit 360c6b7). Removal trigger: cargo audit shows 0 rustls-webpki 0.102.x advisories (upstream serenity bumped tungstenite). The gap row was orphaned through three failed YAML-append refile attempts (#678, #684, #695) before this canonical-CLI shipment via INFRA-147 dump.
  opened_date: '2026-04-30'
  closed_date: '2026-04-30'
  closed_pr: 682

- id: SENSE-001
  domain: agent
  title: PeripheralSensor trait — hot-path interrupt bridge
  status: done
  priority: P3
  effort: m
  description: |
    White-paper hot/cold path: peripheral sensors (future: CV, audio, presence detection) should be able to interrupt a running agent turn via a typed SensorEvent. Today there is no abstraction for this — it would require patching the agent loop ad-hoc per sensor type. Define the trait now so future ambient sensors (NewMessageSensor, MotionSensor, ThresholdSensor) can be wired without touching the loop. Initial implementation: NewMessageSensor fires when a second incoming message arrives while a turn is in flight, triggering cancellation so the agent can process the freshest context.
  depends_on: [AGT-002, AGT-004]
  source_doc: src/agent_loop/orchestrator.rs
  closed_date: '2026-04-18'

- id: TEST-001
  domain: TEST
  title: stacked test
  status: open
  priority: P2
  effort: m

- id: TEST-002
  domain: TEST
  title: Multi-agent coordination integration test coverage - leases, ambient stream, gap-claim, bot-merge are the production layer with thinnest tests
  status: open
  priority: P1
  effort: m
  description: |
    Tour audit on 2026-04-26 found that the highest-shipping-grade part
    of Chump (the multi-agent coordination layer - gap-claim.sh,
    gap-preflight.sh, bot-merge.sh, .chump-locks/, ambient.jsonl,
    chump-ambient-glance.sh, the SQLite gap registry) has the thinnest
    integration test coverage. Most modules in src/ allow dead_code; the
    consciousness_exercise test is a measurement harness not a validator.
    File a coordinated test-coverage push for the coordination layer -
    end-to-end integration tests that exercise concurrent claims, lease
    expiry, ambient-stream events from sibling sessions, gap-preflight
    blocking, bot-merge.sh ship pipeline against a fake-remote repo,
    chump gap reserve atomicity. Use tempfile and git fixtures.
  acceptance_criteria:
    - Integration test - two concurrent gap-claim calls on same gap - one wins, one fails
    - Integration test - gap-preflight blocks when sibling lease present, allows when expired
    - Integration test - ambient.jsonl tail filters self-session correctly
    - Integration test - bot-merge.sh dry run against fake remote - PR title and body assertions
    - Integration test - chump gap reserve picks distinct IDs under concurrent invocation
    - All run in CI under cargo test --workspace
  opened_date: '2026-04-26'

- id: UX-001
  domain: ux
  title: One-command install flow — brew install chump → working PWA in < 60s
  status: done
  priority: P1
  effort: m
  description: |
    COMP-010 (brew formula) is marked done, but the end-to-end "install → running PWA" path has no measured acceptance criterion. North Star: "someone runs one command, a PWA opens." This gap owns the ≤60-second promise. Scope: (1) `chump init` subcommand that, on first run, (a) detects available local models, (b) writes a minimal config, (c) starts the server, (d) opens the PWA at localhost:<port>/v2 in the default browser; (2) OOTB wizard (already exists at web/ootb-wizard.js — audit for reuse vs rewrite once PRODUCT-012 lands); (3) stopwatch script scripts/measure-ftue.sh that times `brew install chump && chump init && <until PWA is responsive>` and fails CI if > 90s on a GitHub runner; (4) docs/ONBOARDING.md with screenshots of each step. If REL-002 (Ollama upstream blocker) is unresolved, ship a bundled-model fallback with a quantized default so no external dependency is needed for the first-run success.
  acceptance_criteria:
    - "`chump init` subcommand exists and chains detect → config → serve → open-browser"
    - FTUE stopwatch ≤ 60s on M4 Mac, ≤ 90s CI budget
    - PWA opens automatically on first-run success
    - Missing-model path guides user to a default download (no silent hangs)
    - docs/ONBOARDING.md with real screenshots
  depends_on: [PRODUCT-012, REL-002]
  notes: |
    COMP-010 shipped the formula; this gap closes the UX promise the formula implies. REL-002 dep is soft — ship a bundled-default fallback if Ollama still blocked.
  source_doc: docs/NORTH_STAR.md
  closed_date: '2026-04-21'

