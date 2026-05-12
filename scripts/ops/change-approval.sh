#!/usr/bin/env bash
# scripts/ops/change-approval.sh — INFRA-912: Change approval workflow and rollback capability
#
# Gates high-risk fleet changes behind an explicit approval token.
# Supported change types: scale-up, model-override, routing-yaml-edit
#
# Usage:
#   change-approval.sh gate   <CHANGE-ID>           # exit 0 if approved, 1 if not
#   change-approval.sh approve <CHANGE-ID> <rationale>  # create approval token
#   change-approval.sh rollback <CHANGE-ID>          # revert fleet-state.json snapshot
#   change-approval.sh list                          # list pending + approved changes
#
# Env overrides (for testing):
#   CHUMP_APPROVER          operator identity (default: $USER)
#   CHUMP_CHANGE_APPROVALS  override approval dir (default: .chump-locks/change-approvals)
#   CHUMP_AMBIENT_OVERRIDE  override ambient.jsonl path
#   CHUMP_REPO              override repo root

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_OVERRIDE:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
APPROVALS_DIR="${CHUMP_CHANGE_APPROVALS:-$REPO_ROOT/.chump-locks/change-approvals}"
STATE_FILE="$REPO_ROOT/.chump-locks/fleet-state.json"
SNAPSHOTS_DIR="$REPO_ROOT/.chump-locks/fleet-state-snapshots"

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[change-approval] %s\n' "$*" >&2; }

emit() {
    local kind="$1"; shift
    printf '{"ts":"%s","kind":"%s",%s}\n' "$(ts)" "$kind" "$*" \
        >> "$AMBIENT" 2>/dev/null || true
}

usage() {
    cat >&2 <<'EOF'
Usage:
  change-approval.sh gate    <CHANGE-ID>
  change-approval.sh approve <CHANGE-ID> <rationale>
  change-approval.sh rollback <CHANGE-ID>
  change-approval.sh list
EOF
    exit 2
}

cmd="${1:-}"
shift || true

case "$cmd" in

# ── gate: check approval token ────────────────────────────────────────────────
gate)
    change_id="${1:-}"
    [[ -z "$change_id" ]] && { log "gate requires CHANGE-ID"; usage; }
    token="$APPROVALS_DIR/${change_id}.json"
    if [[ -f "$token" ]]; then
        log "APPROVED: $change_id (token: $token)"
        exit 0
    fi
    log "NOT APPROVED: $change_id — run: change-approval.sh approve $change_id '<rationale>'"
    exit 1
    ;;

# ── approve: create approval token ───────────────────────────────────────────
approve)
    change_id="${1:-}"
    rationale="${2:-}"
    [[ -z "$change_id" || -z "$rationale" ]] && { log "approve requires CHANGE-ID and rationale"; usage; }

    mkdir -p "$APPROVALS_DIR" "$SNAPSHOTS_DIR"

    # Save snapshot of current fleet-state.json before the change.
    if [[ -f "$STATE_FILE" ]]; then
        cp "$STATE_FILE" "$SNAPSHOTS_DIR/${change_id}.json"
        log "Saved fleet-state snapshot → $SNAPSHOTS_DIR/${change_id}.json"
    fi

    approver="${CHUMP_APPROVER:-${USER:-unknown}}"
    token="$APPROVALS_DIR/${change_id}.json"
    printf '{"ts":"%s","change_id":"%s","approver":"%s","rationale":"%s"}\n' \
        "$(ts)" "$change_id" "$approver" "$rationale" > "$token"

    log "Approval token created: $token"
    emit "change_approved" \
        "\"change_id\":\"$change_id\",\"approver\":\"$approver\",\"rationale\":\"$(printf '%s' "$rationale" | sed 's/"/\\"/g')\""
    echo "approved: $change_id"
    ;;

# ── rollback: restore pre-change fleet-state.json snapshot ───────────────────
rollback)
    change_id="${1:-}"
    [[ -z "$change_id" ]] && { log "rollback requires CHANGE-ID"; usage; }

    snapshot="$SNAPSHOTS_DIR/${change_id}.json"
    if [[ ! -f "$snapshot" ]]; then
        log "No snapshot found for $change_id (looked in $snapshot)"
        exit 1
    fi

    mkdir -p "$(dirname "$STATE_FILE")"
    cp "$snapshot" "$STATE_FILE"
    log "Rolled back fleet-state.json to snapshot for $change_id"

    emit "change_rolled_back" \
        "\"change_id\":\"$change_id\",\"snapshot\":\"$snapshot\""
    echo "rolled-back: $change_id"
    ;;

# ── list: show pending + approved changes ────────────────────────────────────
list)
    echo "=== Approved changes ==="
    if [[ -d "$APPROVALS_DIR" ]] && ls "$APPROVALS_DIR"/*.json >/dev/null 2>&1; then
        for f in "$APPROVALS_DIR"/*.json; do
            id="$(basename "$f" .json)"
            ts_val="$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('ts','?'))" 2>/dev/null || echo '?')"
            approver="$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('approver','?'))" 2>/dev/null || echo '?')"
            echo "  $id  (ts=$ts_val approver=$approver)"
        done
    else
        echo "  (none)"
    fi
    echo
    echo "=== Snapshots available for rollback ==="
    if [[ -d "$SNAPSHOTS_DIR" ]] && ls "$SNAPSHOTS_DIR"/*.json >/dev/null 2>&1; then
        for f in "$SNAPSHOTS_DIR"/*.json; do
            id="$(basename "$f" .json)"
            echo "  $id"
        done
    else
        echo "  (none)"
    fi
    ;;

*)
    usage
    ;;
esac
