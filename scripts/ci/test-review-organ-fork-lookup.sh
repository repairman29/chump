#!/usr/bin/env bash
# RESILIENT-2225: maybe_arm distinguishes a failed fork lookup from a real fork; neither arms.
set -euo pipefail
cd "$(dirname "$0")/../.."
src=scripts/dispatch/review-organ-tick.sh
fn="$(sed -n '/^maybe_arm() {/,/^}/p' "$src")"
run() { # $1 = gh stub output, $2 = gh exit code
    local out
    out="$(
        log() { echo "LOG $*"; }
        GH() { printf '%s' "$GH_OUT"; return "$GH_RC"; }
        review_hold_allows() { echo REACHED_ARM_PATH; return 1; }
        REPO=x ORGAN_LOGIN=o
        eval "$fn"
        GH_OUT="$1" GH_RC="$2" maybe_arm 1 abc 2>&1
    )"
    printf '%s' "$out"
}
o="$(run true 0)";   [[ "$o" == *"cross-repository (fork)"* && "$o" != *REACHED* ]] || { echo "FAIL real fork: $o"; exit 1; }
o="$(run '' 1)";     [[ "$o" == *"fork lookup failed"* && "$o" != *"(fork)"* && "$o" != *REACHED* ]] || { echo "FAIL failed lookup: $o"; exit 1; }
o="$(run false 0)";  [[ "$o" == *REACHED* ]] || { echo "FAIL same-repo: $o"; exit 1; }
echo "PASS"
