#!/usr/bin/env bash
# scripts/ci/test-ruleset-empty-watchdog.sh — META-146
#
# Offline smoke test for scripts/coord/ruleset-empty-watchdog.sh. Stubs `gh`
# and `broadcast.sh` so it runs without network access, and drives the
# empty -> alert -> restored state machine through a fake clock.
#
# Checks:
#   1. transition to EMPTY emits kind=ruleset_required_empty
#   2. outage past CHUMP_RULESET_EMPTY_ALERT_THRESHOLD_S triggers a page
#      (broadcast.sh CRIT WARN call)
#   3. transition back to non-empty emits kind=ruleset_required_restored
#      with a positive outage_duration_s
#
# Exit codes: 0 all pass, 1 one or more failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WATCHDOG_SRC="$REPO_ROOT/scripts/coord/ruleset-empty-watchdog.sh"

PASS=0
FAIL=0
_ok()   { echo "  OK  $1"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL $1" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$WATCHDOG_SRC" ]] || { echo "FAIL: $WATCHDOG_SRC not found"; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cp "$WATCHDOG_SRC" "$TMPDIR_TEST/ruleset-empty-watchdog.sh"
chmod +x "$TMPDIR_TEST/ruleset-empty-watchdog.sh"

LOCK_DIR="$TMPDIR_TEST/.chump-locks"
mkdir -p "$LOCK_DIR"
AMBIENT="$LOCK_DIR/ambient.jsonl"

# ── Stub `gh` — reports FAKE_REQUIRED_TOTAL checks via branch protection ────
cat > "$TMPDIR_TEST/gh" << 'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    case "$2" in
        repos/*/branches/main/protection)
            n="${FAKE_REQUIRED_TOTAL:-0}"
            python3 -c "
import json
checks = [{'context': f'check{i}'} for i in range($n)]
print(json.dumps({'required_status_checks': {'checks': checks}}))
"
            exit 0
            ;;
        repos/*/rulesets)
            echo "[]"
            exit 0
            ;;
    esac
fi
exit 1
GHEOF
chmod +x "$TMPDIR_TEST/gh"

# ── Stub broadcast.sh — records every page call ──────────────────────────────
PAGE_LOG="$TMPDIR_TEST/pages.log"
cat > "$TMPDIR_TEST/broadcast.sh" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$PAGE_LOG"
exit 0
EOF
chmod +x "$TMPDIR_TEST/broadcast.sh"

export PATH="$TMPDIR_TEST:$PATH"
export CHUMP_LOCK_DIR="$LOCK_DIR"
export CHUMP_AMBIENT_LOG="$AMBIENT"
export CHUMP_REPO_NWO="test/repo"
export CHUMP_RULESET_EMPTY_ALERT_THRESHOLD_S=120
export CHUMP_RULESET_EMPTY_REPAGE_S=300

RUN="$TMPDIR_TEST/ruleset-empty-watchdog.sh"

echo "[test-ruleset-empty-watchdog] --- tick 1: total=0, first sight of empty ---"
FAKE_REQUIRED_TOTAL=0 "$RUN" >/dev/null 2>&1
if grep -q '"kind":"ruleset_required_empty"' "$AMBIENT" 2>/dev/null; then
    _ok "emits ruleset_required_empty on empty transition"
else
    _fail "did not emit ruleset_required_empty"
fi
if [[ -s "$PAGE_LOG" ]]; then
    _fail "paged on tick 1 (outage 0s < threshold) — should not have paged yet"
else
    _ok "does not page before threshold is crossed"
fi

echo "[test-ruleset-empty-watchdog] --- tick 2: force empty_since into the past to cross threshold ---"
python3 -c "
import json
from datetime import datetime, timedelta, timezone
state_file = '$LOCK_DIR/ruleset-empty-state.json'
d = json.load(open(state_file))
past = (datetime.now(timezone.utc) - timedelta(seconds=200)).strftime('%Y-%m-%dT%H:%M:%SZ')
d['empty_since'] = past
json.dump(d, open(state_file, 'w'))
"
FAKE_REQUIRED_TOTAL=0 "$RUN" >/dev/null 2>&1
if [[ -s "$PAGE_LOG" ]] && grep -q "CRIT" "$PAGE_LOG"; then
    _ok "pages via broadcast.sh CRIT WARN once threshold crossed"
else
    _fail "did not page after outage exceeded threshold"
fi

echo "[test-ruleset-empty-watchdog] --- tick 3: restore (total>0) ---"
FAKE_REQUIRED_TOTAL=3 "$RUN" >/dev/null 2>&1
if grep -q '"kind":"ruleset_required_restored"' "$AMBIENT" 2>/dev/null; then
    _ok "emits ruleset_required_restored on restore transition"
else
    _fail "did not emit ruleset_required_restored"
fi
RESTORED_LINE="$(grep '"kind":"ruleset_required_restored"' "$AMBIENT" 2>/dev/null | tail -1)"
OUTAGE_S="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('outage_duration_s', -1))" "$RESTORED_LINE" 2>/dev/null || echo -1)"
if [[ "$OUTAGE_S" -gt 0 ]]; then
    _ok "outage_duration_s is positive ($OUTAGE_S)"
else
    _fail "outage_duration_s not positive: $OUTAGE_S"
fi

echo ""
echo "[test-ruleset-empty-watchdog] $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
