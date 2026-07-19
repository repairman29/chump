#!/usr/bin/env bash
# test-curator-pillar-no-overlap.sh — MISSION-003
#
# Verifies that the named curator roles from the 2026-05-24 operator
# pillar-balance directive (target / shepherd / ci-audit / handoff /
# decompose / md-links / overnight / autopilot / orchestrator) each
# declare a `primary_pillar:` field in their .claude/agents/<role>.md
# frontmatter, and that no two roles declare the SAME primary_pillar
# value — except `null`, which is reserved for cross-lane coordination
# roles (handoff) and may repeat.
#
# Scope note: this checks the 9 roles named in MISSION-003's background
# (the operator's "~8 alive sessions" directive), not the full curator
# roster under .claude/agents/ — later-productized curators (context-keeper,
# historian, roadmap-keeper, etc.) are a separate META-097 sub-fleet cohort
# and are out of scope for this specific no-overlap check. Roles from the
# named list not yet productized (no .claude/agents/<role>.md file) are
# skipped, not failed — mirrors scripts/ci/test-inbox-watcher-pattern.sh.
#
# Exit codes:
#   0 — every present named role declares primary_pillar, no overlap
#   1 — a present role is missing primary_pillar, OR two roles collide
#   2 — docs/process/CURATOR_PILLAR_MATRIX.md itself is missing (catastrophic)

set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

DOC="docs/process/CURATOR_PILLAR_MATRIX.md"
AGENTS_DIR=".claude/agents"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { SKIP=$((SKIP+1)); printf '  \033[33m·\033[0m %s\n' "$*"; }

if [[ ! -f "$DOC" ]]; then
    printf '\033[31mFATAL\033[0m: %s missing — pillar matrix undocumented\n' "$DOC" >&2
    exit 2
fi
printf '== Curator pillar no-overlap test (MISSION-003) ==\n\n'
ok "$DOC exists"

ROLES=(target shepherd ci-audit handoff decompose md-links overnight autopilot orchestrator)

declare -a seen_pillars=()
declare -a seen_roles=()

for role in "${ROLES[@]}"; do
    f="$AGENTS_DIR/$role.md"
    if [[ ! -f "$f" ]]; then
        note "$role.md not yet productized — skip (per test-inbox-watcher-pattern.sh precedent)"
        continue
    fi

    pillar_line="$(grep -m1 '^primary_pillar:' "$f" || true)"
    if [[ -z "$pillar_line" ]]; then
        ko "$role.md missing 'primary_pillar:' frontmatter field"
        continue
    fi

    pillar="$(echo "$pillar_line" | sed 's/^primary_pillar: *//' | tr -d '\r')"
    ok "$role.md declares primary_pillar: $pillar"

    if [[ "$pillar" == "null" ]]; then
        continue
    fi

    for i in "${!seen_pillars[@]}"; do
        if [[ "${seen_pillars[$i]}" == "$pillar" ]]; then
            ko "overlap: $role.md and ${seen_roles[$i]}.md both declare primary_pillar: $pillar"
        fi
    done
    seen_pillars+=("$pillar")
    seen_roles+=("$role")
done

printf '\n== Summary: %d passed, %d failed, %d skipped ==\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
