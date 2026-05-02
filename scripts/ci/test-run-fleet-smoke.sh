#!/usr/bin/env bash
# test-run-fleet-smoke.sh — INFRA-203: smoke test for the fleet launcher.
#
# Verifies:
#   1. All three scripts (run-fleet.sh, worker.sh, control.sh) parse cleanly.
#   2. _pick_gap.py runs without error on empty input.
#   3. _pick_gap.py applies priority/domain/effort/exclude filters correctly
#      against synthetic gap JSON.
#   4. run-fleet.sh FLEET_DRY_RUN=1 path prints the plan and exits 0 without
#      touching tmux.
#   5. run-fleet.sh FLEET_SIZE=0 with a nonexistent session is a no-op.
#   6. run-fleet.sh refuses to start when tmux session already exists
#      (returns 2). Skipped if tmux is not on PATH.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DISPATCH_DIR="$REPO_ROOT/scripts/dispatch"

echo "[smoke] 1) bash syntax check"
bash -n "$DISPATCH_DIR/run-fleet.sh"
bash -n "$DISPATCH_DIR/worker.sh"
bash -n "$DISPATCH_DIR/control.sh"
python3 -c "import ast; ast.parse(open('$DISPATCH_DIR/_pick_gap.py').read())"
echo "    OK"

echo "[smoke] 2) _pick_gap.py: empty input"
out="$(python3 "$DISPATCH_DIR/_pick_gap.py" < /dev/null)"
if [ -n "$out" ]; then
    echo "    FAIL: empty input produced output: $out" >&2
    exit 1
fi
echo "    OK"

echo "[smoke] 3) _pick_gap.py: filter logic"
TMP=$(mktemp -t fleet-test.XXXXXX)
cat > "$TMP" <<'JSON'
[
    {"id": "EVAL-001",  "domain": "eval",  "priority": "P0", "effort": "s", "depends_on": ""},
    {"id": "INFRA-100", "domain": "infra", "priority": "P2", "effort": "s", "depends_on": ""},
    {"id": "INFRA-101", "domain": "infra", "priority": "P1", "effort": "l", "depends_on": ""},
    {"id": "INFRA-102", "domain": "infra", "priority": "P1", "effort": "s", "depends_on": "X-1"},
    {"id": "INFRA-103", "domain": "infra", "priority": "P1", "effort": "s", "depends_on": "", "created_at": 100},
    {"id": "INFRA-104", "domain": "infra", "priority": "P0", "effort": "m", "depends_on": "", "created_at": 200},
    {"id": "DOC-001",   "domain": "doc",   "priority": "P1", "effort": "xs","depends_on": "", "created_at": 300}
]
JSON

# Default filters: P0,P1 / any domain / xs,s,m / exclude EVAL-/RESEARCH-/META-
got="$(GAP_JSON_FILE="$TMP" \
       FLEET_PRIORITY_FILTER="P0,P1" \
       FLEET_DOMAIN_FILTER="" \
       FLEET_EFFORT_FILTER="xs,s,m" \
       EXCLUDE_RE="^(EVAL-|RESEARCH-|META-)" \
       ACTIVE_GAPS="" \
       python3 "$DISPATCH_DIR/_pick_gap.py")"
# Expect INFRA-104 (P0 wins over all P1s; EVAL-001 excluded; INFRA-100 wrong prio;
# INFRA-101 wrong effort; INFRA-102 has depends_on)
if [ "$got" != "INFRA-104" ]; then
    echo "    FAIL: expected INFRA-104, got '$got'" >&2
    cat "$TMP" >&2
    rm -f "$TMP"
    exit 1
fi
echo "    OK (got INFRA-104)"

# Domain filter: limit to 'doc' → DOC-001 wins
got="$(GAP_JSON_FILE="$TMP" \
       FLEET_PRIORITY_FILTER="P0,P1" \
       FLEET_DOMAIN_FILTER="DOC" \
       FLEET_EFFORT_FILTER="xs,s,m" \
       EXCLUDE_RE="^(EVAL-|RESEARCH-|META-)" \
       ACTIVE_GAPS="" \
       python3 "$DISPATCH_DIR/_pick_gap.py")"
if [ "$got" != "DOC-001" ]; then
    echo "    FAIL: domain=DOC expected DOC-001, got '$got'" >&2
    rm -f "$TMP"
    exit 1
fi
echo "    OK (domain=DOC → DOC-001)"

# Active-gaps mask: hide INFRA-104. Next pick is highest-rank P1 with
# smallest effort: DOC-001 (xs effort) beats INFRA-103 (s effort).
got="$(GAP_JSON_FILE="$TMP" \
       FLEET_PRIORITY_FILTER="P0,P1" \
       FLEET_DOMAIN_FILTER="" \
       FLEET_EFFORT_FILTER="xs,s,m" \
       EXCLUDE_RE="^(EVAL-|RESEARCH-|META-)" \
       ACTIVE_GAPS="INFRA-104" \
       python3 "$DISPATCH_DIR/_pick_gap.py")"
if [ "$got" != "DOC-001" ]; then
    echo "    FAIL: active=INFRA-104 expected DOC-001 (lowest effort wins), got '$got'" >&2
    rm -f "$TMP"
    exit 1
fi
echo "    OK (active mask → DOC-001)"

# Also mask DOC-001 → INFRA-103 (next P1 with s effort)
got="$(GAP_JSON_FILE="$TMP" \
       FLEET_PRIORITY_FILTER="P0,P1" \
       FLEET_DOMAIN_FILTER="" \
       FLEET_EFFORT_FILTER="xs,s,m" \
       EXCLUDE_RE="^(EVAL-|RESEARCH-|META-)" \
       ACTIVE_GAPS="INFRA-104 DOC-001" \
       python3 "$DISPATCH_DIR/_pick_gap.py")"
if [ "$got" != "INFRA-103" ]; then
    echo "    FAIL: active=INFRA-104,DOC-001 expected INFRA-103, got '$got'" >&2
    rm -f "$TMP"
    exit 1
fi
echo "    OK (double mask → INFRA-103)"
rm -f "$TMP"

echo "[smoke] 4) run-fleet.sh FLEET_DRY_RUN=1 path"
out="$(FLEET_DRY_RUN=1 FLEET_SIZE=3 "$DISPATCH_DIR/run-fleet.sh" 2>&1)"
echo "$out" | grep -q "FLEET_DRY_RUN=1 — exiting before tmux" || {
    echo "    FAIL: dry-run did not bail out" >&2
    echo "$out" >&2
    exit 1
}
echo "$out" | grep -q "size          : 3" || {
    echo "    FAIL: size not echoed" >&2
    exit 1
}
echo "    OK"

echo "[smoke] 5) run-fleet.sh FLEET_SIZE=0 noop"
out="$(FLEET_SIZE=0 FLEET_SESSION="ci-noop-$$" "$DISPATCH_DIR/run-fleet.sh" 2>&1)"
echo "$out" | grep -q "no session named .*nothing to do" || {
    echo "    FAIL: tear-down noop did not match expected message" >&2
    echo "$out" >&2
    exit 1
}
echo "    OK"

echo "[smoke] 6) refuses to start over an existing session"
if command -v tmux >/dev/null 2>&1; then
    SESSION="ci-fleet-collide-$$"
    tmux new-session -d -s "$SESSION" "sleep 60" 2>/dev/null
    set +e
    out="$(FLEET_DRY_RUN=0 FLEET_SIZE=1 FLEET_SESSION="$SESSION" "$DISPATCH_DIR/run-fleet.sh" 2>&1)"
    rc=$?
    set -e
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    if [ "$rc" -ne 2 ]; then
        echo "    FAIL: expected exit 2 on session collision, got $rc" >&2
        echo "$out" >&2
        exit 1
    fi
    echo "    OK (rc=2)"
else
    echo "    SKIP (tmux not on PATH)"
fi

echo
echo "[smoke] all checks passed."
