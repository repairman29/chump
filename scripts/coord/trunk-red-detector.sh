#!/usr/bin/env bash
# trunk-red-detector.sh — META-177 Lane C
#
# Polls the latest CI run on main. When it detects a failure it emits a
# kind=trunk_red_detected ambient event and broadcasts a WARN so the operator
# gets surfaced at the next session-start (within 5 min of the event, not 3h+
# later as happened on 2026-05-30).
#
# Hysteresis: emits at most once per 60-min window (configurable via
# CHUMP_TRUNK_RED_EMIT_INTERVAL_S). Prevents spam during a multi-hour wedge.
#
# One-shot mode: exits 0 after each poll. The launchd plist invokes it every
# 5 min (StartInterval: 300) so no internal loop is needed.
#
# Workflow polled: ci.yml on branch main (GitHub Actions).
# Repo: inferred from `git remote get-url origin` (github.com/<owner>/<repo>).
#
# State file: .chump-locks/trunk-red-detector-state.json
# Fields: last_emit_ts (ISO-8601), last_failed_sha, red_since_ts
#
# Env overrides:
#   CHUMP_TRUNK_RED_EMIT_INTERVAL_S   (default 3600 = 60 min hysteresis)
#   CHUMP_TRUNK_RED_WORKFLOW          (default ci.yml)
#   CHUMP_TRUNK_RED_GH_FIXTURE        (path to fixture JSON; overrides gh call in tests)
#   CHUMP_TRUNK_RED_AMBIENT_FILE      (override ambient.jsonl path; used in tests)
#   CHUMP_TRUNK_RED_STATE_FILE        (override state file path; used in tests)
#   CHUMP_TRUNK_RED_BROADCAST_SCRIPT  (override broadcast.sh path; used in tests)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

# Resolve main repo root (works in linked worktrees too).
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"

# ── Configuration ─────────────────────────────────────────────────────────────
EMIT_INTERVAL_S="${CHUMP_TRUNK_RED_EMIT_INTERVAL_S:-3600}"
WORKFLOW="${CHUMP_TRUNK_RED_WORKFLOW:-ci.yml}"
AMBIENT="${CHUMP_TRUNK_RED_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="${CHUMP_TRUNK_RED_STATE_FILE:-$LOCK_DIR/trunk-red-detector-state.json}"
BROADCAST_SCRIPT="${CHUMP_TRUNK_RED_BROADCAST_SCRIPT:-$REPO_ROOT/scripts/coord/broadcast.sh}"

mkdir -p "$LOCK_DIR"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Fetch latest run on main ──────────────────────────────────────────────────
if [[ -n "${CHUMP_TRUNK_RED_GH_FIXTURE:-}" ]]; then
    # Test fixture mode: read from a file instead of calling gh.
    run_json="$(cat "$CHUMP_TRUNK_RED_GH_FIXTURE")"
else
    set +e
    run_json="$(gh run list \
        --branch main \
        --workflow "$WORKFLOW" \
        --limit 1 \
        --json conclusion,databaseId,createdAt,headSha \
        --jq '.[0]' 2>/dev/null)"
    gh_exit=$?
    set -e
    if [[ $gh_exit -ne 0 || -z "$run_json" ]]; then
        printf '[trunk-red-detector] WARN: gh run list failed or returned empty; skipping poll\n' >&2
        exit 0
    fi
fi

# Parse fields from JSON.
conclusion="$(printf '%s' "$run_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('conclusion',''))" 2>/dev/null || echo "")"
run_id="$(printf '%s' "$run_json"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('databaseId',''))" 2>/dev/null || echo "")"
created_at="$(printf '%s' "$run_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('createdAt',''))" 2>/dev/null || echo "")"
head_sha="$(printf '%s' "$run_json"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('headSha',''))" 2>/dev/null || echo "")"
short_sha="${head_sha:0:8}"

# ── Load existing state ───────────────────────────────────────────────────────
last_emit_ts=""
last_failed_sha=""
red_since_ts=""

if [[ -f "$STATE_FILE" ]]; then
    last_emit_ts="$(python3 -c \
        "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('last_emit_ts',''))" 2>/dev/null || echo "")"
    last_failed_sha="$(python3 -c \
        "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('last_failed_sha',''))" 2>/dev/null || echo "")"
    red_since_ts="$(python3 -c \
        "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('red_since_ts',''))" 2>/dev/null || echo "")"
fi

# ── Helper: seconds since an ISO-8601 UTC timestamp ──────────────────────────
seconds_since() {
    local iso_ts="$1"
    [[ -z "$iso_ts" ]] && { echo 99999999; return; }
    local epoch
    if [[ "$(uname -s)" == "Darwin" ]]; then
        epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso_ts" '+%s' 2>/dev/null || echo "")"
    else
        epoch="$(date -u -d "$iso_ts" '+%s' 2>/dev/null || echo "")"
    fi
    [[ -z "$epoch" ]] && { echo 99999999; return; }
    echo "$(( $(date -u +%s) - epoch ))"
}

# ── Helper: emit ambient event ────────────────────────────────────────────────
emit_ambient() {
    local json="$1"
    mkdir -p "$(dirname "$AMBIENT")"
    printf '%s\n' "$json" >> "$AMBIENT"
}

# ── Infer GitHub repo URL from remote ────────────────────────────────────────
repo_url=""
remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")"
if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
    repo_url="https://github.com/${owner_repo}"
fi

# ── Failure path ──────────────────────────────────────────────────────────────
if [[ "$conclusion" == "failure" ]]; then
    # Hysteresis: skip if we emitted within the window for this same SHA.
    secs_since_emit="$(seconds_since "$last_emit_ts")"
    if [[ -n "$last_failed_sha" && "$last_failed_sha" == "$head_sha" \
          && "$secs_since_emit" -lt "$EMIT_INTERVAL_S" ]]; then
        printf '[trunk-red-detector] hysteresis: already emitted for %s %ds ago (threshold %ds); skipping\n' \
            "$short_sha" "$secs_since_emit" "$EMIT_INTERVAL_S"
        exit 0
    fi

    # Record red_since if this is a new red event.
    if [[ -z "$red_since_ts" || "$last_failed_sha" != "$head_sha" ]]; then
        red_since_ts="$created_at"
    fi

    run_url="${repo_url:+${repo_url}/actions/runs/${run_id}}"

    # Emit ambient event.
    ambient_json="$(python3 -c "
import json, sys
print(json.dumps({
    'ts':            sys.argv[1],
    'kind':          'trunk_red_detected',
    'head_sha':      sys.argv[2],
    'short_sha':     sys.argv[3],
    'failed_run_id': sys.argv[4],
    'since_ts':      sys.argv[5],
    'run_url':       sys.argv[6],
}))
" "$TS" "$head_sha" "$short_sha" "$run_id" "$red_since_ts" "$run_url")"
    emit_ambient "$ambient_json"

    # Broadcast WARN to surface in next session-start digest.
    if [[ -x "$BROADCAST_SCRIPT" ]]; then
        "$BROADCAST_SCRIPT" --urgency WARN WARN \
            "TRUNK-RED: main HEAD run #${run_id} failed at ${created_at}. SHA=${short_sha}. See ${run_url}" \
            2>/dev/null || true
    fi

    # Update state.
    python3 -c "
import json, sys
state = {
    'last_emit_ts':    sys.argv[1],
    'last_failed_sha': sys.argv[2],
    'red_since_ts':    sys.argv[3],
    'failed_run_id':   sys.argv[4],
}
open(sys.argv[5], 'w').write(json.dumps(state, indent=2) + '\n')
" "$TS" "$head_sha" "$red_since_ts" "$run_id" "$STATE_FILE"

    printf '[trunk-red-detector] WARN emitted: trunk RED at %s (run #%s, sha=%s)\n' \
        "$created_at" "$run_id" "$short_sha"

# ── Success / green path ──────────────────────────────────────────────────────
elif [[ "$conclusion" == "success" ]]; then
    if [[ -f "$STATE_FILE" && -n "$red_since_ts" ]]; then
        # Compute how long trunk was red.
        red_since_epoch=""
        if [[ "$(uname -s)" == "Darwin" ]]; then
            red_since_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$red_since_ts" '+%s' 2>/dev/null || echo "")"
        else
            red_since_epoch="$(date -u -d "$red_since_ts" '+%s' 2>/dev/null || echo "")"
        fi
        now_epoch="$(date -u +%s)"
        duration_s=0
        [[ -n "$red_since_epoch" ]] && duration_s="$(( now_epoch - red_since_epoch ))"
        duration_min="$(( duration_s / 60 ))"

        # Emit ambient resolved event.
        ambient_json="$(python3 -c "
import json, sys
print(json.dumps({
    'ts':              sys.argv[1],
    'kind':            'trunk_red_resolved',
    'head_sha':        sys.argv[2],
    'red_since_ts':    sys.argv[3],
    'duration_min':    int(sys.argv[4]),
}))
" "$TS" "$head_sha" "$red_since_ts" "$duration_min")"
        emit_ambient "$ambient_json"

        # Broadcast green (INFO urgency — informational, not wake-up-level).
        if [[ -x "$BROADCAST_SCRIPT" ]]; then
            "$BROADCAST_SCRIPT" WARN \
                "TRUNK-GREEN: main green again after ${duration_min}m (was red since ${red_since_ts})" \
                2>/dev/null || true
        fi

        printf '[trunk-red-detector] trunk GREEN after %dm\n' "$duration_min"
    else
        printf '[trunk-red-detector] trunk green; no prior trunk-red state\n'
    fi

    # Clear state file.
    rm -f "$STATE_FILE"

else
    # Conclusion is null/pending/cancelled/skipped — no action.
    printf '[trunk-red-detector] conclusion=%s; no action\n' "${conclusion:-<empty>}"
    exit 0
fi

exit 0
