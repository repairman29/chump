#!/usr/bin/env bash
# scripts/ci/test-bot-merge-conflict-integration.sh — INFRA-3767
#
# Runtime integration test: simulate a real git merge-conflict and verify
# conflict-resolver-agent.sh (INFRA-1488) is invoked WITHOUT requiring the
# caller to set CHUMP_CONFLICT_RESOLVER_ENABLED=1 (AC #2), and only follows
# through unattended for scenarios it has a confidence pattern for (AC #3).
#
# bot-merge.sh's own call site is covered by the static contract test
# (test-bot-merge-conflict-wiring.sh); this test exercises the actual
# conflict-resolver-agent.sh runtime path with a real conflicted worktree,
# which is what AC #4 ("simulate merge-conflict, verify resolver agent is
# called") asks for.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/conflict-resolver-agent.sh"

[[ -x "$SCRIPT" ]] || { fail "missing $SCRIPT"; echo "FAIL"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Mock `chump` binary on PATH so the agent's dispatch call is observable
# without hitting a real gap/lease.
MOCKBIN="$TMP/mockbin"
mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/chump" <<'EOF'
#!/usr/bin/env bash
# Simulate a successful conflict-resolving agent run: resolve every
# conflicted file in the repo (strip markers, keep "ours") and exit 0.
for f in $(git diff --name-only --diff-filter=U 2>/dev/null); do
    sed -n '/^<<<<<<</,/^=======/{/^<<<<<<</d;/^=======/d;p}' "$f" > "$f.resolved" 2>/dev/null
    mv "$f.resolved" "$f"
done
exit 0
EOF
chmod +x "$MOCKBIN/chump"

setup_repo() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir" && cd "$dir"
    git init --quiet
    git config user.email t@e && git config user.name t
}

make_conflict() {
    # Args: file_name ours_line theirs_line
    local f="$1" ours="$2" theirs="$3"
    echo "base" > "$f"
    git add "$f" && git commit -q -m base
    git checkout -q -b branch-a
    echo "$ours" > "$f"
    git commit -q -am ours
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    git checkout -q -b branch-b
    echo "$theirs" > "$f"
    git commit -q -am theirs
}

# ── Scenario 1: high-confidence (small, textual, allowlisted extension) ──────
REPO1="$TMP/repo-confident"
setup_repo "$REPO1"
make_conflict "notes.md" "ours-line-unique-string-alpha" "theirs-line-unique-string-beta"
git merge branch-a --no-edit -q 2>/dev/null || true

if git diff --name-only --diff-filter=U | grep -q "notes.md"; then
    ok "scenario 1: synthetic conflict created on notes.md"
else
    fail "scenario 1: conflict setup failed"
fi

OUT="$(PATH="$MOCKBIN:$PATH" CHUMP_GAP_ID=INFRA-TEST unset CHUMP_CONFLICT_RESOLVER_ENABLED 2>/dev/null; PATH="$MOCKBIN:$PATH" CHUMP_GAP_ID=INFRA-TEST bash "$SCRIPT" 2>&1)"
if echo "$OUT" | grep -q "conflicted file(s)"; then
    ok "AC#2: resolver invoked with no CHUMP_CONFLICT_RESOLVER_ENABLED set (no opt-in required)"
else
    fail "AC#2: resolver did not run unattended without an explicit opt-in flag (out: ${OUT:0:200})"
fi
if echo "$OUT" | grep -qi "low-confidence"; then
    fail "AC#3: high-confidence scenario was incorrectly treated as low-confidence"
else
    ok "AC#3: high-confidence (.md, small) scenario passed the confidence gate"
fi
if [[ -f "$REPO1/.chump-locks/ambient.jsonl" ]] && grep -q '"kind":"conflict_resolve_start"' "$REPO1/.chump-locks/ambient.jsonl"; then
    ok "AC#4: conflict_resolve_start emitted — resolver agent was called"
else
    fail "AC#4: conflict_resolve_start not found in ambient log"
fi
git merge --abort 2>/dev/null || true

# ── Scenario 2: low-confidence (extension not in textual allowlist) ──────────
REPO2="$TMP/repo-low-confidence"
setup_repo "$REPO2"
make_conflict "artifact.bin" "ours-payload-unique-string-alpha" "theirs-payload-unique-string-beta"
git merge branch-a --no-edit -q 2>/dev/null || true

OUT2="$(PATH="$MOCKBIN:$PATH" CHUMP_GAP_ID=INFRA-TEST bash "$SCRIPT" 2>&1)"
if echo "$OUT2" | grep -qi "low-confidence"; then
    ok "AC#3: low-confidence extension (.bin) correctly skipped without operator override"
else
    fail "AC#3: low-confidence scenario was not detected (out: ${OUT2:0:200})"
fi
if [[ -f "$REPO2/.chump-locks/ambient.jsonl" ]] && grep -q '"reason":"low_confidence"' "$REPO2/.chump-locks/ambient.jsonl"; then
    ok "low_confidence skip reason logged to ambient"
else
    fail "low_confidence skip reason missing from ambient log"
fi

# ── Scenario 3: forced override runs even on a scenario that would otherwise skip
REPO3="$TMP/repo-forced"
setup_repo "$REPO3"
make_conflict "artifact.bin" "ours-payload-unique-string-alpha" "theirs-payload-unique-string-beta"
git merge branch-a --no-edit -q 2>/dev/null || true

OUT3="$(PATH="$MOCKBIN:$PATH" CHUMP_CONFLICT_RESOLVER_ENABLED=1 CHUMP_GAP_ID=INFRA-TEST bash "$SCRIPT" 2>&1)"
if echo "$OUT3" | grep -q "conflicted file(s)" && ! echo "$OUT3" | grep -qi "low-confidence"; then
    ok "CHUMP_CONFLICT_RESOLVER_ENABLED=1 forces the resolver past the confidence gate"
else
    fail "forced override did not bypass the confidence gate (out: ${OUT3:0:200})"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
