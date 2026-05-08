#!/usr/bin/env bash
# test-observability-coverage.sh — INFRA-757
#
# Closes the loop on the INFRA-754/755 doctrine: the registry guards
# what's *committed*, this CI test grades what's *merged*. For every
# new src/*.rs reachable from src/main.rs, src/dispatch.rs, or
# src/agent_loop/*, AND every new scripts/dispatch/*.sh / scripts/coord/*.sh
# in the PR diff against origin/main, assert that file contains at least
# one observability hook.
#
# Why this is in CI rather than pre-commit:
#   - Pre-commit guards are local and bypassable; CI is the strict gate.
#   - "New file in PR" is a comparison against origin/main that a
#     pre-commit hook can't reliably do (the local repo may be ahead/behind).
#   - Catches the case where someone added a path-filter exemption in
#     pre-commit that lets a no-obs file slip through.
#
# Bypass:
#   CHUMP_OBS_COVERAGE_CHECK=0  (env, must be set in the repo workflow —
#                                not a flag, so a contributor can't bypass
#                                from their commit alone).

set -uo pipefail

# Bypass switch
if [[ "${CHUMP_OBS_COVERAGE_CHECK:-1}" == "0" ]]; then
    echo "[obs-coverage] CHUMP_OBS_COVERAGE_CHECK=0 — skipping"
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 2

# Resolve a base ref to diff against. CI sets GITHUB_BASE_REF on PR runs;
# fall back to origin/main for local invocation; if neither resolves,
# bail out (nothing to compare).
BASE_REF="${GITHUB_BASE_REF:-main}"
if ! git rev-parse "origin/$BASE_REF" >/dev/null 2>&1; then
    if ! git rev-parse "$BASE_REF" >/dev/null 2>&1; then
        echo "[obs-coverage] no base ref resolvable — skipping"
        exit 0
    fi
    BASE_REF_FULL="$BASE_REF"
else
    BASE_REF_FULL="origin/$BASE_REF"
fi

# Find files added in this PR's diff (status A) under the watched paths.
# We grade only NEW files — modifying an existing untouched file is the
# obs-budget guard's concern, not this one.
ADDED_FILES=$(git diff --name-only --diff-filter=A "$BASE_REF_FULL"...HEAD -- \
    'src/*.rs' 'src/**/*.rs' \
    'scripts/dispatch/*.sh' 'scripts/coord/*.sh' 2>/dev/null || true)

if [[ -z "$ADDED_FILES" ]]; then
    echo "[obs-coverage] no new src/*.rs or scripts/{dispatch,coord}/*.sh in this PR"
    exit 0
fi

# Filter src/*.rs files: only count ones that look like they are wired
# into the agent loop. Heuristic: the file's module name appears in
# src/main.rs OR src/dispatch.rs OR any file under src/agent_loop/. We
# tolerate a missing reference (a brand-new module that nothing yet
# imports) by also accepting any file under src/agent_loop/* as
# automatically in scope.
is_in_scope_rs() {
    local path=$1
    local stem
    stem=$(basename "$path" .rs)

    # Anything under agent_loop is implicitly in scope.
    case "$path" in
        src/agent_loop/*) return 0 ;;
    esac

    # Otherwise check whether main.rs / dispatch.rs / agent_loop/* refers
    # to it. `mod foo;` or `use crate::foo` or `crate::foo::` patterns.
    if grep -rqE "(^|[^A-Za-z0-9_])(mod[[:space:]]+${stem}[[:space:]]*;|crate::${stem}(::|[[:space:]]))" \
        src/main.rs src/dispatch.rs src/agent_loop/ 2>/dev/null; then
        return 0
    fi

    return 1
}

# Observability marker regex. Mirrors INFRA-755 obs-budget hook + adds
# the chump_improvement_targets / metric.* shapes the gap calls out.
OBS_REGEX='tracing::(info|warn|error|debug|trace)!|^[[:space:]]*(info|warn|error|debug|trace)!\(|"kind"[[:space:]]*:[[:space:]]*"|\\"kind\\"[[:space:]]*:[[:space:]]*\\"|ambient-emit\.sh|ambient\.jsonl|chump_improvement_targets|metric\.(gauge|counter|histogram)|metric_record|metric_inc'

UNCOVERED=()
for f in $ADDED_FILES; do
    [[ -f "$f" ]] || continue   # deleted-then-renamed edge case

    # Apply the in-scope filter for src/*.rs only; .sh files are always in scope.
    case "$f" in
        src/*.rs)
            if ! is_in_scope_rs "$f"; then
                continue
            fi
            ;;
    esac

    if ! grep -qE "$OBS_REGEX" "$f"; then
        UNCOVERED+=("$f")
    fi
done

if [[ "${#UNCOVERED[@]}" -eq 0 ]]; then
    echo "[obs-coverage] all new in-scope files contain observability hooks ✓"
    exit 0
fi

# Block with a diagnostic.
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "❌ INFRA-757 observability-coverage check failed." >&2
echo "" >&2
echo "These new files are reachable from the agent loop / dispatch and" >&2
echo "contain ZERO observability hooks:" >&2
for f in "${UNCOVERED[@]}"; do
    echo "    $f" >&2
done
echo "" >&2
echo "Why: every load-bearing path must be visible in tracing logs," >&2
echo "ambient.jsonl, or chump_improvement_targets so consumers can grade" >&2
echo "it. See docs/process/OBSERVABILITY_DOCTRINE.md." >&2
echo "" >&2
echo "Fix: add at least one of:" >&2
echo "    tracing::info!() / warn!() / error!()" >&2
echo "    a structured ambient event (\"kind\":\"<name>\" — must also be" >&2
echo "      registered per INFRA-754)" >&2
echo "    a chump_improvement_targets row write" >&2
echo "    a metric.{gauge,counter,histogram}() emit" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2
exit 1
