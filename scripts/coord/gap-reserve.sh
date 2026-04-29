#!/usr/bin/env bash
# gap-reserve.sh — Atomically reserve the next free gap ID for a domain (INFRA-021).
#
# As of INFRA-100 (2026-04-28) this script delegates ID picking to the
# `chump gap reserve` Rust path, which is the single source of truth across
# all four collision sources: state.db, docs/gaps.yaml, open PRs, and live
# `pending_new_gap` leases. Pre-INFRA-100 the picker logic lived here in a
# 220-line inline Python script with parallel logic to the Rust path; that
# divergence let the INFRA-087..090 4-way collision through (PRs
# #565/#566/#568/#569, 2026-04-26).
#
# This wrapper still owns:
#   1. Session-id resolution (matches gap-claim.sh).
#   2. Main-worktree guard (refuse to reserve from /Projects/Chump directly).
#   3. Writing `pending_new_gap` into the session's lease file so that
#      sibling agents see the in-flight reservation immediately and the
#      Rust path's `external_pending_ids` will pick it up next time.
#   4. The per-domain `flock` so two concurrent shell invocations on the
#      same machine cannot end up calling chump in parallel and racing
#      the SQLite counter (Rust path uses BEGIN IMMEDIATE; flock here is
#      defense-in-depth at the shell layer).
#
# Usage:
#   scripts/coord/gap-reserve.sh INFRA "title words here"
#   scripts/coord/gap-reserve.sh EVAL "short title"
#
# Prints the reserved ID as the only stdout line; human messages go to stderr.
#
# Environment:
#   CHUMP_SESSION_ID / CLAUDE_SESSION_ID — same resolution order as gap-claim.sh
#   CHUMP_ALLOW_MAIN_WORKTREE=1 — allow running from the main worktree (testing)
#   CHUMP_RESERVE_SCAN_OPEN_PRS=1 — opt-in `gh pr list` scan inside chump
#   CHUMP_LOCK_DIR — override `.chump-locks/` path (tests; must match gap-preflight)

set -euo pipefail

usage() {
    echo "Usage: $0 <DOMAIN> [title words...]" >&2
    echo "  DOMAIN: uppercase prefix, e.g. INFRA, EVAL, COG (no trailing hyphen)" >&2
    exit 1
}

[[ $# -ge 1 ]] || usage
DOMAIN="$1"
shift
TITLE="${*:-"New gap"}"

if ! [[ "$DOMAIN" =~ ^[A-Z][A-Z0-9]*$ ]]; then
    echo "[gap-reserve] ERROR: DOMAIN must be PREFIX letters/digits only, e.g. INFRA or EVAL (got '$DOMAIN')" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
mkdir -p "$LOCK_DIR"
FLOCK_PATH="$LOCK_DIR/.gap-reserve-${DOMAIN}.flock"

# ── Main-worktree guard (same rationale as gap-claim.sh) ─────────────────────
_WT_LIST="$(git worktree list --porcelain)"
MAIN_WORKTREE_PATH="$(awk '/^worktree /{sub(/^worktree /,""); print; exit}' <<<"$_WT_LIST")"
if [[ "$REPO_ROOT" == "$MAIN_WORKTREE_PATH" ]] && [[ "${CHUMP_ALLOW_MAIN_WORKTREE:-0}" != "1" ]]; then
    printf '[gap-reserve] ERROR: refusing to reserve from the main worktree.\n' >&2
    printf '[gap-reserve] Use a linked worktree, or CHUMP_ALLOW_MAIN_WORKTREE=1 for tests.\n' >&2
    exit 1
fi

# ── Session ID (match gap-claim.sh) ──────────────────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    WT_SESSION_CACHE="$LOCK_DIR/.wt-session-id"
    if [[ -f "$WT_SESSION_CACHE" ]]; then
        SESSION_ID="$(cat "$WT_SESSION_CACHE" 2>/dev/null || true)"
    fi
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="ephemeral-$$-$(date +%s)"
fi

SAFE_ID="${SESSION_ID//[^a-zA-Z0-9_-]/_}"
LEASE_FILE="$LOCK_DIR/${SAFE_ID}.json"

# ── Pick ID under flock + write pending_new_gap to lease ─────────────────────
# The flock prevents two concurrent shell invocations from racing the
# `chump gap reserve` SQLite counter. Inside the lock we run `chump`,
# capture the ID, and write `pending_new_gap` so other tools (gap-preflight,
# external_pending_ids) see the in-flight reserve immediately.
exec 9>"$FLOCK_PATH"
flock -x 9

# Drain any stale fd inheritance: chump must not see flock fd as a tty stdin.
NEW_ID="$(chump gap reserve --domain "$DOMAIN" --title "$TITLE" </dev/null)"
if [[ -z "$NEW_ID" ]]; then
    echo "[gap-reserve] ERROR: chump gap reserve returned empty output" >&2
    exit 1
fi

# Write/merge pending_new_gap into the lease file. Keeps existing fields if
# the session already had a lease (e.g. from a prior gap-claim).
python3 - "$LEASE_FILE" "$SESSION_ID" "$NEW_ID" "$DOMAIN" "$TITLE" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone

lease_path, session_id, new_id, domain, title = sys.argv[1:6]
now = datetime.now(timezone.utc)
now_s = now.strftime("%Y-%m-%dT%H:%M:%SZ")
ttl_h = int(os.environ.get("GAP_CLAIM_TTL_HOURS", "4"))
exp_s = (now + timedelta(hours=ttl_h)).strftime("%Y-%m-%dT%H:%M:%SZ")

if os.path.isfile(lease_path):
    with open(lease_path, encoding="utf-8") as f:
        d = json.load(f)
else:
    d = {"session_id": session_id, "paths": [], "purpose": f"gap-reserve:{new_id}"}

d["session_id"] = session_id
d["pending_new_gap"] = {"id": new_id, "title": title, "domain": domain}
d.setdefault("taken_at", now_s)
d["expires_at"] = exp_s
d["heartbeat_at"] = now_s
d.setdefault("paths", [])

with open(lease_path, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

echo "$NEW_ID"
echo "[gap-reserve] Wrote pending_new_gap → $LEASE_FILE (session $SESSION_ID)" >&2
