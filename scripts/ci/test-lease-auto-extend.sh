#!/usr/bin/env bash
# test-lease-auto-extend.sh — INFRA-1327: 5-assertion test for lease-auto-extend.sh
#
# Each test:
#   - Creates an isolated temp directory with fake lease + ambient.jsonl
#   - Stubs the `gh` binary to return a canned JSON response
#   - Calls lease-auto-extend.sh with env overrides pointing at the temp dir
#   - Asserts the expected outcome
#
# Exit 0 = all 5 assertions pass. Exit 1 = one or more failed.
# Usage: bash scripts/ci/test-lease-auto-extend.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTEND_SCRIPT="$REPO_ROOT/scripts/coord/lease-auto-extend.sh"

pass=0
fail=0

# ── Test harness ──────────────────────────────────────────────────────────────

PASS() { echo "  PASS: $*"; ((pass++)); }
FAIL() { echo "  FAIL: $*"; ((fail++)); }

# setup_env: create isolated temp dir, fake gh binary, fake lease, fake ambient.
# Arguments:
#   $1: lease expires_at offset in seconds relative to now (negative = already expired)
#   $2: gh response type: "armed_open" | "not_armed" | "closed" | "empty"
# Prints to stdout: the temp directory path.
setup_env() {
    local offset_s="$1"
    local gh_type="$2"

    local tmp; tmp="$(mktemp -d)"
    local bin_dir="$tmp/bin"
    local lock_dir="$tmp/.chump-locks"
    mkdir -p "$bin_dir" "$lock_dir"

    # ── Fake lease file ───────────────────────────────────────────────────────
    local now_s; now_s=$(date +%s)
    local exp_s=$(( now_s + offset_s ))
    local exp_iso
    exp_iso="$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp($exp_s, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

    cat > "$lock_dir/claim-infra-test-12345.json" <<EOF
{
  "session_id": "claim-infra-test-12345",
  "paths": [],
  "taken_at": "2026-05-15T00:00:00Z",
  "expires_at": "${exp_iso}",
  "heartbeat_at": "2026-05-15T00:00:00Z",
  "purpose": "gap:INFRA-TEST",
  "gap_id": "INFRA-TEST"
}
EOF

    # ── Empty ambient log ─────────────────────────────────────────────────────
    touch "$lock_dir/ambient.jsonl"

    # ── Stub gh binary ────────────────────────────────────────────────────────
    local gh_script="$bin_dir/gh"

    case "$gh_type" in
        armed_open)
            cat > "$gh_script" <<'GHEOF'
#!/usr/bin/env bash
# Stub: return an open PR with auto_merge armed for any api repos/*/pulls call.
echo '[{"number":42,"state":"open","auto_merge":{"merge_method":"squash"},"head":{"ref":"chump/infra-test-claim"}}]'
GHEOF
            ;;
        not_armed)
            cat > "$gh_script" <<'GHEOF'
#!/usr/bin/env bash
echo '[{"number":42,"state":"open","auto_merge":null,"head":{"ref":"chump/infra-test-claim"}}]'
GHEOF
            ;;
        closed)
            cat > "$gh_script" <<'GHEOF'
#!/usr/bin/env bash
echo '[{"number":42,"state":"closed","auto_merge":{"merge_method":"squash"},"head":{"ref":"chump/infra-test-claim"}}]'
GHEOF
            ;;
        empty)
            cat > "$gh_script" <<'GHEOF'
#!/usr/bin/env bash
echo '[]'
GHEOF
            ;;
    esac
    chmod +x "$gh_script"

    printf '%s' "$tmp"
}

# run_extend: call lease-auto-extend.sh with environment pointing at $tmp.
run_extend() {
    local tmp="$1"
    shift
    PATH="$tmp/bin:$PATH" \
    CHUMP_LOCK_DIR="$tmp/.chump-locks" \
    CHUMP_AMBIENT_LOG="$tmp/.chump-locks/ambient.jsonl" \
    CHUMP_CACHE_DB="$tmp/nonexistent-cache.db" \
    CHUMP_REPO_SLUG="testowner/testrepo" \
    GIT_DIR="$REPO_ROOT/.git" \
    GIT_WORK_TREE="$REPO_ROOT" \
    bash "$EXTEND_SCRIPT" "$@" 2>/dev/null
}

# get_expires_at: read expires_at from the fake lease.
get_expires_at() {
    local tmp="$1"
    python3 -c "
import json
d = json.load(open('$tmp/.chump-locks/claim-infra-test-12345.json'))
print(d.get('expires_at',''))
"
}

# ── Test 1: near-expiry lease with armed PR → extended ───────────────────────
echo "Test 1: near-expiry lease with armed auto-merge PR → should extend"
t1="$(setup_env 300 armed_open)"  # expires in 5 min (< 1800s threshold)
before_exp="$(get_expires_at "$t1")"
run_extend "$t1"
after_exp="$(get_expires_at "$t1")"
now_s=$(date +%s)
after_exp_s="$(python3 -c "
from datetime import datetime, timezone
s = '$after_exp'.rstrip('Z')
dt = datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
" 2>/dev/null || echo 0)"

if [[ "$before_exp" != "$after_exp" ]] && [[ "$after_exp_s" -gt $(( now_s + 7200 )) ]]; then
    PASS "expires_at updated from $before_exp → $after_exp"
else
    FAIL "expires_at not extended: before=$before_exp after=$after_exp"
fi

# Check ambient event
if grep -q '"kind":"lease_auto_extended"' "$t1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    PASS "lease_auto_extended event emitted"
else
    FAIL "lease_auto_extended event missing from ambient.jsonl"
fi
rm -rf "$t1"

# ── Test 2: lease with plenty of time → not extended ─────────────────────────
echo ""
echo "Test 2: lease with 2h remaining → should NOT extend"
t2="$(setup_env 7200 armed_open)"  # expires in 2h (> 1800s threshold)
before_exp="$(get_expires_at "$t2")"
run_extend "$t2"
after_exp="$(get_expires_at "$t2")"
if [[ "$before_exp" == "$after_exp" ]]; then
    PASS "expires_at unchanged (${before_exp})"
else
    FAIL "expires_at changed unexpectedly: $before_exp → $after_exp"
fi
rm -rf "$t2"

# ── Test 3: no armed PR → lease not extended ─────────────────────────────────
echo ""
echo "Test 3: near-expiry lease but no armed PR → should NOT extend"
t3="$(setup_env 300 not_armed)"  # expires in 5 min, but PR has auto_merge=null
before_exp="$(get_expires_at "$t3")"
run_extend "$t3"
after_exp="$(get_expires_at "$t3")"
if [[ "$before_exp" == "$after_exp" ]]; then
    PASS "expires_at unchanged (no armed PR)"
else
    FAIL "expires_at changed when PR was not armed: $before_exp → $after_exp"
fi
rm -rf "$t3"

# ── Test 4: closed PR → lease not extended ───────────────────────────────────
echo ""
echo "Test 4: near-expiry lease, PR in closed state → should NOT extend"
t4="$(setup_env 300 closed)"  # expires in 5 min, but PR is closed
before_exp="$(get_expires_at "$t4")"
run_extend "$t4"
after_exp="$(get_expires_at "$t4")"
if [[ "$before_exp" == "$after_exp" ]]; then
    PASS "expires_at unchanged (closed PR)"
else
    FAIL "expires_at changed when PR was closed: $before_exp → $after_exp"
fi
rm -rf "$t4"

# ── Test 5: ambient event has correct fields ──────────────────────────────────
echo ""
echo "Test 5: ambient event contains all required fields"
t5="$(setup_env 300 armed_open)"
run_extend "$t5"
event_line="$(grep '"kind":"lease_auto_extended"' "$t5/.chump-locks/ambient.jsonl" 2>/dev/null | tail -1)"
if [[ -z "$event_line" ]]; then
    FAIL "no lease_auto_extended event found"
else
    # Verify each required field.
    all_ok=1
    for field in '"gap_id"' '"pr_number"' '"new_expires"' '"reason":"auto_merge_armed"'; do
        if ! printf '%s' "$event_line" | grep -q "$field"; then
            FAIL "missing field $field in event: $event_line"
            all_ok=0
        fi
    done
    if [[ "$all_ok" -eq 1 ]]; then
        PASS "event has all required fields (gap_id, pr_number, new_expires, reason=auto_merge_armed)"
    fi
fi
rm -rf "$t5"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────"
echo "Results: ${pass} passed, ${fail} failed"
if [[ "$fail" -eq 0 ]]; then
    echo "ALL PASS"
    exit 0
else
    echo "SOME FAILED"
    exit 1
fi
