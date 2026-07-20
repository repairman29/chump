#!/usr/bin/env bash
# test-curator-pillar-no-overlap.sh — MISSION-003
#
# Verifies that no two curator roles declare the same non-null
# `primary_pillar` in their .claude/agents/<role>.md frontmatter, per
# docs/process/CURATOR_PILLAR_MATRIX.md. Roles with `primary_pillar: null`
# (coordination roles, e.g. `handoff`) are exempt — multiple coordination
# roles are allowed since they don't compete for pillar focus.
#
# Scope: the 9-role set named in docs/process/CURATOR_PILLAR_MATRIX.md
# (target / shepherd / ci-audit / handoff / decompose / md-links /
# overnight / autopilot / orchestrator). Roles not yet productized
# (missing .claude/agents/<role>.md) are skipped, not failed.
#
# Exit codes:
#   0 — no overlap detected
#   1 — two or more roles share a non-null primary_pillar
#   2 — CURATOR_PILLAR_MATRIX.md itself is missing (catastrophic)

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

DOC="docs/process/CURATOR_PILLAR_MATRIX.md"
AGENTS_DIR=".claude/agents"
ROLES=(target shepherd ci-audit handoff decompose md-links overnight autopilot orchestrator)

if [[ ! -f "$DOC" ]]; then
    printf '\033[31mFATAL\033[0m: %s missing — matrix undocumented\n' "$DOC" >&2
    exit 2
fi

printf '== Curator pillar no-overlap gate (MISSION-003) ==\n\n'

declare -a seen_pillars=()
declare -a seen_roles=()
FAIL=0
SKIP=0

for role in "${ROLES[@]}"; do
    f="$AGENTS_DIR/$role.md"
    if [[ ! -f "$f" ]]; then
        printf '  \033[33m·\033[0m %s.md not yet productized — skip\n' "$role"
        SKIP=$((SKIP+1))
        continue
    fi

    line="$(grep -m1 '^primary_pillar:' "$f" || true)"
    if [[ -z "$line" ]]; then
        printf '  \033[31m✗\033[0m %s.md missing primary_pillar field\n' "$role"
        FAIL=$((FAIL+1))
        continue
    fi

    pillar="$(printf '%s' "$line" | sed 's/^primary_pillar:[[:space:]]*//')"

    if [[ "$pillar" == "null" ]]; then
        printf '  \033[32m✓\033[0m %s.md primary_pillar=null (coordination role, exempt)\n' "$role"
        continue
    fi

    for i in "${!seen_pillars[@]}"; do
        if [[ "${seen_pillars[$i]}" == "$pillar" ]]; then
            printf '  \033[31m✗\033[0m %s.md and %s.md both declare primary_pillar=%s — overlap\n' \
                "${seen_roles[$i]}" "$role" "$pillar"
            FAIL=$((FAIL+1))
        fi
    done

    seen_pillars+=("$pillar")
    seen_roles+=("$role")
    printf '  \033[32m✓\033[0m %s.md primary_pillar=%s\n' "$role" "$pillar"
done

printf '\n== Summary: %d roles checked, %d overlap/missing failures, %d skipped ==\n' \
    "${#seen_roles[@]}" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
