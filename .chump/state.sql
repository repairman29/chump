---
gaps:
- id: EVAL-081
  title: Fix binary-mode ablation harness — replace exit-code-0 scorer with LLM-judge scorer
  domain: eval
  priority: P0
  effort: 
  status: done
- id: COMP-001
  title: Skills system — reusable SKILL.md procedure documents with auto-create
  domain: competitive
  priority: P0
  effort: l
  status: done
  notes: "Skills stack: src/skills.rs, src/skill_tool.rs, src/skill_db.rs, src/skill_metrics.rs, context_assembly.rs wired, tool_inventory.rs registered. Auto-create trigger: total_tool_calls added to AgentRunOutcome; maybe_suggest_skill() posts blackboard suggestion when >= CHUMP_SKILL_SUGGEST_THRESHOLD (default 5).
"
- id: COMP-002
  title: Plugin entry points — ChumpPlugin trait with 3 discovery sources
  domain: competitive
  priority: P0
  effort: l
  status: done
  notes: "ChumpPlugin trait + PluginManifest + PluginContext + discover_plugins() (user+project). CLI: --plugins-list, --plugins-install <path>, --plugins-uninstall <name>, --plugins-disable <name>, --plugins-enable <name>. Disabled list persisted in ~/.chump/plugins/.disabled.json. discover_active_plugins() filters disabled. initialize_discovered() uses active-only list. 5 new serial tests. Note: V2 dynamic loading via libloading deferred (entry_path field ready in manifest).
"
- id: REL-001
  title: Model quality matrix — one local model reliably completes T1.1 end-to-end
  domain: reliability
  priority: P0
  effort: m
  status: done
  notes: Partially blocked on REL-002 (upstream Ollama).
- id: RESEARCH-018
  title: Length-matched scaffolding-as-noise control — rule out prompt-length confound in every lessons A/B
  domain: research
  priority: P0
  effort: m
  status: done
  depends_on: ["RESEARCH-019"]
  notes: "Paper-1 prerequisite. Low compute (~$3 cloud) and ~3 days of harness work. This is the single most important missing control in the current methodology. Operational split: Lane A (harness + smoke + result-doc shell) vs Lane B (preregistered n=100 sweeps) — docs/RESEARCH_EXECUTION_LANES.md §3. Result template: docs/eval/RESEARCH-018-length-matched.md.
"
- id: EVAL-060
  title: BLOCK EVAL-059 closure — ablation harness methodology fix before further VALIDATED(NULL) labels
  domain: eval
  priority: P0
  effort: m
  status: done
  depends_on: ["EVAL-049"]
  notes: "~1-2 days. Filed in response to docs/RED_LETTER.md Issue #3 2026-04-20 which called the current instrument a \"measurement failure rebranded as a conclusion.\" The risk of not shipping this: every faculty in Q3 plan ends up labeled COVERED+VALIDATED(NULL) on methodologically invalid evidence, and the project's own RESEARCH_INTEGRITY.md prohibits citing those results externally. Better to have one open faculty than six invalidly closed ones.
"
- id: INFRA-007
  title: Ambient stream firing audit — why FLEET-004 hooks emit nothing despite status=done
  domain: infra
  priority: P0
  effort: m
  status: done
  notes: "Blocker #4 on the 2026-04-20 5-blocker list. Hard prerequisite for any unattended run longer than ~30 minutes. The monitor loop exists, the hooks exist, but end-to-end emission is broken. Expected ~1 day of investigation + fix.
"
- id: PRODUCT-015
  title: Activation funnel telemetry — install → first-task completion → day-2 return
  domain: product
  priority: P0
  effort: m
  status: open
  notes: Gate for Tier 2/3 audit work and the research-credibility panel in docs/EXPERT_REVIEW_PANEL.md. Activation threshold set by CPO once the funnel is live.
- id: INFRA-079
  title: Pre-commit hook for EVAL/RESEARCH gap closure — require cross-judge audit or explicit waiver
  domain: infra
  priority: P0
  effort: m
  status: open
  depends_on: ["EVAL-074"]
- id: INFRA-CLIPPY-RUST195
  title: Clippy sweep for Rust 1.95.0 lints
  domain: infra
  priority: P0
  effort: s
  status: done
- id: RESEARCH-019
  title: Pre-registration protocol for all future eval gaps — docs/eval/preregistered/ infrastructure + pre-commit guard
  domain: research
  priority: P0
  effort: s
  status: done
  notes: Single highest-leverage methodology infrastructure change in the critique. Every other RESEARCH-* gap depends on it. Ship first.

- id: EVAL-066
  title: EVAL-060 methodology framing correction — provider-dependence not instrument failure
  domain: eval
  priority: P0
  effort: s
  status: done
  depends_on: ["EVAL-060"]
  notes: "Pure documentation correction, ~30 LOC across 3 files. The technical fix was already made (LLM judge + A/A mode landed in PR #279); this gap corrects the interpretation of the A/A FAIL that came with it. High priority because every downstream re-score interpretation rests on the methodology doc's claims.
"
- id: EVAL-82
  title: Re-verify EVAL-069 scorer credibility under python3.12
  domain: eval
  priority: P0
  effort: s
  status: done
- id: SECURITY-001
  title: Verify rotation status of leaked Together + Anthropic API keys (Red Letter
  domain: infra
  priority: P0
  effort: s
  status: done
  notes: "P0 because credential exposure is unbounded-cost. ~1 hour. Red Letter #1 ONE BIG THING. Do NOT commit verification responses or keys to git — keep audit trail private; only rotation outcome is public."
- id: INFRA-018
  title: Add config/ + secrets paths to .gitignore + pre-commit credential-pattern guard
  domain: infra
  priority: P0
  effort: s
  status: done
  depends_on: ["SECURITY-001"]
  notes: P0 because credential leakage is the worst-case failure mode this project has so far avoided structurally. ~1 hour. Pairs with SECURITY-001 (verify past leaks rotated, prevent future leaks).
- id: INFRA-020
  title: Close concurrent-gap-ID invention hole in process docs + preflight
  domain: infra
  priority: P0
  effort: s
  status: done
  notes: P0 because process erosion compounds — every additional week without this guard means more wasted agent-hours on collision PRs + reverts. Small code change, large collision-prevention value.
- id: PRODUCT-016
  title: 3-minute demo video + scripted walkthrough against current main
  domain: product
  priority: P0
  effort: s
  status: open
  depends_on: ["PRODUCT-017"]
  notes: Forcing function, not theater. Failed recording attempts are the signal.
- id: PRODUCT-017
  title: UX-001 verification — stopwatch clean-machine install → PWA responsive today
  domain: product
  priority: P0
  effort: s
  status: open
  notes: UX-001 closed 2026-04-21 — re-verify before assuming the activation funnel measures a working path.
- id: REL-002
  title: Ollama upstream stability on 24GB M4 (upstream blocker)
  domain: reliability
  priority: P0
  effort: xs
  status: blocked
  notes: "Workarounds:
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
"
- id: INFRA-017
  title: Fix ab-harness python3 shebang foot-gun — python3 resolves to 3.14 (no anthropic), silently fell back to exit-code scoring
  domain: infra
  priority: P0
  effort: xs
  status: done
  notes: "Scope intentionally narrow — only the shebang and direct caller invocations were changed. Docstring examples inside the scripts (`\"Usage: python3 scripts/ab-harness/foo.py ...\"`) were NOT rewritten in this PR to keep the diff reviewable; a follow-up docs-cleanup sweep can handle those. The core scoring-reliability regression is closed — every chump-initiated ab-harness invocation now runs under python3.12 with anthropic installed.
"
- id: COG-001
  title: A/B study round 2 — LLM-as-judge + multi-model scaling curves
  domain: consciousness
  priority: P1
  effort: l
  status: done
  notes: Gate for COG-003 and COG-006.
- id: INFRA-MULTIAGENT-HYGIENE
  title: Per-session worktree + unique session IDs (structural fix)
  domain: infra
  priority: P1
  effort: l
  status: done
- id: EVAL-013
  title: Real reflection lessons (not synthetic block) — does THE thing help
  domain: eval
  priority: P1
  effort: l
  status: done
  depends_on: ["EVAL-022"]
  notes: TEST-CAT-B. The expected finding is "real lessons help more than synthetic" — would be the first publishable positive result for the framework. If real lessons also fail to help, the framework needs a deeper redesign (not just prompt-engineering).

- id: COMP-003
  title: Pluggable context engine — ContextEngine trait for per-deployment strategies
  domain: competitive
  priority: P1
  effort: l
  status: done
- id: FLEET-006
  title: Distributed ambient stream — bridge .chump-locks/ambient.jsonl to NATS topics
  domain: fleet
  priority: P1
  effort: l
  status: done
  notes: Critical path for distributed fleet. Unblocks FLEET-007/008/009. NATS can run entirely offline on Tailscale network (FLEET-013 prereq). Prototype in 2–3 days.
- id: PRODUCT-003
  title: User profile system — three-layer identity, context, and learned preferences
  domain: product
  priority: P1
  effort: l
  status: done
- id: COG-030
  title: Proactive epistemic probing + EIG-gated execution hard-block
  domain: consciousness
  priority: P1
  effort: l
  status: done
  depends_on: ["AUTO-001"]
- id: INFRA-062
  title: M4 — Feature flags for COG-* (kill long-lived cognitive branches)
  domain: infra
  priority: P1
  effort: l
  status: done
  depends_on: ["INFRA-058"]
  notes: Parallelizable with M3 — independent code paths.
- id: COG-011
  title: Eval A/B — does lesson injection actually improve outcomes?
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["COG-007"]
- id: COG-011d
  title: Investigate why lesson injection hurts on gotchas (-0.30 delta)
  domain: consciousness
  priority: P1
  effort: m
  status: done
  depends_on: ["COG-011","COG-011b"]
  notes: "Variant (b) tested + supported (2026-04-17, 0eecf5e + this run): CHUMP_REFLECTION_STRICT_SCOPE=1 took the LLM-judge delta from -0.10 → +0.05 overall and gotcha from -0.30 → 0.00. Mode A's gotcha rate jumped from 0.50 (COG-011b) to 0.90. The \"noise hypothesis\" is supported: universal-scope lessons leaking into every prompt was the primary harm vector, not the lesson content itself. Still need ≥1 more variant (a/c/d) to satisfy the acceptance criterion.
"
- id: EVAL-001
  title: Expand eval suite from 5 to 30+ cases with golden trajectory tests
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: "37 single-turn seed cases across 6 EvalCategory variants; 5 golden trajectory cases (gt- prefix) with conversation_history. EvalCase.is_multiturn() added. Guard tests: seed_starter_cases_has_at_least_30, seed_covers_all_categories (min 3 per category), seed_has_at_least_5_golden_trajectory_cases.
"
- id: EVAL-010
  title: Human-labeled fixture subset — break circular author-grades-author A/B loop
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: Recommended follow-up from cloud A/B sweep (ce4ebc0). Estimated ~2 hours of human grading. Without this, no further cognitive-layer A/B effort should be funded — we cannot tell signal from rubric noise.

- id: EVAL-022
  title: Expand cognitive-layer fixtures to n>=100 tasks each
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: Task authoring is the bulk of the effort (~80 new tasks per fixture). Could be partly LLM-generated then human-reviewed for diversity. After this lands, the v2 harness can produce numbers that are safe to cite in research papers without the "preliminary, n=20" hedge.

- id: EVAL-012
  title: Multi-turn conversation A/B — does framework effect compound or wash out
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: TEST-CAT-A in docs/eval/TEST_BACKLOG.md. Likely needs new harness (run-cloud-v2.py is single-shot only). Could fork to run-cloud-multiturn.py that drives a loop. Per-trial cost is ~5x single-shot.

- id: EVAL-014
  title: Multi-judge median verdict — eliminate single-judge bias
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: "TEST-CAT-D. Blocker is API key access to a non-Anthropic model. Either user provides OpenAI/Gemini key, OR we add an Ollama-local judge (slower but free). Cost: ~3x the single-judge cost.
"
- id: AUTO-004
  title: Autonomy driver process — cron-friendly single-task-per-run loop
  domain: autonomy
  priority: P1
  effort: m
  status: done
  depends_on: ["AUTO-002"]
- id: FLEET-001
  title: Mutual supervision — Mac can restart Mabel; Pixel can probe Mac health
  domain: fleet
  priority: P1
  effort: m
  status: done
  notes: "scripts/restart-mabel.sh: SSH stop+restart chump --discord on Pixel via ensure-mabel-bot-up.sh. scripts/probe-mac-health.sh: curl /api/dashboard with CHUMP_WEB_TOKEN, parse fleet_status JSON. Integration test checklist added to docs/FLEET_ROLES.md.
"
- id: FLEET-007
  title: Distributed leases with TTL — replace filesystem .chump-locks/*.json with NATS
  domain: fleet
  priority: P1
  effort: m
  status: open
  depends_on: ["FLEET-006"]
  notes: Enables distributed work allocation. Heartbeat interval ~30s; TTL ~5min. Simple NATS state machine (not consensus-based; eventual consistency OK).
- id: FLEET-008
  title: Work board / task queue — post subtasks for other agents to claim
  domain: fleet
  priority: P1
  effort: m
  status: open
  depends_on: ["FLEET-006","FLEET-007"]
  notes: "Unblocks work decomposition (FLEET-011). Initial version: manual posting by agents. Later: automatic decomposition heuristics."
- id: FLEET-009
  title: Capability declaration & task-fit scoring — agents declare capabilities, tasks declare needs
  domain: fleet
  priority: P1
  effort: m
  status: done
  depends_on: ["FLEET-006","FLEET-008"]
  notes: "Early version: simple heuristic scoring. Later (FLEET-011): learn from outcomes, adjust reliability_score based on success/failure. Model family matching is critical (Anthropic vs open-source agents will make different decisions)."
- id: PRODUCT-001
  title: "PWA Dashboard — ship status, what-we're-doing, recent episodes"
  domain: product
  priority: P1
  effort: m
  status: done
  notes: Added fleet_status (green/yellow/red), last_heartbeat_iso to /api/dashboard. New /api/dashboard/stream SSE endpoint pushes snapshot every 30s. Frontend uses EventSource with polling fallback; applyDashboardSnapshot shared between SSE handler and loadDashboard.

- id: PRODUCT-004
  title: FTUE — first-run onboarding conversation that populates the user profile
  domain: product
  priority: P1
  effort: m
  status: done
  depends_on: ["PRODUCT-003"]
- id: COG-028
  title: Checkpoint V2 — zero-compute sleep + full state re-hydration
  domain: consciousness
  priority: P1
  effort: m
  status: done
- id: COG-033
  title: Reflection → dynamic system prompt injection
  domain: consciousness
  priority: P1
  effort: m
  status: done
- id: AUTO-010
  title: HITL permission negotiation — structured escalation with full reasoning
  domain: autonomy
  priority: P1
  effort: m
  status: done
  depends_on: ["AUTO-005","COG-008"]
- id: AGT-001
  title: Explicit AgentState FSM in iteration_controller
  domain: agent
  priority: P1
  effort: m
  status: done
- id: AGT-002
  title: "Cancellation token + tokio::select! interrupt loop"
  domain: agent
  priority: P1
  effort: m
  status: done
  depends_on: ["AGT-001"]
- id: AGT-004
  title: Wire MessagingAdapter events into agent input queue
  domain: agent
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-MESSAGING-DEDUPE","AGT-002"]
- id: COG-016
  title: Model-tier-aware lessons block injection
  domain: consciousness
  priority: P1
  effort: m
  status: done
  notes: "Direct production consequence of the headline finding from this session. Single-file Rust change in reflection_db.rs (model tier map + injection predicate update). Unit test count: 2 (tier mapping + gated predicate). Coordination caveat: prompt_assembler.rs has active edits in PR #66 (COG-015 entity blackboard); land COG-016 after #66 to avoid rebase.
"
- id: EVAL-026
  title: Cognitive-layer U-curve at 32B — extend 1B-14B sweep upward
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["COG-016","EVAL-025"]
  notes: "Cloud run path: scripts/ab-harness/run-cloud-v2.py with --model together:Qwen/Qwen2.5-{7B|72B}-Instruct-Turbo, judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo, --lessons-version v1 (the harm-triggering block, to test if scale flips it from harm to help), --limit 50 reflection. Harness gained together:/ollama: agent-model-prefix dispatch (was Anthropic-only for agent role; judges already supported all three providers). Cost ~\$2-3 cloud (72B Together is \$0.88/M tok, sonnet judge ~\$1).
"
- id: EVAL-027
  title: "SAKE knowledge anchoring — apply Feb 2026 KID paper to Chump's lessons + memory"
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-025","EVAL-026"]
  notes: "Implementation: add LESSONS_BLOCK_COG016_SAKE constant to run-cloud-v2.py that wraps the cog016 block as both system-prefix AND user-suffix appended to the prompt. Or implement as a production change in src/reflection_db.rs::format_lessons_block_sake() gated behind CHUMP_LESSONS_ANCHOR=both env var. Cloud-only sweep cost ~\$1-2. Wall ~30min. Reference paper: https://arxiv.org/abs/2602.09517
"
- id: FRONTIER-005
  title: goose competitive positioning + Chump differentiation strategy
  domain: frontier
  priority: P1
  effort: m
  status: done
  notes: "Action item from session 2026-04-19 strategic review. The deep research pass needs to actually read goose's architecture docs and run goose locally to compare. Reference: https://github.com/block/goose https://block.github.io/goose/ https://aaif.io/
"
- id: RESEARCH-001
  title: "Public research narrative — '2000+ A/B trials' blog post / paper"
  domain: research
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-027b","EVAL-029"]
  notes: "~1 week effort: outline, draft, charts, peer review by Jeff + external reviewer, edit, publish. Highest-leverage Chump positioning artifact we can produce in 2026-Q2. Differentiates Chump from goose/Aider/Claude Code which have shipped no comparable published findings on their own architectures.
"
- id: EVAL-030
  title: Task-class-aware lessons block — fix neuromod harm at its root cause
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-029","EVAL-027"]
  notes: "~3-4 days code + sweep. Cost ~$2 cloud. The cleanest production fix would be: in prompt_assembler.rs, look at the user prompt; if matches conditional-chain or trivial-token patterns, suppress lessons or drop specific directives. Could also be implemented as a per-fixture override at the eval-harness level for testing.
"
- id: COG-023
  title: Sonnet carve-out from cog016 directive — CONFIRMED at n=100, ship Path A
  domain: cognition
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-027b","EVAL-027c"]
  notes: "Atomic-PR ship target (~half day): code change + tests + docs in one commit, single push, auto-merge armed. Defensive ship — kills production harm at sonnet tier. Path B (COG-024) is the longer- term rethink.
"
- id: INFRA-AGENT-CODEREVIEW
  title: code-reviewer agent in the loop for src/* PRs before auto-merge
  domain: infra
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-MERGE-QUEUE","INFRA-AGENT-ESCALATION"]
  notes: ~1 week. Highest-leverage infra change after MERGE-QUEUE for "Jeff is no longer the bottleneck even on code PRs". Today docs PRs auto-ship cleanly; src/ PRs still require manual eyes. This closes the gap.

- id: COG-025
  title: Dispatch-backend pluggability — route orchestrator subagents via Together (free tier)
  domain: cognition
  priority: P1
  effort: m
  status: done
  notes: "~1-2 days. Biggest unknown: whether Together-hosted Qwen3-235B can actually drive a multi-turn tool-use loop end-to-end. EVAL-026 validated it for text-only; tool-use loop hasn't been A/B-tested. COG-026 (filed alongside) is the empirical validation gap that closes that loop.
"
- id: EVAL-041
  title: Human grading baseline — complete EVAL-010 for all fixture pairs
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: ~40 hrs human time (Jeff). Prerequisite for publication-readiness. EVAL-010-labels-jeff.md exists and is partially filled; extend it.

- id: EVAL-043
  title: Ablation suite — belief_state, surprisal EMA, neuromod each in isolation
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-042"]
  notes: ~$15 cloud + 2 days. This is the single most impactful research action remaining. Without it, the "cognitive architecture" thesis cannot be defended.

- id: RESEARCH-002
  title: Docs thesis reframe — align all docs to tier-dependent injection finding
  domain: research
  priority: P1
  effort: m
  status: done
  notes: ~1 day. No code changes. Prevents new contributors and agents from propagating inaccurate claims. Pairs with EVAL-042 — once cross- family judge results land, update these docs again with confirmed or revised deltas.

- id: RESEARCH-021
  title: Tier-dependence replication across 4 model families — extend haiku/sonnet finding to Llama/Qwen/DeepSeek/Gemma
  domain: research
  priority: P1
  effort: m
  status: open
  depends_on: ["RESEARCH-019"]
  notes: Paper-1 blocker. Budget ~$80 cloud (Together free-tier handles Llama/Qwen/DeepSeek; Gemma via Google AI Studio). The publishable framing of the entire tier-dependent finding hinges on whether it generalizes beyond Anthropic. Do not attempt full 1600-trial AC on a thin credit month — phase per docs/RESEARCH_EXECUTION_LANES.md §4 + COST_OPTIMIZATION.md; prereg deviations required for n/model changes.

- id: RESEARCH-023
  title: Counterfactual mediation analysis — upgrade module-contribution claims from average-treatment to natural-direct-effect
  domain: research
  priority: P1
  effort: m
  status: done
  depends_on: ["RESEARCH-019"]
  notes: Upgrades the analysis section of all three papers. ~1 week of analyst time; no new compute required.

- id: EVAL-048
  title: "Metacognition ablation sweeps: run EVAL-043 bypass-flag A/B at n>=100 — belief_state, surprisal, neuromod"
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: "Harness infrastructure confirmed working. Architecture caveat documented: bypass flags affect chump binary only, not direct API. Direct-API harness establishes noise floor (delta=0.0 for all three modules, A/A equivalent). Module isolation sweeps require running via chump binary (commands in docs/eval/EVAL-043-ablation.md). All four acceptance criteria met."
- id: EVAL-058
  title: Executive Function ablation — ship CHUMP_BYPASS_BLACKBOARD flag and binary-mode sweep
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-049"]
  notes: "Flag shipped and wired. n=30/cell binary-mode sweep complete. Delta=-0.033 with overlapping CIs — NO SIGNAL. Binary-mode noise floor (~90% exit-code-1 failures) limits interpretability per RESEARCH_INTEGRITY.md. Verdict: COVERED+VALIDATED(NULL)."
- id: EVAL-062
  title: Social Cognition graduation — stricter LLM-judge rubric or n≥200/cell to resolve PRELIMINARY
  domain: eval
  priority: P1
  effort: m
  status: done
  notes: "Path (1) strict-judge sweep (n=10/cell) run 2026-04-20: ceiling compression confirmed as root cause, NOT judge liberality. Cell B stays near 1.000 on ambiguous prompts even under strict rubric. Non-overlapping CIs not achieved. Social Cognition stays PRELIMINARY. Graduation path: n>=200/cell or lower-baseline model."
- id: EVAL-063
  title: Re-score Metacognition under EVAL-060 fixed instrument — LLM judge n≥50/cell
  domain: eval
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-060"]
- id: REMOVAL-001
  title: Audit + decision-matrix for the 5 NULL-validated cognitive modules — re-test or remove
  domain: reliability
  priority: P1
  effort: m
  status: done
  depends_on: ["EVAL-076"]
  notes: "Filed in response to Red Letter #3 ONE BIG THING. ~1-2 days analysis + decision; removals themselves filed as sub-gaps."
- id: INFRA-022
  title: Evaluate gap-store architecture — offline-first, bot-scaffoldable, optional GitHub mirror
  domain: infra
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-021"]
  notes: "P1, effort medium — this is an architectural decision, not a code push. Sequence: ship INFRA-021 (gap-reserve.sh) first so today's fleet stops colliding, then spend a half-day on the INFRA-022 memo + prototype, then decide."
- id: INFRA-023
  title: Rust-native state — SQLite-backed gap store + lease table in the chump binary (collapses INFRA-021 + INFRA-022)
  domain: infra
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-020"]
  notes: "P1, effort medium. SUPERSEDES INFRA-021 (delete or close as won't-fix once this lands) and SUPERSEDES INFRA-022 (the decision memo collapses to a commit message). Biggest risk is the git-diff story — SQLite-in-repo is polarizing; the .sql-dump-alongside convention is borrowed from Fossil + Dolt and is well-trodden. Pi-mesh sync is natural (sqlite3 .backup is rsync-friendly; for multi-node coordination, a future FLEET-* gap looks at CRDTs or a thin pub/sub). Rust-native alternatives noted in 2026-04-20 session memo: apalis (job queue w/ SQLite backend) is a phase-2 add-on; redb/sled/fjall are pure-Rust KVs worth revisiting if SQLite's C dep becomes a problem on Pi (spoiler: it won't)."
- id: INFRA-033
  title: "chump-mcp-coord: MCP tools for gap preflight, lease introspection, and musher hints"
  domain: infra
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-021"]
  notes: Queued 2026-04-23 from fleet-hardening plan. Ships after INFRA-028 (bot-merge liveness, done) so operators get one coherent observability story.

- id: INFRA-032
  title: Dual-surface coordination excellence — Cursor + Claude parity for Chump team workflows
  domain: infra
  priority: P1
  effort: m
  status: done
  notes: INFRA-031 closed doc parity for headless loop semantics; INFRA-032 is the product-level "both surfaces are best-in-class" slice. Synergy with INFRA-033 MCP tools — optional follow-on once coord server exists.

- id: PRODUCT-012
  title: PWA rebuild spike — framework choice + shell skeleton for web/
  domain: product
  priority: P1
  effort: m
  status: done
  depends_on: ["PRODUCT-011"]
  notes: Rebuild spike, not feature implementation. Follow-ups (chat pane wire-up, tool-call UI, etc.) file as PRODUCT-013..N.
- id: PRODUCT-013
  title: PWA rebuild — first vertical slice — chat pane connected to live agent
  domain: product
  priority: P1
  effort: m
  status: done
  depends_on: ["PRODUCT-012"]
  notes: First user-visible ship against the North Star since COMP-005a-fe (2026-04-04). Keep tight — follow-ups (history, multi-session) file as separate gaps.
- id: UX-001
  title: One-command install flow — brew install chump → working PWA in < 60s
  domain: ux
  priority: P1
  effort: m
  status: done
  depends_on: ["PRODUCT-012","REL-002"]
  notes: COMP-010 shipped the formula; this gap closes the UX promise the formula implies. REL-002 dep is soft — ship a bundled-default fallback if Ollama still blocked.
- id: INFRA-042
  title: Multi-agent dogfooding end-to-end test
  domain: infra
  priority: P1
  effort: m
  status: open
  depends_on: ["FLEET-006","FLEET-007"]
  notes: Critical for validating FLEET concept. Can run after FLEET-006/007 basic implementation.
- id: EVAL-083
  title: Eval credibility audit sweep
  domain: eval
  priority: P1
  effort: m
  status: open
  notes: High confidence gain for publication (PRODUCT-009). Parallelizable across agents.
- id: QUALITY-005
  title: Gap hygiene & estimation audit
  domain: quality
  priority: P1
  effort: m
  status: done
  notes: Improves Q2/Q3 planning accuracy. Results feed into gap registry refresh.
- id: INFRA-047
  title: Dependency modernization audit — clear CVEs and security blockers
  domain: infra
  priority: P1
  effort: m
  status: done
  notes: "Serenity 0.12 (Discord support) pulls old rustls 0.22.4 → webpki 0.102.8 (vulnerable). Not used in publishable crates, so doesn't block lib publishing. Documented as technical debt; serenity replacement tracked in PRODUCT-013. RSA 0.9.10 (Marvin attack) is server-side VAPID signing only (non-critical); acceptable as known risk with local-access requirement. async-std removed; unused legacy dependency.
"
- id: INFRA-059
  title: M1 — SQLite-authoritative gap store (finish INFRA-023)
  domain: infra
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-023","INFRA-058"]
  notes: Highest leverage milestone — every other M2-M5 step assumes a clean queryable gap store. Ship first.

- id: INFRA-060
  title: M2 — Plan-mode gate in dispatcher (file enumeration + open-PR overlap scan)
  domain: infra
  priority: P1
  effort: m
  status: done
  depends_on: ["INFRA-058","INFRA-059"]
- id: FLEET-015
  title: Ambient-stream NATS migration — complete FLEET-007 split-brain
  domain: fleet
  priority: P1
  effort: m
  status: open
  depends_on: ["FLEET-006","FLEET-007"]
- id: INFRA-082
  title: Reserve-time title similarity check — warn when filing a gap whose title overlaps an existing one
  domain: infra
  priority: P1
  effort: m
  status: open
  depends_on: ["INFRA-081"]
- id: INFRA-083
  title: mandate chump gap commands - block raw docs/gaps.yaml edits in pre-commit
  domain: infra
  priority: P1
  effort: m
  status: done
  notes: released - colliding with claude/infra-083-ambient-glance worktree
- id: INFRA-084
  title: mandate chump gap commands - block raw docs/gaps.yaml edits
  domain: infra
  priority: P1
  effort: m
  status: open
- id: INFRA-087
  title: automated repo failure-detection auditor + CI-time health checks
  domain: infra
  priority: P1
  effort: m
  status: open
- id: COG-007
  title: Wire structured reflection (GEPA) into prompt assembly
  domain: consciousness
  priority: P1
  effort: s
  status: done
- id: EVAL-011
  title: Fix LLM-judge hallucination bias — add DoesNotHallucinateFunctionCalls property
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-010"]
- id: AUTO-001
  title: Task contract — structured notes with context/plan/acceptance/verify/risks
  domain: autonomy
  priority: P1
  effort: s
  status: done
  notes: Fully implemented in src/task_contract.rs (template_for, ensure_contract, extract_sections, VerifyContract, parse_verify_json). Wired into task_tool.rs line 87. Tests in task_contract.rs. Nothing left to do.

- id: AUTO-003
  title: Task lease conformance tests — two workers cannot claim same task
  domain: autonomy
  priority: P1
  effort: s
  status: done
- id: ACP-001
  title: MCP server lifecycle — spawn, scope, and reap per ACP session
  domain: acp
  priority: P1
  effort: s
  status: done
- id: FLEET-002
  title: Single fleet report — Mabel drives briefing, Chump notifies only
  domain: fleet
  priority: P1
  effort: s
  status: done
  depends_on: ["FLEET-001"]
  notes: "Added CHUMP_FLEET_REPORT_ROLE=notify_only gate to hourly-update-to-discord.sh. When set, script exits immediately (no LLM call, no DM). Chump's notify tool remains active for ad-hoc events. docs/OPERATIONS.md \"Single fleet report\" section updated with Soft gate guidance.
"
- id: FLEET-004
  title: Peripheral vision — ambient awareness stream for multi-agent sessions
  domain: fleet
  priority: P1
  effort: s
  status: done
  notes: "Decomposed into four xs/s sub-gaps:
  FLEET-004a — ambient.jsonl format + emit helpers (xs)
  FLEET-004b — passive emission via git post-commit hook (xs)
  FLEET-004c — passive emission via Claude Code PostToolUse hooks (xs)
  FLEET-004d — CLAUDE.md context injection at session start (xs)
  FLEET-005  — anomaly detector daemon (s, separate gap)
"
- id: FLEET-005
  title: Anomaly detector — fswatch daemon emits ALERT events to ambient stream
  domain: fleet
  priority: P1
  effort: s
  status: done
  depends_on: ["FLEET-004a"]
- id: INFRA-006
  title: Fix vllm-mlx Metal crash on client disconnect mid-inference
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: "Crash pattern confirmed 2026-04-20. Workaround: kill all sweep procs, clear sessions/cli/cli/messages.json (was 251 messages / 32KB causing 120s+ inference), restart server, use --timeout 300 for sweeps. Also update doc examples in docs/eval/EVAL-054-perception-ablation.md and docs/CHUMP_AUTONOMY_TESTS.md to use --timeout 300."
- id: PRODUCT-002
  title: Single-command fleet deploy — scripts/deploy-fleet.sh for Mac + Pixel
  domain: product
  priority: P1
  effort: s
  status: done
  notes: "scripts/deploy-fleet.sh is fully implemented: parallel Mac+Android builds, hot-swap Discord+Web bots, deploy-all-to-pixel.sh for Pixel, fleet-health.sh final check. Flags: --mac, --pixel, --no-build, --health.
"
- id: EVAL-023
  title: Cross-family judge run — break Anthropic-only judge bias
  domain: eval
  priority: P1
  effort: s
  status: done
  notes: "Uses PR #83 (Ollama judge) which is auto-merge pending. Cost is bounded by the cloud agent calls (~\$1.62 same as PR #80) since Ollama judge is free. ~3-5 min wall on a quiet Ollama. Single command:
  scripts/ab-harness/run-cloud-v2.py --fixture FIX --tag X-cross --limit 100
    --model claude-haiku-4-5 --judges claude-sonnet-4-5,ollama:qwen2.5:14b

PROBE FINDING (2026-04-19, commit b4882e6): Llama-3.3-70B was tested as a cross-family agent and does NOT fit the existing fake_tool_calls axis — Llama reliably emits honest \"I cannot execute\" language rather than fake <function_calls> markup, so it always passes where Anthropic models fail. The existing binary axis measures Anthropic-model hallucination shape, not general hallucination.
REVISED DESIGN: Before running the n=100 cross-family judge sweep, add a positive axis: did_acknowledge_no_tools (model said \"I cannot execute\" + gave actionable guidance instead of faking tool output). This lets Llama score meaningfully. Options: (a) new axis in score.py, (b) family-specific regex detectors per provider, or (c) re-frame headline finding as \"Anthropic-agent + Anthropic-judge pairing reliably exhibits the loop\" — the most publishable framing. Pick one before running the cross-family sweep.
"
- id: EVAL-025
  title: Validate COG-016 anti-hallucination directive — rerun n=100 cross-family
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["COG-016","EVAL-023"]
  notes: "Reuses the EVAL-023 harness path: run-cloud-v2.py with judges claude-sonnet-4-5,together:meta-llama/Llama-3.3-70B-Instruct-Turbo at n=100 per fixture. Only change: `LESSONS_BLOCK` constant updated to match production output of `format_lessons_block()` from src/reflection_db.rs (lines 417-451 on main). Cost ~\$1.50 cloud (haiku-4-5 + sonnet-4-5 + together llama, similar to EVAL-023).
"
- id: INFRA-MERGE-QUEUE
  title: Enable GitHub merge queue — serialize auto-merges atomically against current main
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: "~1 hour settings change + 1 hour testing + ~2 hours docs/script update. Single highest-leverage change in the multi-agent dispatch architecture. References: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
"
- id: INFRA-PUSH-LOCK
  title: Pre-push hook blocks pushes to PRs with auto-merge armed
  domain: infra
  priority: P1
  effort: s
  status: done
  depends_on: ["INFRA-MERGE-QUEUE"]
  notes: "~3 hours including tests. Pattern matches existing CHUMP_GAP_CHECK pre-push hook structure. Reference: scripts/git-hooks/pre-push for conventions.
"
- id: INFRA-CHUMP-API-RETRY
  title: Spawned claude subprocess needs API-5xx retry wrapper
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: ~2 hours. Highest leverage to make the autonomy loop production- ready. Without it, every transient Anthropic 5xx kills a dispatch.

- id: INFRA-DISPATCH-PERMISSIONS-FLAG
  title: Spawned claude subagent stalls on permission prompts — pass --dangerously-skip-permissions
  domain: infra
  priority: P1
  effort: s
  status: done
- id: COG-026
  title: Validate Together-big models on chump agent loop — A/B vs claude
  domain: cognition
  priority: P1
  effort: s
  status: done
  depends_on: ["COG-025"]
  notes: "~1 day after COG-025 lands. If successful: 90%+ cost reduction on autonomous PR shipping. Pair with FRONTIER-007 (cross-agent benchmarking) for the broader story.
"
- id: INFRA-GAPS-DEDUP
  title: Fix gap registry ID collision — 7 duplicate ID pairs
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: "~2 hrs. Blocking: every agent session starts from a corrupted index until this ships. File as P1 hotfix alongside any other work.
"
- id: EVAL-042
  title: Cross-family judge re-run — non-Anthropic judge on all main findings
  domain: eval
  priority: P1
  effort: s
  status: done
  notes: ~$3 cloud + 1 day setup. Highest-leverage unblocking action for publication readiness. Together free tier provides Llama-3.3-70B at no cost. Already supported by run-cloud-v2.py --judges flag.

- id: EVAL-046
  title: LLM judge calibration — fix systematic biases found in EVAL-041 human grading
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-041"]
  notes: ~0.5 days code + Jeff completing EVAL-010-labels-jeff.md (~3 hrs). Blocks publication readiness. EVAL-010-analysis.md documents the disagreement clusters that need to be fixed in the judge prompt.

- id: RESEARCH-003
  title: Align public-facing docs with narrow tier-dependent-injection thesis (README, preprint, dissertation)
  domain: research
  priority: P1
  effort: s
  status: done
  depends_on: ["RESEARCH-002"]
  notes: Follow-on to RESEARCH-002. Does not alter descriptive implementation detail (e.g. the feedback-loop diagram in the dissertation); the reframe is targeted at validation claims only. Once EVAL-043 results land, these docs should be revisited to either tighten or relax the caveats based on the ablation outcomes.

- id: RESEARCH-022
  title: Module-use reference analysis — does the agent actually read the scaffolding it is given?
  domain: research
  priority: P1
  effort: s
  status: done
  notes: Paper-3 prerequisite (belief_state mechanism evidence). Purely post-hoc; re-analyzes existing JSONLs; no new trials. Fast win.

- id: RESEARCH-027
  title: Together free-tier agent routing for ab-harness — implement COST_OPTIMIZATION.md strategy in run-binary-ablation.py and run-cloud-v2.py
  domain: research
  priority: P1
  effort: s
  status: done
  depends_on: ["RESEARCH-019"]
  notes: ~4-6 hours implementation + 1h test. Once shipped, every future preregistered sweep can routes its non-Anthropic cells to the Together free tier by default. Saves ~\$160 across the program.

- id: EVAL-053
  title: Metacognition binary-mode sweep n=30 — measure real bypass-flag impact via chump binary
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-049"]
- id: EVAL-061
  title: "File 3 removal-candidate gaps for Memory/ExecFn/Metacognition OR re-score under EVAL-060's fixed instrument"
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-060"]
  notes: "~2-3 hours for the decision doc; longer if (a) is chosen and removals ship. The failure mode this prevents: the project claims all 10 faculties VALIDATED in external communications while carrying three modules with no measurable effect."
- id: EVAL-068
  title: Cross-judge validation for EVAL-060 — non-Anthropic judge on the A/A + re-score JSONLs
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-060"]
  notes: Target cost ~$0.50 on Together for the non-Anthropic judge passes (re-scoring is cheap vs running the binary sweep). Required for RESEARCH_INTEGRITY.md to permit external citation of any EVAL-060-derived result.

- id: EVAL-072
  title: Judge-methodology fix — rubric literalism + partial-credit divergence between Anthropic/llama judges
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-068"]
  notes: Filed by EVAL-068 per acceptance criteria (agreement <80%). The Together API key (tgp_v1_*) returned HTTP 403 during EVAL-068 — the llama-70B data used is from the existing eval-042-crossjudge sweeps, not a fresh run. Once Together access is restored, run rescore-jsonl.py with Qwen3-Coder-480B to get a third judge data point.
- id: QUALITY-003
  title: Audit which unwrap() calls are in production hot paths (triage before reduction)
  domain: reliability
  priority: P1
  effort: s
  status: done
  depends_on: ["QUALITY-002"]
  notes: "~2 hours of grep + analysis. Turns blocker #5 from a vague \"1065 unwraps\" into a concrete \"20 files to fix for production stability.\" Enables QUALITY-002 to scope to an actually-completable chunk rather than running forever. Chunking function for the blocker.
"
- id: EVAL-069
  title: Reopen EVAL-026 aggregate magnitude question under EVAL-060 fixed instrument
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-060","EVAL-063"]
  notes: ~1-2 days under live provider. ~$3-5 Anthropic judge spend. Core methodology question — the answer is informative either way. Do not defer indefinitely.

- id: INFRA-029
  title: Architecture-family deny-list for CHUMP_LESSONS_AT_SPAWN_N
  domain: infra
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-071"]
- id: EVAL-076
  title: Targeted re-run — claude-haiku-4-5 lessons-block ablation under EVAL-060 instrument
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-060","EVAL-069"]
  notes: Filed by EVAL-069 follow-up analysis 2026-04-21. Cheapest, most informative remaining experiment in Q3 backlog.
- id: PRODUCT-010
  title: Weekly product-commit floor — 1 commit/week to web/, REL-*, COMP-010, or first-run path
  domain: product
  priority: P1
  effort: s
  status: done
  notes: P1 because this is the recurring Red Letter critique — addressing a recurring issue is more valuable than one-shot fixes. Forcing function for product-vs-research velocity balance.
- id: INFRA-021
  title: Replace tiny filing PR workaround with scripts/gap-reserve.sh (atomic ID reservation)
  domain: infra
  priority: P1
  effort: s
  status: done
  depends_on: ["INFRA-020"]
  notes: P1 — supersedes the INFRA-020 stopgap. Small (~50-80 LOC bash + doc edits). Eliminates the human-protocol burden entirely; the two-PR dance was only ever a band-aid.
- id: INFRA-028
  title: bot-merge.sh silent-hang under fleet contention — add liveness diagnostics, watchdog timeout, progress banners
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: P1 because bot-merge.sh is load-bearing for the entire fleet. Silent-fail is the worst failure mode for an agent loop — the loop cannot recover without human intervention. Shipping this unblocks reliable autonomous ship cycles. Scope is explicitly diagnostic-first; no behavior change to the happy path. Dogfoods itself — the first agent to ship this will have used the manual-fallback path in CLAUDE.md to do so.

- id: INFRA-014
  title: Duplicate-ID pre-commit guard — block insert of recycled gap IDs
  domain: infra
  priority: P1
  effort: s
  status: done
- id: PRODUCT-011
  title: Competition analysis — survey Goose/Cursor/Cline/Aider/Claude Desktop/Open WebUI for PWA rebuild inspiration
  domain: product
  priority: P1
  effort: s
  status: done
  notes: "Red Letter #1/#2/#3 all flagged zero product velocity. Must land before PRODUCT-012 rebuild spike to prevent another framework misfire."
- id: PRODUCT-018
  title: Competitive matrix + one-sentence wedge vs Cursor / Cline / Aider / Devin
  domain: product
  priority: P1
  effort: s
  status: open
  notes: Human GTM reviewer (if any) starts from this doc, not a blank page.
- id: PRODUCT-019
  title: Monetization hypothesis — top 2 options with kill criteria
  domain: product
  priority: P1
  effort: s
  status: open
  depends_on: ["PRODUCT-018"]
  notes: Kill criterion matters more than the revenue projection.
- id: INFRA-051
  title: Enrich lease JSON with agent health signals (heartbeat, last commit, disk usage)
  domain: infra
  priority: P1
  effort: s
  status: open
- id: INFRA-052
  title: Queue health monitor — hourly check for blocked PRs and stalled agents
  domain: infra
  priority: P1
  effort: s
  status: open
  depends_on: ["INFRA-051"]
- id: QUALITY-004
  title: Module removal decision — Memory, Executive Function, Metacognition
  domain: quality
  priority: P1
  effort: s
  status: done
  notes: "Clarifies Q2 scope: adds 2–3 weeks if removals needed, or pivots to better instrument."
- id: INFRA-050
  title: First crate publishing test — validate release-plz automation
  domain: infra
  priority: P1
  effort: s
  status: done
  depends_on: ["INFRA-048"]
  notes: "P1: validates the end-to-end publishing pipeline before real publishes in INFRA-051+."
- id: INFRA-049
  title: CI dry-run gate for crate publishing (block on test failure)
  domain: infra
  priority: P1
  effort: s
  status: done
  depends_on: ["INFRA-048"]
  notes: "Gating ensures no broken crates ship. Next: INFRA-050 (test first crate publish).
"
- id: INFRA-064
  title: Fix gaps.yaml duplicate-field corruption from merge collisions
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: "Root cause is that PRs adding gap entries by inserting a new `- id:` block immediately above an existing entry's body — combined with subsequent rebases that tail-append conflicting tails — silently detach bodies from headers. INFRA-052's resolve-gaps-conflict.py only handles the pure tail-append case, not the in-place insertion variant. Long-term mitigation: enforce that gap entries are always tail-appended (never inserted in the middle), and add a YAML lint to pre-commit that runs serde_yaml-strict parsing.
"
- id: INFRA-066
  title: CI guard — fail PR if title implies gap close but gaps.yaml still open
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: Filed by QUALITY-005 audit. Without this guard the audit has to re-run weekly. Cheap to implement — a single shell check in an existing workflow + the bypass label.

- id: EVAL-084
  title: "EVAL-063 re-aggregate using only scorer=='llm_judge' rows"
  domain: eval
  priority: P1
  effort: s
  status: done
  depends_on: ["EVAL-083"]
  notes: Pure aggregation work — no new sweep needed. ~2-3 hours including doc. Filed by EVAL-083 audit.

- id: INFRA-070
  title: "chump gap reserve: silent ID collision when DB and gaps.yaml have drifted"
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: "Suggested fix: have `reserve` consult both the YAML max and the counter row max, taking the maximum of both. Alternative: have `reserve` call `import_from_yaml` first (cheap — INSERT OR IGNORE). Filed by INFRA-042 author after DOC-005 Phase 0 subagent (PR #537) flagged it. Patched locally via direct sqlite UPDATE; no upstream fix yet.
"
- id: INFRA-072
  title: code-reviewer-agent.sh awk regex SIGPIPE — broke auto-merge on every src/* PR
  domain: infra
  priority: P1
  effort: s
  status: done
  notes: "Two-line fix in code-reviewer-agent.sh + a new scripts/test-code-reviewer-agent.sh covering the regression. The other latent SIGPIPE candidates (line 173 head -c 80000, line 269 grep | head -1) were not the cause for PR #542 (diff was 17KB; the API response was a single verdict line) but remain theoretically exposed for future big-PR or chatty-API edge cases. Left for a follow-up if they bite.
"
- id: INFRA-075
  title: Duplicate-ID guard missed same-day INFRA-073 collision — audit and fix guard scope
  domain: infra
  priority: P1
  effort: s
  status: open
- id: EVAL-087
  title: Evaluation-awareness literature invalidates A/B trust — reframe RESEARCH-026 to P1
  domain: eval
  priority: P1
  effort: s
  status: open
- id: INFRA-078
  title: Duplicate-ID pre-commit guard fires on pre-existing dups, training bypass habit
  domain: infra
  priority: P1
  effort: s
  status: open
- id: INFRA-092
  title: fix Phase 3 cross-subdir Python parents+SCRIPT_DIR refs
  domain: infra
  priority: P1
  effort: s
  status: open
- id: INFRA-093
  title: fix Phase 3 cross-subdir Python parents+SCRIPT_DIR refs (re-file)
  domain: infra
  priority: P1
  effort: s
  status: open
- id: EVAL-092
  title: provider-matrix harness — multi-provider chump-local dispatch bake-off across env-configured backends
  domain: eval
  priority: P1
  effort: s
  status: done
  notes: "closed_pr=601 (renumbered from EVAL-089 to resolve collision with PR #558)"
- id: AUTO-002
  title: Planner → Executor → Verifier loop (core autonomy)
  domain: autonomy
  priority: P1
  effort: xl
  status: done
  depends_on: ["AUTO-001"]
- id: AUTO-013
  title: Chump-orchestrator mode — dogfood meta-loop for self-dispatching
  domain: auto
  priority: P1
  effort: xl
  status: done
  depends_on: ["PRODUCT-006","MEM-006"]
  notes: "~10 working days MVP after design lands. Hardest unknown: gap mis-classification at scale; MVP mitigation = auto_dispatch_ok tag on gaps before orchestrator picks them.
"
- id: FLEET-004a
  title: Ambient event stream — ambient.jsonl format + emit helpers
  domain: fleet
  priority: P1
  effort: xs
  status: done
- id: FLEET-004b
  title: Passive emission — git post-commit hook appends to ambient stream
  domain: fleet
  priority: P1
  effort: xs
  status: done
  depends_on: ["FLEET-004a"]
- id: FLEET-004c
  title: Passive emission — Claude Code PostToolUse hooks for file edits
  domain: fleet
  priority: P1
  effort: xs
  status: done
  depends_on: ["FLEET-004a"]
- id: FLEET-004d
  title: Context injection — CLAUDE.md reads ambient stream at session start
  domain: fleet
  priority: P1
  effort: xs
  status: done
  depends_on: ["FLEET-004a"]
- id: INFRA-005
  title: Fix pre-push auto-merge guard for recreated branches
  domain: infra
  priority: P1
  effort: xs
  status: done
  notes: One-line jq fix in scripts/git-hooks/pre-push line ~42. No Rust changes.
- id: INFRA-CI-DISKSPACE
  title: "CI: free pre-installed SDKs to stop rustc-LLVM 'no space left on device'"
  domain: infra
  priority: P1
  effort: xs
  status: done
- id: INFRA-016
  title: Harness timeout hardening — prevent vllm-mlx Metal crash trigger (Chump-side mitigation for INFRA-006)
  domain: infra
  priority: P1
  effort: xs
  status: done
  notes: "Scope bounded deliberately — the Python driver scripts with `timeout: int = 60` targets (run-cross-session-driver, run-longitudinal-driver, run-real-lessons-driver) are calling *cloud* APIs (Anthropic/Together), which don't suffer the Metal crash. Only paths that can hit a local vllm-mlx server needed the bump. docs/eval/EVAL-060-methodology-fix.md:151 is a historical command record and was left untouched.
"
- id: INFRA-019
  title: Frozen-worktree target/ purge + AGENT_LOOP anti-stomp protocol
  domain: infra
  priority: P1
  effort: xs
  status: done
  notes: "Replaces PR #337 (closed dirty). INFRA-017 ID was hijacked three ways on main during the stomp incident."
- id: INFRA-037
  title: "Branch protection: enforce required CI checks (failing PRs are merging to main)"
  domain: infra
  priority: P1
  effort: xs
  status: done
- id: INFRA-048
  title: "Queue driver — refresh oldest BEHIND auto-merge PR so branch protection doesn't strand the train"
  domain: infra
  priority: P1
  effort: xs
  status: done
  notes: "INFRA-046/047 are unrelated (Crate audit, Dependency modernization) and are in flight as PRs #493 / #496. INFRA-048 is the next free ID. The proper long-term fix is to enable GitHub's actual merge queue (`merge_queue` in branch protection); this driver is the cheap interim that survives whether or not the queue ever gets enabled.
"
- id: INFRA-BOT-MERGE-HEREDOC
  title: bot-merge.sh heredoc backtick parse bug blocks auto-merge arming
  domain: infra
  priority: P1
  effort: xs
  status: done
  notes: "Root cause is a well-known bash quirk — `$(cat <<'EOF' ... EOF)` is not safe for heredoc bodies containing backticks, even when the delimiter is single-quoted. Prefer `printf -v` or a temp-file round-trip for any multiline string containing literal backticks.
"
- id: INFRA-BELIEF-STATE-CLEANUP
  title: Remove deleted chump-belief-state crate from publish pipeline
  domain: infra
  priority: P1
  effort: xs
  status: done
  depends_on: ["REMOVAL-003"]
  notes: "Follow-up cleanup after REMOVAL-003. Found while investigating why PR #496 (INFRA-047) was unarmed in the merge queue. The CI pre-flight gate (INFRA-CHOKE, 2026-04-24) correctly refused to arm auto-merge — this fix restores the `dry-run` check to green.
"
- id: INFRA-QUEUE-DRIVER-PERMS
  title: "queue-driver workflow needs contents:write to call updatePullRequestBranch"
  domain: infra
  priority: P1
  effort: xs
  status: done
  depends_on: ["INFRA-048"]
  notes: Found while unsticking the 2026-04-24 queue (11 PRs armed, strict up-to-date rule, main advancing every ~15 min). Manual `gh pr update-branch` (user PAT) works fine; only the workflow token was blocked.

- id: INFRA-QUEUE-DRIVER-APP-TOKEN
  title: queue-driver must push via GitHub App token, not GITHUB_TOKEN (anti-loop rule)
  domain: infra
  priority: P1
  effort: xs
  status: done
  depends_on: ["INFRA-048","INFRA-QUEUE-DRIVER-PERMS"]
  notes: "Secrets QUEUE_DRIVER_APP_ID and QUEUE_DRIVER_APP_PRIVATE_KEY hold the App credentials; App has Contents:write + Pull-requests:write on repairman29/chump only. The App token is minted per workflow run with a 1-hour TTL so no long-lived PAT exposure. If the App is ever uninstalled or the key rotated, the workflow fails loud at the create-github-app-token step — no silent degradation.
"
- id: INFRA-058
  title: World-Class Roadmap — file 5-milestone dev workflow upgrade plan
  domain: infra
  priority: P1
  effort: xs
  status: done
  notes: "Each milestone's retirement-of-old-system step must be ticked before the next starts. Sequence is M1 → M2 → M3 (M3 needs M2, M2 needs M1); M4 and M5 can run parallel with M3.
"
- id: INFRA-068
  title: Doc flip — chump gap is canonical, gaps.yaml demoted to regenerated mirror
  domain: infra
  priority: P1
  effort: xs
  status: done
  depends_on: ["INFRA-059"]
- id: INFRA-073
  title: Gap-closure hygiene audit — close 8 OPEN-BUT-LANDED gaps
  domain: infra
  priority: P1
  effort: xs
  status: open
- id: DOC-009
  title: WORK_QUEUE.md stale — priority and status drift misleads agents on active P0 decisions
  domain: doc
  priority: P1
  effort: xs
  status: done
- id: INFRA-080
  title: gap-reserve.sh outputs unpadded ID (e.g. EVAL-88 instead of EVAL-088)
  domain: infra
  priority: P1
  effort: xs
  status: open
- id: INFRA-097
  title: dispatch prompt starting with --- breaks claude -p arg parsing
  domain: infra
  priority: P1
  effort: xs
  status: open
- id: COG-003
  title: Adaptive regime transitions — learned threshold tuning
  domain: consciousness
  priority: P2
  effort: l
  status: done
  depends_on: ["COG-001"]
- id: MEM-002
  title: Memory curation — confidence decay, deduplication, episodic summarization
  domain: memory
  priority: P2
  effort: l
  status: done
  notes: "DONE: memory_curate() in memory_db.rs: (1) confidence decay -0.01 for unverified memories older than 7 days; (2) exact-content deduplication within each memory_type (keep highest-confidence copy via ROW_NUMBER window function); FTS5 rebuilt after dedup. CurateResult{decayed, deduped} returned. 2 unit tests covering decay and dedup. OPEN: (3) LLM-based episodic cluster summarization (requires agent call).
"
- id: EVAL-003
  title: Golden trajectory tests — multi-turn replay against saved conversations
  domain: eval
  priority: P2
  effort: l
  status: done
  depends_on: ["EVAL-001"]
- id: EVAL-002
  title: LLM-as-judge response quality scoring for eval runs
  domain: eval
  priority: P2
  effort: l
  status: done
  depends_on: ["EVAL-001"]
- id: EVAL-019
  title: Cross-session continuity A/B — do new sessions resume context
  domain: eval
  priority: P2
  effort: l
  status: done
  depends_on: ["EVAL-018"]
  notes: TEST-CAT-J.
- id: AUTO-008
  title: Task decomposition — large tasks split into verified subtasks
  domain: autonomy
  priority: P2
  effort: l
  status: done
  depends_on: ["AUTO-002"]
- id: ACP-003
  title: Real-editor integration tests — Zed and JetBrains CI
  domain: acp
  priority: P2
  effort: l
  status: done
  notes: "Heavy CI setup (JDK + JetBrains gateway). Realistic estimate: 2-4 weeks."
- id: FLEET-011
  title: Work decomposition heuristics & learning — agent learns when to break tasks
  domain: fleet
  priority: P2
  effort: l
  status: open
  depends_on: ["FLEET-008","FLEET-010"]
  notes: "Connects to EVAL-030 (task-class-aware lessons): decomposition heuristics + capability matching + lessons gating are three parts of task-aware execution. Large effort; consider staging in two quarters (heuristics Q4, learning Q1 2027)."
- id: INFRA-003
  title: Multimodal in-process inference — implement after RFC-mistralrs-multimodal Accepted
  domain: infra
  priority: P2
  effort: l
  status: deferred
  notes: Unblock by first accepting the RFC.
- id: COG-034
  title: "Counterfactual simulation — Pearl's Ladder rung 3"
  domain: consciousness
  priority: P2
  effort: l
  status: done
  depends_on: ["COG-004","MEM-003"]
- id: COG-012
  title: ASI telemetry — token log-probabilities + resource spikes in reflection
  domain: consciousness
  priority: P2
  effort: l
  status: done
- id: COG-013
  title: Intrinsic alignment override — contract-proof refusal of unsafe requests
  domain: consciousness
  priority: P2
  effort: l
  status: done
  depends_on: ["AUTO-001","AUTO-005"]
- id: QUALITY-001
  title: unwrap() audit — replace panics with graceful errors in production paths
  domain: reliability
  priority: P2
  effort: l
  status: done
  notes: "Effort is \"l\" because there are ~900 sites but most are in tests or genuinely safe (Vec::new().unwrap() type patterns). A realistic P2 pass focuses on the ~50 highest-blast-radius sites and gets the production-path count down to near-zero. The full audit can be incremental across multiple PRs.
"
- id: EVAL-031
  title: Search-Augmented Reasoning patterns — AutoRefine + policy trajectories evaluation
  domain: eval
  priority: P2
  effort: l
  status: done
  depends_on: ["MEM-005"]
  notes: "Reference paper: AutoRefine (https://openreview.net/forum?id=rBlWKIUQey). ~1 week of literature reading + small evaluation. Could decide to defer if the value isn't clear at Chump scale (we don't currently have multi-hop QA as a primary use case).
"
- id: EVAL-034
  title: Memory retrieval evaluation — multi-hop QA with SAKE comparison
  domain: eval
  priority: P2
  effort: l
  status: done
  depends_on: ["EVAL-027","MEM-005"]
  notes: Fixture authoring ~3 days, code ~2 days, sweep ~1 hour. Cost ~$5.

- id: COG-024
  title: Default lessons-OFF — opt-in per-model only after measurement
  domain: cognition
  priority: P2
  effort: l
  status: done
  depends_on: ["COG-023","EVAL-027","EVAL-030"]
  notes: ~1 week including migration path + per-model re-validation sweeps. Paired with COG-023 = full production story for "Anthropic-family lessons-block policy in 2026-Q3."

- id: RESEARCH-020
  title: Ecological fixture set — 100 real-world tasks scraped from open-source GitHub issues and PRs
  domain: research
  priority: P2
  effort: l
  status: open
  depends_on: ["RESEARCH-019"]
  notes: Paper-2 foundation. Largest single-gap effort in the program (~2 weeks for fixture curation). Can partially overlap with Paper-1 work since the ecological fixtures are independent of the length-matched control.

- id: QUALITY-002
  title: Eliminate top-100 unwrap() panics in production binary — replace with graceful errors
  domain: reliability
  priority: P2
  effort: l
  status: done
- id: EVAL-065
  title: "Social Cognition graduation: n≥200/cell strict-judge sweep — resolve PRELIMINARY ceiling"
  domain: eval
  priority: P2
  effort: l
  status: open
  depends_on: ["EVAL-062"]
  notes: "CLI aligned 2026-04-22: `--n-per-cell` is implemented on run-social-cognition-ab.py (maps to internal repeats via ceil(n / filtered_task_count)). `--strict-judge` is the strict rubric from EVAL-062. Paid sweep remains backlog until budget — harness + python3.12 discipline landed first.
"
- id: DOC-002
  title: docs/ consolidation — merge clusters, archive completed evals, delete stubs (one-time cleanup)
  domain: infra
  priority: P2
  effort: l
  status: done
  depends_on: ["INFRA-009"]
  notes: "File lease widely — every phase touches docs/ which is in active contention. Coordinate in ambient before each phase. Use separate worktree per phase (doc-prune-merge, doc-prune-archive, doc-prune-howto, doc-prune-delete) so PRs are small and independently reviewable. Plan details: see conversation transcript 2026-04-20 or re-run the audit with same prompt.
"
- id: REMOVAL-002
  title: Remove surprisal_ema module — delta=0.000, no positive signal
  domain: reliability
  priority: P2
  effort: l
  status: done
  depends_on: ["REMOVAL-001"]
  notes: "Filed by REMOVAL-001 decision matrix 2026-04-21. Scope: 18 files, 866 lines deleted. Shipped PR via bot-merge.sh 2026-04-21."
- id: REMOVAL-003
  title: Remove belief_state module — delta=+0.020, no positive signal, crate complexity
  domain: reliability
  priority: P2
  effort: l
  status: done
  depends_on: ["REMOVAL-001"]
  notes: "Scope-correction 2026-04-21: effort upgraded s→m→l after audit showed 21 callers across 6 src files, not the simple crate delete the decision-matrix assumed. belief_state is load-bearing for checkpoint/restore snapshot schema, tool-scoring in tool_middleware, and /health telemetry. Any removal PR that does not rewire all 21 callsites first will fail cargo check. Suggest decomposing into sub-gaps: (a) shim each caller to no-op, (b) delete crate after shim lands, (c) clean up checkpoint schema in a follow-up with a migration note."
- id: INFRA-043
  title: Coordination system stress test
  domain: infra
  priority: P2
  effort: l
  status: open
  depends_on: ["FLEET-007"]
  notes: Validates coordination system for fleet scale. Defer until FLEET-007 basic implementation.
- id: COG-002
  title: Memory graph recall benchmark — recall@5 on multi-hop QA
  domain: consciousness
  priority: P2
  effort: m
  status: done
- id: COG-004
  title: Lesson upgrade — replace heuristic lesson extraction with causal graph output
  domain: consciousness
  priority: P2
  effort: m
  status: done
  notes: "lesson_from_graph_paths(graph, action) traverses paths_from() action node, multiplies edge strengths along each path, returns strongest path lesson + confidence. analyze_episode() builds graph first, uses graph lesson when available, falls back to heuristic. causal_confidence column added to chump_causal_lessons via ALTER TABLE migration. CausalLesson.causal_confidence: Option<f64>. persist_causal_graph_as_lessons passes Some(edge.strength). 4 new unit tests in counterfactual::tests. Section 2.5 checkbox marked.
"
- id: COG-005
  title: Perception gate — measure whether perception layer improves tool selection
  domain: consciousness
  priority: P2
  effort: m
  status: done
  depends_on: ["COG-001"]
- id: COG-006
  title: Neuromodulation gate — measure modulator adaptation vs fixed-threshold
  domain: consciousness
  priority: P2
  effort: m
  status: done
  depends_on: ["COG-001"]
- id: COG-008
  title: Upgrade reflect_heuristic → LLM-assisted reflection via delegate worker
  domain: consciousness
  priority: P2
  effort: m
  status: done
  depends_on: ["COG-007"]
- id: MEM-001
  title: Add cross-encoder reranker to final RRF retrieval output
  domain: memory
  priority: P2
  effort: m
  status: done
  depends_on: ["COG-002"]
- id: MEM-005
  title: Episode extractor — synthesise durable facts from episodes into blackboard
  domain: memory
  priority: P2
  effort: m
  status: done
  depends_on: ["MEM-004"]
- id: EVAL-045
  title: Retrieval pipeline benchmark — recall@5 on curated multi-hop QA
  domain: eval
  priority: P2
  effort: m
  status: done
  notes: Closed with COG-002. recall_benchmark_eval_003 test in memory_graph.rs runs 50-QA fixture comparing BFS vs PPR recall@5 (BFS=0.593, PPR=0.427 on synthetic data). bfs_recall() added as baseline. scripts/recall-benchmark.sh runs and appends results to docs/CONSCIOUSNESS_AB_RESULTS.md.

- id: COG-014
  title: Task-specific lessons content — replace generic block per fixture
  domain: consciousness
  priority: P2
  effort: m
  status: done
  depends_on: ["EVAL-010"]
  notes: "Recommended follow-up from cloud A/B sweep (ce4ebc0). Gated on EVAL-010 because re-running A/Bs with the same circular methodology is wasted cloud spend. Total cost when unblocked: ~$2 (one cloud sweep across perception/neuromod/reflection on haiku-4-5).
"
- id: EVAL-015
  title: Adversarial prompt-injection robustness A/B
  domain: eval
  priority: P2
  effort: m
  status: done
  notes: TEST-CAT-E. Should run BEFORE any production-default flip on reflection_injection_enabled().

- id: EVAL-016
  title: Refusal calibration A/B — false-refuse vs false-comply
  domain: eval
  priority: P2
  effort: m
  status: done
  notes: TEST-CAT-F. Critical for production deployment — over-refusal kills user trust faster than occasional false-comply.

- id: EVAL-018
  title: Memory recall A/B — does memory subsystem help on recall tasks
  domain: eval
  priority: P2
  effort: m
  status: done
  notes: TEST-CAT-I.
- id: AUTO-005
  title: Policy-based approvals — auto-allow low-risk tool approvals
  domain: autonomy
  priority: P2
  effort: m
  status: done
  notes: "chump_approval_stats table (db_pool.rs ensure_schema_extensions): tool_name, decision, risk_level, recorded_at. record_approval_stat() in tool_policy.rs inserts on every approval decision (auto_approved, human_allowed, denied, timeout). auto_approve_rate(window_days) queries last N days. tool_policy_for_stack_status() exposes auto_approve_rate_7d in /api/stack-status JSON. task_executor.rs wired at all three decision branches. 3 unit tests (record no-op, rate zeros without DB, parse_comma trim/lowercase).
"
- id: AUTO-006
  title: Autonomy conformance fixtures for key tools
  domain: autonomy
  priority: P2
  effort: m
  status: done
  depends_on: ["AUTO-003"]
  notes: "10 conformance tests in task_executor.rs::tests: (1) validation rejects missing run_cli command; (2) unapproved tool executes directly; (3) batch of two tools; (4) CHUMP_SKIP_TOOL_INPUT_VALIDATE bypass; (5-7) approval_audit_fields for patch_file (high), run_cli (low), unknown tool (medium); (8-10) approval_resolver timeout/allow/deny paths. Tests documented to note OnceLock constraint on CHUMP_TOOLS_ASK (cannot be changed mid-process in unit tests).
"
- id: AUTO-007
  title: Better task selection — dependency awareness and urgency scoring
  domain: autonomy
  priority: P2
  effort: m
  status: done
  depends_on: ["AUTO-002"]
- id: ACP-002
  title: Vision-capable model passthrough via ACP
  domain: acp
  priority: P2
  effort: m
  status: done
  notes: "flatten_prompt_blocks() encodes image+text blocks as JSON array string when CHUMP_VISION_ENABLED=1; local_openai.rs detects content.starts_with('[') and deserializes to Value::Array for OpenAI multipart messages. vision_max_image_bytes() caps images at 4MB (CHUMP_VISION_MAX_IMAGE_BYTES). All vision tests use #[serial_test::serial] to avoid env-var races.
"
- id: COMP-004b
  title: Telegram adapter via teloxide
  domain: competitive
  priority: P2
  effort: m
  status: done
  depends_on: ["COMP-004a"]
- id: COMP-004c
  title: Slack adapter via Socket Mode
  domain: competitive
  priority: P2
  effort: m
  status: done
  depends_on: ["COMP-004a"]
- id: FLEET-010
  title: Help-seeking protocol — agent requests help when blocked
  domain: fleet
  priority: P2
  effort: m
  status: open
  depends_on: ["FLEET-009"]
  notes: "Semantic question: should blocking be synchronous (agent waits) or async (agent continues, help happens in parallel)? Recommend: async for time blockers, sync for capability gaps (need the answer before proceeding)."
- id: PRODUCT-005
  title: scripts/generate-sprint-synthesis.sh — automated synthesis generation in heartbeat
  domain: product
  priority: P2
  effort: m
  status: done
- id: COG-029
  title: Typestate FSM — compile-time-provable autonomy lifecycle transitions
  domain: consciousness
  priority: P2
  effort: m
  status: done
  depends_on: ["AUTO-001"]
- id: AGT-005
  title: "LLM response streaming deltas → SSE AgentEvent::TextDelta"
  domain: agent
  priority: P2
  effort: m
  status: done
  depends_on: ["AGT-002"]
- id: COMP-008
  title: Recipes abstraction — package shareable workflows with declared deps + params
  domain: completeness
  priority: P2
  effort: m
  status: done
  notes: "First task: read https://goose-docs.ai/docs/guides/recipes/recipe-reference and decide whether to adopt their schema verbatim (cross-tool portability win) or adapt for Chump-specific concepts. Recommend adopting verbatim where possible — same standards story as AGENTS.md (COMP-007). Effort estimate is ~3-5 days for schema + runner + first 2-3 packaged recipes.
"
- id: COMP-009
  title: Extend Chump MCP-server catalog from 3 to 6+
  domain: completeness
  priority: P2
  effort: m
  status: done
  notes: Existing chump-mcp-github / -adb / -tavily are the template; new servers follow the same pattern. ~3-5 days per server. Could ship as 3 separate small PRs to keep blast radius low. Cross-agent benchmarking gap (FRONTIER-007 below) depends on chump-mcp-eval existing.

- id: FRONTIER-007
  title: "Cross-agent benchmarking — apply Chump's eval harness to goose, Aider, Claude Code"
  domain: frontier
  priority: P2
  effort: m
  status: done
  depends_on: ["COMP-009"]
  notes: "Significant strategic value: makes Chump THE benchmark for the local-agent space. Cost ~$10-20 cloud per benchmark run (4 agents × 3 fixtures × n=50 × 2 cells = 1200 trials × cross-family judges). Wall ~3-4 hours per agent (some are slower than others).
"
- id: EVAL-030-VALIDATE
  title: Empirically validate EVAL-030 task-class-aware lessons via A/B harness
  domain: eval
  priority: P2
  effort: m
  status: done
  depends_on: ["EVAL-030"]
  notes: "Likely path: spawn the chump binary in a thin subprocess wrapper that builds the system prompt via the actual assembler, or expose a `chump --assemble-prompt` debug subcommand the harness can call. Cost ~$2 cloud + ~1 day harness work.
"
- id: COMP-014
  title: Cost ledger broken across ALL providers — recorded $0.00 across 4621 calls today
  domain: completeness
  priority: P2
  effort: m
  status: done
  notes: ~1 day. Was filed as P3 / "Together-only" originally; rescoped P2 after audit revealed Anthropic recording also broken. Blocks INFRA-COST-CEILING.

- id: EVAL-032
  title: Perception layer ablation A/B — does chump-perception help, hurt, or noise?
  domain: eval
  priority: P2
  effort: m
  status: done
  notes: Add --bypass-perception flag to harness (~1 day). Sweep ~$3 cloud, 1 hour wall.

- id: EVAL-033
  title: Attention mitigation A/B — three candidate distractor-suppression strategies
  domain: eval
  priority: P2
  effort: m
  status: done
  depends_on: ["EVAL-028"]
  notes: Cost ~$2 cloud. Wall ~2 days code + 1 hour sweep. Shipped design doc + harness --mitigation flag + control pilot n=20 + prefix-anchor partial (API load interrupted). Full sweep deferred — fixture may need to change to math/reasoning for CatAttack sensitivity. Null result documented with next-step recommendations.

- id: INFRA-FILE-LEASE
  title: File-level path leases on top of gap-level mutex
  domain: infra
  priority: P2
  effort: m
  status: done
  notes: "~1 day implementation. Most of the lease infrastructure exists; this is wiring + check + docs. Reference: scripts/gap-claim.sh, scripts/chump-commit.sh, scripts/gap-preflight.sh.
"
- id: INFRA-AGENT-ESCALATION
  title: Formal escalation pattern — when an agent is stuck, surface to human
  domain: infra
  priority: P2
  effort: m
  status: done
  notes: ~1 week. Without this, agents that hit unexpected blockers leave stranded work that needs Jeff to manually triage by reading worktree state. Key "why is Jeff still the bottleneck" failure mode.

- id: INFRA-DISPATCH-POLICY
  title: musher dispatch policy — capacity-aware, priority-ordered, dependency-aware
  domain: infra
  priority: P2
  effort: m
  status: done
  notes: "~1 week. Builds on existing musher (PR #113). Removes the manual \"Jeff decides what dispatches next\" decision from the loop.
"
- id: MEM-006
  title: Lessons-loaded-at-spawn — agents inherit prior reflection lessons on start
  domain: memory
  priority: P2
  effort: m
  status: done
  depends_on: ["COG-023","COG-024"]
  notes: ~1 week including A/B validation sweep. Closes the loop between reflection accumulation (PRODUCT-006 shipped) and reflection application (this gap). Without it, our learning system writes to nothing. Code shipped without empirical A/B — validation tracked as MEM-006-VALIDATE.

- id: MEM-007
  title: Agent context-query — "what should I know before working on gap X?"
  domain: memory
  priority: P2
  effort: m
  status: done
  depends_on: ["MEM-006"]
  notes: "~1 week. Pairs with MEM-006: MEM-006 loads lessons systemically at spawn; MEM-007 is the explicit per-gap query API. Together they close the \"what does the team know about THIS task\" loop.
"
- id: EVAL-044
  title: Multi-turn eval fixture — test cognitive layer over 8+ turn conversation
  domain: eval
  priority: P2
  effort: m
  status: done
  depends_on: ["EVAL-043"]
  notes: ~$10 cloud + 2 days fixture design. This is the "Severity 3" limitation in CONSCIOUSNESS_AB_RESULTS.md — long deferred, finally necessary for the publication push.

- id: RESEARCH-024
  title: Multi-turn degradation curve run — ship the EVAL-044 fixture against belief_state on/off × haiku/sonnet
  domain: research
  priority: P2
  effort: m
  status: open
  depends_on: ["RESEARCH-019","RESEARCH-022"]
  notes: Paper-3 foundation. Budget ~$60 cloud. Novel dimension — no prior Chump finding is multi-turn.

- id: RESEARCH-025
  title: Per-task-category human-LLM-judge kappa — extend EVAL-041 to 100 trials × 5 task categories
  domain: research
  priority: P2
  effort: m
  status: open
  depends_on: ["RESEARCH-019"]
  notes: "~40 hours of human grading + analysis. Strengthens every paper's methodology section.
"
- id: RESEARCH-028
  title: Blackboard tool-selection-mediation test — does the blackboard mediate behavior non-verbally via tool sequences?
  domain: research
  priority: P2
  effort: m
  status: open
  depends_on: ["RESEARCH-019","RESEARCH-022"]
  notes: "~\$25 cloud (Together free-tier judge where applicable). Paper-3 adjacent — multi-turn belief dynamics is belief_state-focused, but blackboard tool-mediation is a parallel mechanism-test question. REMOVAL-001 addendum (2026-04-21) recommends this gap as the decisive test for whether blackboard's \"keep\" verdict holds.
"
- id: MEM-009
  title: Reflection episode quality filtering before spawn-load
  domain: memory
  priority: P2
  effort: m
  status: done
  depends_on: ["MEM-006"]
  notes: ~1 day + $2 cloud for A/B. Risk of bad-lesson poisoning compounds as reflection DB accumulates more sessions over time.

- id: MEM-010
  title: Entity resolution accuracy A/B — linked vs unlinked multi-hop QA
  domain: memory
  priority: P2
  effort: m
  status: done
  depends_on: ["MEM-008"]
  notes: "~1 day. Silent failure mode: wrong entity links produce wrong answers with no error signal. Catches this before EVAL-034 runs.
"
- id: INFRA-AMBIENT-STREAM-SCALE
  title: Ambient stream retention policy + query performance at fleet scale
  domain: infra
  priority: P2
  effort: m
  status: done
  notes: "~1 day. Current priority is P2 because ambient stream barely fires (RL Issue #2 confirmed); fix ambient hook firing first (FLEET-004b/c are marked done but emitting nothing — investigate separately).
"
- id: EVAL-047
  title: "Attention faculty graduation: CatAttack full n=50 sweep (EVAL-028b) + CHUMP_FACULTY_MAP.md update"
  domain: eval
  priority: P2
  effort: m
  status: done
- id: EVAL-064
  title: Re-score Memory + Executive Function under EVAL-060 instrument — LLM judge n≥50/cell
  domain: eval
  priority: P2
  effort: m
  status: done
  depends_on: ["EVAL-060","EVAL-061"]
- id: INFRA-008
  title: 4h unattended precursor soak test — forcing function for 72h autonomy gate
  domain: infra
  priority: P2
  effort: m
  status: done
  depends_on: ["INFRA-007","QUALITY-002"]
  notes: Deliberate P2 — not pre-requisite work, but pre-requisite-proof work. File now so the forcing function exists in the registry. Do not start implementation until INFRA-007 and QUALITY-002 have at minimum their triage output, otherwise the soak will just fail on known preexisting issues and waste a cycle.

- id: PRODUCT-009
  title: External publication of F1-F6 empirical findings (preprint or blog post)
  domain: product
  priority: P2
  effort: m
  status: open
  notes: "~1-2 weeks for blog post option, ~4-6 weeks for preprint. No technical dependency; blocked only on writer bandwidth. Single highest-leverage single gap in the project right now per 2026-04-20 strategic review — closes the 'top-decile methodology, zero external visibility' gap. 2026-04-22 integrity fix: reopened from `status: done` because **zero** acceptance rows were satisfied (`closed_pr: TBD`, no live publication URL in FINDINGS, draft still pre-external-review). See docs/RED_LETTER.md Issue #4. Prior mistaken closure date 2026-04-20 exists only in git history.
"
- id: EVAL-071
  title: Extend F2 halluc-inflation finding to non-Anthropic frontier models
  domain: eval
  priority: P2
  effort: m
  status: done
  notes: ~2-3 days + $10-20 Together and $20-40 OpenAI/Google spend. Candidate content for PRODUCT-009 if the finding generalizes. Depends on judge calibration (EVAL-046) being trustworthy on non-Anthropic agent output.

- id: EVAL-074
  title: DeepSeek lesson-injection correctness regression root cause
  domain: eval
  priority: P2
  effort: m
  status: open
  depends_on: ["EVAL-071"]
- id: INFRA-025
  title: Update all Rust crates + publish to crates.io
  domain: infra
  priority: P2
  effort: m
  status: done
  notes: "2026-04-22: Phase 1 audit complete, CLAUDE/AGENTS hygiene added, CI dry-run workflow draft in. Remaining: real publishes, release automation., effort medium. Real value = forcing the hygiene audit + unlocking 'bots publishing products' as a capability. Biggest risk is time-sink: per-crate license/metadata/docs polish can burn a week if done maximally. Recommended slicing: Phase 1+2 + name reservation is one PR (audit + deps modernization). Phase 3 (release automation) is a second PR. Phase 4 (actual publishes) is one PR per crate, landed in topological order. Don't try to ship all of this at once — the first leaf publish teaches us what the pipeline actually needs. 2026-04-22: Phase 1 audit memo landed — docs/eval/INFRA-025-crate-publish-audit.md (gap remains open for CI dry-run gate, cargo audit/outdated, release automation, real publishes, name placeholders, CLAUDE/AGENTS hygiene)."
- id: INFRA-030
  title: "Fleet observability: musher + ambient single-pane status for unattended loops"
  domain: infra
  priority: P2
  effort: m
  status: done
  notes: Queued 2026-04-23. Keep scope read-only; do not turn this into another silent auto-healer without explicit gap.
- id: PRODUCT-014
  title: Discord intent parsing — first visible slice of the "understand and act" promise
  domain: product
  priority: P2
  effort: m
  status: done
  notes: P2 so PRODUCT-011/012/013/UX-001 ship first (PWA path is the primary North Star). This surface is secondary but closes the original brief.
- id: COG-032
  title: Lesson injection feedback loop evaluation
  domain: cognitive
  priority: P2
  effort: m
  status: open
  notes: Can run in parallel. Low cost (mostly gap execution). Results inform COG-024 default and per-gap recommendations.
- id: INFRA-054
  title: Add depends_on field to gap registry (enforce dependency ordering)
  domain: infra
  priority: P2
  effort: m
  status: open
- id: INFRA-055
  title: SQLite as primary gap store — migrate from YAML source-of-truth
  domain: infra
  priority: P2
  effort: m
  status: open
  depends_on: ["INFRA-054"]
- id: TEST-001
  title: stacked test
  domain: test
  priority: P2
  effort: m
  status: open
- id: DOC-005
  title: Doc hygiene plan — classification, automation, staged consolidation
  domain: doc
  priority: P2
  effort: m
  status: open
- id: SECURITY-002
  title: Track RUSTSEC advisories in transitive deps (rsa, rustls-webpki)
  domain: infra
  priority: P2
  effort: m
  status: open
  depends_on: ["INFRA-044"]
  notes: Filed from the INFRA-044 first dry run. Do not close this gap by silencing cargo-audit — the findings doc already records the real advisories. Re-evaluate weekly when the audit CI runs.

- id: INFRA-061
  title: M3 — Stacked-PR dispatcher (--stack-on for related work)
  domain: infra
  priority: P2
  effort: m
  status: done
  depends_on: ["INFRA-058","INFRA-059","INFRA-060"]
- id: INFRA-067
  title: Repo hygiene plan (scripts/, crates+src/, top-level, workflows)
  domain: infra
  priority: P2
  effort: m
  status: done
- id: INFRA-081
  title: Lease coordination misses semantic collisions on the same problem space
  domain: infra
  priority: P2
  effort: m
  status: open
- id: INFRA-086
  title: chump pr-stack per-session view
  domain: infra
  priority: P2
  effort: m
  status: open
- id: INFRA-091
  title: Phase 3 follow-up — fix relative-path scripts broken by reorg
  domain: infra
  priority: P2
  effort: m
  status: open
- id: INFRA-094
  title: x
  domain: infra
  priority: P2
  effort: m
  status: open
- id: INFRA-095
  title: x
  domain: infra
  priority: P2
  effort: m
  status: open
- id: INFRA-096
  title: x
  domain: infra
  priority: P2
  effort: m
  status: open
- id: COG-009b
  title: Wire actual tool_hint signal source from BatchOutcome into orchestrator
  domain: consciousness
  priority: P2
  effort: s
  status: done
  depends_on: ["COG-009"]
- id: COG-010
  title: Integration test for reflection feedback flywheel
  domain: consciousness
  priority: P2
  effort: s
  status: done
  depends_on: ["COG-007"]
- id: COG-011b
  title: LLM-judge scoring for the reflection A/B
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["COG-011"]
- id: EVAL-004
  title: Wire async LLM-as-judge into battle_qa + report per-category score
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-002"]
- id: COG-015
  title: Entity-keyed blackboard injection in prompt assembler (Phase 8.2)
  domain: consciousness
  priority: P2
  effort: s
  status: done
  depends_on: ["MEM-005"]
- id: EVAL-017
  title: Real tool integration A/B — do lessons help when tools EXIST
  domain: eval
  priority: P2
  effort: s
  status: done
  notes: TEST-CAT-G. scripts/ab-harness/run.sh already supports the chump backend; just needs v2 scoring wired in.

- id: AUTO-009
  title: Memory linkage — project playbooks auto-attached to task context
  domain: autonomy
  priority: P2
  effort: s
  status: done
  notes: "fetch_task_memory_context() in autonomy_loop.rs: keyword_search by task title + repo, top 3 results injected into exec_prompt \"Relevant memory\" block. Graceful no-op when memory DB unavailable (Err → empty string).
"
- id: ACP-004
  title: Thinking streaming for reasoning models via ACP
  domain: acp
  priority: P2
  effort: s
  status: done
  notes: "ThinkStreamState in local_openai.rs routes <think> content to AgentEvent::ThinkingDelta → SessionUpdate::Thinking. ACP.md documents the thinking event type (mid-stream + TurnComplete sources).
"
- id: COMP-004a
  title: Extract MessagingAdapter trait from Discord adapter
  domain: competitive
  priority: P2
  effort: s
  status: done
- id: COMP-005a
  title: PWA image-paste → ContentBlock multipart routing
  domain: competitive
  priority: P2
  effort: s
  status: done
  depends_on: ["ACP-002"]
- id: FLEET-012
  title: Blocker detection & timeout handling — agent recognizes stuck state
  domain: fleet
  priority: P2
  effort: s
  status: open
  depends_on: ["FLEET-010"]
  notes: Pairs with EVAL-030 (task-class awareness). Blocker detection is the trigger for help-seeking. Resource monitoring is the infrastructure (need metrics from agent).
- id: FLEET-013
  title: Tailscale integration & agent discovery — agents find each other on VPN
  domain: fleet
  priority: P2
  effort: s
  status: open
  depends_on: ["FLEET-006","FLEET-007"]
  notes: "Air-gapped ready: Tailscale requires initial handshake but then works offline. Alternative: manual IP-based discovery (simpler but less flexible). Recommend Tailscale for the full vision (also enables remote troubleshooting)."
- id: REL-003
  title: Patch crate — fork or replace if upstream abandons panic-on-malformed
  domain: reliability
  priority: P2
  effort: s
  status: done
- id: INFRA-CI-TEST-SPLIT
  title: Split monolithic CI test job into fast unit + gated E2E
  domain: infra
  priority: P2
  effort: s
  status: done
- id: INFRA-001a
  title: Observability — count side effects from rolled-back speculative branches
  domain: infra
  priority: P2
  effort: s
  status: done
- id: INFRA-002
  title: Sandbox hardening — command allowlist, disk budget, CI git requirements
  domain: infra
  priority: P2
  effort: s
  status: done
  notes: "CHUMP_SANDBOX_ALLOWLIST: case-insensitive substring match; rejects non-matching commands with clear Err. CHUMP_SANDBOX_DISK_BUDGET_MB: default 500; post-run du -sk check; warning logged + surfaced in tool output. 4 serial tests (env var isolation). WASM_TOOLS.md: new \"Sandbox prerequisites\" section documenting CHUMP_SANDBOX_ENABLED, all env vars, Mac vs CI differences, git requirements. Note: CI teardown job remains a nice-to-have but acceptance criteria met.
"
- id: INFRA-WORKTREE-STAGING
  title: Pre-staged WIP from other agents leaks into commits in shared worktree
  domain: infra
  priority: P2
  effort: s
  status: done
- id: PRODUCT-006
  title: harvest-synthesis-lessons.sh — mine synthesis operational rules into lessons layer
  domain: product
  priority: P2
  effort: s
  status: done
  depends_on: ["PRODUCT-005"]
- id: AUTO-011
  title: Epistemic stress metric — frustration-triggered strategy pivot
  domain: autonomy
  priority: P2
  effort: s
  status: done
  depends_on: ["AUTO-006"]
- id: AUTO-012
  title: DelegatePreProcessor — compress heavy tool output via worker model
  domain: autonomy
  priority: P2
  effort: s
  status: done
  depends_on: ["AUTO-011"]
- id: MEM-011
  title: Causal graph edge obsolescence — invalidate stale causal chains
  domain: memory
  priority: P2
  effort: s
  status: done
  depends_on: ["MEM-002","COG-004"]
- id: AGT-003
  title: "Per-tool execution timeout with tokio::time::timeout"
  domain: agent
  priority: P2
  effort: s
  status: done
- id: AGT-006
  title: Wire NewMessageSensor into platform_router — mid-turn interrupt
  domain: agent
  priority: P2
  effort: s
  status: done
  depends_on: ["SENSE-001","AGT-002","AGT-004"]
- id: EVAL-024
  title: "Multi-turn A/B re-run with v2 multi-axis scoring (compose with PR #73)"
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-012"]
  notes: "Likely a small Python wrapper that walks the multi-turn jsonl per-turn and applies rescore-with-v2.py logic. ~50 LOC. Cheap to run since the multi-turn fixture is only 10 tasks and the conversations are already executed (just re-scoring existing logs). Cost: \$0 (re-scoring only).
"
- id: EVAL-028
  title: CatAttack adversarial robustness sweep on Chump fixtures
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-026"]
  notes: "Lift adversarial triggers verbatim from CatAttack paper Table 2 (no need to invent). Implementation: add --distractor flag to run-cloud-v2.py that prepends a chosen trigger to args.prompt before sending. Reuse existing fixtures unchanged. Cost ~\$2 cloud. Reference paper: https://arxiv.org/abs/2503.01781
"
- id: EVAL-029
  title: Investigate which neuromod tasks drive cross-architecture harm signal
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-025","EVAL-026"]
  notes: "Pure data analysis on existing jsonl logs — no new sweep needed. Walk per-trial rows in logs/ab/eval-025-*neuromod*.jsonl and logs/ab/eval-026-*neuromod*.jsonl, group by task_id, compute A-B deltas. ~50 LOC Python. Cost: \$0. Wall: ~1hr.
"
- id: COMP-007
  title: AGENTS.md interop standard adoption — supplement or replace CLAUDE.md
  domain: completeness
  priority: P2
  effort: s
  status: done
  notes: "Reference: https://aaif.io/ — AGENTS.md is one of three founding projects. Spec: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation Implementation likely ~1 day: add AGENTS.md reader to prompt_assembler, update install scripts, document precedence.
"
- id: COG-020
  title: DeepMind 10-faculty Chump architecture map — taxonomy alignment doc
  domain: cognition
  priority: P2
  effort: s
  status: done
  notes: "~1 day docs exercise. Reference: https://storage.googleapis.com/deepmind-media/DeepMind.com/Blog/measuring-progress-toward-agi/measuring-progress-toward-agi-a-cognitive-framework.pdf Should call out explicitly: Attention faculty has no monitoring today (gap → EVAL-028 CatAttack), Social Cognition faculty maps to tool approval / ASK_JEFF flow (untested at scale).
"
- id: COMP-010
  title: Brew formula + signed installer — `brew install chump` adoption path
  domain: completeness
  priority: P2
  effort: s
  status: done
  notes: "~1-2 days for the brew formula + tap setup. ~2-3 more days for cross-platform release pipeline + signing. Total effort ~1 week. Reference: https://github.com/block/homebrew-tap or similar.
"
- id: COMP-011a
  title: Adversary-mode-lite — static-rules runtime tool-action monitor
  domain: completeness
  priority: P2
  effort: s
  status: done
  notes: "Static rules cover ~80% of accident-class harms; LLM reviewer (COMP-011b) covers context-aware \"this is suspicious for THIS task\" cases. Ship 011a first — bigger immediate safety win for less effort. Reference goose's default rules at https://goose-docs.ai/docs/guides/security/adversary-mode/
"
- id: COMP-013
  title: MCPwned / DNS rebinding mitigation audit on Chump MCP servers
  domain: completeness
  priority: P2
  effort: s
  status: done
  notes: "~2-4 hour audit + any required patches. Reference: search \"MCPwned DNS rebinding\" — exploit class described in industry security coverage 2026-Q1. Block your COMP-009 release on this audit.
"
- id: EVAL-035
  title: Belief-state ablation A/B — is belief_state.rs net-contributing?
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-030"]
  notes: Add --bypass-belief-state flag. Cost ~$2. Wall ~2 days.

- id: EVAL-038
  title: Ambiguous-prompt A/B — Social Cognition validation of ASK_JEFF policy
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-029"]
  notes: Fixture authoring ~2 days. Cost ~$3.

- id: INFRA-BOT-MERGE-LOCK
  title: bot-merge.sh marks worktree shipped; chump-commit.sh refuses to commit after
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["INFRA-WORKTREE-REAPER"]
  notes: "~half day. Small change, big multi-agent discipline win. Reference: scripts/bot-merge.sh, scripts/chump-commit.sh.
"
- id: MEM-006-VALIDATE
  title: Empirical A/B for spawn-loaded lessons (cell A vs cell B, n=50 reflection)
  domain: memory
  priority: P2
  effort: s
  status: done
  depends_on: ["MEM-006"]
  notes: ~3 days once a local-Chump-dispatch path exists. Pre-requisite work lives in the chump-orchestrator step 4-5 territory.

- id: INFRA-COST-CEILING
  title: Per-session cloud spend cap — hard ceiling + soft warn
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["COMP-014"]
  notes: ~3 days. Pairs with INFRA-AGENT-ESCALATION for the soft-warn surfacing path.

- id: INFRA-WORKTREE-REAPER-FIX
  title: stale-worktree-reaper missed long-running background bash — broke EVAL-026c sweep
  domain: infra
  priority: P2
  effort: s
  status: done
  notes: "~3 hours. Tactical: until this fix lands, when in doubt about reaping a worktree, check `lsof +D <worktree-path>` first or just grep `ps -ef` for the worktree path. The auto-cron is conservative enough (only reaps merged-and-remote-deleted branches) that this bug won't hit there — only manual invocations are at risk.
"
- id: INFRA-BOT-MERGE-UNTRACKED
  title: bot-merge.sh pushes wrong diff when untracked files present in worktree
  domain: infra
  priority: P2
  effort: s
  status: done
  notes: "~2 hours including test. Caught during PR #158 (AUTO-013 step 5) ship. The new files were the new test fixtures + reflect.rs restoration; they were genuinely needed but bot-merge dropped them.
"
- id: INFRA-CODEREVIEWER-FALSE-POSITIVES
  title: Code-reviewer agent false-positives on existing dependencies
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["INFRA-AGENT-CODEREVIEW"]
  notes: ~3 hours. Lower-priority than getting the merge queue UI flipped, but adds up — every false dismissal = ~30s of attention.

- id: INFRA-DISPATCH-FAULT-INJECTION
  title: Fault-injection test mode for chump-orchestrator dispatch
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["INFRA-CHUMP-API-RETRY"]
  notes: ~3 hours. Important for hardening before AUTO-013-A (lesson-aware dispatch) builds on top.

- id: RESEARCH-026
  title: Observer-effect / evaluation-framing sandbagging check
  domain: research
  priority: P2
  effort: s
  status: open
  depends_on: ["RESEARCH-019"]
  notes: "~$20 cloud. Paper-1 credibility booster. If the result is null, it strengthens the publishable finding by ruling out a standard reviewer concern. 2026-04-21: paired formal fixture (reflection_tasks_formal_paired_v1.json), run-observer-effect-ab.sh wiring to run-cloud-v2.py (--n-per-cell, --out-dir), analysis helper analyze-observer-effect.py, result shell docs/eval/RESEARCH-026-observer-effect.md, FINDINGS index row (pending sweep), and scripts/test-research-026-preflight.sh merged to main in PR #400 (2026-04-21). Human pilot validation gate signed off (Jeff Adkins 2026-04-21); 50-task casual fixture shipped; harness smoke (n=2 haiku pilot) passed 2026-04-21 — see docs/eval/RESEARCH-026-observer-effect.md § Harness smoke. Remaining acceptance: preregistered 400-trial cloud sweep, Wilson analysis in FINDINGS, then close this gap with closed_commit. Operating stance (2026-04-21): keep status open and backlog the paid full sweep until a paper or external-credibility sprint — it is not required to inform ordinary engineering. Harness + CI preflight + human validation gate + smoke are treated as sufficient to keep building; schedule the ~\$15–\$20 sweep when publication claims need the preregistered Wilson row.
"
- id: COG-027
  title: Task-aware ask-vs-execute policy — gate clarifying questions on task type
  domain: cognition
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-030"]
  notes: "~1 day. Pairs with EVAL-030's existing task-class detector. The ask- vs-execute trade-off is the same mechanism EVAL-029 diagnosed for neuromod — worth fixing at the same time.
"
- id: MEM-008
  title: Multi-hop QA fixture spec — define what multi-hop means before building
  domain: memory
  priority: P2
  effort: s
  status: done
  notes: ~0.5 days. Cheap design work that prevents an expensive ($10+) EVAL from being uninterpretable. Should precede EVAL-034.

- id: EVAL-050
  title: "Social Cognition graduation: run EVAL-038 ask-vs-guess fixture + update faculty map"
  domain: eval
  priority: P2
  effort: s
  status: done
- id: EVAL-051
  title: Run EVAL-047 + EVAL-050 full sweeps — produce real Attention and Social Cognition faculty verdicts
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-047","EVAL-050"]
- id: EVAL-052
  title: CatAttack hallucination sweep n=50 — confirm or refute Attention faculty distractor-halluc signal
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-051"]
- id: EVAL-054
  title: Perception ablation sweep n=50 — validate CHUMP_BYPASS_PERCEPTION flag via binary-mode harness
  domain: eval
  priority: P2
  effort: s
  status: done
  notes: "n=50/cell sweep complete. Cell A acc=0.980 [0.895, 0.996], Cell B acc=0.940 [0.838, 0.979], delta=-0.040, CIs overlap. Verdict: COVERED+VALIDATED(NULL). Architecture caveat: direct-API harness measures noise floor. All acceptance criteria met."
- id: EVAL-055
  title: Social Cognition full sweep n>=50/cell — upgrade from PRELIMINARY to research-grade
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-050"]
  notes: "n=50/cell sweep complete (300 total trials). ambiguous/procedural H1 confirmed (non-overlapping CIs, delta=+0.300). ambiguous/static H1 inconclusive (CIs overlap by narrow margin, delta=+0.200). clear/dynamic H2 holds. Verdict: COVERED+VALIDATED(PRELIMINARY) — heuristic scorer conservatism limits confidence on ambiguous/static. LLM judge or n>=100/cell recommended for definitive verdict."
- id: EVAL-056
  title: Memory ablation — ship CHUMP_BYPASS_SPAWN_LESSONS flag and run binary-mode sweep
  domain: eval
  priority: P2
  effort: s
  status: done
  notes: "Flag shipped and wired. n=30/cell binary-mode sweep complete. Delta=+0.100 with overlapping CIs — NO SIGNAL. Binary-mode noise floor (~90% exit-code-1 failures) limits interpretability per RESEARCH_INTEGRITY.md. Verdict: COVERED+VALIDATED(NULL)."
- id: EVAL-057
  title: Social Cognition LLM-judge sweep — upgrade heuristic scorer to resolve ambiguous/static CIs
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-055"]
  notes: "LLM-judge sweep complete (300 agent + 300 judge calls, 2026-04-20). Near-ceiling effect: both ambiguous cells 1.000 (A) vs 0.940 (B); CIs overlap due to ceiling compression (A=[0.929,1.000] vs B=[0.838,0.979]). Judge too liberal on clear/dynamic (A=0.860 vs B=0.680) — H2 fails under judge. Verdict: COVERED+VALIDATED(PRELIMINARY) unchanged. --use-llm-judge flag shipped. Definitive verdict requires stricter judge rubric or n>=200/cell."
- id: EVAL-059
  title: Perception binary-mode validation — run CHUMP_BYPASS_PERCEPTION sweep via chump binary
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-049"]
- id: EVAL-070
  title: Extend F4 cross-judge methodology to reflection and perception fixtures
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-042"]
  notes: ~1 day of analysis; JSONL data already exists in logs/ab/. No new sweeps needed. Low-effort promotion of an existing single-fixture finding to a three-fixture methodological claim.

- id: EVAL-073
  title: Both-strict cross-judge rescore — close EVAL-072 residual perception gap
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-072"]
  notes: Estimated cost ~300 Anthropic judge calls (~$1-2) + ~300 Together calls (free tier or <$1). Small effort, informative either way.

- id: EVAL-075
  title: Failure-mode taxonomy — hallucinate vs refuse vs decline scoring axis
  domain: eval
  priority: P2
  effort: s
  status: done
  depends_on: ["EVAL-071"]
- id: INFRA-024
  title: apalis research — evaluate Rust-native job-queue for durable multi-agent work
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["INFRA-023"]
  notes: "2026-04-22: Phase 1 audit complete, CLAUDE/AGENTS hygiene added, CI dry-run workflow draft in. Remaining: real publishes, release automation., effort small. Research-only — the output is a memo + PoC, not a migration. Rationale for priority: INFRA-023 (SQLite state) gives us most of the durability wins already (atomic writes, TTL leases, SQL queries). apalis is an upgrade, not a fix. Worth researching because it could replace stale-pr-reaper.sh + bot-merge retry logic + ambient.jsonl consumers with a single typed job model. But we should not commit to it before INFRA-023 ships — the research needs the new DB to reason about integration."
- id: INFRA-044
  title: AI pre-audit dispatcher + static/license/CVE sweep (cargo-deny, cargo-audit, lychee, clippy-pedantic)
  domain: infra
  priority: P2
  effort: s
  status: open
  notes: "P2 so it doesn't displace PRODUCT-015/016/017 (Tier 1) or PRODUCT-018/019 (Tier 2). Closes ~50% of reviewer roles"
- id: DOC-004
  title: Onboarding simulation — fresh Claude agent, docs-only mount, first-task completion
  domain: doc
  priority: P2
  effort: s
  status: done
  notes: Closes reviewer role
- id: INFRA-045
  title: bot-merge.sh must preserve pending_new_gap across session migration
  domain: infra
  priority: P2
  effort: s
  status: open
  notes: "Filed from PR #476 incident. Shipped workaround: use INFRA-028 manual path (CHUMP_GAP_CHECK=0 git push + gh pr create + gh pr merge --auto --squash). Fix unblocks the default bot-merge path for any gap reserved via gap-reserve.sh + same-PR filed.
"
- id: INFRA-053
  title: Pre-commit guard error messages with recovery hints
  domain: infra
  priority: P2
  effort: s
  status: open
- id: DOC-007
  title: Phase 0 — classify top-level docs with doc_tag front-matter
  domain: doc
  priority: P2
  effort: s
  status: done
  depends_on: ["DOC-005","DOC-006"]
  notes: Mechanical multi-file change shipped as one intent-atomic PR.
- id: FLEET-14
  title: "FLEET dev loop design note: Docker NATS, async-nats integration tests, FLEET-007 first"
  domain: fleet
  priority: P2
  effort: s
  status: done
  notes: Design-note gap; no code change. Pairs with the INFRA-042 multi-agent stress report which empirically demonstrated the missing distributed mutex.

- id: INFRA-056
  title: queue-driver auto-resolves DIRTY PRs whose only conflict is docs/gaps.yaml
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["INFRA-052"]
  notes: "Closes the loop on the queue-driver's purpose: post-INFRA-056 the queue should fully self-drain after any gaps.yaml-touching merge. Real conflicts (non-append) still block on human attention by design.
"
- id: INFRA-063
  title: M5 — Cycle-time dashboard + cost-routed dispatcher
  domain: infra
  priority: P2
  effort: s
  status: done
  depends_on: ["INFRA-058"]
  notes: Independent of M2-M4. Can ship anytime after M1.
- id: INFRA-076
  title: Test <test@test.com> co-author in 29+ commits — document identity or purge from history
  domain: infra
  priority: P2
  effort: s
  status: open
- id: RESEARCH-029
  title: SKILL0 competitive positioning — inference-time injection vs training internalization
  domain: research
  priority: P2
  effort: s
  status: open
  depends_on: ["RESEARCH-021"]
- id: INFRA-085
  title: manual-ship invisibility - auto-write lease on gh pr create
  domain: infra
  priority: P2
  effort: s
  status: open
- id: INFRA-088
  title: reconcile docs/audit→docs/audits + docs/synthesis→docs/syntheses (Phase 2 pre-work)
  domain: infra
  priority: P2
  effort: s
  status: open
- id: INFRA-089
  title: chump gap CLI lacks set subcommand for editing fields
  domain: infra
  priority: P2
  effort: s
  status: open
- id: INFRA-090
  title: chump gap dump produces invalid YAML and reorders entire file
  domain: infra
  priority: P2
  effort: s
  status: open
- id: COMP-004
  title: Multi-platform messaging gateway — Telegram/Slack/Signal/WhatsApp
  domain: competitive
  priority: P2
  effort: xl
  status: done
  depends_on: ["COMP-002"]
  notes: "Decomposed into sub-gaps for incremental delivery:
  COMP-004a — extract MessagingAdapter trait from src/discord.rs
  COMP-004b — Telegram adapter (teloxide; webhook + polling modes)
  COMP-004c — Slack adapter (slack-morphism; bolt-style events)
  COMP-004d — Matrix adapter (matrix-rust-sdk)
Signal/WhatsApp deferred (no viable Rust SDK as of 2026-04).
"
- id: COMP-005
  title: Voice/Vision/Browser — voice mode, image paste, browser automation
  domain: competitive
  priority: P2
  effort: xl
  status: done
  depends_on: ["ACP-002"]
  notes: "Decomposed into sub-gaps for incremental delivery (ACP-002 done):
  COMP-005a — image paste in PWA → ContentBlock parser
  COMP-005b — browser automation tool (chromiumoxide CDP, headless)
  COMP-005c — TTS output (cocoa say / piper-tts shell)
"
- id: INFRA-001
  title: Transactional speculation — real per-tool rollback via sandbox_run
  domain: infra
  priority: P2
  effort: xl
  status: done
  notes: "Decomposed:
  INFRA-001a — observability: count + log unrolled-back side
               effects per turn so the \"product pain\" criterion
               is measurable. Without this we can't tell whether
               the gate is satisfied.
  INFRA-001b — sandbox_run integration in speculative_execution
               (gated behind CHUMP_SANDBOX_SPECULATION=1 once
               INFRA-001a shows pain).
  INFRA-001c — policy doc: which tools route through sandbox
               (write_file, patch_file, run_cli, git_*).
"
- id: INFRA-MEMDB-RACE
  title: Track funny-hypatia memory_db.rs WIP — clean push after revert
  domain: infra
  priority: P2
  effort: xs
  status: done
- id: INFRA-STUCK-QUEUE-RUNBOOK
  title: CLAUDE.md atomic-PR-discipline — add stuck-queue recovery runbook
  domain: infra
  priority: P2
  effort: xs
  status: done
  depends_on: ["INFRA-MERGE-QUEUE","INFRA-PUSH-LOCK"]
  notes: Docs-only. No tooling change. Pairs with a possible future INFRA-QUEUE-HEALTH monitor gap (not filed) that would emit the ALERT kind=queue_stuck event automatically when queue-entry age exceeds a threshold.

- id: INFRA-015
  title: Duplicate-ID pre-commit guard — test fixture + CLAUDE.md documentation follow-up
  domain: infra
  priority: P2
  effort: xs
  status: done
  depends_on: ["INFRA-GAPS-DEDUP"]
  notes: Docs-only + test-only. No change to the guard code itself — just closing the paper trail on the remaining acceptance items so the pre-commit test suite covers all five guards on the same footing.

- id: DOC-003
  title: FINDINGS.md F4 reframed with EVAL-073 both-strict 100% result
  domain: infra
  priority: P2
  effort: xs
  status: done
  depends_on: ["EVAL-073"]
- id: INFRA-040
  title: "INFRA-037 correction: required-check list must exclude path-gated workflows"
  domain: infra
  priority: P2
  effort: xs
  status: done
- id: INFRA-41
  title: "code-reviewer-agent.sh: guard empty-array iteration under bash 3.2 set -u"
  domain: infra
  priority: P2
  effort: xs
  status: done
- id: INFRA-031
  title: Document Cursor headless loop parity vs scripts/agent-loop.sh (Claude)
  domain: infra
  priority: P2
  effort: xs
  status: done
  notes: Queued 2026-04-23. XS effort — documentation only unless Cursor CLI gaps force a helper script.
- id: INFRA-027
  title: Fix SIGPIPE in gap-claim.sh — silent lease-write failure under set -o pipefail
  domain: infra
  priority: P2
  effort: xs
  status: done
  notes: Shipped with the fix in the same PR as the gap entry since the bug blocked normal claim-shipping; xs effort, one-line structural fix.
- id: INFRA-065
  title: Wire select_backend_for_gap into orchestrator dispatch path
  domain: infra
  priority: P2
  effort: xs
  status: done
  depends_on: ["INFRA-063"]
  notes: "Stacked on M5 (PR #521). After both land on main, the COG-026 A/B aggregator can split outcomes by dispatch reason (env vs advisor rule) — measuring whether the rule-based router actually routes work to the cheap tier without quality regression (M5 acceptance #3).
"
- id: INFRA-057
  title: "Serialize OPENAI_MODEL-mutating tests with #[serial(openai_model_env)]"
  domain: infra
  priority: P2
  effort: xs
  status: done
  notes: Surfaced when this test was the only blocker repeatedly forcing --skip-tests on bot-merge runs. Now removed.

- id: DOC-006
  title: Doc inventory script + first CSV run (DOC-005 Phase 1)
  domain: doc
  priority: P2
  effort: xs
  status: done
  depends_on: ["DOC-005"]
  notes: XS effort. Subsequent phase gaps (Phase 0 classification, Phase 2 automation, Phase 3 staged consolidation, Phase 4 generated docs) get their own gap entries when picked up. The CSV is generated, not hand-edited — re-run the script after any docs/ changes to refresh it.

- id: INFRA-069
  title: "Serialize CHUMP_LOCAL_BIN dispatch tests with #[serial(chump_local_bin_env)]"
  domain: infra
  priority: P2
  effort: xs
  status: done
  depends_on: ["INFRA-057"]
  notes: "Surfaced when PR #509 hit this race after the OPENAI_MODEL race was fixed. Audit needed: any other tests setting/removing process env vars without #[serial] are racing — file follow-up gaps as they appear.
"
- id: INFRA-071
  title: Sync book/src frontmatter from docs/ after DOC-006 inventory drift
  domain: infra
  priority: P2
  effort: xs
  status: done
  depends_on: ["DOC-006"]
  notes: Mechanical sync; no content change beyond frontmatter propagation.

- id: INFRA-074
  title: audit AGENTS.md/CLAUDE.md drift — fix guard counts and stale claims
  domain: infra
  priority: P2
  effort: xs
  status: done
  notes: "Pure docs + comment change; no code behavior modified. Audit surfaced two follow-ups left as open work: (a) INFRA-070 itself (gap-reserve.sh zero-padding fix) is still open and tracked separately; (b) \"INFRA-CHOKE\" is referenced in CLAUDE.md as a concept name (the CI pre-flight gate) but isn't a real gap ID — not material drift, kept as-is.
"
- id: FLEET-016
  title: Deduplicate FLEET-006 and FLEET-015 ambient intent before concurrent claim
  domain: fleet
  priority: P2
  effort: xs
  status: open
- id: EVAL-086
  title: opened_date backfill for open gaps + enforce non-null on future reserves
  domain: eval
  priority: P2
  effort: xs
  status: open
- id: EVAL-088
  title: EVAL-073 caveat — cross-judge agreement was rubric- and fixture-specific, not generalizable
  domain: eval
  priority: P2
  effort: xs
  status: done
  depends_on: ["EVAL-074"]
- id: EVAL-021
  title: Longitudinal accumulation — does agent get better over 100 sessions
  domain: eval
  priority: P3
  effort: l
  status: done
  depends_on: ["EVAL-013","EVAL-018"]
  notes: "TEST-CAT-L. The capstone gap. If this passes with a meaningful delta, the framework is empirically validated. If it doesn't, the framework needs deeper redesign.
"
- id: COMP-006
  title: Skills sharing ecosystem — index.json endpoint and tap install
  domain: competitive
  priority: P3
  effort: l
  status: done
  depends_on: ["COMP-001"]
- id: INFRA-001b
  title: Speculative execution routes write tools through sandbox_run
  domain: infra
  priority: P3
  effort: l
  status: done
  depends_on: ["INFRA-001a"]
- id: COMP-011b
  title: Adversary mode full — LLM-based context-aware reviewer (after COMP-011a)
  domain: completeness
  priority: P3
  effort: l
  status: done
  depends_on: ["COMP-011a"]
  notes: Significant effort (~1-2 weeks). Watch for latency cost — every tool call now costs 1 extra LLM call. Recommend Haiku-tier model as reviewer (~50ms latency) and only invoke for "interesting" tools. Direct port of goose Adversary Mode pattern.

- id: EVAL-037
  title: Multi-agent coordination A/B — does chump-coord pay for its overhead?
  domain: eval
  priority: P3
  effort: l
  status: done
  notes: Coordination fixture authoring ~3 days. Cost ~$3.

- id: EVAL-039
  title: Longitudinal learning A/B — does the reflection-DB accumulation loop work?
  domain: eval
  priority: P3
  effort: l
  status: done
  depends_on: ["EVAL-030"]
  notes: Optional Q3 — could defer to Q4. Cost ~$10. Wall ~1 week.

- id: MEM-003
  title: LLM episodic → semantic summarization (curation third pillar)
  domain: memory
  priority: P3
  effort: m
  status: done
  depends_on: ["MEM-002"]
- id: EVAL-007
  title: Wire CHUMP_EVAL_WITH_JUDGE into the main agent loop
  domain: eval
  priority: P3
  effort: m
  status: done
  depends_on: ["EVAL-004","EVAL-006","EVAL-009"]
- id: EVAL-009
  title: Eval runner CLI — `chump eval run` loads cases, runs agent, persists EvalRunResult
  domain: eval
  priority: P3
  effort: m
  status: done
  depends_on: ["EVAL-001","EVAL-004"]
- id: EVAL-008
  title: A/B-grade reflect_via_provider vs reflect_heuristic on labeled episodes
  domain: eval
  priority: P3
  effort: m
  status: done
  notes: Synthetic 20-episode dataset shipped (3e23adc) covers all 9 ErrorPattern variants. Real-data upgrade (curate ~20 actual production episodes with gold labels) is DEFERRED until ~1 month of real session history accumulates the natural diversity. Closes when scripts/ab-harness/run-queue.sh fires the run and append-result writes the delta to CONSCIOUSNESS_AB_RESULTS.md. - COG-008

- id: EVAL-020
  title: Persona/tone consistency A/B — does framework alter UX
  domain: eval
  priority: P3
  effort: m
  status: done
  notes: TEST-CAT-K.
- id: COMP-004d
  title: Matrix adapter via matrix-rust-sdk
  domain: competitive
  priority: P3
  effort: m
  status: deferred
  depends_on: ["COMP-004a"]
- id: COMP-005b
  title: Browser automation tool — chromiumoxide CDP wrapper
  domain: competitive
  priority: P3
  effort: m
  status: done
- id: FLEET-003b
  title: peer_sync extension — atomic blackboard exchange
  domain: fleet
  priority: P3
  effort: m
  status: done
  depends_on: ["FLEET-003a"]
- id: FRONTIER-001
  title: Quantum cognition prototype — density matrix tool-choice vs classical argmax
  domain: frontier
  priority: P3
  effort: m
  status: done
- id: FRONTIER-002
  title: TDA replacement for phi_proxy — persistent homology on blackboard traffic
  domain: frontier
  priority: P3
  effort: m
  status: done
  notes: "Implementation (src/tda_blackboard.rs, 310 lines) was written and compiled but never wired in — no callsites existed outside the module. Acceptance criterion (correlation with human-judged session quality) was never measured because labeled session data from phi_proxy calibration was never produced. Code removed 2026-04-19 (commit 32bc6e1) as dead weight in production binary. Recoverable from commit a383031 if labeled session data becomes available. Prerequisite before re-introducing: run phi_proxy calibration sweep and produce the labeled dataset this gate requires.
"
- id: FRONTIER-003
  title: Adaptive regime transitions via learned bandit/logistic regression
  domain: frontier
  priority: P3
  effort: m
  status: done
  depends_on: ["COG-001"]
  notes: Duplicate of COG-003 for frontier tracking. One closure closes both.
- id: SENSE-001
  title: PeripheralSensor trait — hot-path interrupt bridge
  domain: agent
  priority: P3
  effort: m
  status: done
  depends_on: ["AGT-002","AGT-004"]
- id: COG-019
  title: Context-window compaction for long --chat / --web sessions
  domain: cognition
  priority: P3
  effort: m
  status: done
  notes: Backlog exploration item. No active user need yet — sessions stay short. Reverse to P1 if long --chat sessions become common or if a specific use case (e.g. all-day autonomous agent) needs it.

- id: COMP-012
  title: "MAESTRO + NIST AI RMF threat modeling — formalize Chump's safety posture"
  domain: completeness
  priority: P3
  effort: m
  status: done
  depends_on: ["COMP-011a"]
  notes: "~1 week docs + cross-reference work. References: MAESTRO framework, NIST AI RMF. Not strictly required for open-source dogfooding, but required for any enterprise/compliance conversation.
"
- id: COG-021
  title: Test-time-compute / reasoning-mode integration — Chump uses o3/Deep Think when available
  domain: cognition
  priority: P3
  effort: m
  status: done
  notes: Anthropic exposes "thinking" param in messages API. OpenAI o-series uses "reasoning_effort" (low/medium/high). Different providers, different APIs. ~1 week to implement + sweep. Could double cost on reasoning-mode trials. Worth an A/B before shipping as default.

- id: COG-022
  title: MCP server enterprise-readiness — Sampling + Elicitation patterns
  domain: cognition
  priority: P3
  effort: m
  status: done
  depends_on: ["COMP-009"]
  notes: "Confirm MCP Rust SDK supports Sampling/Elicitation before committing. ~1 week effort. Reference: AAIF roadmap docs.
"
- id: EVAL-040
  title: Out-of-distribution problem solving — extend Problem Solving validation
  domain: eval
  priority: P3
  effort: m
  status: done
  notes: "Shipped: BFCL-inspired 20-task OOD fixture (ood_bfcl_sample.json), methodology doc (docs/eval/EVAL-040-ood-benchmark.md), and stub section in CONSCIOUSNESS_AB_RESULTS.md. Pilot sweep pending — fixture and harness commands ready. Full pilot requires live LLM endpoint and dual-judge panel. Cost ~$5 cloud for n=50 per cell on haiku-4-5.
"
- id: INFRA-HEARTBEAT-WATCHER
  title: Heartbeat / liveness daemon — restart silent long-running sweeps
  domain: infra
  priority: P3
  effort: m
  status: done
  depends_on: ["INFRA-AGENT-ESCALATION"]
  notes: ~1 week. Lower priority than escalation/dispatch policy — most sweeps complete within a session and this is mainly for the multi-hour local-tool sweeps. Becomes higher priority once we run nightly background sweeps.

- id: PRODUCT-008
  title: Best-practice extraction — successful patterns auto-propagate to CLAUDE.md / TEAM_OF_AGENTS.md
  domain: product
  priority: P3
  effort: m
  status: done
  depends_on: ["PRODUCT-006","INFRA-SYNTHESIS-CADENCE"]
  notes: "~1 week. The \"convention crystallization\" loop. Without it, good patterns stay tribal knowledge in one session's head; with it, they propagate into the cross-session brain (CLAUDE.md, etc.).
"
- id: MEM-004
  title: Wire async LLM summarizer into curate_all
  domain: memory
  priority: P3
  effort: s
  status: done
  depends_on: ["MEM-003"]
- id: INFRA-MESSAGING-DEDUPE
  title: Reconcile MessagingAdapter (mine) vs PlatformAdapter (older) traits
  domain: infra
  priority: P3
  effort: s
  status: done
  depends_on: ["COMP-004a","COMP-004b"]
- id: COMP-005c
  title: TTS output — voice channel via piper or cocoa say
  domain: competitive
  priority: P3
  effort: s
  status: done
- id: FLEET-003c
  title: merge_workspace + split_workspace tool pair
  domain: fleet
  priority: P3
  effort: s
  status: done
  depends_on: ["FLEET-003b"]
- id: REL-004
  title: Prompt-token estimation accuracy — real tokenizer or better heuristic
  domain: reliability
  priority: P3
  effort: s
  status: done
  notes: "Content-type-aware heuristic in estimate_tokens_for_str: prose=4 chars/token, code/JSON=2.5 chars/token (detected by code-symbol density >12%), non-ASCII=1 token/byte, +4 tokens per-message overhead. No new deps.
"
- id: INFRA-WHITE-PAPERS-PANDOC
  title: "Pandoc 'withBinaryFile: does not exist' in white-papers CI"
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: "Diagnostic gathered 2026-04-17 (no docker locally — daemon not running, can't run the exact CI invocation):
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
  4. Get the full stderr: `grep -A20 \"withBinaryFile\" /tmp/pandoc-fail.log`
  5. Try pinning to a known-good digest:
     `CHUMP_WHITE_PAPER_IMAGE=pandoc/ubuntu-latex:3.6 python3 scripts/...`
"
- id: FRONTIER-006
  title: JEPA / world-models watchpoint — track LeCun AMI Labs as alternate path
  domain: frontier
  priority: P3
  effort: s
  status: done
  notes: "References: https://techcrunch.com/2026/03/09/yann-lecuns-ami-labs-raises-1-03-billion-to-build-world-models/ https://www.latent.space/p/ainews-yann-lecuns-ami-labs-launches Per the 2026-04-19 strategic memo: COMP-005 (multimodal) remains DO-NOT-START. JEPA tracking is intelligence not implementation.
"
- id: INFRA-MCP-DISCOVERY
  title: Dynamic MCP server discovery — auto-detect + register at session start
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: "Quality-of-life feature, not a blocker. ~2-3 days. Reference goose's Extensions Manager for UX patterns. The dev.to post on dynamic MCP discovery with goose is a useful design reference: https://dev.to/amandamartindev/dynamic-mcp-server-discovery-with-goose-3m41
"
- id: EVAL-036
  title: Prompt-assembler ablation — minimalist vs full context-assembly
  domain: eval
  priority: P3
  effort: s
  status: done
  notes: Cheap test (~$2, 1 day code + 1 hour sweep).

- id: INFRA-WORKTREE-REAPER
  title: Stale-worktree reaper — automate cleanup of merged-branch worktrees
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: "~3-4 hours implementation. Reference: existing scripts/stale-pr-reaper.sh for cron pattern + safety conventions. Filed during 2026-04-19 evening tidy audit.
"
- id: INFRA-WORKTREE-PATH-CASE
  title: Sibling agent created worktree at lowercase /Users/jeffadkins/projects/Chump
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: "Filed during 2026-04-19 evening tidy audit. Active sweet-payne worktree NOT touched — sibling agent's work in progress. After that worktree's PR lands, audit safely.
"
- id: INFRA-EXPERIMENT-CHECKPOINT
  title: Experiment-config checkpoint — versioned harness state per A/B sweep
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: ~3 days. Pays off when future you (or external researchers) wants to re-run a 2026-Q2 sweep on a 2027-Q1 codebase to test for regression.

- id: INFRA-SYNTHESIS-CADENCE
  title: Periodic synthesis pass — distill session learnings into strategic docs
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: "~3 days. Cheap automation. Without it, every session reinvents the wheel by re-reading raw artifacts; with it, the team's collective intelligence keeps refining itself in distilled form.
"
- id: INFRA-009
  title: Doc-deletion pre-commit hook — net-zero docs rule for future PR cycles
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: Advisory P3 — useful hygiene, not a blocker on any path. File now so the pattern has an owner. Can be picked up whenever a sibling agent has a quiet slot.

- id: DOC-001
  title: Integrate FINDINGS.md into book/src/SUMMARY.md navigation
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: ~10 minutes of work. Assign to any sibling agent with a quiet slot who can verify no concurrent SUMMARY.md edit is in flight before touching the file.

- id: INFRA-026
  title: Distinguish dispatched-agent commits from foreign actors via author identity
  domain: infra
  priority: P3
  effort: s
  status: done
  notes: P3 because the misattribution is annoying not dangerous. Small bash + Rust change.
- id: FRONTIER-008
  title: Audit + remove dead-weight FRONTIER modules (TDA blackboard et al.)
  domain: frontier
  priority: P3
  effort: s
  status: done
  notes: P3 — speculative-feature cleanup is non-urgent but real-cost. ~1 day audit + per-module removal PRs. Pairs with REMOVAL-001 in spirit (both are "remove what does not earn its weight").
- id: REMOVAL-004
  title: Haiku-specific neuromod bypass retest — resolve F1 U-curve concern under EVAL-060
  domain: eval
  priority: P3
  effort: s
  status: open
  depends_on: ["REMOVAL-001","EVAL-076"]
  notes: Filed by REMOVAL-001 decision matrix 2026-04-21. Low priority because EVAL-063/069 are both NULL; only F1 U-curve concern motivates retest.
- id: REMOVAL-005
  title: Mechanical sweep of belief_state callsites — drop ~47 inert calls
  domain: reliability
  priority: P3
  effort: s
  status: open
  depends_on: ["REMOVAL-003"]
  notes: Filed by QUALITY-004 (2026-04-25). REMOVAL-001 §Metacognition deferred this as "follow-up gap (TBD)". Estimated S effort because the stub is already inert — this is a delete-plus-fix-imports sweep.

- id: FRONTIER-009
  title: JEPA strategic memo section 3 — file orphaned architectural recommendations
  domain: frontier
  priority: P3
  effort: s
  status: open
  depends_on: ["FRONTIER-006"]
- id: FLEET-003
  title: Workspace merge protocol for dynamic autopoiesis
  domain: fleet
  priority: P3
  effort: xl
  status: done
  depends_on: ["FLEET-001","FLEET-002"]
  notes: "Decomposed (FLEET-001/002 are done — gate satisfied):
  FLEET-003a — protocol spec doc (RFC; xs)
  FLEET-003b — peer_sync extension for atomic blackboard exchange (m)
  FLEET-003c — merge_workspace + split_workspace tool pair (s)
"
- id: INFRA-004
  title: Agent governance toolkit integration (WP-7.2)
  domain: infra
  priority: P3
  effort: xl
  status: blocked
  notes: "Sponsor decision gates this entirely. Do not start WP-7.2 without WP-7.1 adopt.
Unblock checklist (when sponsor moves to \"adopt\"):
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
"
- id: FRONTIER-004
  title: Dynamic autopoiesis — temporary workspace merge/split between fleet agents
  domain: frontier
  priority: P3
  effort: xl
  status: deferred
  depends_on: ["FLEET-001","FLEET-002"]
  notes: Duplicate of FLEET-003 for frontier tracking.
- id: COG-009
  title: Add tool_hint param to PromptAssembler for sharper lesson scope filter
  domain: consciousness
  priority: P3
  effort: xs
  status: done
  depends_on: ["COG-007"]
- id: COG-011c
  title: Reverse-order sanity A/B for COG-011
  domain: eval
  priority: P3
  effort: xs
  status: done
  depends_on: ["COG-011"]
- id: INFRA-AB-TOOL-CALL-COUNTER
  title: ab-harness tool_calls counter greps wrong stream (always 0)
  domain: infra
  priority: P3
  effort: xs
  status: done
- id: EVAL-005
  title: Seed cases with LlmJudge + battle-qa.sh per-category summary
  domain: eval
  priority: P3
  effort: xs
  status: done
  depends_on: ["EVAL-004"]
- id: EVAL-006
  title: scripts/battle-qa.sh --with-judge integration
  domain: eval
  priority: P3
  effort: xs
  status: done
  depends_on: ["EVAL-005"]
- id: COMP-005a-fe
  title: PWA Cmd-V image-paste handler in web/index.html
  domain: competitive
  priority: P3
  effort: xs
  status: done
  depends_on: ["COMP-005a"]
- id: FLEET-003a
  title: Workspace merge protocol — RFC + state diagram
  domain: fleet
  priority: P3
  effort: xs
  status: done
  depends_on: ["FLEET-001","FLEET-002"]
- id: INFRA-001a-wire
  title: Hook tool_middleware to record_unrolled_side_effect on rollback
  domain: infra
  priority: P3
  effort: xs
  status: done
  depends_on: ["INFRA-001a"]
- id: INFRA-001c
  title: Policy doc — which tools opt into sandbox routing
  domain: infra
  priority: P3
  effort: xs
  status: done
- id: INFRA-WHITE-PAPERS-TRIGGER
  title: Stop white-papers workflow firing on registry-file edits
  domain: infra
  priority: P3
  effort: xs
  status: done
- id: INFRA-034
  title: "Cleanup: revert agent debug edits, fix voice-feature thiserror gate, add piped-stdin single-turn"
  domain: infra
  priority: P3
  effort: xs
  status: done
- id: INFRA-039
  title: REMOVAL-003 design + CLAUDE.md PR-size rule update (intent-atomic over file-count)
  domain: infra
  priority: P3
  effort: xs
  status: open
- id: INFRA-036
  title: Rename mis-pathed eval-runs archive directories
  domain: infra
  priority: P3
  effort: xs
  status: done
- id: SECURITY-003
  title: Rotate QUEUE_DRIVER_APP_PRIVATE_KEY every 90 days
  domain: security
  priority: P3
  effort: xs
  status: done
  notes: "Low priority because the App is scoped to this single repo and only has the minimum permissions queue-driver needs (pull-requests: write, contents: write). Defense-in-depth, not an urgent fix.
"
- id: EVAL-085
  title: Verify EVAL-064 published aggregate excluded transient exit-code rows
  domain: eval
  priority: P3
  effort: xs
  status: done
  depends_on: ["EVAL-083"]
  notes: XS effort — likely a 30-minute doc check. Low priority because the transient rows are 12 of 410, ~3% — unlikely to swing a verdict but deserves the trail.

- id: DOC-008
  title: "Red Letter #6 cleanup — WORK_QUEUE.md duplicate + DOC-005 stale-open"
  domain: doc
  priority: P3
  effort: xs
  status: done
- id: INFRA-077
  title: remove obsolete gap-reserve.sh unpadded-ID warning from CLAUDE.md
  domain: infra
  priority: P3
  effort: xs
  status: done
  depends_on: ["INFRA-070"]
  notes: Pure docs cleanup; no code change. Caught while picking up queue work after INFRA-074 landed.

- id: EVAL-067
  title: Lesson-level ablation — localize which lesson directive drives spawn_lessons harm
  domain: eval
  priority: P4
  effort: m
  status: done
  depends_on: ["EVAL-064","EVAL-066"]
  notes: Conditional priority — P2 if EVAL-064 holds, P4 (close as invalid) if EVAL-064 delta drops below +0.05. Estimated 1-2 days IF conditional met. The payoff if the signal holds is a publishable "specific lesson directives harm agent performance" claim with concrete removal candidates, which would graduate the COG-016/COG-023/COG-024 lessons trilogy from open research question to settled result.

