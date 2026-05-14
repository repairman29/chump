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

# INFRA-379: heal a wedged chump binary before any CLI call (see
# scripts/lib/chump-preflight.sh). Silent no-op on healthy binaries.
# shellcheck source=../lib/chump-preflight.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/chump-preflight.sh"

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

# INFRA-109: resolve REPO_ROOT + LOCK_DIR via main-repo path (linked worktree safe).
# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"
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
#
# INFRA-301 (2026-05-02): wrap with timeout. The chump binary can wedge at
# _dyld_start if macOS Sequoia's syspolicyd gets the binary inode into a
# pending-decision state (INFRA-275). Without this timeout, gap-reserve
# hangs forever and the caller silently falls back to direct YAML writes,
# which produces silent ID collisions when N siblings each scan
# docs/gaps/*.yaml for the "next free" ID. The trace log captured a
# real-world instance of this exact pattern from a sibling Claude session
# (see scripts/dev/find-stash-creator.sh).
#
# Timeout default 30s; long enough for legitimate SQLite contention
# (INFRA-253 retry budget is 20 attempts) but short enough to fail loudly
# when the binary itself is stuck before main(). Override with
# CHUMP_GAP_RESERVE_TIMEOUT_S.
RESERVE_TIMEOUT_S="${CHUMP_GAP_RESERVE_TIMEOUT_S:-30}"
NEW_ID=""
RESERVE_RC=0
if command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_BIN=gtimeout
elif command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_BIN=timeout
else
    _TIMEOUT_BIN=""
fi

if [[ -n "$_TIMEOUT_BIN" ]]; then
    NEW_ID="$($_TIMEOUT_BIN "$RESERVE_TIMEOUT_S" chump gap reserve --domain "$DOMAIN" --title "$TITLE" </dev/null)" || RESERVE_RC=$?
else
    # No timeout binary available — fall back to plain invocation. The
    # caller still gets the better banner on non-zero exit at least.
    NEW_ID="$(chump gap reserve --domain "$DOMAIN" --title "$TITLE" </dev/null)" || RESERVE_RC=$?
fi

if [[ "$RESERVE_RC" -ne 0 ]] || [[ -z "$NEW_ID" ]]; then
    {
        echo
        echo "════════════════════════════════════════════════════════════════════"
        if [[ "$RESERVE_RC" -eq 124 ]]; then
            echo "[gap-reserve] ERROR: \`chump gap reserve\` timed out after ${RESERVE_TIMEOUT_S}s"
            echo "  This usually means the chump binary is wedged at _dyld_start"
            echo "  (macOS Sequoia syspolicyd inode-pending-decision state, INFRA-275)."
        elif [[ "$RESERVE_RC" -ne 0 ]]; then
            echo "[gap-reserve] ERROR: \`chump gap reserve\` exited with code $RESERVE_RC"
        else
            echo "[gap-reserve] ERROR: \`chump gap reserve\` returned empty output"
        fi
        echo
        echo "  HEAL: scripts/dev/chump-binary-unwedge.sh"
        echo "        (probes the binary, replaces wedged inode with fresh copy)"
        echo
        echo "  DO NOT fall back to writing docs/gaps/<ID>.yaml directly."
        echo "  Concurrent siblings each picking 'next free ID' from filesystem"
        echo "  scans produce silent collisions. INFRA-301 tracks this pattern."
        echo "════════════════════════════════════════════════════════════════════"
    } >&2
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
# INFRA-110: default 2h (was 4h). Bound the squat window so an unattended
# reserve auto-releases. Override per-call: GAP_CLAIM_TTL_HOURS=4 ...
ttl_h = int(os.environ.get("GAP_CLAIM_TTL_HOURS", "2"))
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

# META-044: emit ambient ALERT when a META-* gap is reserved so high-priority
# process changes don't sit invisibly in a namespace the fleet ignores.
# Fleet pickup: META-* effort=xs|s with filled ACs are fleet-pickable (worker.sh).
if [[ "$DOMAIN" == "META" ]]; then
    _ambient="$LOCK_DIR/ambient.jsonl"
    printf '{"ts":"%s","session":"%s","event":"ALERT","kind":"meta_filed","gap_id":"%s","title":"%s","note":"META-* gap reserved — review for fleet pickup (effort xs|s with filled ACs are fleet-pickable per META-044)"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SESSION_ID" "$NEW_ID" "$TITLE" \
        >> "$_ambient" 2>/dev/null || true
    echo "[gap-reserve] INFO: emitted meta_filed alert to ambient.jsonl (META-044)" >&2
fi

# EVAL-086: stamp opened_date on new gaps so stall detection is expressible as
# a registry query. The Rust path currently leaves opened_date=''; patch it here
# under the same flock we already hold.
_db="$MAIN_REPO/.chump/state.db"
if [[ -f "$_db" ]]; then
    _today="$(date -u +%Y-%m-%d)"
    sqlite3 "$_db" "UPDATE gaps SET opened_date='$_today' WHERE id='$NEW_ID' AND (opened_date IS NULL OR opened_date='')" 2>/dev/null || true
    echo "[gap-reserve] INFO: stamped opened_date=$_today on $NEW_ID" >&2
fi
