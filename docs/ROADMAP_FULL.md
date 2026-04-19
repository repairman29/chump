# Full Roadmap

Complete multi-horizon view of all gaps — open backlog and completed work. Near-term operational backlog with current priorities is in [ROADMAP.md](ROADMAP.md). For the cognitive architecture research direction see [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md).

**186 gaps total — 50 open, 136 done** as of 2026-04-19. Source: `docs/gaps.yaml`.

---

## Open Backlog

### P1 — Ship-blocking / highest leverage

| ID | Title | Effort |
|----|-------|--------|
| EVAL-026 | Cognitive-layer U-curve at 32B — extend 1B-14B sweep upward | M |
| EVAL-027 | SAKE knowledge anchoring — apply Feb 2026 KID paper findings | M |
| EVAL-030 | Task-class-aware lessons block — fix neuromod harm at its root | M |
| COG-023 | Sonnet carve-out from COG-016 directive — confirmed at n=100 | M |
| RESEARCH-001 | Public research narrative — "2000+ A/B trials" blog post | M |
| INFRA-MERGE-QUEUE | Enable GitHub merge queue — serialize auto-merges atomically | S |
| INFRA-PUSH-LOCK | Pre-push hook blocks pushes to PRs with auto-merge armed | S |
| INFRA-AGENT-CODEREVIEW | Code-reviewer agent in the loop for src/* PRs before auto-merge | M |
| AUTO-013 | Chump-orchestrator mode — dogfood meta-loop for self-dispatch | XL |
| FRONTIER-005 | goose competitive positioning + Chump differentiation strategy | M |

### P2 — High value, unblocked

| ID | Title | Effort |
|----|-------|--------|
| EVAL-028 | CatAttack adversarial robustness sweep on Chump fixtures | S |
| EVAL-029 | Investigate which neuromod tasks drive cross-architecture harm | S |
| EVAL-032 | Perception layer ablation A/B | M |
| EVAL-033 | Attention mitigation A/B — distractor-suppression candidates | M |
| EVAL-034 | Memory retrieval evaluation — multi-hop QA with SAKE | L |
| EVAL-035 | Belief-state ablation A/B — is belief_state.rs net-positive | S |
| EVAL-038 | Ambiguous-prompt A/B — Social Cognition validation of ASK_JEFF | S |
| COMP-007 | AGENTS.md interop standard adoption | S |
| COMP-008 | Recipes abstraction — shareable packaged workflows | M |
| COMP-009 | Extend Chump MCP-server catalog from 3 to 6+ | M |
| COMP-010 | Brew formula + signed installer | S |
| COMP-011a | Adversary-mode-lite — static-rules runtime tool-action monitor | S |
| COMP-013 | MCPwned / DNS rebinding mitigation audit on MCP servers | S |
| COMP-014 | Cost ledger broken — fix $0.00 across all providers | M |
| COG-020 | DeepMind 10-faculty architecture map — taxonomy alignment | S |
| COG-024 | Default lessons-OFF — opt-in per-model after measurement | L |
| INFRA-FILE-LEASE | File-level path leases on top of gap-level mutex | M |
| INFRA-BOT-MERGE-LOCK | bot-merge.sh marks worktree shipped; chump-commit.sh refuses | S |
| INFRA-AGENT-ESCALATION | Formal escalation pattern when an agent is stuck | M |
| INFRA-DISPATCH-POLICY | musher dispatch policy — capacity-aware, priority-ordered | M |
| INFRA-COST-CEILING | Per-session cloud spend cap — hard ceiling + soft warn | S |
| MEM-006 | Lessons-loaded-at-spawn — agents inherit prior reflection | M |
| MEM-007 | Agent context-query before working on a gap | M |
| FRONTIER-007 | Cross-agent benchmarking — apply eval harness to goose | M |

### P3 — Research / long-horizon

| ID | Title | Effort |
|----|-------|--------|
| EVAL-031 | Search-Augmented Reasoning — AutoRefine + policy trees | L |
| EVAL-036 | Prompt-assembler ablation — minimalist vs full | S |
| EVAL-037 | Multi-agent coordination A/B | L |
| EVAL-039 | Longitudinal learning A/B — reflection-DB accumulation | L |
| EVAL-040 | Out-of-distribution problem solving extension | M |
| COMP-011b | Adversary mode full — LLM-based context-aware reviewer | L |
| COMP-012 | MAESTRO + NIST AI RMF threat modeling | M |
| COG-021 | Test-time-compute / reasoning-mode integration | M |
| COG-022 | MCP server enterprise-readiness — Sampling + Elicitation | M |
| FRONTIER-006 | JEPA / world-models watchpoint | S |
| INFRA-MCP-DISCOVERY | Dynamic MCP server discovery at session start | S |
| INFRA-WORKTREE-PATH-CASE | Sibling-agent lowercase-path worktree collision | S |
| INFRA-EXPERIMENT-CHECKPOINT | Experiment-config checkpoint — versioned harness state | S |
| INFRA-HEARTBEAT-WATCHER | Heartbeat liveness daemon — restart silent long-running sessions | M |
| INFRA-SYNTHESIS-CADENCE | Periodic synthesis pass — distill session learnings | S |
| PRODUCT-008 | Best-practice extraction — successful patterns auto-propagated | M |

---

## Completed Work (136 gaps)

### Cognitive architecture — COG (26 done)

| ID | Title |
|----|-------|
| COG-001 | Surprisal EMA — rolling average of per-token surprisal |
| COG-002 | Surprise-triggered belief update and regime shift |
| COG-003 | Precision controller — serotonin / dopamine modulation |
| COG-004 | Causal graph lesson extraction |
| COG-005 | Belief state serialization + rollback |
| COG-006 | Expected Free Energy (EFE) tool selection bias |
| COG-007 | Tool execution interrupt on high surprise |
| COG-008 | Neuromodulation heuristics — thresholds and damping |
| COG-009 | Speculative execution — batch tool calls with rollback |
| COG-009b | Wire tool_hint signal from BatchOutcome into orchestrator |
| COG-010 | Multi-turn belief coherence — persist across turns |
| COG-011 | Blackboard injection in prompt assembler |
| COG-012 | Perception sensor — visual + code + text streams |
| COG-013 | Social cognition sensor — user intent + affect |
| COG-014 | Task-specific lessons content per fixture |
| COG-015 | Entity-keyed blackboard injection |
| COG-016 | Model-tier-aware lessons block injection (COG-016 directive, n=100 validated) |
| COG-017 | Generation layer scaffold — text + code + tool outputs |
| COG-018 | Metacognition layer — self-assessment of tool call quality |
| COG-019 | Introspection ring buffer (chump_tool_health) |
| + 6 more | Memory graph PageRank, quantum cognition prototype, TDA blackboard, entity resolution, belief ranking, regime learning |

### Evaluation harness — EVAL (26 done)

| ID | Title |
|----|-------|
| EVAL-001..009 | A/B harness foundation: judge, runner, cost ledger, multi-axis scoring |
| EVAL-010 | Single-judge bias study — 38–63% agreement at chance |
| EVAL-011..015 | Cross-model, cross-family judge, n=100 sweeps |
| EVAL-016 | COG-016 candidate validation at n=100 |
| EVAL-017..022 | Tool integration A/B, multi-turn, multi-judge (median-of-3) |
| EVAL-023 | Cross-family judge via Ollama integration |
| EVAL-024 | A/A controls — 10.7× A/B vs A/A noise floor ratio established |
| EVAL-025 | COG-016 directive validation: **+0.14 mean fake-tool-call reduction**, Wilson 95% CI non-overlapping, p < 0.05, 3 task types, n=100 each |

### Infrastructure — INFRA (17 done)

Gap-claim lease system, merge queue (INFRA-MERGE-QUEUE), worktree reaper, ambient stream (peripheral vision), five-job pre-commit hook, multi-agent coordination hardening, chump-commit.sh stomp prevention.

### Competitive — COMP (13 done)

Skills system (SKILL.md procedural memory), plugin architecture (3 discovery sources), Slack / Telegram / Signal adapters, ACP (Zed/JetBrains), voice mode, image paste, browser V1 scaffold, screen vision.

### Autonomy — AUTO (12 done)

Autonomy driver, task lease conformance, policy-based approvals, dependency-aware task selection, chump-orchestrator MVP scaffold (step 1 + 2 shipped).

### Fleet — FLEET (12 done)

Workspace merge protocol (RFC + atomic exchange), peer sync, peripheral vision ambient stream, Pixel Sentinel role, fleet roles registry, mutual supervision, FLEET-001..005.

### Agent loop — AGT (6 done)

Cancellation tokens, messaging adapter event queue, LLM streaming deltas, mid-turn interrupt, AgentState FSM.

### Memory — MEM (6 done)

Cross-encoder reranker, confidence decay + deduplication, LLM episodic → semantic summarization, episode extractor, async LLM curate_all.

### Product — PRODUCT (6 done)

PWA Dashboard, single-command fleet deploy, user profile system, FTUE, sprint synthesis script, COS weekly snapshot.

### ACP — (4 done)

Vision passthrough, thinking streaming, MCP lifecycle, real-editor integration tests (Zed/JetBrains CI).

### Relations — REL (3 done), Frontier — FRONTIER (3 done), Sense — SENSE (1 done), Quality — QUALITY (1 done)

---

## See Also

- [ROADMAP.md](ROADMAP.md) — current operational priorities (checked/unchecked tasks)
- [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) — "ships this quarter" cut
- [CHUMP_TO_COMPLEX.md](CHUMP_TO_COMPLEX.md) — cognitive architecture frontier
- [CONSCIOUSNESS_AB_RESULTS.md](CONSCIOUSNESS_AB_RESULTS.md) — full EVAL chain
- [NEXT_GEN_COMPETITIVE_INTEL.md](NEXT_GEN_COMPETITIVE_INTEL.md) — competitive landscape
- [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md) — long-horizon architecture bets
