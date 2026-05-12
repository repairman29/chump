# CREDIBLE Gap Template
#
# CREDIBLE gaps establish measurement, observability, and trust:
# - New ambient event kinds (kind=foo in ambient.jsonl)
# - Metrics dashboards or reports
# - Validation gates and quality checks
# - A/B experiments and statistical analysis
# - Documentation of behavior contracts
#
# Copy this file, rename to docs/gaps/INFRA-NNN.yaml,
# then fill in each field.

---
# Required fields — DO NOT leave as TODO/TBD
id: CREDIBLE-NNN               # e.g. INFRA-960, CREDIBLE-050
domain: INFRA                  # INFRA | PRODUCT | META | COG | EVAL | RESEARCH
title: "CREDIBLE: <what you can now measure or verify>"
status: open
priority: P1                   # P0 (unblocker) | P1 (high) | P2 (normal) | P3 (low)
effort: s                      # xs (<2h) | s (2-4h) | m (4-8h) | l (8-16h) | xl (16h+)

# acceptance_criteria: describe what evidence proves success
acceptance_criteria:
  # Example 1: new observable event
  - "Criterion 1: kind=<event_kind> emitted to ambient.jsonl after <trigger>;
    fields_required: [ts, kind, <field1>, <field2>]; registered in
    docs/observability/EVENT_REGISTRY.yaml"
  # Example 2: metric computed correctly
  - "Criterion 2: scripts/ops/<report>.sh reads last N events and computes
    <metric> correctly; verified with synthetic fixture data"
  # Example 3: test gate
  - "Criterion 3: scripts/ci/test-<feature>.sh: N+ tests; emits correct events
    for success/failure/edge cases"

# Optional fields
depends_on: []
tags: []
