#!/usr/bin/env bash
# scripts/ci/test-pillar-balance-alerts.sh — INFRA-902
#
# Tests scripts/ops/pillar-balance-check.sh:
#   AC1: reads state.db via chump gap list --status open
#   AC2: pillar count < 2  → kind=pillar_balance_alert (pillar, count, floor=2)
#   AC3: pillar > 50% pool → kind=pillar_balance_overweight (pillar, count, pct)
#   AC4: exits non-zero when any alert fired
#   AC5: chump gap audit-priorities calls the script
#   AC6: 8+ tests

set -euo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ops/pillar-balance-check.sh"

# ── Binary discovery (INFRA-481: honour cargo metadata target_directory) ──────
TARGET_DIR="$( cd "$REPO_ROOT" && \
    cargo metadata --no-deps --format-version 1 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['target_directory'])" \
    2>/dev/null || echo "$REPO_ROOT/target" )"
CHUMP_BIN="$TARGET_DIR/debug/chump"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[build] building chump binary…"
    (cd "$REPO_ROOT" && cargo build --bin chump -q 2>&1 | tail -5)
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    fail "chump binary not found at $CHUMP_BIN"
    echo "TOTAL: PASS=$PASS  FAIL=$FAIL"; exit 1
fi

echo "=== INFRA-902 pillar-balance-alerts tests ==="
echo

# ── Test 1: script exists and is executable ───────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "pillar-balance-check.sh exists and is executable"
else
    fail "pillar-balance-check.sh not found or not executable"
fi

# ── Fixture helpers ────────────────────────────────────────────────────────────
setup_repo() {
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/.chump" "$tmp/.chump-locks" "$tmp/docs/gaps"
    (
        cd "$tmp"
        git init -q -b main . 2>/dev/null || git init -q . 2>/dev/null || true
        git config user.email "test@ci.local"
        git config user.name  "CI"
    )
    echo "$tmp"
}

reserve_gap() {
    local title="$1" priority="${2:-P1}" effort="${3:-xs}" ac="${4:-verify it works}"
    "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --priority "$priority" \
        --effort   "$effort" \
        --title    "$title" \
        --acceptance-criteria "$ac" \
        --force \
        --force-duplicate 2>/dev/null || true
}

run_check() {
    bash "$SCRIPT" >/dev/null 2>&1
    echo $?
}

# ── Test 2: balanced pillars (2 each) exit 0 ──────────────────────────────────
echo "[Test 2] Balanced pillars (2 per pillar)"
TMP="$(setup_repo)"
(
    cd "$TMP"
    export CHUMP_BIN
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

    for p in EFFECTIVE CREDIBLE RESILIENT "ZERO-WASTE"; do
        reserve_gap "${p}: balanced-a"
        reserve_gap "${p}: balanced-b"
    done

    if bash "$SCRIPT" >/dev/null 2>&1; then
        ok "balanced pillars exit 0"
    else
        fail "balanced pillars should exit 0"
    fi
)
rm -rf "$TMP"

# ── Test 3: under-fed pillar exits non-zero ────────────────────────────────────
echo "[Test 3] Under-fed pillar exits non-zero"
TMP="$(setup_repo)"
(
    cd "$TMP"
    export CHUMP_BIN
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

    # 2 EFFECTIVE, 2 CREDIBLE, 1 RESILIENT (under floor), 0 ZERO-WASTE (under floor)
    reserve_gap "EFFECTIVE: under-a"
    reserve_gap "EFFECTIVE: under-b"
    reserve_gap "CREDIBLE: under-a"
    reserve_gap "CREDIBLE: under-b"
    reserve_gap "RESILIENT: under-a"

    : > "$AMBIENT"
    exit_code=0
    bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        ok "under-fed pillar exits non-zero"
    else
        fail "under-fed pillar should exit non-zero"
    fi
)
rm -rf "$TMP"

# ── Test 4: under-fed alert emitted with correct schema ───────────────────────
echo "[Test 4] Under-fed alert schema"
TMP="$(setup_repo)"
(
    cd "$TMP"
    export CHUMP_BIN
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

    reserve_gap "EFFECTIVE: under-a"
    reserve_gap "EFFECTIVE: under-b"
    reserve_gap "CREDIBLE: under-a"
    reserve_gap "CREDIBLE: under-b"
    reserve_gap "RESILIENT: under-a"
    : > "$AMBIENT"
    bash "$SCRIPT" >/dev/null 2>&1 || true

    if grep -q '"kind":"pillar_balance_alert"' "$AMBIENT" 2>/dev/null; then
        ok "pillar_balance_alert event emitted"
    else
        fail "pillar_balance_alert event not found"
    fi

    if grep '"pillar_balance_alert"' "$AMBIENT" 2>/dev/null | \
       jq -e '.pillar and (.count != null) and (.floor == 2)' >/dev/null 2>&1; then
        ok "pillar_balance_alert has pillar, count, floor=2"
    else
        fail "pillar_balance_alert missing required fields or floor != 2"
    fi
)
rm -rf "$TMP"

# ── Test 5: overweight pillar alert ───────────────────────────────────────────
echo "[Test 5] Overweight pillar alert"
TMP="$(setup_repo)"
(
    cd "$TMP"
    export CHUMP_BIN
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

    # 6 EFFECTIVE + 1 each of the rest = 9 total; EFFECTIVE = 67% > 50%
    for i in $(seq 1 6); do reserve_gap "EFFECTIVE: heavy-$i"; done
    reserve_gap "CREDIBLE: heavy-1"
    reserve_gap "RESILIENT: heavy-1"
    reserve_gap "ZERO-WASTE: heavy-1"
    : > "$AMBIENT"
    bash "$SCRIPT" >/dev/null 2>&1 || true

    if grep -q '"kind":"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null; then
        ok "pillar_balance_overweight event emitted"
    else
        fail "pillar_balance_overweight event not found"
    fi

    if grep '"pillar_balance_overweight"' "$AMBIENT" 2>/dev/null | \
       jq -e '.pillar and (.count != null) and (.pct > 50)' >/dev/null 2>&1; then
        ok "pillar_balance_overweight has pillar, count, pct>50"
    else
        fail "pillar_balance_overweight missing required fields or pct <= 50"
    fi
)
rm -rf "$TMP"

# ── Test 6: non-pickable gaps are ignored ─────────────────────────────────────
echo "[Test 6] Non-pickable gaps ignored"
TMP="$(setup_repo)"
(
    cd "$TMP"
    export CHUMP_BIN
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

    # 2 pickable per pillar (should be balanced)
    for p in EFFECTIVE CREDIBLE RESILIENT "ZERO-WASTE"; do
        reserve_gap "${p}: pickable-a"
        reserve_gap "${p}: pickable-b"
    done
    # P2 gaps should be ignored
    reserve_gap "EFFECTIVE: p2-ignored" P2 xs "verify it"
    # medium effort gaps should be ignored
    reserve_gap "EFFECTIVE: medium-ignored" P1 m "verify it"
    # TODO AC gaps should be ignored
    reserve_gap "EFFECTIVE: todo-ac-ignored" P1 xs "TODO"

    : > "$AMBIENT"
    # Still balanced because non-pickable gaps are filtered out
    if bash "$SCRIPT" >/dev/null 2>&1; then
        ok "non-pickable gaps ignored (balanced exits 0)"
    else
        fail "non-pickable gaps should be ignored — balanced pillars should exit 0"
    fi
)
rm -rf "$TMP"

# ── Test 7: Bash 3.2 compat — script runs under /bin/bash ────────────────────
echo "[Test 7] Bash 3.2 compatibility"
if /bin/bash --version 2>&1 | grep -q 'version [345]'; then
    TMP="$(setup_repo)"
    (
        cd "$TMP"
        export CHUMP_BIN
        export CHUMP_REPO="$TMP"
        export CHUMP_WORKTREE_ROOT="$TMP"
        export CHUMP_HOME="$TMP"
        export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
        export FLEET_029_AMBIENT_GLANCE_SKIP=1
        export CHUMP_RESERVE_NO_AUTOSTAGE=1
        export CHUMP_RESERVE_SCAN_OPEN_PRS=0
        export AMBIENT="$TMP/.chump-locks/ambient.jsonl"

        for p in EFFECTIVE CREDIBLE RESILIENT "ZERO-WASTE"; do
            reserve_gap "${p}: compat-a"
            reserve_gap "${p}: compat-b"
        done

        if /bin/bash "$SCRIPT" >/dev/null 2>&1; then
            ok "script runs under /bin/bash (Bash 3.2 compat)"
        else
            fail "script failed under /bin/bash — check for declare -A / mapfile"
        fi
    )
    rm -rf "$TMP"
else
    ok "Bash 3.2 compat check skipped (unusual shell env)"
fi

# ── Test 8: mkdir -p guards ambient dir creation ─────────────────────────────
echo "[Test 8] mkdir -p for ambient dir"
TMP="$(setup_repo)"
(
    cd "$TMP"
    export CHUMP_BIN
    export CHUMP_REPO="$TMP"
    export CHUMP_WORKTREE_ROOT="$TMP"
    export CHUMP_HOME="$TMP"
    export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
    export FLEET_029_AMBIENT_GLANCE_SKIP=1
    export CHUMP_RESERVE_NO_AUTOSTAGE=1
    export CHUMP_RESERVE_SCAN_OPEN_PRS=0
    # Point ambient to a not-yet-existing sub-directory.
    NEWDIR="$TMP/.chump-locks/nested/subdir"
    export AMBIENT="$NEWDIR/ambient.jsonl"

    for p in EFFECTIVE CREDIBLE RESILIENT "ZERO-WASTE"; do
        reserve_gap "${p}: mkdir-a"
        reserve_gap "${p}: mkdir-b"
    done

    # Script should create the dir automatically.
    bash "$SCRIPT" >/dev/null 2>&1 || true
    if [[ -d "$NEWDIR" ]]; then
        ok "script created ambient parent dir (mkdir -p works)"
    else
        fail "script did not create ambient parent dir"
    fi
)
rm -rf "$TMP"

# ── Test 9: audit-priorities wires the script ─────────────────────────────────
echo "[Test 9] chump gap audit-priorities calls pillar-balance-check.sh"
if grep -q 'pillar.balance.check\|pillar_balance_check\|pillar-balance' "$REPO_ROOT/src/main.rs" 2>/dev/null; then
    ok "audit-priorities references pillar-balance-check in main.rs"
else
    fail "audit-priorities does not call pillar-balance-check (wiring missing)"
fi

echo
echo "TOTAL: PASS=$PASS  FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
