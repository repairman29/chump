#!/usr/bin/env bash
# scripts/ci/test-ruleset-snapshots.sh — INFRA-2041 (2026-05-27)
#
# Smoke test for scripts/ops/ruleset-snapshots/drop.json and restore.json.
# Validates that both files:
#   1. Parse as valid JSON
#   2. Have required top-level keys: name, target, rules
#   3. drop.json has no required_status_checks rule
#   4. restore.json has exactly one required_status_checks rule with the
#      three expected contexts: test, audit, ACP protocol smoke test (Zed / JetBrains compatible)
#
# Does NOT make any live API calls — safe to run offline and in CI.
#
# Exit codes:
#   0  all checks pass
#   1  one or more checks failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SNAPSHOT_DIR="$REPO_ROOT/scripts/ops/ruleset-snapshots"
DROP_JSON="$SNAPSHOT_DIR/drop.json"
RESTORE_JSON="$SNAPSHOT_DIR/restore.json"

PASS=0
FAIL=0

_ok() {
    echo "  OK  $1"
    PASS=$((PASS + 1))
}

_fail() {
    echo "  FAIL $1" >&2
    FAIL=$((FAIL + 1))
}

echo "[test-ruleset-snapshots] checking $DROP_JSON and $RESTORE_JSON"

# ── drop.json checks ─────────────────────────────────────────────────────────
echo ""
echo "--- drop.json ---"

if [[ ! -f "$DROP_JSON" ]]; then
    _fail "drop.json not found: $DROP_JSON"
else
    # Check valid JSON
    if python3 -c "import json; json.load(open('$DROP_JSON'))" 2>/dev/null; then
        _ok "drop.json is valid JSON"
    else
        _fail "drop.json is NOT valid JSON"
    fi

    # Check required top-level keys
    for key in name target rules; do
        if python3 -c "
import json, sys
d = json.load(open('$DROP_JSON'))
sys.exit(0 if '$key' in d else 1)
" 2>/dev/null; then
            _ok "drop.json has top-level key: $key"
        else
            _fail "drop.json missing top-level key: $key"
        fi
    done

    # Check no required_status_checks rule
    if python3 -c "
import json, sys
d = json.load(open('$DROP_JSON'))
has_rsc = any(r.get('type') == 'required_status_checks' for r in d.get('rules', []))
sys.exit(1 if has_rsc else 0)
" 2>/dev/null; then
        _ok "drop.json has no required_status_checks rule"
    else
        _fail "drop.json must NOT contain a required_status_checks rule"
    fi

    # Check rules array is non-empty (deletion, non_fast_forward, pull_request expected)
    RULES_COUNT="$(python3 -c "
import json
d = json.load(open('$DROP_JSON'))
print(len(d.get('rules', [])))
" 2>/dev/null || echo 0)"
    if [[ "$RULES_COUNT" -ge 1 ]]; then
        _ok "drop.json rules array is non-empty ($RULES_COUNT rules)"
    else
        _fail "drop.json rules array should be non-empty (expected deletion/non_fast_forward/pull_request)"
    fi
fi

# ── restore.json checks ───────────────────────────────────────────────────────
echo ""
echo "--- restore.json ---"

if [[ ! -f "$RESTORE_JSON" ]]; then
    _fail "restore.json not found: $RESTORE_JSON"
else
    # Check valid JSON
    if python3 -c "import json; json.load(open('$RESTORE_JSON'))" 2>/dev/null; then
        _ok "restore.json is valid JSON"
    else
        _fail "restore.json is NOT valid JSON"
    fi

    # Check required top-level keys
    for key in name target rules; do
        if python3 -c "
import json, sys
d = json.load(open('$RESTORE_JSON'))
sys.exit(0 if '$key' in d else 1)
" 2>/dev/null; then
            _ok "restore.json has top-level key: $key"
        else
            _fail "restore.json missing top-level key: $key"
        fi
    done

    # Check exactly one required_status_checks rule
    RSC_COUNT="$(python3 -c "
import json
d = json.load(open('$RESTORE_JSON'))
print(sum(1 for r in d.get('rules', []) if r.get('type') == 'required_status_checks'))
" 2>/dev/null || echo 0)"
    if [[ "$RSC_COUNT" -eq 1 ]]; then
        _ok "restore.json has exactly one required_status_checks rule"
    else
        _fail "restore.json must have exactly one required_status_checks rule (found $RSC_COUNT)"
    fi

    # Check the three required contexts are present
    EXPECTED_CONTEXTS=("test" "audit" "ACP protocol smoke test (Zed / JetBrains compatible)")
    for ctx in "${EXPECTED_CONTEXTS[@]}"; do
        if python3 -c "
import json, sys
d = json.load(open('$RESTORE_JSON'))
rsc_rules = [r for r in d.get('rules', []) if r.get('type') == 'required_status_checks']
if not rsc_rules:
    sys.exit(1)
params = rsc_rules[0].get('parameters', {})
checks = params.get('required_status_checks', [])
contexts = [c.get('context', '') for c in checks]
sys.exit(0 if '$ctx' in contexts else 1)
" 2>/dev/null; then
            _ok "restore.json required_status_checks includes: $ctx"
        else
            _fail "restore.json required_status_checks missing context: $ctx"
        fi
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "[test-ruleset-snapshots] results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    echo "[test-ruleset-snapshots] FAILED" >&2
    exit 1
fi

echo "[test-ruleset-snapshots] OK"
