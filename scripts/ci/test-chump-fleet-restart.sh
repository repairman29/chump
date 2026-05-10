#!/usr/bin/env bash
# test-chump-fleet-restart.sh — INFRA-610
#
# End-to-end test for `chump fleet restart`.
# Stubs fleet-restart.sh and run-fleet.sh so no real tmux or API calls happen.
# Verifies that:
#   (a) `chump fleet restart` takes a before-restart snapshot
#   (b) `chump fleet restart` invokes fleet-restart.sh with FLEET_SIZE
#   (c) `chump fleet restart --size N` overrides the size
#   (d) `chump fleet restart` without fleet-restart.sh exits non-zero
#   (e) help text includes restart

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    for candidate in \
        "$REPO_ROOT/target/debug/chump" \
        "$REPO_ROOT/target/release/chump" \
        "$(command -v chump 2>/dev/null || true)"
    do
        if [[ -x "$candidate" ]]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$CHUMP_BIN" ]]; then
    echo "SKIP: chump binary not found (run 'cargo build' first or set CHUMP_BIN=...)" >&2
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fake repo layout ──────────────────────────────────────────────────────────
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/scripts/dispatch"
mkdir -p "$FAKE_REPO/.chump-locks"
mkdir -p "$FAKE_REPO/.chump/restart-snapshots"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" commit --allow-empty -q -m "init"

# ── Stub fleet-restart.sh ─────────────────────────────────────────────────────
cat > "$FAKE_REPO/scripts/dispatch/fleet-restart.sh" <<'SH'
#!/usr/bin/env bash
echo "fleet-restart FLEET_SIZE=${FLEET_SIZE:-} FLEET_SESSION=${FLEET_SESSION:-}"
touch "$FLAG_FILE"
SH
chmod +x "$FAKE_REPO/scripts/dispatch/fleet-restart.sh"

# ── Stub run-fleet.sh ─────────────────────────────────────────────────────────
cat > "$FAKE_REPO/scripts/dispatch/run-fleet.sh" <<'SH'
#!/usr/bin/env bash
echo "run-fleet FLEET_SIZE=${FLEET_SIZE:-}"
SH
chmod +x "$FAKE_REPO/scripts/dispatch/run-fleet.sh"

# ── Stub fleet-status.sh (needed for some tests) ──────────────────────────────
cat > "$FAKE_REPO/scripts/dispatch/fleet-status.sh" <<'SH'
#!/usr/bin/env bash
echo "fleet-status args=$*"
SH
chmod +x "$FAKE_REPO/scripts/dispatch/fleet-status.sh"

# ── Write a dummy lease file so snapshot has content ──────────────────────────
echo '{"gap_id":"TEST-A","kind":"lease"}' > "$FAKE_REPO/.chump-locks/test-lease.json"

# ── Common env: point chump at the fake repo ──────────────────────────────────
_env=(
    CHUMP_REPO="$FAKE_REPO"
    HOME="$TMP/home"
)
mkdir -p "$TMP/home/.chump"

PASS=0
FAIL=0

assert_pass() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $label"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label (expected exit 0)"
        (( FAIL++ )) || true
    fi
}

assert_fail() {
    local label="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        echo "  PASS: $label (non-zero exit as expected)"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label (expected non-zero exit)"
        (( FAIL++ )) || true
    fi
}

assert_output_contains() {
    local label="$1"
    local pattern="$2"
    local actual="$3"
    if echo "$actual" | grep -qF "$pattern"; then
        echo "  PASS: $label"
        (( PASS++ )) || true
    else
        echo "  FAIL: $label — expected '$pattern' in:"
        echo "$actual" | sed 's/^/    /'
        (( FAIL++ )) || true
    fi
}

# ── Test 1: fleet restart takes snapshot and invokes fleet-restart.sh ─────────
echo "=== Test 1: chump fleet restart ==="
FLAG_FILE="$TMP/restart-called-1" export FLAG_FILE
out=$(env "${_env[@]}" "$CHUMP_BIN" fleet restart 2>&1 || true)
assert_output_contains "fleet restart prints snapshot" "snapshot saved" "$out"
assert_output_contains "fleet restart invokes fleet-restart" "fleet-restart" "$out"
snap_count=$(ls "$FAKE_REPO/.chump/restart-snapshots/"*.json 2>/dev/null | wc -l)
if [[ "$snap_count" -ge 1 ]]; then
    echo "  PASS: snapshot file created (count=$snap_count)"
    (( PASS++ )) || true
else
    echo "  FAIL: no snapshot file found"
    (( FAIL++ )) || true
fi
if [[ -f "$FLAG_FILE" ]]; then
    echo "  PASS: fleet-restart.sh was invoked"
    (( PASS++ )) || true
else
    echo "  FAIL: fleet-restart.sh not invoked"
    (( FAIL++ )) || true
fi

# ── Test 2: fleet restart --size N overrides ──────────────────────────────────
echo "=== Test 2: chump fleet restart --size 3 ==="
FLAG_FILE="$TMP/restart-called-2" export FLAG_FILE
# Write desired-size so we can verify override works
echo "2" > "$FAKE_REPO/.chump/fleet-desired-size"
out2=$(env "${_env[@]}" "$CHUMP_BIN" fleet restart --size 3 2>&1 || true)
assert_output_contains "restart --size 3 passes FLEET_SIZE=3" "FLEET_SIZE=3" "$out2"

# ── Test 3: fleet restart without fleet-restart.sh exits non-zero ────────────
echo "=== Test 3: chump fleet restart with missing script ==="
FLAG_FILE="$TMP/restart-called-3" export FLAG_FILE
FAKE_REPO_MISSING="$TMP/repo-missing"
cp -r "$FAKE_REPO" "$FAKE_REPO_MISSING"
rm "$FAKE_REPO_MISSING/scripts/dispatch/fleet-restart.sh"
out3=$(env CHUMP_REPO="$FAKE_REPO_MISSING" HOME="$TMP/home" "$CHUMP_BIN" fleet restart 2>&1 || true)
if echo "$out3" | grep -q "No such file"; then
    echo "  PASS: missing fleet-restart.sh causes error: $(echo "$out3" | tail -1)"
    (( PASS++ )) || true
else
    echo "  FAIL: expected error about missing fleet-restart.sh, got:"
    echo "$out3" | sed 's/^/    /'
    (( FAIL++ )) || true
fi

# ── Test 4: help text includes restart ────────────────────────────────────────
echo "=== Test 4: chump fleet help includes restart ==="
help_out=$(env "${_env[@]}" "$CHUMP_BIN" fleet bogus 2>&1 || true)
if echo "$help_out" | grep -q "restart"; then
    echo "  PASS: restart listed in fleet subcommands"
    (( PASS++ )) || true
else
    echo "  FAIL: restart not found in fleet help"
    (( FAIL++ )) || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    exit 1
fi
