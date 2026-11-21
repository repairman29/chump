#!/usr/bin/env bash
# test-gap-failure-detection.sh — INFRA-872
#
# Exercises scripts/coord/detect-gap-failure.sh against synthetic lease +
# ambient fixtures. Asserts the right gap_failed events fire.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/detect-gap-failure.sh"
[[ -x "$DETECTOR" ]] || { echo "FAIL: $DETECTOR not executable"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCKS="$TMP/locks"
AMB="$LOCKS/ambient.jsonl"
mkdir -p "$LOCKS"

# Args to this helper are split: arguments to the DETECTOR (any leading
# tokens that start with `--`) are passed after the bash command; remaining
# tokens are VAR=val pairs given to `env` BEFORE the bash command.
run_detector() {
  local detector_args=()
  local env_args=()
  for tok in "$@"; do
    if [[ "$tok" == --* ]]; then
      detector_args+=("$tok")
    else
      env_args+=("$tok")
    fi
  done
  env \
    CHUMP_AMBIENT_LOG="$AMB" \
    CHUMP_LOCKS_DIR="$LOCKS" \
    REPO_ROOT="$REPO_ROOT" \
    ${env_args[@]+"${env_args[@]}"} \
    bash "$DETECTOR" ${detector_args[@]+"${detector_args[@]}"} 2>&1
}

ts_iso() {
  python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

seed_lease() {
  local gap="$1" age_s="$2"
  local ts; ts="$(ts_iso "$age_s")"
  cat > "$LOCKS/claim-$(echo "$gap" | tr '[:upper:]' '[:lower:]')-99999-1234.json" <<EOF
{"session_id":"claim-$gap-99999-1234","paths":[],"taken_at":"$ts","heartbeat_at":"$ts","expires_at":"$ts","purpose":"gap:$gap","gap_id":"$gap"}
EOF
}

# ── Scenario 1: fresh lease (< 2h) → no detection ────────────────────────────
: > "$AMB"
rm -f "$LOCKS"/claim-*.json
seed_lease "FAKE-001" 600           # 10 min old
out=$(run_detector)
echo "$out" | grep -q "FAIL \[stalled\]" && fail "fresh lease should not be stalled"
ok "scenario 1: fresh lease (10 min) not stalled"

# ── Scenario 2: old lease (> 2h) with no matching branch → stalled ───────────
: > "$AMB"
rm -f "$LOCKS"/claim-*.json
seed_lease "FAKE-002" 8000          # >2h old, branch chump/fake-002-claim does not exist
out=$(run_detector CHUMP_STUCK_LEASE_S=7200)
echo "$out" | grep -q "FAIL \[stalled\]: FAKE-002" || fail "old lease should be stalled (out: $out)"
grep -q '"kind":"gap_failed"' "$AMB" || fail "scenario 2: gap_failed event not emitted"
grep -q '"class":"stalled"' "$AMB"   || fail "scenario 2: class=stalled not in event"
grep -q '"gap_id":"FAKE-002"' "$AMB" || fail "scenario 2: gap_id not in event"
ok "scenario 2: old lease + no branch → stalled + gap_failed emitted"

# ── Scenario 3: --json output mode ───────────────────────────────────────────
: > "$AMB"
rm -f "$LOCKS"/claim-*.json
seed_lease "FAKE-003" 8000
out=$(run_detector --json CHUMP_STUCK_LEASE_S=7200)
echo "$out" | grep -q '"findings":\[' || fail "json mode: missing findings array"
echo "$out" | grep -q '"gap_id":"FAKE-003"' || fail "json mode: missing gap_id in findings"
ok "scenario 3: --json output well-formed"

# ── Scenario 4: --dry-run suppresses emission ────────────────────────────────
: > "$AMB"
rm -f "$LOCKS"/claim-*.json
seed_lease "FAKE-004" 8000
run_detector --dry-run CHUMP_STUCK_LEASE_S=7200 >/dev/null
if [[ -s "$AMB" ]]; then
  fail "dry-run: ambient.jsonl should be empty"
fi
ok "scenario 4: --dry-run suppresses emission"

# ── Scenario 5: no leases at all → clean exit ────────────────────────────────
: > "$AMB"
rm -f "$LOCKS"/claim-*.json
out=$(run_detector)
echo "$out" | grep -qE "^FAIL" && fail "no leases: detector should report nothing"
[[ ! -s "$AMB" ]] || fail "no leases: ambient should stay empty"
ok "scenario 5: no leases → clean no-op"

echo
echo "=== test-gap-failure-detection.sh PASSED ==="
