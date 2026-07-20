#!/usr/bin/env bash
# test-curator-pillar-no-overlap.sh — MISSION-003
#
# Validates that every checked-in .claude/agents/<role>.md declares a
# `primary_pillar:` frontmatter field, and that no two curators declare the
# same non-null primary_pillar value (coordination-lane roles are allowed to
# share `null` since they route work rather than own a pillar).

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/.claude/agents"

echo "=== MISSION-003 curator pillar no-overlap test ==="
echo

if [[ ! -d "$AGENTS_DIR" ]]; then
    fail "agents dir missing: $AGENTS_DIR"
    echo
    echo "PASS=$PASS FAIL=$FAIL"
    exit 1
fi

declare -a seen_values=()
declare -a seen_files=()
missing_field=0
dup_found=0

for f in "$AGENTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"

    line="$(sed -n '2,10p' "$f" | grep -m1 '^primary_pillar:' || true)"
    if [[ -z "$line" ]]; then
        fail "$base — missing primary_pillar frontmatter field"
        missing_field=$((missing_field + 1))
        continue
    fi

    val="$(echo "$line" | sed 's/^primary_pillar: *//')"

    if [[ "$val" == "null" ]]; then
        ok "$base — primary_pillar: null (coordination lane, overlap allowed)"
        continue
    fi

    dup_idx=-1
    for i in "${!seen_values[@]}"; do
        if [[ "${seen_values[$i]}" == "$val" ]]; then
            dup_idx=$i
            break
        fi
    done

    if [[ $dup_idx -ge 0 ]]; then
        fail "$base declares primary_pillar='$val', already claimed by ${seen_files[$dup_idx]}"
        dup_found=$((dup_found + 1))
    else
        ok "$base — primary_pillar: $val (unique)"
        seen_values+=("$val")
        seen_files+=("$base")
    fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"

if [[ $missing_field -gt 0 || $dup_found -gt 0 ]]; then
    exit 1
fi

exit 0
