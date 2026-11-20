#!/usr/bin/env bash
# scripts/ci/test-graphql-exhausted-empty-coercion-guard.sh — INFRA-2674
#
# Two-layer regression for the recursive graphql_exhausted false-positive
# cascade observed on 2026-06-03 16:00-19:00Z:
#
# Layer 1 (emit-side, scripts/coord/lib/github.sh):
#   `_chump_gh_maybe_emit_exhausted` previously had
#       local gql_rem="${1:-0}"
#   which coerced empty $1 (from malformed _chump_gh_rate_remaining parse)
#   to "0", which then passed `[[ 0 -le 100 ]]` → emit fired with
#   threshold_seen:0. 31 false events / 30 min observed with live GraphQL at
#   4159/5000 healthy.
#
# Layer 2 (detect-side, scripts/coord/bot-merge.sh):
#   The wedge guard's INFRA-2463 live-check routed through the gh PATH shim
#   which has its own failure modes (telemetry/recording-side errors,
#   env-strip in background subprocesses). When the shim failed silently the
#   live remaining became empty → fell into the "real exhaustion" branch
#   → exit 4 even when actual live GraphQL was healthy. Hardened to use
#   CHUMP_GH_NO_SHIM=1 + strict integer-regex validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/coord/lib/github.sh"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

# shellcheck disable=SC1090
source "$LIB"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

_tmp_ambient() {
    local d
    d="$(mktemp -d -t gh-exhausted-guard.XXXXXX)"
    printf '%s\n' "$d/ambient.jsonl"
}

_no_emit() {
    local name="$1" amb="$2"
    if [[ -s "$amb" ]] && grep -q '"kind":"graphql_exhausted"' "$amb"; then
        fail "$name — graphql_exhausted line was emitted but should NOT have been"
        cat "$amb" >&2
    else
        ok "$name — no graphql_exhausted line written"
    fi
}

_yes_emit() {
    local name="$1" amb="$2"
    if [[ -s "$amb" ]] && grep -q '"kind":"graphql_exhausted"' "$amb"; then
        ok "$name — graphql_exhausted line correctly emitted (positive path)"
    else
        fail "$name — graphql_exhausted line NOT emitted but should have been"
    fi
}

# ── Layer 1: emit-side guards ────────────────────────────────────────────────
echo "── Layer 1: emit-side guards (github.sh) ──"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted "" "0" "$amb"
_no_emit "empty string arg (the INFRA-2674 reproducer)" "$amb"
rm -rf "$(dirname "$amb")"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted
_no_emit "missing first arg" "$amb"
rm -rf "$(dirname "$amb")"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted "-1" "0" "$amb"
_no_emit "negative sentinel (INFRA-2484 guard preserved)" "$amb"
rm -rf "$(dirname "$amb")"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted "null" "0" "$amb"
_no_emit "jq 'null' literal" "$amb"
rm -rf "$(dirname "$amb")"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted "{" "0" "$amb"
_no_emit "literal '{' garbage (observed in 2026-06-03 incident)" "$amb"
rm -rf "$(dirname "$amb")"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted "50" "0" "$amb"
_yes_emit "real value under threshold (50 → emit)" "$amb"
rm -rf "$(dirname "$amb")"

amb="$(_tmp_ambient)"; _chump_gh_maybe_emit_exhausted "4266" "0" "$amb"
_no_emit "healthy value (4266 → no emit)" "$amb"
rm -rf "$(dirname "$amb")"

# ── Layer 2: detect-side wedge guard live-check ──────────────────────────────
echo
echo "── Layer 2: detect-side guards (bot-merge.sh wedge) ──"

if grep -q 'CHUMP_GH_NO_SHIM=1 gh api rate_limit' "$BM"; then
    ok "wedge guard live-check uses CHUMP_GH_NO_SHIM=1 (shim-bypass robustness)"
else
    fail "wedge guard live-check does NOT use CHUMP_GH_NO_SHIM=1"
fi

if grep -q '\[\[ "\$_wedge_live_remaining" =~ \^\[0-9\]\+\$ \]\]' "$BM"; then
    ok "wedge guard live-check uses strict integer regex (rejects empty/garbage)"
else
    fail "wedge guard live-check does NOT validate live_remaining as integer"
fi

if grep -q "tr -d '\[:space:\]'" "$BM" || grep -q 'tr -d "\[:space:\]"' "$BM"; then
    ok "wedge guard live-check strips whitespace before validation"
else
    fail "wedge guard live-check does NOT strip whitespace"
fi

echo
echo "── Summary ──"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
