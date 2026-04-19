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
#
# The claim is written to the session's lease file in .chump-locks/. Any other
# session running gap-preflight.sh for the same GAP-ID will see the claim and
# abort.
#
# Environment:
#   CHUMP_SESSION_ID         explicit session ID override (highest priority)
#   CLAUDE_SESSION_ID        set by Claude Code SDK — unique per session
#   GAP_CLAIM_TTL_HOURS      claim TTL in hours (default: 4)
#   CHUMP_ALLOW_MAIN_WORKTREE  set to 1 to allow claiming from the main worktree

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID" >&2
    exit 1
fi

GAP_ID="$1"

# ── Paths (needed before session ID so we can detect main worktree) ───────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCK_DIR="$REPO_ROOT/.chump-locks"

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

# ── Main-worktree guard (AUTO-HYGIENE-a) ─────────────────────────────────────
# Claiming a gap in the main worktree means two concurrent sessions (both in
# $REPO_ROOT) would write to the same .chump-locks/ dir with the same or
# colliding IDs — exactly the stomp class we're fixing. Linked worktrees under
# .claude/worktrees/ each have an isolated REPO_ROOT, so their locks live in
# separate trees.
MAIN_WORKTREE_PATH="$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
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
    # Use python3 to merge gap_id into existing JSON (always available on macOS/Linux)
    python3 - "$LOCK_FILE" "$GAP_ID" <<'PYEOF'
import json, sys
path, gid = sys.argv[1], sys.argv[2]
with open(path) as f:
    d = json.load(f)
d["gap_id"] = gid
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF
    printf '[gap-claim] Updated %s → gap_id=%s\n' "$LOCK_FILE" "$GAP_ID"
else
    # No existing lease — write a minimal standalone claim
    python3 - "$LOCK_FILE" "$GAP_ID" "$SESSION_ID" "$NOW" "$EXPIRES" <<'PYEOF'
import json, sys
path, gap_id, session_id, taken_at, expires_at = sys.argv[1:]
d = {
    "session_id": session_id,
    "paths": [],
    "taken_at": taken_at,
    "expires_at": expires_at,
    "heartbeat_at": taken_at,
    "purpose": f"gap:{gap_id}",
    "gap_id": gap_id,
}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF
    printf '[gap-claim] Claimed %s for session %s (expires %s)\n' "$GAP_ID" "$SESSION_ID" "$EXPIRES"
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
