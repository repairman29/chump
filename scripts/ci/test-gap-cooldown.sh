#!/usr/bin/env bash
# scripts/ci/test-gap-cooldown.sh — INFRA-1220

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/coord/lib/gap-cooldown.sh"
CLI="$REPO_ROOT/scripts/coord/gap-cooldown.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$LIB" ] || fail "library missing: $LIB"
[ -x "$CLI" ] || fail "CLI missing: $CLI"

export CHUMP_LOCK_DIR="$TMP"
# shellcheck disable=SC1090
source "$LIB"

# ── Test 1: clean state — not active ──────────────────────────────────────
if gap_cooldown_active "INFRA-9999"; then fail "fresh gap should not be in cooldown"; fi
ok "fresh gap → no cooldown"

# ── Test 2: stamp → active ────────────────────────────────────────────────
gap_cooldown_stamp "INFRA-9999" "1234" "zombie"
if ! gap_cooldown_active "INFRA-9999"; then fail "stamped gap should be in cooldown"; fi
ok "stamp → active"

# ── Test 3: status output ─────────────────────────────────────────────────
out=$(gap_cooldown_status "INFRA-9999")
echo "$out" | grep -q "ACTIVE" || fail "status should show ACTIVE: $out"
echo "$out" | grep -q "1234" || fail "status should cite PR: $out"
echo "$out" | grep -q "zombie" || fail "status should cite reason: $out"
ok "status output OK"

# ── Test 4: clear → inactive ──────────────────────────────────────────────
gap_cooldown_clear "INFRA-9999" "test-clear"
if gap_cooldown_active "INFRA-9999"; then fail "cleared gap should not be active"; fi
ok "clear → inactive"

# ── Test 5: CHUMP_NO_GAP_COOLDOWN bypass ──────────────────────────────────
gap_cooldown_stamp "INFRA-9998" "5678" "test"
if ! gap_cooldown_active "INFRA-9998"; then fail "should be active before bypass"; fi
if CHUMP_NO_GAP_COOLDOWN=1 gap_cooldown_active "INFRA-9998"; then
    fail "CHUMP_NO_GAP_COOLDOWN=1 should report inactive"
fi
ok "CHUMP_NO_GAP_COOLDOWN=1 bypass"

# ── Test 6: expired stamp auto-prunes ─────────────────────────────────────
gap_cooldown_stamp "INFRA-9997" "111" "expired-test"
# Manually rewrite expires_at_epoch to the past
python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d['expires_at_epoch'] = 1
json.dump(d, open(f, 'w'))
" "$TMP/.gap-cooldown/INFRA-9997.json"
if gap_cooldown_active "INFRA-9997"; then fail "expired stamp should report inactive"; fi
[ -f "$TMP/.gap-cooldown/INFRA-9997.json" ] && fail "expired stamp should be auto-pruned"
ok "expired stamp auto-prunes"

# ── Test 7: CLI stamp/clear/status round-trip ─────────────────────────────
"$CLI" stamp INFRA-7777 --pr 4242 --reason "cli-test" >/dev/null
"$CLI" active INFRA-7777 || fail "CLI active should exit 0 after stamp"
cli_status=$("$CLI" status INFRA-7777)
echo "$cli_status" | grep -q "4242" || fail "CLI status missing PR"
if "$CLI" clear INFRA-7777 2>/dev/null; then
    fail "CLI clear without --reason should fail"
fi
"$CLI" clear INFRA-7777 --reason "test" >/dev/null
if "$CLI" active INFRA-7777; then fail "should be inactive after clear"; fi
ok "CLI round-trip"

# ── Test 8: re-stamp resets expiry ────────────────────────────────────────
CHUMP_GAP_REROLL_COOLDOWN_S=10 gap_cooldown_stamp "INFRA-6666" "1" "first"
sleep 1
first_exp=$(python3 -c "import json; print(json.load(open('$TMP/.gap-cooldown/INFRA-6666.json'))['expires_at_epoch'])")
CHUMP_GAP_REROLL_COOLDOWN_S=10 gap_cooldown_stamp "INFRA-6666" "2" "second"
second_exp=$(python3 -c "import json; print(json.load(open('$TMP/.gap-cooldown/INFRA-6666.json'))['expires_at_epoch'])")
[ "$second_exp" -ge "$first_exp" ] || fail "re-stamp should not decrease expiry"
ok "re-stamp resets expiry"

echo
echo "All INFRA-1220 gap-cooldown tests passed."
