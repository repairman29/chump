#!/usr/bin/env bash
# RESILIENT-088 regression guard.
#
# run-fleet's INFRA-621 launch probe treated ANY non-zero `claude -p ok`
# exit as an auth failure and halted the fleet (exit 3, needs
# CHUMP_FLEET_FORCE_LAUNCH=1 to bypass). But a retired/unknown model 404s
# the same way for valid and invalid credentials — Anthropic authenticates
# the request before resolving the model, so reaching a 404 at all proves
# auth was accepted. The fix treats a 404/model-not-found probe error as
# auth-OK instead of aborting the launch.
#
# This test (1) statically asserts the 404-detection hardening is present
# and (2) extracts the retry-loop + 404-classification block and exercises
# it with a fake `claude` that always 404s on a retired model, proving the
# probe now reports success (rc=0) instead of failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RF="$ROOT/scripts/dispatch/run-fleet.sh"
[[ -f "$RF" ]] || { echo "FAIL: run-fleet.sh not found at $RF"; exit 1; }

fails=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; fails=$((fails+1)); }

# ---- static checks: the 404-classification hardening is present ----
blk="$(awk '/INFRA-621: probing auth path/{p=1} p{print} p&&/^    fi$/{exit}' "$RF")"
grep -q 'RESILIENT-088' <<<"$blk" && ok "RESILIENT-088 fix marker present" || fail "no RESILIENT-088 marker"
grep -q 'model_not_found\|not_found_error' <<<"$blk" && ok "404/model-not-found pattern detection present" || fail "no 404 pattern detection"

# ---- behavioral: extract retry loop + 404 reclassification, run against a fake claude that always 404s ----
block="$(awk '/^    _probe_rc=1$/{p=1} p&&/^    if \[\[ \$_probe_rc -eq 0 \]\]; then$/{exit} p{print}' "$RF")"
[[ -n "$block" ]] || { echo "FAIL: could not extract probe+404-classification block"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Fake `claude` on PATH: always fails with a retired-model 404, as if a
# hardcoded/default model ID has since been retired by Anthropic.
cat >"$tmp/claude" <<'STUB'
#!/usr/bin/env bash
echo 'API Error: 404 {"type":"error","error":{"type":"not_found_error","message":"model: claude-2.0-retired-stub not_found"}}' >&2
exit 1
STUB
chmod +x "$tmp/claude"
export PATH="$tmp:$PATH"
# shellcheck disable=SC2317  # invoked indirectly via the eval'd loop (overrides real sleep)
sleep() { :; }   # neutralise the 3s inter-attempt backoff in the test
_fleet_auth_mode=api_key

eval "$block"
[[ "${_probe_rc}" -eq 0 ]] && ok "404 on a retired model is reclassified as auth-OK (rc=0)" || fail "rc=${_probe_rc} (expected 0 — 404 misread as auth failure)"

# ---- control: a genuine 401 must still surface as a real auth failure ----
cat >"$tmp/claude" <<'STUB'
#!/usr/bin/env bash
echo 'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' >&2
exit 1
STUB
chmod +x "$tmp/claude"
eval "$block"
[[ "${_probe_rc}" -ne 0 ]] && ok "genuine 401 still surfaces as a real failure (rc=${_probe_rc} != 0)" || fail "rc=0 (a real auth failure was masked)"

echo ""
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: test-run-fleet-probe-404-not-auth-fail.sh (retired-model 404 no longer halts the fleet on valid auth)"
  exit 0
else
  echo "FAIL: test-run-fleet-probe-404-not-auth-fail.sh ($fails assertion(s) failed)"
  exit 1
fi
