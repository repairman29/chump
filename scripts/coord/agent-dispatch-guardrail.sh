#!/usr/bin/env bash
# scripts/coord/agent-dispatch-guardrail.sh — RESILIENT-060 (A2A L6c)
#
# Pre-dispatch guardrail that BLOCKS a Sonnet subagent from being invoked
# via the Agent tool unless all three invariants pass:
#
#   1. Gap-id check — current branch matches the lease's gap_id
#   2. Lease check  — every proposed write path is in claim.paths
#   3. Fmt check    — if any proposed path is *.rs, cargo fmt --check passes
#
# Exit 0 = OK to dispatch.
# Exit 1 = BLOCKED with clear stderr + ambient event.
#
# Usage:
#   scripts/coord/agent-dispatch-guardrail.sh <gap-id> <comma-separated-paths>
#
# Rust-First-Bypass: pure shell glue under 200 LOC, no state mutation —
# reads lease JSON and emits ambient event; no canonical state written.
#
# INFRA-2674 / RESILIENT-060

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# CHUMP_REPO_ROOT allows tests to override the repo root without needing to
# install the script in the test's fake repo tree.
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Leases and the ambient log always live in the PRIMARY repo root, not a
# worktree. Resolve via git-common-dir (the shared .git for all worktrees).
# When CHUMP_LOCK_DIR is set directly (as in tests), skip this resolution.
if [[ -n "${CHUMP_LOCK_DIR:-}" ]]; then
    PRIMARY_ROOT="$REPO_ROOT"
else
    _GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || printf '%s/.git' "$REPO_ROOT")"
    # Normalise: git-common-dir may already be absolute or relative to CWD.
    if [[ "$_GIT_COMMON" == /* ]]; then
        PRIMARY_ROOT="$(dirname "$_GIT_COMMON")"
    else
        PRIMARY_ROOT="$(cd "$REPO_ROOT/$_GIT_COMMON/.." && pwd)"
    fi
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$PRIMARY_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
AMBIENT_EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"

# ── Helpers ────────────────────────────────────────────────────────────────────
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

to_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Minimal JSON string escaping: escape backslashes and double-quotes.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

emit_event() {
    local kind="$1"; shift
    local ts; ts="$(now_ts)"
    # Try ambient-emit.sh first (provides flock + harness attribution).
    if [[ -x "$AMBIENT_EMIT" ]] && bash "$AMBIENT_EMIT" "$kind" ts="$ts" "$@" 2>/dev/null; then
        return 0
    fi
    # Fallback: direct printf (best-effort, atomic for single-line appends).
    local kv_json="{\"ts\":\"$ts\",\"kind\":\"$kind\""
    for pair in "$@"; do
        local k="${pair%%=*}"
        local v="${pair#*=}"
        kv_json="${kv_json},\"${k}\":\"${v}\""
    done
    kv_json="${kv_json},\"source\":\"agent-dispatch-guardrail.sh\"}"
    printf '%s\n' "$kv_json" >> "$AMBIENT_LOG" 2>/dev/null || true
}

die_blocked() {
    local reason="$1"
    local gap_id="$2"
    local branch="$3"
    local attempted_paths="$4"
    local leased_paths="$5"

    printf '[GUARDRAIL BLOCKED] gap=%s reason=%s\n' "$gap_id" "$reason" >&2
    printf '  attempted_paths: %s\n' "$attempted_paths" >&2
    printf '  leased_paths:    %s\n' "$leased_paths" >&2
    printf '  branch:          %s\n' "$branch" >&2

    emit_event "agent_dispatch_guardrail_blocked" \
        "gap_id=$(json_escape "$gap_id")" \
        "branch=$(json_escape "$branch")" \
        "attempted_paths=$(json_escape "$attempted_paths")" \
        "leased_paths=$(json_escape "$leased_paths")" \
        "reason=$(json_escape "$reason")"

    exit 1
}

# ── Argument parsing ───────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
    printf 'Usage: %s <gap-id> <comma-separated-paths>\n' "$0" >&2
    exit 1
fi

GAP_ID="$(to_upper "$1")"    # normalise: infra-2674 → INFRA-2674
GAP_ID_LOWER="$(to_lower "$GAP_ID")"
PROPOSED_CSV="$2"

# Split comma-separated paths into a space-separated list for iteration.
# Using a subshell + IFS so we don't stomp on the global IFS.
proposed_list() {
    local IFS=','
    printf '%s\n' $PROPOSED_CSV
}

# ── Find lease file ────────────────────────────────────────────────────────────
# gap_id inside the JSON is authoritative (handles casing).
LEASE_FILE=""
LEASED_PATHS_CSV=""

for candidate in "$LOCK_DIR"/claim-*.json; do
    [[ -f "$candidate" ]] || continue
    cand_gap="$(jq -r '.gap_id // ""' "$candidate" 2>/dev/null || true)"
    cand_gap_upper="$(to_upper "$cand_gap")"
    if [[ "$cand_gap_upper" == "$GAP_ID" ]]; then
        LEASE_FILE="$candidate"
        # Extract paths array as comma-separated string.
        LEASED_PATHS_CSV="$(jq -r '(.paths // []) | join(",")' "$candidate" 2>/dev/null || true)"
        break
    fi
done

if [[ -z "$LEASE_FILE" ]]; then
    current_branch="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || printf 'unknown')"
    printf '[GUARDRAIL BLOCKED] no active lease for gap-id %s\n' "$GAP_ID" >&2
    printf '  Check: ls %s/claim-*.json\n' "$LOCK_DIR" >&2
    emit_event "agent_dispatch_guardrail_blocked" \
        "gap_id=$(json_escape "$GAP_ID")" \
        "branch=$(json_escape "$current_branch")" \
        "attempted_paths=$(json_escape "$PROPOSED_CSV")" \
        "leased_paths=" \
        "reason=no active lease for gap-id $GAP_ID"
    exit 1
fi

# ── Determine current branch ───────────────────────────────────────────────────
CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || printf '')"

# ── INVARIANT 1: Gap-id / branch check ────────────────────────────────────────
# Branch must contain the gap-id prefix: chump/<gap-id-lower>
# e.g. gap_id=INFRA-2674 → branch must start with chump/infra-2674
if [[ -n "$CURRENT_BRANCH" ]]; then
    branch_lower="$(to_lower "$CURRENT_BRANCH")"
    expected_prefix="chump/${GAP_ID_LOWER}"
    # INFRA-1658: case statement avoids pipefail race that `printf | grep -q` has.
    case "$branch_lower" in
        "${expected_prefix}"*) : ;;
        *)
            die_blocked \
                "branch mismatch: branch '${CURRENT_BRANCH}' does not match gap-id '${GAP_ID}' (expected prefix '${expected_prefix}')" \
                "$GAP_ID" "$CURRENT_BRANCH" "$PROPOSED_CSV" "$LEASED_PATHS_CSV"
            ;;
    esac
fi

# ── INVARIANT 2: Lease path check ─────────────────────────────────────────────
# Always-allowed paths (per RESILIENT-026 off-rails protocol).
is_always_allowed() {
    local p="$1"
    case "$p" in
        .chump/state.sql)   return 0 ;;
        docs/gaps/*)        return 0 ;;
        .gitignore)         return 0 ;;
    esac
    return 1
}

# Build newline-separated leased path list for iteration.
leased_list() {
    local IFS=','
    printf '%s\n' $LEASED_PATHS_CSV
}

OFFENDING_CSV=""
while IFS= read -r proposed; do
    [[ -z "$proposed" ]] && continue
    # Strip leading ./ prefix to normalise to repo-relative.
    relative_path="${proposed#./}"

    if is_always_allowed "$relative_path"; then
        continue
    fi

    found=0
    while IFS= read -r leased; do
        [[ -z "$leased" ]] && continue
        leased_rel="${leased#./}"
        # Exact match.
        if [[ "$relative_path" == "$leased_rel" ]]; then
            found=1; break
        fi
        # Proposed path is under a leased directory (leased ends with /).
        if [[ "$leased_rel" == */ ]] && [[ "$relative_path" == "${leased_rel}"* ]]; then
            found=1; break
        fi
    done < <(leased_list)

    if [[ $found -eq 0 ]]; then
        if [[ -n "$OFFENDING_CSV" ]]; then
            OFFENDING_CSV="${OFFENDING_CSV},${relative_path}"
        else
            OFFENDING_CSV="$relative_path"
        fi
    fi
done < <(proposed_list)

if [[ -n "$OFFENDING_CSV" ]]; then
    die_blocked \
        "out-of-lease paths: ${OFFENDING_CSV}" \
        "$GAP_ID" "$CURRENT_BRANCH" "$PROPOSED_CSV" "$LEASED_PATHS_CSV"
fi

# ── INVARIANT 3: cargo fmt --check (for *.rs paths only) ──────────────────────
HAS_RUST=0
while IFS= read -r proposed; do
    case "$proposed" in
        *.rs) HAS_RUST=1; break ;;
    esac
done < <(proposed_list)

if [[ $HAS_RUST -eq 1 ]]; then
    # Prefer CHUMP_WORKTREE_ROOT, then git toplevel of the repo root.
    WORKTREE_ROOT="${CHUMP_WORKTREE_ROOT:-$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$REPO_ROOT")}"

    CARGO=""
    for try_cargo in "${CARGO_BIN:-}" "$HOME/.cargo/bin/cargo" "/usr/local/bin/cargo" "$(command -v cargo 2>/dev/null || true)"; do
        [[ -x "$try_cargo" ]] && CARGO="$try_cargo" && break
    done

    if [[ -z "$CARGO" ]]; then
        printf '[GUARDRAIL] cargo not found — skipping fmt check (non-fatal)\n' >&2
    else
        FMT_OUT="$(cd "$WORKTREE_ROOT" && PATH="$HOME/.cargo/bin:$PATH" "$CARGO" fmt --all -- --check 2>&1)" || {
            # Truncate fmt output to avoid oversized events.
            SHORT_FMT="${FMT_OUT:0:200}"
            die_blocked \
                "cargo fmt --check failed — run 'cargo fmt --all' before dispatching. Details: ${SHORT_FMT}" \
                "$GAP_ID" "$CURRENT_BRANCH" "$PROPOSED_CSV" "$LEASED_PATHS_CSV"
        }
    fi
fi

# ── All invariants passed ──────────────────────────────────────────────────────
printf '[GUARDRAIL PASSED] gap=%s branch=%s paths=%s\n' \
    "$GAP_ID" "$CURRENT_BRANCH" "$PROPOSED_CSV" >&2

emit_event "agent_dispatch_guardrail_passed" \
    "gap_id=$(json_escape "$GAP_ID")" \
    "branch=$(json_escape "$CURRENT_BRANCH")" \
    "attempted_paths=$(json_escape "$PROPOSED_CSV")" \
    "leased_paths=$(json_escape "$LEASED_PATHS_CSV")" \
    "reason=all invariants passed"

exit 0
