#!/usr/bin/env bash
# test-scope-check-subagent-enforce.sh — INFRA-337
#
# Verifies that the pre-commit out-of-scope guard (INFRA-189) defaults to
# ENFORCE for subagent-issued commits and remains in WARN for parent
# (operator-driven) commits.
#
# Acceptance criteria verified:
#   (1) A commit from a subagent session (session_id prefix `chump-anon-`
#       or `subagent-`) with files OUTSIDE the lease's declared `paths`
#       is BLOCKED (exit 1), no env override.
#   (2) A commit from a parent session (any other session_id) with the
#       same out-of-scope diff is ALLOWED with a WARN line on stderr.
#   (3) Operator override `CHUMP_SCOPE_CHECK=warn` downgrades a subagent
#       commit from block to warn (escape hatch preserved).
#   (4) Operator override `CHUMP_SCOPE_CHECK=enforce` upgrades a parent
#       commit from warn to block (existing INFRA-189 behaviour preserved).
#   (5) `CHUMP_SCOPE_CHECK=0` disables the check entirely (kill switch).
#
# Run:
#   ./scripts/ci/test-scope-check-subagent-enforce.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-337 subagent default-enforce scope-check tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit"

if [ ! -x "$HOOK" ]; then
    echo "FATAL: pre-commit hook not found or not executable: $HOOK"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Silence unrelated guards across all sub-tests.
export CHUMP_LEASE_CHECK=0
export CHUMP_STOMP_WARN=0
export CHUMP_CHECK_BUILD=0
export CHUMP_DOCS_DELTA_CHECK=0
export CHUMP_SUBMODULE_CHECK=0
export CHUMP_PREREG_CHECK=0
export CHUMP_GAPS_LOCK=0
export CHUMP_CREDENTIAL_CHECK=0
export CHUMP_BOOK_SYNC_CHECK=0
export CHUMP_RAW_YAML_LOCK=0

# Build a minimal fake repo with a lease declaring `paths: ["src/foo/**"]`
# and a single staged file outside that scope.
make_fake_repo() {
    local sid="$1"
    local fake="$TMPDIR_BASE/repo-$RANDOM"
    mkdir -p "$fake/.git/hooks" "$fake/.chump-locks" "$fake/src/foo" "$fake/other"
    git -C "$fake" init -q -b main
    git -C "$fake" config user.email "test@test.com"
    git -C "$fake" config user.name "Test"
    cp "$HOOK" "$fake/.git/hooks/pre-commit"
    chmod +x "$fake/.git/hooks/pre-commit"

    # Seed an in-scope file so the repo has at least one commit.
    echo "in scope" >"$fake/src/foo/in.txt"
    git -C "$fake" add src/foo/in.txt
    git -C "$fake" commit -q -m "seed"

    # Lease declares scope src/foo/**.
    cat >"$fake/.chump-locks/$sid.json" <<JSON
{
  "session_id": "$sid",
  "gap_id": "INFRA-337",
  "paths": ["src/foo/**"],
  "claimed_at": "2026-05-02T00:00:00Z"
}
JSON

    # Stage an OUT-OF-SCOPE file.
    echo "out of scope" >"$fake/other/leak.txt"
    git -C "$fake" add other/leak.txt

    echo "$fake"
}

run_commit() {
    local fake="$1"; shift
    local sid="$1"; shift
    # Run pre-commit by invoking git commit and capture stdout+stderr+exit.
    (
        cd "$fake"
        export CHUMP_SESSION_ID="$sid"
        # Pass any caller-supplied env-var overrides through.
        if [ "$#" -gt 0 ]; then
            env "$@" git commit -m "test" 2>&1
        else
            git commit -m "test" 2>&1
        fi
    )
}

# ── Test 1: subagent session is BLOCKED by default ────────────────────────────
echo "--- Test 1: subagent session_id 'chump-anon-1234' → BLOCKED by default ---"
unset CHUMP_SCOPE_CHECK
fake1=$(make_fake_repo "chump-anon-1234")
if out=$(run_commit "$fake1" "chump-anon-1234"); then
    fail "subagent commit was allowed (expected block); output: $out"
else
    if echo "$out" | grep -q "OUT-OF-SCOPE COMMIT BLOCKED" \
       && echo "$out" | grep -q "subagent session"; then
        ok "subagent commit BLOCKED with INFRA-337 banner"
    else
        fail "subagent commit blocked but message lacks INFRA-337 banner; output: $out"
    fi
fi

# ── Test 1b: alt subagent prefix 'subagent-' also blocked ────────────────────
echo "--- Test 1b: subagent session_id 'subagent-abc' → BLOCKED by default ---"
unset CHUMP_SCOPE_CHECK
fake1b=$(make_fake_repo "subagent-abc")
if out=$(run_commit "$fake1b" "subagent-abc"); then
    fail "subagent-prefix commit was allowed (expected block); output: $out"
else
    if echo "$out" | grep -q "OUT-OF-SCOPE COMMIT BLOCKED"; then
        ok "subagent-prefix commit BLOCKED"
    else
        fail "blocked but wrong message; output: $out"
    fi
fi

# ── Test 2: parent session emits WARN (allowed) ──────────────────────────────
echo "--- Test 2: parent session_id 'chump-Chump-9999' → WARN, allowed ---"
unset CHUMP_SCOPE_CHECK
fake2=$(make_fake_repo "chump-Chump-9999")
if out=$(run_commit "$fake2" "chump-Chump-9999"); then
    if echo "$out" | grep -q "WARN: out-of-scope commit"; then
        ok "parent commit allowed with WARN line"
    else
        fail "parent commit allowed but no WARN line; output: $out"
    fi
else
    fail "parent commit was blocked (expected warn-only); output: $out"
fi

# ── Test 3: operator override CHUMP_SCOPE_CHECK=warn downgrades subagent ────
echo "--- Test 3: subagent + CHUMP_SCOPE_CHECK=warn → WARN, allowed ---"
unset CHUMP_SCOPE_CHECK
fake3=$(make_fake_repo "chump-anon-warn")
if out=$(run_commit "$fake3" "chump-anon-warn" CHUMP_SCOPE_CHECK=warn); then
    if echo "$out" | grep -q "WARN: out-of-scope commit"; then
        ok "subagent + CHUMP_SCOPE_CHECK=warn downgraded to warn"
    else
        fail "allowed but no WARN line; output: $out"
    fi
else
    fail "CHUMP_SCOPE_CHECK=warn did not allow subagent commit; output: $out"
fi

# ── Test 4: operator override CHUMP_SCOPE_CHECK=enforce upgrades parent ─────
echo "--- Test 4: parent + CHUMP_SCOPE_CHECK=enforce → BLOCKED ---"
unset CHUMP_SCOPE_CHECK
fake4=$(make_fake_repo "chump-Chump-strict")
if out=$(run_commit "$fake4" "chump-Chump-strict" CHUMP_SCOPE_CHECK=enforce); then
    fail "parent + enforce was allowed (expected block); output: $out"
else
    if echo "$out" | grep -q "OUT-OF-SCOPE COMMIT BLOCKED"; then
        ok "parent + enforce BLOCKED"
    else
        fail "blocked but wrong message; output: $out"
    fi
fi

# ── Test 5: CHUMP_SCOPE_CHECK=0 disables entirely (subagent allowed) ────────
echo "--- Test 5: subagent + CHUMP_SCOPE_CHECK=0 → check disabled, allowed ---"
unset CHUMP_SCOPE_CHECK
fake5=$(make_fake_repo "chump-anon-disable")
if out=$(run_commit "$fake5" "chump-anon-disable" CHUMP_SCOPE_CHECK=0); then
    if echo "$out" | grep -q "OUT-OF-SCOPE COMMIT BLOCKED"; then
        fail "CHUMP_SCOPE_CHECK=0 still blocked; output: $out"
    else
        ok "CHUMP_SCOPE_CHECK=0 disables the check"
    fi
else
    fail "CHUMP_SCOPE_CHECK=0 did not allow commit; output: $out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
