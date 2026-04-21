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
#   1  One or more gaps are already done, live-claimed, or missing from gaps.yaml
#      (unless CHUMP_ALLOW_UNREGISTERED_GAP=1 for bootstrap filing PRs).
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

GAPS_YAML_REMOTE="${GAPS_YAML:-$(git show "$REMOTE/$BASE:docs/gaps.yaml" 2>/dev/null || echo "")}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
LOCAL_GAPS_YAML=""
if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/docs/gaps.yaml" ]]; then
    LOCAL_GAPS_YAML="$(cat "$REPO_ROOT/docs/gaps.yaml" 2>/dev/null || true)"
fi

# Prefer origin/main for "done" truth. If fetch/git-show failed (offline, shallow
# clone), fall back to the working-tree copy so unregistered-ID enforcement
# (INFRA-020) still runs instead of silently skipping check 1.
GAPS_YAML="$GAPS_YAML_REMOTE"
if [[ -z "$GAPS_YAML" && -n "$LOCAL_GAPS_YAML" ]]; then
    GAPS_YAML="$LOCAL_GAPS_YAML"
    info "WARN: using working-tree docs/gaps.yaml for gap ID lookup (could not read $REMOTE/$BASE:docs/gaps.yaml)."
fi

gap_status() {
    # Use grep+sed instead of echo|awk to avoid SIGPIPE with large GAPS_YAML.
    # (awk's `exit` causes the `echo` side of the pipe to get SIGPIPE; with
    # set -euo pipefail that propagates as a fatal 141 exit — COMP-014 fix.)
    local gid="$1"
    # docs/gaps.yaml uses `- id: GAP` at column 0 under `gaps:` and `  status:` (two spaces).
    echo "$GAPS_YAML" | grep -A20 "^- id: ${gid}$" | grep -m1 "^  status:" | \
        sed 's/^  status: *//' | tr -d "'\"" || true
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

# ── Domain → file-scope heuristic (matches musher.sh) ───────────────────────
_gap_files() {
    local gap="${1:-}"
    case "$gap" in
        COG-*)   echo "src/reflection.rs,src/reflection_db.rs,src/consciousness_tests.rs" ;;
        EVAL-*)  echo "scripts/ab-harness/,tests/fixtures/" ;;
        COMP-*)  echo "src/browser_tool.rs,src/acp_server.rs,src/acp.rs" ;;
        INFRA-*) echo ".github/workflows/,scripts/" ;;
        AGT-*)   echo "src/agent_loop/,src/autonomy_loop.rs" ;;
        MEM-*)   echo "src/memory_db.rs,src/memory_tool.rs,src/memory_graph.rs" ;;
        AUTO-*)  echo "src/tool_middleware.rs,scripts/" ;;
        DOC-*)   echo "docs/,CLAUDE.md,AGENTS.md" ;;
        *)       echo "" ;;
    esac
}

# ── Check 3: recent INTENT by another session (ambient.jsonl) ─────────────
check_recent_intent() {
    local gap_id="$1"
    local my_session="$2"
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    local ambient="$repo_root/.chump-locks/ambient.jsonl"
    [[ -f "$ambient" ]] || return 0

    python3 - "$ambient" "$gap_id" "$my_session" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
ambient, gap_id, my_session = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.now(timezone.utc)
cutoff_secs = 120  # 2-minute intent window

try:
    lines = open(ambient).readlines()[-300:]
except Exception:
    sys.exit(0)

for line in reversed(lines):
    try:
        d = json.loads(line.strip())
    except Exception:
        continue
    if d.get("event") != "INTENT":
        continue
    if d.get("gap") != gap_id:
        continue
    if d.get("session", "") == my_session:
        continue
    try:
        ts = datetime.fromisoformat(d["ts"].replace("Z", "+00:00"))
        age = (now - ts).total_seconds()
        if age > cutoff_secs:
            continue
    except Exception:
        continue
    print(f"{d['session']}:{int(age)}s")
    sys.exit(0)
PYEOF
}

# ── Check 4: open PR file-scope overlap ──────────────────────────────────────
check_pr_conflict() {
    local gap_id="$1"
    local likely
    likely="$(_gap_files "$gap_id")"
    [[ -n "$likely" ]] || return 0

    PR_DATA="$(gh pr list --state open --json number,headRefName,files \
        --jq '.[] | "\(.number)|\(.headRefName)|" + ([.files[].path] | join(","))' \
        2>/dev/null | head -20 || true)"
    [[ -n "$PR_DATA" ]] || return 0

    IFS=',' read -ra gfiles <<< "$likely"
    while IFS='|' read -r prnum prbranch prfiles; do
        [[ -n "$prfiles" ]] || continue
        for gf in "${gfiles[@]}"; do
            prefix="${gf%%\**}"
            if echo "$prfiles" | grep -q "$prefix"; then
                echo "#$prnum ($prbranch)"
                return
            fi
        done
    done <<< "$PR_DATA"
}

for GAP_ID in "$@"; do
    # ── Check 1: done on main ──────────────────────────────────────────────
    if [[ -n "$GAPS_YAML" ]]; then
        STATUS="$(gap_status "$GAP_ID")"
        if [[ -z "$STATUS" ]]; then
            if [[ "${CHUMP_ALLOW_UNREGISTERED_GAP:-0}" == "1" ]]; then
                info "WARN: $GAP_ID not in gaps.yaml — CHUMP_ALLOW_UNREGISTERED_GAP=1, proceeding."
            else
                red "SKIP $GAP_ID — not found in docs/gaps.yaml."
                red "  Two agents inventing the same ID concurrently was the"
                red "  INFRA-016/017/018 collision chain (2026-04-20). File the"
                red "  gap to gaps.yaml in its own tiny PR FIRST, then claim the"
                red "  ID after that PR merges. For a legit exception (e.g. the"
                red "  filing PR itself) use: CHUMP_ALLOW_UNREGISTERED_GAP=1"
                FAILED=1
                continue
            fi
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

    # ── Check 3: recent INTENT by another session ──────────────────────────
    INTENT="$(check_recent_intent "$GAP_ID" "$SESSION_ID")"
    if [[ -n "$INTENT" ]]; then
        INTENT_SESS="${INTENT%%:*}"
        INTENT_AGE="${INTENT#*:}"
        info "WARN: $GAP_ID — session '$INTENT_SESS' announced INTENT ${INTENT_AGE} ago."
        info "  Sleeping 10s then re-checking to let earlier claimer proceed first…"
        sleep 10
        # Re-check lease (if they claimed in those 10s, we'll catch it now)
        CLAIM2="$(check_lease_claim "$GAP_ID" "$SESSION_ID")"
        if [[ -n "$CLAIM2" ]]; then
            HOLDER2="${CLAIM2%%:*}"
            red "SKIP $GAP_ID — session '$HOLDER2' claimed it while we waited."
            FAILED=1
            continue
        fi
        info "  No lease found after wait — proceeding (their INTENT may have been exploratory)."
    fi

    # ── Check 4: open PR file-scope overlap ───────────────────────────────
    PR_CONFLICT="$(check_pr_conflict "$GAP_ID")"
    if [[ -n "$PR_CONFLICT" ]]; then
        info "WARN: $GAP_ID — open PR $PR_CONFLICT touches the same file domain."
        info "  Domain: $(_gap_files "$GAP_ID")"
        info "  Merge or coordinate with that PR before starting to reduce conflict risk."
        # Non-fatal: warn but don't block — PR may be in a different code path.
    fi

    green "OK $GAP_ID — open and unclaimed."
done

if [[ $FAILED -eq 1 ]]; then
    red "Pre-flight failed: one or more gaps unavailable (already done on $REMOTE/$BASE, live-claimed by another session, or not registered in docs/gaps.yaml)."
    exit 1
fi

green "Pre-flight passed — all specified gaps are available."
exit 0
