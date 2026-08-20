#!/usr/bin/env bash
# scripts/coord/systemic-red-detector.sh — RESILIENT-337 (W-015)
#
# Detects the "SYSTEMIC-RED" wedge class: N>=3 open code PRs failing the
# IDENTICAL required check — a shared broken gate. Distinct from
# main-health-watchdog.sh (INFRA-1656), which only alarms on red MAIN
# itself. A shared-check wedge can exist while main is perfectly green —
# e.g. a farmer-flap false-red that every open PR inherits on rebase, or
# a genuinely broken required job — and main-health-watchdog has no
# visibility into that because it never looks past main's own HEAD.
#
# Also distinct from W-AGG (scripts/coord/wedge-watch.sh) which only
# counts "any PR BLOCKED with any failing check" — a coarse aggregate that
# doesn't confirm the failures share one check, doesn't name it, and
# requires mergeStateStatus=BLOCKED (a farmer-flap false-red often hasn't
# reached BLOCKED yet). This detector groups failing checks BY NAME across
# ALL open PRs regardless of mergeStateStatus, and only alarms when one
# check name is shared by >= threshold PRs — so the alarm names the exact
# shared gate, not just a raw count.
#
# Precedent (2026-08-20): 14 PRs stacked on a farmer-flap false-red for
# hours with ZERO alarm; the board only caught it after operator prodding.
#
# Usage:
#   scripts/coord/systemic-red-detector.sh                # single scan, emit + exit 0
#   scripts/coord/systemic-red-detector.sh --check-only    # exit 1 if signature fires, no emits
#   scripts/coord/systemic-red-detector.sh --json          # structured result on stdout
#
# Env:
#   CHUMP_SYSTEMIC_RED_THRESHOLD  — min PRs sharing a failing check to alarm (default 3)
#   CHUMP_SYSTEMIC_RED_PR_LIMIT   — max open PRs to scan (default 50)
#   CHUMP_REPO_ROOT               — repo root (test hook)
#   CHUMP_AMBIENT_LOG             — ambient.jsonl path override (test hook)
#   CHUMP_SYSTEMIC_RED_DISABLED=1 — bypass, exit 0 immediately, no emits
#
# Events emitted to ambient.jsonl (source=systemic_red_detector):
#   systemic_red_scan_started
#   systemic_red_scan_completed  — result=clean|detected, elapsed_ms, gh_calls
#   wedge_detected (wedge_class=W-015) — fired alongside scan_completed when
#       any check name is shared by >= threshold open PRs' failing checks.
#       Fields: check (the shared gate name), pr_count, pr_numbers (csv),
#       suspected_cause (best-effort heuristic).
#
# Smoke test: scripts/ci/test-systemic-red-detector.sh

set -uo pipefail

if [[ "${CHUMP_SYSTEMIC_RED_DISABLED:-0}" == "1" ]]; then
    echo "[systemic-red-detector] CHUMP_SYSTEMIC_RED_DISABLED=1 — exiting"
    exit 0
fi

REPO_ROOT="${CHUMP_REPO_ROOT:-${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
THRESHOLD="${CHUMP_SYSTEMIC_RED_THRESHOLD:-3}"
PR_LIMIT="${CHUMP_SYSTEMIC_RED_PR_LIMIT:-50}"
CHECK_ONLY=0
FORMAT=text

for a in "$@"; do
    case "$a" in
        --check-only) CHECK_ONLY=1 ;;
        --json) FORMAT=json ;;
        --help|-h)
            head -40 "$0" | grep '^#' | sed 's/^# //; s/^#//'
            exit 0
            ;;
    esac
done

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

_now_ms() {
    date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$' && date +%s%3N || echo "$(( $(date +%s) * 1000 ))"
}

_emit() {
    [[ "$CHECK_ONLY" -eq 1 ]] && return
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"systemic_red_detector"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

cd "$REPO_ROOT" 2>/dev/null || { echo "FATAL: cannot cd to $REPO_ROOT" >&2; exit 2; }

START_MS="$(_now_ms)"
GH_CALLS=0
_emit "systemic_red_scan_started"

if ! command -v gh >/dev/null 2>&1; then
    ELAPSED=$(( $(_now_ms) - START_MS ))
    _emit "systemic_red_scan_completed" \
        "\"result\":\"error\"" "\"reason\":\"gh not on PATH\"" \
        "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    [[ "$FORMAT" == "json" ]] && echo '{"status":"error","reason":"gh not on PATH"}'
    exit 2
fi

GH_CALLS=$((GH_CALLS + 1))
PARSE_SCRIPT="$(mktemp)"
trap 'rm -f "$PARSE_SCRIPT"' EXIT
cat > "$PARSE_SCRIPT" <<'PYEOF'
import json, sys

threshold = int(sys.argv[1])
try:
    data = json.load(sys.stdin)
except Exception:
    data = []

by_check = {}
for p in data or []:
    num = p.get("number")
    if num is None:
        continue
    seen_for_pr = set()
    for c in (p.get("statusCheckRollup") or []):
        conclusion = (c.get("conclusion") or "").upper()
        if conclusion not in ("FAILURE", "TIMED_OUT"):
            continue
        name = c.get("name") or c.get("workflowName") or "unknown"
        if name in seen_for_pr:
            continue
        seen_for_pr.add(name)
        by_check.setdefault(name, []).append(num)

# Sort groups by PR count desc, then name asc, for deterministic output.
groups = sorted(by_check.items(), key=lambda kv: (-len(kv[1]), kv[0]))

alarming = [(name, prs) for name, prs in groups if len(prs) >= threshold]

if not alarming:
    print("NONE")
else:
    for name, prs in alarming:
        pr_csv = ",".join(str(x) for x in sorted(prs))
        print(f"{name}\t{pr_csv}\t{len(prs)}")
PYEOF

RESULT_LINES="$(gh pr list --state open --json number,statusCheckRollup --limit "$PR_LIMIT" 2>/dev/null \
    | python3 "$PARSE_SCRIPT" "$THRESHOLD" 2>/dev/null || echo "NONE")"
[[ -z "$RESULT_LINES" ]] && RESULT_LINES="NONE"

_suspected_cause() {
    local check_name_lower
    check_name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$check_name_lower" in
        *farmer*|*flake*|*flaky*)
            echo "known infra-flake pattern (farmer/daemon flap) — verify with a fresh empty-diff PR before assuming a real logic regression" ;;
        *runner*|*timeout*|*timed_out*)
            echo "runner/timeout instability — check self-hosted runner health before assuming a logic bug" ;;
        *)
            echo "shared required check regression — likely a broken gate or infra flake common to all listed PRs; verify with a fresh empty-diff PR before assuming a logic bug" ;;
    esac
}

ELAPSED=$(( $(_now_ms) - START_MS ))

if [[ "$RESULT_LINES" == "NONE" ]]; then
    _emit "systemic_red_scan_completed" \
        "\"result\":\"clean\"" "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    [[ "$FORMAT" == "json" ]] && printf '{"status":"clean","elapsed_ms":%d,"gh_calls":%d}\n' "$ELAPSED" "$GH_CALLS"
    [[ "$FORMAT" != "json" ]] && echo "systemic-red-detector: clean (no check shared by >= $THRESHOLD open PRs)"
    exit 0
fi

# ── Detected: at least one shared-check group crossed the threshold ────────
FIRST_LINE=1
DETECTED_ANY=0
while IFS=$'\t' read -r CHECK_NAME PR_CSV PR_COUNT; do
    [[ -z "$CHECK_NAME" ]] && continue
    DETECTED_ANY=1
    CAUSE="$(_suspected_cause "$CHECK_NAME")"
    _emit "wedge_detected" \
        "\"wedge_class\":\"W-015\"" \
        "\"reason\":\"$PR_COUNT open PRs failing identical check '$CHECK_NAME'\"" \
        "\"check\":\"$CHECK_NAME\"" \
        "\"pr_count\":$PR_COUNT" \
        "\"pr_numbers\":\"$PR_CSV\"" \
        "\"suspected_cause\":\"$CAUSE\""
    if [[ "$FORMAT" != "json" ]]; then
        echo "systemic-red-detector: W-015 DETECTED — check '$CHECK_NAME' failing on $PR_COUNT PRs ($PR_CSV); suspected cause: $CAUSE"
    fi
    FIRST_LINE=0
done <<< "$RESULT_LINES"

if [[ "$DETECTED_ANY" -eq 1 ]]; then
    _emit "systemic_red_scan_completed" \
        "\"result\":\"detected\"" "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    if [[ "$FORMAT" == "json" ]]; then
        printf '{"status":"detected","elapsed_ms":%d,"gh_calls":%d}\n' "$ELAPSED" "$GH_CALLS"
    fi
    [[ "$CHECK_ONLY" -eq 1 ]] && exit 1
    exit 0
else
    _emit "systemic_red_scan_completed" \
        "\"result\":\"clean\"" "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    [[ "$FORMAT" == "json" ]] && printf '{"status":"clean","elapsed_ms":%d,"gh_calls":%d}\n' "$ELAPSED" "$GH_CALLS"
    exit 0
fi
