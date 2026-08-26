#!/usr/bin/env bash
# test-infra-3803-stale-conflict-retirement.sh — INFRA-3803 regression test.
#
# Verifies the two pieces of logic added to scripts/ops/stale-pr-reaper.sh's
# "stale+conflicting PR retirement" section:
#   1. gap_priority_at / priority_rank correctly detect a gap demotion
#      (priority lowered) between a PR's merge-base and current main.
#   2. The retirement gate: DIRTY + stale >= threshold days => retire;
#      anything else => not yet / not a candidate.
#
# This does NOT spin up the full reaper script (it depends on `gh` + a
# remote). It exercises the same logic via inline mirrors, matching the
# existing test-infra-258-reaper-partial-delivery.sh convention.

set -euo pipefail

priority_rank() {
    case "$1" in
        P0) echo 0 ;;
        P1) echo 1 ;;
        P2) echo 2 ;;
        P3) echo 3 ;;
        *)  echo 9 ;;
    esac
}

gap_priority_at() {
    local ref="$1" gid="$2"
    git show "${ref}:docs/gaps/${gid}.yaml" 2>/dev/null | awk '
        /^- id:/{f=1; next}
        f && /^[[:space:]]+priority:[[:space:]]/{
            sub(/^[[:space:]]+priority:[[:space:]]*/,""); print; exit
        }'
}

is_demoted() {
    local base_prio="$1" cur_prio="$2"
    [[ -z "$base_prio" || -z "$cur_prio" ]] && return 1
    [[ "$base_prio" == "$cur_prio" ]] && return 1
    [[ "$(priority_rank "$cur_prio")" -gt "$(priority_rank "$base_prio")" ]]
}

is_retirement_candidate() {
    local mss="$1" age_days="$2" threshold="$3"
    [[ "$mss" == "DIRTY" ]] || return 1
    [[ "$age_days" -ge "$threshold" ]]
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q -b main
git config user.email "test@chump.local"
git config user.name "Chump Test"

mkdir -p docs/gaps
cat > docs/gaps/INFRA-9001.yaml <<'EOF'
- id: INFRA-9001
  domain: INFRA
  title: "test gap"
  status: open
  priority: P1
EOF
git add . && git commit -qm "initial main: INFRA-9001 at P1"

# PR branch forks here — merge-base priority is P1.
git checkout -q -b feature

# Main later demotes the gap to P3.
git checkout -q main
cat > docs/gaps/INFRA-9001.yaml <<'EOF'
- id: INFRA-9001
  domain: INFRA
  title: "test gap"
  status: open
  priority: P3
EOF
git add . && git commit -qm "main: demote INFRA-9001 P1 -> P3"

BASE_SHA=$(git merge-base feature main)
BASE_PRIO=$(gap_priority_at "$BASE_SHA" "INFRA-9001")
CUR_PRIO=$(gap_priority_at "main" "INFRA-9001")

echo "Test 1: demotion detected across merge-base -> main"
if [[ "$BASE_PRIO" == "P1" && "$CUR_PRIO" == "P3" ]] && is_demoted "$BASE_PRIO" "$CUR_PRIO"; then
    echo "[PASS] P1 -> P3 detected as a demotion"
else
    echo "[FAIL] expected demotion P1->P3, got base='$BASE_PRIO' cur='$CUR_PRIO'"
    exit 1
fi

echo ""
echo "Test 2: promotion (P3 -> P0) is NOT flagged as a demotion"
if is_demoted "P3" "P0"; then
    echo "[FAIL] P3 -> P0 (promotion) incorrectly flagged as demotion"
    exit 1
else
    echo "[PASS] promotion correctly excluded"
fi

echo ""
echo "Test 3: unchanged priority is NOT a demotion"
if is_demoted "P1" "P1"; then
    echo "[FAIL] unchanged priority incorrectly flagged as demotion"
    exit 1
else
    echo "[PASS] unchanged priority correctly excluded"
fi

echo ""
echo "Test 4: retirement gate — DIRTY + stale >= threshold => candidate (AC3, unconditional)"
if is_retirement_candidate "DIRTY" 8 7; then
    echo "[PASS] DIRTY + 8d >= 7d threshold retires"
else
    echo "[FAIL] expected retirement candidate"
    exit 1
fi

echo ""
echo "Test 5: retirement gate — DIRTY but not yet stale => not a candidate"
if is_retirement_candidate "DIRTY" 3 7; then
    echo "[FAIL] DIRTY + 3d < 7d threshold should NOT retire yet"
    exit 1
else
    echo "[PASS] not-yet-stale correctly excluded"
fi

echo ""
echo "Test 6: retirement gate — stale but not DIRTY (e.g. BEHIND) => not a candidate"
if is_retirement_candidate "BEHIND" 30 7; then
    echo "[FAIL] BEHIND (rebase-recoverable) should NOT retire"
    exit 1
else
    echo "[PASS] non-conflicting mergeStateStatus correctly excluded"
fi

echo ""
echo "[OK] all 6 INFRA-3803 stale+conflicting retirement cases passed"
