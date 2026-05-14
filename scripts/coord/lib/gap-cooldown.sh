#!/usr/bin/env bash
# scripts/coord/lib/gap-cooldown.sh — INFRA-1220
#
# Post-close cooldown for gaps whose PRs forcibly closed without merging
# (zombies, dirties, abandons). After a PR closes unmerged, a small window
# (default 1 h) prevents the next worker from immediately re-claiming the
# same gap and hitting the same environmental bug.
#
# Today's evidence (2026-05-14 audit): INFRA-988 (PWA settings panel) was
# closed-not-merged THREE times in 12 hours — every attempt hit the same
# cross-worktree state corruption pattern. A 1-hour pause after the second
# close would have signaled to operator/agent that the infra needed a fix
# before attempt #3 was burned.
#
# Storage: file per gap at $LOCK_DIR/.gap-cooldown/<GAP-ID>.json
#   {"gap":"...","closed_at":"...","pr":N,"reason":"...","expires_at":"..."}
#
# Public functions (after `source`):
#   gap_cooldown_active <GAP-ID>     → exits 0 if cooldown blocking; 1 if clear
#   gap_cooldown_stamp <GAP-ID> [PR_NUM] [REASON]
#   gap_cooldown_clear <GAP-ID> [REASON]
#   gap_cooldown_status <GAP-ID>     → prints cooldown info if present
#
# Env:
#   CHUMP_GAP_REROLL_COOLDOWN_S   — cooldown window in seconds (default 3600)
#   CHUMP_LOCK_DIR                — override lock dir (tests)
#   CHUMP_NO_GAP_COOLDOWN         — skip checks entirely (emergency bypass)

[[ -n "${_CHUMP_GAP_COOLDOWN_LOADED:-}" ]] && return 0
_CHUMP_GAP_COOLDOWN_LOADED=1

_gc_lock_dir() {
    if [[ -n "${CHUMP_LOCK_DIR:-}" ]]; then
        printf '%s' "$CHUMP_LOCK_DIR"
        return
    fi
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    printf '%s/.chump-locks' "$root"
}

_gc_dir() { printf '%s/.gap-cooldown' "$(_gc_lock_dir)"; }

_gc_now_epoch() { date +%s; }

_gc_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Returns 0 (true) if cooldown is currently active for the gap, 1 otherwise.
gap_cooldown_active() {
    local gap_id="${1:-}"
    [[ -z "$gap_id" ]] && return 1
    [[ "${CHUMP_NO_GAP_COOLDOWN:-0}" == "1" ]] && return 1
    local f
    f="$(_gc_dir)/$gap_id.json"
    [[ -f "$f" ]] || return 1
    local expires
    expires="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('expires_at_epoch', 0))
except Exception:
    print(0)
" "$f" 2>/dev/null)"
    [[ -z "$expires" || "$expires" == "0" ]] && return 1
    local now
    now="$(_gc_now_epoch)"
    if [[ "$now" -lt "$expires" ]]; then
        return 0
    fi
    # Expired — best-effort remove the stale file so the next call is fast.
    rm -f "$f" 2>/dev/null || true
    return 1
}

# Write a cooldown stamp. Idempotent: re-stamping resets the expiry.
gap_cooldown_stamp() {
    local gap_id="${1:-}"
    local pr_num="${2:-}"
    local reason="${3:-unknown}"
    [[ -z "$gap_id" ]] && return 2
    local dir
    dir="$(_gc_dir)"
    mkdir -p "$dir" 2>/dev/null || return 1
    local window="${CHUMP_GAP_REROLL_COOLDOWN_S:-3600}"
    local now_epoch
    now_epoch="$(_gc_now_epoch)"
    local expires_at_epoch=$((now_epoch + window))
    local f="$dir/$gap_id.json"
    python3 -c "
import json, sys
data = {
    'gap': sys.argv[1],
    'closed_at': sys.argv[2],
    'expires_at': sys.argv[3],
    'expires_at_epoch': int(sys.argv[4]),
    'pr': sys.argv[5] or None,
    'reason': sys.argv[6],
}
with open(sys.argv[7], 'w') as fh:
    json.dump(data, fh, indent=2)
" "$gap_id" "$(_gc_iso_now)" "$(date -u -r "$expires_at_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" "$expires_at_epoch" "$pr_num" "$reason" "$f"
}

# Operator-only clear (audit trail: requires a reason).
gap_cooldown_clear() {
    local gap_id="${1:-}"
    local reason="${2:-operator-override}"
    [[ -z "$gap_id" ]] && return 2
    local f
    f="$(_gc_dir)/$gap_id.json"
    [[ -f "$f" ]] || return 0
    rm -f "$f"
    # Audit line to ambient.
    local ambient
    ambient="$(_gc_lock_dir)/ambient.jsonl"
    printf '{"ts":"%s","kind":"gap_cooldown_cleared","gap":"%s","reason":"%s"}\n' \
        "$(_gc_iso_now)" "$gap_id" "$reason" >> "$ambient" 2>/dev/null || true
}

# Pretty-print the cooldown state for `chump gap show` / operator triage.
gap_cooldown_status() {
    local gap_id="${1:-}"
    [[ -z "$gap_id" ]] && return 2
    local f
    f="$(_gc_dir)/$gap_id.json"
    [[ -f "$f" ]] || return 0
    python3 -c "
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    rem = int(d.get('expires_at_epoch', 0) - time.time())
    if rem <= 0:
        print('cooldown: EXPIRED (file is stale)')
    else:
        m = rem // 60
        print(f'cooldown: ACTIVE — {m}m remaining, closed_pr={d.get(\"pr\")}, reason={d.get(\"reason\")}')
except Exception as e:
    print(f'cooldown: (parse error: {e})')
" "$f"
}
