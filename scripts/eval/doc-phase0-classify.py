#!/usr/bin/env python3
"""DOC-007 Phase 0 — classify top-level docs/*.md with doc_tag front-matter.

For each top-level docs/*.md:
- if it already has a YAML front-matter block, only add missing keys
- otherwise prepend a fresh front-matter block

Tags from docs/DOC_HYGIENE_PLAN.md:
  canonical | decision-record | runbook | log | redirect | archive-candidate
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
TODAY = "2026-04-25"

# Explicit classification map. Every top-level docs/*.md must appear here or
# we fail loud. owner_gap is best-effort; "" means "leave blank".
CLASSIFICATION: dict[str, tuple[str, str]] = {
    # --- canonical: current source-of-truth references ---
    "AGENT_COORDINATION.md": ("canonical", ""),
    "AGENT_LOOP.md": ("canonical", ""),
    "ARCHITECTURE.md": ("canonical", ""),
    "BENCHMARKS.md": ("canonical", ""),
    "BROWSER_AUTOMATION.md": ("canonical", ""),
    "CAPABILITY_CHECKLIST.md": ("canonical", ""),
    "CHUMP_BRAIN.md": ("canonical", ""),
    "CHUMP_CURSOR_FLEET.md": ("canonical", ""),
    "CHUMP_DISPATCH_RULES.md": ("canonical", ""),
    "CHUMP_FACULTY_MAP.md": ("canonical", ""),
    "CHUMP_RECIPES.md": ("canonical", ""),
    "CHUMP_TO_COMPLEX.md": ("canonical", ""),
    "CODEREVIEW_POLICY.md": ("canonical", ""),
    "CONSCIOUSNESS.md": ("canonical", ""),
    "CONTEXT_PRECEDENCE.md": ("canonical", ""),
    "DOC_HYGIENE_PLAN.md": ("canonical", "DOC-005"),
    "EXECUTION_BACKENDS.md": ("canonical", ""),
    "EXTERNAL_GOLDEN_PATH.md": ("canonical", ""),
    "FINDINGS.md": ("canonical", ""),
    "FLEET_ROLES.md": ("canonical", ""),
    "HIGH_ASSURANCE_AGENT_PHASES.md": ("canonical", ""),
    "INFERENCE_MESH.md": ("canonical", ""),
    "INFERENCE_PROFILES.md": ("canonical", ""),
    "INFERENCE_STABILITY.md": ("canonical", ""),
    "INTENT_ACTION_PATTERNS.md": ("canonical", ""),
    "LATENCY_ENVELOPE.md": ("canonical", ""),
    "MD_BOOK_PUBLISH_SURFACE.md": ("canonical", ""),
    "MEMORY_GRAPH_VS_FTS5.md": ("canonical", ""),
    "MESSAGING_ADAPTERS.md": ("canonical", ""),
    "METRICS.md": ("canonical", ""),
    "MISTRALRS.md": ("canonical", ""),
    "NORTH_STAR.md": ("canonical", ""),
    "ONBOARDING.md": ("canonical", ""),
    "OPERATIONS.md": ("canonical", ""),
    "PERFORMANCE.md": ("canonical", ""),
    "PROVIDER_CASCADE.md": ("canonical", ""),
    "PWA.md": ("canonical", ""),
    "README.md": ("canonical", ""),
    "RED_LETTER.md": ("canonical", ""),
    "RESEARCH_INTEGRITY.md": ("canonical", ""),
    "ROADMAP.md": ("canonical", ""),
    "ROADMAP_INDEX.md": ("canonical", ""),
    "RUST_CODEBASE_PATTERNS.md": ("canonical", ""),
    "RUST_INFRASTRUCTURE.md": ("canonical", ""),
    "RUST_MODULE_MAP.md": ("canonical", ""),
    "SCRIPTS_REFERENCE.md": ("canonical", ""),
    "STORAGE_AND_ARCHIVE.md": ("canonical", ""),
    "TEAM_OF_AGENTS.md": ("canonical", ""),
    "TOOL_APPROVAL.md": ("canonical", ""),
    "WASM_TOOLS.md": ("canonical", ""),
    "WEB_API_REFERENCE.md": ("canonical", ""),
    "WORLD_CLASS_ROADMAP.md": ("canonical", ""),
    "tools_index.md": ("canonical", ""),

    # --- decision-record: ADRs and one-shot design docs ---
    "ACP.md": ("decision-record", ""),
    "ADR-001-transactional-tool-speculation.md": ("decision-record", "INFRA-001b"),
    "ADR-002-mistralrs-structured-output-spike.md": ("decision-record", ""),
    "ADR-004-coord-blackboard-v2.md": ("decision-record", ""),
    "AUTO-013-ORCHESTRATOR-DESIGN.md": ("decision-record", "AUTO-013"),
    "COG-024-MIGRATION.md": ("decision-record", "COG-024"),
    "COS_DECISION_LOG.md": ("decision-record", ""),
    "CRATES_EXTRACTION_PLAN.md": ("decision-record", ""),
    "FLEET_BLOCKER_DETECT_DESIGN.md": ("decision-record", ""),
    "FLEET_CAPABILITY_DESIGN.md": ("decision-record", ""),
    "POLICY-sandbox-tool-routing.md": ("decision-record", ""),
    "PROPOSAL_FLEET_ROLES.md": ("decision-record", ""),
    "SECURITY-001-key-rotation-audit.md": ("decision-record", "SECURITY-001"),
    "TAURI_FRONTEND_PLAN.md": ("decision-record", ""),

    # --- runbook: operational how-to ---
    "ACTIVATION.md": ("runbook", ""),
    "A2A_DISCORD.md": ("runbook", ""),
    "ANDROID_COMPANION.md": ("runbook", ""),
    "AUTOMATION_SNIPPETS.md": ("runbook", ""),
    "AUTONOMOUS_PR_WORKFLOW.md": ("runbook", ""),
    "CHUMP_AUTONOMY_TESTS.md": ("runbook", ""),
    "DEFENSE_PILOT_REPRO_KIT.md": ("runbook", ""),
    "DEMO_HOSTING.md": ("runbook", ""),
    "DEMO_SCRIPT.md": ("runbook", ""),
    "DISCORD_TROUBLESHOOTING.md": ("runbook", ""),
    "FLEET_WS_SPIKE_RUNBOOK.md": ("runbook", ""),
    "FTUE_USER_PROFILE.md": ("runbook", ""),
    "MABEL_FRONTEND.md": ("runbook", ""),
    "MERGE_QUEUE_SETUP.md": ("runbook", ""),
    "OOPS.md": ("runbook", ""),
    "PACKAGING_AND_NOTARIZATION.md": ("runbook", ""),
    "PUBLISHING.md": ("runbook", ""),
    "REPO_HYGIENE_PLAN.md": ("canonical", "INFRA-067"),  # already has FM, will be a no-op
    "STEADY_RUN.md": ("runbook", ""),
    "TOGETHER_SPEND.md": ("runbook", ""),
    "UI_WEEK_SMOKE_PROMPTS.md": ("runbook", ""),

    # --- log: append-only history / dated reports / completed-work logs ---
    "CHUMP_PROJECT_BRIEF.md": ("log", ""),  # superseded by RESEARCH_INTEGRITY
    "CHUMP_RESEARCH_BRIEF.md": ("log", ""),  # superseded by RESEARCH_INTEGRITY
    "COMPETITIVE_MATRIX.md": ("log", ""),
    "CONSCIOUSNESS_AB_RESULTS.md": ("log", ""),
    "CROSS_AGENT_BENCHMARK_2026Q3.md": ("log", ""),
    "CURSOR_CLAUDE_COORDINATION.md": ("log", ""),
    "EVALUATION_PLAN_2026Q2.md": ("log", ""),
    "EXPERT_REVIEW_PANEL.md": ("log", ""),
    "EXTERNAL_PLAN_ALIGNMENT.md": ("log", ""),
    "FLEET_VISION_2026Q2.md": ("log", ""),
    "HERMES_COMPETITIVE_ROADMAP.md": ("log", ""),
    "MARKET_EVALUATION.md": ("log", ""),
    "MARKET_RESEARCH_EVIDENCE_LOG.md": ("log", ""),
    "MDBOOK_REMEDIATION_REPORT.md": ("log", ""),
    "MODEL_TESTING_TAIL.md": ("log", ""),
    "MODERNIZATION_AUDIT.md": ("log", ""),
    "MONETIZATION_V0.md": ("log", ""),
    "NEUROMODULATION_HEURISTICS.md": ("log", ""),
    "NEXT_GEN_COMPETITIVE_INTEL.md": ("log", ""),
    "ONBOARDING_FRICTION_LOG.md": ("log", ""),
    "PROACTIVE_SHIPPING.md": ("log", ""),
    "PROBLEM_VALIDATION_CHECKLIST.md": ("log", ""),
    "PRODUCT-009-PUBLICATION-CHECKLIST.md": ("log", "PRODUCT-009"),
    "PRODUCT-009-blog-draft.md": ("log", "PRODUCT-009"),
    "PRODUCT-011-competition-scan.md": ("log", "PRODUCT-011"),
    "PRODUCT-012-rebuild-decision.md": ("log", "PRODUCT-012"),
    "PRODUCT-014-discord.md": ("log", "PRODUCT-014"),
    "PRODUCT_CRITIQUE.md": ("log", ""),
    "PRODUCT_REALITY_CHECK.md": ("log", ""),
    "PRODUCT_ROADMAP_CHIEF_OF_STAFF.md": ("log", ""),
    "PROJECT_STORY.md": ("log", ""),
    "RESEARCH_AGENT_REVIEW_LOG.md": ("log", ""),
    "RESEARCH_CRITIQUE_2026-04-21.md": ("log", ""),
    "RESEARCH_EXECUTION_LANES.md": ("log", ""),
    "RESEARCH_PLAN_2026Q3.md": ("log", ""),
    "RETRIEVAL_EVAL_HARNESS.md": ("log", ""),
    "ROADMAP_FULL.md": ("log", ""),
    "ROADMAP_MABEL_DRIVER.md": ("log", ""),
    "ROADMAP_PRAGMATIC.md": ("log", ""),
    "ROADMAP_SPRINTS.md": ("log", ""),
    "ROADMAP_UNIVERSAL_POWER.md": ("log", ""),
    "ROAD_TEST_VALIDATION.md": ("log", ""),
    "SECURITY_MCP_AUDIT.md": ("log", ""),
    "STRATEGIC_MEMO_2026Q2.md": ("log", ""),
    "TRUST_SPECULATIVE_ROLLBACK.md": ("log", ""),
    "WEDGE_H1_GOLDEN_EXTENSION.md": ("log", ""),
    "WEDGE_PILOT_METRICS.md": ("log", ""),
    "WORK_QUEUE.md": ("log", ""),
    "eval-credibility-audit.md": ("log", "EVAL-083"),

    # --- redirect: short "moved to X" stubs ---
    "CHUMP_CURSOR_PROTOCOL.md": ("redirect", ""),
    "CURSOR_CLI_INTEGRATION.md": ("redirect", ""),

    # --- archive-candidate: orphans (0 inbound refs) or superseded ---
    "CONTEXT_ASSEMBLY_AUDIT.md": ("archive-candidate", ""),
    "CRATE_AUDIT.md": ("archive-candidate", "INFRA-046"),
    "EVALUATION_PRIORITIZATION_FRAMEWORK.md": ("archive-candidate", ""),
    "FLEET_OPEN_QUESTIONS_RESEARCH_2026Q2.md": ("archive-candidate", ""),
    "GAPS_YAML_TO_SQLITE_MIGRATION.md": ("archive-candidate", ""),
    "RED_LETTER_RESPONSE_2026Q2.md": ("archive-candidate", ""),
}


FRONT_MATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def merge_front_matter(existing: str, fields: dict[str, str]) -> str:
    """Add any fields from `fields` that are not already present in `existing` YAML block."""
    out_lines = existing.splitlines()
    have_keys = set()
    for line in out_lines:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:", line)
        if m:
            have_keys.add(m.group(1))
    for k, v in fields.items():
        if k not in have_keys:
            out_lines.append(f"{k}: {v}" if v != "" else f"{k}:")
    return "\n".join(out_lines)


def render_block(fields: dict[str, str]) -> str:
    body_lines = [f"{k}: {v}" if v != "" else f"{k}:" for k, v in fields.items()]
    return "---\n" + "\n".join(body_lines) + "\n---\n"


def apply_to_file(path: Path, doc_tag: str, owner_gap: str) -> str:
    text = path.read_text()
    fields = {
        "doc_tag": doc_tag,
        "owner_gap": owner_gap,
        "last_audited": TODAY,
    }
    m = FRONT_MATTER_RE.match(text)
    if m:
        merged = merge_front_matter(m.group(1), fields)
        new_text = "---\n" + merged + "\n---\n" + text[m.end():]
        action = "merged"
    else:
        new_text = render_block(fields) + "\n" + text
        action = "prepended"
    if new_text != text:
        path.write_text(new_text)
        return action
    return "noop"


def main() -> int:
    md_files = sorted(p for p in DOCS.glob("*.md"))
    missing = []
    actions = {"merged": 0, "prepended": 0, "noop": 0}
    tag_counts: dict[str, int] = {}
    for p in md_files:
        if p.name == "_inventory.csv":
            continue
        if p.name not in CLASSIFICATION:
            missing.append(p.name)
            continue
        tag, owner_gap = CLASSIFICATION[p.name]
        action = apply_to_file(p, tag, owner_gap)
        actions[action] += 1
        tag_counts[tag] = tag_counts.get(tag, 0) + 1

    if missing:
        print("FAIL: docs not in CLASSIFICATION map:", file=sys.stderr)
        for name in missing:
            print(f"  - {name}", file=sys.stderr)
        return 1

    print("=== DOC-007 Phase 0 classify summary ===")
    print(f"Total classified: {sum(tag_counts.values())}")
    for tag in sorted(tag_counts):
        print(f"  {tag:>20s}: {tag_counts[tag]}")
    print()
    print("File actions:")
    for k, v in actions.items():
        print(f"  {k:>20s}: {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
