#!/usr/bin/env bash
# test-main-health-watchdog.sh — INFRA-1656
# Validates the main-health watchdog:
#   - source contract: script exists + executable + bash-syntax clean
#   - plist + installer present and reference the script
#   - CHUMP_MAIN_HEALTH_DISABLED bypass short-circuits
#   - SUCCESS path: stubbed gh returns conclusion=success → no gap filed, exit 0
#   - FAILURE path: stubbed gh returns conclusion=failure → chump gap reserve
#                    called once
#   - DEDUP path: stubbed gh failure + stubbed `chump gap list` reports a
#                   pre-existing P0 INFRA-NEW-MAIN-RED-* with the same sha
#                   → no new reserve attempted
#
# Stub strategy: write fake `gh` and `chump` binaries into a temp directory,
# pass them to the watchdog via CHUMP_MAIN_HEALTH_GH_BIN and
# CHUMP_MAIN_HEALTH_CHUMP_BIN. We avoid PATH manipulation because the watchdog
# itself calls `python3` and `date` from PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WATCHDOG="$REPO_ROOT/scripts/ops/main-health-watchdog.sh"
PLIST="$REPO_ROOT/launchd/com.chump.main-health-watchdog.plist"
INSTALL="$REPO_ROOT/scripts/setup/install-main-health-watchdog.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-main-health-watchdog.sh (INFRA-1656) ==="

# ── 1. Script presence + executable + syntax ─────────────────────────────────
echo "--- 1: source contract ---"
[[ -f "$WATCHDOG" ]] || fail "watchdog script missing: $WATCHDOG"
[[ -x "$WATCHDOG" ]] || fail "watchdog script not executable: $WATCHDOG"
bash -n "$WATCHDOG" || fail "watchdog bash -n failed"
[[ -f "$INSTALL" ]] || fail "installer missing: $INSTALL"
[[ -x "$INSTALL" ]] || fail "installer not executable: $INSTALL"
bash -n "$INSTALL" || fail "installer bash -n failed"
[[ -f "$PLIST" ]] || fail "plist missing: $PLIST"
grep -q "main-health-watchdog.sh" "$PLIST" \
    || fail "plist does not reference main-health-watchdog.sh"
grep -q "com.chump.main-health-watchdog" "$PLIST" \
    || fail "plist missing expected Label"
pass "script + plist + installer present, syntax clean"

# ── 2. Bypass ────────────────────────────────────────────────────────────────
echo "--- 2: CHUMP_MAIN_HEALTH_DISABLED bypass ---"
TMP_AMB="$(mktemp)"
: > "$TMP_AMB"
out="$(CHUMP_MAIN_HEALTH_DISABLED=1 CHUMP_AMBIENT_LOG="$TMP_AMB" "$WATCHDOG" 2>&1)"
echo "$out" | grep -q "CHUMP_MAIN_HEALTH_DISABLED" \
    || fail "bypass did not log expected message; got: $out"
[[ ! -s "$TMP_AMB" ]] \
    || fail "bypass must not write to ambient.jsonl; got: $(cat "$TMP_AMB")"
pass "CHUMP_MAIN_HEALTH_DISABLED=1 short-circuits cleanly"

# ── Shared stub builder ─────────────────────────────────────────────────────
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_AMB" "$STUB_DIR"' EXIT

# Counter file the stubs append to so we can assert call counts.
STUB_LOG="$STUB_DIR/calls.log"
: > "$STUB_LOG"

write_gh_stub() {
    # write_gh_stub <json_payload>
    local payload="$1"
    cat > "$STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$STUB_LOG"
cat <<'JSON'
$payload
JSON
EOF
    chmod +x "$STUB_DIR/gh"
}

write_chump_stub() {
    # write_chump_stub <open_gaps_json>
    # The stub handles two calls:
    #   chump gap list --status open --json   → prints the supplied JSON
    #   chump gap reserve ...                  → logs the call, prints INFRA-9999
    #   chump gap set ...                      → logs the call, prints nothing
    local open_gaps="$1"
    cat > "$STUB_DIR/chump" <<EOF
#!/usr/bin/env bash
echo "chump \$*" >> "$STUB_LOG"
case "\$2" in
    list)
        cat <<'JSON'
$open_gaps
JSON
        ;;
    reserve)
        echo "INFRA-9999"
        ;;
    set)
        :
        ;;
    *)
        echo "chump-stub: unhandled args: \$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$STUB_DIR/chump"
}

run_watchdog() {
    : > "$STUB_LOG"
    : > "$TMP_AMB"
    CHUMP_MAIN_HEALTH_GH_BIN="$STUB_DIR/gh" \
    CHUMP_MAIN_HEALTH_CHUMP_BIN="$STUB_DIR/chump" \
    CHUMP_AMBIENT_LOG="$TMP_AMB" \
        "$WATCHDOG" 2>&1
}

# ── 3. SUCCESS path: no gap filed ────────────────────────────────────────────
echo "--- 3: stubbed SUCCESS → no gap filed ---"
write_gh_stub '[{"conclusion":"success","headSha":"deadbeefcafe000000000000000000000000aaaa","url":"https://github.com/x/y/actions/runs/1","databaseId":1,"createdAt":"2026-05-22T00:00:00Z","jobs":[]}]'
write_chump_stub '[]'

out="$(run_watchdog)" || fail "watchdog exited non-zero on success path: $out"
if grep -q "chump gap reserve" "$STUB_LOG"; then
    fail "SUCCESS path called chump gap reserve; calls were: $(cat "$STUB_LOG")"
fi
grep -q '"kind":"main_red_detected"' "$TMP_AMB" \
    || fail "SUCCESS path did not emit kind=main_red_detected heartbeat; ambient: $(cat "$TMP_AMB")"
grep -q '"status":"success"' "$TMP_AMB" \
    || fail "SUCCESS heartbeat missing status=success; ambient: $(cat "$TMP_AMB")"
pass "SUCCESS path emits heartbeat and does not file"

# ── 4. FAILURE path: gap reserve attempted ───────────────────────────────────
echo "--- 4: stubbed FAILURE → chump gap reserve attempted ---"
write_gh_stub '[{"conclusion":"failure","headSha":"feedface000000000000000000000000aaaabbbb","url":"https://github.com/x/y/actions/runs/2","databaseId":2,"createdAt":"2026-05-22T00:00:00Z","jobs":[{"name":"fast-checks","conclusion":"failure","steps":[{"name":"event-registry-coverage","conclusion":"failure"}]}]}]'
write_chump_stub '[]'

out="$(run_watchdog)" || fail "watchdog exited non-zero on failure path: $out"
grep -q "chump gap reserve" "$STUB_LOG" \
    || fail "FAILURE path did not call chump gap reserve; calls: $(cat "$STUB_LOG")"
grep -q "chump gap set INFRA-9999" "$STUB_LOG" \
    || fail "FAILURE path did not enrich the new gap via chump gap set; calls: $(cat "$STUB_LOG")"
# Title must encode the date and the failed gate.
grep -q "INFRA-NEW-MAIN-RED-" "$STUB_LOG" \
    || fail "reserve title missing INFRA-NEW-MAIN-RED- prefix; calls: $(cat "$STUB_LOG")"
grep -q "fast-checks" "$STUB_LOG" \
    || fail "reserve title did not encode failed gate 'fast-checks'; calls: $(cat "$STUB_LOG")"
grep -q '"status":"filed"' "$TMP_AMB" \
    || fail "FAILURE path did not emit status=filed; ambient: $(cat "$TMP_AMB")"
grep -q '"gap_id":"INFRA-9999"' "$TMP_AMB" \
    || fail "FAILURE event missing gap_id=INFRA-9999; ambient: $(cat "$TMP_AMB")"
pass "FAILURE path filed gap and emitted status=filed"

# ── 5. DEDUP path: pre-existing P0 with same sha → no new reserve ────────────
echo "--- 5: stubbed FAILURE with pre-existing dedup target → no new reserve ---"
# Reuse the failure gh payload from step 4 (sha=feedface...).
write_gh_stub '[{"conclusion":"failure","headSha":"feedface000000000000000000000000aaaabbbb","url":"https://github.com/x/y/actions/runs/2","databaseId":2,"createdAt":"2026-05-22T00:00:00Z","jobs":[{"name":"fast-checks","conclusion":"failure","steps":[{"name":"event-registry-coverage","conclusion":"failure"}]}]}]'
# An existing P0 gap whose notes contain the exact head sha.
write_chump_stub '[{"id":"INFRA-9000","domain":"INFRA","title":"INFRA-NEW-MAIN-RED-2026-05-22: fast-checks","priority":"P0","notes":"sha=feedface000000000000000000000000aaaabbbb watchdog=main-health (INFRA-1656)","status":"open"}]'

out="$(run_watchdog)" || fail "watchdog exited non-zero on dedup path: $out"
if grep -q "chump gap reserve" "$STUB_LOG"; then
    fail "DEDUP path called chump gap reserve; calls: $(cat "$STUB_LOG")"
fi
grep -q '"status":"deduped"' "$TMP_AMB" \
    || fail "DEDUP path did not emit status=deduped; ambient: $(cat "$TMP_AMB")"
grep -q '"gap_id":"INFRA-9000"' "$TMP_AMB" \
    || fail "DEDUP event missing gap_id=INFRA-9000 reference; ambient: $(cat "$TMP_AMB")"
pass "DEDUP path skipped reserve and emitted status=deduped"

# ── 6. EVENT_REGISTRY: main_red_detected registered ──────────────────────────
echo "--- 6: EVENT_REGISTRY.yaml registers main_red_detected ---"
grep -q "kind: main_red_detected" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "EVENT_REGISTRY.yaml is missing kind: main_red_detected"
pass "main_red_detected registered in EVENT_REGISTRY.yaml"

# ── 7. chump-fleet-bootstrap REQUIRED_DAEMONS includes the new daemon ────────
echo "--- 7: bootstrap REQUIRED_DAEMONS contains the new daemon ---"
grep -q "com.chump.main-health-watchdog" "$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh" \
    || fail "chump-fleet-bootstrap.sh REQUIRED_DAEMONS missing com.chump.main-health-watchdog"
pass "bootstrap REQUIRED_DAEMONS wired"

echo
echo "=== test-main-health-watchdog.sh PASSED ==="
