#!/usr/bin/env python3
"""pr-failing-run-ids.py — extract the failing GitHub Actions run-ids from a
PR's statusCheckRollup, so the stale-pr-reaper can PROMPT an immediate retry of
the CURRENT failing run when it re-arms a flake budget.

Why this exists (completes PR #4606, references the PR #4589 incident):
  PR #4606 taught the reaper to SPARE a green-but-flake-blocked PR and, for the
  `flake_exhausted` verdict, call `rearm_flake_budget` — which deletes the
  INFRA-304 per-PR budget markers so scripts/ops/ci-flake-rerun.sh MAY rerun the
  known flake again. But re-arming only permits a rerun on the NEXT distinct
  run-id: ci-flake-rerun.sh keys its per-run cooldown on the run-id
  (COOLDOWN_DIR/run-<RUN_ID>.ts), so the CURRENT still-failing run is not retried
  until a re-push or fresh CI trigger produces a new run-id. That delayed recovery
  of green-but-flake-blocked PRs (e.g. a fix stack held overnight in CI).

  The fix: when the reaper re-arms, it ALSO reruns the PR's current failing run
  directly (`gh run rerun <id> [--failed]`). This module is the single, pure,
  fixture-tested run-id discovery function it uses — NOT a third divergent copy
  of the targetUrl/detailsUrl regex already embedded inline in ci-flake-rerun.sh
  and keep-mergeable-organ.sh.

Discovery mirrors ci-flake-rerun.sh's semantics exactly:
  * A check "failed" iff its conclusion is one of FAILURE / ERROR / CANCELLED /
    TIMED_OUT / STARTUP_FAILURE (CheckRun) or FAILURE / ERROR (StatusContext).
  * The run-id is parsed from `targetUrl` (StatusContext) or `detailsUrl`
    (CheckRun) via `/actions/runs/(\\d+)`.
  * A run is flagged `cancelled=1` iff ANY of its failing checks ended CANCELLED
    or TIMED_OUT — those are NOT rerun by `gh run rerun --failed` (that flag
    silently skips non-FAILED jobs), so the caller must do a WHOLE-run rerun
    (`gh run rerun <id>` with no --failed). RESILIENT-308 established this.

Input : a statusCheckRollup JSON — either a bare list (as ci-flake-rerun reads
        it) or a full `gh pr view --json statusCheckRollup[,mergeable]` object
        (as the reaper's classifier already fetches). Read from --rollup-file or
        stdin ('-').
Output: one line per failing run-id, `<run_id>\\t<cancelled 0|1>`, deterministic
        (sorted by run-id). No failing runs → no output (exit 0).
"""
import argparse
import json
import re
import sys

_RUN_RE = re.compile(r"/actions/runs/(\d+)")

# CheckRun.conclusion values that mean the completed check failed the gate.
_FAILING_CONCLUSIONS = {
    "FAILURE",
    "ERROR",
    "CANCELLED",
    "TIMED_OUT",
    "STARTUP_FAILURE",
}
# Conclusions that a plain `gh run rerun --failed` will NOT re-trigger — the run
# needs a whole-run rerun instead.
_CANCEL_CONCLUSIONS = {"CANCELLED", "TIMED_OUT"}
# Legacy StatusContext.state values that mean failure.
_STATUS_FAILING = {"FAILURE", "ERROR"}


def failing_runs(rollup):
    """rollup list -> {run_id: cancelled_bool} for failing checks only."""
    runs = {}
    if not isinstance(rollup, list):
        return runs
    for c in rollup:
        if not isinstance(c, dict):
            continue
        typ = c.get("__typename") or ""
        if typ == "StatusContext":
            state = (c.get("state") or "").upper()
            if state not in _STATUS_FAILING:
                continue
            cancelled = False  # legacy statuses carry no cancel distinction
            url = c.get("targetUrl") or c.get("detailsUrl") or ""
        else:
            concl = (c.get("conclusion") or "").upper()
            if concl not in _FAILING_CONCLUSIONS:
                continue
            cancelled = concl in _CANCEL_CONCLUSIONS
            url = c.get("targetUrl") or c.get("detailsUrl") or ""
        m = _RUN_RE.search(url)
        if not m:
            continue
        rid = m.group(1)
        runs[rid] = runs.get(rid, False) or cancelled
    return runs


def _load_rollup(path):
    if path in (None, "", "-"):
        raw = sys.stdin.read()
    else:
        with open(path) as fh:
            raw = fh.read()
    try:
        data = json.loads(raw) if raw.strip() else []
    except (ValueError, TypeError):
        return []
    if isinstance(data, dict):
        return data.get("statusCheckRollup") or []
    return data


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="List failing GitHub Actions run-ids from a statusCheckRollup."
    )
    ap.add_argument(
        "--rollup-file",
        default="-",
        help="JSON file with a statusCheckRollup array (or a full gh-pr-view "
        "object); '-' for stdin.",
    )
    args = ap.parse_args(argv)

    try:
        rollup = _load_rollup(args.rollup_file)
    except OSError:
        return 0  # unreadable rollup: emit nothing (caller falls back safely)

    runs = failing_runs(rollup)
    for rid in sorted(runs):
        print("{}\t{}".format(rid, 1 if runs[rid] else 0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
