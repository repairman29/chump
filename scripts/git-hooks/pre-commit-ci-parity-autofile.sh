#!/usr/bin/env bash
# pre-commit-ci-parity-autofile.sh — RESILIENT-587 (RESILIENT-545 slice)
#
# Fires ONLY when .github/workflows/ci.yml is part of the staged diff.
# Runs the existing parity classifier (scripts/ci/test-preflight-ci-parity.sh)
# in --report mode and, for any gate it reports as unmirrored/unallowlisted
# (i.e. a newly-added CI gate that lacks a preflight mirror or Tier-D
# classification), auto-appends an allowlist line to
# scripts/ci/preflight-ci-parity-exceptions.txt so the commit is not blocked
# by scripts/git-hooks/pre-commit-preflight-ci-parity.sh, which runs right
# after this hook in the pre-commit orchestrator.
#
# This does NOT replace human triage — the auto-filed entry says so and
# flags a follow-up gap should be filed to give the gate a real mirror or
# Tier-D classification. It exists to unblock the commit instead of forcing
# a manual edit of the exceptions file for every new gate.
#
# AC (RESILIENT-587):
#   1. Runs on staged changes to .github/workflows/ci.yml
#   2. New gate -> appends the exceptions line, allows the commit
#   3. Cannot update the exceptions file -> aborts the commit with an error
#   4. Entry already exists -> passes without modification
#
# Bypass: CHUMP_CI_PARITY_AUTOFILE=0

set -uo pipefail

if [ "${CHUMP_CI_PARITY_AUTOFILE:-1}" = "0" ]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 0

# AC1: fire only when ci.yml is staged.
if ! git diff --cached --name-only | grep -qE '^\.github/workflows/ci\.yml$'; then
    exit 0
fi

# Overridable so the AC smoke test (test-pre-commit-ci-parity-autofile.sh)
# can point this hook at synthetic fixtures instead of the real repo files.
# Defaults are unchanged.
PARITY_SCRIPT="${CHUMP_CI_PARITY_AUTOFILE_SCRIPT:-$REPO_ROOT/scripts/ci/test-preflight-ci-parity.sh}"
EXCEPTIONS_FILE="${CHUMP_PARITY_EXCEPTIONS_FILE:-$REPO_ROOT/scripts/ci/preflight-ci-parity-exceptions.txt}"

if [ ! -f "$PARITY_SCRIPT" ]; then
    # Nothing to classify against — soft-skip, the blocking hook is the backstop.
    exit 0
fi

# Run the classifier in report mode. It always prints the DELTA detail list
# regardless of exit code, so ignore the exit status here.
REPORT_OUT="$(CHUMP_PARITY_REPORT=1 bash "$PARITY_SCRIPT" 2>/dev/null || true)"

# Extract lines of the form:
#   - [ci.yml] job=fast-checks step='some step name' (scripts/ci/foo.sh)
DELTA_LINES="$(printf '%s\n' "$REPORT_OUT" | grep -E '^\s+-\s+\[.*\]\s+job=.*step=' || true)"

if [ -z "$DELTA_LINES" ]; then
    # No delta -> nothing new to file (AC4-adjacent: no-op when there's
    # nothing unclassified, which also covers "entry already exists").
    exit 0
fi

APPENDED=0
FAILED=0

while IFS= read -r line; do
    [ -z "$line" ] && continue

    # step='...' capture (single-quoted, may contain spaces/parens)
    step_name="$(printf '%s\n' "$line" | sed -n "s/.*step='\([^']*\)'.*/\1/p")"
    # trailing (ci_path) capture
    ci_path="$(printf '%s\n' "$line" | sed -n 's/.*(\(scripts\/ci\/[^)]*\.sh\))\s*$/\1/p')"

    identifier="$ci_path"
    if [ -z "$identifier" ]; then
        identifier="$step_name"
    fi
    [ -z "$identifier" ] && continue

    # AC4: entry already present (exact first-field match) -> skip, no modification.
    if [ -f "$EXCEPTIONS_FILE" ] && grep -qF "$identifier" "$EXCEPTIONS_FILE"; then
        continue
    fi

    entry_line="$identifier   # reason: auto-filed by pre-commit-ci-parity-autofile.sh (RESILIENT-587) — new CI gate in .github/workflows/ci.yml added without a preflight mirror or Tier-D classification; file a follow-up gap and replace this entry with a proper classification."

    if ! printf '%s\n' "$entry_line" >> "$EXCEPTIONS_FILE" 2>/dev/null; then
        FAILED=1
        break
    fi
    APPENDED=1
done <<EOF
$DELTA_LINES
EOF

if [ "$FAILED" = "1" ]; then
    echo "[pre-commit] ci-parity-autofile: could not write to $EXCEPTIONS_FILE (RESILIENT-587)" >&2
    echo "[pre-commit] Aborting commit — fix file permissions or add the exception manually." >&2
    echo "[pre-commit] Bypass: CHUMP_CI_PARITY_AUTOFILE=0 git commit ..." >&2
    exit 1
fi

if [ "$APPENDED" = "1" ]; then
    git add "$EXCEPTIONS_FILE" 2>/dev/null || true
    echo "[pre-commit] ci-parity-autofile: auto-appended new gate(s) to $EXCEPTIONS_FILE (RESILIENT-587)" >&2
    echo "[pre-commit] Review the auto-filed entry and replace it with a real preflight mirror or Tier-D classification." >&2
fi

exit 0
