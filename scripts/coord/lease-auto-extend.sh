#!/usr/bin/env bash
# lease-auto-extend.sh — INFRA-1327: auto-extend near-expiry leases when an
# armed auto-merge PR exists for the gap.
#
# Problem: when an agent ships a gap (arms auto-merge), the lease expires after
# CHUMP_GAP_CLAIM_TTL_SECS. If GitHub merge takes longer than that window,
# another worker re-claims the gap and stomps the in-flight PR.
#
# Fix: this script reads all .chump-locks/claim-*.json leases; for any lease
# expiring in less than CHUMP_LEASE_EXTEND_THRESHOLD_S (default 1800s = 30min),
# it checks whether the gap has an open PR with auto-merge armed. If so, it
# rewrites expires_at to now + CHUMP_GAP_CLAIM_TTL_SECS and emits
# kind=lease_auto_extended to ambient.jsonl.
#
# Usage:
#   scripts/coord/lease-auto-extend.sh            # run once
#   scripts/coord/lease-auto-extend.sh --dry-run  # show what would extend
#
# Integration: call from the worker loop (scripts/dispatch/worker.sh) every
# ~300s (once per iteration), or from a launchd plist / cron at 5-min cadence.
#
# Env:
#   CHUMP_LEASE_EXTEND_THRESHOLD_S   — seconds before expiry to trigger extend
#                                       (default 1800 = 30 min)
#   CHUMP_GAP_CLAIM_TTL_SECS         — how long to extend to (default 14400 = 4h)
#   CHUMP_CACHE_DB                   — override path to github_cache.db
#   CHUMP_AMBIENT_LOG                — override path to ambient.jsonl
#   CHUMP_LOCK_DIR                   — override path to .chump-locks/
#   CHUMP_REPO_OWNER                 — GitHub repo owner (falls back to gh repo view)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config ────────────────────────────────────────────────────────────────────
EXTEND_THRESHOLD_S="${CHUMP_LEASE_EXTEND_THRESHOLD_S:-1800}"
CLAIM_TTL_S="${CHUMP_GAP_CLAIM_TTL_SECS:-14400}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
CACHE_LIB="$SCRIPT_DIR/lib/github_cache.sh"

# Source the cache lib if available (provides cache_lookup_pr_by_branch).
if [[ -f "$CACHE_LIB" ]]; then
    # shellcheck source=lib/github_cache.sh
    source "$CACHE_LIB"
    _CACHE_LIB_LOADED=1
else
    _CACHE_LIB_LOADED=0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_emit() {
    # _emit <json-fields>
    printf '%s\n' "$1" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# iso8601_to_epoch: convert "2026-05-15T12:00:00Z" → unix seconds.
# Prefers Python (handles UTC correctly on both GNU/BSD), falls back to GNU date.
iso8601_to_epoch() {
    local iso="$1"
    # Python: most reliable — handles the Z suffix as UTC on all platforms.
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
from datetime import datetime, timezone
s = '${iso}'.replace('Z','')
dt = datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
print(int(dt.timestamp()))
" 2>/dev/null && return
    fi
    # GNU date (Linux) — only if python3 unavailable.
    date -d "$iso" +%s 2>/dev/null && return
    echo 0
}

# epoch_to_iso8601: convert unix seconds → "2026-05-15T12:00:00Z"
epoch_to_iso8601() {
    local epoch="$1"
    # GNU date
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return
    # BSD date (macOS)
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return
    # Python fallback
    python3 -c "
import sys
from datetime import datetime, timezone
print(datetime.fromtimestamp($epoch, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo ""
}

# derive_branch_from_gap_id: "INFRA-1327" → "chump/infra-1327-claim"
derive_branch_from_gap_id() {
    local gap_id="$1"
    local lower; lower="$(printf '%s' "$gap_id" | tr '[:upper:]' '[:lower:]')"
    printf 'chump/%s-claim' "$lower"
}

# get_repo_slug: return "owner/repo" for gh API calls, or "" on failure.
# Override via CHUMP_REPO_SLUG env var (useful for tests / offline scenarios).
_repo_slug=""
get_repo_slug() {
    if [[ -n "$_repo_slug" ]]; then printf '%s' "$_repo_slug"; return 0; fi
    if [[ -n "${CHUMP_REPO_SLUG:-}" ]]; then
        _repo_slug="$CHUMP_REPO_SLUG"
        printf '%s' "$_repo_slug"
        return 0
    fi
    _repo_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    printf '%s' "$_repo_slug"
}

# is_auto_merge_armed_via_cache <branch> → stdout: pr_number or ""
# Returns 0 if an armed open PR was found, 1 otherwise.
is_auto_merge_armed_via_cache() {
    local branch="$1"
    if [[ "$_CACHE_LIB_LOADED" -eq 1 ]]; then
        local payload
        payload="$(cache_lookup_pr_by_branch "$branch" 2>/dev/null || true)"
        if [[ -n "$payload" ]]; then
            local pr_num auto_merge state
            pr_num="$(printf '%s' "$payload" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('number',''))" 2>/dev/null || true)"
            auto_merge="$(printf '%s' "$payload" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); am=d.get('auto_merge'); print('armed' if am else 'null')" 2>/dev/null || true)"
            state="$(printf '%s' "$payload" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('state',''))" 2>/dev/null || true)"
            if [[ "$auto_merge" == "armed" && "$state" == "open" ]]; then
                printf '%s' "$pr_num"
                return 0
            fi
        fi
    fi
    return 1
}

# is_auto_merge_armed_via_rest <branch> → stdout: pr_number or ""
# Returns 0 if an armed open PR was found, 1 otherwise.
is_auto_merge_armed_via_rest() {
    local branch="$1"
    local slug; slug="$(get_repo_slug)"
    [[ -z "$slug" ]] && return 1

    local owner="${slug%%/*}"
    local resp
    resp="$(gh api "repos/${slug}/pulls?head=${owner}:${branch}&state=open" 2>/dev/null || true)"
    [[ -z "$resp" ]] && return 1

    python3 - "$resp" <<'PY'
import sys, json
prs = json.loads(sys.argv[1])
for pr in prs:
    if pr.get("auto_merge") is not None and pr.get("state") == "open":
        print(pr["number"])
        sys.exit(0)
sys.exit(1)
PY
}

# ── Main loop ─────────────────────────────────────────────────────────────────
NOW_S=$(date +%s)
extended_count=0
skipped_count=0
no_pr_count=0

for lease_file in "$LOCK_DIR"/claim-*.json; do
    [[ -f "$lease_file" ]] || continue

    lease_base="$(basename "$lease_file")"

    # Parse gap_id and expires_at from lease JSON.
    gap_id=""
    expires_at_iso=""
    if command -v python3 >/dev/null 2>&1; then
        _parsed="$(python3 - "$lease_file" <<'PY' 2>/dev/null || true
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("gap_id",""))
    print(d.get("expires_at",""))
except Exception:
    print("")
    print("")
PY
)"
        gap_id="$(printf '%s' "$_parsed" | head -1)"
        expires_at_iso="$(printf '%s' "$_parsed" | tail -1)"
    else
        # Fallback: grep for simple values (no jq dependency)
        gap_id="$(grep -o '"gap_id":[[:space:]]*"[^"]*"' "$lease_file" 2>/dev/null \
            | sed 's/.*"gap_id":[[:space:]]*"\([^"]*\)".*/\1/' | head -1 || true)"
        expires_at_iso="$(grep -o '"expires_at":[[:space:]]*"[^"]*"' "$lease_file" 2>/dev/null \
            | sed 's/.*"expires_at":[[:space:]]*"\([^"]*\)".*/\1/' | head -1 || true)"
    fi

    if [[ -z "$gap_id" || -z "$expires_at_iso" ]]; then
        printf '[lease-auto-extend] SKIP %s: missing gap_id or expires_at\n' "$lease_base" >&2
        ((skipped_count++))
        continue
    fi

    # Skip leases that already have plenty of time left.
    expires_s="$(iso8601_to_epoch "$expires_at_iso")"
    if ! [[ "$expires_s" =~ ^[0-9]+$ ]]; then
        printf '[lease-auto-extend] SKIP %s: cannot parse expires_at=%s\n' "$lease_base" "$expires_at_iso" >&2
        ((skipped_count++))
        continue
    fi

    remaining_s=$(( expires_s - NOW_S ))
    if [[ "$remaining_s" -gt "$EXTEND_THRESHOLD_S" ]]; then
        printf '[lease-auto-extend] SKIP %s (%s): %ss remaining > threshold %ss\n' \
            "$lease_base" "$gap_id" "$remaining_s" "$EXTEND_THRESHOLD_S" >&2
        ((skipped_count++))
        continue
    fi

    # Derive branch name from gap_id (lease JSON may not have a branch field).
    branch="$(derive_branch_from_gap_id "$gap_id")"

    # Check for armed auto-merge PR: try cache first, then REST fallback.
    pr_number=""
    if pr_number="$(is_auto_merge_armed_via_cache "$branch" 2>/dev/null)"; then
        :  # cache hit with armed PR
    elif pr_number="$(is_auto_merge_armed_via_rest "$branch" 2>/dev/null)"; then
        :  # REST hit with armed PR
    else
        printf '[lease-auto-extend] SKIP %s (%s): no armed auto-merge PR on branch %s\n' \
            "$lease_base" "$gap_id" "$branch" >&2
        ((no_pr_count++))
        continue
    fi

    [[ -z "$pr_number" ]] && { ((no_pr_count++)); continue; }

    # Armed PR found and lease is near-expiry — extend it.
    new_expires_s=$(( NOW_S + CLAIM_TTL_S ))
    new_expires_iso="$(epoch_to_iso8601 "$new_expires_s")"

    if [[ -z "$new_expires_iso" ]]; then
        printf '[lease-auto-extend] ERROR %s (%s): could not format new expires_at\n' \
            "$lease_base" "$gap_id" >&2
        continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[lease-auto-extend] DRY-RUN: would extend %s (%s) PR#%s → expires_at=%s\n' \
            "$lease_base" "$gap_id" "$pr_number" "$new_expires_iso"
        ((extended_count++))
        continue
    fi

    # Rewrite expires_at in the lease file (atomic write via temp file).
    tmp_file="$(mktemp "${lease_file}.tmp.XXXXXX")"
    if python3 - "$lease_file" "$new_expires_iso" "$tmp_file" <<'PY' 2>/dev/null; then
import sys, json
lease_path, new_expires, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(lease_path) as f:
    content = f.read()
d = json.loads(content)
d["expires_at"] = new_expires
# Re-serialise preserving field order as close as possible (Python 3.7+ dicts are ordered).
out = "{\n"
for i, (k, v) in enumerate(d.items()):
    comma = "," if i < len(d) - 1 else ""
    out += f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}{comma}\n"
out += "}\n"
with open(out_path, "w") as f:
    f.write(out)
PY
        mv -f "$tmp_file" "$lease_file"
        printf '[lease-auto-extend] EXTENDED %s (%s) PR#%s → expires_at=%s\n' \
            "$lease_base" "$gap_id" "$pr_number" "$new_expires_iso"
        # Emit ambient event.
        _emit "$(printf \
            '{"ts":"%s","kind":"lease_auto_extended","gap_id":"%s","pr_number":%s,"new_expires":"%s","reason":"auto_merge_armed","lease":"%s"}' \
            "$(_ts)" "$gap_id" "$pr_number" "$new_expires_iso" "$lease_base")"
        ((extended_count++))
    else
        rm -f "$tmp_file" 2>/dev/null || true
        printf '[lease-auto-extend] ERROR %s (%s): failed to rewrite lease JSON\n' \
            "$lease_base" "$gap_id" >&2
    fi
done

printf '[lease-auto-extend] done: extended=%d skipped=%d no_armed_pr=%d\n' \
    "$extended_count" "$skipped_count" "$no_pr_count"
