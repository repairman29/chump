#!/usr/bin/env bash
# gap-preflight.sh — Verify gap IDs are still open/unclaimed before starting work.
#
# Run this BEFORE claiming a gap or starting work on a new branch. It checks:
#   1. docs/gaps.yaml on origin/main — if status:done, abort (work already landed).
#   2. .chump-locks/*.json — if another live session has the same gap_id (or the
#      same pending_new_gap.id from gap-reserve.sh), abort.
#
# The old in_progress/claimed_by/claimed_at YAML fields are gone. Claims now
# live in lease files (.chump-locks/<session>.json) so there are zero merge
# conflicts and stale claims auto-expire with the session TTL.
#
# INFRA-186/INFRA-187: Branch and worktree naming — both conventions accepted.
# Canonical naming is chump/* (new standard per INFRA-186), but claude/* and
# other tool prefixes remain supported for backward compatibility. This script
# has no branch-name enforcement; git and bot-merge.sh handle that.
#
# Usage:
#   scripts/coord/gap-preflight.sh GAP-ID [GAP-ID ...]
#   scripts/coord/gap-preflight.sh AUTO-003 COMP-002
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
#   CHUMP_LOCK_DIR    override `.chump-locks/` path (tests; must match gap-claim)

set -euo pipefail

# INFRA-379: heal a wedged chump binary before any CLI call (see
# scripts/lib/chump-preflight.sh). Silent no-op on healthy binaries.
# shellcheck source=../lib/chump-preflight.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/chump-preflight.sh"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID [GAP-ID ...]" >&2
    exit 0
fi

REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
# INFRA-109: resolve REPO_ROOT + LOCK_DIR via main-repo path (linked worktree safe).
# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"

SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    # Prefer the worktree-scoped session ID cached by gap-claim.sh over the
    # machine-scoped $HOME/.chump/session_id — avoids false "already claimed"
    # positives when multiple sessions share the machine ID.
    _WT_CACHE="$LOCK_DIR/.wt-session-id"
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

# INFRA-590: print error + doc link, then set FAILED=1 (caller decides exit).
warn_with_help() {
    local msg="$1" anchor="$2"
    red "ERROR: $msg"
    red "See: docs/process/CLAUDE_GOTCHAS.md#${anchor}"
}

# ── 1. Fetch origin/main (for done-check) ────────────────────────────────────
git fetch "$REMOTE" "$BASE" --quiet 2>/dev/null || {
    info "WARN: could not fetch $REMOTE/$BASE — skipping remote done-check (offline?)"
    GAPS_YAML=""
}

# INFRA-188: load gap YAML from per-file directory or monolithic file.
# Returns concatenated YAML text in the monolithic format (gaps:\n- id: ...\n).
_load_gaps_yaml_from_ref() {
    local ref="$1"  # e.g. "origin/main"
    # Try per-file layout first (post-INFRA-188 canonical)
    local per_file_list
    per_file_list=$(git ls-tree --name-only -r "$ref" "docs/gaps/" 2>/dev/null \
        | grep '\.yaml$' | sort || true)
    if [[ -n "$per_file_list" ]]; then
        echo "gaps:"
        while IFS= read -r f; do
            git show "${ref}:${f}" 2>/dev/null | sed 's/^$//' | grep -v '^$' || true
            echo ""
        done <<< "$per_file_list"
        return
    fi
    # Fall back to monolithic
    git show "${ref}:docs/gaps.yaml" 2>/dev/null || true
}

_load_gaps_yaml_local() {
    local root="$1"
    # Try per-file layout first
    local gaps_dir="$root/docs/gaps"
    if [[ -d "$gaps_dir" ]]; then
        echo "gaps:"
        for f in "$gaps_dir"/*.yaml; do
            [[ -f "$f" ]] || continue
            # Strip blank lines at end of each file
            grep -v '^$' "$f" 2>/dev/null || true
            echo ""
        done
        return
    fi
    # Fall back to monolithic
    cat "$root/docs/gaps.yaml" 2>/dev/null || true
}

GAPS_YAML_REMOTE="${GAPS_YAML:-$(_load_gaps_yaml_from_ref "$REMOTE/$BASE" 2>/dev/null || true)}"
LOCAL_GAPS_YAML=""
if [[ -n "$REPO_ROOT" ]]; then
    LOCAL_GAPS_YAML="$(_load_gaps_yaml_local "$REPO_ROOT" 2>/dev/null || true)"
fi

# Prefer origin/main for "done" truth. If fetch/git-show failed (offline, shallow
# clone), fall back to the working-tree copy so unregistered-ID enforcement
# (INFRA-020) still runs instead of silently skipping check 1.
GAPS_YAML="$GAPS_YAML_REMOTE"
if [[ -z "$GAPS_YAML" && -n "$LOCAL_GAPS_YAML" ]]; then
    GAPS_YAML="$LOCAL_GAPS_YAML"
    info "WARN: using working-tree gap registry for gap ID lookup (could not read $REMOTE/$BASE)."
fi

# True when this session's lease already reserves gap_id via pending_new_gap (INFRA-021).
# INFRA-344: also accepts when gap_id is set directly in the lease (post-claim, after
# gap-claim.sh removes pending_new_gap and writes gap_id instead).
my_pending_reserves_gap() {
    local gap_id="$1"
    [[ -n "$SESSION_ID" ]] || return 1
    local safe="${SESSION_ID//[^a-zA-Z0-9_-]/_}"
    local lf="$LOCK_DIR/${safe}.json"
    [[ -f "$lf" ]] || return 1
    python3 - "$lf" "$gap_id" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    p = d.get("pending_new_gap") or {}
    # pre-claim: pending_new_gap.id matches; post-claim: gap_id matches (gap-claim.sh
    # moves pending_new_gap → gap_id, so the session still owns this gap — INFRA-344)
    if p.get("id") == sys.argv[2] or d.get("gap_id") == sys.argv[2]:
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
PYEOF
}

# INFRA-344: True when the gap exists in the local state.db with status=open/in_progress.
# Used as a defense-in-depth check for filing-style PRs: the gap is reserved locally
# (chump gap reserve wrote it to state.db) but not yet on origin/main.  This catches
# the case where the session-ID path doesn't line up (e.g. a different chump-anon-*
# lease owns the pending_new_gap but the current session already ran gap-claim.sh
# under its own ID).
gap_locally_open() {
    local gap_id="$1"
    # CHUMP_STATE_DB overrides the default path (used by tests to avoid reading prod DB).
    local db="${CHUMP_STATE_DB:-${REPO_ROOT:+$REPO_ROOT/.chump/state.db}}"
    [[ -n "$db" && -f "$db" ]] || return 1
    command -v sqlite3 >/dev/null 2>&1 || return 1
    local status
    # Single-quote the ID; gap IDs are ASCII-only so no escaping risk here.
    status=$(sqlite3 "$db" "SELECT status FROM gaps WHERE id='${gap_id}' LIMIT 1;" 2>/dev/null || true)
    [[ "$status" == "open" || "$status" == "in_progress" ]]
}

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
#
# INFRA-193 (speculative execution): if the CALLER is speculative
# (CHUMP_SPECULATIVE=1) AND the existing claim is also marked
# `"speculative": true`, the conflict is allowed — both sessions race in
# parallel and first-to-land wins. Any non-speculative collision still
# blocks: exclusive lease semantics remain the safe default.
check_lease_claim() {
    local gap_id="$1"
    local my_session="$2"
    local my_speculative="${CHUMP_SPECULATIVE:-0}"
    [[ -d "$LOCK_DIR" ]] || return 0

    python3 - "$LOCK_DIR" "$gap_id" "$my_session" "$my_speculative" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

lock_dir, gap_id, my_session, my_spec = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
now = datetime.now(timezone.utc)
my_spec = my_spec == "1"

for fname in os.listdir(lock_dir):
    if not fname.endswith(".json"):
        continue
    path = os.path.join(lock_dir, fname)
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue

    mine = d.get("session_id", "") == my_session
    held = False
    if d.get("gap_id") == gap_id:
        held = True
    p = d.get("pending_new_gap")
    pending_only = False
    if isinstance(p, dict) and p.get("id") == gap_id:
        held = True
        # INFRA-322: distinguish "real claim" from "reserve-transaction artifact".
        # A real claim sets gap_id (via gap-claim.sh); a chump-anon-* lease
        # with ONLY pending_new_gap is the transient artifact that
        # `chump gap reserve` leaves behind for ~1 hour. Those should not
        # block a real session from claiming the same gap (the reserve
        # transaction is already complete; the lease is dead weight).
        sid = d.get("session_id", "")
        if d.get("gap_id") in (None, "", gap_id) and sid.startswith("chump-anon-"):
            pending_only = True
    if not held:
        continue
    if mine:
        continue
    if pending_only:
        sys.stderr.write(
            f"[gap-preflight] INFRA-322: ignoring chump-anon reserve-artifact lease "
            f"'{d.get('session_id', '?')}' on {gap_id} (no real claim).\n"
        )
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

    # INFRA-193: speculative-on-speculative is NOT a conflict — both race.
    other_spec = bool(d.get("speculative"))
    if my_spec and other_spec:
        # Surface as advisory note so the operator sees the race
        sys.stderr.write(
            f"[gap-preflight] INFRA-193 speculative race: '{d['session_id']}' is also "
            f"working on {gap_id} (both speculative). First-to-land wins.\n"
        )
        continue

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
    local ambient="$LOCK_DIR/ambient.jsonl"
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

# ── INFRA-1069: hot-file serialize list helpers ───────────────────────────────
# Read hot-files.yaml serialize: list.  Cached on first call.
_HF_YAML="${CHUMP_HOT_FILES_YAML:-$REPO_ROOT/scripts/coord/hot-files.yaml}"
_HF_SERIALIZE_CACHE=""

_hf_load_serialize() {
    [[ -r "$_HF_YAML" ]] || return 0
    _HF_SERIALIZE_CACHE="$(awk '
        /^serialize:/ { in_s=1; next }
        /^[a-zA-Z]/ && !/^serialize:/ { in_s=0 }
        in_s && /^[[:space:]]+- / {
            sub(/^[[:space:]]+- /, "")
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            if (length > 0) print
        }
    ' "$_HF_YAML")"
}

# Returns 0 (true) if the given file path matches a serializing hot file.
_hf_is_serializing() {
    local file="$1"
    [[ -n "$_HF_SERIALIZE_CACHE" ]] || _hf_load_serialize
    [[ -n "$_HF_SERIALIZE_CACHE" ]] || return 1
    while IFS= read -r hot; do
        [[ -z "$hot" ]] && continue
        # Exact match OR file is under a serialized directory prefix.
        if [[ "$file" == "$hot" || "$file" == "$hot/"* ]]; then
            return 0
        fi
    done <<< "$_HF_SERIALIZE_CACHE"
    return 1
}

# Emit kind=hot_file_contention to ambient.jsonl.
_emit_hot_file_contention() {
    local gap_id="$1" pr_ref="$2" hot_file="$3"
    local ambient="$LOCK_DIR/ambient.jsonl"
    printf '{"ts":"%s","kind":"hot_file_contention","gap_id":"%s","pr":"%s","file":"%s","note":"preflight blocked: serializing hot file already claimed by open PR"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$gap_id" "$pr_ref" "$hot_file" \
        >> "$ambient" 2>/dev/null || true
}

# ── Check 4: open PR file-scope overlap ──────────────────────────────────────
# Returns one of:
#   "HOT:#<N> (<branch>)|<file>"   — overlap on a serializing hot file (BLOCK)
#   "#<N> (<branch>)"              — generic overlap (WARN)
#   ""                             — no overlap
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
                # INFRA-1069: check if any overlapping file is in the serialize list.
                local hot_file=""
                if [[ "${CHUMP_HOT_FILE_PREFLIGHT_CHECK:-1}" != "0" ]]; then
                    local _pf
                    while IFS= read -r _pf; do
                        [[ -z "$_pf" ]] && continue
                        if [[ "$_pf" == "$prefix"* ]] && _hf_is_serializing "$_pf"; then
                            hot_file="$_pf"
                            break
                        fi
                    done < <(echo "$prfiles" | tr ',' '\n')
                fi
                if [[ -n "$hot_file" ]]; then
                    printf 'HOT:#%s (%s)|%s\n' "$prnum" "$prbranch" "$hot_file"
                else
                    printf '#%s (%s)\n' "$prnum" "$prbranch"
                fi
                return 0
            fi
        done
    done <<< "$PR_DATA"
}

# ── Check 5: fetch gap YAML from sibling branches ──────────────────────────
# FLEET-036: auto-fetch gap YAML from sibling branches before preflight reject.
# When a gap_id is not found on origin/main, search sibling branches for the
# gap definition and return concatenated YAML if found.
# Optimization: try per-file direct fetch first (fast), skip slower fallback for
# efficiency. If a gap is on a branch, it should already use per-file layout
# (post-INFRA-188).
_fetch_gap_from_sibling_branches() {
    local gap_id="$1"
    local remote="${2:-origin}"

    # Get list of remote branches, excluding the base branch itself.
    # Limit to 50 branches to avoid excessive git operations for bogus IDs.
    local branch_list
    branch_list=$(git branch -r --list "${remote}/*" --format='%(refname:short)' 2>/dev/null | \
        grep -v "^${remote}/${BASE}$" | head -50 || true)
    [[ -n "$branch_list" ]] || return 0

    # For each sibling branch, try to fetch the gap YAML directly from per-file layout.
    # INFRA-188 means all branches post-cutover use per-file layout; this check should
    # be fast (git cat-file is a near-instant inode check).
    while IFS= read -r branch; do
        if git cat-file -e "${branch}:docs/gaps/${gap_id}.yaml" 2>/dev/null; then
            git show "${branch}:docs/gaps/${gap_id}.yaml" 2>/dev/null || true
            return 0
        fi
    done <<< "$branch_list"
}

for GAP_ID in "$@"; do
    # FLEET-036: Before checking status, try to fetch gap YAML from sibling branches
    # if not found on origin/main. This allows dispatch to pick up gaps filed on
    # feature branches before they land on main.
    if [[ -z "$(gap_status "$GAP_ID")" ]]; then
        SIBLING_GAP_YAML="$(_fetch_gap_from_sibling_branches "$GAP_ID" "$REMOTE")"
        if [[ -n "$SIBLING_GAP_YAML" ]]; then
            info "NOTE: $GAP_ID found on sibling branch (FLEET-036) — fetching gap definition."
            # Append to GAPS_YAML so gap_status() can find it
            GAPS_YAML="$GAPS_YAML
$SIBLING_GAP_YAML"
        fi
    fi

    # ── Check 1: done on main / registered ─────────────────────────────────
    # INFRA-499: post-INFRA-498 docs/gaps/*.yaml is empty so GAPS_YAML is
    # always empty too. Registration check now defers to state.db via
    # `chump gap preflight <ID>`, which is canonical anyway. The legacy
    # "if -n GAPS_YAML" block is preserved as a fallback for any
    # pre-deletion checkout.
    STATUS=""
    if [[ -n "$GAPS_YAML" ]]; then
        STATUS="$(gap_status "$GAP_ID")"
        if [[ "$STATUS" == "done" ]]; then
            red "SKIP $GAP_ID — already status:done on $REMOTE/$BASE."
            red "  The work exists. No need to re-implement. Choose a different gap."
            FAILED=1
            continue
        fi
    fi
    if [[ -z "$STATUS" ]]; then
        # No status from YAML — check state.db (canonical post-INFRA-498).
        if my_pending_reserves_gap "$GAP_ID"; then
            info "NOTE: $GAP_ID matches session lease (pending_new_gap or gap_id) — OK (INFRA-021/INFRA-344)."
        elif _pf_out="$(chump gap preflight "$GAP_ID" 2>&1)" \
                && echo "$_pf_out" | grep -q '\[preflight\] OK'; then
            # INFRA-168 / INFRA-499: gap exists in local state.db with
            # status=open. Canonical path post-INFRA-498.
            info "NOTE: $GAP_ID found open in local state.db — OK (INFRA-168/INFRA-499)."
        elif gap_locally_open "$GAP_ID"; then
            info "NOTE: $GAP_ID exists in local state.db with status=open — OK (INFRA-344: filing-style PR)."
        elif [[ "${CHUMP_ALLOW_UNREGISTERED_GAP:-0}" == "1" ]]; then
            info "WARN: $GAP_ID not in registry — CHUMP_ALLOW_UNREGISTERED_GAP=1, proceeding."
        else
            red "SKIP $GAP_ID — not found in gap registry (state.db is canonical post-INFRA-498)."
            red "  Reserve an ID first: chump gap reserve --domain D --title T"
            red "  (atomic; writes pending_new_gap to your lease). Two agents inventing"
            red "  the same ID was the INFRA-016/017/018 collision chain (2026-04-20)."
            red "  Bootstrap escape hatch: CHUMP_ALLOW_UNREGISTERED_GAP=1"
            FAILED=1
            continue
        fi
    fi

    # ── Check 1.5: open PR with this gap-ID in title (INFRA-273) ──────────
    # Caught during the 2026-05-02 dogfood fleet run: 2 fleet workers picked
    # INFRA-261 even though PR #874 ("INFRA-261: ...") was already OPEN+armed.
    # gap-preflight had no idea because Check 1 only looks at the registry's
    # status:done state, and PR #874 hadn't merged yet. Both workers spent
    # claude -p quota on a gap that was actively being shipped — pure waste.
    #
    # This check searches open PRs by exact gap-ID match in title and blocks
    # the claim if found, unless:
    #   - CHUMP_PREFLIGHT_PR_CHECK=0 (operator opt-out)
    #   - CHUMP_SPECULATIVE=1        (INFRA-193 speculative race wanted)
    if [[ "${CHUMP_PREFLIGHT_PR_CHECK:-1}" != "0" ]] \
            && command -v gh >/dev/null 2>&1; then
        _PR_QUERY="$(gh pr list --state open --search "${GAP_ID} in:title" \
            --json number,headRefName,autoMergeRequest -q '.[0]' 2>/dev/null || true)"
        if [[ -n "$_PR_QUERY" && "$_PR_QUERY" != "null" && "$_PR_QUERY" != "{}" ]]; then
            PR_NUM="$(printf '%s' "$_PR_QUERY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("number",""))' 2>/dev/null)"
            PR_HEAD="$(printf '%s' "$_PR_QUERY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("headRefName",""))' 2>/dev/null)"
            _PR_ARMED="$(printf '%s' "$_PR_QUERY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("armed" if d.get("autoMergeRequest") else "open")' 2>/dev/null)"
            # Skip if it's our OWN branch (we're re-running preflight on the same work).
            CURRENT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
            if [[ -n "$PR_NUM" && "$PR_HEAD" != "$CURRENT_BRANCH" ]]; then
                if [[ "${CHUMP_SPECULATIVE:-0}" != "1" ]]; then
                    # See: docs/process/CLAUDE_GOTCHAS.md#error-gap-collision
                    warn_with_help "SKIP $GAP_ID — open PR #$PR_NUM ($PR_HEAD) [$_PR_ARMED] is already implementing this gap. Pick a different gap, or wait for #$PR_NUM to land/close." "error-gap-collision"
                    red "  Bypass: CHUMP_PREFLIGHT_PR_CHECK=0 (skip this check)"
                    red "  Or: CHUMP_SPECULATIVE=1 (race against the existing PR per INFRA-193)"
                    FAILED=1
                    continue
                else
                    # INFRA-684: speculative mode — show the spec-lease holder.
                    # If the existing PR is already armed, the race is decided.
                    info "SPEC-LEASE: PR #$PR_NUM ($PR_HEAD) holds the open impl for $GAP_ID [$_PR_ARMED]."
                    if [[ "$_PR_ARMED" == "armed" ]]; then
                        warn_with_help "SKIP $GAP_ID — PR #$PR_NUM is already armed for auto-merge (spec race decided). Racing into an armed PR wastes quota — the winner is #$PR_NUM." "error-gap-collision"
                        red "  If PR #$PR_NUM is abandoned, bypass: CHUMP_SPECULATIVE=1 CHUMP_PREFLIGHT_PR_CHECK=0"
                        FAILED=1
                        continue
                    fi
                    info "  Spec race still open — PR #$PR_NUM not yet armed. Proceeding with speculative claim."
                fi
            fi
        fi
    fi

    # ── Check 1.6: NATS KV cross-machine lease (FLEET-032 Phase 1) ───────────
    # FLEET-032 Phase 1: dual-write pattern for cross-machine visibility.
    # gap-claim.sh writes to BOTH:
    #   1. .chump-locks/<session>.json (same-machine, file-based)
    #   2. NATS KV (cross-machine, atomic via chump-coord)
    #
    # gap-preflight.sh reads from BOTH stores and unions claim sets:
    #   - Check 1.6 (NATS): whois query for NATS KV claims (cross-host visible)
    #   - Check 2 (file): check_lease_claim() for .chump-locks/ (same-host visible)
    #   - Union: either source blocking means the gap is unavailable
    #
    # If chump-coord is unavailable or NATS unreachable, NATS check returns
    # empty (no-op); file-based check still runs. Coordination is sound even
    # when NATS is down — fleet simply falls back to same-machine only.
    #
    # Bypass:
    #   CHUMP_PREFLIGHT_NATS_CHECK=0 (skip NATS union, local-only)
    #   CHUMP_SPECULATIVE=1          (INFRA-193 race wanted)
    if [[ "${CHUMP_PREFLIGHT_NATS_CHECK:-1}" != "0" ]] \
            && [[ "${CHUMP_SPECULATIVE:-0}" != "1" ]] \
            && command -v chump-coord >/dev/null 2>&1; then
        NATS_HOLDER="$(chump-coord whois "$GAP_ID" 2>/dev/null || true)"
        # Strip whitespace; empty means no claim (or NATS unreachable).
        NATS_HOLDER="${NATS_HOLDER//[[:space:]]/}"
        if [[ -n "$NATS_HOLDER" && "$NATS_HOLDER" != "$SESSION_ID" ]]; then
            red "SKIP $GAP_ID — NATS KV claim held by session '$NATS_HOLDER' (cross-machine visible)."
            red "  This is another machine's claim — union of NATS KV + .chump-locks/ blocks this gap."
            red "  Coordinate with that session or wait for the claim to expire (NATS KV TTL)."
            red "  Bypass: CHUMP_PREFLIGHT_NATS_CHECK=0 (skip cross-machine check)"
            red "  Or: CHUMP_SPECULATIVE=1 (race per INFRA-193)"
            FAILED=1
            continue
        fi
    fi

    # ── INFRA-524: atomic-picker self-lock bypass ──────────────────────────
    # _pick_and_claim_gap.py writes .gap-<ID>.lock with "session_id timestamp"
    # before returning the gap to the worker. If this session wrote the lock,
    # the gap is already ours — skip check_lease_claim to prevent the race
    # where the worker claims via the lock file then immediately fails preflight
    # when run inside the spawned agent's pre-flight (different CLAUDE_SESSION_ID
    # but same CHUMP_SESSION_ID, so the JSON lease looks like a foreign claim).
    _gap_lock_file="$LOCK_DIR/.gap-${GAP_ID}.lock"
    if [[ -f "$_gap_lock_file" ]] && [[ -n "$SESSION_ID" ]]; then
        _gap_lock_session="$(awk 'NR==1{print $1}' "$_gap_lock_file" 2>/dev/null || true)"
        if [[ "$_gap_lock_session" == "$SESSION_ID" ]]; then
            green "OK $GAP_ID — .gap-lock owned by this session; skip lease check (INFRA-524)."
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
        if [[ "$PR_CONFLICT" == HOT:* ]]; then
            # INFRA-1069: serializing hot file — BLOCK to prevent expensive rebase rounds.
            _pr_ref="${PR_CONFLICT#HOT:}"
            _pr_ref="${_pr_ref%%|*}"
            _hot_f="${PR_CONFLICT##*|}"
            red "BLOCK $GAP_ID — open PR $_pr_ref holds a serializing hot file: '$_hot_f'"
            red "  This file is in hot-files.yaml serialize: list — parallel PRs touching it"
            red "  force N-1 expensive rebase rounds (INFRA-1069 audit: up to 6 concurrent)."
            red "  Wait for $_pr_ref to land, or coordinate with its author."
            red "  Bypass: CHUMP_HOT_FILE_PREFLIGHT_CHECK=0 (use only if paths are disjoint)"
            _emit_hot_file_contention "$GAP_ID" "$_pr_ref" "$_hot_f"
            FAILED=1
        else
            info "WARN: $GAP_ID — open PR $PR_CONFLICT touches the same file domain."
            info "  Domain: $(_gap_files "$GAP_ID")"
            info "  Merge or coordinate with that PR before starting to reduce conflict risk."
            # Non-fatal: warn but don't block — PR may be in a different code path.
        fi
    fi

    # ── INFRA-1029: Check 5: existing worktree directory scan ────────────────
    if [[ -z "${CHUMP_PREFLIGHT_NO_WORKTREE_SCAN:-}" ]]; then
        _wt_slug=$(echo "$GAP_ID" | tr '[:upper:]' '[:lower:]')
        _wt_found=""
        for _wt in /private/tmp/chump-*"${_wt_slug}"* /tmp/chump-*"${_wt_slug}"*; do
            [ -d "$_wt" ] || continue
            # Skip /tmp → /private/tmp duplicates (macOS symlink)
            _wt_real=$(cd "$_wt" 2>/dev/null && pwd -P 2>/dev/null || echo "$_wt")
            [[ "$_wt_real" == "$_wt_found" ]] && continue
            _wt_found="$_wt_real"
            info "WARN: $GAP_ID — existing worktree directory found at $_wt_real"
            info "  If resuming work: re-attach with 'git worktree list' and re-claim."
            info "  If stale: remove with 'git worktree remove --force $_wt_real'."
            info "  Skip this check: CHUMP_PREFLIGHT_NO_WORKTREE_SCAN=1"
            printf '{"ts":"%s","kind":"preflight_dupe_worktree","gap":"%s","path":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GAP_ID" "$_wt_real" \
                >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
        done
    fi

    # ── INFRA-1029: Check 6: open PR title scan (REST, no GraphQL) ───────────
    if [[ -z "${CHUMP_PREFLIGHT_NO_PR_SCAN:-}" ]]; then
        _nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
        if [[ -n "$_nwo" ]]; then
            _gap_lower=$(echo "$GAP_ID" | tr '[:upper:]' '[:lower:]')
            _pr_hit=$(gh api "repos/$_nwo/pulls?state=open&per_page=100" \
                --jq "[.[] | select(.title | ascii_downcase | contains(\"$_gap_lower\"))] | .[].number" \
                2>/dev/null || echo "")
            if [[ -n "$_pr_hit" ]]; then
                _pr_list=$(echo "$_pr_hit" | tr '\n' ',' | sed 's/,$//')
                info "WARN: $GAP_ID — open PR(s) found with this gap ID in title: #$_pr_list"
                info "  An existing PR may already implement this gap."
                info "  Review before claiming: gh pr view <N>"
                info "  Skip this check: CHUMP_PREFLIGHT_NO_PR_SCAN=1"
                printf '{"ts":"%s","kind":"preflight_dupe_pr","gap":"%s","prs":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GAP_ID" "$_pr_list" \
                    >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
            fi
        fi
    fi

    green "OK $GAP_ID — open and unclaimed."
done

if [[ $FAILED -eq 1 ]]; then
    red "Pre-flight failed: one or more gaps unavailable (already done on $REMOTE/$BASE, live-claimed by another session, or not registered in gap registry)."
    exit 1
fi

# INFRA-1116: refuse-on-overlapping-INTENT enforcement. Opt-in via the
# CHUMP_CLAIM_PATHS env var (CSV of paths). When set, scan ambient.jsonl
# for live INTENT events from other sessions touching overlapping paths
# in the last $CHUMP_CLAIM_INTENT_WINDOW_S (default 60s); refuse the
# claim if any overlap. Bypass: CHUMP_CLAIM_FORCE_OVERLAP=1 with reason.
#
# Path-undeclared claims (no CHUMP_CLAIM_PATHS) skip the gate to preserve
# back-compat with today's mostly-undeclared callers; v1 tightens the
# default once most agents pass --paths.
INTENT_CHECK="$(dirname "${BASH_SOURCE[0]}")/intent-overlap-check.sh"
if [[ -x "$INTENT_CHECK" && -n "${CHUMP_CLAIM_PATHS:-}" ]]; then
    for GAP_ID in "$@"; do
        if ! "$INTENT_CHECK" "$GAP_ID" "$CHUMP_CLAIM_PATHS"; then
            rc=$?
            if [[ "$rc" -eq 14 ]]; then
                red "Pre-flight failed: overlapping INTENT detected for $GAP_ID."
                red "  Coordinate with the holding session or set CHUMP_CLAIM_FORCE_OVERLAP=1 with CHUMP_CLAIM_OVERRIDE_REASON."
                exit 14
            fi
        fi
    done
fi

green "Pre-flight passed — all specified gaps are available."
exit 0
