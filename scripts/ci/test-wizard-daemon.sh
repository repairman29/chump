#!/usr/bin/env bash
# scripts/ci/test-wizard-daemon.sh — META-109 Phase 1
#
# Smoke tests for wizard-daemon.sh Phase 1 (steps 1, 2, 6 + safety + bypass).
#
# Test cases:
#   1. CHUMP_WIZARD_DAEMON_ENABLED unset → daemon exits 0, no action
#   2. CHUMP_WIZARD_DAEMON_PAUSE=1 → emits wizard_daemon_paused, exits 0
#   3. Floor temp HOT → emits wizard_daemon_safety_refusal, exits 0
#   4. Fleet-hold active → daemon stands down (step1 skipped), exits 0
#   5. Step 1: BEHIND+auto-armed PR → classified as BLOCKED+stale-base
#   6. Step 1: CONFLICTING PR → classified as CONFLICTING + safety refusal emitted
#   7. Step 2: BLOCKED+stale-base → recovery-queue-emit.sh called
#   8. Step 2: CONFLICTING → refused (safety guard), emit.sh NOT called
#   9. Step 2: rate limit (3 emits) → 4th PR is rate-limited
#  10. Step 6: fleet_stalled event in ambient → broadcast-urgent.sh called
#  11. Step 6: worker_stuck event in ambient → broadcast-urgent.sh called
#  12. Step 6: stall event outside lookback window → no broadcast
#  13. Step 6: dedup — second run doesn't re-broadcast within window
#  14. No open PRs → cycle completes cleanly

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }
section() { printf '\n--- %s ---\n' "$1"; }

echo "=== META-109 Phase 1: wizard-daemon smoke tests ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DAEMON="$REPO_ROOT/scripts/coord/wizard-daemon.sh"

[[ -x "$DAEMON" ]] || { echo "FATAL: $DAEMON not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Shared helper: build a fake repo environment ───────────────────────────────
make_env() {
    local dir="$1"
    mkdir -p "$dir/.chump-locks" "$dir/scripts/coord" "$dir/scripts/coord/lib"

    # Fake git so daemon can detect repo root
    mkdir -p "$dir/.git"

    # Stub github_cache.sh — returns empty (cache miss → fall through to gh)
    cat > "$dir/scripts/coord/lib/github_cache.sh" <<'CACHE'
[[ -n "${_CHUMP_GITHUB_CACHE_LIB:-}" ]] && return 0
_CHUMP_GITHUB_CACHE_LIB=1
cache_query_open_prs()   { return 0; }   # empty — forces gh fallback
cache_lookup_pr()        { return 2; }   # miss — forces gh fallback
CACHE

    # Stub recovery-queue-emit.sh
    cat > "$dir/scripts/coord/recovery-queue-emit.sh" <<'EMIT'
#!/usr/bin/env bash
echo "recovery-queue-emit called: $*" >> "${EMIT_CALL_LOG:-/dev/null}"
exit 0
EMIT
    chmod +x "$dir/scripts/coord/recovery-queue-emit.sh"

    # Stub broadcast-urgent.sh
    cat > "$dir/scripts/coord/broadcast-urgent.sh" <<'BCAST'
#!/usr/bin/env bash
echo "broadcast-urgent called: $*" >> "${BCAST_CALL_LOG:-/dev/null}"
exit 0
BCAST
    chmod +x "$dir/scripts/coord/broadcast-urgent.sh"

    # Stub fleet-hold-check.sh — default: no hold
    cat > "$dir/scripts/coord/fleet-hold-check.sh" <<'HOLD'
#!/usr/bin/env bash
# By default: no hold. Override by touching fleet-hold.txt in the fake repo.
HOLD_FILE="${CHUMP_FLEET_HOLD_FILE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.chump-locks/fleet-hold.txt}"
[[ -f "$HOLD_FILE" ]] && exit 2
exit 0
HOLD
    chmod +x "$dir/scripts/coord/fleet-hold-check.sh"
}

# ── Helper: run daemon with specific env ──────────────────────────────────────
run_daemon() {
    local dir="$1"; shift
    local fake_gh="${1:-}"; shift || true

    env \
        CHUMP_REPO="$dir" \
        CHUMP_REPO_ROOT="$dir" \
        CHUMP_AMBIENT_LOG="$dir/.chump-locks/ambient.jsonl" \
        CHUMP_FLEET_HOLD_FILE="$dir/.chump-locks/fleet-hold.txt" \
        CHUMP_WIZARD_TEST_GH="${fake_gh:-/bin/false}" \
        CHUMP_WIZARD_TEST_CHUMP="${FAKE_CHUMP:-/bin/true}" \
        EMIT_CALL_LOG="$dir/emit-calls.log" \
        BCAST_CALL_LOG="$dir/bcast-calls.log" \
        "$@" \
        bash "$DAEMON" 2>&1
}

make_fake_gh() {
    local path="$1"
    local pr_list_json="${2:-}"; shift 2 || true
    pr_list_json="${pr_list_json:-[]}"
    local pr_view_json="${1:-}"
    mkdir -p "$(dirname "$path")"
    # Write the list JSON and view JSON into companion files so the heredoc
    # doesn't have to embed them directly (avoids quoting edge cases).
    local list_file; list_file="$(dirname "$path")/.gh-list-fixture"
    local view_file; view_file="$(dirname "$path")/.gh-view-fixture"
    printf '%s' "$pr_list_json" > "$list_file"
    printf '%s' "$pr_view_json" > "$view_file"
    cat > "$path" <<GH_EOF
#!/usr/bin/env bash
LIST_FILE="$(dirname "$path")/.gh-list-fixture"
VIEW_FILE="$(dirname "$path")/.gh-view-fixture"
case "\$*" in
    *"pr list"*)
        # If caller passes --jq '.[].number', extract numbers via python3
        if printf '%s\n' "\$@" | grep -q '\\[\\]\.number'; then
            python3 -c "
import json,sys
data=json.load(open('\$LIST_FILE'))
for pr in data: print(pr['number'])
" 2>/dev/null
        else
            cat "\$LIST_FILE"
        fi
        exit 0
        ;;
    *"pr view"*)
        if [[ -n "\${GH_PR_DATA_FILE:-}" ]] && [[ -f "\${GH_PR_DATA_FILE}" ]]; then
            cat "\${GH_PR_DATA_FILE}"
        else
            cat "\$VIEW_FILE"
        fi
        exit 0
        ;;
esac
exit 0
GH_EOF
    chmod +x "$path"
}

# ── Test 1: not enabled ────────────────────────────────────────────────────────
section "T1: ENABLED unset → silent exit"
D="$TMP/t1"; make_env "$D"
OUT="$(CHUMP_WIZARD_DAEMON_ENABLED=0 run_daemon "$D" "" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s\n' "$OUT" | grep -q "NOT enabled"; then
    ok "T1: exits 0 with NOT enabled message"
else
    fail "T1: expected exit 0 + NOT enabled message (rc=$RC output=$OUT)"
fi

# ── Test 2: PAUSE kill-switch ──────────────────────────────────────────────────
section "T2: PAUSE=1 → wizard_daemon_paused emitted"
D="$TMP/t2"; make_env "$D"
run_daemon "$D" "" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_DAEMON_PAUSE=1 >/dev/null 2>&1 || true
if grep -q '"kind":"wizard_daemon_paused"' "$D/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "T2: wizard_daemon_paused emitted"
else
    fail "T2: wizard_daemon_paused not found in ambient"
fi

# ── Test 3: HOT floor temp ─────────────────────────────────────────────────────
section "T3: HOT temp → safety refusal"
D="$TMP/t3"; make_env "$D"

# Fake chump that reports HOT
FAKE_CHUMP_HOT="$TMP/t3-chump"
cat > "$FAKE_CHUMP_HOT" <<'CHUMP'
#!/usr/bin/env bash
if [[ "$1 $2" == "health --temp" ]]; then
    echo "floor_temp: HOT"
    exit 0
fi
exit 0
CHUMP
chmod +x "$FAKE_CHUMP_HOT"

run_daemon "$D" "" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_TEST_CHUMP="$FAKE_CHUMP_HOT" >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_daemon_safety_refusal"' "$AMBIENT" 2>/dev/null \
   && grep -q '"reason":"floor_temp_HOT"' "$AMBIENT" 2>/dev/null; then
    ok "T3: wizard_daemon_safety_refusal emitted for HOT temp"
else
    fail "T3: safety_refusal not found (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 4: Fleet-hold active ─────────────────────────────────────────────────
section "T4: fleet-hold active → stand_down"
D="$TMP/t4"; make_env "$D"
echo '{"active":true,"reason":"ci_failure_cluster"}' > "$D/.chump-locks/fleet-hold.txt"

GH4="$TMP/t4-gh"
make_fake_gh "$GH4" '[]' '{}'

run_daemon "$D" "$GH4" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"decision":"stand_down"' "$AMBIENT" 2>/dev/null \
   && grep -q '"reason":"fleet_hold_active"' "$AMBIENT" 2>/dev/null; then
    ok "T4: stand_down emitted when fleet-hold active"
else
    fail "T4: expected stand_down with fleet_hold_active (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 5: Step 1 — BEHIND+auto-armed → BLOCKED+stale-base ──────────────────
section "T5: Step 1 — BEHIND+auto-armed PR classified BLOCKED+stale-base"
D="$TMP/t5"; make_env "$D"

GH5="$TMP/t5-gh"
make_fake_gh "$GH5" '[{"number":999}]' \
    '{"number":999,"title":"test PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH5" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"pr_class":"BLOCKED+stale-base"' "$AMBIENT" 2>/dev/null; then
    ok "T5: BEHIND+auto-armed → BLOCKED+stale-base"
else
    fail "T5: expected BLOCKED+stale-base class (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 6: Step 1 — CONFLICTING → safety refusal ────────────────────────────
section "T6: Step 1 — CONFLICTING PR → safety refusal"
D="$TMP/t6"; make_env "$D"

GH6="$TMP/t6-gh"
make_fake_gh "$GH6" '[{"number":888}]' \
    '{"number":888,"title":"conflicting PR","mergeable":"CONFLICTING","mergeStateStatus":"CONFLICTING","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH6" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"kind":"wizard_daemon_safety_refusal"' "$AMBIENT" 2>/dev/null \
   && grep -q '"reason":"pr_conflicting"' "$AMBIENT" 2>/dev/null; then
    ok "T6: CONFLICTING PR → wizard_daemon_safety_refusal emitted"
else
    fail "T6: expected safety_refusal for CONFLICTING (ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty))"
fi

# ── Test 7: Step 2 — BLOCKED+stale-base → recovery-queue-emit called ─────────
section "T7: Step 2 — BLOCKED+stale-base → emit.sh called"
D="$TMP/t7"; make_env "$D"

GH7="$TMP/t7-gh"
make_fake_gh "$GH7" '[{"number":777}]' \
    '{"number":777,"title":"stale PR","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH7" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

if [[ -f "$D/emit-calls.log" ]] && grep -q "777" "$D/emit-calls.log" 2>/dev/null; then
    ok "T7: recovery-queue-emit.sh called for BLOCKED+stale-base PR"
else
    fail "T7: emit.sh not called (emit-calls.log=$(cat "$D/emit-calls.log" 2>/dev/null || echo empty))"
fi

# Also check ambient has recovery_queue_emitted decision
AMBIENT="$D/.chump-locks/ambient.jsonl"
if grep -q '"decision":"recovery_queue_emitted"' "$AMBIENT" 2>/dev/null; then
    ok "T7b: wizard_daemon_action with recovery_queue_emitted emitted"
else
    fail "T7b: recovery_queue_emitted not found in ambient"
fi

# ── Test 8: Step 2 — CONFLICTING → refused, emit NOT called ──────────────────
section "T8: Step 2 — CONFLICTING → emit.sh NOT called"
D="$TMP/t8"; make_env "$D"

GH8="$TMP/t8-gh"
make_fake_gh "$GH8" '[{"number":666}]' \
    '{"number":666,"title":"conflict PR","mergeable":"CONFLICTING","mergeStateStatus":"CONFLICTING","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}'

run_daemon "$D" "$GH8" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 >/dev/null 2>&1 || true

if [[ ! -f "$D/emit-calls.log" ]] || [[ ! -s "$D/emit-calls.log" ]]; then
    ok "T8: emit.sh NOT called for CONFLICTING PR"
else
    fail "T8: emit.sh was called for CONFLICTING PR (should be refused)"
fi

# ── Test 9: Step 2 — rate limit (3 emits, 4th is rate-limited) ───────────────
section "T9: Step 2 — rate limit: 4th PR skipped"
D="$TMP/t9"; make_env "$D"

# Fake gh that returns 4 BEHIND+armed PRs.
# Use single-quoted heredoc so ${...} is NOT expanded at write time.
GH9="$TMP/t9-gh"
cat > "$GH9" <<'GH9_EOF'
#!/usr/bin/env bash
case "$*" in
    *"pr list"*)
        # Emit numbers one per line (mimics --jq '.[].number')
        if printf '%s\n' "$@" | grep -q '\[\]\.number'; then
            printf '101\n102\n103\n104\n'
        else
            echo '[{"number":101},{"number":102},{"number":103},{"number":104}]'
        fi
        exit 0
        ;;
    *"pr view"*)
        # Extract last numeric argument as PR number
        N=""
        for arg in "$@"; do
            [[ "$arg" =~ ^[0-9]+$ ]] && N="$arg"
        done
        N="${N:-101}"
        printf '{"number":%s,"title":"PR %s","mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledAt":"2026-01-01"},"isDraft":false}\n' "$N" "$N"
        exit 0
        ;;
esac
exit 0
GH9_EOF
chmod +x "$GH9"

run_daemon "$D" "$GH9" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_RECOVERY_RATE_LIMIT=3 >/dev/null 2>&1 || true

EMIT_COUNT=0
[[ -f "$D/emit-calls.log" ]] && EMIT_COUNT="$(wc -l < "$D/emit-calls.log" | tr -d ' ')"

AMBIENT="$D/.chump-locks/ambient.jsonl"
RATE_LIMITED="$(grep -c '"decision":"rate_limited"' "$AMBIENT" 2>/dev/null || echo 0)"

if [[ "$EMIT_COUNT" -eq 3 ]]; then
    ok "T9: exactly 3 emit calls (rate limit=3)"
else
    fail "T9: expected 3 emit calls, got $EMIT_COUNT"
fi
if [[ "$RATE_LIMITED" -ge 1 ]]; then
    ok "T9b: rate_limited decision emitted for 4th PR"
else
    fail "T9b: no rate_limited decision found (rate_limited_count=$RATE_LIMITED)"
fi

# ── Test 10: Step 6 — fleet_stalled → broadcast CRIT ─────────────────────────
section "T10: Step 6 — fleet_stalled event → broadcast-urgent called"
D="$TMP/t10"; make_env "$D"

GH10="$TMP/t10-gh"
make_fake_gh "$GH10" '[]' '{}'

# Inject a recent fleet_stalled event into ambient
TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"fleet_stalled","source":"fleet_brief","ships_1h":0,"blocked_prs":3}\n' \
    "$TS_NOW" > "$D/.chump-locks/ambient.jsonl"

run_daemon "$D" "$GH10" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

AMBIENT="$D/.chump-locks/ambient.jsonl"
if [[ -f "$D/bcast-calls.log" ]] && grep -q "CRIT" "$D/bcast-calls.log" 2>/dev/null; then
    ok "T10: broadcast-urgent.sh called with CRIT for fleet_stalled"
else
    fail "T10: broadcast-urgent.sh not called (bcast-calls=$(cat "$D/bcast-calls.log" 2>/dev/null || echo empty))"
fi
if grep -q '"decision":"broadcast_crit"' "$AMBIENT" 2>/dev/null; then
    ok "T10b: wizard_daemon_action broadcast_crit emitted"
else
    fail "T10b: broadcast_crit decision not found in ambient"
fi

# ── Test 11: Step 6 — worker_stuck → broadcast CRIT ──────────────────────────
section "T11: Step 6 — worker_stuck event → broadcast-urgent called"
D="$TMP/t11"; make_env "$D"

GH11="$TMP/t11-gh"
make_fake_gh "$GH11" '[]' '{}'

TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"worker_stuck","source":"worker","reason":"no_pickable_gap"}\n' \
    "$TS_NOW" > "$D/.chump-locks/ambient.jsonl"

run_daemon "$D" "$GH11" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

if [[ -f "$D/bcast-calls.log" ]] && grep -q "CRIT" "$D/bcast-calls.log" 2>/dev/null; then
    ok "T11: broadcast-urgent.sh called with CRIT for worker_stuck"
else
    fail "T11: broadcast-urgent.sh not called for worker_stuck"
fi

# ── Test 12: Step 6 — stall event outside lookback window → no broadcast ──────
section "T12: Step 6 — old stall event → no broadcast"
D="$TMP/t12"; make_env "$D"

GH12="$TMP/t12-gh"
make_fake_gh "$GH12" '[]' '{}'

# Inject an OLD fleet_stalled event (2 hours ago)
TS_OLD="$(date -u -v-7200S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '-7200 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo '2020-01-01T00:00:00Z')"
printf '{"ts":"%s","kind":"fleet_stalled","source":"fleet_brief","ships_1h":0,"blocked_prs":3}\n' \
    "$TS_OLD" > "$D/.chump-locks/ambient.jsonl"

run_daemon "$D" "$GH12" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

if [[ ! -f "$D/bcast-calls.log" ]] || [[ ! -s "$D/bcast-calls.log" ]]; then
    ok "T12: no broadcast for stall event outside lookback window"
else
    fail "T12: unexpected broadcast for old stall event (bcast=$(cat "$D/bcast-calls.log"))"
fi

# ── Test 13: Step 6 — dedup: second run doesn't re-broadcast ─────────────────
section "T13: Step 6 — dedup: second run within window → no re-broadcast"
D="$TMP/t13"; make_env "$D"

GH13="$TMP/t13-gh"
make_fake_gh "$GH13" '[]' '{}'

TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"fleet_stalled","source":"fleet_brief"}\n' "$TS_NOW" \
    > "$D/.chump-locks/ambient.jsonl"

# First run — should broadcast
run_daemon "$D" "$GH13" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

FIRST_BCAST_COUNT=0
[[ -f "$D/bcast-calls.log" ]] && FIRST_BCAST_COUNT="$(wc -l < "$D/bcast-calls.log" | tr -d ' ')"

# Second run — should dedup (wizard_daemon_action broadcast_crit is now in ambient)
run_daemon "$D" "$GH13" \
    CHUMP_WIZARD_DAEMON_ENABLED=1 \
    CHUMP_WIZARD_STALL_LOOKBACK_S=600 >/dev/null 2>&1 || true

SECOND_BCAST_COUNT=0
[[ -f "$D/bcast-calls.log" ]] && SECOND_BCAST_COUNT="$(wc -l < "$D/bcast-calls.log" | tr -d ' ')"

AMBIENT="$D/.chump-locks/ambient.jsonl"
DEDUP_COUNT="$(grep -c '"decision":"broadcast_deduped"' "$AMBIENT" 2>/dev/null || echo 0)"

if [[ "$FIRST_BCAST_COUNT" -ge 1 ]]; then
    ok "T13: first run broadcast (count=$FIRST_BCAST_COUNT)"
else
    fail "T13: first run did not broadcast"
fi
if [[ "$SECOND_BCAST_COUNT" -eq "$FIRST_BCAST_COUNT" ]]; then
    ok "T13b: second run did not add new broadcast (deduped)"
else
    fail "T13b: second run added broadcast (count went $FIRST_BCAST_COUNT → $SECOND_BCAST_COUNT)"
fi
if [[ "$DEDUP_COUNT" -ge 1 ]]; then
    ok "T13c: broadcast_deduped decision emitted on second run"
else
    fail "T13c: broadcast_deduped not found in ambient"
fi

# ── Test 14: No open PRs → cycle completes cleanly ────────────────────────────
section "T14: No open PRs → clean exit"
D="$TMP/t14"; make_env "$D"

GH14="$TMP/t14-gh"
make_fake_gh "$GH14" '[]' '{}'

OUT="$(run_daemon "$D" "$GH14" CHUMP_WIZARD_DAEMON_ENABLED=1 2>&1)"
RC=$?

AMBIENT="$D/.chump-locks/ambient.jsonl"
if [[ "$RC" -eq 0 ]] && grep -q '"decision":"done"' "$AMBIENT" 2>/dev/null; then
    ok "T14: clean exit with cycle_complete + done for empty PR queue"
else
    fail "T14: rc=$RC; ambient=$(cat "$AMBIENT" 2>/dev/null || echo empty)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "${#FAILS[@]}" -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
