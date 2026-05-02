#!/usr/bin/env bash
# distill-pr-skills.sh — INFRA-195 v1 (2026-05-01)
#
# The infrastructure for cross-agent skill sharing already exists:
#   - chump_reflections          (parent rows, episode-linked)
#   - chump_improvement_targets  (child rows: directive + priority + scope)
#   - load_spawn_lessons()       (Rust path that prepends top-N to prompt)
#   - chump --briefing <ID>      (per-gap query path; MEM-007)
#
# What was MISSING: a feedback loop that distills SHIPPED PRs into new
# improvement_targets rows. Today they get added only by manual sqlite3
# INSERT (which is why nobody adds them).
#
# This script scans the most recently merged PR (or last N), runs a
# whitelist of pure-rule pattern matches over the diff, and INSERTs an
# improvement_target row for each match. Idempotent on (directive,
# scope) so repeated runs don't bloat the table.
#
# v1 is rule-based only. Future v2 (separate gap) can add LLM-based
# pattern detection on top.
#
# Usage:
#   scripts/ops/distill-pr-skills.sh                    # most recently merged PR
#   scripts/ops/distill-pr-skills.sh --pr 692           # specific PR
#   scripts/ops/distill-pr-skills.sh --last 5           # last N merged PRs
#   scripts/ops/distill-pr-skills.sh --dry-run          # report only, no INSERT
#
# Env:
#   CHUMP_DISTILL=0   bypass — exit 0 immediately (for tests)
#
# Exit codes:
#   0  ran (with or without new rows)
#   1  no PR found
#   2  database not writable
#   3  usage error

set -euo pipefail

if [[ "${CHUMP_DISTILL:-1}" == "0" ]]; then
    echo "[distill] CHUMP_DISTILL=0 — bypass"
    exit 0
fi

PR_ARG=""
LAST_N=1
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)       PR_ARG="$2"; shift 2 ;;
        --last)     LAST_N="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 3 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Linked worktrees don't have their own sessions/ dir — the canonical
# memory DB lives in the MAIN repo's sessions/. Derive via git-common-dir.
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi

DB="${CHUMP_MEMORY_DB:-$MAIN_REPO/sessions/chump_memory.db}"
[[ -f "$DB" ]] || { echo "[distill] memory DB missing: $DB" >&2; exit 2; }

say()  { printf '\033[1;36m[distill]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[distill]\033[0m %s\n' "$*" >&2; }

# ── Pattern whitelist ───────────────────────────────────────────────────────
# Each entry = "FILE_GLOB_OR_TITLE_REGEX|SCOPE|PRIORITY|DIRECTIVE"
# Scope ties the lesson to a domain so future agents working on that
# domain see it via load_spawn_lessons.
PATTERNS=(
    "scripts/coord/bot-merge.sh|INFRA|high|Use scripts/coord/bot-merge.sh as the canonical ship pipeline (handles fmt, clippy, tests, push, PR, auto-merge, INFRA-154 auto-close, INFRA-190 pr-watch hook)"
    "scripts/coord/gap-claim.sh|INFRA|medium|Claim gaps via gap-claim.sh which writes lease files. Pass --paths to declare scope (INFRA-189 enforces it)"
    "scripts/coord/gap-reserve.sh|INFRA|high|Reserve new gap IDs via 'chump gap reserve --domain X --title Y' (canonical Rust path) instead of editing docs/gaps.yaml directly — prevents ID collisions across sibling agents"
    "scripts/coord/pr-watch.sh|INFRA|high|pr-watch.sh auto-recovers DIRTY-after-arm PRs via rebase + force-push + re-arm. Already wired into bot-merge.sh by default; opt-out via CHUMP_PR_WATCH_AFTER_ARM=0"
    "scripts/coord/broadcast.sh|INFRA|high|Use broadcast.sh to announce intent / handoff / done to siblings before structural changes (kinds: INTENT, HANDOFF, STUCK, DONE, WARN, ALERT). Especially before any work that touches gaps.yaml or shared coord scripts"
    "crates/chump-perception/src/lib.rs|INFRA|medium|Build on chump-perception's structured perception (PerceivedInput.task_type/entities/constraints/risks/ambiguity_level + route_tools). Don't rebuild perception; extend it"
    ".github/workflows/.*\\.yml|INFRA|high|GH Actions multi-line strings inside 'run: |' blocks must NOT have column-1 lines or YAML pipe-scalar terminates at parse-time. Build the body in a bash heredoc"
    "Formula/.*\\.rb|INFRA|medium|Modern Homebrew rejects local-file formula paths. Use 'brew tap-new <name>/local --no-git --quiet && cp Formula/foo.rb \$(brew --repo <name>/local)/Formula/' for build-from-source tests"
    "docs/gaps\\.yaml|INFRA|high|gaps.yaml conflicts are the #1 source of merge friction. Add gap rows via 'chump gap reserve' (canonical SQLite path). Per-file split tracked as INFRA-188"
    "scripts/git-hooks/pre-commit|INFRA|medium|Pre-commit guards live here. Each guard has its own bypass env (CHUMP_LEASE_CHECK / CHUMP_GAPS_LOCK / CHUMP_SCOPE_CHECK / etc.); 'git commit --no-verify' bypasses all"
    "AGENTS\\.md|META|high|Cross-tool conventions (branches, worktrees, lease files, naming) live in AGENTS.md. CLAUDE.md / GEMINI.md / .cursorrules carry tool-specific overlays only. AGENTS.md wins on conflicts"
    "src/agent_loop/types\\.rs|INFRA|medium|Narration-detection retry (response_wanted_tools) is conservative post-INFRA-177: only past-tense success claims count. Don't broaden the patterns without considering the false-positive cost (INFRA-177 burned 2 model calls per conversational reply)"
    "scripts/dev/restart-chump-web\\.sh|INFRA|medium|Use restart-chump-web.sh after pulling main with new agent-loop / streaming / web-server changes — silent stale-binary serves wrong code (INFRA-148 class)"
)

# ── Find the target PR(s) ───────────────────────────────────────────────────
get_pr_numbers() {
    if [[ -n "$PR_ARG" ]]; then
        echo "$PR_ARG"
    else
        gh pr list --state merged --limit "$LAST_N" --json number -q '.[].number' 2>/dev/null
    fi
}

PRS=$(get_pr_numbers)
[[ -n "$PRS" ]] || { warn "no PRs found"; exit 1; }

# ── Process each PR ─────────────────────────────────────────────────────────
TOTAL_NEW=0
for PR in $PRS; do
    say "Distilling PR #${PR}…"
    FILES=$(gh pr view "$PR" --json files -q '.files[].path' 2>/dev/null)
    TITLE=$(gh pr view "$PR" --json title -q .title 2>/dev/null)
    if [[ -z "$FILES" ]]; then
        warn "  PR #$PR has no files; skipping"
        continue
    fi

    # Match each pattern against the file list + title
    for pattern_entry in "${PATTERNS[@]}"; do
        IFS='|' read -r match scope priority directive <<< "$pattern_entry"
        # Match: any file in the PR matches the regex/glob OR the title matches
        if printf '%s\n%s\n' "$FILES" "$TITLE" | grep -qE "$match"; then
            # Idempotency check: directive + scope already in the table?
            existing=$(sqlite3 "$DB" \
                "SELECT id FROM chump_improvement_targets WHERE directive = $(printf '%s' "$directive" | sed "s/'/''/g; s/^/'/; s/$/'/") AND scope = $(printf '%s' "$scope" | sed "s/'/''/g; s/^/'/; s/$/'/") LIMIT 1;" 2>/dev/null || true)
            if [[ -n "$existing" ]]; then
                continue  # already known
            fi

            if [[ "$DRY_RUN" -eq 1 ]]; then
                say "  [dry-run] would insert: scope=$scope priority=$priority directive=\"${directive:0:60}…\""
                continue
            fi

            # Insert parent reflection + child improvement_target in a tx.
            # Reflection rows can have empty episode/task IDs (NOT NULL has
            # a default).
            actioned_as="PR#$PR"
            sqlite3 "$DB" <<SQL 2>/dev/null
BEGIN;
INSERT INTO chump_reflections (intended_goal, observed_outcome, outcome_class, hypothesis)
    VALUES ('Distill PR #$PR pattern: $match',
            '$(printf '%s' "$TITLE" | sed "s/'/''/g")',
            'success',
            'pure-rule pattern match in distill-pr-skills.sh');
INSERT INTO chump_improvement_targets (reflection_id, directive, priority, scope, actioned_as)
    VALUES (last_insert_rowid(),
            $(printf '%s' "$directive" | sed "s/'/''/g; s/^/'/; s/$/'/"),
            '$priority',
            '$scope',
            '$actioned_as');
COMMIT;
SQL
            if [[ $? -eq 0 ]]; then
                TOTAL_NEW=$((TOTAL_NEW + 1))
                say "  inserted: scope=$scope priority=$priority"
            else
                warn "  insert failed for pattern: $match"
            fi
        fi
    done
done

say "Distillation complete: ${TOTAL_NEW} new improvement_target row(s)."
if [[ "$TOTAL_NEW" -gt 0 ]]; then
    say "  Next agent with CHUMP_LESSONS_AT_SPAWN_N>0 will pick them up automatically."
    say "  Manual peek: chump --briefing <GAP-ID> (per-gap) or sqlite3 ${DB} 'SELECT directive, scope, priority FROM chump_improvement_targets ORDER BY id DESC LIMIT 10;'"
fi
exit 0
