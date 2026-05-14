#!/usr/bin/env bash
# gap-claim.sh — Claim a gap by writing a lease file entry.
#
# Replaces the old "edit docs/gaps.yaml + git push" claim workflow. Writing a
# local JSON file is instant, causes no merge conflicts, and auto-expires when
# the session ends or the TTL fires — no stale locks possible.
#
# INFRA-186/INFRA-187: Branch and worktree naming — both conventions accepted.
# Canonical naming is chump/* (new standard per INFRA-186), but claude/* and
# other tool prefixes remain supported for backward compatibility. This script
# has no branch-name enforcement; git and bot-merge.sh handle that.
#
# Usage:
#   scripts/coord/gap-claim.sh GAP-ID
#   scripts/coord/gap-claim.sh REL-004
#   scripts/coord/gap-claim.sh REL-004 --paths src/foo.rs,src/bar.rs
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
#   --speculative             INFRA-193: opt-in speculative-execution mode.
#                             Marks the lease with `"speculative": true` so
#                             gap-preflight.sh allows concurrent claims by other
#                             speculative-mode sessions. First-to-land wins; the
#                             loser's PR is auto-closed by the post-merge sweep
#                             in bot-merge.sh / stale-pr-reaper.sh. Default OFF
#                             — exclusive lease semantics remain the safe default.
#
# Environment:
#   CHUMP_SESSION_ID         explicit session ID override (highest priority)
#   CLAUDE_SESSION_ID        set by Claude Code SDK — unique per session
#   GAP_CLAIM_TTL_HOURS      claim TTL in hours (default: 4)
#   CHUMP_ALLOW_MAIN_WORKTREE  set to 1 to allow claiming from the main worktree
#   CHUMP_PATH_CASE_CHECK    set to 0 to skip the path-case guard (default: 1)
#   CHUMP_LOCK_DIR           override `.chump-locks/` path (tests; must match gap-preflight)
#   CHUMP_SPECULATIVE        INFRA-193: equivalent to --speculative when set to 1

set -euo pipefail

# INFRA-956: default harness to a schema-valid value so ambient events emit
# meaningful attribution instead of triggering 'missing_attribution' alerts.
# Operator-driven coord scripts default to "manual"; agents that wrap this
# script (claude-code-ide, opencode, etc.) override before invocation.
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

# INFRA-379: heal a wedged chump binary before any CLI call (see
# scripts/lib/chump-preflight.sh). Silent no-op on healthy binaries.
# shellcheck source=../lib/chump-preflight.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/chump-preflight.sh"

# INFRA-975: disk-pressure gate. Abort the claim BEFORE any expensive
# setup (worktree creation, cargo build, lease write) if the filesystem
# is too tight to accommodate another ~5-9 GB worktree. Today 2026-05-13
# we filled /private/tmp to 911 MB free because cleanup was manual.
# shellcheck source=../lib/disk-check.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/disk-check.sh"
chump_disk_check_or_abort

# INFRA-590: print error + doc link, then exit 1.
die_with_help() {
    local msg="$1" anchor="$2"
    printf '\033[0;31m[gap-claim] ERROR: %s\033[0m\n' "$msg" >&2
    printf '\033[0;31m[gap-claim] See: docs/process/CLAUDE_GOTCHAS.md#%s\033[0m\n' "$anchor" >&2
    exit 1
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 GAP-ID [--paths file1,file2,...]" >&2
    exit 1
fi

GAP_ID="$1"
shift

# ── Parse optional --paths / --speculative arguments ────────────────────────
CLAIM_PATHS=""
SPECULATIVE="${CHUMP_SPECULATIVE:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths)
            shift
            CLAIM_PATHS="${1:-}"
            ;;
        --paths=*)
            CLAIM_PATHS="${1#--paths=}"
            ;;
        --speculative)
            SPECULATIVE=1
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 GAP-ID [--paths file1,file2,...] [--speculative]" >&2
            exit 1
            ;;
    esac
    shift
done

# ── INFRA-1059: bail-fast on non-gap tokens ──────────────────────────────────
# chump-commit.sh auto-lease greps commit messages for gap-IDs. If a commit
# mentions tokens like SHA-256, P0-1, or HTTP-200, gap-claim.sh was previously
# invoked on phantom IDs, hanging on the index mutex. Reject IDs whose leading
# prefix is not a known gap domain — this catches SHA, P0, HTTP, UTF, etc.
# We only check the PREFIX so test fixtures like INFRA-RACE-TEST still pass.
_KNOWN_PREFIX_RE='^(INFRA|CREDIBLE|EFFECTIVE|RESILIENT|EVAL|COG|DOC|FLEET|META|PRODUCT|SMOKE|ACP|AGT|AUTO|COMP|FRONTIER|MEM|QUALITY|RELIABILITY|RESEARCH|SECURITY|SENSE|SWARM|UX|TEST)-'
if ! echo "$GAP_ID" | grep -qE "$_KNOWN_PREFIX_RE"; then
    printf '[gap-claim] skipping non-gap token: %s (does not match known domain prefix)\n' "$GAP_ID" >&2
    exit 0
fi

# ── Paths (needed before session ID so we can detect main worktree) ───────────
# INFRA-109: REPO_ROOT + LOCK_DIR resolved via main-repo path so leases
# from linked worktrees land in the shared .chump-locks/ where siblings see them.
# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"

# ── INFRA-810: worktree show-toplevel health check ────────────────────────────
# core.bare=true in the main .git/config prevents `git rev-parse --show-toplevel`
# from working in linked worktrees. With extensions.worktreeconfig=true, we can
# override per-worktree by writing config.worktree with core.bare=false to the
# worktree's gitdir. Auto-heal here so callers don't hit silent failures.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    _WT_GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [[ -n "$_WT_GITDIR" ]]; then
        printf '[core]\n\tbare = false\n' > "$_WT_GITDIR/config.worktree"
        git worktree repair 2>/dev/null || true
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
            printf '[gap-claim] INFRA-810: auto-healed core.bare in worktree gitdir %s\n' "$_WT_GITDIR" >&2
        fi
    fi
fi
unset _WT_GITDIR

# ── INFRA-779: gitdir back-reference repair ───────────────────────────────────
# Concurrent `git worktree add` calls from sibling agents can clobber the
# .git/worktrees/<name>/gitdir file, causing git rev-parse --show-toplevel to
# return a sibling worktree path. Repair by comparing the recorded path against
# the expected canonicalized worktree/.git path and rewriting if wrong.
_WT_ACTUAL_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# gap-claim.sh runs with CWD = the worktree root; use $PWD as expected toplevel.
_WT_EXPECTED_TOP="$(pwd -P 2>/dev/null || pwd)"
if [[ -n "$_WT_ACTUAL_TOP" && "$_WT_ACTUAL_TOP" != "$_WT_EXPECTED_TOP" ]]; then
    _WT_GITDIR_PATH="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
    if [[ -n "$_WT_GITDIR_PATH" && -f "$_WT_GITDIR_PATH/gitdir" ]]; then
        _WT_EXPECTED_DOT_GIT="${_WT_EXPECTED_TOP}/.git"
        printf '%s\n' "$_WT_EXPECTED_DOT_GIT" > "$_WT_GITDIR_PATH/gitdir"
        printf '[gap-claim] INFRA-779: repaired gitdir back-ref (was %s → now %s)\n' \
            "$_WT_ACTUAL_TOP" "$_WT_EXPECTED_TOP" >&2
        _WT_NAME="$(basename "$_WT_GITDIR_PATH")"
        printf '{"ts":"%s","kind":"worktree_gitdir_repaired","wt_name":"%s","was":"%s","now":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_WT_NAME" "$_WT_ACTUAL_TOP" "$_WT_EXPECTED_TOP" \
            >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    fi
fi
unset _WT_ACTUAL_TOP _WT_EXPECTED_TOP _WT_GITDIR_PATH _WT_EXPECTED_DOT_GIT _WT_NAME

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
        printf '[gap-claim]   cd "%s" && scripts/coord/gap-claim.sh %s\n' "$_CANONICAL_ROOT" "$GAP_ID" >&2
        printf '[gap-claim] Bypass: CHUMP_PATH_CASE_CHECK=0 scripts/coord/gap-claim.sh %s\n' "$GAP_ID" >&2
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
    printf '[gap-claim] Run `git worktree add .claude/worktrees/<name> -b chump/<name> origin/main`\n' >&2
    printf '[gap-claim] then re-run gap-claim.sh from that worktree, or set CHUMP_ALLOW_MAIN_WORKTREE=1.\n' >&2
    # See: docs/process/CLAUDE_GOTCHAS.md#error-wrong-worktree
    die_with_help "refusing to claim gap in the main worktree — concurrent sessions share the same .chump-locks/ dir and collide" "error-wrong-worktree"
fi

# ── INFRA-573: existing remote branch guard ──────────────────────────────────
# If a branch for this gap already exists on origin (from a prior abandoned
# session), git push will fail or silently overwrite work. Detect early.
# Override: CHUMP_ALLOW_REUSE_BRANCH=1
if [[ "${CHUMP_ALLOW_REUSE_BRANCH:-0}" != "1" ]]; then
    _GAP_ID_LOWER="$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')"
    _REMOTE_BRANCH_PATTERN="refs/heads/chump/${_GAP_ID_LOWER}-*"
    _EXISTING_BRANCHES="$(git ls-remote --heads origin "${_REMOTE_BRANCH_PATTERN}" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' || true)"
    if [[ -n "$_EXISTING_BRANCHES" ]]; then
        printf '[gap-claim] ERROR: branch already exists on origin: %s\n' "$_EXISTING_BRANCHES" >&2
        printf '[gap-claim] Either delete-remote: gh api repos/:owner/:repo/git/refs/heads/%s -X DELETE\n' "$(printf '%s' "$_EXISTING_BRANCHES" | head -1)" >&2
        printf '[gap-claim] Or pick a fresh worktree suffix and use a new branch name.\n' >&2
        printf '[gap-claim] Bypass: CHUMP_ALLOW_REUSE_BRANCH=1 scripts/coord/gap-claim.sh %s\n' "$GAP_ID" >&2
        exit 1
    fi
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

# ── Ambient glance (INFRA-083) ───────────────────────────────────────────────
# Peripheral-vision check: scan the last 10 min of ambient.jsonl for sibling
# sessions touching the same gap or files. Hard-stop if a sibling INTENT or
# file_edit landed in the last 120s — odds are too high we're racing.
SCRIPT_DIR_PRECLAIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" ]] && [[ "${CHUMP_AMBIENT_GLANCE:-1}" != "0" ]]; then
    _GLANCE_ARGS=(--gap "$GAP_ID")
    [[ -n "$CLAIM_PATHS" ]] && _GLANCE_ARGS+=(--paths "$CLAIM_PATHS")
    if ! CHUMP_SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" \
         "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" "${_GLANCE_ARGS[@]}" --check-overlap; then
        printf '[gap-claim] Sibling activity collision on %s — re-tail ambient.jsonl and re-plan.\n' "$GAP_ID" >&2
        printf '[gap-claim] Bypass: CHUMP_AMBIENT_GLANCE=0 scripts/coord/gap-claim.sh %s\n' "$GAP_ID" >&2
        exit 1
    fi
fi

# ── Phase 1: NATS KV dual-write (FLEET-032) ──────────────────────────────────
# Dual-write pattern: before writing the file-based lease, attempt an atomic
# CAS claim via NATS KV (via chump-coord binary). This enables cross-machine
# visibility in multi-machine fleets (Pi mesh, cloud overflow, ephemeral
# runners). The NATS KV write is NATS-conditional (CHUMP_NATS_URL set or
# chump-coord available); if NATS is unreachable, file-based lease proceeds.
#
# chump-coord claim exits:
#   0 — claim succeeded (atomic CAS won in NATS KV, or NATS unavailable)
#   1 — CONFLICT: another session holds the atomic claim in NATS KV — abort
#
# NATS KV behavior:
#   - Bucket: chump_gaps (one key per gap, indexed by `gap.<gap-id>`)
#   - TTL: native NATS KV max_age (CHUMP_GAP_CLAIM_TTL_SECS, default 4h)
#   - Visibility: cross-machine (siblings on other hosts see this claim)
#
# File-based lease behavior (INFRA-109):
#   - Location: .chump-locks/<session>.json in main repo
#   - TTL: stale-lease reaper + manual cleanup (.chump-locks cleanup runs hourly)
#   - Visibility: same-machine only (FLEET-032 Phase 2+ will deprecate this)
_COORD_BIN="$(command -v chump-coord 2>/dev/null || true)"
_NATS_ENABLED="${CHUMP_NATS_URL:+1}"
if [[ -n "$_COORD_BIN" ]] && [[ "${_NATS_ENABLED}" == "1" ]]; then
    # Derive file hints from gap domain (same heuristic as musher.sh)
    _COORD_FILES="$(python3 -c "
gap='$GAP_ID'
m = {'COG':'src/reflection.rs,src/reflection_db.rs','EVAL':'scripts/ab-harness/','COMP':'src/browser_tool.rs','INFRA':'.github/workflows/','AGT':'src/agent_loop/','MEM':'src/memory_db.rs','AUTO':'src/tool_middleware.rs','DOC':'docs/'}
prefix=gap.split('-')[0]
print(m.get(prefix,''))
" 2>/dev/null || true)"
    export CHUMP_COORD_FILES="$_COORD_FILES"
    printf '[gap-claim] FLEET-032 Phase 1: attempting NATS KV atomic claim for %s (CHUMP_NATS_URL set)...\n' "$GAP_ID" >&2
    if ! CHUMP_SESSION_ID="$SESSION_ID" "$_COORD_BIN" claim "$GAP_ID" 2>&1; then
        # Exit code 1 = atomic conflict — another agent won the CAS race in NATS KV.
        printf '[gap-claim] NATS KV conflict on %s — another session holds the atomic claim. Aborting.\n' "$GAP_ID" >&2
        printf '[gap-claim] Run musher.sh --pick for next available gap.\n' >&2
        exit 1
    fi
    printf '[gap-claim] NATS KV claim succeeded for %s (cross-machine visible).\n' "$GAP_ID" >&2
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOCK_DIR"

# ── INFRA-403: claim-time exclusivity check ───────────────────────────────────
# Closes the pre-PR race window: two sessions can both pass gap-preflight in the
# same millisecond (no lease exists yet), then proceed to write leases and create
# duplicate PRs. Re-checking here — right before writing our lease — aborts the
# slower session cleanly. Without this, Check 1.5 in gap-preflight.sh only fires
# when the OTHER PR already exists, leaving a window where both sessions create PRs.
#
# Two sources checked (mirrors gap-preflight Checks 1.5 + 2):
#   1. .chump-locks/*.json — sibling may have written its lease while we were in
#      the NATS KV / ambient-glance phase above.
#   2. Open PRs for this gap-ID — sibling is already past gap-claim and pushing.
#
# Bypass: CHUMP_SPECULATIVE=1 (intentional race per INFRA-193) or
#         CHUMP_PREFLIGHT_PR_CHECK=0 (skip PR check; lease check still runs).
if [[ "${CHUMP_SPECULATIVE:-0}" != "1" ]]; then
    _CLAIM_RACE="$(python3 - "$LOCK_DIR" "$GAP_ID" "$SESSION_ID" <<'PYEOF' 2>/dev/null || true
import json, os, sys
from datetime import datetime, timezone
lock_dir, gap_id, my_session = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.now(timezone.utc)
for fname in (sorted(os.listdir(lock_dir)) if os.path.isdir(lock_dir) else []):
    if not fname.endswith(".json"):
        continue
    path = os.path.join(lock_dir, fname)
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue
    if d.get("session_id", "") == my_session:
        continue
    if d.get("gap_id") != gap_id:
        continue
    try:
        expires = datetime.fromisoformat(d["expires_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        heartbeat = datetime.fromisoformat(d["heartbeat_at"].rstrip("Z")).replace(tzinfo=timezone.utc)
        grace = 30
        stale_secs = 900
        if (now - expires).total_seconds() > grace or (now - heartbeat).total_seconds() > stale_secs:
            continue
    except Exception:
        continue
    print(d.get("session_id", "unknown"))
    sys.exit(0)
PYEOF
)"
    if [[ -n "$_CLAIM_RACE" ]]; then
        printf '[gap-claim] INFRA-403: lease conflict at claim time — session %s already holds %s.\n' "$_CLAIM_RACE" "$GAP_ID" >&2
        printf '[gap-claim] Aborting to prevent duplicate-PR race (INFRA-403). Re-run musher --pick for next gap.\n' >&2
        exit 1
    fi

    if [[ "${CHUMP_PREFLIGHT_PR_CHECK:-1}" != "0" ]] && command -v gh >/dev/null 2>&1; then
        _PR_CLAIM="$(gh pr list --state open --search "${GAP_ID} in:title" \
            --json number,headRefName -q '.[0]' 2>/dev/null || true)"
        if [[ -n "$_PR_CLAIM" && "$_PR_CLAIM" != "null" && "$_PR_CLAIM" != "{}" ]]; then
            _PR_NUM="$(printf '%s' "$_PR_CLAIM" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("number",""))' 2>/dev/null || true)"
            printf '[gap-claim] INFRA-403: open PR #%s already implements %s — aborting claim.\n' "$_PR_NUM" "$GAP_ID" >&2
            printf '[gap-claim] Sibling session reached gh pr create first (Check 1.5 at claim time).\n' >&2
            exit 1
        fi
    fi
fi

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
    python3 - "$LOCK_FILE" "$GAP_ID" "$CLAIM_PATHS" "$SPECULATIVE" "$REPO_ROOT" <<'PYEOF'
import json, os, sys
path, gid, paths_csv, spec, repo_root = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(path) as f:
    d = json.load(f)
d["gap_id"] = gid
d["worktree"] = os.path.basename(repo_root)  # INFRA-1074: reaper safety
if spec == "1":
    d["speculative"] = True
p = d.get("pending_new_gap")
if isinstance(p, dict) and p.get("id") == gid:
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
        printf '[gap-claim] Updated %s → gap_id=%s, paths=%s%s\n' "$LOCK_FILE" "$GAP_ID" "$CLAIM_PATHS" "$([[ "$SPECULATIVE" == "1" ]] && echo ' (speculative)' || true)"
    else
        printf '[gap-claim] Updated %s → gap_id=%s%s\n' "$LOCK_FILE" "$GAP_ID" "$([[ "$SPECULATIVE" == "1" ]] && echo ' (speculative)' || true)"
    fi
else
    # No existing lease — write a minimal standalone claim
    python3 - "$LOCK_FILE" "$GAP_ID" "$SESSION_ID" "$NOW" "$EXPIRES" "$CLAIM_PATHS" "$SPECULATIVE" "$REPO_ROOT" <<'PYEOF'
import json, os, sys
path, gap_id, session_id, taken_at, expires_at, paths_csv, spec, repo_root = sys.argv[1:]
paths_list = [p.strip() for p in paths_csv.split(",") if p.strip()] if paths_csv else []
d = {
    "session_id": session_id,
    "paths": paths_list,
    "taken_at": taken_at,
    "expires_at": expires_at,
    "heartbeat_at": taken_at,
    "purpose": f"gap:{gap_id}",
    "gap_id": gap_id,
    "worktree": os.path.basename(repo_root),  # INFRA-1074: reaper safety
}
if spec == "1":
    d["speculative"] = True
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF
    if [[ -n "$CLAIM_PATHS" ]]; then
        printf '[gap-claim] Claimed %s for session %s (expires %s, paths=%s)%s\n' "$GAP_ID" "$SESSION_ID" "$EXPIRES" "$CLAIM_PATHS" "$([[ "$SPECULATIVE" == "1" ]] && echo ' [SPECULATIVE]' || true)"
    else
        printf '[gap-claim] Claimed %s for session %s (expires %s)%s\n' "$GAP_ID" "$SESSION_ID" "$EXPIRES" "$([[ "$SPECULATIVE" == "1" ]] && echo ' [SPECULATIVE]' || true)"
    fi
fi

# ── FLEET-032 Phase 1: log dual-write completion ──────────────────────────────
# At this point, the claim is now present in:
#   1. NATS KV (if CHUMP_NATS_URL set) — cross-machine visible, TTL via KV expiry
#   2. .chump-locks/<session>.json — same-machine visible, TTL via reaper
if [[ "${_NATS_ENABLED}" == "1" ]] && [[ -n "$_COORD_BIN" ]]; then
    printf '[gap-claim] FLEET-032 Phase 1: dual-write complete — claim visible in NATS KV + .chump-locks/.\n' >&2
fi

# ── INFRA-168: sync claim to SQLite leases table ─────────────────────────────
# Keep state.db in sync so `chump gap preflight` sees this session's claim
# and gap-preflight.sh can delegate to the Rust binary instead of sqlite3 CLI.
# Best effort — soft failure if chump is unavailable or the gap is not yet
# imported into local state.db (e.g. gaps on origin/main but never imported).
if command -v chump >/dev/null 2>&1; then
    _CLAIM_TTL_SECS=$(( ${GAP_CLAIM_TTL_HOURS:-4} * 3600 ))
    chump gap claim "$GAP_ID" \
        --session "$SESSION_ID" \
        --worktree "${REPO_ROOT:-}" \
        --ttl "$_CLAIM_TTL_SECS" 2>/dev/null || true
fi

# ── INFRA-193: speculative-mode advisory banner ──────────────────────────────
# When the operator opts in to speculative execution, surface the racing
# siblings explicitly so the human/agent knows they are not the only one
# working on this gap.
if [[ "$SPECULATIVE" == "1" ]]; then
    SIBLING_LIST="$(python3 - "$LOCK_DIR" "$GAP_ID" "$SESSION_ID" <<'PYEOF' 2>/dev/null || true
import json, os, sys
lock_dir, gid, mine = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
if os.path.isdir(lock_dir):
    for fn in sorted(os.listdir(lock_dir)):
        if not fn.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(lock_dir, fn)))
        except Exception:
            continue
        if d.get("session_id") == mine:
            continue
        if d.get("gap_id") == gid:
            tag = " [spec]" if d.get("speculative") else ""
            out.append(f"{d.get('session_id','?')}{tag}")
print(",".join(out))
PYEOF
)"
    if [[ -n "$SIBLING_LIST" ]]; then
        printf '[gap-claim] SPECULATIVE: racing sibling sessions on %s: %s\n' "$GAP_ID" "$SIBLING_LIST"
        printf '[gap-claim]   First-to-land wins; loser PRs auto-closed by stale-pr-reaper.sh / bot-merge.sh post-arm sweep.\n'
    else
        printf '[gap-claim] SPECULATIVE: no current racing siblings on %s — you are the first speculative claimer.\n' "$GAP_ID"
    fi
fi

# ── INFRA-102: session_start emit (fallback for non-Claude-Code dispatch) ────
# The SessionStart Claude Code hook (ambient-context-inject.sh) is the primary
# emitter, but agents reaching gap-claim.sh through chump-local dispatch,
# Cursor, or direct shell invocation never fire that hook. Emit here too so
# every gap claim is paired with a session_start event in the stream. The
# emit is idempotent for the Claude Code path: a session may now produce two
# session_start events (one on hook fire, one on gap-claim), which is fine —
# the cost is one extra row, the benefit is a guaranteed signal for siblings.
# Bypass with CHUMP_AMBIENT_SESSION_START_EMIT=0.
if [[ "${CHUMP_AMBIENT_SESSION_START_EMIT:-1}" != "0" ]] \
        && [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
    CHUMP_SESSION_ID="$SESSION_ID" \
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" session_start "gap=$GAP_ID" 2>/dev/null || true
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
if [[ -x "$REPO_ROOT/scripts/setup/install-hooks.sh" ]]; then
    "$REPO_ROOT/scripts/setup/install-hooks.sh" --quiet 2>/dev/null || true
fi

# ── CREDIBLE-040: per-harness git author identity ────────────────────────────
# Each harness commits under a distinct identity so per-harness attribution
# in `git log` matches ambient event tags (CREDIBLE-037) and model tags
# (CREDIBLE-025). Canonical identity table:
#   harness=opencode-bigpickle → bigpickle@chump.bot / opencode-bigpickle
#   harness=fleet-dispatcher   → chump-dispatch@chump.bot / Chump Dispatched
#   harness=claude-code-ide    → operator identity (jeffadkins1@gmail.com)
#   harness=manual             → operator identity (unchanged)
#
# We only set git config when the harness is opencode-bigpickle (the others
# already have correct identities via GIT_AUTHOR_* in bot-merge.sh or via
# the operator's ~/.gitconfig).
if [[ "${CHUMP_AGENT_HARNESS:-}" == "opencode-bigpickle" ]]; then
    git config user.email "bigpickle@chump.bot" 2>/dev/null || true
    git config user.name  "opencode-bigpickle"  2>/dev/null || true
    printf '[gap-claim] CREDIBLE-040: git identity set to bigpickle@chump.bot for harness=opencode-bigpickle\n' >&2
fi
