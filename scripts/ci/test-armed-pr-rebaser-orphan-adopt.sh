#!/usr/bin/env bash
# scripts/ci/test-armed-pr-rebaser-orphan-adopt.sh — RESILIENT-357
#
# A DIRTY, unarmed PR has no owner: armed-pr-rebaser.sh only rebases ARMED
# PRs, and auto-merge-rearm-daemon.sh only re-arms CLEAN PRs — so a
# conflict-rotted, unarmed, otherwise-green PR fell between both and sat
# forever (#4012, #4033/4036/4037/4040/4041).
#
# Reproduces the fix: armed-pr-rebaser.sh must ALSO adopt DIRTY/BEHIND PRs
# that are unarmed but blocked ONLY by the conflict — fix-class
# (pr:parallel-safe label) with zero failing checks. It rebases the branch
# and, on a clean rebase, arms auto-merge (gh pr merge --auto --squash) so
# the lander merges it hands-off.
#
# Two scenarios:
#   1. Positive — DIRTY, unarmed, pr:parallel-safe label, no failing checks:
#      must be rebased AND armed.
#   2. Negative — DIRTY, unarmed, NO pr:parallel-safe label: must be left
#      alone (no rebase/push, no gh pr merge call) — real conflicts on
#      non-fix-class PRs still need a human / conflict-resolver.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/armed-pr-rebaser.sh"

echo "=== RESILIENT-357 armed-pr-rebaser orphan-adopt tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }

# ── Source-contract: adopt logic must exist and gate on label + no failures ──
if grep -q "adopt = (not armed) and ('pr:parallel-safe' in labels) and (not failing)" "$TARGET"; then
    ok "contract: adopt gated on unarmed + pr:parallel-safe label + zero failing checks"
else
    fail "contract: adopt gate missing or changed — orphan-adopt regression"
fi

build_fixture() {
    local tmp="$1" pr_content="$2"
    local origin="$tmp/origin.git"
    git init -q --bare -b main "$origin"

    local seed="$tmp/seed"
    git init -q -b main "$seed"
    git -C "$seed" config user.email "test@example.com"
    git -C "$seed" config user.name "Test Seed"
    echo "root" > "$seed/README.md"
    git -C "$seed" add README.md
    git -C "$seed" commit -q -m "init"
    git -C "$seed" remote add origin "$origin"
    git -C "$seed" push -q origin main

    # PR branch — a fix-class commit that does NOT touch README.md, so a
    # rebase onto main's advance is always conflict-free.
    git -C "$seed" checkout -q -b pr-branch
    echo "$pr_content" > "$seed/fix.txt"
    git -C "$seed" add fix.txt
    git -C "$seed" commit -q -m "fix: orphaned change"
    git -C "$seed" push -q origin pr-branch

    # main advances so the PR is DIRTY/behind.
    git -C "$seed" checkout -q main
    echo "advance" >> "$seed/README.md"
    git -C "$seed" add README.md
    git -C "$seed" commit -q -m "advance main"
    git -C "$seed" push -q origin main
}

run_scenario() {
    local label="$1" pr_json="$2"
    local tmp
    tmp="$(mktemp -d -t armed-pr-rebaser-orphan-XXXXXX)"

    build_fixture "$tmp" "orphan-fix-$label"

    local root="$tmp/root"
    git clone -q "$tmp/origin.git" "$root"
    git -C "$root" config user.email "test@example.com"
    git -C "$root" config user.name "Test Root"
    mkdir -p "$root/.chump-locks"

    mkdir -p "$tmp/bin"
    local merge_log="$tmp/merge-calls.log"
    cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
    pr)
        case "\$2" in
            list)
                cat <<'JSON'
$pr_json
JSON
                ;;
            merge)
                echo "\$@" >> "$merge_log"
                ;;
        esac
        ;;
esac
exit 0
EOF
    chmod +x "$tmp/bin/gh"

    local out
    out="$(PATH="$tmp/bin:$PATH" CHUMP_REPO_ROOT="$root" CHUMP_PR_REPO="test/repo" bash "$TARGET" 2>&1)"

    echo "$tmp|$out|$merge_log"
}

# ── Scenario 1: positive — adopt, rebase, and arm ──────────────────────────
POS_JSON='[
  {"number": 5001, "mergeStateStatus": "DIRTY", "autoMergeRequest": null, "headRefName": "pr-branch",
   "labels": [{"name": "pr:parallel-safe"}], "statusCheckRollup": []}
]'
result="$(run_scenario pos "$POS_JSON")"
tmp1="${result%%|*}"; rest="${result#*|}"; out1="${rest%|*}"; merge_log1="${rest##*|}"

if echo "$out1" | grep -q "rebased clean + pushed"; then
    ok "positive: DIRTY-unarmed fix-class PR was rebased"
else
    fail "positive: expected clean rebase+push; got: $out1"
fi
if echo "$out1" | grep -q "adopted DIRTY-unarmed fix-class orphan"; then
    ok "positive: orphan-adopt path logged"
else
    fail "positive: orphan-adopt log line missing; got: $out1"
fi
if [[ -f "$merge_log1" ]] && grep -q "5001" "$merge_log1" && grep -q -- "--auto" "$merge_log1"; then
    ok "positive: gh pr merge --auto --squash was called to arm the PR"
else
    fail "positive: gh pr merge was NOT called — orphan left unarmed"
fi
README_ON_BRANCH="$(git -C "$tmp1/origin.git" show "refs/heads/pr-branch:README.md" 2>/dev/null || true)"
if echo "$README_ON_BRANCH" | grep -q "advance"; then
    ok "positive: rebase actually picked up main's advance"
else
    fail "positive: pr-branch missing main's advance — not a real rebase"
fi
rm -rf "$tmp1"

# ── Scenario 2: negative — no pr:parallel-safe label, must be left alone ──
NEG_JSON='[
  {"number": 5002, "mergeStateStatus": "DIRTY", "autoMergeRequest": null, "headRefName": "pr-branch",
   "labels": [], "statusCheckRollup": []}
]'
result="$(run_scenario neg "$NEG_JSON")"
tmp2="${result%%|*}"; rest="${result#*|}"; out2="${rest%|*}"; merge_log2="${rest##*|}"

if [[ -z "$out2" ]]; then
    ok "negative: non-fix-class DIRTY-unarmed PR produced no rebaser output (left alone)"
else
    fail "negative: expected no action on non-fix-class PR; got: $out2"
fi
if [[ ! -s "$merge_log2" ]]; then
    ok "negative: gh pr merge was NOT called for non-fix-class orphan"
else
    fail "negative: gh pr merge was unexpectedly called for non-fix-class orphan"
fi
rm -rf "$tmp2"

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf '  - %s\n' "${FAILS[@]}"
    exit 1
fi
exit 0
