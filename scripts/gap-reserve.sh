#!/usr/bin/env bash
# gap-reserve.sh — atomically reserve the next numeric gap ID for a domain.
#
# Computes max(PREFIX-NNN) across origin/main docs/gaps.yaml, open PRs that
# touch docs/gaps.yaml, and live .chump-locks/*.json (gap_id + pending_new_gap),
# then writes pending_new_gap into this session's lease so gap-preflight.sh
# allows claiming the ID before the YAML row exists on main (INFRA-021).
#
# Usage:
#   scripts/gap-reserve.sh INFRA "short title for the pending gap"
#   scripts/gap-reserve.sh RESEARCH   # default title
#
# Environment:
#   CHUMP_SESSION_ID / CLAUDE_SESSION_ID — same resolution order as gap-claim.sh
#   CHUMP_LOCK_DIR   — override lock directory (tests; must match gap-preflight)
#   REMOTE / BASE     — same as gap-preflight.sh (default origin/main)
#   CHUMP_ALLOW_MAIN_WORKTREE — set to 1 to allow running from main worktree
#   GAP_CLAIM_TTL_HOURS — lease TTL written alongside the reservation (default 4)

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <DOMAIN> [TITLE...]" >&2
    echo "  DOMAIN: uppercase gap prefix (INFRA, EVAL, RESEARCH, ...)" >&2
    exit 1
fi

DOMAIN="$1"
shift
TITLE="${*:-"reserved (pending registry)"}"

if ! [[ "$DOMAIN" =~ ^[A-Z][A-Z0-9-]*$ ]]; then
    echo "[gap-reserve] ERROR: DOMAIN must match ^[A-Z][A-Z0-9-]*$ (got '$DOMAIN')" >&2
    exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"

# Main-worktree guard (same policy as gap-claim.sh)
_WT_LIST="$(git worktree list --porcelain)"
MAIN_WORKTREE_PATH="$(awk '/^worktree /{sub(/^worktree /,""); print; exit}' <<<"$_WT_LIST")"
if [[ "$REPO_ROOT" == "$MAIN_WORKTREE_PATH" ]] && [[ "${CHUMP_ALLOW_MAIN_WORKTREE:-0}" != "1" ]]; then
    printf '[gap-reserve] ERROR: refusing to reserve from the main worktree.\n' >&2
    printf '[gap-reserve] Use a linked worktree or CHUMP_ALLOW_MAIN_WORKTREE=1.\n' >&2
    exit 1
fi

SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    mkdir -p "$LOCK_DIR"
    WT_SESSION_CACHE="$LOCK_DIR/.wt-session-id"
    if [[ -f "$WT_SESSION_CACHE" ]]; then
        SESSION_ID="$(cat "$WT_SESSION_CACHE")"
    else
        SESSION_ID="chump-$(basename "$REPO_ROOT")-$(date +%s)"
        printf '%s' "$SESSION_ID" > "$WT_SESSION_CACHE"
    fi
fi
if [[ -z "$SESSION_ID" && -f "$HOME/.chump/session_id" ]]; then
    SESSION_ID="$(cat "$HOME/.chump/session_id" 2>/dev/null || true)"
fi
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="ephemeral-$$-$(date +%s)"
fi

SAFE_ID="${SESSION_ID//[^a-zA-Z0-9_-]/_}"
LOCK_FILE="$LOCK_DIR/${SAFE_ID}.json"
mkdir -p "$LOCK_DIR"

export DOMAIN TITLE REMOTE BASE LOCK_DIR LOCK_FILE SESSION_ID REPO_ROOT

# Single-writer lock per domain + compute next id + merge lease (fcntl — macOS/Linux).
if ! command -v python3 >/dev/null 2>&1; then
    echo "[gap-reserve] ERROR: python3 required" >&2
    exit 1
fi
python3 <<'PYRESERVE'
import fcntl, json, os, re, subprocess, sys
from datetime import datetime, timezone

domain = os.environ["DOMAIN"]
title = os.environ["TITLE"]
remote = os.environ.get("REMOTE", "origin")
base = os.environ.get("BASE", "main")
lock_dir = os.environ["LOCK_DIR"]
lock_file = os.environ["LOCK_FILE"]
session_id = os.environ["SESSION_ID"]
repo_root = os.environ["REPO_ROOT"]

def info(msg: str) -> None:
    print(f"[gap-reserve] {msg}", file=sys.stderr)

def safe_id(sid: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "_", sid)

def load_main_gaps_yaml() -> str:
    ref = f"{remote}/{base}:docs/gaps.yaml"
    try:
        return subprocess.check_output(
            ["git", "show", ref],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=60,
        )
    except Exception:
        pass
    try:
        with open(os.path.join(repo_root, "docs/gaps.yaml")) as f:
            return f.read()
    except Exception:
        return ""

def ids_from_yaml(text: str, prefix: str) -> list[int]:
    pat = re.compile(rf"^- id: {re.escape(prefix)}-(\d+)\s*$", re.MULTILINE)
    return [int(m.group(1)) for m in pat.finditer(text)]

def ids_from_pr_diffs(prefix: str) -> list[int]:
    nums: list[int] = []
    try:
        raw = subprocess.check_output(
            [
                "gh",
                "pr",
                "list",
                "--state",
                "open",
                "--json",
                "number",
                "--jq",
                ".[].number",
            ],
            cwd=repo_root,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=60,
        ).strip()
    except Exception:
        return nums
    pat = re.compile(rf"{re.escape(prefix)}-(\d+)")
    for line in raw.splitlines():
        num = line.strip()
        if not num.isdigit():
            continue
        try:
            diff = subprocess.check_output(
                ["gh", "pr", "diff", num, "--", "docs/gaps.yaml"],
                cwd=repo_root,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=60,
            )
        except Exception:
            continue
        for ln in diff.splitlines():
            if not ln.startswith("+"):
                continue
            nums.extend(int(m.group(1)) for m in pat.finditer(ln))
    return nums

def lease_alive(d: dict, now: datetime) -> bool:
    try:
        expires = datetime.fromisoformat(d["expires_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        heartbeat = datetime.fromisoformat(d["heartbeat_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        grace = 30
        stale_secs = 900
        if (now - expires).total_seconds() > grace:
            return False
        if (now - heartbeat).total_seconds() > stale_secs:
            return False
    except Exception:
        return False
    return True

def ids_from_leases(prefix: str, now: datetime) -> list[int]:
    pat = re.compile(rf"^{re.escape(prefix)}-(\d+)$")
    out: list[int] = []
    if not os.path.isdir(lock_dir):
        return out
    for fname in os.listdir(lock_dir):
        if not fname.endswith(".json"):
            continue
        path = os.path.join(lock_dir, fname)
        try:
            with open(path) as f:
                d = json.load(f)
        except Exception:
            continue
        if not lease_alive(d, now):
            continue
        gid = d.get("gap_id") or ""
        m = pat.match(gid)
        if m:
            out.append(int(m.group(1)))
        pend = d.get("pending_new_gap") or {}
        if isinstance(pend, dict):
            pid = pend.get("id") or ""
            m2 = pat.match(pid)
            if m2:
                out.append(int(m2.group(1)))
    return out

lock_path = os.path.join(lock_dir, f".gap-reserve-{domain}.lock")
os.makedirs(lock_dir, exist_ok=True)
with open(lock_path, "a") as lk:
    fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
    now = datetime.now(timezone.utc)
    text = load_main_gaps_yaml()
    nums = ids_from_yaml(text, domain)
    nums.extend(ids_from_pr_diffs(domain))
    nums.extend(ids_from_leases(domain, now))
    nxt = max(nums) + 1 if nums else 1
    next_id = f"{domain}-{nxt}"

    ttl_h = int(os.environ.get("GAP_CLAIM_TTL_HOURS", "4"))
    now_s = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    # naive UTC + ttl hours
    from datetime import timedelta

    exp = (now + timedelta(hours=ttl_h)).strftime("%Y-%m-%dT%H:%M:%SZ")

    if os.path.isfile(lock_file):
        with open(lock_file) as f:
            d = json.load(f)
    else:
        d = {
            "session_id": session_id,
            "paths": [],
            "taken_at": now_s,
            "expires_at": exp,
            "heartbeat_at": now_s,
            "purpose": "gap-reserve",
        }

    d["session_id"] = session_id
    d["heartbeat_at"] = now_s
    d["expires_at"] = exp
    d["pending_new_gap"] = {"id": next_id, "title": title, "domain": domain}
    with open(lock_file, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")

    info(f"Wrote pending_new_gap → {next_id} ({lock_file})")
    print(next_id)
PYRESERVE
