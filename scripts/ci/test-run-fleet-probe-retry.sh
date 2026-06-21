#!/usr/bin/env bash
# CREDIBLE-138 regression guard.
#
# run-fleet's INFRA-621 launch probe used a single `timeout 30 claude -p ok`
# whose failure set _auth_probe_failed=1 and aborted the WHOLE fleet (0 panes).
# Observed flaky 2/3 under launch-moment contention while credentials were
# valid. Since every worker re-validates its own auth before each spawn
# (worker.sh refresh_oauth_token, CREDIBLE-137), one transient probe failure
# must NOT abort the fleet. The fix: retry the probe N times before giving up,
# with a 90s timeout and (on the subscription path) ANTHROPIC_API_KEY unset.
#
# This test (1) statically asserts the hardenings are present and (2) extracts
# the retry loop and exercises it with a fake `claude` that fails twice then
# succeeds — proving the fleet proceeds rather than aborting on a transient blip.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RF="$ROOT/scripts/dispatch/run-fleet.sh"
[[ -f "$RF" ]] || { echo "FAIL: run-fleet.sh not found at $RF"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# ---- static checks: the hardenings are present in the probe block ----
blk="$(awk '/INFRA-621: probing auth path/{p=1} p{print} p&&/^    done$/{exit}' "$RF")"
grep -q 'CHUMP_FLEET_PROBE_ATTEMPTS' <<<"$blk" && ok "probe attempts are configurable" || fail "no CHUMP_FLEET_PROBE_ATTEMPTS"
grep -q 'timeout 90 claude'          <<<"$blk" && ok "probe timeout raised to 90s"      || fail "probe not using timeout 90"
grep -q 'env -u ANTHROPIC_API_KEY'   <<<"$blk" && ok "subscription path unsets api-key" || fail "no env -u ANTHROPIC_API_KEY"
grep -q 'for _attempt in'            <<<"$blk" && ok "retry loop present"               || fail "no retry loop"

# ---- behavioral: extract the loop and run it against a fake claude ----
loop="$(awk '/^    _probe_rc=1$/{p=1} p{print} p&&/^    done$/{exit}' "$RF")"
[[ -n "$loop" ]] || { echo "FAIL: could not extract probe retry loop"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Fake `claude` on PATH: exit 1 until the CLAUDE_STUB_SUCCEED_AT-th call, then 0.
# (env -u … timeout 90 claude resolves `claude` via PATH, so a stub binary works.)
cat >"$tmp/claude" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$CLAUDE_STUB_COUNTER" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$CLAUDE_STUB_COUNTER"
if [[ "$n" -lt "${CLAUDE_STUB_SUCCEED_AT:-3}" ]]; then echo "stub auth blip $n" >&2; exit 1; fi
echo "ok"; exit 0
STUB
chmod +x "$tmp/claude"
export PATH="$tmp:$PATH" CLAUDE_STUB_COUNTER="$tmp/cnt"
# shellcheck disable=SC2317  # invoked indirectly via the eval'd loop (overrides real sleep)
sleep() { :; }   # neutralise the 3s inter-attempt backoff in the test
_fleet_auth_mode=subscription

# Case A: transient — fails attempts 1 & 2, succeeds on 3 → fleet proceeds.
: >"$tmp/cnt"; export CLAUDE_STUB_SUCCEED_AT=3
eval "$loop"
[[ "${_probe_rc}" -eq 0 ]] && ok "caseA: probe succeeds after retries (rc=0)" || fail "caseA: rc=${_probe_rc} (expected 0)"
[[ "$(cat "$tmp/cnt")" -eq 3 ]] && ok "caseA: made exactly 3 attempts" || fail "caseA: attempts=$(cat "$tmp/cnt") (expected 3)"

# Case B: genuine failure — never succeeds → rc!=0 after all attempts (still surfaces).
: >"$tmp/cnt"; export CLAUDE_STUB_SUCCEED_AT=99
eval "$loop"
[[ "${_probe_rc}" -ne 0 ]] && ok "caseB: persistent failure still surfaces (rc=${_probe_rc} != 0)" || fail "caseB: rc=0 (should have failed)"
[[ "$(cat "$tmp/cnt")" -eq 3 ]] && ok "caseB: exhausted all 3 attempts before aborting" || fail "caseB: attempts=$(cat "$tmp/cnt") (expected 3)"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-run-fleet-probe-retry.sh (probe retries instead of aborting the fleet)"
  exit 0
else
  echo "FAIL: test-run-fleet-probe-retry.sh ($fails assertion(s) failed)"
  exit 1
fi
