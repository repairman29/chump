#!/usr/bin/env bash
# scripts/coord/daily-self-productize.sh — META-098
#
# Daily A2A wave that asks each curator role to add delta-AC for what
# changed in their lane in the last 24h. Productizes the manual operator-
# initiated wave that spawned META-097 (and the 4 sibling productizations
# INFRA-1922/1923/1924/1925) into a recurring ritual.
#
# Operator's principle: "Automate today so we can innovate tomorrow."
#
# Per run:
#   1. Check today-already-fired guard (idempotent on same date)
#   2. For each of 6 curator roles, send a broadcast.sh DM asking the
#      curator to contemplate their lane and either add delta-AC to
#      their agent.md/SKILL.md or file a follow-up gap
#   3. Emit kind=daily_self_productize_wave with roles_paged count
#   4. Stamp the state file so today's run won't re-fire
#
# The actual contemplation happens inside the curator's session when its
# PostToolUse inbox-poll surfaces this message — this script does NOT
# call any LLM. Cost is 6 file-writes (one per inbox).
#
# Bypass: CHUMP_DAILY_PRODUCTIZE_DISABLED=1.

set -uo pipefail

# Quick bypass
[[ "${CHUMP_DAILY_PRODUCTIZE_DISABLED:-0}" == "1" ]] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE="$REPO_ROOT/.chump-locks/daily-self-productize-state.jsonl"
DATE="${CHUMP_SELF_PRODUCTIZE_DATE_OVERRIDE:-$(date -u +%Y-%m-%d)}"
WIZARD="${CHUMP_WIZARD_SESSION:-orchestrator-opus-${DATE}}"

mkdir -p "$(dirname "$STATE")"
touch "$STATE"

# Idempotency — if today already fired, exit 0 silently
if grep -q "\"last_run_date\":\"${DATE}\"" "$STATE" 2>/dev/null; then
    echo "[daily-self-productize] already fired today ($DATE) — no-op"
    exit 0
fi

# Locate broadcast.sh (script lives in scripts/coord/)
BCAST="$REPO_ROOT/scripts/coord/broadcast.sh"
if [[ ! -x "$BCAST" ]]; then
    echo "[daily-self-productize] broadcast.sh missing or non-executable at $BCAST" >&2
    exit 1
fi

ROLES=(target handoff ci-audit shepherd decompose md-links)
paged=0
failed=0

for role in "${ROLES[@]}"; do
    curator="curator-opus-${role}-${DATE}"

    # Message: ask curator to contemplate their lane + add delta-AC OR file follow-up
    msg="DAILY-SELF-PRODUCTIZE wave (META-098) — please contemplate what changed in YOUR lane (${role}) in the last 24h:
1. Scan ambient.jsonl for kind events tagged to your role; scan recent shipped PRs with title prefix matching your pillar focus
2. If material change occurred, either: (a) edit .claude/agents/${role}.md or .claude/skills/${role}/SKILL.md with a new lane-scope item / discipline rule / pattern reference, OR (b) file a follow-up META gap with concrete AC for the productization work
3. Reply DONE to ${WIZARD} with what you decided (committed-delta or filed-gap or no-op-no-change)
Operator principle: 'Automate today so we can innovate tomorrow.' Your role.md should accrue ≥1 commit per week if your lane is active."

    if bash "$BCAST" --to "$curator" WARN "$msg" >/dev/null 2>&1; then
        paged=$((paged + 1))
        echo "[daily-self-productize] paged $curator"
    else
        failed=$((failed + 1))
        echo "[daily-self-productize] FAILED to page $curator" >&2
    fi
done

# Emit drift signal
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"daily_self_productize_wave","date":"%s","roles_paged":%d,"failed":%d}\n' \
    "$ts" "$DATE" "$paged" "$failed" >> "$AMBIENT"

# Stamp state file (idempotent)
printf '{"ts":"%s","last_run_date":"%s","roles_paged":%d,"failed":%d}\n' \
    "$ts" "$DATE" "$paged" "$failed" >> "$STATE"

echo "[daily-self-productize] done — paged=$paged failed=$failed"
exit 0
