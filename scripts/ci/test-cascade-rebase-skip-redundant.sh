#!/usr/bin/env bash
# test-cascade-rebase-skip-redundant.sh — INFRA-2232
#
# Verifies the skip-redundant-rerun gate in cascade_rebase_if_hot: a batch of
# hot-file commits landing within CHUMP_CASCADE_REBASE_DEBOUNCE_S of each
# other must coalesce into ONE sweep (one cascade_rebase_triggered event),
# with every later commit in the window emitting
# cascade_rebase_skipped_redundant instead of re-firing a full CI-reset
# sweep. This is distinct from the per-SHA lock (INFRA-1310, covered by
# test-cascade-rebase-debounce.sh) which only dedupes concurrent workers on
# the SAME commit — this gate dedupes sequential DIFFERENT commits.
#
#   1. First hot-file commit fires a full sweep, writes the last-run marker.
#   2. A second (different-SHA) commit landing immediately after is skipped
#      as redundant — cascade_rebase_skipped_redundant emitted, no sweep.
#   3. CHUMP_CASCADE_REBASE_NO_DEBOUNCE=1 bypasses the gate — sweep fires
#      even inside the window.
#   4. Once the debounce window has elapsed, a new commit fires a fresh
#      sweep again.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

QUEUE_DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"
[[ -f "$QUEUE_DRIVER" ]] || fail "queue-driver.sh missing: $QUEUE_DRIVER"

grep -q "cascade_rebase_skipped_redundant" "$QUEUE_DRIVER" \
    || fail "queue-driver.sh does not reference cascade_rebase_skipped_redundant"
grep -q "CHUMP_CASCADE_REBASE_DEBOUNCE_S" "$QUEUE_DRIVER" \
    || fail "queue-driver.sh does not read CHUMP_CASCADE_REBASE_DEBOUNCE_S"
ok "queue-driver.sh wires the skip-redundant-rerun gate"

TMP="$(mktemp -d -t infra2232-test-XXXX)"
trap 'rm -rf "$TMP"' EXIT

FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.chump-locks"
AMBIENT="$FAKE_REPO/.chump-locks/ambient.jsonl"
touch "$AMBIENT"

# ── Minimal harness reproducing just the debounce-gate slice of
#    cascade_rebase_if_hot (the real function needs a live git repo + gh
#    auth; this isolates the pure-bash coalescing logic under test). ────────
FUNCS_FILE="$TMP/funcs.sh"
cat > "$FUNCS_FILE" << 'FUNCS_EOF'
_ambient_write() { printf '%s\n' "$2" >> "$1" 2>/dev/null || true; }

cascade_rebase_if_hot() {
    local triggered_by="Cargo.toml"  # test always triggers

    local _debounce_s="${CHUMP_CASCADE_REBASE_DEBOUNCE_S:-180}"
    local _last_run_file="$REPO_ROOT/.chump-locks/cascade-rebase-last-run.ts"
    if [[ "${CHUMP_CASCADE_REBASE_NO_DEBOUNCE:-0}" != "1" && -f "$_last_run_file" ]]; then
        local _last_run_s _now_s _elapsed_s
        _last_run_s="$(cat "$_last_run_file" 2>/dev/null || echo 0)"
        _now_s="$(date +%s)"
        _elapsed_s=$(( _now_s - _last_run_s ))
        if [[ "$_last_run_s" =~ ^[0-9]+$ ]] && (( _elapsed_s < _debounce_s )); then
            local _ambient_db="$REPO_ROOT/.chump-locks/ambient.jsonl"
            local _now_ts; _now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _ambient_write "$_ambient_db" \
                "$(printf '{"ts":"%s","kind":"cascade_rebase_skipped_redundant","triggered_by":"%s","seconds_since_last":%d,"debounce_s":%d}' \
                    "$_now_ts" "$triggered_by" "$_elapsed_s" "$_debounce_s")"
            return 0
        fi
    fi

    local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _ambient_write "$REPO_ROOT/.chump-locks/ambient.jsonl" \
        "$(printf '{"ts":"%s","kind":"cascade_rebase_triggered","triggered_by":"%s","pr_ok":0,"pr_fail":0,"dry_run":1}' "$_now" "$triggered_by")"
    date +%s > "$_last_run_file"
}
FUNCS_EOF

REPO_ROOT="$FAKE_REPO"
export REPO_ROOT
# shellcheck source=/dev/null
source "$FUNCS_FILE"

# ── Test 1: first commit fires a full sweep ────────────────────────────────
cascade_rebase_if_hot
triggered=$(grep -c '"kind":"cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null || true)
[[ "$triggered" -eq 1 ]] && ok "Test 1: first hot-file commit fired a sweep" \
    || fail "Test 1: expected 1 cascade_rebase_triggered, got $triggered"

# ── Test 2: second commit inside the debounce window is coalesced ────────
CHUMP_CASCADE_REBASE_DEBOUNCE_S=180 cascade_rebase_if_hot
triggered=$(grep -c '"kind":"cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null || true)
skipped=$(grep -c '"kind":"cascade_rebase_skipped_redundant"' "$AMBIENT" 2>/dev/null || true)
[[ "$triggered" -eq 1 && "$skipped" -eq 1 ]] \
    && ok "Test 2: second commit in-window skipped as redundant (no re-sweep)" \
    || fail "Test 2: expected triggered=1 skipped=1, got triggered=$triggered skipped=$skipped"

# ── Test 3: bypass flag forces a fresh sweep even inside the window ──────
CHUMP_CASCADE_REBASE_NO_DEBOUNCE=1 cascade_rebase_if_hot
triggered=$(grep -c '"kind":"cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null || true)
[[ "$triggered" -eq 2 ]] && ok "Test 3: CHUMP_CASCADE_REBASE_NO_DEBOUNCE=1 bypasses the gate" \
    || fail "Test 3: expected 2 total cascade_rebase_triggered after bypass, got $triggered"

# ── Test 4: once the window has elapsed, a new commit fires again ────────
# Backdate the marker past the (tiny) debounce window used here.
echo $(( $(date +%s) - 5 )) > "$FAKE_REPO/.chump-locks/cascade-rebase-last-run.ts"
CHUMP_CASCADE_REBASE_DEBOUNCE_S=2 cascade_rebase_if_hot
triggered=$(grep -c '"kind":"cascade_rebase_triggered"' "$AMBIENT" 2>/dev/null || true)
[[ "$triggered" -eq 3 ]] && ok "Test 4: sweep fires again once the debounce window elapses" \
    || fail "Test 4: expected 3 total cascade_rebase_triggered after window elapsed, got $triggered"

echo ""
echo "=== test-cascade-rebase-skip-redundant.sh PASSED ==="
