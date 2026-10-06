#!/usr/bin/env bash
# INFRA-382: smoke test for scripts/ops/auto-arm-sweeper.sh (INFRA-374).
#
# The sweeper itself depends on `gh` + a real GitHub session, which CI
# doesn't have without a token. So this test:
#
#   1. Asserts the script exists + is executable.
#   2. Asserts --dry-run is in its --help / usage hint (catches an accidental
#      removal of the safety knob).
#   3. Asserts the WIP/skip/hold regex catches the patterns it documents.
#
# Logic-deeper testing (which PRs would be armed under specific input)
# requires fixture-style mocking of `gh pr list` JSON which would couple
# the test tightly to the script's internals. Keep this test as the
# load-bearing "did anyone delete the script or break its docs" guard.
#
# Run from repo root: bash scripts/ci/test-auto-arm-sweeper.sh

set -e
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SWEEPER="$REPO_ROOT/scripts/ops/auto-arm-sweeper.sh"

# 1. exists + executable
[[ -f "$SWEEPER" ]] && pass "scripts/ops/auto-arm-sweeper.sh exists" \
                   || fail "scripts/ops/auto-arm-sweeper.sh missing"
[[ -x "$SWEEPER" ]] && pass "auto-arm-sweeper.sh is executable" \
                   || fail "auto-arm-sweeper.sh not executable"

# 2. --dry-run is documented + handled
grep -q -- '--dry-run' "$SWEEPER" && pass "--dry-run flag present in script" \
                                  || fail "--dry-run flag absent (safety regression)"

# 3. WIP/hold/skip pattern present (the docs claim these stop arming)
for pat in 'WIP' 'skip' 'hold'; do
    if grep -q -i "$pat" "$SWEEPER"; then
        pass "skip pattern present: $pat"
    else
        fail "skip pattern missing: $pat"
    fi
done

# 4. CHUMP_AUTOARM_SKIP bypass present
grep -q "CHUMP_AUTOARM_SKIP" "$SWEEPER" \
    && pass "CHUMP_AUTOARM_SKIP bypass env var present" \
    || fail "CHUMP_AUTOARM_SKIP bypass env var missing"

# 5. CHUMP_AUTOARM_SKIP=1 actually short-circuits + exits 0
if CHUMP_AUTOARM_SKIP=1 bash "$SWEEPER" --dry-run > /tmp/auto-arm-skip.log 2>&1; then
    grep -q "CHUMP_AUTOARM_SKIP" /tmp/auto-arm-skip.log \
        && pass "CHUMP_AUTOARM_SKIP=1 emits a clear bypass message + exits 0" \
        || fail "CHUMP_AUTOARM_SKIP=1 didn't emit expected message (got: $(head -1 /tmp/auto-arm-skip.log))"
else
    fail "CHUMP_AUTOARM_SKIP=1 should exit 0 (got non-zero)"
fi

# 6. INFRA-8047: behavioural test with a fake `gh` + fake armer.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") echo tester ;;
  "pr list") cat "$FAKE_PRS" ;;
  "api repos/{owner}/{repo}/issues/"*) echo human-op ;;
esac
GH
cat > "$T/armer" <<'AR'
#!/usr/bin/env bash
echo "$2" >> "$ARM_LOG"
AR
chmod +x "$T/bin/gh" "$T/armer"
export PATH="$T/bin:$PATH" FAKE_PRS="$T/prs.json" ARM_LOG="$T/arm.log" \
       CHUMP_AUTOARM_ARMER="$T/armer" CHUMP_AUTOARM_STATE="$T/state.tsv"
: > "$ARM_LOG"
pr_json() { # <labels-json> <autoMerge-json> <sha>
  echo "[{\"number\":7,\"title\":\"x\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"autoMergeRequest\":$2,\"labels\":$1,\"headRefOid\":\"$3\"}]" > "$FAKE_PRS"
}

# held PR: two ticks, never armed
pr_json '[{"name":"hold"}]' null aaa
bash "$SWEEPER" >/dev/null 2>&1; bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "hold label: PR stays unarmed across two ticks" \
                      || fail "hold label: PR was armed"

# unheld PR gets armed
pr_json '[]' null aaa
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "unheld green PR is armed" || fail "unheld PR not armed"

# human disarm (armed state remembered, now unarmed, same sha): not re-armed
: > "$ARM_LOG"
bash "$SWEEPER" >/dev/null 2>&1; bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "human disarm respected across two ticks" || fail "disarmed PR was re-armed"
grep -q "disarmed.human-op" "$T/state.tsv" && pass "disarmer recorded" || fail "disarmer not recorded"

# new push (new sha), no hold label: re-armed
pr_json '[]' null bbb
bash "$SWEEPER" >/dev/null 2>&1
[[ "$(cat "$ARM_LOG")" == "7" ]] && pass "new head SHA re-arms" || fail "new head SHA did not re-arm"

# new push but hold label: still not armed
: > "$ARM_LOG"; pr_json '[{"name":"do-not-merge"}]' null ccc
bash "$SWEEPER" >/dev/null 2>&1
[[ ! -s "$ARM_LOG" ]] && pass "do-not-merge label blocks re-arm" || fail "do-not-merge ignored"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
