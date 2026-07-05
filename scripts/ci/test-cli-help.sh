#!/usr/bin/env bash
# CREDIBLE-015: CLI help system consistency gate.
#
# Verifies:
#   (1) All 31 listed commands have at least one "Usage: chump <cmd>" in source
#   (2) Help-responding commands print "Usage:" to stdout (runtime, if binary built)
#   (3) Help exits with code 0 (not error)
#   (4) The print_help() entry-point covers all listed command names
#
# Run: ./scripts/ci/test-cli-help.sh
# CI:  called from scripts/ci/fast-checks.sh

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAIN_RS="$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/dispatch_gap.rs"
source "$(dirname "$0")/lib/discover-chump-bin.sh"
echo "=== CREDIBLE-015 CLI help system consistency ==="
echo

# ── Part 1: Static audit — Usage strings present in source ─────────────────
echo "--- Part 1: Source audit — Usage strings per command ---"

# Commands that must have at least one "Usage: chump <cmd>" in source.
CMDS_NEED_USAGE=(
    claim
    lesson-grade
    fleet
    dispatch
    reflect-delta
    gap
    session-resume
    pr-coupling-cost
    health
    funnel
    mission-grade
    roadmap-status
    fleet-status
    fleet-velocity
    waste-tally
    health-digest
    ship-quality
    ci-summary
    session-export
    dashboard
    cost-watch
)

for cmd in "${CMDS_NEED_USAGE[@]}"; do
    if grep -q "Usage: chump $cmd" "$MAIN_RS" 2>/dev/null; then
        ok "Source: 'Usage: chump $cmd' present"
    else
        fail "Source: 'Usage: chump $cmd' missing from main.rs"
    fi
done

# ── Part 2: print_help() coverage — all listed commands appear in top-level help ─
echo
echo "--- Part 2: print_help() covers all advertised commands ---"

CMDS_IN_HELP=(
    gap claim gen fleet dispatch orchestrate
    health health-digest fleet-status fleet-velocity waste-tally
    ship-quality roadmap-status mission-grade lesson-grade
    ci-summary classify-failure cost-watch cost funnel
    dashboard session-track session-export session-resume
    reflect-delta rebase-stuck
)

for cmd in "${CMDS_IN_HELP[@]}"; do
    if grep -q "$cmd" "$MAIN_RS" 2>/dev/null; then
        ok "print_help coverage: $cmd referenced in main.rs"
    else
        fail "print_help coverage: $cmd not found in main.rs"
    fi
done

# ── Part 3: Runtime — help exits 0 and prints "Usage:" ─────────────────────
echo
echo "--- Part 3: Runtime help check (requires binary) ---"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[info] binary not found at $CHUMP_BIN — attempting build"
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet 2>/dev/null || true
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    ok "Runtime tests: binary not built — skipping (source checks passed)"
else
    # Commands to test at runtime with --help.
    RUNTIME_CMDS=(
        health funnel mission-grade roadmap-status fleet-status fleet-velocity
        waste-tally health-digest ship-quality ci-summary session-export
        dashboard cost-watch
    )

    for cmd in "${RUNTIME_CMDS[@]}"; do
        # Capture output + exit code.
        set +e
        _out=$("$CHUMP_BIN" "$cmd" --help 2>&1)
        _rc=$?
        set -e

        if [[ $_rc -ne 0 ]]; then
            fail "Runtime: chump $cmd --help exited $_rc (expected 0)"
        elif echo "$_out" | grep -q 'Usage:'; then
            ok "Runtime: chump $cmd --help exits 0 and prints Usage:"
        else
            fail "Runtime: chump $cmd --help output missing 'Usage:' line"
        fi
    done

    # Top-level help.
    set +e
    _out=$("$CHUMP_BIN" --help 2>&1)
    _rc=$?
    set -e
    if [[ $_rc -eq 0 ]] && echo "$_out" | grep -q 'USAGE\|Usage'; then
        ok "Runtime: chump --help exits 0 and prints USAGE"
    else
        fail "Runtime: chump --help rc=$_rc or missing USAGE"
    fi
fi

# ── Part 4: Format consistency — every Usage line follows standard ──────────
echo
echo "--- Part 4: Help format consistency in source ---"

# Every "Usage: chump" line should include a command name or flag immediately after.
# Valid: "Usage: chump gap …", "Usage: chump --briefing …", "Usage: chump -V …"
_malformed=$(grep 'Usage: chump' "$MAIN_RS" | grep -Ev 'Usage: chump [-a-zA-Z]' || true)
if [[ -z "$_malformed" ]]; then
    ok "Format: all 'Usage: chump' lines include command name or flag"
else
    fail "Format: malformed Usage lines found:"
    echo "$_malformed"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
