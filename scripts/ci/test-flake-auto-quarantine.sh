#!/usr/bin/env bash
# test-flake-auto-quarantine.sh — INFRA-2361 smoke test.
#
# Exercises scripts/coord/flake-auto-quarantine.sh against a synthetic
# ambient.jsonl + KNOWN_FLAKES.yaml (all paths overridden via env, no
# writes to real repo state). Verifies:
#   1. A check capped on >= threshold distinct PRs gets quarantined:
#      catalog entry appended, gap filed (stubbed chump), events emitted.
#   2. A check capped on < threshold distinct PRs is left alone (transient).
#   3. A check already present in check_flakes: is skipped (no duplicate).
#   4. --dry-run does not mutate the catalog or state file.
#   5. The tick event (cost/report surface) is always emitted, once per run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/flake-auto-quarantine.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stub `chump` binary: prints a fixed gap id, exit 0.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "gap" ] && [ "$2" = "reserve" ]; then
  echo "[reserve] created INFRA-9901"
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/chump"
export PATH="$TMP/bin:$PATH"
export CHUMP_BIN="chump"

AMBIENT="$TMP/ambient.jsonl"
CATALOG="$TMP/KNOWN_FLAKES.yaml"
STATE="$TMP/state.json"

cat > "$CATALOG" << 'EOF'
schema_version: 1
flakes: []
check_flakes:
  - check_name: "already-known-flake"
    reason: "pre-existing"
    tracking_gap: INFRA-1
    added: "2026-01-01"
    last_observed: "2026-01-01"
    max_reruns: 2
EOF

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  # persistent-flake: capped on 3 distinct PRs -> should be quarantined
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":101,\"check_names\":\"persistent-flake\",\"author\":\"a\",\"dry_run\":false}"
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":102,\"check_names\":\"persistent-flake\",\"author\":\"b\",\"dry_run\":false}"
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":103,\"check_names\":\"persistent-flake\",\"author\":\"c\",\"dry_run\":false}"
  # occasional-flake: capped on only 2 distinct PRs -> transient, not actioned
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":201,\"check_names\":\"occasional-flake\",\"author\":\"a\",\"dry_run\":false}"
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":202,\"check_names\":\"occasional-flake\",\"author\":\"a\",\"dry_run\":false}"
  # already-known-flake: capped on 3 PRs but already in catalog -> skip
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":301,\"check_names\":\"already-known-flake\",\"author\":\"a\",\"dry_run\":false}"
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":302,\"check_names\":\"already-known-flake\",\"author\":\"a\",\"dry_run\":false}"
  echo "{\"ts\":\"$now\",\"kind\":\"flake_rerun_capped\",\"pr\":303,\"check_names\":\"already-known-flake\",\"author\":\"a\",\"dry_run\":false}"
} > "$AMBIENT"

run_script() {
  CHUMP_AMBIENT_PATH="$AMBIENT" \
  CHUMP_KNOWN_FLAKES_FILE="$CATALOG" \
  CHUMP_FLAKE_QUARANTINE_STATE_FILE="$STATE" \
  CHUMP_FLAKE_QUARANTINE_PR_THRESHOLD=3 \
  CHUMP_FLAKE_QUARANTINE_WINDOW_HOURS=72 \
  CHUMP_REPO_ROOT="$REPO_ROOT" \
  "$SCRIPT" "$@"
}

echo "=== INFRA-2361 flake-auto-quarantine tests ==="

# ── Test group 1: --dry-run must not mutate catalog/state ───────────────────
cp "$CATALOG" "$TMP/catalog.before"
run_script --dry-run >/dev/null 2>&1
if diff -q "$TMP/catalog.before" "$CATALOG" >/dev/null 2>&1; then
  ok "--dry-run does not mutate KNOWN_FLAKES.yaml"
else
  fail "--dry-run mutated KNOWN_FLAKES.yaml"
fi
if [[ ! -f "$STATE" ]]; then
  ok "--dry-run does not write state file"
else
  fail "--dry-run wrote state file"
fi
if grep -q '"kind":"flake_auto_quarantined".*"check_name":"persistent-flake"' "$AMBIENT"; then
  ok "--dry-run still emits flake_auto_quarantined (audit trail)"
else
  fail "--dry-run did not emit flake_auto_quarantined"
fi

# ── Test group 2: real run quarantines the persistent flake ────────────────
run_script >/dev/null 2>&1

if grep -q 'check_name: "persistent-flake"' "$CATALOG"; then
  ok "persistent-flake (3 distinct PRs) appended to check_flakes:"
else
  fail "persistent-flake not appended to check_flakes:"
fi

if grep -q 'tracking_gap: INFRA-9901' "$CATALOG"; then
  ok "quarantine entry carries the filed tracking_gap"
else
  fail "quarantine entry missing tracking_gap"
fi

if ! grep -q 'check_name: "occasional-flake"' "$CATALOG"; then
  ok "occasional-flake (2 distinct PRs, below threshold) left alone (transient)"
else
  fail "occasional-flake was quarantined despite being below threshold"
fi

if [[ "$(grep -c 'check_name: "already-known-flake"' "$CATALOG")" -eq 1 ]]; then
  ok "already-known-flake not duplicated (dedupe against existing catalog entry)"
else
  fail "already-known-flake entry count wrong (dedupe failed)"
fi

if grep -q '"kind":"flake_auto_quarantined".*"check_name":"persistent-flake".*"failure_class":"permanent"' "$AMBIENT"; then
  ok "flake_auto_quarantined event carries failure_class=permanent taxonomy"
else
  fail "flake_auto_quarantined event missing failure_class=permanent"
fi

tick_count="$(grep -c '"kind":"flake_auto_quarantine_tick"' "$AMBIENT" || true)"
if [[ "$tick_count" -ge 2 ]]; then
  ok "flake_auto_quarantine_tick (cost/report event) emitted each run"
else
  fail "flake_auto_quarantine_tick not emitted as expected (count=$tick_count)"
fi

if grep -q '"quarantined_count":1' "$AMBIENT" && grep -q '"gaps_filed_count":1' "$AMBIENT"; then
  ok "tick event reports cost (gaps_filed_count) to operator"
else
  fail "tick event missing quarantined_count/gaps_filed_count"
fi

# ── Test group 3: idempotence — second run doesn't re-quarantine ───────────
before_lines="$(wc -l < "$CATALOG")"
run_script >/dev/null 2>&1
after_lines="$(wc -l < "$CATALOG")"
if [[ "$before_lines" -eq "$after_lines" ]]; then
  ok "second tick is idempotent (state-file dedupe prevents re-quarantine)"
else
  fail "second tick re-mutated the catalog (expected idempotence via state file)"
fi

# ── Test group 4: --report mode reads back the audit trail ─────────────────
report_out="$(CHUMP_AMBIENT_PATH="$AMBIENT" "$SCRIPT" --report 2>&1)"
if echo "$report_out" | grep -q "persistent-flake"; then
  ok "--report surfaces the quarantine audit trail"
else
  fail "--report did not surface persistent-flake"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
