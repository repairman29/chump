# EFFECTIVE Gap Template
#
# EFFECTIVE gaps deliver direct user or operator value:
# - New CLI commands or subcommands
# - New web/UI features
# - Workflows that save time for humans
# - Integrations with external tools
#
# Copy this file, rename to docs/gaps/INFRA-NNN.yaml (or domain-NNN.yaml),
# then fill in each field.

---
# Required fields — DO NOT leave as TODO/TBD
id: EFFECTIVE-NNN              # e.g. INFRA-952, PRODUCT-012
domain: INFRA                  # INFRA | PRODUCT | META | COG | EVAL | RESEARCH
title: "EFFECTIVE: <one-line description of what the user gets>"
status: open
priority: P1                   # P0 (unblocker) | P1 (high) | P2 (normal) | P3 (low)
effort: s                      # xs (<2h) | s (2-4h) | m (4-8h) | l (8-16h) | xl (16h+)

# acceptance_criteria: concrete, testable, non-vague
# Each criterion must be falsifiable (no TODO/TBD/fill-in placeholders).
acceptance_criteria:
  # Example 1: CLI command
  - "Criterion 1: 'chump <subcommand> <args>' subcommand exists in src/main.rs and
    exits 0 with expected stdout on the happy path"
  # Example 2: observable side effect
  - "Criterion 2: emits kind=<event_kind> to ambient.jsonl with fields: ts, kind,
    <field1>, <field2>; verified by scripts/ci/test-<feature>.sh"
  # Example 3: test gate
  - "Criterion 3: scripts/ci/test-<feature>.sh passes with N/N tests in CI"

# Optional fields
depends_on: []                 # list of gap IDs this blocks on, e.g. [INFRA-800]
tags: []                       # freeform labels
