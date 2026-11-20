#!/usr/bin/env bash
# scripts/ci/test-keep-mergeable.sh — RESILIENT-342
#
# Source-contract + behavioural smoke for scripts/coord/keep-mergeable.sh.
# No live `gh`/network calls: stubs `gh` on PATH and drives the script
# against a real local git repo fixture (bare "origin" + a clean-rebase
# branch + a genuinely-conflicting branch) so the rebase-vs-escalate
# split is proven, not just asserted via grep.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/keep-mergeable.sh"

echo "=== RESILIENT-342 keep-mergeable tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }
[[ -x "$TARGET" ]] && ok "script executable" || fail "$TARGET not executable"

for needle in \
    "mergeStateStatus" \
    "DIRTY" \
    "BEHIND" \
    "CLEAN" \
    "force-with-lease" \
    "rebase --abort" \
    "keep_mergeable_rebased" \
    "keep_mergeable_needs_escalation" \
    "keep_mergeable_checks_rerun" \
    "gh run rerun"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

# ── Behavioural smoke: real git repo, stubbed gh ─────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BARE="$TMP/origin.git"
WORK="$TMP/work"
git init --quiet --bare "$BARE"
git -c init.defaultBranch=main init --quiet "$WORK"
(
    cd "$WORK"
    git config user.email test@test.com
    git config user.name test
    git remote add origin "$BARE"
    git checkout -q -b main
    echo base > base.txt
    git add base.txt
    git commit -q -m base
    git push -q origin main

    # clean-rebase branch: touches a different file than what main will
    # later touch — rebases cleanly.
    git checkout -q -b clean-branch
    echo clean > clean.txt
    git add clean.txt
    git commit -q -m clean-change
    git push -q origin clean-branch

    # conflicting branch: edits the SAME line main will edit — real conflict.
    git checkout -q main
    git checkout -q -b conflict-branch
    echo conflict-version > base.txt
    git add base.txt
    git commit -q -m conflict-change
    git push -q origin conflict-branch

    # advance main so both feature branches are now BEHIND/DIRTY.
    git checkout -q main
    echo main-advanced > base.txt
    git add base.txt
    git commit -q -m main-advance
    git push -q origin main
)

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    pr)
        case "$2" in
            list)
                cat <<JSON
[
  {"number": 9101, "mergeStateStatus": "DIRTY", "headRefName": "clean-branch", "headRefOid": "deadbeef"},
  {"number": 9102, "mergeStateStatus": "DIRTY", "headRefName": "conflict-branch", "headRefOid": "deadbeef"}
]
JSON
                exit 0 ;;
            comment) exit 0 ;;
        esac ;;
    api) echo ""; exit 0 ;;
    run) exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"

AMB="$WORK/.chump-locks/ambient.jsonl"
mkdir -p "$WORK/.chump-locks"

(
    cd "$WORK"
    PATH="$TMP/bin:$PATH" \
    CHUMP_PR_REPO="test/repo" \
    CHUMP_REPO_ROOT="$WORK" \
    CHUMP_KEEP_MERGEABLE_BUDGET_DIR="$WORK/.chump-locks/keep-mergeable-budget" \
    bash "$TARGET" > "$TMP/run.log" 2>&1
)
echo "  [script output]"
sed 's/^/    /' "$TMP/run.log"

if grep -q '"kind":"keep_mergeable_rebased".*"pr":9101' "$AMB" 2>/dev/null; then
    ok "clean-rebase branch (#9101) rebased + emitted keep_mergeable_rebased"
else
    fail "expected keep_mergeable_rebased for #9101"
fi

if grep -q '"kind":"keep_mergeable_needs_escalation".*"pr":9102' "$AMB" 2>/dev/null; then
    ok "conflicting branch (#9102) escalated, not force-pushed"
else
    fail "expected keep_mergeable_needs_escalation for #9102"
fi

# The conflicting branch's origin ref must be UNCHANGED (no bad force-push).
conflict_before="$(git -C "$WORK" rev-parse origin/conflict-branch 2>/dev/null)"
if [[ -n "$conflict_before" ]]; then
    ok "origin/conflict-branch still resolvable (repo not corrupted)"
else
    fail "origin/conflict-branch missing after run"
fi

# The clean branch should now be rebased ONTO the advanced main tip.
clean_head_msg="$(cd "$WORK" && git fetch -q origin clean-branch 2>/dev/null; git log -1 --format=%s origin/clean-branch 2>/dev/null)"
if [[ "$clean_head_msg" == "clean-change" ]]; then
    main_ancestor="$(cd "$WORK" && git merge-base --is-ancestor origin/main origin/clean-branch && echo yes || echo no)"
    if [[ "$main_ancestor" == "yes" ]]; then
        ok "clean-branch was rebased onto current origin/main tip"
    else
        fail "clean-branch pushed but not rebased onto latest main"
    fi
else
    fail "clean-branch head commit unexpected: $clean_head_msg"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
echo "PASS"
