#!/usr/bin/env bash
# Phase 2 docs/ categorization plan — INFRA-134.
# Each line is "<src>:<dst-subdir>". README.md stays at root.
# Categories per .chump/PHASE_2_3_5_PLAN.md.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

declare -a MOVES=(
  # architecture/ — system design, internals, ADRs, protocols
  "ACP.md:architecture"
  "ACTIVATION.md:architecture"
  "ADR-001-transactional-tool-speculation.md:architecture"
  "ADR-002-mistralrs-structured-output-spike.md:architecture"
  "ADR-004-coord-blackboard-v2.md:architecture"
  "AGENT_LOOP.md:architecture"
  "ANDROID_COMPANION.md:architecture"
  "ARCHITECTURE.md:architecture"
  "AUTO-013-ORCHESTRATOR-DESIGN.md:architecture"
  "CHUMP_BRAIN.md:architecture"
  "CHUMP_FACULTY_MAP.md:architecture"
  "CONTEXT_PRECEDENCE.md:architecture"
  "EXECUTION_BACKENDS.md:architecture"
  "FLEET_BLOCKER_DETECT_DESIGN.md:architecture"
  "FLEET_CAPABILITY_DESIGN.md:architecture"
  "FLEET_DEV_LOOP_DESIGN.md:architecture"
  "FLEET_ROLES.md:architecture"
  "INFERENCE_MESH.md:architecture"
  "INTENT_ACTION_PATTERNS.md:architecture"
  "MABEL_FRONTEND.md:architecture"
  "MEMORY_GRAPH_VS_FTS5.md:architecture"
  "MESSAGING_ADAPTERS.md:architecture"
  "MISTRALRS.md:architecture"
  "POLICY-sandbox-tool-routing.md:architecture"
  "PROVIDER_CASCADE.md:architecture"
  "PWA.md:architecture"
  "RUST_CODEBASE_PATTERNS.md:architecture"
  "RUST_INFRASTRUCTURE.md:architecture"
  "RUST_MODULE_MAP.md:architecture"
  "TEAM_OF_AGENTS.md:architecture"
  "TRUST_SPECULATIVE_ROLLBACK.md:architecture"
  "WASM_TOOLS.md:architecture"

  # operations/ — runtime, ops, troubleshooting, perf
  "AUTOMATION_SNIPPETS.md:operations"
  "BENCHMARKS.md:operations"
  "BROWSER_AUTOMATION.md:operations"
  "DEFENSE_PILOT_REPRO_KIT.md:operations"
  "DEMO_HOSTING.md:operations"
  "DEMO_SCRIPT.md:operations"
  "DISCORD_TROUBLESHOOTING.md:operations"
  "FLEET_WS_SPIKE_RUNBOOK.md:operations"
  "INFERENCE_PROFILES.md:operations"
  "INFERENCE_STABILITY.md:operations"
  "LATENCY_ENVELOPE.md:operations"
  "METRICS.md:operations"
  "MODEL_TESTING_TAIL.md:operations"
  "OOPS.md:operations"
  "OPERATIONS.md:operations"
  "PACKAGING_AND_NOTARIZATION.md:operations"
  "PERFORMANCE.md:operations"
  "PUBLISHING.md:operations"
  "RETRIEVAL_EVAL_HARNESS.md:operations"
  "ROAD_TEST_VALIDATION.md:operations"
  "STEADY_RUN.md:operations"
  "STORAGE_AND_ARCHIVE.md:operations"
  "TOGETHER_SPEND.md:operations"
  "TOOL_APPROVAL.md:operations"
  "UI_WEEK_SMOKE_PROMPTS.md:operations"

  # process/ — dev workflow, coordination, governance
  "A2A_DISCORD.md:process"
  "AGENT_COORDINATION.md:process"
  "AUTONOMOUS_PR_WORKFLOW.md:process"
  "CAPABILITY_CHECKLIST.md:process"
  "CHUMP_AUTONOMY_TESTS.md:process"
  "CHUMP_CURSOR_FLEET.md:process"
  "CHUMP_CURSOR_PROTOCOL.md:process"
  "CHUMP_DISPATCH_RULES.md:process"
  "CHUMP_RECIPES.md:process"
  "CODEREVIEW_POLICY.md:process"
  "COG-024-MIGRATION.md:process"
  "COS_DECISION_LOG.md:process"
  "CRATES_EXTRACTION_PLAN.md:process"
  "CURSOR_CLAUDE_COORDINATION.md:process"
  "CURSOR_CLI_INTEGRATION.md:process"
  "DOC_HYGIENE_PLAN.md:process"
  "EVALUATION_PRIORITIZATION_FRAMEWORK.md:process"
  "EXPERT_REVIEW_PANEL.md:process"
  "EXTERNAL_GOLDEN_PATH.md:process"
  "FTUE_USER_PROFILE.md:process"
  "GAPS_YAML_TO_SQLITE_MIGRATION.md:process"
  "MD_BOOK_PUBLISH_SURFACE.md:process"
  "MERGE_QUEUE_SETUP.md:process"
  "ONBOARDING.md:process"
  "ONBOARDING_FRICTION_LOG.md:process"
  "PROACTIVE_SHIPPING.md:process"
  "PROBLEM_VALIDATION_CHECKLIST.md:process"
  "PRODUCT-009-PUBLICATION-CHECKLIST.md:process"
  "REPO_HYGIENE_PLAN.md:process"
  "RESEARCH_INTEGRITY.md:process"
  "WORK_QUEUE.md:process"

  # strategy/ — direction, vision, roadmaps
  "CHUMP_TO_CHAMP.md:strategy"
  "COMPETITIVE_MATRIX.md:strategy"
  "EVALUATION_PLAN_2026Q2.md:strategy"
  "EXTERNAL_PLAN_ALIGNMENT.md:strategy"
  "FLEET_VISION_2026Q2.md:strategy"
  "HERMES_COMPETITIVE_ROADMAP.md:strategy"
  "HIGH_ASSURANCE_AGENT_PHASES.md:strategy"
  "MARKET_EVALUATION.md:strategy"
  "MONETIZATION_V0.md:strategy"
  "NEXT_GEN_COMPETITIVE_INTEL.md:strategy"
  "NORTH_STAR.md:strategy"
  "PRODUCT-009-blog-draft.md:strategy"
  "PRODUCT-011-competition-scan.md:strategy"
  "PRODUCT-012-rebuild-decision.md:strategy"
  "PRODUCT-014-discord.md:strategy"
  "PRODUCT_CRITIQUE.md:strategy"
  "PRODUCT_REALITY_CHECK.md:strategy"
  "PRODUCT_ROADMAP_CHIEF_OF_STAFF.md:strategy"
  "PROJECT_STORY.md:strategy"
  "PROPOSAL_FLEET_ROLES.md:strategy"
  "ROADMAP.md:strategy"
  "ROADMAP_FULL.md:strategy"
  "ROADMAP_INDEX.md:strategy"
  "ROADMAP_MABEL_DRIVER.md:strategy"
  "ROADMAP_PRAGMATIC.md:strategy"
  "ROADMAP_SPRINTS.md:strategy"
  "ROADMAP_UNIVERSAL_POWER.md:strategy"
  "STRATEGIC_MEMO_2026Q2.md:strategy"
  "TAURI_FRONTEND_PLAN.md:strategy"
  "WEDGE_H1_GOLDEN_EXTENSION.md:strategy"
  "WEDGE_PILOT_METRICS.md:strategy"
  "WORLD_CLASS_ROADMAP.md:strategy"

  # audits/ — retrospectives, audits, red letters
  "CONTEXT_ASSEMBLY_AUDIT.md:audits"
  "CRATE_AUDIT.md:audits"
  "FINDINGS.md:audits"
  "INFRA-042-MULTI-AGENT-REPORT.md:audits"
  "MDBOOK_REMEDIATION_REPORT.md:audits"
  "MODERNIZATION_AUDIT.md:audits"
  "RED_LETTER.md:audits"
  "RED_LETTER_RESPONSE_2026Q2.md:audits"
  "SECURITY-001-key-rotation-audit.md:audits"
  "SECURITY_MCP_AUDIT.md:audits"
  "eval-credibility-audit.md:audits"

  # research/ — methodology, results, evidence logs
  "CONSCIOUSNESS.md:research"
  "CONSCIOUSNESS_AB_RESULTS.md:research"
  "CROSS_AGENT_BENCHMARK_2026Q3.md:research"
  "FLEET_OPEN_QUESTIONS_RESEARCH_2026Q2.md:research"
  "MARKET_RESEARCH_EVIDENCE_LOG.md:research"
  "NEUROMODULATION_HEURISTICS.md:research"
  "RESEARCH_AGENT_REVIEW_LOG.md:research"
  "RESEARCH_CRITIQUE_2026-04-21.md:research"
  "RESEARCH_EXECUTION_LANES.md:research"
  "RESEARCH_PLAN_2026Q3.md:research"

  # briefs/ — operator briefs
  "CHUMP_PROJECT_BRIEF.md:briefs"
  "CHUMP_RESEARCH_BRIEF.md:briefs"

  # api/ — references
  "SCRIPTS_REFERENCE.md:api"
  "WEB_API_REFERENCE.md:api"
  "tools_index.md:api"
)

# README.md stays at root (canonical entry).
EXPECTED_MOVES=146

if [[ "${1:-}" == "--check" ]]; then
  printf '%s\n' "${MOVES[@]}" | wc -l
  exit 0
fi

if [[ "${1:-}" == "--sed-pairs" ]]; then
  for entry in "${MOVES[@]}"; do
    src="${entry%%:*}"
    dst="${entry##*:}"
    printf 's|docs/%s|docs/%s/%s|g\n' "$src" "$dst" "$src"
  done
  exit 0
fi

# Default: execute the moves
mkdir -p docs/architecture docs/operations docs/process docs/strategy docs/api
# audits, briefs, research, syntheses already exist

count=0
for entry in "${MOVES[@]}"; do
  src="${entry%%:*}"
  dst="${entry##*:}"
  git mv "docs/$src" "docs/$dst/$src"
  count=$((count+1))
done
echo "moved $count files"
