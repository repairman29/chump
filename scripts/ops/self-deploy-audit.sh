#!/usr/bin/env bash
# scripts/ops/self-deploy-audit.sh — INFRA-3598
#
# WHY THIS EXISTS. INFRA-3593 was marked done but installed no actual deploy
# mechanism the board could verify — two merged fixes (INFRA-3595, INFRA-3596)
# sat DARK on helsinki with nobody able to tell, short of an operator SSHing
# in by hand. This is the PROOF tool: a single read-mostly command that
# answers "is the merge->deploy loop actually working right now?" with an
# ambient audit event any curator or board report can poll, instead of
# trusting that node-refresh-chump.sh + install-helsinki-atc.sh --auto ran.
#
# Three checks, every cycle:
#   1. Clone currency — is this node's mirror checkout within
#      CHUMP_SELF_DEPLOY_STALE_MINUTES of origin/main HEAD? (AC 1, AC 5 — a
#      merge must reach helsinki with no human pull, and a fetch that's
#      silently failing must show up as staleness here even if
#      node-refresh-chump.sh's own alarm gets missed.)
#   2. Unit drift — does every tracked chump-*.service/.timer file in
#      scripts/dispatch/ match what's actually live in
#      /etc/systemd/system? A mismatch means a merged unit change hasn't
#      been installed. (AC 1)
#   3. Organ health — is any chump-*.service currently ActiveState=failed?
#      (AC 3 — this is exactly how the board confirms the scorecard organ
#      recovered to green after its already-merged fix landed.)
#
# Emits exactly one kind=self_deploy_audit event per run (pass or fail) with
# the full detail the board needs to verify without re-deriving it (AC 7).
#
# Usage:
#   scripts/ops/self-deploy-audit.sh            # human-readable + ambient emit
#   scripts/ops/self-deploy-audit.sh --json      # machine-readable summary on stdout
#
# Test hooks (used by scripts/ci/test-self-deploy-audit.sh):
#   CHUMP_SELF_DEPLOY_REPO_ROOT      — repo root to audit (default: this script's repo)
#   CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN  — path to a stubbed `systemctl`
#   CHUMP_SELF_DEPLOY_UNIT_DIR       — live unit dir (default /etc/systemd/system)
#   CHUMP_SELF_DEPLOY_AMBIENT        — override ambient.jsonl path
#   CHUMP_SELF_DEPLOY_STALE_MINUTES  — clone-lag alarm threshold (default 30)
#
# Exit codes:
#   0  everything checked is current/healthy
#   1  at least one check failed (stale clone, unit drift, or a failed organ)
#   2  systemctl unavailable (dev laptop, not helsinki) — clone check still
#      runs; unit-drift + organ-health checks are skipped, not failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_SELF_DEPLOY_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_LOG="${CHUMP_SELF_DEPLOY_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
UNIT_DIR="${CHUMP_SELF_DEPLOY_UNIT_DIR:-/etc/systemd/system}"
SYSTEMCTL_BIN="${CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN:-systemctl}"
STALE_MINUTES="${CHUMP_SELF_DEPLOY_STALE_MINUTES:-30}"
JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

emit() {  # kind, extra-json (no leading/trailing comma)
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

FAIL=0
REASONS=()

# ── 1. Clone currency ────────────────────────────────────────────────────────
cd "$REPO_ROOT" 2>/dev/null || { echo "FATAL: cannot cd $REPO_ROOT" >&2; exit 1; }
git fetch origin main --quiet 2>/dev/null || echo "WARN: git fetch failed; using last-known origin/main" >&2
LOCAL_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
MAIN_SHA="$(git rev-parse --short=12 origin/main 2>/dev/null || echo "$LOCAL_SHA")"
LAG_COMMITS="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
LAG_MINUTES=0
if [[ "$LAG_COMMITS" -gt 0 ]]; then
    HEAD_EPOCH="$(git log -1 --format=%ct origin/main 2>/dev/null || echo 0)"
    NOW_EPOCH="$(date -u +%s)"
    LAG_MINUTES=$(( (NOW_EPOCH - HEAD_EPOCH) / 60 ))
    [[ "$LAG_MINUTES" -lt 0 ]] && LAG_MINUTES=0
fi
CLONE_CURRENT=1
if [[ "$LAG_COMMITS" -gt 0 && "$LAG_MINUTES" -gt "$STALE_MINUTES" ]]; then
    CLONE_CURRENT=0
    FAIL=1
    REASONS+=("clone_stale")
    echo "[self-deploy-audit] STALE: local=$LOCAL_SHA origin/main=$MAIN_SHA lag=${LAG_COMMITS}commits/${LAG_MINUTES}m (threshold ${STALE_MINUTES}m)"
else
    echo "[self-deploy-audit] clone current: local=$LOCAL_SHA origin/main=$MAIN_SHA lag=${LAG_COMMITS}commits/${LAG_MINUTES}m"
fi

DRIFTED_UNITS=()
FAILED_ORGANS=()
SYSTEMCTL_AVAILABLE=1
if ! command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1; then
    SYSTEMCTL_AVAILABLE=0
    echo "[self-deploy-audit] systemctl unavailable ($SYSTEMCTL_BIN not found) — skipping unit-drift + organ-health checks (expected off helsinki)"
fi

# ── 2. Unit drift ────────────────────────────────────────────────────────────
if [[ "$SYSTEMCTL_AVAILABLE" == "1" ]]; then
    shopt -s nullglob
    for src in "$REPO_ROOT"/scripts/dispatch/chump-*.service "$REPO_ROOT"/scripts/dispatch/chump-*.timer; do
        unit="$(basename "$src")"
        dest="$UNIT_DIR/$unit"
        if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
            DRIFTED_UNITS+=("$unit")
        fi
    done
    shopt -u nullglob
    if [[ "${#DRIFTED_UNITS[@]}" -gt 0 ]]; then
        FAIL=1
        REASONS+=("unit_drift")
        echo "[self-deploy-audit] DRIFTED units (repo != live): ${DRIFTED_UNITS[*]}"
    else
        echo "[self-deploy-audit] no unit drift — live units match tracked repo copies"
    fi

    # ── 3. Organ health ──────────────────────────────────────────────────────
    FAILED_RAW="$("$SYSTEMCTL_BIN" list-units --all --type=service --state=failed --plain --no-legend 'chump-*.service' 2>/dev/null | awk '{print $1}')"
    if [[ -n "$FAILED_RAW" ]]; then
        while IFS= read -r unit; do
            [[ -z "$unit" ]] && continue
            FAILED_ORGANS+=("$unit")
        done <<< "$FAILED_RAW"
    fi
    if [[ "${#FAILED_ORGANS[@]}" -gt 0 ]]; then
        FAIL=1
        REASONS+=("organ_failed")
        echo "[self-deploy-audit] FAILED organs: ${FAILED_ORGANS[*]}"
    else
        echo "[self-deploy-audit] no failed chump-* organs"
    fi
fi

# ── emit + report ────────────────────────────────────────────────────────────
json_arr() {  # join array items as a JSON string array
    local -n arr_ref="$1"
    local out="["
    local first=1
    for item in "${arr_ref[@]}"; do
        [[ "$first" == 1 ]] && first=0 || out+=","
        out+="\"$item\""
    done
    out+="]"
    printf '%s' "$out"
}

STATUS="pass"
[[ "$FAIL" == "1" ]] && STATUS="fail"
REASONS_JSON="$(json_arr REASONS)"
DRIFTED_JSON="$(json_arr DRIFTED_UNITS)"
FAILED_JSON="$(json_arr FAILED_ORGANS)"

# scanner-anchor: "kind":"self_deploy_audit"  (INFRA-3598; the single audit
# event the board polls to verify the merge->deploy loop is actually
# running, not just present on disk)
emit self_deploy_audit \
    "\"status\":\"$STATUS\",\"local_sha\":\"$LOCAL_SHA\",\"main_sha\":\"$MAIN_SHA\",\"lag_commits\":$LAG_COMMITS,\"lag_minutes\":$LAG_MINUTES,\"drifted_units\":$DRIFTED_JSON,\"failed_organs\":$FAILED_JSON,\"reasons\":$REASONS_JSON"

if [[ "$JSON" == "1" ]]; then
    printf '{"status":"%s","local_sha":"%s","main_sha":"%s","lag_commits":%s,"lag_minutes":%s,"drifted_units":%s,"failed_organs":%s,"reasons":%s}\n' \
        "$STATUS" "$LOCAL_SHA" "$MAIN_SHA" "$LAG_COMMITS" "$LAG_MINUTES" "$DRIFTED_JSON" "$FAILED_JSON" "$REASONS_JSON"
fi

echo "[self-deploy-audit] status=$STATUS reasons=${REASONS[*]:-none}"

if [[ "$FAIL" == "1" ]]; then
    exit 1
fi
[[ "$SYSTEMCTL_AVAILABLE" == "0" ]] && exit 2
exit 0
