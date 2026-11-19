#!/usr/bin/env bash
# scripts/ci/test-silent-failure-tax.sh — INFRA-1996 (THE FLOOR Phase 2)
#
# Audits silent-failure surfaces (places where code silently does nothing
# when it should do something) and ratchets the count down over time.
#
# Pattern catalog (the surfaces that ate us in INFRA-1986):
#   - shell:  2>/dev/null || true        (silent stderr discard + ignore exit)
#   - rust:   .unwrap_or_default()       (silent fallback on Err)
#   - rust:   .unwrap_or(0|false|...)    (silent fallback to neutral)
#   - rust:   .ok();                     (silent discard of Result)
#
# Each surface should have one of:
#   (a) a "# Silent-OK-Reason: <sentence>" comment on the line ABOVE
#       explaining why this silent failure is intentional (graceful
#       degradation, fail-open on read-only ops, etc.)
#   (b) removal (convert to explicit error handling)
#
# This gate compares the current count to a baseline file
# (scripts/ci/silent-failure-baseline.txt). If the count grows AND the
# new surfaces aren't annotated, the gate FAILS.
#
# Mode (CHUMP_SILENT_FAILURE_TAX_MODE):
#   report (default) — warn-only; never fails CI; updates baseline
#   strict          — fails CI on unannotated growth
#   bootstrap       — writes current counts as new baseline (one-shot reset)
#
# Bypass: CHUMP_SILENT_FAILURE_TAX_BYPASS=1 + commit body trailer
#         'Silent-Failure-Tax-Bypass: <reason>'

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BASELINE="$REPO_ROOT/scripts/ci/silent-failure-baseline.txt"
MODE="${CHUMP_SILENT_FAILURE_TAX_MODE:-report}"

if [[ "${CHUMP_SILENT_FAILURE_TAX_BYPASS:-0}" == "1" ]]; then
    echo "[silent-failure-tax] BYPASS via env — commit body must include 'Silent-Failure-Tax-Bypass: <reason>'"
    exit 0
fi

echo "=== INFRA-1996 silent-failure tax audit (mode: $MODE) ==="
echo

# ── Counters ────────────────────────────────────────────────────────────────
count_pattern() {
    local desc="$1"
    local glob_dir="$2"
    local glob_ext="$3"
    local pattern="$4"
    local raw annotated unannotated
    raw="$(grep -rE "$pattern" "$REPO_ROOT/$glob_dir" --include="$glob_ext" 2>/dev/null | wc -l | xargs)"
    raw="${raw:-0}"
    # Annotated = preceded by a Silent-OK-Reason: comment line. We approximate
    # by counting `Silent-OK-Reason:` comments in the same files.
    annotated="$(grep -rE "Silent-OK-Reason:" "$REPO_ROOT/$glob_dir" --include="$glob_ext" 2>/dev/null | wc -l | xargs)"
    annotated="${annotated:-0}"
    unannotated=$(( raw - annotated ))
    [[ "$unannotated" -lt 0 ]] && unannotated=0
    echo "$desc|$raw|$annotated|$unannotated"
}

CURRENT="$(
    count_pattern "shell:silent_redirect_or_true"   "scripts" "*.sh" '2>/dev/null \|\| true'
    count_pattern "rust:unwrap_or_default"          "src"     "*.rs" '\.unwrap_or_default\(\)'
    count_pattern "rust:unwrap_or_neutral"          "src"     "*.rs" '\.unwrap_or\((0|false|""\.to_string\(\))\)'
    count_pattern "rust:ok_discarded"               "src"     "*.rs" '\.ok\(\)\s*;\s*$'
)"

echo "Current silent-failure surface counts:"
echo "$CURRENT" | awk -F'|' '{
    printf "  %-40s raw=%-6s annotated=%-6s unannotated=%-6s\n", $1, $2, $3, $4
}'
echo

# ── Baseline comparison ────────────────────────────────────────────────────
if [[ "$MODE" == "bootstrap" ]]; then
    echo "$CURRENT" > "$BASELINE"
    echo "[bootstrap] wrote new baseline to $BASELINE"
    exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
    echo "[init] no baseline file — writing initial baseline to $BASELINE"
    echo "$CURRENT" > "$BASELINE"
    exit 0
fi

# Diff current vs baseline per-pattern
EXIT_CODE=0
DRIFT_FOUND=0
while IFS='|' read -r desc cur_raw cur_ann cur_unann; do
    [[ -z "$desc" ]] && continue
    base_raw="$(grep "^$desc|" "$BASELINE" | head -1 | cut -d'|' -f2)"
    base_raw="${base_raw:-0}"
    delta=$(( cur_raw - base_raw ))
    if [[ "$delta" -gt 0 ]]; then
        DRIFT_FOUND=1
        echo "[DRIFT] $desc: +$delta surfaces since baseline (baseline=$base_raw, current=$cur_raw)"
        # If the new surfaces are annotated, it's allowed
        base_ann="$(grep "^$desc|" "$BASELINE" | head -1 | cut -d'|' -f3)"
        base_ann="${base_ann:-0}"
        ann_delta=$(( cur_ann - base_ann ))
        if [[ "$ann_delta" -ge "$delta" ]]; then
            echo "  → all $delta new surfaces annotated (Silent-OK-Reason present) — OK"
        else
            unann_new=$(( delta - ann_delta ))
            echo "  → $unann_new new surface(s) lack Silent-OK-Reason annotation"
            if [[ "$MODE" == "strict" ]]; then
                EXIT_CODE=1
            fi
        fi
    elif [[ "$delta" -lt 0 ]]; then
        echo "[GOOD]  $desc: ${delta} (count went DOWN — surfaces removed/annotated)"
    fi
done <<< "$CURRENT"

if [[ "$DRIFT_FOUND" -eq 0 ]]; then
    echo "[clean] no drift from baseline — silent-failure surfaces stable"
fi

echo
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "=== Result: PASS (mode: $MODE) ==="
    if [[ "$MODE" == "report" ]] && [[ "$DRIFT_FOUND" -eq 1 ]]; then
        echo "(report mode — not failing CI; switch to strict via CHUMP_SILENT_FAILURE_TAX_MODE=strict to enforce)"
    fi
else
    echo "=== Result: FAIL — unannotated silent-failure surfaces added ==="
    echo
    echo "Each new silent-failure surface needs a comment on the line above:"
    echo "  # Silent-OK-Reason: <one sentence why this is intentional>"
    echo "  some_command 2>/dev/null || true"
    echo
    echo "Bypass (with audit trail):"
    echo "  CHUMP_SILENT_FAILURE_TAX_BYPASS=1 git push"
    echo "  Commit body: Silent-Failure-Tax-Bypass: <reason>"
fi
exit "$EXIT_CODE"
