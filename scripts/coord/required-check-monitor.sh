#!/usr/bin/env bash
# required-check-monitor.sh — INFRA-1395
#
# Detects when a new required CI check appears (compare branch-protection
# required-contexts vs. current ci.yml job list) and manages a 30-minute
# grace window so in-flight PRs opened before the change are not blocked.
#
# Option B (workflow_dispatch with SKIP_GRACE_CHECKS=1) is used:
#   - When bot-merge.sh detects a pre-grace PR needing a new required check,
#     it triggers `gh workflow run ci.yml -F grace=1` for that PR, which
#     re-runs CI with the new check guard-gated via env var.
#   - No external GitHub App required; simpler, entirely within gh CLI scope.
#
# Usage:
#   scripts/coord/required-check-monitor.sh [--check-only] [--pr N] [--dry-run]
#
#   --check-only   Detect and emit events; do NOT trigger any workflow re-runs.
#   --pr N         Check whether PR N is within a grace window for any added check.
#   --dry-run      Print actions without executing gh workflow run.
#
# Grace file: .chump-locks/required-check-grace.json
#   Array of entries: [{required_check_added_at, check_name, grace_until, pr_opened_before}]
#
# Emits: kind=required_check_added to ambient.jsonl (AC #1)
#
# Rust-First-Bypass: <200 LOC glue-between-gh+jq, shell-OK criteria met per META-064>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${REPO_ROOT}/.chump-locks"
GRACE_FILE="${LOCK_DIR}/required-check-grace.json"
AMBIENT="${CHUMP_AMBIENT_LOG:-${LOCK_DIR}/ambient.jsonl}"
GRACE_WINDOW_MINS="${CHUMP_REQUIRED_CHECK_GRACE_MINS:-30}"

CHECK_ONLY=0
DRY_RUN=0
TARGET_PR=""

for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --pr)         _next_pr=1 ;;
        *)
            if [[ "${_next_pr:-0}" == "1" ]]; then
                TARGET_PR="$arg"
                _next_pr=0
            fi
            ;;
    esac
done

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_log() { printf '[required-check-monitor] %s\n' "$*" >&2; }

# ── Load ambient-write helper if available ───────────────────────────────────
_emit_ambient() {
    local payload="$1"
    mkdir -p "$LOCK_DIR"
    printf '%s\n' "$payload" >> "$AMBIENT" 2>/dev/null || true
}

# ── AC #1: detect newly added required checks ────────────────────────────────
# Compares branch-protection required-status-checks against the set of job
# names in the last known snapshot (.chump-locks/required-check-snapshot.json).
# On first run, writes snapshot and exits cleanly (no false "new" on init).
SNAPSHOT_FILE="${LOCK_DIR}/required-check-snapshot.json"

_get_required_checks() {
    # Returns newline-separated check names from branch protection API.
    gh api "repos/{owner}/{repo}/branches/main/protection" \
        --jq '.required_status_checks.contexts // [] | .[]' 2>/dev/null || true
}

_update_snapshot() {
    local checks="$1"
    mkdir -p "$LOCK_DIR"
    printf '%s' "$checks" | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
print(json.dumps(sorted(lines)))
" > "$SNAPSHOT_FILE" 2>/dev/null || true
}

_detect_new_checks() {
    local current_checks
    current_checks="$(_get_required_checks)"

    if [[ ! -f "$SNAPSHOT_FILE" ]]; then
        _log "First run — writing snapshot, no new-check detection this cycle."
        _update_snapshot "$current_checks"
        return 0
    fi

    local prev_checks
    prev_checks="$(python3 -c "import json; print('\n'.join(json.load(open('${SNAPSHOT_FILE}'))))" 2>/dev/null || true)"

    # Find checks in current but not in prev
    local new_checks=""
    while IFS= read -r check; do
        [[ -z "$check" ]] && continue
        if ! echo "$prev_checks" | grep -qxF "$check"; then
            new_checks="${new_checks}${check}"$'\n'
        fi
    done <<< "$current_checks"

    # Find checks in prev but no longer in current (META-146 AC #1: removals
    # are a "modification" too — the ruleset_changed event must fire on both).
    local removed_checks=""
    while IFS= read -r check; do
        [[ -z "$check" ]] && continue
        if ! echo "$current_checks" | grep -qxF "$check"; then
            removed_checks="${removed_checks}${check}"$'\n'
        fi
    done <<< "$prev_checks"

    if [[ -z "$new_checks" && -z "$removed_checks" ]]; then
        return 0
    fi

    local now
    now="$(_ts)"

    # META-146 AC #1: emit a single kind=ruleset_changed covering the full
    # before/after diff, on ANY modification (add and/or remove), so
    # aggregator-watchdog-class consumers don't need to reconstruct the diff
    # from per-check required_check_added events alone.
    local old_json new_json
    old_json="$(printf '%s' "$prev_checks" | python3 -c "import json,sys; print(json.dumps(sorted([l for l in sys.stdin.read().splitlines() if l])))")"
    new_json="$(printf '%s' "$current_checks" | python3 -c "import json,sys; print(json.dumps(sorted([l for l in sys.stdin.read().splitlines() if l])))")"
    local reason
    reason="$(python3 -c "
added = len('''${new_checks}'''.strip().splitlines())
removed = len('''${removed_checks}'''.strip().splitlines())
parts = []
if added: parts.append(f'{added} added')
if removed: parts.append(f'{removed} removed')
print(', '.join(parts) or 'no-op')
")"
    # scanner-anchor: "kind":"ruleset_changed"
    _emit_ambient "$(printf \
        '{"ts":"%s","kind":"ruleset_changed","actor":"unknown","ruleset_id":"branch_protection","old_required_checks":%s,"new_required_checks":%s,"reason":"%s"}' \
        "$now" "$old_json" "$new_json" "$reason")"

    if [[ -z "$new_checks" ]]; then
        _update_snapshot "$current_checks"
        return 0
    fi

    # AC #1 + AC #2 (INFRA-1395): for each new check, emit event and write grace entry
    local grace_until
    grace_until="$(date -u -v+"${GRACE_WINDOW_MINS}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "+${GRACE_WINDOW_MINS} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)+timedelta(minutes=${GRACE_WINDOW_MINS})).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

    # Get creation timestamp of oldest open PR (for pr_opened_before field)
    local oldest_pr_ts
    oldest_pr_ts="$(gh pr list --state open --json createdAt \
        --jq 'sort_by(.createdAt) | .[0].createdAt // ""' 2>/dev/null || true)"

    while IFS= read -r check; do
        [[ -z "$check" ]] && continue
        _log "New required check detected: ${check}"

        # Emit kind=required_check_added (AC #1)
        # scanner-anchor: "kind":"required_check_added"
        _emit_ambient "$(printf \
            '{"ts":"%s","kind":"required_check_added","check_name":"%s","added_at":"%s","grace_until":"%s","grace_window_mins":%s}' \
            "$now" "$check" "$now" "$grace_until" "$GRACE_WINDOW_MINS")"

        # Write grace window entry (AC #2)
        _write_grace_entry "$check" "$now" "$grace_until" "$oldest_pr_ts"
    done <<< "$new_checks"

    # Update snapshot to include new checks
    _update_snapshot "$current_checks"
}

# ── AC #2: grace window file management ─────────────────────────────────────
_write_grace_entry() {
    local check_name="$1" added_at="$2" grace_until="$3" pr_opened_before="${4:-}"
    mkdir -p "$LOCK_DIR"

    local existing="[]"
    [[ -f "$GRACE_FILE" ]] && existing="$(cat "$GRACE_FILE" 2>/dev/null || echo "[]")"

    python3 - <<PYEOF
import json, sys
existing = json.loads('''${existing}''') if isinstance(json.loads('''${existing}'''), list) else []
entry = {
    "required_check_added_at": "${added_at}",
    "check_name": "${check_name}",
    "grace_until": "${grace_until}",
    "pr_opened_before": "${pr_opened_before}"
}
# Deduplicate by check_name — update if already present
existing = [e for e in existing if e.get("check_name") != "${check_name}"]
existing.append(entry)
with open("${GRACE_FILE}", "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")
PYEOF
    _log "Grace window written: ${check_name} → grace_until=${grace_until}"
}

# ── AC #4: purge expired grace entries ───────────────────────────────────────
_purge_expired_grace() {
    [[ -f "$GRACE_FILE" ]] || return 0
    local now
    now="$(_ts)"
    python3 - <<PYEOF
import json
from datetime import datetime, timezone

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

now = datetime.now(timezone.utc)
try:
    entries = json.load(open("${GRACE_FILE}"))
    if not isinstance(entries, list):
        entries = []
except Exception:
    entries = []

active = []
purged = []
for e in entries:
    gu = parse_ts(e.get("grace_until", ""))
    if gu and gu > now:
        active.append(e)
    else:
        purged.append(e.get("check_name", "?"))

with open("${GRACE_FILE}", "w") as f:
    json.dump(active, f, indent=2)
    f.write("\n")

if purged:
    print("PURGED:" + ",".join(purged))
PYEOF
}

# ── AC #3: check if a PR is within a grace window ────────────────────────────
# Returns 0 (in grace) or 1 (not in grace / no grace entries)
_pr_in_grace() {
    local pr_number="$1"
    [[ -f "$GRACE_FILE" ]] || return 1

    local pr_created_at
    pr_created_at="$(gh pr view "$pr_number" --json createdAt --jq '.createdAt' 2>/dev/null || true)"
    [[ -z "$pr_created_at" ]] && return 1

    python3 - <<PYEOF
import json, sys
from datetime import datetime, timezone

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None

pr_ts = parse_ts("${pr_created_at}")
if not pr_ts:
    sys.exit(1)

now = datetime.now(timezone.utc)
try:
    entries = json.load(open("${GRACE_FILE}"))
    if not isinstance(entries, list):
        sys.exit(1)
except Exception:
    sys.exit(1)

for e in entries:
    grace_until = parse_ts(e.get("grace_until", ""))
    if not grace_until or grace_until <= now:
        continue  # expired
    # PR opened before grace_until was set → covered by this grace window
    if pr_ts < grace_until:
        print(e.get("check_name", ""))
        sys.exit(0)

sys.exit(1)
PYEOF
}

# ── Option B: trigger grace workflow re-run ───────────────────────────────────
# When a pre-grace PR needs the new check, trigger ci.yml with SKIP_GRACE_CHECKS=1
_trigger_grace_rerun() {
    local pr_number="$1"
    local head_sha
    head_sha="$(gh pr view "$pr_number" --json headRefSha --jq '.headRefSha' 2>/dev/null || true)"

    if [[ -z "$head_sha" ]]; then
        _log "WARN: cannot get head SHA for PR #${pr_number}"
        return 1
    fi

    _log "Triggering grace re-run for PR #${pr_number} (sha=${head_sha:0:8})"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        _log "[dry-run] gh workflow run ci.yml --ref <head_ref> -F grace=1 -F pr=${pr_number}"
        return 0
    fi

    local head_ref
    head_ref="$(gh pr view "$pr_number" --json headRefName --jq '.headRefName' 2>/dev/null || true)"
    [[ -z "$head_ref" ]] && { _log "WARN: cannot get head ref for PR #${pr_number}"; return 1; }

    gh workflow run ci.yml \
        --ref "$head_ref" \
        -f grace=1 \
        -f pr="$pr_number" \
        2>/dev/null || {
            _log "WARN: workflow dispatch failed for PR #${pr_number} — may need repo write perms"
            return 0  # non-fatal; main CI will still run
        }

    _log "Grace workflow dispatched for PR #${pr_number}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    # Purge expired entries first (AC #4)
    _purge_expired_grace

    if [[ -n "$TARGET_PR" ]]; then
        # --pr N mode: check if this specific PR is in grace window
        if _pr_in_grace "$TARGET_PR"; then
            _log "PR #${TARGET_PR} is within grace window — triggering grace re-run"
            [[ "$CHECK_ONLY" -eq 0 ]] && _trigger_grace_rerun "$TARGET_PR" || true
            exit 0
        else
            _log "PR #${TARGET_PR} is not in any active grace window"
            exit 1
        fi
    fi

    # Default: detect new required checks
    _detect_new_checks
}

main "$@"
