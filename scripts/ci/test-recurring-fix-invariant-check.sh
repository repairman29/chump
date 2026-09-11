#!/usr/bin/env bash
# test-recurring-fix-invariant-check.sh — RESILIENT-1107
#
# Exercises the meta-rule gate: no fix for a RECURRING failure class ships
# without its invariant-check registered alongside it
# (scripts/git-hooks/pre-commit-recurring-fix-invariant.sh).
#
#   (a) non-recurring commit, no registry touch   → ACCEPT (gate doesn't fire)
#   (b) "recurring" commit, no registry touch     → REJECT
#   (c) "recurring" commit + registry touched     → ACCEPT
#   (d) "recurring" commit + bypass trailer        → ACCEPT (bypass logged)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-recurring-fix-invariant.sh"

echo "=== RESILIENT-1107 recurring-fix invariant meta-rule gate tests ==="
[[ -x "$GATE" ]] || { fail "gate not executable at $GATE"; echo "FAIL"; exit 1; }
ok "gate present + executable"

mk_repo() {
    local d
    d="$(mktemp -d -t recurring-fix-invariant.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name test
        git commit --allow-empty -q -m "init"
    )
    printf '%s\n' "$d"
}

run_gate() {
    local repo="$1" msg="$2"
    (
        cd "$repo"
        printf '%s\n' "$msg" > .git/COMMIT_EDITMSG
        bash "$GATE" 2>&1
    )
}

# --- (a) non-recurring commit, no registry touch → ACCEPT --------------
REPO_A="$(mk_repo)"
(
    cd "$REPO_A"
    echo "hello" > foo.txt
    git add foo.txt
)
if OUT_A="$(run_gate "$REPO_A" "INFRA-1: add a quick helper script")"; then
    ok "(a) non-recurring commit passes untouched"
else
    fail "(a) non-recurring commit unexpectedly blocked: $OUT_A"
fi
rm -rf "$REPO_A"

# --- (b) recurring commit, no registry touch → REJECT ------------------
REPO_B="$(mk_repo)"
(
    cd "$REPO_B"
    echo "hello" > foo.txt
    git add foo.txt
)
if OUT_B="$(run_gate "$REPO_B" "RESILIENT-999: fix a recurring auth-storm crash")"; then
    fail "(b) recurring commit with no invariant registered was NOT blocked (regression!)"
else
    if echo "$OUT_B" | grep -q "RESILIENT-1107"; then
        ok "(b) recurring commit without invariant-registry touch is blocked"
    else
        fail "(b) blocked but without expected RESILIENT-1107 message: $OUT_B"
    fi
fi
rm -rf "$REPO_B"

# --- (c) recurring commit + registry touched → ACCEPT -------------------
REPO_C="$(mk_repo)"
(
    cd "$REPO_C"
    mkdir -p scripts/ops
    echo "id|check|comparator|threshold|owner|severity" > scripts/ops/invariant-registry.txt
    echo "foo-floor|scripts/ops/invariant-checks/foo.sh|gte|1|jeff|page" >> scripts/ops/invariant-registry.txt
    git add scripts/ops/invariant-registry.txt
)
if OUT_C="$(run_gate "$REPO_C" "RESILIENT-999: fix a recurring auth-storm crash")"; then
    ok "(c) recurring commit that registers an invariant passes"
else
    fail "(c) recurring commit with registry touch unexpectedly blocked: $OUT_C"
fi
rm -rf "$REPO_C"

# --- (d) recurring commit + bypass trailer → ACCEPT ----------------------
REPO_D="$(mk_repo)"
(
    cd "$REPO_D"
    echo "hello" > foo.txt
    git add foo.txt
    mkdir -p .chump-locks
)
if OUT_D="$(run_gate "$REPO_D" "RESILIENT-999: fix a recurring auth-storm crash

Invariant-Check-Bypass: predates the registry landing, tracked in RESILIENT-1106")"; then
    ok "(d) recurring commit with bypass trailer passes"
else
    fail "(d) recurring commit with bypass trailer unexpectedly blocked: $OUT_D"
fi
rm -rf "$REPO_D"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo "FAILURES:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    echo "FAIL"
    exit 1
fi
echo "PASS"
exit 0
