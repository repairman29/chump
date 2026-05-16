#!/usr/bin/env bash
# test-precommit-gate-auto-skip.sh — INFRA-1398
#
# Verifies the pre-commit / pre-push gates auto-skip when the staged-or-
# pushed file types make them irrelevant:
#
#   1. obs-budget gate: scripts/ci/test-*.sh additions are NOT counted as
#      feature LOC (those scripts ARE observability assertions, not
#      runtime code paths)
#   2. obs-budget gate: scripts/git-hooks/* additions also excluded
#   3. (informational) fmt-check on push only runs when push delta has
#      .rs files

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OBS_GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-obs-budget.sh"
PRE_PUSH="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-1398 pre-commit/pre-push gate auto-skip tests ==="

# ── AC #1+2: obs-budget excludes scripts/ci/test-*.sh + scripts/git-hooks/ ──
if grep -q "scripts/git-hooks/\|scripts/ci/test-" "$OBS_GATE"; then
    ok "obs-budget excludes scripts/git-hooks/ + scripts/ci/test-* paths"
else
    fail "obs-budget gate still counts gate-files / CI-test-files as feature LOC"
fi

# Validate the actual exclusion regex matches both prefixes.
if grep -qE "grep -vE.*scripts/git-hooks/.*scripts/ci/test-" "$OBS_GATE"; then
    ok "exclusion regex combines both prefixes in one filter"
else
    fail "exclusion regex shape not as expected"
fi

# ── Functional: simulate the obs-budget gate on a fake test-only diff ───────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Set up a fake repo with the gate script + a staged scripts/ci/test-*.sh
( cd "$TMP" && \
  git init -q . && \
  git config user.email t@t && git config user.name t && \
  mkdir -p scripts/ci scripts/git-hooks && \
  cp "$OBS_GATE" scripts/git-hooks/pre-commit-obs-budget.sh && \
  echo "init" > R && git add R && git -c commit.gpgsign=false commit -qm i )
# Stage a 200-line scripts/ci/test-*.sh — large enough to trip the default 50-line threshold
# if the exclusion didn't fire.
seq 1 200 | sed 's/^/echo /' > "$TMP/scripts/ci/test-mock.sh"
( cd "$TMP" && git add scripts/ci/test-mock.sh )
if ( cd "$TMP" && bash scripts/git-hooks/pre-commit-obs-budget.sh ) >/dev/null 2>&1; then
    ok "functional: obs-budget passes on 200-line scripts/ci/test-*.sh diff"
else
    fail "functional: obs-budget BLOCKED scripts/ci/test-*.sh — exclusion not effective"
fi

# Sanity: a 200-line FEATURE diff in src/ STILL gets blocked (regression guard
# that we didn't accidentally disable the gate entirely).
mkdir -p "$TMP/src"
seq 1 200 | sed 's/^/let _x = /; s/$/;/' > "$TMP/src/mock.rs"
( cd "$TMP" && git add src/mock.rs )
if ( cd "$TMP" && bash scripts/git-hooks/pre-commit-obs-budget.sh ) >/dev/null 2>&1; then
    fail "sanity: obs-budget should STILL block 200-line src/*.rs diff (regression!)"
else
    ok "sanity: obs-budget still blocks 200-line src/*.rs diff (no over-eager skip)"
fi

# ── AC #3: pre-push fmt gate scopes by push-delta, not repo-existence ──────
if grep -q "git diff --name-only.*range_base.*local_sha.*grep -qE '\\\\.rs\$'" "$PRE_PUSH"; then
    ok "pre-push fmt gate scopes cargo fmt --check by push DELTA"
else
    fail "pre-push fmt gate still runs unconditionally"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
