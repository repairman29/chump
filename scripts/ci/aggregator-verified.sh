#!/usr/bin/env bash
# aggregator-verified.sh — CREDIBLE-269 (SHIP-INFRA 1/7)
#
# Decision-logic core for the `verified` aggregator described in
# docs/design/CI_VERIFIED_AGGREGATOR.md (META-134). Classifies each CI lane's
# GitHub-Actions result (and, for path-filtered lanes, its stub sibling's
# result) into PASS / FAIL / PENDING per that doc's §2.2-2.3, then prints one
# overall verdict.
#
# This is the "single legible required check" foundation: branch protection
# and the ruleset are meant to eventually require ONLY the `verified` check
# (see notes on CREDIBLE-269) instead of a scattered set of named contexts
# that drift out of sync with ci.yml/branch-protection/ruleset (the 3-surface
# drift class documented in docs/strategy/CI_REVIEW_2026-05-29.md).
#
# Usage:
#   aggregator-verified.sh --lane "name=result[,stub_result]" [--lane ...] \
#       [--pr N] [--sha SHA] [--ambient-log PATH]
#
# result / stub_result are literal GitHub Actions job `result` values:
#   success | failure | cancelled | skipped | in_progress | queued | ""(missing)
#
# Lane classification (per docs/design/CI_VERIFIED_AGGREGATOR.md §2.2-2.3):
#   - Single-value lane (no stub declared for this lane):
#       success           -> PASS
#       skipped           -> PASS   (lane genuinely doesn't apply this PR)
#       failure/cancelled -> FAIL
#       in_progress/queued/"" -> PENDING
#   - Two-value lane "real,stub" (path-filtered lane with a stub sibling):
#       real=success                       -> PASS (stub irrelevant)
#       real=skipped, stub=success         -> PASS (SKIPPED-PATH-FILTER)
#       real=skipped, stub=skipped         -> FAIL (missing-stub config bug)
#       real=failure/cancelled             -> FAIL
#       real=in_progress/queued/""         -> PENDING (unless another lane FAILed)
#
# Overall verdict:
#   FAIL    if any lane classifies FAIL
#   PENDING if no lane FAILed but at least one lane is PENDING
#   PASS    if every lane classifies PASS
#
# Exit codes: 0=PASS  1=FAIL  2=PENDING  3=invocation error
#
# Emits kind=verified_aggregator_decision to ambient.jsonl (best-effort; never
# fails the run if the log can't be written).
#
# Environment:
#   CHUMP_AMBIENT_LOG   override ambient.jsonl path

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/../.." && pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LANES=()
PR=""
SHA=""

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lane)         LANES+=("$2"); shift 2 ;;
        --pr)           PR="$2"; shift 2 ;;
        --sha)          SHA="$2"; shift 2 ;;
        --ambient-log)  AMBIENT_LOG="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "[aggregator-verified] unknown arg: $1" >&2; exit 3 ;;
    esac
done

if [[ ${#LANES[@]} -eq 0 ]]; then
    echo "[aggregator-verified] ERROR: at least one --lane is required" >&2
    exit 3
fi

classify_lane() {
    # $1 = "name=result[,stub_result]"
    local spec="$1"
    local name="${spec%%=*}"
    local rest="${spec#*=}"
    local real="${rest%%,*}"
    local stub=""
    local has_stub=0
    if [[ "$rest" == *,* ]]; then
        has_stub=1
        stub="${rest#*,}"
    fi

    case "$real" in
        success)
            echo "PASS"; return ;;
        failure|cancelled)
            echo "FAIL"; return ;;
        skipped)
            if [[ "$has_stub" -eq 0 ]]; then
                echo "PASS"
                return
            fi
            case "$stub" in
                success) echo "PASS" ;;
                failure|cancelled) echo "FAIL" ;;
                skipped) echo "FAIL" ;;   # missing-stub config bug (§2.3)
                *) echo "PENDING" ;;
            esac
            return ;;
        in_progress|queued|"")
            echo "PENDING"; return ;;
        *)
            echo "FAIL"; return ;;
    esac
}

OVERALL="PASS"
declare -a LANE_REPORT=()
for spec in "${LANES[@]}"; do
    name="${spec%%=*}"
    verdict="$(classify_lane "$spec")"
    LANE_REPORT+=("${name}=${verdict}")
    echo "lane ${name}: ${verdict}"
    if [[ "$verdict" == "FAIL" ]]; then
        OVERALL="FAIL"
    elif [[ "$verdict" == "PENDING" && "$OVERALL" != "FAIL" ]]; then
        OVERALL="PENDING"
    fi
done

echo "VERDICT=${OVERALL}"

# ── ambient emit (best-effort) ──────────────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
    lanes_json=$(printf '%s\n' "${LANE_REPORT[@]}" | python3 -c '
import json, sys
d = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    k, v = line.split("=", 1)
    d[k] = v
print(json.dumps(d))
')
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    python3 -c '
import json, sys
event = {
    "ts": sys.argv[1],
    "kind": "verified_aggregator_decision",
    "pr": sys.argv[2],
    "sha": sys.argv[3],
    "verdict": sys.argv[4],
    "lanes_classified": json.loads(sys.argv[5]),
}
try:
    with open(sys.argv[6], "a") as f:
        f.write(json.dumps(event) + "\n")
except OSError:
    pass
' "$ts" "$PR" "$SHA" "$OVERALL" "$lanes_json" "$AMBIENT_LOG" 2>/dev/null || true
fi

case "$OVERALL" in
    PASS) exit 0 ;;
    FAIL) exit 1 ;;
    PENDING) exit 2 ;;
esac
