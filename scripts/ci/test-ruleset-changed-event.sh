#!/usr/bin/env bash
# scripts/ci/test-ruleset-changed-event.sh — META-146
#
# Offline smoke test: scripts/coord/required-check-monitor.sh must emit
# kind=ruleset_changed on ANY modification to main's required CI checks —
# additions, removals, or both — not just on additions (which already had
# kind=required_check_added from INFRA-1395).
#
# Stubs `gh` so it runs without network access.
#
# Exit codes: 0 all pass, 1 one or more failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MONITOR_SRC="$REPO_ROOT/scripts/coord/required-check-monitor.sh"

PASS=0
FAIL=0
_ok()   { echo "  OK  $1"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL $1" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$MONITOR_SRC" ]] || { echo "FAIL: $MONITOR_SRC not found"; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cp "$MONITOR_SRC" "$TMPDIR_TEST/required-check-monitor.sh"
chmod +x "$TMPDIR_TEST/required-check-monitor.sh"

LOCK_DIR="$TMPDIR_TEST/.chump-locks"
mkdir -p "$LOCK_DIR"
AMBIENT="$LOCK_DIR/ambient.jsonl"
SNAPSHOT_FILE="$LOCK_DIR/required-check-snapshot.json"

# ── Stub `gh` — _get_required_checks() calls:
#      gh api repos/.../branches/main/protection --jq '.required_status_checks.contexts // [] | .[]'
#    Real gh applies --jq server-side and returns one context per line; emulate
#    that directly from $FAKE_CONTEXTS (comma-separated).
cat > "$TMPDIR_TEST/gh" << 'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
    for a in "$@"; do
        if [[ "$a" == repos/*/branches/main/protection ]]; then
            IFS=',' read -ra ctxs <<< "${FAKE_CONTEXTS:-}"
            for c in "${ctxs[@]}"; do
                [[ -n "$c" ]] && echo "$c"
            done
            exit 0
        fi
    done
    exit 1
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo ""
    exit 0
fi
exit 1
GHEOF
chmod +x "$TMPDIR_TEST/gh"

export PATH="$TMPDIR_TEST:$PATH"
export CHUMP_AMBIENT_LOG="$AMBIENT"

cd "$TMPDIR_TEST" || exit 1
RUN="$TMPDIR_TEST/required-check-monitor.sh"

echo "[test-ruleset-changed-event] --- run 1: first run writes snapshot, no emit ---"
FAKE_CONTEXTS="audit,test" "$RUN" --check-only >/dev/null 2>&1
if [[ ! -s "$AMBIENT" ]]; then
    _ok "first run (no prior snapshot) does not emit"
else
    _fail "first run unexpectedly emitted: $(cat "$AMBIENT")"
fi

echo "[test-ruleset-changed-event] --- run 2: add a check ---"
FAKE_CONTEXTS="audit,test,new-check" "$RUN" --check-only >/dev/null 2>&1
if grep -q '"kind":"ruleset_changed"' "$AMBIENT"; then
    _ok "emits ruleset_changed on addition"
else
    _fail "did not emit ruleset_changed on addition"
fi
if grep -q '"kind":"required_check_added"' "$AMBIENT"; then
    _ok "still emits required_check_added on addition (backward compat)"
else
    _fail "regressed: required_check_added no longer emitted"
fi

echo "[test-ruleset-changed-event] --- run 3: remove a check (no additions) ---"
: > "$AMBIENT"
FAKE_CONTEXTS="audit" "$RUN" --check-only >/dev/null 2>&1
if grep -q '"kind":"ruleset_changed"' "$AMBIENT"; then
    _ok "emits ruleset_changed on removal-only (no addition)"
else
    _fail "did not emit ruleset_changed on removal-only change"
fi
LINE="$(grep '"kind":"ruleset_changed"' "$AMBIENT" | tail -1)"
REASON="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('reason',''))" "$LINE" 2>/dev/null || echo "")"
if [[ "$REASON" == *removed* ]]; then
    _ok "reason field mentions removal ($REASON)"
else
    _fail "reason field does not mention removal: $REASON"
fi

echo "[test-ruleset-changed-event] --- run 4: no change ---"
: > "$AMBIENT"
FAKE_CONTEXTS="audit" "$RUN" --check-only >/dev/null 2>&1
if [[ ! -s "$AMBIENT" ]]; then
    _ok "no-op tick emits nothing"
else
    _fail "no-op tick unexpectedly emitted: $(cat "$AMBIENT")"
fi

echo ""
echo "[test-ruleset-changed-event] $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
