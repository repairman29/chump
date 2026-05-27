#!/usr/bin/env bash
# orphan-worktree-watchdog.sh — RESILIENT-026
#
# Detects abandoned /tmp/chump-* worktrees: those that have uncommitted or
# unpushed work but whose owning process is no longer running, have been idle
# >15 min, and haven't received a recent push.
#
# In autopilot, no one watches sub-agents crash mid-task. This daemon fires
# every 5 min via launchd and emits kind=orphan_worktree_detected to
# ambient.jsonl so the operator (or a downstream watchdog) can act.
#
# Detection criteria — ALL four must hold to emit:
#   1. Uncommitted changes OR unpushed commits exist in the worktree
#   2. No live process with the claim session_id in args/env
#   3. Worktree filesystem idle >15 min (last mtime)
#   4. No recent push: upstream sha absent or differs from local HEAD
#
# Usage:
#   scripts/coord/orphan-worktree-watchdog.sh               # scan and emit
#   scripts/coord/orphan-worktree-watchdog.sh --dry-run     # print only
#   scripts/coord/orphan-worktree-watchdog.sh --worktree-scan-dir /tmp  # override scan dir
#
# Emits: kind=orphan_worktree_detected
# Fields: ts, kind, worktree_path, branch, last_commit_sha, uncommitted_line_count,
#         age_minutes, claim_gap_id
#
# Environment:
#   CHUMP_ORPHAN_WATCHDOG_DISABLED=1   — skip entirely (bypass)
#   CHUMP_ORPHAN_IDLE_MIN              — idle threshold in minutes (default 15)
#   CHUMP_LOCK_DIR                     — override .chump-locks path
#   CHUMP_AMBIENT_LOG                  — override ambient.jsonl path
#   CHUMP_ORPHAN_SCAN_DIR              — override /tmp scan root
#
# Performance: relies on local .git data only (no git fetch), parallel per-worktree
# checks via background subshells. Target: <2s for 20 worktrees.
#
# Install:
#   plutil -lint ~/Library/LaunchAgents/ai.chump.orphan-worktree-watchdog.plist
#   launchctl load ~/Library/LaunchAgents/ai.chump.orphan-worktree-watchdog.plist
# scanner-anchor: "kind":"orphan_worktree_detected"

set -uo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# CHUMP_REPO_ROOT env override for tests; otherwise resolve from script location.
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
    || git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel 2>/dev/null \
    || echo "/Users/jeffadkins/Projects/Chump")}"

LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SCAN_DIR="${CHUMP_ORPHAN_SCAN_DIR:-/tmp}"
IDLE_MIN="${CHUMP_ORPHAN_IDLE_MIN:-15}"
DRY_RUN=0

# ── Bypass ───────────────────────────────────────────────────────────────────
if [[ "${CHUMP_ORPHAN_WATCHDOG_DISABLED:-0}" == "1" ]]; then
    echo "[orphan-worktree-watchdog] CHUMP_ORPHAN_WATCHDOG_DISABLED=1 — skipping" >&2
    exit 0
fi

# ── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --worktree-scan-dir) SCAN_DIR="$2"; shift ;;
        --idle-min) IDLE_MIN="$2"; shift ;;
        --lock-dir) LOCK_DIR="$2"; AMBIENT_LOG="$LOCK_DIR/ambient.jsonl"; shift ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[orphan-worktree-watchdog] unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOCK_DIR"

# Normalize SCAN_DIR to canonical real path after args (handles /tmp → /private/tmp on macOS)
SCAN_DIR="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" \
    "$SCAN_DIR" 2>/dev/null || echo "$SCAN_DIR")"

NOW_EPOCH=$(date +%s)
IDLE_SEC=$((IDLE_MIN * 60))
DETECTED=0

# ── Emit helper ──────────────────────────────────────────────────────────────

_emit() {
    local worktree_path="$1" branch="$2" last_sha="$3" uncommitted_lines="$4" \
          age_minutes="$5" gap_id="$6"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local gap_field
    if [[ -n "$gap_id" && "$gap_id" != "null" ]]; then
        gap_field="\"$gap_id\""
    else
        gap_field="null"
    fi
    local line
    line="$(printf '{"ts":"%s","kind":"orphan_worktree_detected","worktree_path":"%s","branch":"%s","last_commit_sha":"%s","uncommitted_line_count":%d,"age_minutes":%d,"claim_gap_id":%s}' \
        "$ts" "$worktree_path" "$branch" "$last_sha" \
        "$uncommitted_lines" "$age_minutes" "$gap_field")"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[orphan-worktree-watchdog] DRY-RUN detect: $line"
    else
        echo "$line" >> "$AMBIENT_LOG"
        echo "[orphan-worktree-watchdog] DETECT orphan: path=$worktree_path branch=$branch gap=${gap_id:-null} age=${age_minutes}min uncommitted=${uncommitted_lines}"
    fi
    DETECTED=$((DETECTED + 1))
}

# ── Session/gap lookup helpers (pure python3, no jq dependency) ──────────────

# Prints session_id from the best-matching claim file for a given worktree,
# or empty string if none found.
_get_session_id() {
    local wt="$1" branch="$2"
    # Strategy 1: claim in main LOCK_DIR whose purpose contains branch name
    python3 - "$LOCK_DIR" "$wt" "$branch" 2>/dev/null <<'PYEOF'
import json, os, sys, glob
lock_dir, wt, branch = sys.argv[1], sys.argv[2], sys.argv[3]
for f in glob.glob(os.path.join(lock_dir, "claim-*.json")):
    try:
        d = json.load(open(f))
        purpose = d.get("purpose", "")
        # Match if wt path or branch appears in purpose
        if wt in purpose or (branch and branch in purpose):
            sid = d.get("session_id", "")
            if sid:
                print(sid)
                sys.exit(0)
    except Exception:
        pass
# Strategy 2: claim in worktree's own .chump-locks/
for f in glob.glob(os.path.join(wt, ".chump-locks", "claim-*.json")):
    try:
        d = json.load(open(f))
        sid = d.get("session_id", "")
        if sid:
            print(sid)
            sys.exit(0)
    except Exception:
        pass
print("")
PYEOF
}

# Prints gap_id from best matching claim file, or "null".
_get_gap_id() {
    local wt="$1" branch="$2"
    python3 - "$LOCK_DIR" "$wt" "$branch" 2>/dev/null <<'PYEOF'
import json, os, sys, glob, re
lock_dir, wt, branch = sys.argv[1], sys.argv[2], sys.argv[3]
for f in glob.glob(os.path.join(lock_dir, "claim-*.json")):
    try:
        d = json.load(open(f))
        # gap_id field is canonical
        gid = d.get("gap_id", "")
        if gid:
            # Confirm this claim file belongs to this worktree
            purpose = d.get("purpose", "")
            m = re.search(r'([A-Z]+-\d+)', gid)
            slug = m.group(1).lower().replace("-", "") if m else ""
            if (wt in purpose or (branch and slug and slug in branch.lower())):
                print(gid)
                sys.exit(0)
        # Fallback: parse purpose for gap ID
        purpose = d.get("purpose", "")
        m = re.search(r'gap:([A-Z]+-\d+)', purpose)
        if m:
            gid = m.group(1)
            slug = gid.lower().replace("-", "")
            if wt in purpose or (branch and slug in branch.lower()):
                print(gid)
                sys.exit(0)
    except Exception:
        pass
# Strategy 2: claim in worktree's own .chump-locks/
for f in glob.glob(os.path.join(wt, ".chump-locks", "claim-*.json")):
    try:
        d = json.load(open(f))
        gid = d.get("gap_id", "")
        if gid:
            print(gid)
            sys.exit(0)
        purpose = d.get("purpose", "")
        m = re.search(r'gap:([A-Z]+-\d+)', purpose)
        if m:
            print(m.group(1))
            sys.exit(0)
    except Exception:
        pass
print("null")
PYEOF
}

# ── Per-worktree check (runs in a subshell for parallelism) ──────────────────
# Writes result to a temp file: SKIP:<reason> or DETECT:<fields...>
_check_worktree() {
    local wt="$1" result_file="$2"

    # Guard: worktree must exist on disk
    [[ -d "$wt" ]] || { echo "SKIP:not_on_disk" > "$result_file"; return; }

    # 1a. Uncommitted changes count
    local uncommitted_lines
    uncommitted_lines=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    uncommitted_lines="${uncommitted_lines:-0}"

    # 1b. Unpushed commits check (no network — local .git only)
    # Only flag unpushed when a tracking upstream exists and HEAD is ahead of it.
    # No upstream → branch was never pushed, but we can't distinguish "fresh clone
    # with no remote configured" from "work pending push" without a network call.
    # To avoid false positives on clean worktrees without remotes, require upstream.
    local has_unpushed=0
    local upstream
    upstream=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    if [[ -n "$upstream" ]]; then
        local unpushed_count
        # shellcheck disable=SC1083
        unpushed_count=$(git -C "$wt" log '@{u}..' --oneline 2>/dev/null | wc -l | tr -d ' ')
        [[ "${unpushed_count:-0}" -gt 0 ]] && has_unpushed=1
    fi

    # Skip if clean (no uncommitted + no unpushed)
    if [[ "$uncommitted_lines" -eq 0 && "$has_unpushed" -eq 0 ]]; then
        echo "SKIP:clean" > "$result_file"
        return
    fi

    # 2. Get branch name and last commit sha
    local branch last_sha
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    last_sha=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # 3. Get claim session_id (for live-process check)
    local session_id
    session_id=$(_get_session_id "$wt" "$branch")

    # 4. Live process check — skip if session is still running
    if [[ -n "$session_id" ]]; then
        if pgrep -af "$session_id" 2>/dev/null | grep -v "pgrep" | grep -q "."; then
            echo "SKIP:live_process" > "$result_file"
            return
        fi
    fi

    # 5. Idle time check — skip if modified within IDLE_SEC
    local mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        mtime=$(stat -f %m "$wt" 2>/dev/null || echo 0)
    else
        mtime=$(stat -c %Y "$wt" 2>/dev/null || echo 0)
    fi
    local age_sec age_minutes
    age_sec=$(( NOW_EPOCH - mtime ))
    if [[ "$age_sec" -lt "$IDLE_SEC" ]]; then
        echo "SKIP:too_fresh" > "$result_file"
        return
    fi
    age_minutes=$(( age_sec / 60 ))

    # 6. Get gap_id for the event payload
    local gap_id
    gap_id=$(_get_gap_id "$wt" "$branch")

    # All criteria met — emit orphan detection
    printf 'DETECT:%s:%s:%s:%d:%d:%s\n' \
        "$wt" "$branch" "$last_sha" "$uncommitted_lines" "$age_minutes" "$gap_id" \
        > "$result_file"
}

# ── Main scan ────────────────────────────────────────────────────────────────

# Get list of /tmp/chump-* worktrees known to git.
# Use the main repo's worktree list as source-of-truth, then filter by SCAN_DIR.
# Use while-read instead of mapfile for bash 3.2 compatibility (macOS /bin/bash).
ALL_WORKTREES=()
while IFS= read -r _wt; do
    [[ -n "$_wt" ]] && ALL_WORKTREES+=("$_wt")
done < <(
    git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print $2}' \
        | grep "^${SCAN_DIR}/chump-" || true
)

if [[ ${#ALL_WORKTREES[@]} -eq 0 ]]; then
    echo "[orphan-worktree-watchdog] no ${SCAN_DIR}/chump-* worktrees found — nothing to check"
    exit 0
fi

echo "[orphan-worktree-watchdog] scanning ${#ALL_WORKTREES[@]} worktrees under ${SCAN_DIR}/chump-*"

# Temp directory for parallel result files
_TMPDIR="$(mktemp -d -t orphan-watchdog.XXXXXX)"
trap 'rm -rf "$_TMPDIR"' EXIT

# Launch parallel per-worktree checks as background subshells
_pids=()
for wt in "${ALL_WORKTREES[@]}"; do
    result_file="$_TMPDIR/$(printf '%s' "$wt" | tr '/' '_')"
    _check_worktree "$wt" "$result_file" &
    _pids+=($!)
done

# Wait for all parallel checks to complete
for pid in "${_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# Collect and process results
for wt in "${ALL_WORKTREES[@]}"; do
    result_file="$_TMPDIR/$(printf '%s' "$wt" | tr '/' '_')"
    [[ -f "$result_file" ]] || continue
    line=$(cat "$result_file")
    case "$line" in
        SKIP:*)
            reason="${line#SKIP:}"
            echo "[orphan-worktree-watchdog] SKIP $wt (reason=$reason)"
            ;;
        DETECT:*)
            # Format: DETECT:<path>:<branch>:<sha>:<uncommitted>:<age_min>:<gap_id>
            # path may contain colons (e.g. /tmp/chump-infra:1234) — use cut carefully
            # Fields after DETECT: are positional; path is field 2, rest follow
            rest="${line#DETECT:}"
            # Split on the known-safe fields from right: gap_id, age_min, uncommitted, sha, branch, path
            gap_id="${rest##*:}"
            rest2="${rest%:*}"
            age_min="${rest2##*:}"
            rest3="${rest2%:*}"
            uncommitted="${rest3##*:}"
            rest4="${rest3%:*}"
            last_sha="${rest4##*:}"
            rest5="${rest4%:*}"
            branch="${rest5##*:}"
            wt_path="${rest5%:*}"
            _emit "$wt_path" "$branch" "$last_sha" "$uncommitted" "$age_min" "$gap_id"
            ;;
    esac
done

echo "[orphan-worktree-watchdog] done — detected=${DETECTED}"
