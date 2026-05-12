# RESILIENT Gap Template
#
# RESILIENT gaps make the fleet harder to break and faster to recover:
# - Error detection and alerting
# - Retry logic, circuit breakers, timeouts
# - Graceful degradation and fallback paths
# - Recovery procedures and runbooks
# - Security: credential rotation, audit logs
#
# Copy this file, rename to docs/gaps/INFRA-NNN.yaml,
# then fill in each field.

---
# Required fields — DO NOT leave as TODO/TBD
id: RESILIENT-NNN              # e.g. INFRA-970, RESILIENT-010
domain: INFRA
title: "RESILIENT: <what failure mode is now caught or recovered>"
status: open
priority: P1                   # P0 (unblocker) | P1 (high) | P2 (normal) | P3 (low)
effort: s                      # xs (<2h) | s (2-4h) | m (4-8h) | l (8-16h) | xl (16h+)

# acceptance_criteria: describe the failure mode and how it's handled
acceptance_criteria:
  # Example 1: detection
  - "Criterion 1: scripts/ops/<detector>.sh detects <failure condition>;
    emits kind=<alert_kind> to ambient.jsonl with fields: ts, kind, <field1>, <field2>"
  # Example 2: recovery / fallback
  - "Criterion 2: when <failure> occurs, system falls back to <safe state>
    within <timeout>; emits kind=<recovery_kind> on successful recovery"
  # Example 3: test gate
  - "Criterion 3: scripts/ci/test-<feature>.sh: N+ tests; simulates failure,
    asserts correct event emitted and system reaches safe state"

# Optional fields
depends_on: []
tags: []
