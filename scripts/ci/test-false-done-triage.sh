#!/usr/bin/env bash
# CREDIBLE-279 AC2: prove scripts/ops/false-done-triage.py produces the three
# verdicts it promises — FOUND_ELSEWHERE, NOT_FOUND, AMBIGUOUS — against a
# throwaway git repo fixture, so the test never depends on the real chump
# repo's history (fast, deterministic, no network).
set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

cd "$FIXTURE"
git init -q
git config user.email "test@example.com"
git config user.name "test"

# Commit 1: creates foo.rs (this PR "credited" but ships no real fix later).
mkdir -p src
echo "fn main() {}" > src/foo.rs
git add src/foo.rs
git commit -q -m "feat(TEST-1): add foo skeleton (#1001)"

# Commit 2: a REAL later fix to foo.rs, under a different PR.
echo "fn main() { println!(\"fixed\"); }" > src/foo.rs
git add src/foo.rs
git commit -q -m "fix(TEST-2): foo actually works now (#1002)"

# Commit 3: bar.rs created and NEVER touched again (single-commit path).
echo "fn bar() {}" > src/bar.rs
git add src/bar.rs
git commit -q -m "feat(TEST-3): add bar skeleton (#1003)"

# Commit 4 + 5: baz.rs touched by two different unrelated PRs (ambiguous).
echo "fn baz() {}" > src/baz.rs
git add src/baz.rs
git commit -q -m "feat(TEST-4): add baz skeleton (#1004)"
echo "fn baz() { /* v2 */ }" > src/baz.rs
git add src/baz.rs
git commit -q -m "chore(TEST-5): baz cleanup (#1005)"

python3 - "$REPO_ROOT" <<'PYEOF'
import sys, importlib.util
sys.path.insert(0, f"{sys.argv[1]}/scripts/ops")
spec = importlib.util.spec_from_file_location(
    "false_done_triage", f"{sys.argv[1]}/scripts/ops/false-done-triage.py"
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

failures = []
def check(name, cond):
    print(f"[{'PASS' if cond else 'FAIL'}] {name}")
    if not cond:
        failures.append(name)

# FOUND_ELSEWHERE: src/foo.rs has 2 commits; candidate excluding credited PR
# 1001 must be 1002 (the real later fix), not the creation commit.
c = m.commits_touching("src/foo.rs")
check("foo.rs has 2 commits in history", len(c) == 2)
subjects = [s for _, s in c]
check("foo.rs newest-first order (fix before creation)",
      "TEST-2" in subjects[0] and "TEST-1" in subjects[1])

# NOT_FOUND shape: bar.rs has exactly 1 commit -> triage_one's "len(history)<2"
# rule must exclude it as a candidate source entirely.
c2 = m.commits_touching("src/bar.rs")
check("bar.rs has exactly 1 commit (single-touch, excluded as weak signal)", len(c2) == 1)

# AMBIGUOUS shape: baz.rs has 2 distinct PRs, both non-credited when credited
# PR is something else entirely (e.g. 9999).
c3 = m.commits_touching("src/baz.rs")
prs = sorted({m.PR_IN_SUBJECT.search(s).group(1) for _, s in c3 if m.PR_IN_SUBJECT.search(s)})
check("baz.rs surfaces 2 distinct real PR numbers", prs == ["1004", "1005"])

if failures:
    print(f"\n{len(failures)} check(s) failed: {failures}")
    sys.exit(1)
print("\nall checks passed")
PYEOF
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "false-done-triage commits_touching + candidate shape fixture"
else
    fail "false-done-triage commits_touching + candidate shape fixture"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
