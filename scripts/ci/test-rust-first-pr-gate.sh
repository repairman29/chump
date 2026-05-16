#!/usr/bin/env bash
# test-rust-first-pr-gate.sh — INFRA-1447
#
# Verifies the CI-side Rust-first gate. The pre-commit hook only runs
# locally and squash-merge strips per-commit trailers, so the in-PR
# `audit` job re-runs the gate against the FULL PR diff with the PR body
# as the trailer source.
#
# Mechanism: in CI we do `git reset --soft $(merge-base origin/main HEAD)`
# which makes every commit in the PR appear as a single staged-add diff,
# then write the PR body to COMMIT_EDITMSG and invoke the existing
# scripts/git-hooks/pre-commit-rust-first.sh unchanged.
#
# This smoke test verifies that mechanism end-to-end:
#   1. PR adds a state-mutating .sh in scripts/coord/, PR body has no
#      trailer → gate FAILs (rc=1) with the expected diagnostic
#   2. Same PR, PR body has 'Rust-First-Bypass: <reason>' → gate PASSes
#      (rc=0) and emits kind=rust_first_bypass_used to ambient
#   3. PR adds only docs/*.md (no shell) → gate PASSes silently
#   4. PR modifies an existing scripts/coord/*.sh (no new file) → PASSes
#
# Strategy: build a synthetic git repo with a "main" commit + a "PR"
# commit, soft-reset, run the gate, assert.
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-rust-first.sh"

echo "=== INFRA-1447 Rust-first PR-side (CI) gate tests ==="
[[ -x "$GATE" ]] || { fail "gate missing at $GATE"; echo "FAIL"; exit 1; }
ok "gate present + executable"

# Build a synthetic repo simulating "main" + "PR" history.
# After setup the working tree is at the PR tip; the test then does a
# soft-reset against the merge-base, just like the CI step will.
mk_pr_repo() {
    local d
    d="$(mktemp -d -t rust-first-pr-gate.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name test
        mkdir -p .git/info
        # "main" baseline
        echo seed > README.md
        git add README.md
        git -c user.email=test@test.local -c user.name=test \
            commit -q -m "main: seed"
    )
    printf '%s\n' "$d"
}

# Apply edits to the repo, commit as the "PR" branch, then soft-reset
# back to main and run the gate with the given PR body.
run_pr_gate() {
    local repo="$1" pr_body="$2"
    (
        cd "$repo"
        # All currently-untracked / modified content represents the PR.
        git add -A
        if ! git diff --cached --quiet; then
            git -c user.email=test@test.local -c user.name=test \
                commit -q -m "pr: simulated changes"
        fi
        # Now do what the CI step does: soft-reset to base, write PR body,
        # run the gate. The merge-base of HEAD against itself is HEAD,
        # so we reset to HEAD~1 (the "main" commit).
        local base
        base="$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)"
        git reset --soft "$base" >/dev/null 2>&1 || true
        # Write the PR body into COMMIT_EDITMSG (the gate's trailer source).
        printf '%s\n' "$pr_body" > "$(git rev-parse --git-common-dir)/COMMIT_EDITMSG"
        # Invoke the gate.
        bash "$GATE" 2>&1
    )
}

# ── Test 1: state-mutator add + no PR-body trailer → BLOCK ───────────────────
echo "--- Test 1: state-mutator + no trailer → BLOCK ---"
R1="$(mk_pr_repo)"
mkdir -p "$R1/scripts/coord"
cat > "$R1/scripts/coord/state-mutator.sh" <<'SH'
#!/bin/sh
echo "{\"kind\":\"x\"}" >> .chump-locks/ambient.jsonl
SH
out="$(run_pr_gate "$R1" "feat: add coord script")"; rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "Rust-first gate blocked"; then
    ok "state-mutator without trailer is BLOCKED (rc=$rc)"
else
    fail "expected BLOCK; rc=$rc out=$out"
fi
rm -rf "$R1"

# ── Test 2: state-mutator add + PR-body has trailer → PASS + emit ────────────
echo "--- Test 2: state-mutator + trailer in PR body → PASS ---"
R2="$(mk_pr_repo)"
mkdir -p "$R2/scripts/coord" "$R2/.chump-locks"
cat > "$R2/scripts/coord/state-mutator.sh" <<'SH'
#!/bin/sh
echo "{\"kind\":\"x\"}" >> .chump-locks/ambient.jsonl
SH
BODY="## Summary

Adds coord/state-mutator.sh for X.

Rust-First-Bypass: thin 5-line wrapper around gh+jq; full port tracked as INFRA-NEW"
out="$(run_pr_gate "$R2" "$BODY")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "state-mutator WITH trailer in PR body: PASSes (rc=0)"
else
    fail "expected PASS with trailer; rc=$rc out=$out"
fi
if [[ -f "$R2/.chump-locks/ambient.jsonl" ]] \
    && grep -q '"kind":"rust_first_bypass_used"' "$R2/.chump-locks/ambient.jsonl"; then
    ok "PR-body trailer emits rust_first_bypass_used to ambient"
else
    fail "expected ambient emit; not found"
fi
rm -rf "$R2"

# ── Test 3: docs-only PR (no shell) → PASS silently ──────────────────────────
echo "--- Test 3: docs-only PR → silent PASS ---"
R3="$(mk_pr_repo)"
mkdir -p "$R3/docs"
echo "# new doc" > "$R3/docs/new.md"
out="$(run_pr_gate "$R3" "docs: add new note")"; rc=$?
if [[ $rc -eq 0 ]] && [[ -z "${out// }" ]]; then
    ok "docs-only PR: silent PASS"
else
    fail "expected silent pass; rc=$rc out=$out"
fi
rm -rf "$R3"

# ── Test 4: modify existing shell (no add) → PASS ────────────────────────────
echo "--- Test 4: modify-only existing shell → PASS ---"
R4="$(mk_pr_repo)"
mkdir -p "$R4/scripts/coord"
echo '#!/bin/sh' > "$R4/scripts/coord/existing.sh"
# Stage the file on "main" first so the PR is a modify, not an add.
(cd "$R4" && git add scripts/coord/existing.sh \
    && git -c user.email=test@test.local -c user.name=test \
        commit -q --amend --no-edit)
echo "# modified" >> "$R4/scripts/coord/existing.sh"
out="$(run_pr_gate "$R4" "fix: tweak existing")"; rc=$?
if [[ $rc -eq 0 ]]; then
    ok "modify-only existing shell: PASS"
else
    fail "expected PASS; rc=$rc out=$out"
fi
rm -rf "$R4"

# ── Test 5: contract assertion — gate detects soft-reset staged diff ─────────
# This is the load-bearing claim: after `git reset --soft <base>`, the gate's
# `git diff --cached --diff-filter=A` returns the PR-added files. If a future
# git version changes this behavior the CI gate becomes a no-op silently.
echo "--- Test 5: contract — soft-reset surfaces adds in --cached --diff-filter=A ---"
R5="$(mk_pr_repo)"
mkdir -p "$R5/scripts/coord"
echo '#!/bin/sh' > "$R5/scripts/coord/new.sh"
(cd "$R5" && git add -A \
    && git -c user.email=test@test.local -c user.name=test \
        commit -q -m "pr: add new.sh" \
    && git reset --soft HEAD~1 >/dev/null)
got="$(cd "$R5" && git diff --cached --name-only --diff-filter=A)"
if [[ "$got" == "scripts/coord/new.sh" ]]; then
    ok "soft-reset exposes adds via --cached --diff-filter=A"
else
    fail "soft-reset contract broken (got: '$got')"
fi
rm -rf "$R5"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
