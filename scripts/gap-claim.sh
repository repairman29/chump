#!/usr/bin/env bash
# gap-claim.sh — Claim a gap by writing a lease file entry.
#
# Replaces the old "edit docs/gaps.yaml + git push" claim workflow. Writing a
# local JSON file is instant, causes no merge conflicts, and auto-expires when
# the session ends or the TTL fires — no stale locks possible.
#
# Usage:
#   scripts/gap-claim.sh GAP-ID
#   scripts/gap-claim.sh REL-004
#   scripts/gap-claim.sh REL-004 --paths src/foo.rs,src/bar.rs
#
# The claim is written to the session's lease file in .chump-locks/. Any other
# session running gap-preflight.sh for the same GAP-ID will see the claim and
# abort.
#
# Options:
#   --paths file1,file2,...   comma-separated list of files this session intends
#                             to edit. Written to the lease JSON under "paths".
#                             chump-commit.sh uses this for advisory conflict
#                             warnings when another session claims the same file.
#
# Environment:
#   CHUMP_SESSION_ID         explicit session ID override (highest priority)
#   CLAUDE_SESSION_ID        set by Claude Code SDK — unique per session
#   GAP_CLAIM_TTL_HOURS      claim TTL in hours (default: 4)
#   CHUMP_ALLOW_MAIN_WORKTREE  set to 1 to allow claiming from the main worktree
#   CHUMP_PATH_CASE_CHECK    set to 0 to skip the path-case guard (default: 1)

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID [--paths file1,file2,...]" >&2
    exit 1
fi

GAP_ID="$1"
shift

# ── Parse optional --paths argument ──────────────────────────────────────────
CLAIM_PATHS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths)
            shift
            CLAIM_PATHS="${1:-}"
            ;;
        --paths=*)
            CLAIM_PATHS="${1#--paths=}"
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 GAP-ID [--paths file1,file2,...]" >&2
            exit 1
            ;;
    esac
    shift
done

# ── Paths (needed before session ID so we can detect main worktree) ───────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"

# ── Phase 1: NATS atomic claim (COORD-NATS) ───────────────────────────────────
# Before writing the file-based lease, attempt an atomic CAS claim via the
# chump-coord binary. This eliminates the 3-second sleep race that caused
# 5× duplicate implementations in April 2026 (see ADR-004).
#
# chump-coord claim exits:
#   0 — claim won (or NATS unavailable — file-based fallback proceeds)
#   1 — CONFLICT: another session holds the atomic claim — abort immediately
#
# If chump-coord is not in PATH, we fall through to the file-based system
# unchanged. No coordination regression is possible.
_COORD_BIN="$(command -v chump-coord 2>/dev/null || true)"
if [[ -n "$_COORD_BIN" ]]; then
    # Derive file hints from gap domain (same heuristic as musher.sh)
    _COORD_FILES="$(python3 -c "
gap='$GAP_ID'
m = {'COG':'src/reflection.rs,src/reflection_db.rs','EVAL':'scripts/ab-harness/','COMP':'src/browser_tool.rs','INFRA':'.github/workflows/','AGT':'src/agent_loop/','MEM':'src/memory_db.rs','AUTO':'src/tool_middleware.rs','DOC':'docs/'}
prefix=gap.split('-')[0]
print(m.get(prefix,''))
" 2>/dev/null || true)"
    export CHUMP_COORD_FILES="$_COORD_FILES"
    if ! CHUMP_SESSION_ID="$SESSION_ID" "$_COORD_BIN" claim "$GAP_ID" 2>&1; then
        # Exit code 1 = atomic conflict — another agent won the CAS race.
        printf '[gap-claim] NATS atomic conflict on %s — aborting. Run musher.sh --pick for next available gap.\n' "$GAP_ID" >&2
        exit 1
    fi
fi

# ── Path-case guard (INFRA-WORKTREE-PATH-CASE) ───────────────────────────────
# macOS is case-insensitive, so /Users/jeffadkins/projects/Chump and
# /Users/jeffadkins/Projects/Chump resolve to the same directory. But
# case-sensitive tools (git operations, ripgrep, CI matchers, cross-repo
# symlinks) may fail when the path capitalization doesn't match the canonical
# filesystem entry. This guard detects the mismatch early so the agent knows
# to restart from a properly-cased directory.
#
# We compare $REPO_ROOT against its own canonical form from `realpath -m` (or
# Python's os.path.realpath as a portable fallback). If they differ, we warn
# and abort — the fix is to cd to the canonical path and re-run.
#
# Bypass: CHUMP_PATH_CASE_CHECK=0 (e.g. for bootstrap or intentional aliases).
if [[ "${CHUMP_PATH_CASE_CHECK:-1}" != "0" ]]; then
    # Try `realpath` (coreutils/greadlink) then Python fallback.
    _CANONICAL_ROOT=""
    if command -v python3 >/dev/null 2>&1; then
        _CANONICAL_ROOT="$(python3 -c "import os; print(os.path.realpath('$REPO_ROOT'))" 2>/dev/null || true)"
    fi
    if [[ -z "$_CANONICAL_ROOT" ]] && command -v realpath >/dev/null 2>&1; then
        _CANONICAL_ROOT="$(realpath "$REPO_ROOT" 2>/dev/null || true)"
    fi
    if [[ -z "$_CANONICAL_ROOT" ]] && command -v greadlink >/dev/null 2>&1; then
        _CANONICAL_ROOT="$(greadlink -f "$REPO_ROOT" 2>/dev/null || true)"
    fi

    if [[ -n "$_CANONICAL_ROOT" && "$REPO_ROOT" != "$_CANONICAL_ROOT" ]]; then
        printf '[gap-claim] ERROR: worktree path case mismatch detected.\n' >&2
        printf '[gap-claim]   Current REPO_ROOT:  %s\n' "$REPO_ROOT" >&2
        printf '[gap-claim]   Canonical path:     %s\n' "$_CANONICAL_ROOT" >&2
        printf '[gap-claim] Case-sensitive tools (git, ripgrep, CI) may fail with the non-canonical path.\n' >&2
        printf '[gap-claim] Fix: cd to the canonical path and re-run.\n' >&2
        printf '[gap-claim]   cd "%s" && scripts/gap-claim.sh %s\n' "$_CANONICAL_ROOT" "$GAP_ID" >&2
        printf '[gap-claim] Bypass: CHUMP_PATH_CASE_CHECK=0 scripts/gap-claim.sh %s\n' "$GAP_ID" >&2
        exit 1
    fi
fi

# ── Main-worktree guard (AUTO-HYGIENE-a) ─────────────────────────────────────
# Claiming a gap in the main worktree means two concurrent sessions (both in
# $REPO_ROOT) would write to the same .chump-locks/ dir with the same or
# colliding IDs — exactly the stomp class we're fixing. Linked worktrees under
# .claude/worktrees/ each have an isolated REPO_ROOT, so their locks live in
# separate trees.
# INFRA-027: the original version used `awk '…exit'` which closed the pipe
# while `git worktree list` was still writing, producing SIGPIPE → pipeline
# exit 141 under `set -o pipefail`, and the lease never got written.
# Capture git's output first, then parse with a single awk (no pipeline).
_WT_LIST="$(git worktree list --porcelain)"
MAIN_WORKTREE_PATH="$(awk '/^worktree /{sub(/^worktree /,""); print; exit}' <<<"$_WT_LIST")"
if [[ "$REPO_ROOT" == "$MAIN_WORKTREE_PATH" ]] && [[ "${CHUMP_ALLOW_MAIN_WORKTREE:-0}" != "1" ]]; then
    printf '[gap-claim] ERROR: refusing to claim gap in the main worktree.\n' >&2
    printf '[gap-claim] Run `git worktree add .claude/worktrees/<name> -b claude/<name> origin/main`\n' >&2
    printf '[gap-claim] then re-run gap-claim.sh from that worktree, or set CHUMP_ALLOW_MAIN_WORKTREE=1.\n' >&2
    exit 1
fi

# ── Resolve session ID (AUTO-HYGIENE-b) ──────────────────────────────────────
# Priority:
#   1. CHUMP_SESSION_ID      — explicit override (e.g. from bot-merge.sh)
#   2. CLAUDE_SESSION_ID     — set by Claude Code SDK; unique per session (best)
#   3. Worktree-derived      — stable per-worktree ID cached in .chump-locks/.wt-session-id
#                              avoids sharing $HOME/.chump/session_id across sessions
#   4. $HOME/.chump/session_id — legacy machine-scoped fallback (last resort only)
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

if [[ -z "$SESSION_ID" ]]; then
    # Worktree-derived: generate once, cache in the worktree's lock dir.
    # Using the worktree basename + epoch gives a unique, human-readable ID
    # that scopes leases to this worktree without the machine-ID collision.
    mkdir -p "$LOCK_DIR"
    WT_SESSION_CACHE="$LOCK_DIR/.wt-session-id"
    if [[ -f "$WT_SESSION_CACHE" ]]; then
        SESSION_ID="$(cat "$WT_SESSION_CACHE")"
    else
        SESSION_ID="chump-$(basename "$REPO_ROOT")-$(date +%s)"
        printf '%s' "$SESSION_ID" > "$WT_SESSION_CACHE"
    fi
fi

if [[ -z "$SESSION_ID" ]] && [[ -f "$HOME/.chump/session_id" ]]; then
    # Legacy machine-scoped ID — only reached when all above are absent.
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi

if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="ephemeral-$$-$(date +%s)"
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOCK_DIR"

# Sanitise session ID for use as filename (match Rust agent_lease.rs rules)
SAFE_ID="${SESSION_ID//[^a-zA-Z0-9_-]/_}"
LOCK_FILE="$LOCK_DIR/${SAFE_ID}.json"

# ── Timestamps ────────────────────────────────────────────────────────────────
TTL_HOURS="${GAP_CLAIM_TTL_HOURS:-4}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# macOS: date -v+Xh; Linux: date -d '+X hours'. Try macOS first.
EXPIRES="$(date -u -v+"${TTL_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -d "+${TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || echo "$NOW")"

# ── Read existing lease (if any) and merge ────────────────────────────────────
# If the session already has a path-lease file, preserve its fields and just
# inject/update the gap_id. Otherwise write a minimal standalone claim.
if [[ -f "$LOCK_FILE" ]]; then
    # Use python3 to merge gap_id (and optional paths) into existing JSON
    python3 - "$LOCK_FILE" "$GAP_ID" "$CLAIM_PATHS" <<'PYEOF'
import json, sys
path, gid, paths_csv = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    d = json.load(f)
d["gap_id"] = gid
pend = d.get("pending_new_gap") or {}
if isinstance(pend, dict) and pend.get("id") == gid:
    d.pop("pending_new_gap", None)
if paths_csv:
    # Merge with any existing paths, preserving dedup order.
    new_paths = [p.strip() for p in paths_csv.split(",") if p.strip()]
    existing = d.get("paths", [])
    merged = existing[:]
    for p in new_paths:
        if p not in merged:
            merged.append(p)
    d["paths"] = merged
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF
    if [[ -n "$CLAIM_PATHS" ]]; then
        printf '[gap-claim] Updated %s → gap_id=%s, paths=%s\n' "$LOCK_FILE" "$GAP_ID" "$CLAIM_PATHS"
    else
        printf '[gap-claim] Updated %s → gap_id=%s\n' "$LOCK_FILE" "$GAP_ID"
    fi
else
    # No existing lease — write a minimal standalone claim
    python3 - "$LOCK_FILE" "$GAP_ID" "$SESSION_ID" "$NOW" "$EXPIRES" "$CLAIM_PATHS" <<'PYEOF'
import json, sys
path, gap_id, session_id, taken_at, expires_at, paths_csv = sys.argv[1:]
paths_list = [p.strip() for p in paths_csv.split(",") if p.strip()] if paths_csv else []
d = {
    "session_id": session_id,
    "paths": paths_list,
    "taken_at": taken_at,
    "expires_at": expires_at,
    "heartbeat_at": taken_at,
    "purpose": f"gap:{gap_id}",
    "gap_id": gap_id,
}
pend = d.get("pending_new_gap") or {}
if isinstance(pend, dict) and pend.get("id") == gap_id:
    d.pop("pending_new_gap", None)
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF
    if [[ -n "$CLAIM_PATHS" ]]; then
        printf '[gap-claim] Claimed %s for session %s (expires %s, paths=%s)\n' "$GAP_ID" "$SESSION_ID" "$EXPIRES" "$CLAIM_PATHS"
    else
        printf '[gap-claim] Claimed %s for session %s (expires %s)\n' "$GAP_ID" "$SESSION_ID" "$EXPIRES"
    fi
fi

# ── Intent broadcast (COORD-MUSHER) ──────────────────────────────────────────
# Announce this session's intention to work on the gap BEFORE writing the
# lease. Other sessions running gap-preflight.sh will see the INTENT event
# in ambient.jsonl and pause/re-route. Without this, two sessions can both
# pass gap-preflight.sh in the same second and collide on the same gap.
#
# The 3-second sleep creates a conflict window: if two sessions emit INTENT
# simultaneously, both will see each other's event after the sleep and the
# lower-priority one (later alphabetically by session ID) will back off.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/broadcast.sh" ]]; then
    LIKELY_FILES="$(python3 -c "
import re, sys
gap='$GAP_ID'
m = {'COG':'src/reflection.rs,src/reflection_db.rs','EVAL':'scripts/ab-harness/','COMP':'src/browser_tool.rs','INFRA':'.github/workflows/','AGT':'src/agent_loop/','MEM':'src/memory_db.rs','AUTO':'src/tool_middleware.rs','DOC':'docs/'}
prefix=gap.split('-')[0]
print(m.get(prefix,''))
" 2>/dev/null || true)"
    "$SCRIPT_DIR/broadcast.sh" INTENT "$GAP_ID" "${LIKELY_FILES:-}" 2>/dev/null || true
    # Give other sessions a 3-second window to see the INTENT and back off.
    sleep 3
fi

# ── Auto-install hooks (AUTO-HYGIENE-c) ──────────────────────────────────────
# Ensure pre-commit / pre-push hooks are wired into this worktree's git dir.
# install-hooks.sh is idempotent; running it here means any newly-created
# worktree gets hooks the first time gap-claim.sh is called — no manual step.
if [[ -x "$SCRIPT_DIR/install-hooks.sh" ]]; then
    "$SCRIPT_DIR/install-hooks.sh" --quiet 2>/dev/null || true
fi
