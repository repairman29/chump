#!/usr/bin/env bash
# test-ci-verified-shape.sh — CREDIBLE-1554 (PHASE-R R7), item 2
#
# PyYAML ci.yml-shape test for the sole required `verified` job. Pins the
# WIRING that #5602 claimed but did not contain: the fix-forward replaced the
# verified job's poll(120s)+aggregate-once step pair with a single
# `bash scripts/ci/verified-wait.sh` step and raised timeout-minutes to 95.
# A comment-only edit (as #5602 shipped) leaves the verified job byte-identical,
# so this test parses the REAL structure and fails if the wiring regresses.
#
# Asserts, against .github/workflows/ci.yml's `verified` job:
#   1. some step's `run:` invokes `scripts/ci/verified-wait.sh`
#   2. that run passes BOTH cross lanes:
#        --cross "audit"
#        --cross "ACP protocol smoke test (Zed / JetBrains compatible)"
#   3. timeout-minutes >= 91 (the in-job wait is 90 min; the runner must outlive it)
#   4. the stale poll/aggregate pair is GONE — no direct
#      poll-cross-workflow-checks.sh or aggregator-verified.sh call, and no
#      `--timeout-s 120` grace window — so verified can only reach its verdict
#      through the wait loop.
#
# Usage:
#   bash scripts/ci/test-ci-verified-shape.sh
#   CI_YML=path/to/ci.yml bash scripts/ci/test-ci-verified-shape.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CI_YML="${CI_YML:-$REPO_ROOT/.github/workflows/ci.yml}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required for ci.yml-shape parse" >&2
  exit 2
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "FATAL: PyYAML required (pip install pyyaml) — see scripts/ci/test-precommit-pyyaml-required.sh" >&2
  exit 2
fi
[[ -f "$CI_YML" ]] || { echo "FAIL: ci.yml not found at $CI_YML" >&2; exit 1; }

CI_YML="$CI_YML" python3 <<'PY'
import os, sys, yaml

ci_yml = os.environ["CI_YML"]
with open(ci_yml) as f:
    data = yaml.safe_load(f)

jobs = data.get("jobs", {})
if "verified" not in jobs:
    print("FAIL: no `verified` job in ci.yml", file=sys.stderr)
    sys.exit(1)
v = jobs["verified"]

fail = 0
def ok(msg):  print(f"PASS: {msg}")
def bad(msg):
    global fail
    print(f"FAIL: {msg}", file=sys.stderr); fail = 1

run_blob = "\n".join(s.get("run", "") for s in v.get("steps", []) if isinstance(s, dict))

# 1. verified-wait.sh is wired in.
if "scripts/ci/verified-wait.sh" in run_blob:
    ok("verified job runs scripts/ci/verified-wait.sh")
else:
    bad("verified job does not call scripts/ci/verified-wait.sh (was it comment-only, like #5602?)")

# 2. both cross lanes present.
if '--cross "audit"' in run_blob:
    ok('verified-wait call passes --cross "audit"')
else:
    bad('verified-wait call missing --cross "audit"')
acp = '--cross "ACP protocol smoke test (Zed / JetBrains compatible)"'
if acp in run_blob:
    ok("verified-wait call passes the ACP smoke --cross lane")
else:
    bad("verified-wait call missing the ACP smoke --cross lane")

# 3. timeout-minutes >= 91 (wait is 90 min).
tm = v.get("timeout-minutes")
if isinstance(tm, int) and tm >= 91:
    ok(f"timeout-minutes is {tm} (>= 91, outlives the 90-min in-job wait)")
else:
    bad(f"timeout-minutes is {tm!r}; must be an int >= 91 so the runner outlives the 90-min wait")

# 4. the stale poll+aggregate pair is gone.
if "poll-cross-workflow-checks.sh" in run_blob:
    bad("verified job still calls poll-cross-workflow-checks.sh directly — the wait loop owns cross polling now")
else:
    ok("no direct poll-cross-workflow-checks.sh call in verified")
if "aggregator-verified.sh" in run_blob:
    bad("verified job still calls aggregator-verified.sh directly — the wait loop owns aggregation now")
else:
    ok("no direct aggregator-verified.sh call in verified")
if "--timeout-s 120" in run_blob:
    bad("stale 120s grace window still present in verified")
else:
    ok("no stale --timeout-s 120 grace window in verified")

sys.exit(1 if fail else 0)
PY
rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo 'PASS: ci.yml verified job is wired to verified-wait.sh (CREDIBLE-1554)'
fi
exit "$rc"
