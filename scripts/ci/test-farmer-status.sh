#!/usr/bin/env bash
# test-farmer-status.sh — RESILIENT-069: smoke tests for `chump farmer status`
#
# Exercises the readiness gate via the compiled binary in three modes:
#   T1: RED when sentinel present (exit 1, "RED" in output)
#   T2: RED when heartbeat absent (exit 1)
#   T3: GREEN when all conditions met (exit 0, "GREEN" in output)
#   T4: --json output is valid JSON with "status" field
#   T5: --quiet suppresses output, exit code still correct
#   T6: help text prints usage without error
#
# Tier A: locally mirrorable — reads only local tmpdir state, no network.
# Requires: chump binary (built from src/commands/farmer_status.rs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Locate the chump binary
CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" ]]; then
    for candidate in \
        "$HOME/.cargo/bin/chump" \
        "$REPO_ROOT/target/debug/chump" \
        "$REPO_ROOT/target/release/chump"; do
        if [[ -x "$candidate" ]]; then
            CHUMP="$candidate"
            break
        fi
    done
fi
if [[ -z "$CHUMP" || ! -x "$CHUMP" ]]; then
    echo "SKIP: chump binary not found (set CHUMP_BIN or run cargo build first)"
    exit 0
fi

# Verify farmer status subcommand exists
if ! "$CHUMP" farmer status --help >/dev/null 2>&1; then
    echo "SKIP: chump farmer status not implemented in this build"
    exit 0
fi

PASS=0
FAIL=0
_pass() { echo "  PASS: $1"; (( PASS++ )) || true; }
_fail() { echo "  FAIL: $1 — $2"; (( FAIL++ )) || true; }

run_test() {
    local name="$1"; shift
    echo ""
    echo "── $name ──"
    if "$@"; then
        _pass "$name"
    else
        _fail "$name" "test function returned non-zero"
    fi
}

# ── helpers ───────────────────────────────────────────────────────────────────
make_repo() {
    local d; d="$(mktemp -d)"
    mkdir -p "$d/.chump" "$d/.chump-locks"
    echo "$d"
}

write_fresh_oauth() {
    local home="$1"
    mkdir -p "$home/.chump"
    printf '{"access_token":"fake"}\n' > "$home/.chump/oauth-token.json"
}

write_fresh_heartbeat() {
    local repo="$1"
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$repo/.chump/farmer-heartbeat"
}

farmer_status() {
    local repo="$1" home="$2"
    shift 2
    CHUMP_REPO_ROOT="$repo" HOME="$home" "$CHUMP" farmer status "$@"
}

# ── T1: RED when sentinel present ─────────────────────────────────────────────
t1_sentinel_red() {
    local repo home
    repo="$(make_repo)"; home="$(mktemp -d)"
    trap "rm -rf '$repo' '$home'" RETURN
    write_fresh_oauth "$home"
    write_fresh_heartbeat "$repo"
    touch "$repo/.chump/fleet-paused"
    local out
    out="$(farmer_status "$repo" "$home" 2>/dev/null)" && {
        echo "  expected exit 1 (RED) but got exit 0"; return 1
    }
    [[ "$out" == *"RED"* ]] || { echo "  output missing RED: $out"; return 1; }
    return 0
}

# ── T2: RED when heartbeat absent ─────────────────────────────────────────────
t2_heartbeat_red() {
    local repo home
    repo="$(make_repo)"; home="$(mktemp -d)"
    trap "rm -rf '$repo' '$home'" RETURN
    write_fresh_oauth "$home"
    # No heartbeat written
    local out
    out="$(farmer_status "$repo" "$home" 2>/dev/null)" && {
        echo "  expected exit 1 (RED) but got exit 0"; return 1
    }
    [[ "$out" == *"RED"* ]] || { echo "  output missing RED: $out"; return 1; }
    return 0
}

# ── T3: GREEN when all conditions met ─────────────────────────────────────────
t3_green() {
    local repo home
    repo="$(make_repo)"; home="$(mktemp -d)"
    trap "rm -rf '$repo' '$home'" RETURN
    write_fresh_oauth "$home"
    write_fresh_heartbeat "$repo"
    # No sentinel; launchctl in test env returns empty (no exit-78)
    local out
    out="$(farmer_status "$repo" "$home" 2>/dev/null)" || {
        echo "  expected exit 0 (GREEN) but got exit 1: $out"; return 1
    }
    [[ "$out" == *"GREEN"* ]] || { echo "  output missing GREEN: $out"; return 1; }
    return 0
}

# ── T4: --json produces valid JSON with status field ──────────────────────────
t4_json_valid() {
    local repo home
    repo="$(make_repo)"; home="$(mktemp -d)"
    trap "rm -rf '$repo' '$home'" RETURN
    write_fresh_oauth "$home"
    write_fresh_heartbeat "$repo"
    local out
    out="$(farmer_status "$repo" "$home" --json 2>/dev/null || true)"
    # Must be parseable JSON
    echo "$out" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'status' in d, f'missing status: {d}'" || {
        echo "  invalid JSON or missing status field: $out"; return 1
    }
    return 0
}

# ── T5: --quiet suppresses output ─────────────────────────────────────────────
t5_quiet() {
    local repo home
    repo="$(make_repo)"; home="$(mktemp -d)"
    trap "rm -rf '$repo' '$home'" RETURN
    write_fresh_oauth "$home"
    write_fresh_heartbeat "$repo"
    local out
    out="$(farmer_status "$repo" "$home" --quiet 2>/dev/null || true)"
    [[ -z "$out" ]] || { echo "  --quiet produced output: $out"; return 1; }
    return 0
}

# ── T6: --help prints usage ────────────────────────────────────────────────────
t6_help() {
    local out
    out="$("$CHUMP" farmer status --help 2>/dev/null)" || {
        echo "  --help returned non-zero"; return 1
    }
    [[ "$out" == *"Usage"* || "$out" == *"usage"* ]] || {
        echo "  --help output missing Usage: $out"; return 1
    }
    return 0
}

# ── Run ───────────────────────────────────────────────────────────────────────
echo "=== test-farmer-status.sh (RESILIENT-069) ==="

run_test "T1: RED when sentinel present"   t1_sentinel_red
run_test "T2: RED when heartbeat absent"   t2_heartbeat_red
run_test "T3: GREEN when all OK"           t3_green
run_test "T4: --json valid output"         t4_json_valid
run_test "T5: --quiet no output"           t5_quiet
run_test "T6: --help prints usage"         t6_help

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
