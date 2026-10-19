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
# CREDIBLE-1554 item 2 tightens the binding against the reviewer's Mutant B (an
# `if:` on the wait step + a dispatch-only step without --cross) by reading the
# STRUCTURE per-step, not a joined run blob:
#   5. EXACTLY ONE step in verified runs verified-wait.sh (a 2nd call FAILs);
#   6. NO step in verified has a step-level `if:` (the binding is unconditional;
#      the job-level `if: always()` is not a step and is unaffected);
#   7. the call's --lane names EQUAL the job's needs: (all six);
#   8. the --cross set is EXACTLY {audit, ACP smoke};
#   9. the call passes NO --timeout-s (the per-event budget resolves from
#      --event-name inside verified-wait.sh);
#  10. the call's only ${{ }} expressions are needs.*.result + the sha/pr/
#      event_name inputs — nothing else drives the wait.
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

# ── CREDIBLE-1554 item 2: tighten the binding so its mutants cannot pass ──────
# The reviewer's Mutant B (an `if:` on the wait step + a dispatch-only step
# without --cross) slipped past the join-every-run-into-one-string checks above.
# These assertions read the STRUCTURE (per-step), not a joined blob.
import re

steps = [s for s in v.get("steps", []) if isinstance(s, dict)]

# 5. EXACTLY ONE step runs verified-wait.sh (Mutant B adds a 2nd dispatch-only
#    step → count 2 → FAIL). The verdict must flow through a single call site.
wait_steps = [s for s in steps if "scripts/ci/verified-wait.sh" in s.get("run", "")]
if len(wait_steps) == 1:
    ok("exactly one step in verified runs verified-wait.sh")
else:
    bad(f"expected exactly one verified-wait.sh step in verified, found {len(wait_steps)}")

# 6. NO step in verified has a step-level `if:` (Mutant B puts
#    `if: github.event_name != 'workflow_dispatch'` on the wait step → FAIL).
#    The job-level `if: always()` (v["if"]) is NOT a step and is unaffected.
steps_with_if = [s for s in steps if "if" in s]
if not steps_with_if:
    ok("no step in verified has a step-level `if:` (the lane set is unconditional)")
else:
    bad(f"{len(steps_with_if)} step(s) in verified carry a step-level `if:` — the binding must be unconditional for every event")

# Parse the single verified-wait call's run for the remaining assertions. If
# there is not exactly one, the assertions above already failed; guard anyway.
wait_run = wait_steps[0].get("run", "") if wait_steps else ""

# 7. The --lane names equal the job's needs: (all six). A lane added/dropped vs
#    needs means a local lane goes unclassified or a phantom lane is waited on.
lane_names = set(re.findall(r'--lane\s+"([^="]+)=', wait_run))
needs = v.get("needs", [])
needs_set = set(needs) if isinstance(needs, list) else {needs}
if lane_names == needs_set:
    ok(f"verified-wait --lane names equal the job's needs: ({sorted(needs_set)})")
else:
    bad(f"--lane names {sorted(lane_names)} != job needs: {sorted(needs_set)} "
        f"(missing: {sorted(needs_set - lane_names)}; extra: {sorted(lane_names - needs_set)})")

# 8. The --cross set is EXACTLY {audit, ACP smoke} — no more, no fewer.
cross_set = set(re.findall(r'--cross\s+"([^"]+)"', wait_run))
expect_cross = {"audit", "ACP protocol smoke test (Zed / JetBrains compatible)"}
if cross_set == expect_cross:
    ok("verified-wait --cross set is exactly {audit, ACP smoke}")
else:
    bad(f"--cross set {sorted(cross_set)} != expected {sorted(expect_cross)} "
        f"(missing: {sorted(expect_cross - cross_set)}; extra: {sorted(cross_set - expect_cross)})")

# 9. The call passes NO --timeout-s at all (the per-event budget is resolved
#    inside verified-wait.sh from --event-name; a hard-coded --timeout-s would
#    override the budget and could shrink the pull_request/merge_group window).
if re.search(r'--timeout-s\b', wait_run):
    bad("verified-wait call passes --timeout-s — the per-event budget must resolve from --event-name, not a hard-coded flag")
else:
    ok("verified-wait call passes no --timeout-s (per-event budget resolves from --event-name)")

# 10. The call's only ${{ }} expressions are needs.*.result and the
#     sha/pr/event_name inputs — nothing else drives the wait. A stray expression
#     (e.g. a Mutant-B-style `if:` condition smuggled into the run, or an
#     event-name-switched arg) would show up here.
exprs = [e.strip() for e in re.findall(r'\$\{\{(.*?)\}\}', wait_run)]
allowed_exact = {
    "github.event.pull_request.head.sha || github.sha",  # --sha input
    "github.event.pull_request.number",                  # --pr input
    "github.event_name",                                 # --event-name input
}
bad_exprs = []
for e in exprs:
    norm = " ".join(e.split())
    if re.fullmatch(r"needs\.[A-Za-z0-9_-]+\.result", norm):
        continue
    if norm in allowed_exact:
        continue
    bad_exprs.append(norm)
if not bad_exprs:
    ok(f"verified-wait run uses only needs.*.result + sha/pr/event_name expressions ({len(exprs)} total)")
else:
    bad(f"verified-wait run has disallowed ${{{{ }}}} expression(s): {bad_exprs}")

sys.exit(1 if fail else 0)
PY
rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo 'PASS: ci.yml verified job is wired to verified-wait.sh (CREDIBLE-1554)'
fi
exit "$rc"
