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
#   CHUMP_SESSION_ID   override session ID (default: $HOME/.chump/session_id)
#   CLAUDE_SESSION_ID  fallback session ID (set by Claude agent SDK)
#   GAP_CLAIM_TTL_HOURS  claim TTL in hours (default: 4)

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID" >&2
    exit 1
fi

GAP_ID="$1"

# ── Resolve session ID ────────────────────────────────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" ]]; then
    # Last resort: random ID (won't survive across shell invocations)
    SESSION_ID="ephemeral-$$-$(date +%s)"
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
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
