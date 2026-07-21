#!/usr/bin/env bash
# ruleset-empty-watchdog.sh — META-146 (META-131 slice)
#
# Watches `main`'s required-status-checks (classic branch-protection AND
# any active ruleset) and pages the operator when the combined set has been
# EMPTY for more than 2 minutes — the INFRA-2201 class incident where main
# is silently unprotected because a manual ruleset edit dropped required
# checks and nobody restored them.
#
# Designed for launchd, run every 60s (see launchd/com.chump.ruleset-empty-watchdog.plist).
#
# State: .chump-locks/ruleset-empty-state.json
#   {"empty_since": null|"<ISO ts>", "prior_total": N, "paged_at": null|"<ISO ts>"}
#
# Emits (per docs/design/CI_VERIFIED_AGGREGATOR.md §5.2 / registered in
# docs/observability/EVENT_REGISTRY.yaml):
#   kind=ruleset_required_empty     — transition into empty (0 required checks)
#   kind=ruleset_required_restored  — transition out of empty (>0 required checks)
#
# Usage:
#   scripts/coord/ruleset-empty-watchdog.sh              # single tick
#   scripts/coord/ruleset-empty-watchdog.sh --check-only  # no emits/paging, exit 1 if empty
#   scripts/coord/ruleset-empty-watchdog.sh --dry-run     # print actions, don't emit/page
#
# Environment:
#   CHUMP_RULESET_EMPTY_ALERT_THRESHOLD_S  — page threshold (default 120 = AC #2)
#   CHUMP_RULESET_EMPTY_REPAGE_S           — re-page cadence while still empty (default 300)
#   CHUMP_AMBIENT_LOG                      — override ambient.jsonl path
#   CHUMP_LOCK_DIR                         — override .chump-locks path
#
# Bypass: CHUMP_SKIP_RULESET_EMPTY_WATCHDOG=1 short-circuits to exit 0.

set -uo pipefail

if [[ "${CHUMP_SKIP_RULESET_EMPTY_WATCHDOG:-0}" == "1" ]]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="$LOCK_DIR/ruleset-empty-state.json"
ALERT_THRESHOLD_S="${CHUMP_RULESET_EMPTY_ALERT_THRESHOLD_S:-120}"
REPAGE_S="${CHUMP_RULESET_EMPTY_REPAGE_S:-300}"

CHECK_ONLY=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '[ruleset-empty-watchdog] %s\n' "$*" >&2; }

_emit_ambient() {
    [[ "$DRY_RUN" -eq 1 ]] && { _log "[dry-run] emit: $1"; return 0; }
    mkdir -p "$LOCK_DIR"
    printf '%s\n' "$1" >> "$AMBIENT" 2>/dev/null || true
}

if ! command -v gh >/dev/null 2>&1; then
    _log "SKIP: gh CLI not in PATH"
    exit 0
fi

REPO="${CHUMP_REPO_NWO:-}"
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
fi
if [[ -z "$REPO" ]]; then
    _log "SKIP: could not resolve repo NWO (offline?)"
    exit 0
fi

# ── Combined required-check count: classic branch-protection + active rulesets ──
_total_required_checks() {
    python3 - "$REPO" << 'PYEOF'
import json, subprocess, sys

repo = sys.argv[1]

def gh_json(args):
    r = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None

total = 0

bp = gh_json([f"repos/{repo}/branches/main/protection"])
if bp:
    total += len(bp.get("required_status_checks", {}).get("checks", []))

rulesets = gh_json([f"repos/{repo}/rulesets"]) or []
for rs in rulesets:
    if rs.get("enforcement") != "active":
        continue
    rid = rs.get("id")
    if rid is None:
        continue
    detail = gh_json([f"repos/{repo}/rulesets/{rid}"])
    if not detail:
        continue
    for rule in detail.get("rules", []):
        if rule.get("type") == "required_status_checks":
            total += len(rule.get("parameters", {}).get("required_status_checks", []))

print(total)
PYEOF
}

TOTAL="$(_total_required_checks 2>/dev/null || echo -1)"
if [[ "$TOTAL" -lt 0 ]]; then
    _log "SKIP: could not determine required-check total (gh api error)"
    exit 0
fi

_log "combined required-check total: $TOTAL"

# ── Load state ────────────────────────────────────────────────────────────
mkdir -p "$LOCK_DIR"
EMPTY_SINCE=""
PRIOR_TOTAL="-1"
PAGED_AT=""
if [[ -f "$STATE_FILE" ]]; then
    EMPTY_SINCE="$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('empty_since') or '')" 2>/dev/null || echo "")"
    PRIOR_TOTAL="$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('prior_total', -1))" 2>/dev/null || echo -1)"
    PAGED_AT="$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('paged_at') or '')" 2>/dev/null || echo "")"
fi

NOW="$(_ts)"

_write_state() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    python3 - "$STATE_FILE" "$1" "$2" "$3" << 'PYEOF'
import json, sys
state_file, empty_since, prior_total, paged_at = sys.argv[1:5]
json.dump({
    "empty_since": empty_since or None,
    "prior_total": int(prior_total),
    "paged_at": paged_at or None,
}, open(state_file, "w"))
PYEOF
}

if [[ "$TOTAL" -eq 0 ]]; then
    if [[ -z "$EMPTY_SINCE" ]]; then
        # AC #1 transition: non-empty (or unknown) -> empty
        EMPTY_SINCE="$NOW"
        _log "TRANSITION: required checks went EMPTY at $EMPTY_SINCE"
        # scanner-anchor: "kind":"ruleset_required_empty"
        _emit_ambient "$(printf '{"ts":"%s","kind":"ruleset_required_empty","ruleset_id":"main","prior_check_count":%s}' \
            "$NOW" "$([[ "$PRIOR_TOTAL" -ge 0 ]] && echo "$PRIOR_TOTAL" || echo 0)")"
    fi

    OUTAGE_S="$(python3 -c "
from datetime import datetime, timezone
def p(s):
    return datetime.fromisoformat(s.replace('Z','+00:00'))
print(int((p('$NOW') - p('$EMPTY_SINCE')).total_seconds()))
" 2>/dev/null || echo 0)"

    _log "outage open for ${OUTAGE_S}s (alert threshold=${ALERT_THRESHOLD_S}s)"

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        _write_state "$EMPTY_SINCE" "$TOTAL" "$PAGED_AT"
        exit 1
    fi

    # AC #2: alert if empty for > threshold, re-page on a cadence while still open
    if [[ "$OUTAGE_S" -ge "$ALERT_THRESHOLD_S" ]]; then
        SHOULD_PAGE=1
        if [[ -n "$PAGED_AT" ]]; then
            SINCE_LAST_PAGE_S="$(python3 -c "
from datetime import datetime, timezone
def p(s):
    return datetime.fromisoformat(s.replace('Z','+00:00'))
print(int((p('$NOW') - p('$PAGED_AT')).total_seconds()))
" 2>/dev/null || echo "$REPAGE_S")"
            [[ "$SINCE_LAST_PAGE_S" -lt "$REPAGE_S" ]] && SHOULD_PAGE=0
        fi

        if [[ "$SHOULD_PAGE" -eq 1 ]]; then
            MSG="main required_status_checks EMPTY for ${OUTAGE_S}s (>${ALERT_THRESHOLD_S}s threshold) — repo is silently unprotected. Restore via scripts/ops/admin-merge-cycle.sh or gh api repos/${REPO}/rulesets/<id>."
            if [[ "$DRY_RUN" -eq 1 ]]; then
                _log "[dry-run] page: $MSG"
            elif [[ -x "$SCRIPT_DIR/broadcast.sh" ]]; then
                "$SCRIPT_DIR/broadcast.sh" --urgency CRIT WARN "$MSG" 2>/dev/null || _log "WARN: broadcast.sh page failed"
            else
                _log "WARN: broadcast.sh not found — cannot page; alert logged to ambient only"
            fi
            PAGED_AT="$NOW"
        fi
    fi

    _write_state "$EMPTY_SINCE" "$TOTAL" "$PAGED_AT"
    exit 0
fi

# TOTAL > 0
if [[ -n "$EMPTY_SINCE" ]]; then
    OUTAGE_S="$(python3 -c "
from datetime import datetime, timezone
def p(s):
    return datetime.fromisoformat(s.replace('Z','+00:00'))
print(int((p('$NOW') - p('$EMPTY_SINCE')).total_seconds()))
" 2>/dev/null || echo 0)"
    _log "TRANSITION: required checks RESTORED (count=$TOTAL) after ${OUTAGE_S}s outage"
    # scanner-anchor: "kind":"ruleset_required_restored"
    _emit_ambient "$(printf '{"ts":"%s","kind":"ruleset_required_restored","ruleset_id":"main","restored_check_count":%s,"outage_duration_s":%s}' \
        "$NOW" "$TOTAL" "$OUTAGE_S")"
fi

_write_state "" "$TOTAL" ""
exit 0
