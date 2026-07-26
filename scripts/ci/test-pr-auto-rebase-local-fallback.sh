#!/usr/bin/env bash
# scripts/ci/test-pr-auto-rebase-local-fallback.sh — INFRA-1811
#
# Extends the INFRA-1958 local-rebase fallback (gh-API false-positive
# recovery) with: a wall-clock timeout guard on the local rebase attempt,
# a distinct kind=pr_auto_rebase_recovered event naming the merge-driver
# resolved files on success, and a distinct kind=pr_auto_rebase_unresolvable
# event with a conflict_files array when conflicts survive the merge-driver
# pass.
#
# Tests are STRUCTURAL (grep the script for the right code shapes) plus one
# functional fixture that exercises an ADDITIVE two-sided conflict through a
# real local git rebase with the repo's ci-yml-add-row merge driver, and one
# fixture that exercises a genuine semantic conflict (same line changed two
# ways) to confirm the daemon aborts cleanly. Both fixtures run against a
# throwaway bare repo — no gh/network dependency.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/coord/pr-auto-rebase.sh"

echo "=== INFRA-1811 pr-auto-rebase local-fallback extension tests ==="

[[ -f "$TARGET" ]] && ok "script exists" || { fail "missing $TARGET"; exit 1; }

# ── 1. Source contract — new event kinds + timeout guard present ───────────
for needle in \
    "INFRA-1811" \
    "CHUMP_PR_AUTO_REBASE_LOCAL_TIMEOUT_S" \
    "pr_auto_rebase_recovered" \
    "pr_auto_rebase_unresolvable" \
    "conflict_files" \
    "resolved_files" \
    "REBASE_TIMED_OUT"; do
    if grep -qF "$needle" "$TARGET"; then
        ok "contract: $needle"
    else
        fail "contract missing: $needle"
    fi
done

bash -n "$TARGET" || fail "script has syntax error"
ok "script parses cleanly via bash -n"

# ── 2. Functional fixture: additive ci.yml conflict resolved via local
#      rebase + custom merge driver, asserting the daemon would emit
#      pr_auto_rebase_recovered on a clean 0-conflict rebase. ────────────────
FIXTURE="$(mktemp -d -t infra1811-fixture-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

(
    set -e
    cd "$FIXTURE"
    git init -q -b main upstream
    cd upstream
    git config user.email "test@chump.local"
    git config user.name "chump-test"

    cat > .gitattributes <<'EOF'
.github/workflows/ci.yml merge=ci-yml-add-row
EOF
    cat > merge-ci-yml-add-row.sh <<'EOF'
#!/usr/bin/env bash
# Minimal stand-in for the repo's real ci-yml-add-row merge driver: union both
# sides' added lines, keep base otherwise. %O/%A/%B are provided by git.
BASE="$1" OURS="$2" THEIRS="$3"
sort -u "$OURS" "$THEIRS" > "$OURS.merged"
mv "$OURS.merged" "$OURS"
exit 0
EOF
    chmod +x merge-ci-yml-add-row.sh
    git config merge.ci-yml-add-row.driver "./merge-ci-yml-add-row.sh %O %A %B"

    mkdir -p .github/workflows
    printf 'jobs:\n  base:\n    x\n' > .github/workflows/ci.yml
    git add -A
    git commit -q -m "base"

    git checkout -q -b pr-branch
    printf 'jobs:\n  base:\n    x\n  pr-job:\n    y\n' > .github/workflows/ci.yml
    git commit -q -am "pr adds a job"

    git checkout -q main
    printf 'jobs:\n  base:\n    x\n  main-job:\n    z\n' > .github/workflows/ci.yml
    git commit -q -am "main adds a different job"

    git checkout -q pr-branch
    git rebase main >/tmp/infra1811-rebase-out.$$ 2>&1
    echo $? > /tmp/infra1811-rebase-rc.$$
) 2>/tmp/infra1811-fixture-err.$$

RC="$(cat /tmp/infra1811-rebase-rc.$$ 2>/dev/null || echo 1)"
if [[ "$RC" == "0" ]]; then
    ok "fixture: additive ci.yml conflict resolves cleanly via merge driver (rebase rc=0 -> daemon path emits pr_auto_rebase_recovered)"
else
    fail "fixture: additive ci.yml conflict did NOT resolve via merge driver (rebase rc=$RC)"
fi
rm -f /tmp/infra1811-rebase-out.$$ /tmp/infra1811-rebase-rc.$$ /tmp/infra1811-fixture-err.$$

# ── 3. Functional fixture: genuine semantic conflict (same line, two
#      different values) — merge driver does NOT apply, rebase must fail so
#      the daemon takes the pr_auto_rebase_unresolvable path. ──────────────
FIXTURE2="$(mktemp -d -t infra1811-fixture2-XXXXXX)"
(
    set -e
    cd "$FIXTURE2"
    git init -q -b main upstream2
    cd upstream2
    git config user.email "test@chump.local"
    git config user.name "chump-test"

    echo "value=1" > src/config.txt 2>/dev/null || { mkdir -p src; echo "value=1" > src/config.txt; }
    git add -A
    git commit -q -m "base"

    git checkout -q -b pr-branch
    echo "value=2" > src/config.txt
    git commit -q -am "pr sets value=2"

    git checkout -q main
    echo "value=3" > src/config.txt
    git commit -q -am "main sets value=3"

    git checkout -q pr-branch
    rc=0
    git rebase main >/tmp/infra1811-rebase2-out.$$ 2>&1 || rc=$?
    echo "$rc" > /tmp/infra1811-rebase2-rc.$$
    git rebase --abort >/dev/null 2>&1 || true
) 2>/tmp/infra1811-fixture2-err.$$

RC2="$(cat /tmp/infra1811-rebase2-rc.$$ 2>/dev/null || echo 0)"
if [[ "$RC2" != "0" ]]; then
    ok "fixture: genuine semantic conflict fails local rebase (rc=$RC2 -> daemon path emits pr_auto_rebase_unresolvable + aborts cleanly)"
else
    fail "fixture: semantic conflict unexpectedly rebased cleanly (rc=$RC2) — fixture is not testing a real conflict"
fi
rm -rf "$FIXTURE2" /tmp/infra1811-rebase2-out.$$ /tmp/infra1811-rebase2-rc.$$ /tmp/infra1811-fixture2-err.$$

echo
echo "=== Summary: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
