#!/usr/bin/env bash
# scripts/ci/test-audit-orphan-landed-detector.sh — INFRA-4535
#
# Smoke test for scripts/ops/audit-orphan-landed-detector.sh:
#   1. A synthetic fixture tree with one register-without-emit orphan
#      produces exactly one kind=audit_orphan_landed event.
#   2. Running the detector again (same tree, same state) emits nothing new
#      — the orphan was already seen.
#   3. Once the fixture registry drops the orphan (it "got resolved"), a
#      re-run clears it from state so a future re-landing would re-fire.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-4535 audit-orphan-landed-detector tests ==="

TMPDIR_FIX=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FIX"' EXIT

# ── Build a fixture tree that mirrors the real repo layout so the copied
# coverage script's own REPO_ROOT resolution (relative to its own path)
# lands on the fixture root, not the real repo. ──────────────────────────────
mkdir -p "$TMPDIR_FIX/docs/observability"
mkdir -p "$TMPDIR_FIX/scripts/ci"
mkdir -p "$TMPDIR_FIX/scripts/coord"
cp "$REPO_ROOT/scripts/ci/test-event-registry-coverage.sh" "$TMPDIR_FIX/scripts/ci/test-event-registry-coverage.sh"

cat > "$TMPDIR_FIX/docs/observability/EVENT_REGISTRY.yaml" <<'YAML'
events:
  - kind: infra_4535_fixture_orphan
    effect_metric: self
    emitter: test-fixture (INFRA-4535)
    trigger: Synthetic orphan kind used only by the detector smoke test — no
      production code emits this literal anywhere in the fixture tree.
    consumers: []
    fields_required: [ts, kind]
    status: stable
YAML

# No emit site anywhere in scripts/coord/ for infra_4535_fixture_orphan — it
# is a true register-without-emit orphan by construction.
cat > "$TMPDIR_FIX/scripts/coord/unrelated.sh" <<'SH'
#!/usr/bin/env bash
printf '{"ts":"2026-01-01T00:00:00Z","kind":"some_other_kind"}\n'
SH

touch "$TMPDIR_FIX/scripts/ci/event-registry-reserved.txt"

STATE_FILE="$TMPDIR_FIX/audit-orphan-seen.json"
AMBIENT_LOG="$TMPDIR_FIX/ambient.jsonl"
COVERAGE_SCRIPT="$TMPDIR_FIX/scripts/ci/test-event-registry-coverage.sh"

run_detector() {
    CHUMP_ORPHAN_DETECTOR_STATE="$STATE_FILE" \
    CHUMP_ORPHAN_DETECTOR_AMBIENT="$AMBIENT_LOG" \
    CHUMP_ORPHAN_DETECTOR_COVERAGE_SCRIPT="$COVERAGE_SCRIPT" \
        bash "$REPO_ROOT/scripts/ops/audit-orphan-landed-detector.sh"
}

# ── Test 1: first run emits exactly one audit_orphan_landed event ───────────
echo ""
echo "Test 1: first run emits audit_orphan_landed for the new orphan"
run_detector > /tmp/infra4535_run1.log 2>&1
if [[ -f "$AMBIENT_LOG" ]] && grep -q '"kind":"audit_orphan_landed"' "$AMBIENT_LOG"; then
    ok "audit_orphan_landed emitted"
else
    fail "audit_orphan_landed NOT emitted (see /tmp/infra4535_run1.log)"
fi
if grep -q '"orphan_kind":"infra_4535_fixture_orphan"' "$AMBIENT_LOG" 2>/dev/null; then
    ok "event carries the correct orphan_kind"
else
    fail "event missing/incorrect orphan_kind"
fi
if grep -oE '"hash":"[0-9a-f]{8}"' "$AMBIENT_LOG" | head -1 | grep -q .; then
    ok "event carries an 8-hex-char hash"
else
    fail "event missing a hash field"
fi
count1=$(grep -c '"kind":"audit_orphan_landed"' "$AMBIENT_LOG" 2>/dev/null || echo 0)
if [[ "$count1" -eq 1 ]]; then
    ok "exactly one audit_orphan_landed event after first run"
else
    fail "expected exactly 1 audit_orphan_landed event, got $count1"
fi

# ── Test 2: second run (same tree) emits nothing new — dedup via state ──────
echo ""
echo "Test 2: second run does not re-emit the already-seen orphan"
run_detector > /tmp/infra4535_run2.log 2>&1
count2=$(grep -c '"kind":"audit_orphan_landed"' "$AMBIENT_LOG" 2>/dev/null || echo 0)
if [[ "$count2" -eq 1 ]]; then
    ok "still exactly 1 audit_orphan_landed event after second run (deduped)"
else
    fail "expected dedup to hold at 1 event, got $count2"
fi
if grep -q "0 new orphan" /tmp/infra4535_run2.log; then
    ok "second run reports 0 new orphans"
else
    fail "second run did not report 0 new orphans"
fi

# ── Test 3: orphan resolved (registry entry removed) clears state ───────────
echo ""
echo "Test 3: resolving the orphan clears it from state (re-arms for future landings)"
cat > "$TMPDIR_FIX/docs/observability/EVENT_REGISTRY.yaml" <<'YAML'
events: []
YAML
run_detector > /tmp/infra4535_run3.log 2>&1
if grep -q '\[\]' "$STATE_FILE" 2>/dev/null; then
    ok "state file cleared once the orphan is no longer on the tree"
else
    fail "state file was not cleared (content: $(cat "$STATE_FILE" 2>/dev/null))"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
