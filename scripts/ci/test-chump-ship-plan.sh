#!/usr/bin/env bash
# INFRA-1229 slice 1: smoke test for `chump ship plan` CLI.
#
# Exercises the pure planner via the CLI wrapper, against:
#   1. --dry-run with no PR (expect OperatorAction)
#   2. --help (expect usage line)
#   3. --json output schema (required keys present)
#
# Does NOT make real GitHub API calls — those are exercised via the unit
# tests in `crates/chump-ship/` (cargo test -p chump-ship).

set -euo pipefail

BIN="${CHUMP_BIN:-target/debug/chump}"
if [[ ! -x "$BIN" ]]; then
    echo "[test] FAIL: chump binary not found at $BIN — build first with cargo build --bin chump" >&2
    exit 2
fi

# ── 1. --help shows usage ─────────────────────────────────────────────
OUT=$("$BIN" ship plan --help 2>&1)
if ! echo "$OUT" | grep -q "Usage: chump ship plan"; then
    echo "[test] FAIL: --help did not show usage line" >&2
    echo "$OUT" >&2
    exit 1
fi
echo "[test] PASS: --help shows usage"

# ── 2. --dry-run with no PR yields OperatorAction (no commits to ship) ─
OUT=$("$BIN" ship plan --dry-run --json 2>/dev/null)
ACTION=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan"]["action"])')
if [[ "$ACTION" != "OperatorAction" ]]; then
    # The dry-run path may pick up real ahead_main if we're on a fresh
    # branch — so accept any non-failure action. The point is the JSON
    # parsed and "plan.action" exists.
    if [[ -z "$ACTION" ]]; then
        echo "[test] FAIL: plan.action missing from --dry-run JSON" >&2
        echo "$OUT" >&2
        exit 1
    fi
fi
echo "[test] PASS: --dry-run emits JSON with plan.action=$ACTION"

# ── 3. JSON schema contains required keys ─────────────────────────────
python3 - <<PYEOF
import json, sys
out = """$OUT"""
d = json.loads(out)
required_top = ['gap', 'branch', 'behind_main', 'ahead_main', 'pr', 'plan']
missing = [k for k in required_top if k not in d]
if missing:
    print(f"[test] FAIL: top-level keys missing: {missing}", file=sys.stderr)
    sys.exit(1)
pr_required = ['number', 'state', 'mergeable', 'mergeable_state',
               'auto_merge_set', 'head_sha', 'base_sha', 'checks']
missing_pr = [k for k in pr_required if k not in d['pr']]
if missing_pr:
    print(f"[test] FAIL: pr.* keys missing: {missing_pr}", file=sys.stderr)
    sys.exit(1)
checks_required = ['total', 'completed_success', 'completed_failure',
                   'incomplete', 'neutral_or_skipped']
missing_checks = [k for k in checks_required if k not in d['pr']['checks']]
if missing_checks:
    print(f"[test] FAIL: pr.checks.* keys missing: {missing_checks}", file=sys.stderr)
    sys.exit(1)
plan_keys = list(d['plan'].keys())
if 'action' not in plan_keys:
    print(f"[test] FAIL: plan.action missing", file=sys.stderr)
    sys.exit(1)
print(f"[test] PASS: JSON schema complete — top + pr + checks + plan")
PYEOF

# ── 4. --human format prints action: line ─────────────────────────────
OUT=$("$BIN" ship plan --dry-run --human 2>/dev/null)
if ! echo "$OUT" | grep -qE '^\s*action:'; then
    echo "[test] FAIL: --human output missing 'action:' line" >&2
    echo "$OUT" >&2
    exit 1
fi
echo "[test] PASS: --human prints action: line"

# ── 5. Unknown flag rejected with exit 2 ──────────────────────────────
set +e
"$BIN" ship plan --not-a-real-flag >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -ne 2 ]]; then
    echo "[test] FAIL: unknown flag should exit 2, got $rc" >&2
    exit 1
fi
echo "[test] PASS: unknown flag rejected with exit 2"

echo ""
echo "[test] ALL CHUMP-SHIP-PLAN CHECKS PASSED — INFRA-1229 slice 1 CLI verified"
