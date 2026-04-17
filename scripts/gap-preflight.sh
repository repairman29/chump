#!/usr/bin/env bash
# gap-preflight.sh — Verify gap IDs are still open/unclaimed before starting work.
#
# Run this BEFORE claiming a gap or starting work on a new branch. It checks:
#   1. docs/gaps.yaml on origin/main — if status:done, abort (work already landed).
#   2. .chump-locks/*.json — if another live session has the same gap_id, abort.
#
# The old in_progress/claimed_by/claimed_at YAML fields are gone. Claims now
# live in lease files (.chump-locks/<session>.json) so there are zero merge
# conflicts and stale claims auto-expire with the session TTL.
#
# Usage:
#   scripts/gap-preflight.sh GAP-ID [GAP-ID ...]
#   scripts/gap-preflight.sh AUTO-003 COMP-002
#
# Exit codes:
#   0  All specified gaps are open and unclaimed — proceed.
#   1  One or more gaps are already done or live-claimed by another session.
#
# Environment:
#   REMOTE            git remote to check (default: origin)
#   BASE              base branch to check against (default: main)
#   CHUMP_SESSION_ID  current agent session ID — used to distinguish "our" claims

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID [GAP-ID ...]" >&2
    exit 0
fi

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    # Prefer the worktree-scoped session ID cached by gap-claim.sh over the
    # machine-scoped $HOME/.chump/session_id — avoids false "already claimed"
    # positives when multiple sessions share the machine ID.
    _WT_CACHE="$(git rev-parse --show-toplevel 2>/dev/null)/.chump-locks/.wt-session-id"
    if [[ -f "$_WT_CACHE" ]]; then
        SESSION_ID="$(cat "$_WT_CACHE" 2>/dev/null || true)"
    fi
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi

red()   { printf '\033[0;31m[gap-preflight] %s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m[gap-preflight] %s\033[0m\n' "$*" >&2; }
info()  { printf '[gap-preflight] %s\n' "$*" >&2; }

# ── 1. Fetch origin/main (for done-check) ────────────────────────────────────
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    info "WARN: could not fetch $REMOTE/$BASE — skipping remote done-check (offline?)"
    GAPS_YAML=""
}

GAPS_YAML="${GAPS_YAML:-$(git show "$REMOTE/$BASE:docs/gaps.yaml" 2>/dev/null || echo "")}"

gap_status() {
    local gid="$1"
    echo "$GAPS_YAML" | awk \
        "/^  - id: ${gid}\$/{found=1} found && /^    status:/{sub(/^    status: */,\"\"); print; exit}"
}

# ── 2. Check active lease files for gap_id conflicts ─────────────────────────
# Parse .chump-locks/*.json with python3 (always available; no jq dependency).
# Returns "session_id:expires_at" for any live lease with matching gap_id that
# belongs to a different session, or empty string if free.
check_lease_claim() {
    local gap_id="$1"
    local my_session="$2"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local lock_dir="$repo_root/.chump-locks"
    [[ -d "$lock_dir" ]] || return 0

    python3 - "$lock_dir" "$gap_id" "$my_session" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

lock_dir, gap_id, my_session = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.now(timezone.utc)

for fname in os.listdir(lock_dir):
    if not fname.endswith(".json"):
        continue
    path = os.path.join(lock_dir, fname)
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue

    if d.get("gap_id") != gap_id:
        continue
    if d.get("session_id", "") == my_session:
        continue

    # Check liveness: expires_at and heartbeat_at must not be stale.
    try:
        expires = datetime.fromisoformat(d["expires_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        heartbeat = datetime.fromisoformat(d["heartbeat_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        grace = 30          # seconds of clock-skew grace (mirrors Rust REAP_GRACE_SECS)
        stale_secs = 900    # mirrors Rust HEARTBEAT_STALE_SECS
        expired = (now - expires).total_seconds() > grace
        stale = (now - heartbeat).total_seconds() > stale_secs
        if expired or stale:
            continue  # stale claim — treat as free
    except Exception:
        continue  # unparseable timestamps → treat as expired

    print(f"{d['session_id']}:{d.get('expires_at', '?')}")
    sys.exit(0)
PYEOF
}

FAILED=0

for GAP_ID in "$@"; do
    # ── Check 1: done on main ──────────────────────────────────────────────
    if [[ -n "$GAPS_YAML" ]]; then
        STATUS="$(gap_status "$GAP_ID")"
        if [[ -z "$STATUS" ]]; then
            info "WARN: $GAP_ID not found in gaps.yaml — skipping done-check (new gap?)"
        elif [[ "$STATUS" == "done" ]]; then
            red "SKIP $GAP_ID — already status:done on $REMOTE/$BASE."
            red "  The work exists. No need to re-implement. Choose a different gap."
            FAILED=1
            continue
        fi
    fi

    # ── Check 2: live lease claim by another session ───────────────────────
    CLAIM="$(check_lease_claim "$GAP_ID" "$SESSION_ID")"
    if [[ -n "$CLAIM" ]]; then
        HOLDER="${CLAIM%%:*}"
        EXPIRES="${CLAIM#*:}"
        red "SKIP $GAP_ID — claimed by session '$HOLDER' (lease expires $EXPIRES)."
        red "  Coordinate with that session or wait for the lease to expire."
        FAILED=1
        continue
    fi

    green "OK $GAP_ID — open and unclaimed."
done

if [[ $FAILED -eq 1 ]]; then
    red "Pre-flight failed: one or more gaps already done or live-claimed."
    exit 1
fi

green "Pre-flight passed — all specified gaps are available."
exit 0
