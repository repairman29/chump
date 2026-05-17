#!/usr/bin/env bash
# scripts/ci/test-merge-queue-monitor.sh — CREDIBLE-068
#
# Verifies the merge-queue health monitor:
#   1. Script exists + is executable
#   2. EVENT_REGISTRY has merge_queue_health + queue_health_check_failed
#   3. MONITOR_ONCE=1 with stubbed gh (empty queue) → correct JSON emitted
#   4. MONITOR_ONCE=1 with stubbed gh (50 queued) → saturation 100% + backpressure=true
#   5. MONITOR_ONCE=1 with gh timeout stub → queue_health_check_failed emitted
#   6. CHUMP_MERGE_QUEUE_MONITOR=0 exits 0 immediately (disabled)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/monitor-merge-queue.sh"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Script exists + executable ────────────────────────────────────────────
[[ -f "$SCRIPT" ]] || fail "monitor-merge-queue.sh missing: $SCRIPT"
[[ -x "$SCRIPT" ]] || fail "monitor-merge-queue.sh not executable"
grep -q "CREDIBLE-068" "$SCRIPT" \
    || fail "CREDIBLE-068 marker missing from monitor script"
ok "monitor-merge-queue.sh exists and is executable"

# ── 2. EVENT_REGISTRY entries ─────────────────────────────────────────────────
[[ -f "$REGISTRY" ]] || fail "EVENT_REGISTRY.yaml missing"
grep -q "merge_queue_health" "$REGISTRY" \
    || fail "merge_queue_health not in EVENT_REGISTRY.yaml"
grep -q "queue_health_check_failed" "$REGISTRY" \
    || fail "queue_health_check_failed not in EVENT_REGISTRY.yaml"
grep -q "queue_saturation_pct" "$REGISTRY" \
    || fail "effect_metric=queue_saturation_pct missing from registry"
ok "merge_queue_health + queue_health_check_failed registered in EVENT_REGISTRY"

# ── Prepare stub gh binary + work dir ────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/stubs"
mkdir -p "$STUB_DIR"

write_gh_stub() {
    local queued="$1"
    local auto_merge="$2"
    cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for testing monitor-merge-queue.sh
if [[ "\$*" == *"run list"* ]]; then
    echo "$queued"
elif [[ "\$*" == *"pr list"* ]]; then
    echo "$auto_merge"
fi
STUB
    chmod +x "$STUB_DIR/gh"
}

write_timeout_gh_stub() {
    cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Simulate timeout / error
exit 1
STUB
    chmod +x "$STUB_DIR/gh"
}

run_monitor() {
    local ambient="$WORK/ambient.jsonl"
    rm -f "$ambient"
    # Redirect stdout to /dev/null so only the path is captured by callers.
    PATH="$STUB_DIR:$PATH" \
        MONITOR_ONCE=1 \
        CHUMP_AMBIENT_LOG="$ambient" \
        QUEUE_ALERT_THRESHOLD=50 \
        bash "$SCRIPT" >/dev/null 2>/dev/null
    echo "$ambient"
}

# ── 3. Empty queue → merge_queue_health with saturation 0 ────────────────────
write_gh_stub "0" "3"
AMBIENT="$(run_monitor)"

[[ -f "$AMBIENT" ]] || fail "round 3: ambient.jsonl not created"
grep -q '"kind":"merge_queue_health"' "$AMBIENT" \
    || fail "round 3: merge_queue_health not emitted; contents: $(cat "$AMBIENT" 2>/dev/null)"
grep -q '"queued_workflows":0' "$AMBIENT" \
    || fail "round 3: queued_workflows not 0; got: $(cat "$AMBIENT")"
grep -q '"queue_saturation_pct":0' "$AMBIENT" \
    || fail "round 3: saturation not 0; got: $(cat "$AMBIENT")"
grep -q '"backpressure_recommended":false' "$AMBIENT" \
    || fail "round 3: backpressure should be false; got: $(cat "$AMBIENT")"
ok "round 3: empty queue → merge_queue_health with 0% saturation, backpressure=false"

# ── 4. 50 queued (= threshold) → saturation 100% + backpressure=true ─────────
write_gh_stub "50" "8"
AMBIENT="$(run_monitor)"

grep -q '"queue_saturation_pct":100' "$AMBIENT" \
    || fail "round 4: saturation not 100 for 50 queued at threshold=50; got: $(cat "$AMBIENT")"
grep -q '"backpressure_recommended":true' "$AMBIENT" \
    || fail "round 4: backpressure should be true; got: $(cat "$AMBIENT")"
grep -q '"auto_merge_prs":8' "$AMBIENT" \
    || fail "round 4: auto_merge_prs not 8; got: $(cat "$AMBIENT")"
ok "round 4: 50 queued → 100% saturation, backpressure=true, auto_merge_prs=8"

# ── 5. gh timeout → queue_health_check_failed ────────────────────────────────
write_timeout_gh_stub
AMBIENT="$(run_monitor)"

[[ -f "$AMBIENT" ]] || fail "round 5: ambient.jsonl not created on failure"
grep -q '"kind":"queue_health_check_failed"' "$AMBIENT" \
    || fail "round 5: queue_health_check_failed not emitted; got: $(cat "$AMBIENT" 2>/dev/null)"
ok "round 5: gh failure → queue_health_check_failed emitted"

# ── 6. CHUMP_MERGE_QUEUE_MONITOR=0 → exits 0 immediately ────────────────────
set +e
CHUMP_MERGE_QUEUE_MONITOR=0 bash "$SCRIPT" 2>/dev/null
EXIT6=$?
set -e
[[ "$EXIT6" -eq 0 ]] || fail "round 6: disabled monitor should exit 0, got $EXIT6"
ok "round 6: CHUMP_MERGE_QUEUE_MONITOR=0 exits 0"

echo ""
echo "All 6 checks PASSED — CREDIBLE-068 merge queue health monitor works"
