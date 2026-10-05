#!/usr/bin/env bash
# INFRA-2285: smoke test for scripts/coord/rescue-stale-pr.sh
#
# Proves the pure decision functions (conflict triviality classifier, hook
# gate-detector) do the right thing without touching a real PR, then proves
# --dry-run prints a plan (no commit/push) for a synthetic stale-PR fixture
# with a trivial registry-only conflict.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../coord/rescue-stale-pr.sh
RESCUE_STALE_PR_LIB_ONLY=1 source "${REPO_ROOT}/scripts/coord/rescue-stale-pr.sh"

PASS=0
FAIL=0

expect_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS + 1)); echo "  ok   ${label}"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL ${label} — got '${got}' want '${want}'" >&2
    fi
}

echo "=== INFRA-2285 rescue-stale-pr.sh smoke test ==="

# ── gate detector ────────────────────────────────────────────────────────
tmp_hook_out="$(mktemp)"
trap 'rm -f "$tmp_hook_out"' EXIT

cat > "$tmp_hook_out" <<'EOF'
[pre-push] BLOCKED (INFRA-1441): CHUMP_BYPASS_BOT_MERGE=1 requires audit trailer.
[pre-push]   Bot-Merge-Bypass: <one-sentence reason>
[pre-commit] event-registry: unregistered kind. Bypass:
        CHUMP_EVENT_REGISTRY_CHECK=0 git commit ...
EOF

got="$(rescue_gate_from_hook_output "$(cat "$tmp_hook_out")")"
expect_eq "gate detector finds Bot-Merge-Bypass" \
    "$(grep -c 'Bot-Merge-Bypass|CHUMP_BYPASS_BOT_MERGE=1' <<<"$got")" "1"
expect_eq "gate detector finds Event-Registry-Bypass" \
    "$(grep -c 'Event-Registry-Bypass|CHUMP_EVENT_REGISTRY_CHECK=0' <<<"$got")" "1"
expect_eq "gate detector does not false-positive Test-Gate-Bypass" \
    "$(grep -c 'Test-Gate-Bypass' <<<"$got")" "0"

# Fixture conflict markers are built at runtime (not written as a literal
# 7-char run in this file's source) — a literal "<<<<<<< " line in a
# brand-new file trips the pre-push merge-tree DIRTY-conflict false-positive
# scan (scripts/git-hooks/pre-push guard 0e), since the whole file appears
# as "+"-added lines on first push and the scan can't tell fixture data
# from a real conflict.
ours_marker="$(printf '<%.0s' 1 2 3 4 5 6 7) HEAD"
theirs_marker="$(printf '>%.0s' 1 2 3 4 5 6 7) origin/main"
sep_marker="$(printf '=%.0s' 1 2 3 4 5 6 7)"

# ── conflict triviality classifier ──────────────────────────────────────
trivial_fixture="$(mktemp)"
printf '%s\n' \
    "line one" \
    "line two" \
    "$ours_marker" \
    "- kind: branch_a_event" \
    "$sep_marker" \
    "$theirs_marker" \
    "line three" \
    > "$trivial_fixture"
expect_eq "both-add disjoint-lines conflict classified trivial" \
    "$(rescue_classify_conflict_hunks "$trivial_fixture")" "trivial"
rm -f "$trivial_fixture"

nontrivial_fixture="$(mktemp)"
printf '%s\n' \
    "line one" \
    "$ours_marker" \
    "value: 5" \
    "$sep_marker" \
    "value: 9" \
    "$theirs_marker" \
    "line three" \
    > "$nontrivial_fixture"
expect_eq "same-line edit conflict classified nontrivial" \
    "$(rescue_classify_conflict_hunks "$nontrivial_fixture")" "nontrivial"
rm -f "$nontrivial_fixture"

# ── --dry-run plan output (no commit/push side effects) ─────────────────
plan_out="$(bash "${REPO_ROOT}/scripts/coord/rescue-stale-pr.sh" 9999 --dry-run 2>&1)"
expect_eq "dry-run mentions Bot-Merge-Bypass trailer" \
    "$(grep -c 'Bot-Merge-Bypass' <<<"$plan_out")" "1"
expect_eq "dry-run mentions force-with-lease / auto-merge arm" \
    "$(grep -c 'auto-merge' <<<"$plan_out")" "1"
expect_eq "dry-run mentions stale_pr_rescued ambient emit" \
    "$(grep -c 'stale_pr_rescued' <<<"$plan_out")" "1"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
