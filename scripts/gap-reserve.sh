#!/usr/bin/env bash
# gap-reserve.sh — Atomically reserve the next free gap ID for a domain (INFRA-021).
#
# Scans docs/gaps.yaml on origin/main (falls back to working tree when offline),
# open PR diffs touching docs/gaps.yaml (via gh, optional), and live lease JSON
# files for gap_id + pending_new_gap.id collisions. Under a per-domain file lock,
# picks the next DOMAIN-NNN not in use, then writes pending_new_gap into this
# session's lease file.
#
# Usage:
#   scripts/gap-reserve.sh INFRA "title words here"
#   scripts/gap-reserve.sh EVAL "short title"
#
# Prints the reserved ID as the only stdout line; human messages go to stderr.
#
# Environment:
#   CHUMP_SESSION_ID / CLAUDE_SESSION_ID — same resolution order as gap-claim.sh
#   CHUMP_ALLOW_MAIN_WORKTREE=1 — allow running from the main worktree (testing)
#   CHUMP_GAP_RESERVE_SKIP_PR=1 — skip gh pr diff scan (CI / offline speed)
#   REMOTE / BASE — same as gap-preflight.sh (default origin/main)

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

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCK_DIR="$REPO_ROOT/.chump-locks"
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

git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || true

MAIN_TMP="$(mktemp)"
PR_TMP="$(mktemp)"
trap 'rm -f "$MAIN_TMP" "$PR_TMP"' EXIT

if ! git show "$REMOTE/$BASE:docs/gaps.yaml" >"$MAIN_TMP" 2>/dev/null; then
    cp "$REPO_ROOT/docs/gaps.yaml" "$MAIN_TMP" 2>/dev/null || {
        echo "[gap-reserve] ERROR: could not read docs/gaps.yaml (remote or local)." >&2
        exit 1
    }
    echo "[gap-reserve] WARN: using working-tree docs/gaps.yaml (could not read $REMOTE/$BASE:docs/gaps.yaml)." >&2
fi

: >"$PR_TMP"
if [[ "${CHUMP_GAP_RESERVE_SKIP_PR:-0}" != "1" ]] && command -v gh >/dev/null 2>&1; then
    while IFS= read -r prnum; do
        [[ -z "$prnum" ]] && continue
        gh pr diff "$prnum" -- docs/gaps.yaml 2>/dev/null >>"$PR_TMP" || true
    done < <(cd "$REPO_ROOT" && gh pr list --state open --json number --jq '.[].number' 2>/dev/null || true)
fi

python3 - "$FLOCK_PATH" "$DOMAIN" "$TITLE" "$SESSION_ID" "$LEASE_FILE" "$MAIN_TMP" "$PR_TMP" "$LOCK_DIR" <<'PY'
import fcntl, json, os, re, sys
from datetime import datetime, timezone

(
    flock_path,
    domain,
    title,
    session_id,
    lease_path,
    main_path,
    pr_path,
    lock_dir,
) = sys.argv[1:9]

fd = os.open(flock_path, os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    texts = [open(main_path, encoding="utf-8", errors="replace").read()]
    pr_extra = open(pr_path, encoding="utf-8", errors="replace").read()
    if pr_extra.strip():
        texts.append(pr_extra)

    used = set()
    id_re = re.compile(rf"^- id: ({re.escape(domain)}-\S+)\s*$", re.MULTILINE)
    for t in texts:
        for m in id_re.finditer(t):
            used.add(m.group(1))

    now = datetime.now(timezone.utc)
    for fname in os.listdir(lock_dir):
        if not fname.endswith(".json"):
            continue
        if fname.startswith(".") or fname == "ambient.jsonl":
            continue
        path = os.path.join(lock_dir, fname)
        try:
            with open(path, encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            continue
        try:
            expires = datetime.fromisoformat(d["expires_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
            heartbeat = datetime.fromisoformat(d["heartbeat_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
            grace = 30
            stale_secs = 900
            expired = (now - expires).total_seconds() > grace
            stale = (now - heartbeat).total_seconds() > stale_secs
            if expired or stale:
                continue
        except Exception:
            continue

        gid = d.get("gap_id")
        if isinstance(gid, str) and gid.startswith(f"{domain}-"):
            used.add(gid)
        p = d.get("pending_new_gap")
        if isinstance(p, dict):
            pid = p.get("id")
            if isinstance(pid, str) and pid.startswith(f"{domain}-"):
                used.add(pid)

    nums = []
    for g in used:
        m = re.match(rf"^{re.escape(domain)}-(\d+)$", g)
        if m:
            nums.append(int(m.group(1)))
    n = max(nums, default=0) + 1
    prop = f"{domain}-{n}"
    while prop in used:
        n += 1
        prop = f"{domain}-{n}"

    now_s = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ttl_h = int(os.environ.get("GAP_CLAIM_TTL_HOURS", "4"))
    # portable-ish +4h: delegate to same approach as gap-claim (best-effort)
    try:
        from datetime import timedelta

        exp = (now + timedelta(hours=ttl_h)).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        exp = now_s

    pending = {"id": prop, "title": title, "domain": domain}
    if os.path.isfile(lease_path):
        with open(lease_path, encoding="utf-8") as f:
            d = json.load(f)
    else:
        d = {
            "session_id": session_id,
            "paths": [],
            "taken_at": now_s,
            "expires_at": exp,
            "heartbeat_at": now_s,
            "purpose": f"gap-reserve:{prop}",
        }
    d["session_id"] = session_id
    d["pending_new_gap"] = pending
    d.setdefault("taken_at", now_s)
    d.setdefault("expires_at", exp)
    d.setdefault("heartbeat_at", now_s)
    d.setdefault("paths", [])
    with open(lease_path, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)
        f.write("\n")

    sys.stdout.write(prop + "\n")
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)
PY

echo "[gap-reserve] Wrote pending_new_gap → $LEASE_FILE (session $SESSION_ID)" >&2
