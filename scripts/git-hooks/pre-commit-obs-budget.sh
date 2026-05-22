#!/usr/bin/env bash
# pre-commit-obs-budget.sh — INFRA-755
#
# "Observability budget" guard. Refuses commits where the staged diff
# adds substantial feature code (default >50 lines across .rs/.sh/.py)
# but introduces ZERO new observability hooks.
#
# Companion to INFRA-754 (event registry). Where INFRA-754 enforces that
# every ambient.jsonl `kind=` value is documented, this guard nudges
# every meaningful new code path to at least *try* to emit something —
# tracing macros, structured ambient events, or chump_improvement_targets
# rows. It catches the "shipped a feature, forgot the logs" failure
# mode at the cheapest possible point.
#
# What counts as feature code:
#   Added lines in *.rs / *.sh / *.py (excluding the registry / hook /
#   test files themselves) that are NOT empty, NOT comments.
#
# What counts as observability code (any of):
#   tracing::{info,warn,error,debug}!  /  info!(  /  warn!(  /  error!(
#   "kind":"..."                         (ambient event JSON)
#   ambient-emit.sh                       (script that writes ambient)
#   chump_improvement_targets             (lessons table writes)
#   metric_record / metric_inc            (placeholder metric API)
#
# Tunables:
#   CHUMP_OBS_BUDGET_FEATURE_THRESHOLD  feature-line cap before guard fires
#                                        (default: 50)
#   CHUMP_OBS_BUDGET_BYPASS=1           skip guard entirely; commit body
#                                        MUST include `Obs-Bypass-Reason:`
#                                        trailer (the wrapper checks).
#
# Bypass discipline mirrors --no-verify: sparingly, with a documented
# reason. The reason field is what the operator audits in retrospect.

set -uo pipefail

# Bypass switch (matches the --no-verify pattern used by other guards)
if [[ "${CHUMP_OBS_BUDGET_BYPASS:-0}" == "1" ]]; then
    exit 0
fi

THRESHOLD="${CHUMP_OBS_BUDGET_FEATURE_THRESHOLD:-50}"

# numstat = added\tremoved\tpath ; we want only added across our code
# extensions, ignoring the guard's own test fixtures and hook plumbing.
#
# INFRA-1398: also exclude CI assertion scripts (scripts/ci/test-*.sh) — they
# don't emit runtime events because they ARE the observability (the assertions
# themselves). Same for scripts/git-hooks/* (they're pre-commit gates, not
# runtime code paths). Forcing operators to add tracing::info! inside a CI
# assert script makes no semantic sense and burned ~7 bypass-trailers in the
# 2026-05-16 session alone.
STATS=$(git diff --cached --numstat --diff-filter=ACM -- \
    '*.rs' '*.sh' '*.py' 2>/dev/null \
    | grep -vE '(scripts/git-hooks/|scripts/ci/test-)' \
    || true)

if [[ -z "$STATS" ]]; then
    exit 0
fi

# Sum feature-line additions. Skip binary diffs (numstat shows "-").
FEATURE_ADDED=$(printf '%s\n' "$STATS" \
    | awk '$1 != "-" { sum += $1 } END { print sum+0 }')

if [[ "$FEATURE_ADDED" -le "$THRESHOLD" ]]; then
    exit 0
fi

# Now scan the actual added content for observability markers.
# We look at the unified diff and grep for either tracing macros or
# the ambient kind shape or chump_improvement_targets writes.
DIFF_BODY=$(git diff --cached --no-color --diff-filter=ACM -U0 -- \
    '*.rs' '*.sh' '*.py' 2>/dev/null || true)

# Only consider added lines (start with `+`, not the +++ header).
ADDED_LINES=$(printf '%s\n' "$DIFF_BODY" | grep -E '^\+[^+]' || true)

OBS_HITS=0
# INFRA-1658: tempfile materialization to avoid printf|grep -qE pipefail race.
# Under set -o pipefail, grep -q closes stdin on first match → printf gets
# SIGPIPE → pipeline exits non-zero even when the pattern matched. See
# docs/process/CLAUDE_GOTCHAS.md "printf | grep -q pipefail race".
_OBS_TMP=$(mktemp)
printf '%s\n' "$ADDED_LINES" > "$_OBS_TMP"
if grep -qE \
    'tracing::(info|warn|error|debug|trace)!|^[+][[:space:]]*(info|warn|error|debug|trace)!\(|"kind"[[:space:]]*:[[:space:]]*"|\\"kind\\"[[:space:]]*:[[:space:]]*\\"|ambient-emit\.sh|chump_improvement_targets|metric_record|metric_inc' \
    "$_OBS_TMP"; then
    OBS_HITS=1
fi
rm -f "$_OBS_TMP"

if [[ "$OBS_HITS" -gt 0 ]]; then
    exit 0
fi

# Block: feature-heavy commit with no observability hook.
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "❌ INFRA-755 observability-budget guard blocked this commit." >&2
echo "" >&2
echo "Staged diff adds $FEATURE_ADDED lines of feature code (.rs/.sh/.py)" >&2
echo "but contains 0 new observability hooks." >&2
echo "" >&2
echo "Threshold: > $THRESHOLD lines." >&2
echo "" >&2
echo "Why: every meaningful code path should be observable from" >&2
echo ".chump-locks/ambient.jsonl, tracing logs, or chump_improvement_targets." >&2
echo "Without it, consumers (fleet-brief, kpi-report, watchdogs) can't" >&2
echo "tell whether the new path ran or wedged. See" >&2
echo "docs/process/OBSERVABILITY_DOCTRINE.md." >&2
echo "" >&2
echo "Fix one of:" >&2
echo "  1. Add at least one observability hook to the new code:" >&2
echo "       - tracing::info!(... ) / warn!() / error!()" >&2
echo "       - emit an ambient event with \"kind\":\"<name>\"" >&2
echo "         (must also be registered per INFRA-754)" >&2
echo "       - record a chump_improvement_targets lesson" >&2
echo "" >&2
echo "  2. Bypass once, with a reason in the commit body:" >&2
echo "       CHUMP_OBS_BUDGET_BYPASS=1 git commit ..." >&2
echo "     and add a trailer:" >&2
echo "       Obs-Bypass-Reason: <one-sentence why>" >&2
echo "" >&2
echo "  3. Raise the threshold for this commit:" >&2
echo "       CHUMP_OBS_BUDGET_FEATURE_THRESHOLD=<N> git commit ..." >&2
echo "──────────────────────────────────────────────────────────────────────" >&2

exit 1
