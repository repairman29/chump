# CI Regression Guards — INFRA-1421

> **TL;DR** — when you fix a CI regression in `ci.yml`, write a test that
> asserts the healthy condition, add a `CI-Regression-Guard:` trailer to the
> commit, and the hook + audit job keep the fix from silently reverting.

## Problem

CI regressions recur. The canonical example: PR #2065 fixed the `tauri:`
paths-filter in `ci.yml`; within hours a merge from a parallel branch
re-introduced it. The fix cost 45 minutes to diagnose; the regression
cost a ship cycle.

Without a guard, the fix has no mechanical resistance to re-introduction.
With a guard, any future PR that re-introduces the broken condition trips
a test that blocks the push.

## Protocol

### Step 1 — Fix the regression

Write your fix commit as normal. `fix(INFRA-NNN): RESILIENT — <what-was-broken>`.

### Step 2 — Write the inverse test

Create `scripts/ci/test-<your-fix>.sh`. The test asserts the **healthy
condition** — i.e. the condition that must hold after the fix, which is
the inverse of the broken state.

Example: if the bug was `ci.yml` having `tauri:` in its paths-filter
(causing tauri rebuild on every PR even when no tauri code changed), the
guard test asserts that `tauri:` is NOT present in the paths-filter:

```bash
#!/usr/bin/env bash
# test-tauri-filter-no-ciyml.sh — CI-Regression-Guard for INFRA-1432/1421
# Asserts that .github/workflows/ci.yml is NOT listed in the tauri: job's
# paths-filter. Re-introduction of this regression caused a full tauri
# rebuild on every PR even when no tauri code changed.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

# Find the tauri: job's paths block and check ci.yml isn't in it.
# The guard fails (exit 1) if .github/workflows/ci.yml appears as a path entry.
if awk '/^  tauri:/{found=1} found && /paths:/{inpaths=1} inpaths && /\.github\/workflows\/ci\.yml/{exit 1} /^  [a-z]/ && found && !/^  tauri:/{exit 0}' "$CI_YML"; then
    echo "PASS: ci.yml is not in tauri: paths-filter."
else
    echo "FAIL: .github/workflows/ci.yml found in tauri: paths-filter — regression re-introduced!"
    exit 1
fi
```

**Key rule:** the test must **fail** when the bug is present and **pass**
when the fix is in place.

### Step 3 — Add the trailer

In the same commit (or a follow-up squash), add to the commit body:

```
CI-Regression-Guard: scripts/ci/test-<your-fix>.sh
```

Multiple guards are allowed — one trailer line per test:

```
CI-Regression-Guard: scripts/ci/test-tauri-filter-no-ciyml.sh
CI-Regression-Guard: scripts/ci/test-audit-job-runs-unconditionally.sh
```

### Step 4 — Push

The pre-push guard (`scripts/git-hooks/pre-push-ci-regression-guard.sh`)
runs automatically and:

1. Verifies every `CI-Regression-Guard:` trailer references a file that
   exists. If not, **push is blocked**.
2. Runs each referenced test script. If any fails, **push is blocked** —
   meaning the regression you're trying to fix is still present.
3. Warns (non-blocking) if a `fix(` commit touches `ci.yml` but has no
   `CI-Regression-Guard:` trailer.

### Step 5 — CI runs the suite on every PR

The `audit` CI job runs `pre-push-ci-regression-guard.sh` on the PR diff,
providing the same guarantee in the merge path.

---

## Wiring the hook into pre-push (INFRA-1421)

Add to `scripts/git-hooks/pre-push` (in the Guards section, after the
existing numbered guards):

```bash
# Guard N: CI regression guard — fix commits touching ci.yml need test (INFRA-1421)
_CI_REGRESSION_GUARD="$REPO_ROOT/scripts/git-hooks/pre-push-ci-regression-guard.sh"
if [[ -x "$_CI_REGRESSION_GUARD" ]]; then
    if ! bash "$_CI_REGRESSION_GUARD"; then
        exit 1
    fi
fi
```

---

## Registered guards

| Test script | Protects | Gap | Added |
|---|---|---|---|
| `scripts/ci/test-tauri-filter-no-ciyml.sh` | `ci.yml` tauri paths-filter | INFRA-1432 | 2026-05-16 |

*(add new rows here when registering a guard)*

---

## Bypasses

**Pre-push bypass** (sparingly):

```bash
CHUMP_CI_REGRESSION_GUARD=0 git push
```

Always document the reason in the commit body:

```
CI-Regression-Guard-Bypass: test scaffold not yet written; guard lands in INFRA-NNNN follow-up
```

**CI bypass**: not available. The audit job has no bypass env. If a guard
test fails in CI, fix the regression — that's the point.

---

## Ambient events

| Kind | When |
|---|---|
| `ci_regression_guard_blocked` | Push blocked: trailer references missing test |
| `ci_regression_guard_missing` | Warning: fix commit touches ci.yml, no trailer |
| `ci_regression_guard_suite_failed` | Push blocked: guard test failed (regression re-introduced) |
