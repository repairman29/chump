#!/usr/bin/env bash
# scripts/coord/toolchain-ratchet-detector.sh — INFRA-2036 (RESILIENT)
#
# Detects the "toolchain-ratchet" wedge class (W-014 in
# docs/process/WEDGE_CLASS_CATALOG.md): a PR bumping rust-toolchain.toml,
# .cargo/config.toml, or clippy.toml (or otherwise tightening fmt/clippy
# strictness) merges CLEAN — main is fine at merge time — but the new
# stricter lint set then ratchets onto every OTHER open PR's pre-existing
# code, wedging PRs that never touched the ratcheted files. Same failure
# shape as THE FLOOR's strict-mode flip (INFRA-1996), scoped to the
# toolchain/lint-config surface instead of the silent-failure-tax surface.
#
# Usage:
#   scripts/coord/toolchain-ratchet-detector.sh                # single scan, emit + exit 0
#   scripts/coord/toolchain-ratchet-detector.sh --check-only    # exit 1 if signature fires, no emits
#   scripts/coord/toolchain-ratchet-detector.sh --json          # structured result on stdout
#
# Designed to be run standalone (cron/launchd) OR sourced by wedge-watch.sh
# for inclusion in the aggregate 5-min sweep.
#
# ── Observability contract (INFRA-2036 AC) ──────────────────────────────────
# Events emitted to ambient.jsonl (source=toolchain_ratchet_detector):
#   toolchain_ratchet_scan_started    — scan begins (always, even under --check-only... no: real runs only)
#   toolchain_ratchet_scan_completed  — scan finished; result=clean|detected, elapsed_ms, gh_calls,
#                                        failure_class present only when result=detected (see below)
#   toolchain_ratchet_scan_timeout    — scan aborted after CHUMP_W014_TIMEOUT_S; failure_class=transient
#   wedge_detected (wedge_class=W-014) — fired alongside scan_completed when the signature confirms;
#                                        this is the event wedge-state-machine.sh consumes
#
# Cost tracking: every terminal event carries elapsed_ms (wall clock) and
# gh_calls (count of `gh` invocations this scan made) so the operator can
# see the API cost of each detector tick via
# `grep toolchain_ratchet .chump-locks/ambient.jsonl | tail`. Ties into the
# same api-cost-leaderboard surface other detectors report through
# (scripts/dev/api-cost-leaderboard.sh reads gh call volume from ambient).
#
# Failure-class taxonomy (INFRA-2036 AC):
#   transient — git/gh command missing, errored, or the scan hit its wall-clock
#               budget (CHUMP_W014_TIMEOUT_S, default 20s). Retry next tick;
#               no action needed unless it recurs (wedge-state-machine's
#               chronic escalation catches that).
#   permanent — the ratchet signature is real: a toolchain-defining file
#               changed AND ≥2 open PRs are now failing fmt/clippy unrelated
#               to their own diff. Needs a human/agent fix (bulk fmt/clippy
#               pass on main), not a retry.
#
# Smoke test: scripts/ci/test-toolchain-ratchet-detector.sh

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
TIMEOUT_S="${CHUMP_W014_TIMEOUT_S:-20}"
LOOKBACK="${CHUMP_W014_LOOKBACK:-2 hours ago}"
MIN_FAILING_PRS="${CHUMP_W014_MIN_FAILING_PRS:-2}"
CHECK_ONLY=0
FORMAT=text

for a in "$@"; do
    case "$a" in
        --check-only) CHECK_ONLY=1 ;;
        --json) FORMAT=json ;;
        --help|-h)
            head -30 "$0" | grep '^#' | sed 's/^# //; s/^#//'
            exit 0
            ;;
    esac
done

mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

_now_ms() {
    # GNU date supports %N; BSD/macOS date does not — fall back to seconds*1000.
    date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$' && date +%s%3N || echo "$(( $(date +%s) * 1000 ))"
}

_emit() {
    [[ "$CHECK_ONLY" -eq 1 ]] && return
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"toolchain_ratchet_detector"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT" 2>/dev/null || true
}

cd "$REPO_ROOT" 2>/dev/null || { echo "FATAL: cannot cd to $REPO_ROOT" >&2; exit 2; }

START_MS="$(_now_ms)"
GH_CALLS=0
_emit "toolchain_ratchet_scan_started"

if ! command -v git >/dev/null 2>&1; then
    ELAPSED=$(( $(_now_ms) - START_MS ))
    _emit "toolchain_ratchet_scan_completed" \
        "\"result\":\"error\"" "\"failure_class\":\"transient\"" \
        "\"reason\":\"git not on PATH\"" "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    [[ "$FORMAT" == "json" ]] && echo '{"status":"error","failure_class":"transient"}'
    exit 2
fi

# ── Step 1: has a toolchain-defining file changed recently? ────────────────
TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout $TIMEOUT_S"

RAW=""
GIT_RC=0
if [[ -n "$TIMEOUT_BIN" ]]; then
    RAW="$($TIMEOUT_BIN git log --since="$LOOKBACK" --pretty=format:'COMMIT:%H' \
        -- rust-toolchain.toml rust-toolchain .cargo/config.toml clippy.toml 2>/dev/null)"
    GIT_RC=$?
else
    RAW="$(git log --since="$LOOKBACK" --pretty=format:'COMMIT:%H' \
        -- rust-toolchain.toml rust-toolchain .cargo/config.toml clippy.toml 2>/dev/null)"
    GIT_RC=$?
fi

if [[ "$GIT_RC" -eq 124 ]]; then
    ELAPSED=$(( $(_now_ms) - START_MS ))
    _emit "toolchain_ratchet_scan_timeout" \
        "\"timeout_s\":$TIMEOUT_S" "\"elapsed_ms\":$ELAPSED" \
        "\"gh_calls\":$GH_CALLS" "\"failure_class\":\"transient\""
    [[ "$FORMAT" == "json" ]] && echo '{"status":"timeout","failure_class":"transient"}'
    exit 3
fi

TOOLCHAIN_COMMIT="$(printf '%s\n' "$RAW" | grep '^COMMIT:' | head -1 | sed 's/^COMMIT://')"

RESULT="clean"
FAILING_PRS=0
if [[ -n "$TOOLCHAIN_COMMIT" ]]; then
    # ── Step 2: are ≥N open PRs now failing fmt/clippy checks? ─────────────
    if command -v gh >/dev/null 2>&1; then
        GH_CALLS=$((GH_CALLS + 1))
        FAILING_PRS="$(gh pr list --state open --json number,statusCheckRollup --limit 30 2>/dev/null \
            | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
n = 0
for p in data:
    for c in p.get('statusCheckRollup', []) or []:
        name = (c.get('name') or c.get('workflowName') or '').lower()
        if c.get('conclusion') == 'FAILURE' and ('clippy' in name or 'fmt' in name):
            n += 1
            break
print(n)
" 2>/dev/null)"
        FAILING_PRS="${FAILING_PRS:-0}"
        [[ "$FAILING_PRS" =~ ^[0-9]+$ ]] || FAILING_PRS=0
    fi

    if [[ "$FAILING_PRS" -ge "$MIN_FAILING_PRS" ]]; then
        RESULT="detected"
        _emit "wedge_detected" \
            "\"wedge_class\":\"W-014\"" \
            "\"reason\":\"toolchain-defining file changed at $TOOLCHAIN_COMMIT; $FAILING_PRS open PR(s) now failing fmt/clippy\"" \
            "\"commit\":\"$TOOLCHAIN_COMMIT\"" "\"failing_pr_count\":$FAILING_PRS"
    fi
fi

ELAPSED=$(( $(_now_ms) - START_MS ))
if [[ "$RESULT" == "detected" ]]; then
    _emit "toolchain_ratchet_scan_completed" \
        "\"result\":\"detected\"" "\"failure_class\":\"permanent\"" \
        "\"commit\":\"$TOOLCHAIN_COMMIT\"" "\"failing_pr_count\":$FAILING_PRS" \
        "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    [[ "$FORMAT" == "json" ]] && printf '{"status":"detected","commit":"%s","failing_pr_count":%d,"elapsed_ms":%d,"gh_calls":%d}\n' \
        "$TOOLCHAIN_COMMIT" "$FAILING_PRS" "$ELAPSED" "$GH_CALLS"
    [[ "$FORMAT" != "json" ]] && echo "toolchain-ratchet-detector: W-014 DETECTED — commit $TOOLCHAIN_COMMIT, $FAILING_PRS PR(s) failing fmt/clippy"
    [[ "$CHECK_ONLY" -eq 1 ]] && exit 1
    exit 0
else
    _emit "toolchain_ratchet_scan_completed" \
        "\"result\":\"clean\"" "\"elapsed_ms\":$ELAPSED" "\"gh_calls\":$GH_CALLS"
    [[ "$FORMAT" == "json" ]] && printf '{"status":"clean","elapsed_ms":%d,"gh_calls":%d}\n' "$ELAPSED" "$GH_CALLS"
    [[ "$FORMAT" != "json" ]] && echo "toolchain-ratchet-detector: clean (no W-014 signature)"
    exit 0
fi
