#!/usr/bin/env bash
# INFRA-1052: chump fleet start --harness <name> CLI surface test.
#
# Validates:
#   1. Unknown --harness → exit 2 with helpful error
#   2. Known --harness (claude/opencode/codex/manual) → run-fleet.sh receives FLEET_HARNESS
#   3. Default (no flag, no env, no config) → "claude" (back-compat)
#   4. Env CHUMP_AGENT_HARNESS overrides default; --harness CLI flag overrides env
#   5. Last-fleet-config.json persists the harness field
#
# Run from repo root: bash scripts/ci/test-infra-1052-fleet-harness.sh
# Exit code: 0 = all pass, 1 = any failure.

set -eu
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Locate the chump binary. Prefer a freshly built one if present in the
# current worktree's target; fall back to the cargo-installed one.
CHUMP_BIN=""
for cand in "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" "$HOME/.cargo/bin/chump" "$(command -v chump || true)"; do
    if [[ -x "$cand" ]]; then CHUMP_BIN="$cand"; break; fi
done
if [[ -z "$CHUMP_BIN" ]]; then
    echo "[SKIP] no chump binary available — build with 'cargo build -p chump' first"
    exit 0
fi

# Sandbox: minimal repo layout with a stub run-fleet.sh that records its env.
SANDBOX=$(mktemp -d)
trap "rm -rf '$SANDBOX'" EXIT
cd "$SANDBOX"
git init --quiet
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p scripts/dispatch .chump
cat > scripts/dispatch/run-fleet.sh <<'STUB'
#!/usr/bin/env bash
# Stub: dump every env var the fleet start passes, then exit 0.
{
    echo "FLEET_SIZE=$FLEET_SIZE"
    echo "FLEET_MODEL=$FLEET_MODEL"
    echo "FLEET_HARNESS=$FLEET_HARNESS"
    echo "FLEET_EFFORT_FILTER=$FLEET_EFFORT_FILTER"
    echo "FLEET_DOMAIN_FILTER=$FLEET_DOMAIN_FILTER"
} > "${RECORD:-/tmp/test-infra-1052-record.txt}"
exit 0
STUB
chmod +x scripts/dispatch/run-fleet.sh
# Need at least one tracked file for git rev-parse to work; commit the stub.
git add scripts/dispatch/run-fleet.sh
git -c commit.gpgsign=false commit --quiet -m "sandbox: stub run-fleet.sh"

# Use an isolated HOME so last-fleet-config.json doesn't pollute the real one.
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.chump"

# Helper: run `chump fleet start <args>` and capture exit code, stdout, stderr.
run_start() {
    local record="$1"; shift
    RECORD="$record" "$CHUMP_BIN" fleet start "$@" </dev/null
}

# --- Test 1: unknown --harness exits 2 with helpful error ---
record="$SANDBOX/r1.txt"
set +e
err=$(run_start "$record" --harness foobar 2>&1 1>/dev/null)
rc=$?
set -e
if [[ $rc -eq 2 ]] && echo "$err" | grep -q "unknown --harness 'foobar'" && echo "$err" | grep -q "claude, opencode, codex, manual"; then
    pass "unknown --harness → exit 2 with helpful error"
else
    fail "unknown --harness expected exit 2 + descriptive error, got rc=$rc, err: $err"
fi

# --- Test 2: each known harness reaches run-fleet.sh as FLEET_HARNESS ---
for h in claude opencode codex manual; do
    record="$SANDBOX/r-$h.txt"
    run_start "$record" --harness "$h" --size 1 >/dev/null 2>&1 || true
    if grep -q "^FLEET_HARNESS=$h$" "$record"; then
        pass "--harness $h → FLEET_HARNESS=$h reaches run-fleet.sh"
    else
        fail "--harness $h not forwarded (record: $(cat "$record"))"
    fi
done

# --- Test 3: no flag, no env, no config → default claude ---
record="$SANDBOX/r-default.txt"
unset CHUMP_AGENT_HARNESS
run_start "$record" --size 1 >/dev/null 2>&1 || true
if grep -q "^FLEET_HARNESS=claude$" "$record"; then
    pass "default (no flag) → FLEET_HARNESS=claude (back-compat)"
else
    fail "default expected claude, got: $(grep FLEET_HARNESS "$record" || echo 'unset')"
fi

# --- Test 4a: env CHUMP_AGENT_HARNESS=opencode overrides default ---
record="$SANDBOX/r-env.txt"
CHUMP_AGENT_HARNESS=opencode run_start "$record" --size 1 >/dev/null 2>&1 || true
if grep -q "^FLEET_HARNESS=opencode$" "$record"; then
    pass "env CHUMP_AGENT_HARNESS=opencode → FLEET_HARNESS=opencode"
else
    fail "env override failed (record: $(cat "$record"))"
fi

# --- Test 4b: --harness flag overrides env ---
record="$SANDBOX/r-flag-wins.txt"
CHUMP_AGENT_HARNESS=opencode run_start "$record" --harness codex --size 1 >/dev/null 2>&1 || true
if grep -q "^FLEET_HARNESS=codex$" "$record"; then
    pass "--harness flag overrides env (canonical priority)"
else
    fail "flag-over-env failed (record: $(cat "$record"))"
fi

# --- Test 5: last-fleet-config.json persists the harness field ---
last_cfg="$HOME/.chump/last-fleet-config.json"
if [[ -f "$last_cfg" ]] && grep -q '"harness":' "$last_cfg"; then
    pass "last-fleet-config.json contains 'harness' field"
else
    fail "last-fleet-config.json missing harness (content: $(cat "$last_cfg" 2>/dev/null))"
fi

echo
echo "===== INFRA-1052 results: $PASS pass, $FAIL fail ====="
[[ $FAIL -eq 0 ]]
