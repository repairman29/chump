#!/usr/bin/env bash
# lint-handoff-comment.sh — INFRA-769: validate Review-as-Handoff comment format.
#
# A handoff comment is a PR comment that contains a [handoff:apply] annotation.
# Only comments with that annotation are validated — plain review comments are
# passed through without error (non-handoff comments are advisory-only).
#
# Required sections (in order, per REVIEW_AS_HANDOFF.md §3):
#   ## Failure surface
#   ## Root cause
#   ## Apply this diff
#   ## Verification
#   [handoff:apply by=<id> verified=<true|false>]
#
# Usage:
#   lint-handoff-comment.sh < comment.md
#   lint-handoff-comment.sh comment.md
#   echo "comment body" | lint-handoff-comment.sh
#
# Exit codes:
#   0 — valid handoff comment, or not a handoff comment (no [handoff:apply])
#   1 — contains [handoff:apply] but is malformed (missing sections/annotation)
#   2 — usage error

set -uo pipefail

# Read input: from file argument or stdin
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [comment.md]  (or pipe comment body to stdin)" >&2
    exit 2
fi

if [[ $# -eq 1 ]]; then
    if [[ ! -f "$1" ]]; then
        echo "[lint-handoff] ERROR: file not found: $1" >&2
        exit 2
    fi
    body="$(cat "$1")"
else
    body="$(cat)"
fi

# Not a handoff comment — skip silently.
if ! echo "$body" | grep -q '\[handoff:apply'; then
    exit 0
fi

FAIL=0
errors=()

# ── Required sections ─────────────────────────────────────────────────────
required_sections=(
    "## Failure surface"
    "## Root cause"
    "## Apply this diff"
    "## Verification"
)
for section in "${required_sections[@]}"; do
    if ! echo "$body" | grep -qF "$section"; then
        errors+=("missing required section: '$section'")
        FAIL=1
    fi
done

# ── [handoff:apply] annotation syntax ────────────────────────────────────
# Required form: [handoff:apply by=<non-empty-id> verified=<true|false>]
if ! echo "$body" | grep -qE '\[handoff:apply by=[^ ]+ verified=(true|false)\]'; then
    errors+=("malformed [handoff:apply] annotation — required form: [handoff:apply by=<id> verified=true|false]")
    FAIL=1
fi

# ── Apply this diff must contain a diff block ─────────────────────────────
# After "## Apply this diff", there should be a ```diff block or explicit
# edit instructions (any non-empty content). Warn if the section appears
# empty (just the heading with nothing following before the next section).
diff_section=$(echo "$body" | awk '/^## Apply this diff/{found=1; next} found && /^## /{exit} found{print}')
if [[ -z "$(echo "$diff_section" | tr -d '[:space:]')" ]]; then
    errors+=("'## Apply this diff' section is empty — must contain a unified diff or precise edit instructions")
    FAIL=1
fi

# ── Report ────────────────────────────────────────────────────────────────
if [[ $FAIL -eq 0 ]]; then
    echo "[lint-handoff] OK: valid handoff comment (all 4 sections + annotation present)"
    exit 0
fi

echo "[lint-handoff] FAIL: malformed handoff comment:" >&2
for e in "${errors[@]}"; do
    echo "  - $e" >&2
done
echo "" >&2
echo "Required format (REVIEW_AS_HANDOFF.md §3):" >&2
echo "  ## Failure surface" >&2
echo "  ## Root cause" >&2
echo "  ## Apply this diff" >&2
echo "  ## Verification" >&2
echo "  [handoff:apply by=<reviewer-id> verified=true|false]" >&2
exit 1
