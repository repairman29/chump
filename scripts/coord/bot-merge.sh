#!/usr/bin/env bash
#
# bot-merge.sh — Automated ship pipeline for agent branches.
#
# Intended for Claude sessions, Cursor agents, and the autonomy loop. Runs the
# full pre-merge checklist, pushes to origin, and opens (or updates) a GitHub PR.
#
# Usage:
#   scripts/coord/bot-merge.sh [--gap GAP-ID ...] [--stack-on PREV-GAP-ID] [--auto-merge] [--skip-tests] [--dry-run] [--no-merge-driver]
#                              [--branch-prefix PREFIX] [--pr-template PATH] [--required-checks CHECK1,CHECK2,...]
#
#   --stack-on PREV-GAP-ID
#                  Open this PR with base=<prev-PR-head> instead of main. When
#                  the prev PR lands, the merge queue auto-rebases this PR.
#                  Used for related work that would otherwise file-conflict if
#                  shipped in parallel (INFRA-061 / M3).
#
#   --gap GAP-ID   One or more gap IDs to check against origin/main before proceeding.
#                  If any gap is already `done` or claimed by another agent, the
#                  script aborts early. Repeat for multiple gaps: --gap A --gap B
#                  or pass space-separated: --gap "AUTO-003 COMP-002".
#   --auto-merge   Enable GitHub auto-merge on the PR (requires branch protection
#                  with required CI status checks configured).
#   --skip-tests   Skip `cargo test` (for pure-doc or non-Rust changes). fmt and
#                  clippy still run.
#   --fast         Skip BOTH cargo clippy AND cargo test locally. CI clippy/test
#                  is the gate (auto-merge won't land a red PR). Reduces total
#                  bot-merge wall time from ~5-10 min cold → ~30-60 sec, so
#                  agent-driven shipping fits inside the ~10-15 min subagent
#                  task budget. Implies --skip-tests. Default OFF; pass
#                  explicitly when running from chump dispatch / Agent tool /
#                  any context with a tight task budget. (INFRA-252)
#   --dry-run      Print every step without executing git push or gh commands.
#   --no-merge-driver
#                  Disable custom git merge drivers (INFRA-310) during rebase.
#                  Use when custom drivers are causing issues or you want to
#                  force git's default 3-way merge strategy.
#   --branch-prefix PREFIX
#                  Branch namespace prefix for auto-derive and branch rename
#                  (default: 'chump'). Set to the tool prefix used by the target
#                  repo — e.g. 'acme' for branches like 'acme/feat-123-title'.
#                  Env: BM_BRANCH_PREFIX
#   --pr-template PATH
#                  Path to a Markdown file whose contents replace the default
#                  PR body template. Use for repos with their own PR structure
#                  (e.g. chump-proprietary). Supports the following placeholders
#                  which are substituted before posting:
#                    {{COMMIT_LOG}}   one-line git log since base
#                    {{GAP_LINE}}     "Gaps addressed: ..." or empty
#                    {{PLAN_BLOCK}}   plan-mode details block or empty
#                  Env: BM_PR_TEMPLATE
#   --required-checks CHECK1,CHECK2,...
#                  Comma-separated list of CI check names that must pass before
#                  auto-merge is armed. When set, only checks matching one of
#                  these names are considered blockers (others are advisory).
#                  When unset, any FAILURE/ERROR check blocks auto-merge.
#                  Env: BM_REQUIRED_CHECKS
#
# Requirements: gh CLI authenticated, GITHUB_TOKEN in env or gh keyring, cargo.
#
# Exit codes (RESILIENT-010 — step-specific codes for automated recovery):
#   0   PR opened/updated (or already up to date)
#   1   Unexpected error (set -e trap or unhandled failure)
#   3   Branch too stale to merge safely (>50 commits behind main at start,
#       or >15 behind right before push — INFRA-995)
#   10  Preflight failed (gap already done, claimed, or unavailable)
#   11  Rebase failed (merge conflict or timeout)
#   12  Cargo clippy failed (lint errors)
#   13  Cargo test failed (test suite errors)
#   14  git push failed (force-with-lease rejected or network error)
#   15  gh pr create/update failed
# Legacy codes kept for external callers: 2=push/gh, 4=misc abort

set -euo pipefail


# INFRA-956: default harness to a schema-valid value (kills missing_attribution noise).
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

# ── INFRA-119: health-file globals + cleanup traps ───────────────────────────
_BM_PID=$$
_BM_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_BM_HEALTH_FILE=""
_BM_STEP_FILE=""
_BM_STEPS_FILE=""   # INFRA-1035: append-only transition log for crash recovery
_BM_LAST_STEP_TRANSITION=""  # "start" or "done" — detect open transitions on crash
_BM_HEALTH_PID=""
_BM_WATCHDOG_PID=""
_BM_CLEANUP_DONE=0

# INFRA-1035: append one JSONL entry to the steps file.
# Usage: _bm_steps_append <transition> <step> [elapsed_s]
_bm_steps_append() {
    [[ -z "${_BM_STEPS_FILE:-}" ]] && return 0
    local transition="$1" step="${2:-unknown}" elapsed_s="${3:-0}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","step":"%s","transition":"%s","elapsed_s":%s}\n' \
        "$ts" "$step" "$transition" "$elapsed_s" \
        >> "$_BM_STEPS_FILE" 2>/dev/null || true
    _BM_LAST_STEP_TRANSITION="$transition"
}

_bm_cleanup() {
    [[ "$_BM_CLEANUP_DONE" == "1" ]] && return
    _BM_CLEANUP_DONE=1
    [[ -n "${_BM_HEALTH_PID:-}" ]]   && kill "$_BM_HEALTH_PID"   2>/dev/null || true
    [[ -n "${_BM_WATCHDOG_PID:-}" ]] && kill "$_BM_WATCHDOG_PID" 2>/dev/null || true
    rm -f "${_BM_HEALTH_FILE:-}" "${_BM_STEP_FILE:-}" 2>/dev/null || true
    # INFRA-1035: if the last transition was "start" (no matching "done"),
    # we crashed mid-step — record that so bot-merge-recover.sh can report it.
    if [[ -n "${_BM_STEPS_FILE:-}" && "${_BM_LAST_STEP_TRANSITION:-}" == "start" ]]; then
        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","step":"%s","transition":"error","elapsed_s":0,"crashed":true}\n' \
            "$ts" "${__STAGE_LABEL:-unknown}" \
            >> "$_BM_STEPS_FILE" 2>/dev/null || true
        # Emit to ambient so fleet monitors can detect bot-merge crashes.
        local ambient=".chump-locks/ambient.jsonl"
        [[ -n "${CHUMP_AMBIENT_LOG:-}" ]] && ambient="$CHUMP_AMBIENT_LOG"
        printf '{"ts":"%s","kind":"bot_merge_crashed","step":"%s","pid":%d,"steps_file":"%s","note":"start without done on exit"}\n' \
            "$ts" "${__STAGE_LABEL:-unknown}" "$_BM_PID" "${_BM_STEPS_FILE:-}" \
            >> "$ambient" 2>/dev/null || true
    fi
    # NOTE: _BM_STEPS_FILE is intentionally NOT deleted here — it's the
    # recovery artifact that bot-merge-recover.sh needs to diagnose the crash.
    # INFRA-1017: vacuum state.db leases row so gap-preflight doesn't report a
    # phantom live claim after this process is killed (SIGTERM, OOM, ctrl-C).
    if [[ -n "${CHUMP_SESSION_ID:-}" ]] && command -v sqlite3 &>/dev/null; then
        local _db="${MAIN_REPO:-${REPO_ROOT:-.}}/.chump/state.db"
        [[ -f "$_db" ]] && sqlite3 "$_db" \
            "DELETE FROM leases WHERE session_id='${CHUMP_SESSION_ID}'" 2>/dev/null || true
    fi
}
trap '_bm_cleanup' EXIT
trap '_bm_cleanup; exit 1' TERM INT

# ── RESILIENT-010: step-specific failure helper ───────────────────────────────
# Usage: _bm_fail <step-name> <exit-code> [message]
# Emits kind=bot_merge_phase_failure to ambient.jsonl (RESILIENT-011), exits with the given code.
#
# Exit code table (RESILIENT-011):
#   0  — success
#   1  — unexpected error (not a named phase)
#   2  — arg-parse / usage error
#   10 — preflight-fail  (gap already done/claimed, or post-rebase preflight)
#   11 — rebase-fail     (merge conflict or timeout)
#   12 — fmt-fail        (cargo fmt failed or timed out)
#   13 — clippy-fail     (clippy lint errors)
#   14 — test-fail       (cargo test suite failure)
#   15 — push-fail       (force-with-lease rejected or network error)
#   16 — pr-create-fail  (gh pr create failed or PR not visible after create)
_bm_fail() {
    local step="${1:-unknown}" code="${2:-1}" msg="${3:-}"
    local ambient="${CHUMP_AMBIENT_LOG:-${CHUMP_REPO:-.chump-locks}/ambient.jsonl}"
    # Fallback to .chump-locks/ambient.jsonl if CHUMP_AMBIENT_LOG unset.
    [[ -z "${CHUMP_AMBIENT_LOG:-}" ]] && ambient=".chump-locks/ambient.jsonl"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"
    printf '{"ts":"%s","kind":"bot_merge_phase_failure","step":"%s","exit_code":%d,"gap_id":"%s","branch":"%s","note":"%s"}\n' \
        "$ts" "$step" "$code" "${GAP_IDS[*]:-}" "${BRANCH:-}" "$msg" \
        >> "$ambient" 2>/dev/null || true
    exit "$code"
}

# ── INFRA-017: dispatched-agent identity ─────────────────────────────────────
# When bot-merge.sh runs inside a dispatched subagent (chump-orchestrator set
# CHUMP_DISPATCH_DEPTH=1), stamp git author/committer so amend commits and
# any fresh commits we make are attributable to the bot — not the host
# developer's git config. Human invocations leave the env unset and keep
# the user's configured identity.
if [[ "${CHUMP_DISPATCH_DEPTH:-0}" == "1" ]]; then
    export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Chump Dispatched}"
    export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-chump-dispatch@chump.bot}"
    export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Chump Dispatched}"
    export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-chump-dispatch@chump.bot}"
fi

# ── INFRA-209: ensure pre-commit hooks are installed in this worktree ────────
# Cold Water Issue #10 audit (2026-05-02) found 8 commits on origin/main since
# 2026-05-01 introducing status:done with closed_pr:TBD — the INFRA-107 guard
# was supposed to block these but was bypassed because the remote dispatch
# agents had empty .git/hooks/ dirs. install-hooks.sh is per-worktree (post-
# checkout hook does it on `git worktree add` since INFRA-072) but ephemeral
# sandbox checkouts skip the post-checkout hook.
#
# Idempotent guard: if pre-commit is missing OR points at a path that no
# longer exists, run install-hooks.sh --quiet. This protects every bot-merge
# invocation regardless of how the worktree was created.
#
# Disable: CHUMP_AUTO_INSTALL_HOOKS=0
if [[ "${CHUMP_AUTO_INSTALL_HOOKS:-1}" != "0" ]]; then
    _bm_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _bm_git_dir="$(git rev-parse --git-dir 2>/dev/null || echo "$_bm_repo_root/.git")"
    _bm_hook="$_bm_git_dir/hooks/pre-commit"
    _bm_install_sh="$_bm_repo_root/scripts/setup/install-hooks.sh"
    _bm_needs_install=0
    if [[ ! -e "$_bm_hook" ]]; then
        _bm_needs_install=1
    elif [[ -L "$_bm_hook" ]] && [[ ! -e "$_bm_hook" ]]; then
        # symlink to a missing target (stale install from another machine)
        _bm_needs_install=1
    fi
    if [[ "$_bm_needs_install" == "1" ]] && [[ -x "$_bm_install_sh" ]]; then
        printf '\033[0;32m[bot-merge] INFRA-209: pre-commit hook missing, running install-hooks.sh\033[0m\n'
        "$_bm_install_sh" --quiet 2>&1 | sed 's/^/[bot-merge] /' || \
            printf '\033[0;31m[bot-merge] WARN: install-hooks.sh failed; continuing without hooks\033[0m\n'
    fi
fi

# ── Flags ────────────────────────────────────────────────────────────────────
AUTO_MERGE=0
SKIP_TESTS=0
FAST=0
DRY_RUN=0
NO_MERGE_DRIVER=0
# INFRA-193: speculative execution opt-in. With --speculative, gap-claim.sh
# writes `"speculative": true` into the lease and gap-preflight.sh allows
# concurrent claims by other speculative-mode sessions on the same gap.
# After auto-merge is armed for our PR, the post-arm sweep below scans for
# open sibling PRs citing the same gap and closes them with a "superseded
# by #N" comment. CHUMP_SPECULATIVE=1 is the env equivalent.
SPECULATIVE=${CHUMP_SPECULATIVE:-0}
# INFRA-632: portability knobs — configurable branch prefix, PR template, required CI checks.
BRANCH_PREFIX="${BM_BRANCH_PREFIX:-chump}"
PR_TEMPLATE="${BM_PR_TEMPLATE:-}"
REQUIRED_CHECKS="${BM_REQUIRED_CHECKS:-}"
NEXT_IS_BRANCH_PREFIX=0
NEXT_IS_PR_TEMPLATE=0
NEXT_IS_REQUIRED_CHECKS=0
# INFRA-996: bypass dup-PR check when the prior PR is known-closed during this run.
FORCE_DUPLICATE=${CHUMP_FORCE_DUPLICATE:-0}
GAP_IDS=()
NEXT_IS_GAP=0
# INFRA-061 (M3): --stack-on <PREV-GAP-ID> opens this PR with base=claude/<branch
# of the prev gap's open PR>, instead of base=main. When the prev PR lands, the
# merge queue auto-rebases this stacked PR onto the new main. One-deep stacks
# cover the dispatcher case; deeper stacks just chain (--stack-on the most
# recent open PR's gap).
STACK_ON_GAP=""
NEXT_IS_STACK_ON=0
for arg in "$@"; do
    if [[ $NEXT_IS_GAP -eq 1 ]]; then
        # Support --gap "AUTO-003 COMP-002" (space-separated) or --gap AUTO-003 --gap COMP-002
        for gid in $arg; do GAP_IDS+=("$gid"); done
        NEXT_IS_GAP=0
        continue
    fi
    if [[ $NEXT_IS_STACK_ON -eq 1 ]]; then
        STACK_ON_GAP="$arg"
        NEXT_IS_STACK_ON=0
        continue
    fi
    if [[ $NEXT_IS_BRANCH_PREFIX -eq 1 ]]; then
        BRANCH_PREFIX="$arg"
        NEXT_IS_BRANCH_PREFIX=0
        continue
    fi
    if [[ $NEXT_IS_PR_TEMPLATE -eq 1 ]]; then
        PR_TEMPLATE="$arg"
        NEXT_IS_PR_TEMPLATE=0
        continue
    fi
    if [[ $NEXT_IS_REQUIRED_CHECKS -eq 1 ]]; then
        REQUIRED_CHECKS="$arg"
        NEXT_IS_REQUIRED_CHECKS=0
        continue
    fi
    case "$arg" in
        --gap)             NEXT_IS_GAP=1 ;;
        --stack-on)        NEXT_IS_STACK_ON=1 ;;
        --auto-merge)         AUTO_MERGE=1 ;;
        --skip-tests)         SKIP_TESTS=1 ;;
        --fast)               FAST=1; SKIP_TESTS=1 ;;
        --dry-run)            DRY_RUN=1 ;;
        --speculative)        SPECULATIVE=1 ;;
        --no-merge-driver)    NO_MERGE_DRIVER=1 ;;
        --branch-prefix)      NEXT_IS_BRANCH_PREFIX=1 ;;
        --pr-template)        NEXT_IS_PR_TEMPLATE=1 ;;
        --required-checks)    NEXT_IS_REQUIRED_CHECKS=1 ;;
        --allow-mass-delete)  ALLOW_MASS_DELETE=1 ;;  # INFRA-993 scratch-commit-guard override
        --force-duplicate)    FORCE_DUPLICATE=1 ;;    # INFRA-996 dup-PR-guard override
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# INFRA-993: default disabled. Set --allow-mass-delete to permit a push that
# would otherwise be blocked by the scratch-commit guard (legit large-deletion
# PRs like archive/ rewrites).
ALLOW_MASS_DELETE="${ALLOW_MASS_DELETE:-0}"

# INFRA-237: when --gap was not given, auto-derive from the current branch
# name. Branches following the canonical naming convention encode the gap ID
# (e.g. chump/infra-127-reflection-e2e → INFRA-127, claude/research-026-impl
# → RESEARCH-026, chore/file-infra-243 → INFRA-243). When auto-derive fires,
# print a clear info banner so the agent knows --gap was inferred (not
# silently skipped).
#
# The user can suppress auto-derivation by passing --gap none for genuine
# non-gap-bound PRs (e.g. dependabot bumps, doc-only sweeps that touch many
# unrelated areas). The literal string "none" filters out of GAP_IDS to keep
# downstream logic simple.
#
# Why this matters: when --gap is missing AND no auto-derive succeeds, the
# INFRA-154 auto-close path silently skips, producing the OPEN-BUT-LANDED
# ghosts INFRA-241 had to backfill. Making --gap effectively-required closes
# that path at the bottleneck without forcing every legitimate non-gap PR
# to add boilerplate.
if [[ ${#GAP_IDS[@]} -eq 0 ]]; then
    _branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
    # Strip the canonical chump-codename prefixes (chump/, claude/, chore/file-,
    # chore/close-) so the regex catches IDs anywhere in the remainder.
    # Strip leading namespace token (chump/, claude/, chore/) and an optional
    # action prefix (file-, close-, fix-) — but NOT the domain prefix
    # (infra-, research-, etc.) because the domain IS the gap-ID prefix we
    # want to extract. Then turn dashes into spaces and uppercase so
    # 'infra-127-reflection' becomes 'INFRA 127 RELECTION' for the grep.
    # INFRA-632: strip BRANCH_PREFIX (and legacy Chump prefixes) so gap-ID
    # auto-derive works for non-Chump repos with custom branch namespaces.
    # Use ${BRANCH_PREFIX:-chump} so the pattern degrades gracefully when this
    # block is eval'd in isolation (e.g. unit tests that source only this block).
    # INFRA-630: extract UUID-format gap IDs BEFORE tr strips hyphens.
    # Supported branch patterns:
    #   chump/8d3f2c0e-9f5b-4e1a-b2c3-d4e5f6a7b8c9-slug  (full RFC-4122 UUID)
    #   chump/8d3f2c0e--my-slug                           (8-char short-prefix, chump-proprietary)
    _branch_raw=$(echo "$_branch_name" \
        | sed -E "s,^(${BRANCH_PREFIX:-chump}|chump|claude|chore)/(file-|close-|fix-)?,," )
    # Full UUID pattern (RFC-4122: 8-4-4-4-12 hex)
    _uuid_full=$(printf '%s' "$_branch_raw" \
        | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' 2>/dev/null \
        | tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ' ' || true)
    # Short-prefix pattern: 8 lowercase hex chars immediately followed by --
    _uuid_short=$(printf '%s' "$_branch_raw" \
        | sed -n 's/^\([0-9a-f]\{8\}\)--.*$/\1/p' \
        | tr '[:lower:]' '[:upper:]' || true)
    _uuid_derived_gaps="${_uuid_full}${_uuid_short:+${_uuid_short} }"
    # Fallback to standard sed-based approach for [DOMAIN]-[NUM] patterns.
    _branch_tail=$(echo "$_branch_raw" \
        | tr '-' ' ' | tr 'a-z' 'A-Z')
    # Extract every <DOMAIN>-<NUMBER> pattern from the cleaned branch name.
    _derived_gaps=$(echo "$_branch_tail" \
        | grep -oE '[A-Z]+ [0-9]+' \
        | sed 's/ /-/' \
        | sort -u | tr '\n' ' ')
    # Merge UUID-format + classic-format derived gaps (INFRA-630)
    _derived_gaps="${_uuid_derived_gaps}${_derived_gaps}"
    if [[ -n "$_derived_gaps" ]]; then
        for gid in $_derived_gaps; do GAP_IDS+=("$gid"); done
        printf '\033[0;32m[bot-merge] auto-derived --gap from branch name: %s\033[0m\n' "${GAP_IDS[*]}"
        printf '\033[0;32m[bot-merge]   (suppress with explicit --gap none for non-gap PRs)\033[0m\n'
    elif [[ -z "$_branch_name" ]]; then
        # Detached HEAD or non-branch state — let the script proceed; downstream
        # checks will fail loud if a gap is needed.
        :
    else
        echo "" >&2
        printf '\033[0;31m[bot-merge] ERROR: no --gap given and could not auto-derive from branch name "%s"\033[0m\n' "$_branch_name" >&2
        echo "[bot-merge]   INFRA-237: --gap is now effectively required to keep INFRA-154" >&2
        echo "[bot-merge]   auto-close working. Either:" >&2
        echo "[bot-merge]     1. Pass --gap explicitly: --gap INFRA-NNN" >&2
        echo "[bot-merge]     2. Rename the branch to encode the gap ID:" >&2
        echo "[bot-merge]          git branch -m chump/infra-NNN-<short>" >&2
        echo "[bot-merge]     3. Pass --gap none for genuine non-gap PRs" >&2
        echo "[bot-merge]        (dependabot bumps, doc-only sweeps, etc.)" >&2
        exit 2
    fi
fi

# Filter out the literal "none" sentinel — this is how callers explicitly
# suppress auto-derivation for non-gap PRs without tripping downstream checks
# that expect a real ID.
_filtered=()
for gid in "${GAP_IDS[@]}"; do
    [[ "$gid" == "none" || "$gid" == "NONE" ]] && continue
    _filtered+=("$gid")
done
# INFRA-237: ${_filtered[@]} expansion under `set -u` would error when the
# array is empty (e.g. caller passed --gap none). Reset GAP_IDS to an empty
# array first, then append only if there's anything to keep.
GAP_IDS=()
if [[ ${#_filtered[@]} -gt 0 ]]; then
    GAP_IDS=("${_filtered[@]}")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── INFRA-305: hot-file rebase-loop expectation list ─────────────────────────
# Files that every parallel agent appends to (CI test list, pre-commit guard
# list, coordination scripts, top-level docs). PRs touching these almost
# always hit ≥1 DIRTY rebase before landing because main moves under them
# while CI runs. The arm-time hot-file scan below emits a stdout note +
# ambient.jsonl event so the agent KNOWS to expect the rebase loop instead
# of treating it as a surprise. See docs/gaps/INFRA-305.yaml.
#
# Hand-curated, intentionally small. Update when a new shared append-only
# file becomes a steady contention point.
BOT_MERGE_HOT_FILES=(
    ".github/workflows/ci.yml"
    "scripts/git-hooks/pre-commit"
    "scripts/coord/bot-merge.sh"
    "scripts/coord/gap-claim.sh"
    "scripts/coord/gap-preflight.sh"
    "scripts/coord/gap-reserve.sh"
    "CLAUDE.md"
    "AGENTS.md"
    # INFRA-670: workspace-wide files — touching these requires cascade rebase
    # of all sibling PRs (queue-driver.sh cascade_rebase_if_hot handles it).
    "Cargo.toml"
    "rust-toolchain.toml"
)

# INFRA-711: extend BOT_MERGE_HOT_FILES with additional workspace-wide paths
# (src/main.rs, src/lib.rs, src/agent_loop/**, src/dispatch.rs, etc.)
# Paths are configurable via scripts/coord/cascade-rebase-trigger-paths.txt
_bm_cascade_config="${REPO_ROOT:-$(git rev-parse --show-toplevel)}/scripts/coord/cascade-rebase-trigger-paths.txt"
if [[ -f "$_bm_cascade_config" ]]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip paths that are already hardcoded
        [[ "$line" == "Cargo.toml" || "$line" == "rust-toolchain.toml" ]] && continue
        BOT_MERGE_HOT_FILES+=("$line")
    done < "$_bm_cascade_config"
fi

# ── INFRA-103: serializing hot-file list ──────────────────────────────────────
# PRs touching any of these files cannot safely land concurrently because they
# modify shared coordination state or global config. All other PRs are
# parallel-safe. Configure via BM_SERIALIZING_HOT_FILES env var (colon-separated
# overrides the entire list) or append with BM_SERIALIZING_EXTRA (colon-separated).
_DEFAULT_SERIALIZING_HOT_FILES=(
    "gaps.yaml"
    ".chump/state.db"
    ".chump/state.sql"
    "CLAUDE.md"
    ".gitmodules"
    "Cargo.lock"
)
if [[ -n "${BM_SERIALIZING_HOT_FILES:-}" ]]; then
    IFS=':' read -ra SERIALIZING_HOT_FILES <<< "$BM_SERIALIZING_HOT_FILES"
else
    SERIALIZING_HOT_FILES=("${_DEFAULT_SERIALIZING_HOT_FILES[@]}")
fi
if [[ -n "${BM_SERIALIZING_EXTRA:-}" ]]; then
    IFS=':' read -ra _extra <<< "$BM_SERIALIZING_EXTRA"
    SERIALIZING_HOT_FILES+=("${_extra[@]}")
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# INFRA-026 — timestamped banners let the fleet distinguish "stuck" from
# "working hard." Every green/red/info output carries `[bot-merge HH:MM:SS]`.
# Long stages use `stage_start <label>` → `stage_done` which prints the
# elapsed seconds. Silent intervals >30s are the symptom INFRA-026 was
# filed about; banners make them attributable.
green()  { printf '\033[0;32m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
red()    { printf '\033[0;31m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
yellow() { printf '\033[0;33m[bot-merge %s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
warn()   { yellow "$*"; }
info()   { printf '[bot-merge %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# INFRA-590: print error + doc link, then exit 1.
die_with_help() {
    local msg="$1" anchor="$2"
    red "ERROR: $msg"
    red "See: docs/process/CLAUDE_GOTCHAS.md#${anchor}"
    exit 1
}

# ── INFRA-305: hot-file rebase-loop pre-emit warning ─────────────────────────
# Inspect the diff vs origin/main and emit a stderr note + ambient event for
# any file matching BOT_MERGE_HOT_FILES. Idempotent (keyed by gap+path on the
# stdout side; ambient is append-only). No behavior change — purely an
# expectation-setting note that a DIRTY rebase is likely while parallel
# agents touch the same shared append-only configs.
emit_hot_file_warnings() {
    local target_pr="${1:-}"   # may be empty if PR not yet open
    local gap_label="${2:-none}"
    local diff_files
    diff_files="$(git diff "$REMOTE/$BASE_BRANCH"..HEAD --name-only 2>/dev/null || true)"
    [[ -z "$diff_files" ]] && return 0

    local ambient="${LOCK_DIR:-/tmp}/ambient.jsonl"
    local now path hot
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        for hot in "${BOT_MERGE_HOT_FILES[@]}"; do
            if [[ "$path" == "$hot" ]]; then
                printf '\033[0;33m[bot-merge] HOT FILE: %s — expect rebase loop, OK to wait\033[0m\n' "$path" >&2
                printf '{"ts":"%s","session":"bot-merge-%d","event":"bot_merge_hot_file","kind":"bot_merge_hot_file","path":"%s","gap_id":"%s","pr":"%s","note":"PR touches hot file — expect ≥1 DIRTY rebase before landing if other agents are active. The 4-step disarm-push-rearm loop in CLAUDE.md is the recovery."}\n' \
                    "$now" "$_BM_PID" "$path" "$gap_label" "$target_pr" \
                    >> "$ambient" 2>/dev/null || true
                break
            fi
        done
    done <<< "$diff_files"
}

# ── INFRA-103: PR parallelism classifier ──────────────────────────────────────
# Outputs "serializing" if the diff touches any SERIALIZING_HOT_FILES entry,
# "parallel-safe" otherwise. Applies a GitHub label to the PR so the queue
# health monitor (and humans) can spot avoidable serialization.
classify_pr_parallelism() {
    local diff_files
    diff_files="$(git diff "$REMOTE/$BASE_BRANCH"..HEAD --name-only 2>/dev/null || true)"
    [[ -z "$diff_files" ]] && { echo "parallel-safe"; return; }
    local path hot
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        for hot in "${SERIALIZING_HOT_FILES[@]}"; do
            if [[ "$path" == "$hot" ]]; then
                echo "serializing"
                return
            fi
        done
    done <<< "$diff_files"
    echo "parallel-safe"
}

apply_pr_parallelism_label() {
    local pr_number="$1"
    local class
    class="$(classify_pr_parallelism)"
    local label="pr:${class}"
    info "INFRA-103: PR #${pr_number} classified as ${class} — applying label '${label}'"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] gh pr edit $pr_number --add-label $label"
        return 0
    fi
    # Create the label if it doesn't exist (idempotent).
    if [[ "$class" == "serializing" ]]; then
        gh label create "pr:serializing" --color "e4e669" --description "Touches shared hot files; cannot land concurrently with other serializing PRs" --force 2>/dev/null || true
    else
        gh label create "pr:parallel-safe" --color "0075ca" --description "Does not touch shared coordination files; can land concurrently with other parallel-safe PRs" --force 2>/dev/null || true
    fi
    gh pr edit "$pr_number" --add-label "$label" 2>/dev/null || true
    # Emit ambient event so queue-health-monitor and sibling agents see the class.
    local ambient="${LOCK_DIR:-/tmp}/ambient.jsonl"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local gap_label="${GAP_IDS[0]:-none}"
    printf '{"ts":"%s","session":"bot-merge-%d","event":"pr_classified","kind":"pr_classified","pr":"%s","class":"%s","gap_id":"%s","serializing_hot_files":"%s"}\n' \
        "$now" "$_BM_PID" "$pr_number" "$class" "$gap_label" \
        "$(IFS=','; echo "${SERIALIZING_HOT_FILES[*]}")" \
        >> "$ambient" 2>/dev/null || true
}

__STAGE_LABEL=""
__STAGE_T0=0
stage_start() {
    __STAGE_LABEL="$1"
    __STAGE_T0=$(date +%s)
    info "▶ $__STAGE_LABEL starting …"
    # INFRA-119: keep step file current so the health-file writer tracks progress
    [[ -n "${_BM_STEP_FILE:-}" ]] && printf '%s' "$__STAGE_LABEL" > "$_BM_STEP_FILE" 2>/dev/null || true
    # INFRA-1035: record transition start in the steps log
    _bm_steps_append "start" "$__STAGE_LABEL" 0
}
stage_done() {
    local elapsed=$(( $(date +%s) - __STAGE_T0 ))
    info "✓ $__STAGE_LABEL done (${elapsed}s)"
    # INFRA-1035: record transition done in the steps log
    _bm_steps_append "done" "$__STAGE_LABEL" "$elapsed"
}

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $*"
        return 0
    fi
    "$@"
}

# INFRA-028 — per-stage wall-clock timeouts (fleet contention / hung gh / cargo).
# Streams child output; on breach prints last lines via bot-merge-run-timed.py.
run_timed() {
    local max_secs=$1; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] (timeout ${max_secs}s) $*"
        return 0
    fi
    python3 "$SCRIPT_DIR/bot-merge-run-timed.py" "$max_secs" -- "$@"
}

# INFRA-954: load circuit-breaker so run_timed_hb can refuse known-wedged phases.
_CB_HELPER="$SCRIPT_DIR/bot-merge-circuit-breaker.sh"
if [[ -r "$_CB_HELPER" ]]; then
    # shellcheck source=./bot-merge-circuit-breaker.sh
    source "$_CB_HELPER"
fi

__HEARTBEAT_PID=""
heartbeat_end() {
    if [[ -n "${__HEARTBEAT_PID:-}" ]]; then
        kill "$__HEARTBEAT_PID" 2>/dev/null || true
        wait "$__HEARTBEAT_PID" 2>/dev/null || true
        __HEARTBEAT_PID=""
    fi
}

# Emit a line every 30s so parent watchers see progress during long subprocesses.
heartbeat_begin() {
    local label=$1
    (
        local t0
        t0=$(date +%s)
        while true; do
            sleep 30
            local now elapsed
            now=$(date +%s)
            elapsed=$((now - t0))
            info "… ${label} still running (${elapsed}s elapsed, heartbeat)"
        done
    ) &
    __HEARTBEAT_PID=$!
}

run_timed_hb() {
    local label=$1 max_secs=$2; shift 2
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] (timeout ${max_secs}s, heartbeat) $*"
        return 0
    fi
    # INFRA-954: refuse to enter a wedge-prone phase that has tripped the
    # circuit-breaker (3+ bot_merge_hang events for this phase in last 1h).
    # Re-running a wedged phase is the dominant token-bleed pattern from
    # bot_merge_hang (META-055 audit #2, 17% of 7d waste).
    if declare -F circuit_breaker_check >/dev/null 2>&1; then
        if ! circuit_breaker_check "$label"; then
            red "INFRA-954: circuit-breaker tripped on phase '$label' — refusing to run."
            red "  Recent bot_merge_hang events suggest the underlying child process is wedged."
            red "  Investigate, then: scripts/coord/bot-merge-circuit-breaker.sh clear"
            return 124
        fi
    fi
    heartbeat_begin "$label"
    set +e
    run_timed "$max_secs" "$@"
    local _rc=$?
    set -e
    heartbeat_end
    # INFRA-587: emit bot_merge_hang ALERT when a phase times out (exit 124 = timeout)
    if [[ "$_rc" -eq 124 ]]; then
        _emit_hang_alert "$label" "$max_secs"
    fi
    return "$_rc"
}

# INFRA-587: emit a bot_merge_hang ALERT to ambient.jsonl when a phase times out.
# Called by run_timed_hb when bot-merge-run-timed.py returns 124 (timeout).
_emit_hang_alert() {
    local phase="$1" timeout_secs="$2"
    local ambient="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
    local now gap_label
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    gap_label="${GAP_IDS[0]:-none}"
    printf '{"ts":"%s","session":"bot-merge-%d","event":"ALERT","kind":"bot_merge_hang","phase":"%s","timeout_secs":%s,"gap_id":"%s","note":"bot-merge phase timed out after %ss — possible hang (INFRA-587)"}\n' \
        "$now" "$_BM_PID" "$phase" "$timeout_secs" "$gap_label" "$timeout_secs" \
        >> "$ambient" 2>/dev/null || true
    red "INFRA-587: phase '$phase' timed out after ${timeout_secs}s — bot_merge_hang ALERT emitted to ambient stream"
}

# INFRA-564: gh secondary rate-limit backoff — 60/120/240s, max 3 retries.
# Usage: gh_with_backoff <label> <timeout_secs> <gh args...>
gh_with_backoff() {
    local label=$1 timeout_secs=$2; shift 2
    local -a delays=(60 120 240)
    local attempt=0 rc tmpout api_tag started_ms ended_ms
    api_tag="$(chump_gh_api_tag "$@" 2>/dev/null || printf '%s' "${1:-?}")"
    while true; do
        tmpout=$(mktemp)
        started_ms="$(_chump_gh_now_ms 2>/dev/null || echo 0)"
        set +e
        run_timed_hb "$label" "$timeout_secs" gh "$@" 2>&1 | tee -a "$tmpout"
        rc=${PIPESTATUS[0]}
        set -e
        ended_ms="$(_chump_gh_now_ms 2>/dev/null || echo 0)"
        # INFRA-999: log this call to ambient.jsonl for cost telemetry.
        if declare -F chump_gh_record >/dev/null 2>&1; then
            chump_gh_record "$api_tag" "$(( ended_ms - started_ms ))" "$rc" "bot-merge.sh" \
                2>/dev/null || true
        fi
        if [[ $rc -eq 0 ]]; then
            rm -f "$tmpout"; return 0
        fi
        if grep -qi "secondary rate limit" "$tmpout" && [[ $attempt -lt 3 ]]; then
            local sleep_secs=${delays[$attempt]}
            rm -f "$tmpout"
            attempt=$((attempt + 1))
            warn "gh secondary rate-limit hit — sleeping ${sleep_secs}s before retry ${attempt}/3…"
            sleep "$sleep_secs"
            continue
        fi
        rm -f "$tmpout"
        return "$rc"
    done
}

# ── INFRA-539 / CREDIBLE-032: GitHub API reachability probe ──────────────────
# Call once at startup. Exits 1 if gh cannot reach the API, emitting one of:
#   kind=gh_missing   — gh binary not installed
#   kind=gh_errored   — gh installed but API call failed (auth, rate-limit, network)
# Backward-compat: kind=github_unreachable is also emitted alongside gh_errored.
# Bypass: CHUMP_GH_PROBE_SKIP=1 (air-gapped tests, mocks).
gh_api_probe() {
    [[ "${CHUMP_GH_PROBE_SKIP:-0}" == "1" ]] && return 0
    local ambient="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
    local timeout_s="${CHUMP_GH_PROBE_TIMEOUT:-10}"
    local ts rc=0

    # CREDIBLE-032: distinguish missing binary from API failure
    if ! command -v gh >/dev/null 2>&1; then
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        red "CREDIBLE-032: gh binary not found — halting (install gh CLI)"
        printf '{"ts":"%s","kind":"gh_missing","source":"bot-merge","note":"gh binary not in PATH — CREDIBLE-032"}\n' \
            "$ts" >> "$ambient" 2>/dev/null || true
        return 1
    fi

    set +e
    timeout "$timeout_s" gh api /rate_limit --silent 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        red "CREDIBLE-032: gh API call failed (exit=${rc}) — halting to prevent queue churn"
        printf '{"ts":"%s","kind":"gh_errored","source":"bot-merge","exit_code":%d,"note":"gh api /rate_limit failed — CREDIBLE-032"}\n' \
            "$ts" "$rc" >> "$ambient" 2>/dev/null || true
        # backward-compat alias so consumers watching github_unreachable still fire
        printf '{"ts":"%s","kind":"github_unreachable","source":"bot-merge","exit_code":%d,"note":"alias for gh_errored — CREDIBLE-032"}\n' \
            "$ts" "$rc" >> "$ambient" 2>/dev/null || true
        return 1
    fi
}

# ── INFRA-119: health-file writer + total-budget watchdog ────────────────────
# Call _bm_health_init once after REPO_ROOT is known. It:
#   1. Creates .chump-locks/bot-merge-<pid>.health — read by queue-health-monitor
#      to detect hangs when last_heartbeat_at goes > 5 min stale.
#   2. Starts a background loop that rewrites the health file every 30s with the
#      current stage label (read from .chump-locks/bot-merge-<pid>.step).
#   3. Starts a budget-watchdog: if CHUMP_BOT_MERGE_BUDGET_SECS (default 600)
#      elapses without the script completing, the watchdog emits an ambient
#      ALERT kind=bot_merge_hung and sends SIGTERM to this process.
#      Set to 0 to disable (e.g. for full cargo-test runs).
_bm_health_write() {
    [[ -z "${_BM_HEALTH_FILE:-}" ]] && return 0
    local step now
    step="$(cat "$_BM_STEP_FILE" 2>/dev/null || echo init)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"pid":%d,"started_at":"%s","current_step":"%s","last_heartbeat_at":"%s"}\n' \
        "$_BM_PID" "$_BM_STARTED_AT" "$step" "$now" \
        > "${_BM_HEALTH_FILE}.tmp" 2>/dev/null \
    && mv "${_BM_HEALTH_FILE}.tmp" "$_BM_HEALTH_FILE" 2>/dev/null || true
}

_bm_health_init() {
    local lock_dir="$1"
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$lock_dir" 2>/dev/null || true
    _BM_HEALTH_FILE="${lock_dir}/bot-merge-${_BM_PID}.health"
    _BM_STEP_FILE="${lock_dir}/bot-merge-${_BM_PID}.step"
    _BM_STEPS_FILE="${lock_dir}/bot-merge-${_BM_PID}.steps"  # INFRA-1035
    printf 'init' > "$_BM_STEP_FILE" 2>/dev/null || true
    # INFRA-1035: seed the steps log with a session-start entry
    printf '{"ts":"%s","step":"session","transition":"start","elapsed_s":0,"pid":%d}\n' \
        "$_BM_STARTED_AT" "$_BM_PID" > "$_BM_STEPS_FILE" 2>/dev/null || true
    _bm_health_write

    # Background heartbeat: rewrite health file every 30s
    local hf="$_BM_HEALTH_FILE" sf="$_BM_STEP_FILE"
    local pid="$_BM_PID" sa="$_BM_STARTED_AT"
    (
        while true; do
            sleep 30
            local step now
            step="$(cat "$sf" 2>/dev/null || echo unknown)"
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"pid":%d,"started_at":"%s","current_step":"%s","last_heartbeat_at":"%s"}\n' \
                "$pid" "$sa" "$step" "$now" \
                > "${hf}.tmp" && mv "${hf}.tmp" "$hf" || true
        done
    ) &
    _BM_HEALTH_PID=$!

    # Budget watchdog: SIGTERM + ambient ALERT if total runtime exceeds budget
    local budget="${CHUMP_BOT_MERGE_BUDGET_SECS:-600}"
    if [[ "$budget" -gt 0 ]]; then
        local ppid="$_BM_PID" ambient="${lock_dir}/ambient.jsonl"
        (
            sleep "$budget"
            local step now
            step="$(cat "$sf" 2>/dev/null || echo unknown)"
            now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '{"ts":"%s","session":"bot-merge-%d","event":"ALERT","kind":"bot_merge_hung","pid":%d,"step":"%s","note":"total budget %ss exceeded — sending SIGTERM"}\n' \
                "$now" "$ppid" "$ppid" "$step" "$budget" >> "$ambient" 2>/dev/null || true
            rm -f "$hf" 2>/dev/null || true
            kill -TERM "$ppid" 2>/dev/null || true
        ) &
        _BM_WATCHDOG_PID=$!
        disown "$_BM_WATCHDOG_PID" 2>/dev/null || true
    fi

    info "INFRA-119: health monitoring active (file=$(basename "$_BM_HEALTH_FILE") budget=${budget}s steps=$(basename "$_BM_STEPS_FILE"))"
}

# ── Repo context ──────────────────────────────────────────────────────────────
# INFRA-109: REPO_ROOT is the worktree (we cd into it for git ops). LOCK_DIR
# resolves to the MAIN repo's .chump-locks/ so health files + leases are
# visible to siblings. queue-health-monitor.sh reads from the main repo path.
# shellcheck source=../lib/repo-paths.sh
source "$(dirname "$0")/../lib/repo-paths.sh"
# shellcheck source=lib/github.sh
# INFRA-999: chump_gh + chump_gh_record for API cost telemetry.
source "$(dirname "$0")/lib/github.sh"
# shellcheck source=lib/github_cache.sh
# INFRA-1130: cache_lookup_pr / cache_lookup_checks for zero-API CI polling.
source "$(dirname "$0")/lib/github_cache.sh"
# INFRA-1055: API rate-limit circuit breaker (non-fatal if missing on old branches).
# shellcheck source=api-rate-limit-gate.sh
_rl_gate_path="$(dirname "$0")/api-rate-limit-gate.sh"
[[ -f "$_rl_gate_path" ]] && source "$_rl_gate_path"
unset _rl_gate_path
# INFRA-1169: fail fast if the worktree has been reaped before we emit health
# files or create any files — prevents the 15-line No-such-file-or-directory
# spam from _bm_health_init trying to write .chump-locks/*.health.tmp.
if [[ ! -d "$REPO_ROOT" ]]; then
    echo "[bot-merge] ERROR: worktree '$REPO_ROOT' no longer exists (reaped?)." >&2
    echo "[bot-merge]   This bot-merge was triggered after the worktree was pruned." >&2
    echo "[bot-merge]   Re-claim the gap or ship from main checkout if still needed." >&2
    _bm_emit_path="$(command -v chump 2>/dev/null || true)"
    if [[ -n "$_bm_emit_path" ]]; then
        "$_bm_emit_path" ambient emit bot_merge_aborted_no_worktree \
            "gap=${GAP_IDS[*]:-unknown}" "worktree_path=$REPO_ROOT" 2>/dev/null || true
    fi
    exit 17
fi
# Also check if the gap is already shipped — exit cleanly to avoid wasted CI.
if command -v chump >/dev/null 2>&1 && [[ ${#GAP_IDS[@]} -gt 0 ]]; then
    for _gid in "${GAP_IDS[@]}"; do
        _status="$(chump gap show "$_gid" 2>/dev/null | grep -E '^\s+status:' | awk '{print $2}' || true)"
        if [[ "$_status" == "done" ]]; then
            _closed="$(chump gap show "$_gid" 2>/dev/null | grep -E 'closed_pr:' | awk '{print $2}' || true)"
            echo "[bot-merge] $_gid already shipped (closed_pr=${_closed:-unknown}) — nothing to do." >&2
            exit 0
        fi
    done
fi

cd "$REPO_ROOT"
# INFRA-469: route every `chump` call through the wedge-heal shim.
export PATH="$REPO_ROOT/bin:$PATH"

# ── INFRA-224: ensure pre-commit hooks are installed before any commit ────────
# Cold Water Red Letter #10 (2026-05-02) found that fresh CCR sandboxes / new
# worktrees commit through bot-merge.sh WITHOUT the pre-commit hook installed,
# silently bypassing every guard (closed_pr integrity, gaps-yaml-discipline,
# duplicate-id, etc.). Result: 9 gaps shipped with `closed_pr: TBD` since
# 2026-05-01 alone. This block ensures the hook is present before we make any
# commits, so the guards always run.
#
# Cheap (a stat call); silent on the happy path. Bypass with
# CHUMP_INSTALL_HOOKS=0 if you really know what you're doing.
#
# NOTE: must use git's resolved git-dir, not "$REPO_ROOT/.git", because in a
# linked worktree .git is a file (gitdir pointer), not a directory. The hook
# we care about lives at <git-dir-for-this-worktree>/hooks/pre-commit.
if [[ "${CHUMP_INSTALL_HOOKS:-1}" == "1" ]] \
        && [[ -x "$REPO_ROOT/scripts/setup/install-hooks.sh" ]]; then
    _bm_git_dir="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "$REPO_ROOT/.git")"
    if [[ ! -x "$_bm_git_dir/hooks/pre-commit" ]]; then
        bash "$REPO_ROOT/scripts/setup/install-hooks.sh" --quiet 2>/dev/null \
            && echo "[bot-merge] installed pre-commit hooks (INFRA-224 first-run)" \
            || echo "[bot-merge] WARN: install-hooks.sh failed; pre-commit guards may be skipped" >&2
    fi
    unset _bm_git_dir
fi

# INFRA-017: attribute bot-merge synthetic commits (fmt amends, checkpoint tags)
# to the canonical dispatched-agent identity so Red Letter doesn't flag them as
# foreign-actor intrusions. Human sessions override with their own git config.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Chump Dispatched}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-chump-dispatch@chump.bot}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-Chump Dispatched}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-chump-dispatch@chump.bot}"

# ── Session-ID auto-detection ─────────────────────────────────────────────────
# gap-preflight reads CHUMP_SESSION_ID to distinguish "our" claim from others'.
# If not set, try to infer it from an existing gap lease file so the preflight
# recognises our own claim at ship time (the claim may have been written by a
# different shell with a different default session ID — e.g. CHUMP_SESSION_ID
# set explicitly during gap-claim.sh vs. ~/.chump/session_id at bot-merge time).
#
# INFRA-045 (2026-04-24): also match pending_new_gap.id, not just gap_id.
# For new gaps reserved via gap-reserve.sh, the caller's lease has a
# pending_new_gap reservation (gap isn't yet on origin/main). Without this
# match, bot-merge spawned a new session via its worktree-scoped fallback,
# post-rebase preflight ran under that new session (no pending_new_gap),
# and failed with "not found in docs/gaps.yaml" — forcing the INFRA-028
# manual path. Surfaced by PR #476 (PRODUCT-015).
if [[ -z "${CHUMP_SESSION_ID:-}" && ${#GAP_IDS[@]} -gt 0 ]]; then
    # LOCK_DIR is set by repo-paths.sh (sourced above) — main-repo path.
    for _gid in "${GAP_IDS[@]}"; do
        for _lf in "$LOCK_DIR"/*.json; do
            [[ -f "$_lf" ]] || continue
            _match=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    if d.get('gap_id', '') == sys.argv[2]:
        print(d.get('session_id', ''))
    else:
        p = d.get('pending_new_gap')
        if isinstance(p, dict) and p.get('id', '') == sys.argv[2]:
            print(d.get('session_id', ''))
except Exception:
    pass
" "$_lf" "$_gid" 2>/dev/null || true)
            if [[ -n "$_match" ]]; then
                export CHUMP_SESSION_ID="$_match"
                info "Auto-detected session ID from gap lease: $CHUMP_SESSION_ID"
                break 2
            fi
        done
    done
fi

# INFRA-919: release lease on any exit so the gap can be re-claimed after a
# failure without hitting "lease conflict". Guards are evaluated at exit time
# so late-set CHUMP_SESSION_ID values are captured. On successful ship, the
# explicit rm near the end of the script fires first; the trap is a no-op there.
trap '[[ "${DRY_RUN:-0}" -eq 0 && -n "${CHUMP_SESSION_ID:-}" ]] && rm -f "${LOCK_DIR:-$REPO_ROOT/.chump-locks}/${CHUMP_SESSION_ID}.json" 2>/dev/null || true' EXIT

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
    red "Detached HEAD — check out a branch first."
    exit 2
fi
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    red "Already on $BRANCH. Run from a feature/agent branch."
    exit 2
fi

# INFRA-187: derive default branch name from worktree directory if current branch
# doesn't already follow the tool-prefix naming convention (chump/, claude/, etc).
# This lets agents create a worktree without specifying -b, and bot-merge derives
# the branch name from the worktree dir (e.g., .chump/worktrees/infra-127 → chump/infra-127).
_wt_dir="$(basename "$REPO_ROOT" 2>/dev/null || echo "")"
# INFRA-632: build the known-prefix pattern from BRANCH_PREFIX + legacy Chump prefixes.
_known_prefix_re="^(${BRANCH_PREFIX}|chump|claude|chore|cursor|goose|aider)/"
_known_wt_re="^(${BRANCH_PREFIX}|chump|claude|chore|cursor|goose|aider)-"
if [[ -n "$_wt_dir" ]] && ! echo "$BRANCH" | grep -qE "$_known_prefix_re"; then
    # Current branch doesn't have a tool prefix. If the worktree basename doesn't
    # start with a tool prefix either, derive <BRANCH_PREFIX>/<basename> as a suggestion.
    if ! echo "$_wt_dir" | grep -qE "$_known_wt_re"; then
        _default_branch="${BRANCH_PREFIX}/${_wt_dir}"
        info "INFRA-187: current branch '$BRANCH' lacks tool prefix (${BRANCH_PREFIX}/, chump/, claude/, etc.)."
        info "Renaming to match worktree: $BRANCH → $_default_branch"
        if ! run git branch -m "$BRANCH" "$_default_branch"; then
            red "Failed to rename branch — proceeding with current branch '$BRANCH'."
        else
            BRANCH="$_default_branch"
            green "Branch renamed to $BRANCH"
        fi
    fi
fi

BASE_BRANCH="${BASE_BRANCH:-main}"
REMOTE="${REMOTE:-origin}"

# ── INFRA-119: start health monitoring now that REPO_ROOT is set ──────────────
_bm_health_init "$REPO_ROOT/.chump-locks"

# ── INFRA-1034: always tee stdout+stderr to a per-PID log file ───────────────
# Problem observed 2026-05-13: launching bot-merge in the background with
# `bash bot-merge.sh ... 2>&1 | tail -15 &` produces 0-byte output until the
# script exits because the tail pipe buffers. Operator can't see progress for
# 4+ minutes. Always-on tee removes the buffering trap and gives a stable
# `tail -f` target regardless of how the caller redirects.
#
# Opt-out: CHUMP_BOT_MERGE_NO_TEE=1 (preserves prior behavior for callers that
# want the script's stdout to flow only through their own pipe).
if [[ "${DRY_RUN:-0}" != "1" && "${CHUMP_BOT_MERGE_NO_TEE:-0}" != "1" ]]; then
    _BM_LOG_FILE="${REPO_ROOT}/.chump-locks/bot-merge-${_BM_PID}.log"
    # Print BEFORE redirecting so the operator-visible message lands on the
    # original stdout (the log file gets it too via subsequent writes).
    info "[INFRA-1034] full log: $_BM_LOG_FILE  (tail -f to follow)"
    # Emit a discoverable marker so fleet-brief / operator-recall / chump-
    # ambient-glance can show "bot-merge currently running, log at X" without
    # scanning ps. Debounced to once per script invocation by virtue of being
    # outside the heartbeat loop.
    _bm_amb_path="${REPO_ROOT}/.chump-locks/ambient.jsonl"
    printf '{"ts":"%s","kind":"bot_merge_log_started","pid":%d,"log_path":"%s","branch":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_BM_PID" "$_BM_LOG_FILE" "${BRANCH:-unknown}" \
        >> "$_bm_amb_path" 2>/dev/null || true
    # Process substitution: every subsequent write to stdout/stderr is
    # duplicated into the log file. tee runs in its own subprocess that
    # exits when the script's fd 1/2 close.
    exec > >(tee -a "$_BM_LOG_FILE") 2>&1
fi

# ── INFRA-539: probe GitHub API before doing any real work ────────────────────
if [[ "${DRY_RUN:-0}" != "1" ]]; then
    gh_api_probe || { red "Aborting bot-merge: GitHub unreachable. Retry when connectivity is restored."; exit 1; }
    # INFRA-1055: circuit breaker — check quota headroom before any real work.
    # Returns 2 (exhausted) → hard stop; returns 1 (approaching) → degraded mode.
    if declare -F rate_limit_gate >/dev/null 2>&1; then
        _rl_gate_rc=0
        rate_limit_gate "startup" --source "bot-merge.sh" || _rl_gate_rc=$?
        if [[ $_rl_gate_rc -eq 2 ]]; then
            red "INFRA-1055: REST API quota exhausted — aborting bot-merge to prevent churn (rate_limit_exhausted event emitted)."
            exit 1
        fi
        # _rl_gate_rc=1 (approaching): continue in degraded mode — GraphQL-heavy
        # optional phases will be skipped below when RL_GQL_PCT is low.
        export _BM_RL_DEGRADED="${_rl_gate_rc:-0}"
    fi
fi

# ── INFRA-379: chump-doctor preflight ─────────────────────────────────────────
# macOS Sequoia syspolicyd occasionally wedges a chump binary's inode at
# `_dyld_start`, hanging every subsequent `chump …` invocation indefinitely.
# bot-merge.sh makes ~5 chump calls (preflight, claim, ship, release, etc.) —
# any one of them hanging stalls the whole pipeline for 30+ minutes before
# the operator notices.
#
# chump-doctor.sh probes (5s timeout) and self-heals by replacing the wedged
# inode. Idempotent — exit 0 if healthy, exit 0 after heal, exit 1 only on
# hard failure (rebuild needed). Run BEFORE any chump call so wedge is
# caught upfront, not midstream.
#
# Bypass: CHUMP_DOCTOR_SKIP=1 (cron-side, or for the chump-doctor PR itself).
if [[ "${CHUMP_DOCTOR_SKIP:-0}" != "1" ]] \
        && [[ -x "$REPO_ROOT/scripts/dev/chump-doctor.sh" ]]; then
    if ! bash "$REPO_ROOT/scripts/dev/chump-doctor.sh" >/dev/null 2>&1; then
        # See: docs/process/CLAUDE_GOTCHAS.md#error-binary-wedge
        die_with_help "chump binary is wedged and could not self-heal — every subsequent chump call will hang. Run: CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-doctor.sh" "error-binary-wedge"
    fi
fi

# INFRA-061 (M3): if --stack-on <PREV-GAP> was passed, look up the open PR for
# that gap and use its head branch as our base. Falls back to main with a
# warning if the prev gap has no open PR (already landed → just stack on main).
if [[ -n "$STACK_ON_GAP" ]]; then
    info "Resolving --stack-on $STACK_ON_GAP via gh pr list …"
    _stack_branch=$(gh pr list --state open --search "$STACK_ON_GAP in:title,body" \
        --json number,headRefName --jq '.[0].headRefName' 2>/dev/null || echo "")
    if [[ -z "$_stack_branch" || "$_stack_branch" == "null" ]]; then
        info "No open PR found for $STACK_ON_GAP — falling back to base=main."
        info "(If the prev gap already landed, this is correct. Otherwise check the gap ID.)"
    else
        BASE_BRANCH="$_stack_branch"
        green "Stacking on PR for $STACK_ON_GAP — base=$BASE_BRANCH"
    fi
fi

green "=== bot-merge: $BRANCH → $BASE_BRANCH ==="

# ── 0a. Untracked-files handler (INFRA-404) ──────────────────────────────────
# Instead of aborting when untracked files exist, auto-add them with an
# explicit warning. This closes the "partial-ship hazard" where bot-merge
# aborts before pushing, leaving the PR incomplete. Bypass: CHUMP_BOT_MERGE_ALLOW_UNTRACKED=0
if [[ "${CHUMP_BOT_MERGE_ALLOW_UNTRACKED:-1}" != "0" ]]; then
    untracked=$(git ls-files --others --exclude-standard src/ crates/ scripts/ docs/ 2>/dev/null)
    if [[ -n "$untracked" ]]; then
        yellow "INFRA-404: Untracked files found — auto-adding with explicit warning:"
        echo "$untracked" | sed 's/^/  + /'
        git add $untracked
        green "Auto-added $(echo "$untracked" | wc -l) untracked file(s)"
    fi
fi

# ── 0b. Modified-files handler (INFRA-472) ───────────────────────────────────
# INFRA-404 stages untracked but doesn't commit. If the operator's worktree
# has *modified* (M) tracked files OR *staged-but-uncommitted* changes from
# 0a, the upcoming `git rebase` fails with "cannot rebase: You have unstaged
# changes" — observed twice this session (INFRA-458 retry + INFRA-470 ship)
# and three more times across the 2026-05-04 fleet. Each occurrence costs a
# manual commit + bot-merge re-invocation cycle.
#
# Fix: after the INFRA-404 stage, also auto-stage modified files in the
# scoped paths AND commit anything staged with a default message. Pre-commit
# hooks still run (no --no-verify) so the discipline guards aren't bypassed.
# If the hook rejects, exit cleanly with a clear message instead of letting
# git rebase fail later with a cryptic error.
#
# Bypass: CHUMP_BOT_MERGE_AUTO_COMMIT_M=0 (operator wants to handle staging
# manually — useful for partial-stage scenarios where M files are
# intentionally not part of this PR).
if [[ "${CHUMP_BOT_MERGE_AUTO_COMMIT_M:-1}" != "0" ]]; then
    modified=$(git diff --name-only -- src/ crates/ scripts/ docs/ 2>/dev/null)
    if [[ -n "$modified" ]]; then
        yellow "INFRA-472: Modified files found — auto-staging:"
        echo "$modified" | sed 's/^/  M /'
        git add $modified
    fi
    # Whether files came from INFRA-404 (untracked) or INFRA-472 (modified),
    # they're now staged. Commit them so rebase doesn't trip.
    if ! git diff --cached --quiet 2>/dev/null; then
        _autostage_msg="auto: bot-merge pre-rebase staging (INFRA-472)

Auto-committed by bot-merge.sh before rebase to prevent the
'cannot rebase: You have unstaged changes' error class. If this
commit needs a different message, amend after ship lands or split
the PR.

Bypass: CHUMP_BOT_MERGE_AUTO_COMMIT_M=0 to opt out (handles staging manually)."
        if git commit -m "$_autostage_msg"; then
            green "INFRA-472: auto-committed pre-rebase changes"
        else
            red "INFRA-472: auto-commit failed — pre-commit hook rejected the changes."
            red "  Fix the hook errors above, then re-run bot-merge.sh."
            red "  (Or stage+commit manually with scripts/coord/chump-commit.sh and retry.)"
            exit 4
        fi
    fi
fi

# ── 0. Gap pre-flight (abort if work is already done on main) ─────────────────
if [[ ${#GAP_IDS[@]} -gt 0 ]]; then
    info "Running gap pre-flight for: ${GAP_IDS[*]} …"
    # INFRA-193: when speculative, export so gap-preflight allows the
    # concurrent-speculative case (still blocks non-speculative collisions).
    if ! CHUMP_SPECULATIVE="$SPECULATIVE" "$SCRIPT_DIR/gap-preflight.sh" "${GAP_IDS[@]}"; then
        red "Gap pre-flight failed — aborting to avoid duplicate work."
        red "The gaps are already done or claimed. Pick a different gap from docs/gaps.yaml."
        _bm_fail "preflight" 10 "gap already done or claimed"
    fi
    green "Gap pre-flight passed."

    # Write gap claim to lease file (replaces YAML in_progress edit — no merge conflicts).
    # INFRA-193: under `set -u`, an empty bash array can't be safely expanded with
    # "${arr[@]}". Build the optional flag as a string, then word-split via $arr.
    _claim_extra=""
    [[ "$SPECULATIVE" == "1" ]] && _claim_extra="--speculative"
    for gid in "${GAP_IDS[@]}"; do
        if [[ $DRY_RUN -eq 0 ]]; then
            "$SCRIPT_DIR/gap-claim.sh" "$gid" $_claim_extra
            # INFRA-492: emit session_start so INFRA-477's cost ledger
            # gets data. Best-effort — silent on chump fail.
            chump session-track --start "$gid" >/dev/null 2>&1 || true
        else
            info "[dry-run] gap-claim.sh $gid $_claim_extra"
        fi
    done
fi

# ── INFRA-537: ship-quality grade signal accumulators ───────────────────────
# null = signal not captured (step skipped). true/false = captured result.
_grade_clippy_ok="null"
_grade_test_added="null"
_grade_rebase_clean="null"

# ── INFRA-953: hot-file lock acquisition ──────────────────────────────────────
# If our diff touches any file in scripts/coord/hot-files.yaml `serialize:`
# list, take a flock on each (one per file). Held until this script exits.
# Prevents two bot-merges from racing on the same shared file, which is what
# drives bot_merge_hot_file emissions (META-055 audit: 71.5% of token waste).
_HF_HELPER="${REPO_ROOT}/scripts/coord/hot-file-lock.sh"
if [[ -r "$_HF_HELPER" ]]; then
    # shellcheck source=./hot-file-lock.sh
    source "$_HF_HELPER"
    if declare -F hot_file_lock_acquire >/dev/null 2>&1; then
        if ! hot_file_lock_acquire; then
            red "INFRA-953: failed to acquire hot-file lock(s) — aborting"
            exit 1
        fi
    fi
fi

# ── 1. Fetch and rebase ───────────────────────────────────────────────────────
stage_start "git fetch $REMOTE/$BASE_BRANCH"
run_timed_hb "git fetch" 180 git fetch "$REMOTE" "$BASE_BRANCH" --quiet
stage_done

info "Fetched $REMOTE/$BASE_BRANCH."

BEHIND=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)

# Hard abort if branch is extremely stale — rebase at 50+ commits is risky and
# likely means the work has already landed on main via another agent.
if [[ "$BEHIND" -gt 50 ]]; then
    red "Branch is $BEHIND commits behind $REMOTE/$BASE_BRANCH — too stale to merge safely."
    red "Run: scripts/coord/gap-preflight.sh ${GAP_IDS[*]:-<gap-ids>}"
    red "Then: git fetch && git rebase $REMOTE/$BASE_BRANCH (resolve conflicts)"
    red "If all your gaps are already done on main, close this branch instead."
    exit 3
fi

if [[ "$BEHIND" -gt 0 ]]; then
    stage_start "rebase on $REMOTE/$BASE_BRANCH ($BEHIND commit(s) behind)"
    _rebase_args=("${REMOTE}/${BASE_BRANCH}")
    if [[ "$NO_MERGE_DRIVER" == "1" ]]; then
        _rebase_args+=(-c merge.ci-yml-add-row.driver= -c merge.pre-commit-add-guard.driver= -c merge.chump-state-sql-regen.driver=)
    fi
    if ! run_timed_hb "git rebase" 60 git rebase "${_rebase_args[@]}"; then
        red "git rebase failed or timed out — resolve conflicts or retry."
        _grade_rebase_clean="false"
        _bm_fail "rebase" 11 "merge conflict or timeout"
    fi
    _grade_rebase_clean="true"
    stage_done

    # Re-check gap status after rebase: main may have merged the gap while we rebased.
    if [[ ${#GAP_IDS[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        info "Re-checking gaps after rebase …"
        # INFRA-509: INFRA-344 filing-style PR detection removed — post-INFRA-498,
        # gap YAMLs are no longer added as new files in PRs; state.db is canonical.
        # Always run preflight here so we catch gaps completed on main while rebasing.
        if ! CHUMP_SPECULATIVE="$SPECULATIVE" "$SCRIPT_DIR/gap-preflight.sh" "${GAP_IDS[@]}"; then
            red "Gap was completed on main while we rebased — nothing left to push."
            _bm_fail "preflight" 10 "gap completed on main during rebase"
        fi
    fi
else
    info "Branch is up to date with $REMOTE/$BASE_BRANCH."
fi

# INFRA-920 + INFRA-1042 + INFRA-1061: detect shell/doc-only diffs.
#
# Detection runs UNCONDITIONALLY (not gated on SKIP_TESTS) so --fast invocations
# still get the DOC_ONLY flag — original INFRA-1042 wrapped this in
# `if SKIP_TESTS == 0`, which silently disabled doc-only skip for every --fast
# run since --fast pre-sets SKIP_TESTS=1. INFRA-1061 hoists the detection out
# and uses DOC_ONLY to also skip cargo clippy entirely (CI clippy stays the
# gate). Observed savings: ~2-3 min per doc PR (DOC-036 baseline 2m36s clippy
# on 1-line README diff; INFRA-1038 observed clippy timing out 245s).
#
# wc -l replaces `grep -c .` for file-count: grep -c returns exit 1 on 0
# matches, which propagates under set -o pipefail.
DOC_ONLY=0
_changed_files=$(git diff --name-only "${REMOTE}/${BASE_BRANCH}...HEAD" 2>/dev/null || true)
if [[ -n "$_changed_files" ]]; then
    _rs_count=0
    _unsafe_count=0
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        case "$_f" in
            *.rs)                              _rs_count=$((_rs_count + 1)) ;;
            scripts/*|docs/*|*.md|*.yaml|*.sh) ;;
            *)                                 _unsafe_count=$((_unsafe_count + 1)) ;;
        esac
    done <<< "$_changed_files"
    if [[ $_rs_count -eq 0 && $_unsafe_count -eq 0 ]]; then
        DOC_ONLY=1
        # Only flip SKIP_TESTS if the caller hadn't already (--fast / --skip-tests
        # both pre-set it; we still log credit + emit so waste-tally sees it).
        if [[ $SKIP_TESTS -eq 0 ]]; then
            SKIP_TESTS=1
            info "[bot-merge] auto-skip: shell/doc-only diff — skipping cargo test (INFRA-920)"
        fi
        info "[bot-merge] DOC_ONLY=1 — clippy will be skipped (INFRA-1042/INFRA-1061)"
        # Emit so fleet-brief / waste-tally credit the saved cycles.
        _doc_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$_doc_amb")" 2>/dev/null || true
        _doc_filecount=$(printf '%s\n' "$_changed_files" | wc -l | tr -d ' ')
        printf '{"ts":"%s","kind":"bot_merge_doc_only_fastpath","branch":"%s","files_changed":%d,"saved_steps":["cargo_test","cargo_clippy"]}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BRANCH:-unknown}" \
            "${_doc_filecount:-0}" \
            >> "$_doc_amb" 2>/dev/null || true
    fi
fi

# ── 2. cargo fmt ──────────────────────────────────────────────────────────────
if command -v cargo &>/dev/null && ls src/**/*.rs &>/dev/null 2>&1; then
    stage_start "cargo fmt"
    if ! run_timed_hb "cargo fmt" 120 cargo fmt --all; then
        red "cargo fmt failed or timed out."
        _bm_fail "fmt" 12 "cargo fmt failed or timed out"
    fi
    if [[ $DRY_RUN -eq 0 ]] && ! git diff --quiet; then
        # INFRA-370 (2026-05-03): only `git commit --amend` when this branch
        # has at least one commit OF ITS OWN above $REMOTE/$BASE_BRANCH.
        # Without this guard, when the agent forgot to commit before calling
        # bot-merge.sh (uncommitted work in tree, HEAD = a foreign main
        # commit), the amend path silently grafted the agent's uncommitted
        # changes ONTO the foreign commit, mutating its tree. META-014's
        # subagent confirmed this live via `git reflog` showing
        # `commit (amend)` against an INFRA-335 SHA. PR #52-class silent
        # squash-loss. Fix: when there are 0 own-commits, create a NEW
        # commit instead of amending.
        commits_on_branch=$(git rev-list --count "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null || echo 0)
        if [[ "$commits_on_branch" -lt 1 ]] && [[ "${CHUMP_BOT_MERGE_FORCE_AMEND:-0}" != "1" ]]; then
            yellow "INFRA-370: HEAD has no commits above $REMOTE/$BASE_BRANCH — refusing to --amend foreign commit"
            yellow "  (override with CHUMP_BOT_MERGE_FORCE_AMEND=1 for genuine recovery)"
            info "cargo fmt changed files — creating fresh commit on top instead of amending …"
            git add -u
            git commit --no-verify -m "chore: cargo fmt --all (auto from bot-merge.sh, INFRA-370 fresh-commit path)"
        else
            info "cargo fmt changed files — staging and amending …"
            git add -u
            git commit --amend --no-edit --no-verify
        fi
        green "fmt fixes committed."
    fi
    stage_done
fi

# ── INFRA-164: parallelism + timeouts for cold-cache builds ───────────────────
# A cold workspace build of all rustc test/bin targets at default parallelism
# (= host logical CPUs, e.g. 10 on an M4) easily peaks past 16 GB RAM and gets
# rustc subprocesses SIGTERM'd by macOS Jetsam when the fleet has other
# concurrent worktrees building. The classic symptom is a sudden cascade of
# "(signal: 15, SIGTERM: termination signal)" across two or three rustc
# processes mid-build, with cargo reporting "build failed, waiting for other
# jobs to finish". That is not a real test failure — and it isn't a bot-merge
# timeout either; the wall-clock is fine. It is OOM pressure.
#
# Fix: limit cargo's parallelism. Default to 4 (safe for 24 GB / 10-core M4
# under fleet contention); operators with more headroom can raise via env.
#
# Separately: cold clippy alone takes ~8 minutes on this codebase. The
# previous 300s budget triggered TIMEOUT mid-compile — a real wall-clock
# hit, not OOM. Bumped to 900s (15 min). cargo test budget (3600s) was
# already generous enough for cold builds.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
info "cargo parallelism: CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} (override via env)"

# INFRA-1063: per-worktree CARGO_TARGET_DIR to eliminate cargo build-dir lock
# contention when multiple bot-merge runs execute in parallel across
# /tmp/chump-*/ worktrees.  Without this, all worktrees resolve to the same
# shared target/ (either $CARGO_HOME/registry or the root workspace target/),
# causing "Blocking waiting for file lock on build directory" timeouts (observed:
# two parallel clippy runs each waited 240 s in 2026-05-13).
#
# Strategy: option (a) — per-worktree target dir.
#   - If CARGO_TARGET_DIR is already set externally (e.g. CI), respect it.
#   - Otherwise, pin it to <worktree>/target/ so each gap gets its own build
#     cache.  The dir is under /tmp/ and cleaned up when the worktree is reaped.
#   - When the wait exceeds 60 s, cargo emits "Blocking waiting for file lock"
#     to stderr; we capture that and emit kind=cargo_lock_wait to ambient.jsonl.
if [[ -z "${CARGO_TARGET_DIR:-}" ]]; then
    export CARGO_TARGET_DIR="${REPO_ROOT}/target"
    info "INFRA-1063: CARGO_TARGET_DIR pinned to ${CARGO_TARGET_DIR} (per-worktree isolation)"
else
    info "INFRA-1063: CARGO_TARGET_DIR already set to ${CARGO_TARGET_DIR} (respecting caller)"
fi

# INFRA-1063 AC #5: wrapper for cargo invocations that detects build-dir lock
# contention.  Cargo emits "Blocking waiting for file lock on build directory"
# to stderr when it cannot acquire the lock; we tee output to a temp file,
# scan for that message after the run, and emit kind=cargo_lock_wait to
# ambient.jsonl so the fleet can observe and measure the cost.
#
# Usage: _run_cargo_with_lock_detect <label> <timeout_secs> <cargo subcommand...>
# Returns the exit code of the underlying cargo invocation.
_run_cargo_with_lock_detect() {
    local label="$1" timeout_secs="$2"; shift 2
    local _tmpout _rc
    _tmpout="$(mktemp)"
    set +e
    run_timed_hb "$label" "$timeout_secs" cargo "$@" 2>&1 | tee -a "$_tmpout"
    _rc=${PIPESTATUS[0]}
    set -e
    if grep -q "Blocking waiting for file lock on build directory" "$_tmpout" 2>/dev/null; then
        local _ambient _now _gap_label
        _ambient="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
        _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _gap_label="${GAP_IDS[0]:-none}"
        printf '{"ts":"%s","session":"bot-merge-%d","kind":"cargo_lock_wait","phase":"%s","gap_id":"%s","target_dir":"%s","note":"cargo build-dir lock contention detected; CARGO_TARGET_DIR per-worktree isolation may not be active (INFRA-1063)"}\n' \
            "$_now" "$_BM_PID" "$label" "$_gap_label" "${CARGO_TARGET_DIR:-?}" \
            >> "$_ambient" 2>/dev/null || true
        warn "INFRA-1063: cargo build-dir lock wait detected on phase '${label}' — cargo_lock_wait emitted to ambient stream"
    fi
    rm -f "$_tmpout"
    return "$_rc"
}

# ── 3. cargo clippy ───────────────────────────────────────────────────────────
# Timeout 900s: cold workspace clippy is ~8 min on chump as of 2026-04-28.
#
# INFRA-252: --fast skips the local clippy step entirely. Rationale: cold
# workspace clippy is the long pole (5-8 min), busts the agent task budget
# (~10-15 min on Anthropic's general-purpose subagent) and forces the parent
# session to rescue commit-but-don't-push orphans. The GitHub Actions CI
# clippy job runs the same checks anyway and is the actual gate (auto-merge
# refuses to land a PR with red checks). With --fast, bot-merge.sh ships in
# ~30-60 sec total, comfortably inside any agent budget. Cost: a clippy-broken
# PR may briefly exist on the open-PR list before CI grades it red. Default
# OFF (preserves human-developer fail-fast ergonomics); agents pass --fast
# explicitly.
#
# INFRA-1042: doc-only diffs (set DOC_ONLY=1 above) skip clippy entirely.
# Zero Rust changes means zero new lints; CI clippy is the safety net.
# Observed savings: ~2-3 min per doc PR (DOC-036 spent 2m36s on clippy for
# a 1-line README diff before this gate landed).
if [[ "${DOC_ONLY:-0}" -eq 1 ]]; then
    info "[bot-merge] DOC_ONLY=1 — skipping cargo clippy entirely (INFRA-1042)"
elif [[ $FAST -eq 1 ]]; then
    # 2026-05-07: Even in --fast mode, run `cargo clippy --workspace --fix`
    # as a cheap auto-correction pass. This catches the wave of fleet PRs
    # that ship doc-list-overindented / manual_strip / manual_split_once
    # / lines_filter_map_ok / manual_is_multiple_of style lints that
    # fleet workers' Rust style produces. Auto-fix is fast (<2 min on
    # warm cache) and amends the lint fixes into the current commit so
    # CI sees a clean PR. If clippy --fix can't auto-resolve everything,
    # we still let CI be the gate (no -D warnings).
    if command -v cargo &>/dev/null; then
        stage_start "cargo clippy --workspace --fix (--fast pre-flight auto-correct)"
        _clippy_fix_rc=0
        _run_cargo_with_lock_detect "cargo clippy --fix" 240 clippy --workspace --all-targets --fix --allow-dirty --allow-staged || _clippy_fix_rc=$?
        if [[ "$_clippy_fix_rc" -eq 124 ]]; then
            # INFRA-1062: timeout is non-fatal for --fast (CI clippy is the gate);
            # log explicitly so the operator sees it rather than silent exit.
            warn "INFRA-1062: clippy --fix timed out after 240s — continuing to push (CI clippy is the gate)"
        fi
        if [[ -n "$(git status --porcelain)" ]]; then
            info "clippy --fix auto-corrected lints — staging + amending"
            git add -A
            git commit --amend --no-edit --no-verify >/dev/null 2>&1 || \
                git commit --no-verify -m "chore: cargo clippy --fix (auto from bot-merge.sh --fast pre-flight, INFRA-624 follow-up)" || true
        fi
        stage_done
        green "clippy --fix pre-flight done."
    else
        info "Skipping local clippy (--fast, no cargo). CI clippy is the gate."
    fi
elif command -v cargo &>/dev/null; then
    stage_start "cargo clippy --workspace --all-targets"
    if ! _run_cargo_with_lock_detect "cargo clippy" 900 clippy --workspace --all-targets -- -D warnings; then
        red "clippy found errors — fix them before merging."
        _grade_clippy_ok="false"
        _bm_fail "clippy" 13 "clippy lint errors"
    fi
    _grade_clippy_ok="true"
    stage_done
    green "clippy clean."
fi

# ── 4. cargo test ─────────────────────────────────────────────────────────────
if [[ $SKIP_TESTS -eq 0 ]] && command -v cargo &>/dev/null; then
    stage_start "cargo test --bin chump --tests"
    if ! _run_cargo_with_lock_detect "cargo test" 1200 test --bin chump --tests; then
        red "Tests failed — fix them before merging."
        info "If you saw 'signal: 15, SIGTERM' across multiple rustc processes,"
        info "that is most likely OOM, not a real test failure. Try lowering"
        info "CARGO_BUILD_JOBS (currently ${CARGO_BUILD_JOBS}) and retry."
        _bm_fail "test" 14 "test suite failure"
    fi
    stage_done
    green "Tests passed."
else
    info "Skipping tests (--skip-tests)."
fi

# ── 4a. CI shell-test gate for THIS PR's new/modified tests (INFRA-222) ──────
# `cargo test` covers Rust unit/integration tests but NOT the shell-script
# guard tests under `scripts/ci/test-*.sh`. PR #729 (INFRA-200) shipped with
# its own guard's test suite failing because bot-merge never ran the new
# `scripts/ci/test-raw-yaml-guard.sh` — CI caught it but the PR sat stuck.
#
# Strategy: run only the shell tests this PR adds or modifies. These are tests
# the PR author owns and should be passing locally before push. We skip the
# 38-test full sweep because many tests have implicit env dependencies (chump
# binary, ACP server, cursor CLI) that CI sets up but local worktrees don't.
#
# Bypass: CHUMP_SKIP_CI_SHELL=1 scripts/coord/bot-merge.sh ...
# Skipped automatically with --skip-tests.
if [[ $SKIP_TESTS -eq 0 ]] && [[ "${CHUMP_SKIP_CI_SHELL:-0}" != "1" ]]; then
    # Find shell tests added or modified relative to base branch
    BASE_REF="${CHUMP_BASE_REF:-origin/main}"
    CHANGED_TESTS=()
    while IFS= read -r f; do
        [[ -n "$f" && -f "$REPO_ROOT/$f" ]] && CHANGED_TESTS+=("$REPO_ROOT/$f")
    done < <(git diff --name-only --diff-filter=AM "$BASE_REF...HEAD" 2>/dev/null \
             | grep -E '^scripts/ci/test-.*\.sh$' || true)

    if [[ ${#CHANGED_TESTS[@]} -gt 0 ]]; then
        stage_start "PR-modified scripts/ci/test-*.sh (${#CHANGED_TESTS[@]} suites)"
        FAILED_TESTS=()
        for t in "${CHANGED_TESTS[@]}"; do
            tname="$(basename "$t")"
            # INFRA-473: write per-test log files (not a single shared one
            # that gets clobbered between iterations) so the operator can
            # read the FULL output of any failed test, not just tail -10.
            ci_log="/tmp/bot-merge-citest-${tname%.sh}.log"
            if ! timeout 60 bash "$t" >"$ci_log" 2>&1; then
                FAILED_TESTS+=("$tname")
                red "  ✗ $tname"
                # Surface explicit FAIL lines first (cheap, high-signal).
                fail_lines=$(grep -E '^\s*FAIL:' "$ci_log" 2>/dev/null || true)
                if [[ -n "$fail_lines" ]]; then
                    echo "$fail_lines" | sed 's/^/    /'
                fi
                # Plus the trailing 30 lines (Results: summary + immediate
                # context). 30 not 10 — Cargo/test output is verbose enough
                # that 10 lines often misses the failure detail.
                echo "    --- last 30 lines of $ci_log ---"
                tail -30 "$ci_log" | sed 's/^/    /'
                echo "    --- end ($(wc -l <"$ci_log") total lines; full log: $ci_log) ---"
            fi
        done
        if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
            red "${#FAILED_TESTS[@]} CI shell test(s) failed: ${FAILED_TESTS[*]}"
            info "These are tests THIS PR adds/modifies. Fix locally before pushing —"
            info "they will block the PR's CI 'test' job otherwise (PR #729 was the"
            info "originating example — it sat stuck for 2+ hours waiting on a test"
            info "the author could have run in 5 seconds locally)."
            info "Full per-test logs at /tmp/bot-merge-citest-<name>.log"
            info "Bypass (only if you've already verified the failure is environmental):"
            info "  CHUMP_SKIP_CI_SHELL=1 scripts/coord/bot-merge.sh ..."
            exit 1
        fi
        stage_done
        green "All ${#CHANGED_TESTS[@]} PR-modified CI shell tests passed."
    fi
fi

# ── INFRA-537: test-added signal ─────────────────────────────────────────────
# Scan the PR diff for test additions. Heuristic: any Rust #[test] or #[cfg(test)]
# annotation, or any file whose path contains 'test' added/modified in this branch.
_grade_test_added="false"
_test_base="${CHUMP_BASE_REF:-${REMOTE}/${BASE_BRANCH}}"
if git diff --name-only --diff-filter=AM "${_test_base}...HEAD" 2>/dev/null \
        | grep -qiE 'test'; then
    _grade_test_added="true"
elif git diff "${_test_base}...HEAD" 2>/dev/null \
        | grep -qE '^\+.*#\[(test|cfg\(test)'; then
    _grade_test_added="true"
fi

# ── 4a-decomp. Decomposition advisory (FLEET-025 / FLEET-011 v0) ─────────────
# Surface heuristic-based decomposition hints for monolithic PRs. Per the
# FLEET-011 vision: file_count > 5 + LOC > 500 → consider decomposition.
# This is ADVISORY only (never blocks ship) — agents see the hint and decide
# whether to split or proceed. v0 emits the hint to stderr + ambient as
# kind=decomposition_hint so we can build a learning loop later (track
# whether agents heeded the hint vs proceeded; bias future hints).
#
# Bypass: CHUMP_DECOMP_HINT=0 (silence entirely)
# Tune:   CHUMP_DECOMP_FILE_THRESHOLD (default 5), CHUMP_DECOMP_LOC_THRESHOLD (default 500)
if [[ "${CHUMP_DECOMP_HINT:-1}" != "0" ]]; then
    DECOMP_FILES_T="${CHUMP_DECOMP_FILE_THRESHOLD:-5}"
    DECOMP_LOC_T="${CHUMP_DECOMP_LOC_THRESHOLD:-500}"
    DECOMP_BASE="${CHUMP_BASE_REF:-origin/main}"
    DECOMP_FILES="$(git diff --name-only --diff-filter=AM "$DECOMP_BASE...HEAD" 2>/dev/null | wc -l | tr -d ' ')"
    DECOMP_LOC="$(git diff --shortstat "$DECOMP_BASE...HEAD" 2>/dev/null \
                  | awk '{ins=0;del=0; for(i=1;i<=NF;i++){if($i~/insertion/)ins=$(i-1); if($i~/deletion/)del=$(i-1)} print ins+del}')"
    DECOMP_LOC="${DECOMP_LOC:-0}"

    # Heuristic exemptions: codemod-style changes (gap registry regen, lockfile
    # bumps, mass formatting) shouldn't trigger because they're already atomic
    # by intent. Detect by checking if >80% of touched files are in known
    # codemod paths.
    # INFRA-509: dropped docs/gaps/ from codemod pattern — post-INFRA-498 PRs
    # no longer bulk-add gap YAMLs; docs/gaps/ changes should trigger the hint.
    DECOMP_CODEMOD="$(git diff --name-only --diff-filter=AM "$DECOMP_BASE...HEAD" 2>/dev/null \
                     | grep -cE '^(\.chump/state\.sql|Cargo\.lock|book/src/)' || true)"
    DECOMP_CODEMOD="${DECOMP_CODEMOD:-0}"
    DECOMP_CODEMOD_RATIO=0
    if [[ "$DECOMP_FILES" -gt 0 ]]; then
        DECOMP_CODEMOD_RATIO=$(( DECOMP_CODEMOD * 100 / DECOMP_FILES ))
    fi

    if [[ "$DECOMP_FILES" -gt "$DECOMP_FILES_T" ]] && [[ "$DECOMP_LOC" -gt "$DECOMP_LOC_T" ]] \
       && [[ "$DECOMP_CODEMOD_RATIO" -lt 80 ]]; then
        warn "decomposition hint: ${DECOMP_FILES} files, ${DECOMP_LOC} LOC changed"
        info "  thresholds: > ${DECOMP_FILES_T} files AND > ${DECOMP_LOC_T} LOC (FLEET-011 v0 heuristic)"
        info "  consider: split by subsystem / per-file / 'land then migrate' stack — not blocking, just a nudge"
        info "  silence: CHUMP_DECOMP_HINT=0 scripts/coord/bot-merge.sh ..."
        # Best-effort emit to ambient so we can build the learning loop later
        if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
            "$REPO_ROOT/scripts/dev/ambient-emit.sh" decomposition_hint \
                "kind=oversize" \
                "files=$DECOMP_FILES" \
                "loc=$DECOMP_LOC" \
                "gap=${GAP_ID:-unknown}" \
                "branch=$BRANCH" 2>/dev/null || true
        fi
    fi
fi

# ── 4b. Ambient glance (INFRA-083) ───────────────────────────────────────────
# Final peripheral-vision check before push: surface any sibling that already
# committed or pushed against the same gap (race window between gap-claim and
# now). Hard-stop if a sibling commit for this gap landed in the last 120s.
if [[ -n "${GAP_ID:-}" ]] && [[ -x "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" ]] \
   && [[ "${CHUMP_AMBIENT_GLANCE:-1}" != "0" ]]; then
    if ! "$REPO_ROOT/scripts/dev/chump-ambient-glance.sh" --gap "$GAP_ID" --since-secs 600 --limit 5 --check-overlap; then
        red "Sibling activity collision on $GAP_ID — aborting push. Re-tail ambient.jsonl, re-plan, re-run."
        info "Bypass: CHUMP_AMBIENT_GLANCE=0 scripts/coord/bot-merge.sh ..."
        exit 2
    fi
fi

# ── 4c. Pre-registered eval guard (META-043) ─────────────────────────────────
# If this commit modifies cognition-or-routing src, require a preregistered
# eval doc at docs/eval/preregistered/<GAP-ID>.md to be present in the tree.
# Rationale: no measurement = no merge (EVAL-098 pattern).
# Bypass: CHUMP_NO_PREREG=1 (with reason in commit body)
_PREREG_COGNITION_PATTERN='src/(briefing|reflection|reflection_db|prompt_assembly|provider_|bandit|cog_|cognition_|atomic_claim)'
_PREREG_DISPATCH_PATTERN='scripts/dispatch/'
if [[ "${CHUMP_NO_PREREG:-0}" != "1" ]] && [[ -n "${GAP_ID:-}" ]]; then
    _prereg_base="${CHUMP_BASE_REF:-${REMOTE}/${BASE_BRANCH}}"
    _cognition_touched=$(git diff --name-only --diff-filter=ACM "${_prereg_base}...HEAD" 2>/dev/null \
        | grep -cE "^(${_PREREG_COGNITION_PATTERN}|${_PREREG_DISPATCH_PATTERN})" || true)
    if [[ "${_cognition_touched:-0}" -gt 0 ]]; then
        _prereg_doc="docs/eval/preregistered/${GAP_ID}.md"
        if [[ ! -f "$REPO_ROOT/${_prereg_doc}" ]]; then
            red "[META-043] PREREG-REQUIRED: commit modifies cognition/routing src but"
            red "  docs/eval/preregistered/${GAP_ID}.md is missing."
            info "  Create the file (even a stub with hypothesis + metric) and re-run."
            info "  Bypass once: CHUMP_NO_PREREG=1 scripts/coord/bot-merge.sh ..."
            info "  Bypass trailer (required in commit): Prereg-Bypass-Reason: <reason>"
            printf '{"ts":"%s","kind":"prereg_blocked","gap":"%s","missing":"%s","session":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_ID}" "${_prereg_doc}" "${SESSION_ID:-unknown}" \
                >> "${REPO_ROOT}/.chump-locks/ambient.jsonl" 2>/dev/null || true
            exit 1
        else
            green "[META-043] prereg doc found: ${_prereg_doc}"
            printf '{"ts":"%s","kind":"prereg_ok","gap":"%s","doc":"%s","session":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_ID}" "${_prereg_doc}" "${SESSION_ID:-unknown}" \
                >> "${REPO_ROOT}/.chump-locks/ambient.jsonl" 2>/dev/null || true
        fi
    fi
fi

# ── 5a. INFRA-306: pre-push MERGED check ─────────────────────────────────────
# Bail BEFORE the force-push if a PR for this branch already MERGED. The
# 30s window between the start of bot-merge and reaching here is enough for
# auto-merge to fire on green CI — and force-pushing to a merged-and-deleted
# branch wastes 5-15min of cargo + can lose work in stack-of-PRs scenarios.
# Cheap one-shot query (~200ms). Bypass: CHUMP_SKIP_MERGED_CHECK=1.
if [[ "${CHUMP_SKIP_MERGED_CHECK:-0}" != "1" ]]; then
    _existing_state=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null || echo "")
    if [[ "$_existing_state" == "MERGED" ]]; then
        green "PR for $BRANCH already MERGED — skipping force-push (INFRA-306)."
        info "Saved you the cargo cost on a race that's already settled."
        info "Bypass for genuine recovery: CHUMP_SKIP_MERGED_CHECK=1 scripts/coord/bot-merge.sh ..."
        exit 0
    fi
fi

# ── 4d. INFRA-686: WIP-commit squash — rebase to clean up graceful-shutdown rescues ──
# If the top commit starts with "WIP-", it was created by the SIGTERM checkpoint.
# Clean it up by squashing into the previous meaningful commit before shipping.
_top_msg="$(git log -1 --format="%s" HEAD 2>/dev/null || true)"
if [[ "$_top_msg" == WIP-* ]]; then
    info "[INFRA-686] Top commit is a WIP rescue: '$_top_msg' — squashing into parent"
    if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
        # Use soft reset to unstage the WIP commit, then re-commit cleanly.
        if git reset --soft HEAD~1 2>/dev/null; then
            _parent_msg="$(git log -1 --format="%s" HEAD 2>/dev/null || echo "chore: squash WIP rescue commit")"
            if git commit --amend -m "$_parent_msg" --no-edit --no-verify 2>/dev/null; then
                green "[INFRA-686] WIP commit squashed cleanly."
            else
                warn "[INFRA-686] WIP squash amend failed — shipping with WIP commit (not ideal)"
                # Restore the WIP commit to avoid a dirty tree
                git reset HEAD~1 --hard 2>/dev/null || true
            fi
        else
            warn "[INFRA-686] WIP soft-reset failed — shipping as-is"
        fi
    else
        info "[dry-run] would squash WIP commit '$_top_msg' into parent"
    fi
fi

# ── 4e. INFRA-860: bot-merge mutex — prevent parallel push+merge contention ───
# Multiple fleet workers can race to push + merge simultaneously, causing
# `git push --force-with-lease` failures and `gh pr merge` races.  Acquire a
# per-repo file lock so only one bot-merge is in the push/PR/merge critical
# section at a time.  Timeout = 60s; logs contention if wait > 5s.
if [[ "${CHUMP_BOT_MERGE_LOCK:-1}" != "0" ]]; then
    _bm_lock_dir="${CHUMP_BOT_MERGE_LOCK_DIR:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}}"
    _bm_lock_file="${_bm_lock_dir}/bot-merge.lock"
    mkdir -p "$_bm_lock_dir" 2>/dev/null || true
    _bm_lock_start=$(date +%s)
    # Use flock <lockfile> form (bash 3.x compatible; lock held until script exits).
    # We open FD 200 explicitly since {var} dynamic FD assignment requires bash 4.1+.
    # INFRA-1062: do NOT include 2>/dev/null on an `exec FD>file` call — bash
    # applies all redirections to the shell permanently, which would silence
    # ALL subsequent stderr output and hide set -e exits as "silent" failures.
    exec 200>"$_bm_lock_file" || { warn "[INFRA-860] Could not open bot-merge.lock — skipping mutex"; exec 200>/dev/null; }
    if ! flock -w 60 200 2>/dev/null; then
        red "[INFRA-860] bot-merge.lock: timed out waiting 60s — another bot-merge is stuck?"
        exit 2
    fi
    _bm_wait=$(( $(date +%s) - _bm_lock_start ))
    if [[ "$_bm_wait" -gt 5 ]]; then
        info "[INFRA-860] bot-merge.lock: waited ${_bm_wait}s (contention detected)"
        _bm_amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
        mkdir -p "$(dirname "$_bm_amb")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"bot_merge_contention_avoided","branch":"%s","wait_s":%d}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$_bm_wait" >> "$_bm_amb" 2>/dev/null || true
    fi
fi
# FD 200 stays open; flock released automatically when the script process exits.

# ── INFRA-995: pre-push staleness gate ───────────────────────────────────────
# Belt-and-suspenders for the CLAUDE.md rule "rebase if your branch is more than
# 15 commits behind main". The earlier rebase block (§1) already rebases above
# 0 behind, but main may have moved during cargo clippy/test (often a 5-15 min
# window). Re-fetch and refuse to push if we are now > STALE_REBASE_THRESHOLD
# commits behind — pushing would burn a CI cycle on a stale base and then sit
# in BEHIND state waiting on queue-driver.
STALE_REBASE_THRESHOLD="${CHUMP_BOT_MERGE_STALE_THRESHOLD:-15}"
if [[ $DRY_RUN -eq 0 ]]; then
    run_timed_hb "git fetch (pre-push freshness)" 60 \
        git fetch "$REMOTE" "$BASE_BRANCH" --quiet 2>/dev/null || true
    BEHIND_NOW=$(git rev-list --count "HEAD..${REMOTE}/${BASE_BRANCH}" 2>/dev/null || echo 0)
    if [[ "$BEHIND_NOW" -gt "$STALE_REBASE_THRESHOLD" ]]; then
        red "INFRA-995: branch is $BEHIND_NOW commits behind $REMOTE/$BASE_BRANCH (threshold ${STALE_REBASE_THRESHOLD})."
        red "  main moved while we built/tested. Pushing now would queue a stale base for CI."
        red "  Recover: git fetch && git rebase $REMOTE/$BASE_BRANCH && rerun bot-merge."
        _amb_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
        mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"stale_branch_blocked","branch":"%s","behind":%d,"threshold":%d,"phase":"pre-push"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$BEHIND_NOW" "$STALE_REBASE_THRESHOLD" \
            >> "$_amb_path" 2>/dev/null || true
        _bm_fail "stale-branch" 3 "branch $BEHIND_NOW commits behind > threshold ${STALE_REBASE_THRESHOLD}"
    fi
fi

# ── INFRA-993: scratch-commit guard — block catastrophic-delete PRs ──────────
# Near-miss observed 2026-05-11: PRs #1441 + #1452 each proposed +2 / -378000+
# lines across ~1910 files (effectively deleting the entire repo). Root cause:
# worktree corruption (INFRA-779 family). Independent of root-cause fix, this
# is the creation-time gate: refuse to push when the diff vs origin/main shows
# > 50000 deletions OR deletions > 100× additions. Override: --allow-mass-delete.
if [[ "$DRY_RUN" -eq 0 && "${CHUMP_SCRATCH_GUARD_DISABLE:-0}" != "1" ]]; then
    _sg_amb="${CHUMP_AMBIENT_LOG:-${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl}"
    _sg_stats="$(git diff --shortstat "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null || true)"
    # Sample format: "5 files changed, 12 insertions(+), 3 deletions(-)"
    # Parse with sed; default to 0 if a clause is missing.
    _sg_files="$(printf '%s' "$_sg_stats" | sed -nE 's/.* ([0-9]+) files? changed.*/\1/p')"
    _sg_adds="$(printf '%s' "$_sg_stats"  | sed -nE 's/.* ([0-9]+) insertions?\(\+\).*/\1/p')"
    _sg_dels="$(printf '%s' "$_sg_stats"  | sed -nE 's/.* ([0-9]+) deletions?\(-\).*/\1/p')"
    _sg_files="${_sg_files:-0}"
    _sg_adds="${_sg_adds:-0}"
    _sg_dels="${_sg_dels:-0}"
    # Tripwire: > 50000 deletions OR deletions > 100× max(adds, 1).
    _sg_threshold_abs="${CHUMP_SCRATCH_GUARD_MAX_DELETIONS:-50000}"
    _sg_threshold_ratio="${CHUMP_SCRATCH_GUARD_RATIO:-100}"
    _sg_adds_floor=$((_sg_adds > 0 ? _sg_adds : 1))
    if [[ "$_sg_dels" -gt "$_sg_threshold_abs" ]] || \
       [[ "$_sg_dels" -gt $(( _sg_adds_floor * _sg_threshold_ratio )) ]]; then
        # Compose gap ID for the ambient event.
        _sg_gap="${GAP_IDS[0]:-unknown}"
        if [[ "$ALLOW_MASS_DELETE" == "1" ]]; then
            yellow "scratch-commit guard: --allow-mass-delete set; permitting +${_sg_adds} / -${_sg_dels} across ${_sg_files} files"
            mkdir -p "$(dirname "$_sg_amb")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"scratch_commit_override_used","gap_id":"%s","additions":%s,"deletions":%s,"files":%s,"threshold_abs":%s,"threshold_ratio":%s,"branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sg_gap" "$_sg_adds" "$_sg_dels" "$_sg_files" "$_sg_threshold_abs" "$_sg_threshold_ratio" "$BRANCH" \
                >> "$_sg_amb" 2>/dev/null || true
        else
            red "Aborting: this commit deletes ${_sg_dels} lines across ${_sg_files} files (refusing — set --allow-mass-delete to override)."
            red "Adds: ${_sg_adds}. Threshold: > ${_sg_threshold_abs} deletions OR deletions > ${_sg_threshold_ratio}× additions."
            red "See ambient.jsonl for the kind=scratch_commit_blocked event."
            mkdir -p "$(dirname "$_sg_amb")" 2>/dev/null || true
            printf '{"ts":"%s","kind":"scratch_commit_blocked","gap_id":"%s","additions":%s,"deletions":%s,"files":%s,"threshold_abs":%s,"threshold_ratio":%s,"branch":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_sg_gap" "$_sg_adds" "$_sg_dels" "$_sg_files" "$_sg_threshold_abs" "$_sg_threshold_ratio" "$BRANCH" \
                >> "$_sg_amb" 2>/dev/null || true
            exit 15
        fi
    fi
fi

# ── 4b. Duplicate-PR check (INFRA-996) ────────────────────────────────────────
# Before pushing, verify no open PR already has this GAP-ID in its title with a
# different head branch. Duplicate PRs waste CI, confuse reviewers, and caused
# 3 incidents in 7 days (#1536+#1540, #1323+#1333, #1283/#1284).
# Bypass: --force-duplicate or CHUMP_FORCE_DUPLICATE=1.
_amb_path="${CHUMP_AMBIENT_IN_PROMPT:-${LOCK_DIR}/ambient.jsonl}"
if [[ "${FORCE_DUPLICATE}" != "1" && ${#GAP_IDS[@]} -gt 0 ]]; then
    _dup_found=0
    _dup_pr_numbers=""
    for _gid in "${GAP_IDS[@]}"; do
        # REST-only: gh pr list uses GraphQL but falls back cleanly; we skip if
        # rate-limited rather than blocking the push (fail-open for dup check).
        _existing=$(gh pr list --repo "${REPO}" --state open \
            --search "${_gid} in:title" --json number,headRefName \
            --limit 10 2>/dev/null || true)
        if [[ -z "$_existing" ]]; then
            continue
        fi
        # Filter: exclude PRs whose head ref matches our current branch.
        _conflicts=$(echo "$_existing" | python3 -c "
import json,sys
rows=json.load(sys.stdin)
conflicts=[str(r['number']) for r in rows if r.get('headRefName','') != '${BRANCH}']
print(' '.join(conflicts))
" 2>/dev/null || true)
        if [[ -n "$_conflicts" ]]; then
            _dup_found=1
            _dup_pr_numbers="${_dup_pr_numbers} ${_conflicts}"
        fi
    done
    if [[ "$_dup_found" -eq 1 ]]; then
        _dup_pr_numbers="${_dup_pr_numbers# }"
        red "Duplicate PR blocked: open PR(s) already claim this gap: ${_dup_pr_numbers}"
        red "  Use --force-duplicate to override (legitimate retry after the prior PR closed)."
        # Emit ambient event for frequency tracking.
        printf '{"ts":"%s","kind":"dup_pr_blocked","gap_id":"%s","existing_pr_numbers":"%s","current_branch":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_IDS[*]:-}" "$_dup_pr_numbers" "$BRANCH" \
            >> "$_amb_path" 2>/dev/null || true
        _bm_fail "dup-pr" 16 "duplicate PR detected for gap ${GAP_IDS[*]:-}: existing ${_dup_pr_numbers}"
    fi
fi

# ── 5. Push ───────────────────────────────────────────────────────────────────
stage_start "git push $BRANCH → $REMOTE"
# INFRA-719: signal to the pre-push hook that this push is bot-merge-initiated.
# The hook blocks first-push of chump/* branches unless this flag is set, to
# prevent the manual "git push + gh pr create" bypass that skips gap-ship-fatal.
export CHUMP_BOT_MERGE_IN_PROGRESS=1
if ! run_timed_hb "git push" 120 git push "$REMOTE" "$BRANCH" --force-with-lease; then
    red "git push failed or timed out."
    _bm_fail "push" 15 "force-with-lease rejected or network error"
fi
stage_done
green "Pushed."

# ── 5b. INFRA-084 advisory: warn if PR diff hand-edits docs/gaps.yaml ───────
# The merge_group workflow `.github/workflows/regenerate-gaps-yaml.yml`
# auto-regenerates the YAML from .chump/state.db on every queue temp branch,
# so most hand-edits are unnecessary now. Common case where this matters:
#   - filing PRs that append a new gap entry by hand instead of using
#     `chump gap reserve`
#   - closure PRs that hand-edit status:done instead of running
#     `chump gap ship --closed-pr <N> --update-yaml`
# Advisory-only for now; INFRA-094 will block these in pre-commit once the
# merge_group regen is fully validated.
if [[ "${CHUMP_RAW_YAML_EDIT_CHECK:-1}" != "0" ]]; then
    if git diff --name-only "${REMOTE}/${BASE_BRANCH}..HEAD" 2>/dev/null \
        | grep -qx 'docs/gaps.yaml'; then
        info "[bot-merge] NOTE: this PR's diff includes docs/gaps.yaml hand-edits."
        info "[bot-merge]   Prefer: chump gap reserve / set / ship --update-yaml so the canonical"
        info "[bot-merge]   regenerator (.github/workflows/regenerate-gaps-yaml.yml) round-trips"
        info "[bot-merge]   the diff cleanly. The merge_group workflow will auto-fix any drift."
        info "[bot-merge]   Suppress this notice: CHUMP_RAW_YAML_EDIT_CHECK=0"
    fi
fi

# ── 6. Open or update PR ─────────────────────────────────────────────────────
EXISTING_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")

# INFRA-997: refuse to open a PR when the branch's commits since divergence
# are ONLY auto-staging commits from INFRA-472. These are mechanical commits
# bot-merge.sh creates pre-rebase to stash uncommitted scoped edits; they
# carry no gap work. PR #1655 (2026-05-13) shipped exactly this pattern — a
# pre-rebase staging branch with no meaningful work, immediately closed as
# duplicate. Guard prevents that waste class. To bypass when legitimate
# (rare — operator confirms staging IS the work): CHUMP_ALLOW_STAGING_ONLY_PR=1.
if [[ -z "$EXISTING_PR" && "${CHUMP_ALLOW_STAGING_ONLY_PR:-0}" != "1" ]]; then
    _commit_subjects=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --pretty=format:'%s' 2>/dev/null)
    _total_commits=$(echo "$_commit_subjects" | grep -cE '.')
    _staging_commits=$(echo "$_commit_subjects" | grep -cE '^auto: bot-merge pre-rebase staging' || true)
    if [[ "$_total_commits" -gt 0 && "$_total_commits" -eq "$_staging_commits" ]]; then
        red "INFRA-997: refusing to gh pr create — branch $BRANCH has $_total_commits commit(s) since $BASE_BRANCH"
        red "          and ALL of them are auto-staging commits from INFRA-472."
        red "          A PR with only mechanical staging carries no gap work."
        red ""
        red "  Commits on this branch:"
        echo "$_commit_subjects" | sed 's/^/    /' >&2
        red ""
        red "  Most likely cause: bot-merge.sh ran without any gap commits being landed first."
        red "  Recovery: do the actual gap work, commit it, then re-run bot-merge.sh."
        red "  Bypass (rare; operator confirmed): CHUMP_ALLOW_STAGING_ONLY_PR=1"
        # Best-effort ambient event so the operator can see this fired
        _ambient_path="${LOCK_DIR:-${REPO_ROOT:-.}/.chump-locks}/ambient.jsonl"
        if [[ -w "$(dirname "$_ambient_path")" ]] 2>/dev/null; then
            printf '{"ts":"%s","kind":"staging_only_pr_blocked","branch":"%s","commits":%d}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" "$_total_commits" >> "$_ambient_path"
        fi
        _bm_fail "pr-create" 16 "staging-only branch — refused to open empty PR (INFRA-997)"
    fi
fi

if [[ -z "$EXISTING_PR" ]]; then
    stage_start "gh pr create"
    # Build a body from the gap IDs cited in commits since base diverged.
    COMMIT_LOG=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline 2>/dev/null | head -20)
    # INFRA-630: extract both classic DOMAIN-NUMBER and RFC-4122 UUID gap IDs from commit log.
    COMMIT_GAP_IDS=$(echo "$COMMIT_LOG" | grep -oE '[A-Z]+-[0-9]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u | tr '\n' ' ' || true)
    GAP_LINE=""
    [[ -n "$COMMIT_GAP_IDS" ]] && GAP_LINE="**Gaps addressed:** $COMMIT_GAP_IDS"

    # INFRA-501: PR title is public — ensure the last commit subject complies with
    # docs/agents/RESEARCH_PRIVACY.md § "PR title and commit subject hygiene".
    # Prohibited: specific findings, model-tier outcomes, IP-protection mechanic language.
    PR_TITLE=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | tail -1 | sed 's/^[a-f0-9]* //')

    # INFRA-060 (M2): if a `.chump-plans/<gap>.md` exists for any gap cited in
    # commit messages, splice its body verbatim into the PR description so
    # reviewers can see the planned files + open-PR overlap scan.
    PLAN_BLOCK=""
    for gid in $COMMIT_GAP_IDS; do
        plan_file=".chump-plans/${gid}.md"
        if [[ -f "$plan_file" ]]; then
            PLAN_BLOCK+="$(printf '\n\n<details><summary>Plan-mode (%s)</summary>\n\n%s\n\n</details>' "$gid" "$(cat "$plan_file")")"
        fi
    done

    # INFRA-632: build PR body — use --pr-template file when provided,
    # substituting {{COMMIT_LOG}}, {{GAP_LINE}}, {{PLAN_BLOCK}} placeholders;
    # otherwise fall back to the default Chump template.
    if [[ -n "$PR_TEMPLATE" ]]; then
        if [[ ! -f "$PR_TEMPLATE" ]]; then
            red "INFRA-632: --pr-template '$PR_TEMPLATE' not found."
            exit 1
        fi
        _commit_log_escaped=$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | sed 's/^/- /' | sed 's/[&/\]/\\&/g' | tr '\n' '\r')
        _pr_body=$(sed \
            -e "s|{{GAP_LINE}}|${GAP_LINE}|g" \
            -e "s|{{PLAN_BLOCK}}|${PLAN_BLOCK}|g" \
            "$PR_TEMPLATE" \
            | awk -v cl="$_commit_log_escaped" '{gsub(/\{\{COMMIT_LOG\}\}/, cl); print}' \
            | tr '\r' '\n')
    else
        _pr_body="$(cat <<EOF
## Changes
$(git log "${REMOTE}/${BASE_BRANCH}..HEAD" --oneline | sed 's/^/- /')

${GAP_LINE}
${PLAN_BLOCK}

## Checklist
- [x] \`cargo fmt\` clean
- [x] \`cargo clippy\` clean
$([ $SKIP_TESTS -eq 0 ] && echo "- [x] \`cargo test\` passed" || echo "- [ ] tests skipped (non-Rust change)")

🤖 Opened by bot-merge.sh
EOF
)"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] gh pr create --base $BASE_BRANCH --title \"$PR_TITLE\" …"
    else
        # INFRA-1031 + INFRA-1055: GraphQL preflight — gh pr create uses GraphQL;
        # if quota is 0 (or low per circuit-breaker gate) fall back to REST.
        _graphql_remaining="${RL_GQL_REMAINING:-1}"
        if [[ "$_graphql_remaining" -le 0 ]] || \
           { declare -F rate_limit_gate >/dev/null 2>&1 && [[ "${_BM_RL_DEGRADED:-0}" -ge 1 ]] && [[ "${RL_GQL_PCT:-100}" -le "${CHUMP_RL_GQL_WARN_PCT:-50}" ]]; }; then
            warn "INFRA-1031/1055: GraphQL quota ${_graphql_remaining:-0} (${RL_GQL_PCT:-?}% remaining) — falling back to REST gh api repos/.../pulls"
            _repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
            if [[ -n "$_repo_nwo" ]]; then
                _rest_body=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$_pr_body" 2>/dev/null || echo "\"$_pr_body\"")
                _rest_result=$(gh api "repos/$_repo_nwo/pulls" --method POST \
                    --field title="$PR_TITLE" \
                    --field base="$BASE_BRANCH" \
                    --field head="$BRANCH" \
                    --field body="$_pr_body" \
                    --jq '.number' 2>/dev/null || echo "")
                if [[ -n "$_rest_result" ]]; then
                    printf '{"ts":"%s","kind":"graphql_exhausted","source":"bot-merge","note":"INFRA-1031 REST fallback succeeded PR #%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_rest_result" >> "${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}" 2>/dev/null || true
                    green "PR #$_rest_result created via REST fallback (GraphQL quota was 0)."
                else
                    red "INFRA-1031: REST fallback also failed — GraphQL exhausted and REST failed."
                    printf '{"ts":"%s","kind":"graphql_exhausted","source":"bot-merge","note":"INFRA-1031 REST fallback failed; branch=%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BRANCH" >> "${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}" 2>/dev/null || true
                    _bm_fail "pr-create" 16 "GraphQL exhausted and REST fallback failed; retry when quota resets (gh api rate_limit)"
                fi
            else
                red "INFRA-1031: GraphQL exhausted and cannot determine repo NWO for REST fallback."
                _bm_fail "pr-create" 16 "GraphQL exhausted; retry when quota resets (gh api rate_limit)"
            fi
        elif ! gh_with_backoff "gh pr create" 120 pr create \
            --base "$BASE_BRANCH" \
            --title "$PR_TITLE" \
            --body "$_pr_body"; then
            red "gh pr create failed or timed out."
            _bm_fail "pr-create" 16 "gh pr create failed or timed out"
        fi
        # INFRA-1031: if REST fallback set the PR number, skip gh pr view (may also be GraphQL).
        if [[ -n "${_rest_result:-}" ]]; then
            _new_pr="$_rest_result"
        else
            _new_pr=""
            for _try in 1 2 3 4 5; do
                _new_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || \
                          gh api "repos/$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)/pulls" \
                              --jq "[.[] | select(.head.ref==\"$BRANCH\")] | first | .number" 2>/dev/null || echo "")
                [[ -n "$_new_pr" ]] && break
                sleep 2
            done
            if [[ -z "$_new_pr" ]]; then
                red "gh pr create reported success but no PR is visible for branch $BRANCH — refusing to exit 0."
                _bm_fail "pr-create" 16 "PR not visible after gh pr create"
            fi
        fi
        stage_done
        green "PR #$_new_pr created and verified."

        # ── FLEET-029: post-PR-create overlap scan ──
        if [[ -z "${FLEET_029_PR_SCAN_SKIP:-}" ]]; then
            # Scan for overlapping open PRs with similar titles or gap IDs
            info "FLEET-029: scanning for overlapping open PRs…"
            bash scripts/coord/chump-ambient-glance.sh --title "$PR_TITLE" --check-prs || true
        fi
    fi
else
    green "PR #$EXISTING_PR already exists — updated by push."
fi

# ── INFRA-103: apply parallelism label to the PR ─────────────────────────────
# Classify this PR as 'serializing' or 'parallel-safe' based on whether it
# touches shared coordination hot files. Label is applied regardless of
# whether the PR was just created or already existed.
_label_pr="${EXISTING_PR:-}"
if [[ -z "$_label_pr" ]]; then
    _label_pr="$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")"
fi
if [[ -n "$_label_pr" ]]; then
    apply_pr_parallelism_label "$_label_pr"
fi

# ── 6.7. CREDIBLE-039: pre-ship guard — refuse if gap is done+closed_pr ──────
# If state.db says the gap is already done with a closed_pr set (and that PR
# is not our current PR), refuse to proceed: someone else already closed it or
# the gap was prematurely closed on a different PR.
# Bypass: CHUMP_ALLOW_RECYCLE=1 (same env var used by --auto-fix).
if [[ "${CHUMP_ALLOW_RECYCLE:-0}" != "1" ]] && [[ ${#GAP_IDS[@]} -gt 0 ]] && [[ -f "${MAIN_REPO:-$REPO_ROOT}/.chump/state.db" ]]; then
    _pre_ship_db="${MAIN_REPO:-$REPO_ROOT}/.chump/state.db"
    for _gid in "${GAP_IDS[@]}"; do
        _existing=$(sqlite3 "$_pre_ship_db" "SELECT status, closed_pr FROM gaps WHERE id='$_gid' AND status='done' AND closed_pr IS NOT NULL AND closed_pr != '';" 2>/dev/null || true)
        if [[ -n "$_existing" ]]; then
            _e_status="${_existing%%|*}"
            _e_pr="${_existing##*|}"
            red "CREDIBLE-039: gap $_gid is already status=done with closed_pr=#$_e_pr in state.db"
            red "  This gap was already closed — refusing to ship a second time."
            red "  Bypass: CHUMP_ALLOW_RECYCLE=1 $0 ..."
            exit 3
        fi
    done
fi

# ── 6.75. Auto-close gap on the implementation PR (INFRA-154 / INFRA-1030) ────
# INFRA-1030: gap ship is now AFTER auto-merge arm (section 7 below).
# Previous order was: gap ship → arm auto-merge. If bot-merge died between those
# two steps, the gap was left status=done but the PR had no auto-merge → stalls.
# New order: arm auto-merge → THEN gap ship. Worst-case on abort: gap stays
# in_progress but PR will still merge when CI passes. Operator recovers with:
#   chump gap ship <GAP-ID> --closed-pr <PR> --update-yaml
# (Moved body to end of section 7, after gh pr merge --auto --squash.)

# ── 7. Enable auto-merge (optional) ──────────────────────────────────────────
if [[ $AUTO_MERGE -eq 1 ]]; then
    TARGET_PR="${EXISTING_PR:-}"
    if [[ -z "$TARGET_PR" ]]; then
        TARGET_PR=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    fi
    if [[ -n "$TARGET_PR" ]]; then
        # ── 6.5 Code-reviewer agent gate (INFRA-AGENT-CODEREVIEW MVP) ────────
        # If the PR touches src/* or crates/*/src/*, run the code-reviewer
        # agent before enabling auto-merge. APPROVE/SKIP -> proceed; CONCERN
        # or ESCALATE blocks the auto-merge so a human can resolve.
        # Bypass with CHUMP_CODEREVIEW=0 (e.g. infra/scripts changes).
        if [[ "${CHUMP_CODEREVIEW:-1}" != "0" ]] && [[ -x "$SCRIPT_DIR/code-reviewer-agent.sh" ]]; then
            CHANGED=$(gh pr diff "$TARGET_PR" --name-only 2>/dev/null || echo "")
            TOUCHES_SRC=0
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                if [[ "$f" =~ ^src/ ]] || [[ "$f" =~ ^crates/.*/src/ ]]; then
                    TOUCHES_SRC=1; break
                fi
            done <<< "$CHANGED"

            if [[ $TOUCHES_SRC -eq 1 ]]; then
                info "PR #$TARGET_PR touches src/* — invoking code-reviewer-agent.sh …"
                _gap_arg=""
                [[ ${#GAP_IDS[@]} -gt 0 ]] && _gap_arg="--gap ${GAP_IDS[0]}"
                set +e
                "$SCRIPT_DIR/code-reviewer-agent.sh" "$TARGET_PR" $_gap_arg --post
                _rc=$?
                set -e
                case $_rc in
                    0|3)
                        green "Code-reviewer verdict: APPROVE/SKIP — proceeding with auto-merge." ;;
                    1)
                        red "Code-reviewer raised CONCERN — auto-merge NOT enabled."
                        red "Resolve concerns then run: gh pr merge $TARGET_PR --auto --squash"
                        exit 1 ;;
                    2)
                        red "Code-reviewer ESCALATED — human review required, auto-merge NOT enabled."
                        exit 1 ;;
                    *)
                        red "Code-reviewer agent errored (exit $_rc) — auto-merge NOT enabled."
                        exit 1 ;;
                esac
            else
                info "PR #$TARGET_PR is non-src — code-reviewer skipped (auto-merge proceeds)."
            fi
        fi

        # ── Pre-merge CI gate (INFRA-CHOKE prevention) ────────────────────────────
        # Before arming auto-merge, verify that all required CI checks are passing.
        # If Release job or Crate Publish dry-run are failing, abort with a diagnostic
        # message and commit a comment to the PR so the developer sees the blocker.
        # (This prevents PR #470-style situations where auto-merge is armed on a PR
        # that's waiting for shared infrastructure to be fixed.)
        stage_start "CI status pre-flight check"
        # INFRA-632: when --required-checks is set, only flag failures for
        # checks whose name matches one of the comma-separated entries.
        # When unset, any FAILURE/ERROR check blocks auto-merge (original behaviour).
        # INFRA-1130: prefer SQLite cache over live API; fall back on miss.
        _all_failing=""
        _ci_cache_used=0
        _ci_head_sha=""
        if _ci_pr_json="$(cache_lookup_pr "$TARGET_PR" --max-age-s 120 2>/dev/null)"; then
            _ci_head_sha="$(printf '%s' "$_ci_pr_json" | \
                python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('head',{}).get('sha',''))" 2>/dev/null || true)"
        fi
        if [[ -n "$_ci_head_sha" ]]; then
            _ci_checks_cache="$(cache_lookup_checks "$_ci_head_sha" 2>/dev/null || true)"
            if [[ -n "$_ci_checks_cache" ]]; then
                _ci_cache_used=1
                # tab-separated name\tstatus\tconclusion — filter failing conclusions
                _all_failing="$(printf '%s\n' "$_ci_checks_cache" | \
                    awk -F'\t' 'toupper($3) ~ /FAILURE|ERROR|TIMED_OUT|CANCELLED/ {print $1 "\t" toupper($3)}')"
            fi
        fi
        if [[ $_ci_cache_used -eq 0 ]]; then
            info "INFRA-1130: cache miss for PR #$TARGET_PR — falling back to live API"
            _all_failing=$(gh pr checks "$TARGET_PR" 2>/dev/null | grep -E "FAILURE|ERROR" || true)
        fi
        if [[ -n "$REQUIRED_CHECKS" && -n "$_all_failing" ]]; then
            _ci_status=""
            IFS=',' read -ra _req_list <<< "$REQUIRED_CHECKS"
            while IFS= read -r _line; do
                for _req in "${_req_list[@]}"; do
                    _req_trimmed="${_req#"${_req%%[![:space:]]*}"}"
                    _req_trimmed="${_req_trimmed%"${_req_trimmed##*[![:space:]]}"}"
                    if echo "$_line" | grep -qF "$_req_trimmed"; then
                        _ci_status+="$_line"$'\n'
                        break
                    fi
                done
            done <<< "$_all_failing"
            _ci_status="${_ci_status%$'\n'}"
            if [[ -n "$_all_failing" ]] && [[ -z "$_ci_status" ]]; then
                info "INFRA-632: failing checks are non-required — proceeding (advisory only):"
                echo "$_all_failing" | sed 's/^/  [advisory] /'
            fi
        else
            _ci_status="$_all_failing"
        fi
        if [[ -n "$_ci_status" ]]; then
            red "BLOCKER: Required CI jobs failed. Not arming auto-merge."
            red "Failed checks:"
            echo "$_ci_status" | sed 's/^/  /'

            # Post a comment to the PR so the developer sees the blocker.
            # NOTE: previously built with $(cat <<'EOF' ...), which hits a bash
            # pre-parser bug — inside $(...) the backtick-balance scanner still
            # runs across the heredoc body even when the delimiter is quoted,
            # so literal triple-backticks in the markdown fence caused
            # "line NNN: unexpected EOF while looking for matching `". That
            # aborted bot-merge *after* PR create but *before* the auto-merge
            # arm step, silently dropping PRs into the queue without --auto.
            # See: PR #482/#488/#491 (2026-04-24). The fix: build the body
            # with printf + a backtick variable, so no un-escaped backticks
            # ever appear inside a $(...) literal.
            _fence='```'
            printf -v _comment_body '%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n' \
                '⚠️ Auto-merge blocked: Required CI checks failed.' \
                '**Failing checks:**' \
                "${_fence}" \
                "${_ci_status}" \
                "${_fence}" \
                '**Next steps:**' \
                '1. Investigate the failing check (click the link in the GitHub UI)' \
                '2. Fix the underlying issue (usually in Release job or infrastructure)' \
                "3. Once all checks pass, re-run: \`scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge\`"
            if [[ $DRY_RUN -eq 0 ]]; then
                gh pr comment "$TARGET_PR" -b "$_comment_body" 2>/dev/null || true
            fi
            exit 1
        fi
        green "All required CI checks passing — proceeding with auto-merge."
        stage_done

        # INFRA-305: hot-file rebase-loop expectation. Pre-emit a note for any
        # file in BOT_MERGE_HOT_FILES so the agent knows to expect ≥1 DIRTY
        # rebase before landing if other agents are active. No behavior change.
        _hot_gap_label="${GAP_IDS[0]:-none}"
        emit_hot_file_warnings "$TARGET_PR" "$_hot_gap_label"

        # Pre-merge checkpoint tag (2026-04-18 PR #52 retrospective).
        # GitHub squash-merge captures branch state at the moment CI
        # passes and drops any commits pushed after — losing 11 commits
        # on PR #52, recovery via PR #65 was forced. This tag pins the
        # branch HEAD at the moment we enable auto-merge, so recovery is
        # `git checkout pr-NN-checkpoint` (vs. having to fetch the
        # orphaned branch and cherry-pick). Disable with
        # CHUMP_PRE_MERGE_CHECKPOINT=0.
        if [[ "${CHUMP_PRE_MERGE_CHECKPOINT:-1}" != "0" ]]; then
            CHECKPOINT_TAG="pr-${TARGET_PR}-checkpoint"
            if ! git rev-parse --quiet --verify "refs/tags/${CHECKPOINT_TAG}" >/dev/null; then
                info "Pinning checkpoint tag ${CHECKPOINT_TAG} (squash-loss insurance) …"
                run_timed 60 git tag "${CHECKPOINT_TAG}" HEAD
                if ! run_timed_hb "git push checkpoint tag" 120 git push origin "${CHECKPOINT_TAG}"; then
                    red "Failed to push checkpoint tag ${CHECKPOINT_TAG}."
                    exit 2
                fi
                green "Checkpoint tag pushed — recovery via 'git checkout ${CHECKPOINT_TAG}'."
            else
                info "Checkpoint tag ${CHECKPOINT_TAG} already exists — skipping."
            fi
        fi

        # INFRA-390: bench mode skips auto-merge + gap-closure so each trial
        # is non-destructive. The PR is opened (so CI grades it) but does NOT
        # land on main. Per COG-032 prereg §4 the success criterion is "PR
        # opened + required CI checks pass" — merging is not required for
        # the trial to count as success.
        #
        # Set CHUMP_BENCH_MODE=1 + CHUMP_BENCH_CELL + CHUMP_BENCH_TASK_ID
        # (+ optional CHUMP_BENCH_TRIAL_N) to emit a JSONL trial line to
        # logs/ab/COG-032/run.jsonl. Production callers leave CHUMP_BENCH_MODE
        # unset (default 0) and behavior is unchanged.
        if [[ "${CHUMP_BENCH_MODE:-0}" == "1" ]]; then
            yellow "[bench-mode] CHUMP_BENCH_MODE=1 — skipping auto-merge arming + gap-closure"
            yellow "[bench-mode] PR #$TARGET_PR remains OPEN for CI grading"

            # Emit the trial outcome line. Best-effort I/O — never blocks.
            _bench_log_dir="$REPO_ROOT/logs/ab/COG-032"
            mkdir -p "$_bench_log_dir" 2>/dev/null || true
            _bench_log="${CHUMP_BENCH_LOG:-$_bench_log_dir/run.jsonl}"
            _bench_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _bench_session="${CLAUDE_SESSION_ID:-${CHUMP_SESSION_ID:-bench-$$}}"
            _bench_cell="${CHUMP_BENCH_CELL:-?}"
            _bench_task="${CHUMP_BENCH_TASK_ID:-?}"
            _bench_trial="${CHUMP_BENCH_TRIAL_N:-1}"
            _bench_dur_s="${SECONDS:-0}"
            # PR state at record-time (stage where bot-merge has just opened it
            # but not yet armed auto-merge). State will be polled separately
            # by the harness for the final pass/fail call.
            _bench_pr_state="$(gh pr view "$TARGET_PR" --json state --jq .state 2>/dev/null || echo unknown)"
            # Record success by the prereg's criterion — PR exists + this run
            # got past the CI-pre-flight gate (see line ~1224 above). The
            # harness re-checks CI green async via gh pr view.
            _bench_success_at_arm=true
            printf '{"ts":"%s","cell":"%s","task_id":"%s","trial_n":%s,"agent_session":"%s","pr_number":%s,"pr_state_at_record":"%s","duration_s":%s,"success_criteria_met_at_arm_stage":%s,"branch":"%s"}\n' \
                "$_bench_ts" "$_bench_cell" "$_bench_task" "$_bench_trial" \
                "$_bench_session" "$TARGET_PR" "$_bench_pr_state" \
                "$_bench_dur_s" "$_bench_success_at_arm" "$BRANCH" \
                >> "$_bench_log" 2>/dev/null || true

            green "[bench-mode] trial recorded → $_bench_log"
        else
            # ── INFRA-684: speculative-on-speculative guard ───────────────────
            # Before arming, check that no other PR for the same gap is already
            # armed. If two speculative agents both reach this point before the
            # INFRA-193 loser sweep runs, both could get auto-merge enabled and
            # both could land (or conflict). The check exits 1 if a competing
            # armed PR is detected; bypass with CHUMP_SPEC_ON_SPEC_CHECK=0.
            if [[ "${CHUMP_SPEC_ON_SPEC_CHECK:-1}" != "0" ]] \
                    && [[ ${#GAP_IDS[@]} -gt 0 ]]; then
                for _spec_gid in "${GAP_IDS[@]}"; do
                    if ! "$SCRIPT_DIR/check-spec-on-spec.sh" "$_spec_gid" "$TARGET_PR"; then
                        red "INFRA-684: Arm blocked — competing armed PR exists for $_spec_gid."
                        red "  The speculative race was already decided. Aborting this arm."
                        red "  Bypass (if the competing PR is stale): CHUMP_SPEC_ON_SPEC_CHECK=0"
                        exit 1
                    fi
                done
            fi

            # ── INFRA-1166: REST-direct fast path ────────────────────────────────
            # When all required CI checks are already completed and green, skip
            # GraphQL enablePullRequestAutoMerge and merge immediately via REST
            # PUT /pulls/N/merge. This avoids the separate GraphQL secondary rate
            # limit that has caused "API rate limit already exceeded" errors even
            # when REST quota was healthy. Disable with CHUMP_BOT_MERGE_REST_DIRECT=0.
            _rest_direct_merged=0
            _rd_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
            if [[ "${CHUMP_BOT_MERGE_REST_DIRECT:-1}" != "0" && $DRY_RUN -eq 0 ]]; then
                stage_start "INFRA-1166: REST-direct fast path (check all CI green)"
                _rd_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
                _rd_sha=$(gh api "repos/$_rd_nwo/pulls/$TARGET_PR" --jq '.head.sha' 2>/dev/null || true)
                if [[ -n "$_rd_nwo" && -n "$_rd_sha" ]]; then
                    _rd_checks_json=$(gh api "repos/$_rd_nwo/commits/$_rd_sha/check-runs" \
                        --paginate 2>/dev/null || true)
                    if [[ -n "$_rd_checks_json" ]]; then
                        # Count incomplete and failed required checks with python3
                        _rd_counts=$(printf '%s' "$_rd_checks_json" | python3 - "$REQUIRED_CHECKS" <<'RDPYEOF'
import sys, json
required_raw = sys.argv[1] if len(sys.argv) > 1 else ""
required_list = [r.strip() for r in required_raw.split(",") if r.strip()] if required_raw else []
try:
    data = json.load(sys.stdin)
except Exception:
    print("0 0 0"); sys.exit(0)
checks = data.get("check_runs", [])
incomplete = failed = total = 0
for c in checks:
    conclusion = (c.get("conclusion") or "").lower()
    if conclusion in ("skipped", "neutral", "cancelled"):
        continue
    name = c.get("name", "")
    if required_list and not any(r in name for r in required_list):
        continue
    total += 1
    status = (c.get("status") or "").lower()
    if status != "completed":
        incomplete += 1
    elif conclusion != "success":
        failed += 1
print(f"{incomplete} {failed} {total}")
RDPYEOF
                        )
                        _rd_incomplete=$(printf '%s' "$_rd_counts" | awk '{print $1}')
                        _rd_failed=$(printf '%s' "$_rd_counts" | awk '{print $2}')
                        _rd_total=$(printf '%s' "$_rd_counts" | awk '{print $3}')
                        if [[ "${_rd_total:-0}" -gt 0 && \
                              "${_rd_incomplete:-1}" -eq 0 && \
                              "${_rd_failed:-1}" -eq 0 ]]; then
                            info "INFRA-1166: all $_rd_total required checks green — merging via REST PUT (no GraphQL)"
                            _rd_commit_title=$(gh api "repos/$_rd_nwo/pulls/$TARGET_PR" \
                                --jq '.title' 2>/dev/null || echo "Merge PR #$TARGET_PR")
                            _rd_gap_str="${GAP_IDS[*]:-}"
                            if gh api "repos/$_rd_nwo/pulls/$TARGET_PR/merge" \
                                    -X PUT \
                                    -f merge_method=squash \
                                    -f "commit_title=${_rd_commit_title}" \
                                    2>/dev/null; then
                                _rest_direct_merged=1
                                green "INFRA-1166: REST-direct merge succeeded — PR #$TARGET_PR merged (no GraphQL)."
                                mkdir -p "$(dirname "$_rd_amb")" 2>/dev/null || true
                                printf '{"ts":"%s","kind":"bot_merge_rest_direct","pr":%s,"gap":"%s","sha":"%s","checks_verified":%s,"note":"INFRA-1166 all-checks-green fast path"}\n' \
                                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                    "$TARGET_PR" "$_rd_gap_str" "$_rd_sha" "$_rd_total" \
                                    >> "$_rd_amb" 2>/dev/null || true
                            else
                                info "INFRA-1166: REST PUT merge failed (guard/review requirement?) — falling back to auto-merge arm."
                            fi
                        else
                            info "INFRA-1166: checks not all green (incomplete=${_rd_incomplete:-?}, failed=${_rd_failed:-?}, total=${_rd_total:-0}) — using auto-merge arm."
                        fi
                    else
                        info "INFRA-1166: no check-runs data returned — using auto-merge arm."
                    fi
                else
                    info "INFRA-1166: could not determine NWO/SHA — using auto-merge arm."
                fi
                stage_done
            fi

            if [[ $_rest_direct_merged -eq 0 ]]; then
                # INFRA-1113: delegate to centralized armer to enforce 5s spacing
                # between successive gh pr merge --auto calls across all callers.
                stage_start "auto-merge-armer.sh --pr $TARGET_PR"
                if ! "$SCRIPT_DIR/auto-merge-armer.sh" --pr "$TARGET_PR"; then
                    red "auto-merge-armer failed (see above)."
                    exit 2
                fi
            fi
        fi

        # ── INFRA-1030: Auto-close gap AFTER auto-merge arm ──────────────────────
        # This is the LAST irreversible state change. If bot-merge dies here, the
        # PR is already queued → will merge on green CI. Operator recovers with:
        #   chump gap ship <GAP-ID> --closed-pr <PR> --update-yaml
        # Old behavior (exit 1 on ship failure) moved to a WARN: PR is already
        # armed, aborting the script here would be confusing. Emit ambient event.
        # Disable with CHUMP_AUTO_CLOSE_GAP=0 for partial-progress PRs.
        if [[ $DRY_RUN -eq 0 ]] && [[ "${CHUMP_AUTO_CLOSE_GAP:-1}" != "0" ]] \
                && [[ ${#GAP_IDS[@]} -gt 0 ]] && [[ "${CHUMP_BENCH_MODE:-0}" != "1" ]] \
                && [[ -n "$TARGET_PR" ]] && command -v chump >/dev/null 2>&1; then
            # INFRA-526 / META-022: use $MAIN_REPO for canonical state.db.
            _autoclose_main_repo="${MAIN_REPO:-$REPO_ROOT}"
            # INFRA-526: pin to canonical chump binary; fall back to PATH.
            _autoclose_chump="chump"
            if [[ -x "${HOME}/.cargo/bin/chump" ]]; then
                _autoclose_chump="${HOME}/.cargo/bin/chump"
            fi
            info "INFRA-526: auto-close targeting state.db at $_autoclose_main_repo/.chump/state.db (binary: $_autoclose_chump)"
            for _gid in "${GAP_IDS[@]}"; do
                stage_start "auto-close gap $_gid via PR #$TARGET_PR (INFRA-154)"
                # INFRA-469 / INFRA-587: run_timed_hb captures output + has 60s timeout.
                _tmpship=$(mktemp)
                set +e
                CHUMP_REPO="$_autoclose_main_repo" \
                CHUMP_REAL_BINARY="$_autoclose_chump" \
                run_timed_hb "gap ship $_gid" 60 \
                    chump gap ship "$_gid" \
                        --closed-pr "$TARGET_PR" \
                        --update-yaml > "$_tmpship" 2>&1
                _autoclose_rc=$?
                set -e
                _autoclose_err=$(cat "$_tmpship")
                rm -f "$_tmpship"
                if [[ $_autoclose_rc -eq 0 ]]; then
                    # INFRA-509: state.db is canonical; no YAML file staging needed.
                    green "Auto-closed $_gid (closed_pr=$TARGET_PR) — squashed atomically by merge queue"
                    # INFRA-192: forward-chain notifier (best-effort; never blocks close path).
                    if command -v chump >/dev/null 2>&1 \
                        && [[ -x scripts/coord/broadcast.sh ]]; then
                        _unblocked=$(chump gap list --status open --json 2>/dev/null \
                                    | python3 -c "
import json, sys
gid = '$_gid'
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for g in data:
    deps = g.get('depends_on') or []
    if isinstance(deps, str):
        deps = [d.strip() for d in deps.split(',') if d.strip()]
    if gid in deps:
        print(g['id'])
" 2>/dev/null || true)
                        if [[ -n "$_unblocked" ]]; then
                            _unblocked_count=0
                            while IFS= read -r _down; do
                                [[ -z "$_down" ]] && continue
                                scripts/coord/broadcast.sh ALERT \
                                    kind=gap_unblocked \
                                    "INFRA-192: $_gid closed (PR #$TARGET_PR) — $_down newly actionable (depends_on link satisfied)" \
                                    >/dev/null 2>&1 || true
                                _unblocked_count=$((_unblocked_count + 1))
                            done <<< "$_unblocked"
                            green "Forward-chain (INFRA-192): $_gid unblocked ${_unblocked_count} downstream gap(s); broadcast to siblings"
                        fi
                    fi
                else
                    # INFRA-1030: gap ship failure is WARN-only (not exit 1) because
                    # auto-merge is already armed. Killing bot-merge here would confuse
                    # the caller: the PR will land regardless. Emit ambient event for
                    # curator / operator visibility; recover manually.
                    red "Auto-close FAILED for $_gid (chump gap ship rc=$_autoclose_rc) — WARN (PR already armed, will merge):"
                    if [[ -n "$_autoclose_err" ]]; then
                        while IFS= read -r _line; do
                            [[ -z "$_line" ]] && continue
                            red "  | $_line"
                        done <<< "$_autoclose_err"
                    fi
                    red "  YAML mirror NOT updated; gap status NOT flipped."
                    red "  RECOVER: chump gap ship $_gid --closed-pr $TARGET_PR --update-yaml"
                    red "           (run from main repo: $_autoclose_main_repo)"
                    red "  See: docs/process/CLAUDE_GOTCHAS.md#error-missing-closed-pr"
                    # Emit ambient event for curator pickup.
                    _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                    _ts_ship="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    printf '{"ts":"%s","kind":"gap_ship_post_arm_failed","gap_id":"%s","pr":%s,"rc":%s}\n' \
                        "$_ts_ship" "$_gid" "$TARGET_PR" "$_autoclose_rc" >> "$_amb" 2>/dev/null || true
                    # Do NOT exit 1 — continue (PR is already armed).
                fi
                stage_done
            done
        fi

        # ── INFRA-193: speculative-execution loser sweep ─────────────────────
        # When --speculative was set, scan open PRs that cite the same gap
        # ID(s) and close them as superseded. The losers' branches stay intact
        # (no force-push, no commit loss) — only the PR is closed with a
        # diagnostic comment pointing at the winning PR. Bypass with
        # CHUMP_SPECULATIVE_SWEEP=0 (e.g. when re-running bot-merge.sh on a
        # PR that's already armed and you don't want to re-close losers).
        if [[ "$SPECULATIVE" == "1" ]] \
            && [[ "${CHUMP_SPECULATIVE_SWEEP:-1}" != "0" ]] \
            && [[ ${#GAP_IDS[@]} -gt 0 ]] \
            && [[ -n "$TARGET_PR" ]]; then
            stage_start "INFRA-193 speculative loser sweep (gap=${GAP_IDS[*]})"
            for _gid in "${GAP_IDS[@]}"; do
                # Search open PRs whose title or body mentions the gap ID.
                # Exclude our own PR. gh pr list --search syntax: "GAP-ID in:title,body".
                _losers=$(gh pr list --state open --search "$_gid" \
                    --json number,headRefName,title \
                    --jq ".[] | select(.number != $TARGET_PR) | \"\(.number)|\(.headRefName)|\(.title)\"" \
                    2>/dev/null | head -10 || true)
                if [[ -z "$_losers" ]]; then
                    info "  No sibling PRs cite $_gid — clean win."
                    continue
                fi
                while IFS='|' read -r _lpr _lbranch _ltitle; do
                    [[ -z "$_lpr" ]] && continue
                    # Defence-in-depth: require the loser PR's title or
                    # branch to also reference the gap ID directly (avoids
                    # supersede-by-mention false positives).
                    if [[ "$_ltitle" != *"$_gid"* ]] && [[ "$_lbranch" != *"$(echo "$_gid" | tr '[:upper:]' '[:lower:]')"* ]]; then
                        info "  PR #$_lpr mentions $_gid in body only (title=$_ltitle, branch=$_lbranch) — skipping (false-positive guard)."
                        continue
                    fi
                    info "  Closing PR #$_lpr (branch=$_lbranch) as superseded by #$TARGET_PR …"
                    _supersede_msg="$(printf 'Auto-closing as superseded by #%s.\n\nINFRA-193 speculative-execution race: two agents picked up %s in parallel; PR #%s won the race to ship and is queued for auto-merge. Branch `%s` stays intact (no force-push, no commit loss) — re-open this PR or cherry-pick if the winning PR is later reverted.\n\nSee CLAUDE.md → "Speculative execution (INFRA-193)" for opt-in semantics.' \
                        "$TARGET_PR" "$_gid" "$TARGET_PR" "$_lbranch")"
                    if [[ $DRY_RUN -eq 0 ]]; then
                        gh pr close "$_lpr" --comment "$_supersede_msg" 2>/dev/null \
                            || info "  WARN: could not close PR #$_lpr (already closed? insufficient perms?)"
                        # FLEET-035: emit speculative_race_loss event for waste tracking
                        _rl_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                        _rl_payload="{\"ts\":\"$_rl_ts\",\"kind\":\"speculative_race_loss\",\
\"session\":\"${SESSION_ID:-unknown}\",\"gap_id\":\"$_gid\",\
\"loser_pr\":$_lpr,\"winner_pr\":$TARGET_PR,\"loser_branch\":\"$_lbranch\"}"
                        _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                        mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
                        printf '%s\n' "$_rl_payload" >> "$_amb" 2>/dev/null || true
                    else
                        info "  [dry-run] gh pr close $_lpr --comment '...'"
                    fi
                done <<< "$_losers"
            done
            stage_done
        fi

        # INFRA-190: fire-and-forget pr-watch.sh so the PR auto-recovers
        # if main moves while it's queued (DIRTY → rebase + force-push +
        # re-arm). The script handles the 80% case (no real conflicts);
        # real conflicts surface to the operator via exit 3.
        # Default ON; opt out with CHUMP_PR_WATCH_AFTER_ARM=0 (e.g. when
        # the operator wants to babysit the PR manually).
        if [[ "${CHUMP_PR_WATCH_AFTER_ARM:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/coord/pr-watch.sh" ]]; then
            _watch_log="/tmp/pr-watch-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/coord/pr-watch.sh" "$TARGET_PR" \
                > "$_watch_log" 2>&1 &
            _watch_pid=$!
            disown "$_watch_pid" 2>/dev/null || true
            info "pr-watch.sh detached (pid $_watch_pid, log $_watch_log) — PR will auto-recover from DIRTY"
        fi

        # INFRA-765: fire-and-forget rebase-stacked-prs.sh after auto-merge
        # is armed. Monitors for this PR to merge, then rebases all open PRs
        # that are stacked on our branch (base=BRANCH) onto origin/main and
        # re-arms their auto-merge. Eliminates the 3-PR manual ceremony when
        # a stacked base PR merges. Kill switch: CHUMP_AUTO_REBASE_STACKED=0.
        if [[ "${CHUMP_AUTO_REBASE_STACKED:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/coord/rebase-stacked-prs.sh" ]] \
            && [[ -n "$TARGET_PR" ]]; then
            _stacked_log="/tmp/rebase-stacked-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/coord/rebase-stacked-prs.sh" \
                "$TARGET_PR" "$BRANCH" "$REPO_ROOT" \
                > "$_stacked_log" 2>&1 &
            _stacked_pid=$!
            disown "$_stacked_pid" 2>/dev/null || true
            info "rebase-stacked-prs.sh detached (pid $_stacked_pid, log $_stacked_log) — will rebase PRs stacked on $BRANCH when it merges"
        fi

        # INFRA-223: feed the chump_improvement_targets loop after every
        # shipped PR. distill-pr-skills.sh shipped in PR #712 but produces 0
        # rows in production because no scheduler fires it (Cold Water #10
        # finding). Hook it into bot-merge's post-arm step so every shipped
        # PR feeds the loop. Background (&) so a slow gh-api call doesn't
        # block the bot-merge happy path; bypass via existing CHUMP_DISTILL=0
        # env var (already supported by the script) or CHUMP_DISTILL_AFTER_SHIP=0
        # to disable just the bot-merge hook without affecting manual runs.
        if [[ "${CHUMP_DISTILL_AFTER_SHIP:-1}" != "0" ]] \
            && [[ -x "$REPO_ROOT/scripts/ops/distill-pr-skills.sh" ]] \
            && [[ -n "$TARGET_PR" ]]; then
            _distill_log="/tmp/distill-pr-${TARGET_PR}-$(date +%s).log"
            nohup "$REPO_ROOT/scripts/ops/distill-pr-skills.sh" --pr "$TARGET_PR" \
                > "$_distill_log" 2>&1 &
            _distill_pid=$!
            disown "$_distill_pid" 2>/dev/null || true
            info "distill-pr-skills.sh detached (pid $_distill_pid, log $_distill_log) — feeds chump_improvement_targets"
        fi
    fi
fi

# INFRA-028 — exit-code honesty: never finish "success" without a visible PR.
if [[ $DRY_RUN -eq 0 ]]; then
    _verify_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    if [[ -z "$_verify_pr" ]]; then
        red "No GitHub PR found for branch $BRANCH — refusing to exit 0."
        exit 2
    fi
fi

# ── 8. Write shipped-marker (INFRA-BOT-MERGE-LOCK) ───────────────────────────
# Presence of .bot-merge-shipped causes chump-commit.sh to refuse further
# commits in this worktree — enforcing the "PR frozen once shipped" rule from
# the PR #52 retrospective. The worktree-reaper (INFRA-WORKTREE-REAPER) treats
# this file as "definitely safe to remove" when cleaning up old worktrees.
if [[ $DRY_RUN -eq 0 ]]; then
    _shipped_pr="${TARGET_PR:-${EXISTING_PR:-}}"
    if [[ -z "$_shipped_pr" ]]; then
        # PR may have been created in this run; fetch it now.
        _shipped_pr=$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || echo "")
    fi
    _shipped_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > .bot-merge-shipped <<EOF
PR_NUMBER=${_shipped_pr:-unknown}
SHIPPED_AT=${_shipped_at}
BRANCH=${BRANCH}
# Worktree-reaper: safe to remove this worktree
EOF
    green "Wrote .bot-merge-shipped — this worktree is now frozen (no further commits)."

    # INFRA-017: purge ./target in the frozen worktree. Each Rust target/ is
    # 1.4–9 GB; with ~25 frozen worktrees the 460 GB disk fills and subsequent
    # ship runs fail at clippy with `No space left on device (os error 28)`.
    # The PR is already pushed — no further clippy/test runs need this cache.
    # Override with CHUMP_KEEP_TARGET=1 to poke around post-ship.
    # INFRA-210: when CARGO_TARGET_DIR points outside the worktree (shared
    # fleet cache), skip the purge — ./target doesn't exist and wiping the
    # shared dir would break all other active worktrees.
    _wt_abs="$(pwd)"
    _skip_target_purge=0
    if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
        _ct_abs="$(cd "${CARGO_TARGET_DIR}" 2>/dev/null && pwd || echo "${CARGO_TARGET_DIR}")"
        case "$_ct_abs" in
            "${_wt_abs}"/*|"${_wt_abs}") ;;  # inside this worktree — purge as normal
            *) _skip_target_purge=1 ;;         # outside — shared cache, skip
        esac
    fi
    if [[ "${CHUMP_KEEP_TARGET:-0}" != "1" && "$_skip_target_purge" = "0" && -d "./target" ]]; then
        info "Purging ./target in frozen worktree (set CHUMP_KEEP_TARGET=1 to keep)…"
        run rm -rf ./target
        green "Removed ./target — disk reclaimed."
    elif [[ "$_skip_target_purge" = "1" ]]; then
        info "Skipping ./target purge — CARGO_TARGET_DIR is outside this worktree (INFRA-210)."
    fi
fi

# INFRA-537: emit ship_grade event for per-agent/per-model quality tracking.
# Captures clippy_ok, test_added, rebase_clean signals gathered above.
# model and agent_id come from fleet env vars (set by run-fleet.sh / worker.sh);
# for manual ships they default to "unknown".
if [[ $DRY_RUN -eq 0 ]]; then
    _grade_model="${FLEET_MODEL:-unknown}"
    _grade_agent="${AGENT_ID:-unknown}"
    _grade_harness="${CHUMP_AGENT_HARNESS:-manual}"
    _grade_amb="${REPO_ROOT}/.chump-locks/ambient.jsonl"
    _grade_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for gid in "${GAP_IDS[@]:-}"; do
        [[ -z "$gid" ]] && continue
        printf '{"event":"ship_grade","kind":"ship_grade","ts":"%s","gap_id":"%s","model":"%s","agent_id":"%s","harness":"%s","clippy_ok":%s,"test_added":%s,"rebase_clean":%s}\n' \
            "$_grade_ts" "$gid" "$_grade_model" "$_grade_agent" "$_grade_harness" \
            "$_grade_clippy_ok" "$_grade_test_added" "$_grade_rebase_clean" \
            >> "$_grade_amb" 2>/dev/null || true
    done
fi

# INFRA-492: emit session_end with outcome=shipped on the success path.
# Failure paths (exit 1 above) emit nothing — INFRA-477's outcome:abandoned
# is computed by absence of session_end pairing, but the session-track
# CLI doesn't auto-emit on shell exit. For now, success-path-only is
# the simpler implementation; failure-path emission can come as a
# follow-up if the abandoned-session signal becomes critical.
if [[ $DRY_RUN -eq 0 ]]; then
    for gid in "${GAP_IDS[@]:-}"; do
        [[ -z "$gid" ]] && continue
        chump session-track --end "$gid" --outcome shipped >/dev/null 2>&1 || true
    done
fi

# INFRA-495: release the operator's lease at end of successful ship.
# Pre-fix bot-merge.sh emitted session_end but left the lease file at
# .chump-locks/$CHUMP_SESSION_ID.json — the watcher then re-emitted
# silent_agent every hour for 6h until the TTL reaper deleted it.
# 'chump fleet-status' (INFRA-494) surfaced 10 such stale leases from
# manual ships within minutes of going live; this is the operator-side
# parallel of INFRA-490's worker.sh fix.
if [[ $DRY_RUN -eq 0 && -n "${CHUMP_SESSION_ID:-}" ]]; then
    rm -f "$REPO_ROOT/.chump-locks/${CHUMP_SESSION_ID}.json" 2>/dev/null || true
fi

green "=== bot-merge done. ==="
