#!/usr/bin/env bash
# test-vercel-resolve.sh — INFRA-8174: vercel-resolve resolves known names, rejects guesses.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
R="$ROOT/scripts/ops/vercel-resolve.sh"
export CHUMP_VERCEL_RESOLVE_OFFLINE=1
unset VERCEL_TOKEN
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

out="$(bash "$R" --json olive 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && ok "olive exits 0" || bad "olive exit $rc"
[[ "$(jq -r .project_name <<<"$out")" == "cartpilot" ]] && ok "olive -> cartpilot" || bad "olive project_name"
[[ "$(jq -r .prod_domain <<<"$out")" == "shopolive.xyz" ]] && ok "olive -> shopolive.xyz" || bad "olive prod_domain"

out="$(bash "$R" --json https://WWW.shopolive.xyz/ 2>/dev/null)"
[[ "$(jq -r .project_name <<<"$out")" == "cartpilot" ]] && ok "domain URL normalizes" || bad "domain URL"

err="$(bash "$R" madeupname 2>&1 >/dev/null)"; rc=$?
[[ $rc -ne 0 ]] && ok "madeupname exits non-zero" || bad "madeupname exit 0"
grep -q "Resolution instructions" <<<"$err" && ok "prints resolve steps" || bad "no resolve steps"
grep -q "madeupname.vercel.app" <<<"$err" && bad "echoed guessed name" || ok "no guessed name echoed"

bash "$R" >/dev/null 2>&1 && bad "empty arg accepted" || ok "empty arg rejected"

exit $fail
