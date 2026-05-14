#!/usr/bin/env bash
# pre-commit-pwa-index-uniq.sh — INFRA-1201
#
# Guards web/v2/index.html against two failure modes introduced by the
# merge=union driver:
#
# 1. Duplicate <script src="X.js"> lines. union merges unique LINES, so two
#    PRs that add the exact same script tag from different positions will
#    BOTH land (no auto-resolution). Catch at commit time.
#
# 2. Duplicate <chump-X></chump-X> top-level component placements. Same
#    issue: union merges line-unique entries, but if two PRs each add
#    "<chump-welcome></chump-welcome>" they'd both stay.
#
# Both are append-only zones so the merge driver is a net win — this guard
# just catches the rare same-tag duplication.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
INDEX="$REPO_ROOT/web/v2/index.html"

# Only run when the file is staged or exists.
if [[ ! -f "$INDEX" ]]; then
    exit 0
fi

fail=0

# Check 1: duplicate <script src="…"> lines.
dup_scripts=$(grep -E '^\s*<script src="[^"]+\.js"' "$INDEX" 2>/dev/null \
    | sed -E 's/^\s+//' \
    | sort | uniq -d)
if [[ -n "$dup_scripts" ]]; then
    echo "[pre-commit] FAIL: duplicate <script src=…> in web/v2/index.html:" >&2
    echo "$dup_scripts" | sed 's/^/  /' >&2
    echo "[pre-commit] cause: merge=union (INFRA-1201) merged identical tags from two branches." >&2
    echo "[pre-commit] fix: keep one, remove the dup; rerun commit." >&2
    fail=1
fi

# Check 2: duplicate top-level custom-element placement lines like
# "<chump-NAME></chump-NAME>" appearing more than once.
dup_components=$(grep -oE '<chump-[a-z][a-z0-9-]*></chump-[a-z][a-z0-9-]*>' "$INDEX" 2>/dev/null \
    | sort | uniq -d)
if [[ -n "$dup_components" ]]; then
    echo "[pre-commit] FAIL: duplicate <chump-X> placement in web/v2/index.html:" >&2
    echo "$dup_components" | sed 's/^/  /' >&2
    echo "[pre-commit] cause: merge=union (INFRA-1201) merged identical components from two branches." >&2
    echo "[pre-commit] fix: keep one placement; rerun commit." >&2
    fail=1
fi

exit $fail
