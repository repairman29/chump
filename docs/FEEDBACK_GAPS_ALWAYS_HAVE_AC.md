# Every gap must have acceptance_criteria

**Rule:** Any gap filed into the Chump registry (`docs/gaps/*.yaml` or `chump gap reserve`)
must include a non-empty `acceptance_criteria:` field with at least one concrete,
testable item before it can be committed.

**Why:** Gaps without acceptance criteria are unpickable in practice — a worker
cannot tell when they are done, and reviewers cannot verify completion. The fleet
repeatedly wasted cycles on vague gaps that required back-and-forth clarification
before work could start.

**How to fix a rejected commit:**

```yaml
# Bad — rejected by pre-commit (CREDIBLE-054):
id: INFRA-999
title: "Fix the thing"
status: open

# Good — passes:
id: INFRA-999
title: "Fix the thing"
status: open
acceptance_criteria:
  - "scripts/ci/test-infra-999.sh passes (N assertions)"
  - "ambient event kind=thing_fixed registered in EVENT_REGISTRY.yaml"
```

**Bypass (rare, must document why):**

```bash
CHUMP_AC_CHECK=0 git commit -m "msg

Obs-Bypass-Reason: AC will follow in the same PR as the implementation"
```

**Enforcement point:** `scripts/git-hooks/pre-commit` guard 3d (CREDIBLE-054).
