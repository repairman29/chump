#!/usr/bin/env bash
# test-pre-push-actionlint-guard.sh — INFRA-2322
#
# Smoke test for scripts/git-hooks/pre-push-actionlint-guard.sh:
#  1. Guard script exists, is executable, and is wired into scripts/git-hooks/pre-push
#  2. No changed workflow files → guard exits 0 (no-op)
#  3. actionlint binary absent → guard exits 0 (transient, non-blocking) and
#     emits kind=actionlint_guard_skipped
#  4. actionlint binary present + clean workflow → exits 0, emits
#     kind=actionlint_guard_passed
#  5. actionlint binary present + broken workflow → exits 1, emits
#     kind=actionlint_guard_blocked
#  6. CHUMP_ACTIONLINT_GUARD=0 bypasses entirely
#  7. New ambient kinds are registered in EVENT_REGISTRY.yaml

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$REPO_ROOT/scripts/git-hooks/pre-push-actionlint-guard.sh"

PASS=0
FAIL=0
FAIL_CLASS=""
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() {
    printf '  \033[0;31mFAIL\033[0m %s\n' "$*"
    FAIL=$((FAIL+1))
    # INFRA-1649: classify so the final `guard: fail class=...` line tells the
    # caller whether a re-run is worth it. Setup/tooling failures (missing
    # guard script, guard not wired into pre-push) are environment problems —
    # transient. Guard *behavior* failures (wrong exit code, missing ambient
    # event) are logic bugs in the guard itself — permanent.
    case "$*" in
        *"guard script missing"*|*"not wired into"*|*"bypass variable missing"*)
            FAIL_CLASS="transient" ;;
        *)
            FAIL_CLASS="permanent" ;;
    esac
}

echo "=== INFRA-2322 pre-push actionlint gate test ==="
echo

# ── 1. Guard present + wired ─────────────────────────────────────────────────
[[ -x "$GUARD" ]] && ok "guard script exists and is executable" \
  || fail "guard script missing or not executable at $GUARD"

grep -q "pre-push-actionlint-guard.sh" "$REPO_ROOT/scripts/git-hooks/pre-push" \
  && ok "guard is wired into scripts/git-hooks/pre-push" \
  || fail "guard not referenced from scripts/git-hooks/pre-push"

grep -q "CHUMP_ACTIONLINT_GUARD" "$REPO_ROOT/scripts/git-hooks/pre-push" \
  && ok "CHUMP_ACTIONLINT_GUARD bypass variable wired into pre-push" \
  || fail "CHUMP_ACTIONLINT_GUARD bypass variable missing from pre-push"

# ── Synthetic repo setup ─────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q -b main
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name "Test"
mkdir -p "$TMP/.github/workflows" "$TMP/.chump-locks"
echo "placeholder" > "$TMP/README.md"
git -C "$TMP" add README.md
git -C "$TMP" commit -q -m "init"
git -C "$TMP" remote add origin "$TMP" 2>/dev/null || true
git -C "$TMP" update-ref refs/remotes/origin/main main

AMB="$TMP/.chump-locks/ambient.jsonl"

# run_guard — INFRA-1649 hardened: runs the guard, captures its rc + combined
# output, and classifies any non-zero rc as transient (tooling/environment —
# e.g. actionlint binary absent, base ref unresolvable — see the guard's own
# "(transient class)"/"skipping" markers) or permanent (an actual blocking
# finding against a workflow file). Classification is exposed via
# LAST_GUARD_RC / LAST_GUARD_CLASS for callers that want to assert on it;
# existing callers keep using the function's exit code unchanged.
LAST_GUARD_RC=0
LAST_GUARD_CLASS=""
run_guard() {
    local out rc
    out="$( cd "$TMP" && bash "$GUARD" 2>&1 )"
    rc=$?
    LAST_GUARD_RC=$rc
    if [[ $rc -eq 0 ]]; then
        LAST_GUARD_CLASS=""
    elif echo "$out" | grep -qiE 'transient class|skipping|not found|no-base-ref'; then
        LAST_GUARD_CLASS="transient"
    else
        LAST_GUARD_CLASS="permanent"
    fi
    echo "$out"
    return "$rc"
}

# ── 2. No changed workflow files → no-op ─────────────────────────────────────
git -C "$TMP" checkout -q -b feat-no-workflow
echo "more" >> "$TMP/README.md"
git -C "$TMP" add README.md
git -C "$TMP" commit -q -m "unrelated change"
if run_guard >/tmp/actionlint-guard-test.out 2>&1; then
    ok "no changed workflow files → guard exits 0"
else
    fail "guard should exit 0 when no workflow files changed"
fi
git -C "$TMP" checkout -q main
git -C "$TMP" branch -q -D feat-no-workflow

# ── 3. actionlint absent → skip (only meaningful if binary truly absent) ────
git -C "$TMP" checkout -q -b feat-workflow-skip
cat > "$TMP/.github/workflows/demo.yml" <<'EOF'
name: demo
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
EOF
git -C "$TMP" add .github/workflows/demo.yml
git -C "$TMP" commit -q -m "add workflow"

if command -v actionlint &>/dev/null; then
    echo "  SKIP: actionlint installed locally — skip test 3 (binary-absent path), covering test 4/5 instead"
    # ── 4. clean workflow, actionlint present → pass ─────────────────────────
    if run_guard >/tmp/actionlint-guard-test.out 2>&1; then
        ok "clean workflow + actionlint present → guard exits 0"
    else
        fail "guard should pass on a clean workflow file"
        cat /tmp/actionlint-guard-test.out
    fi
    grep -q '"kind":"actionlint_guard_passed"' "$AMB" 2>/dev/null \
        && ok "kind=actionlint_guard_passed emitted" \
        || fail "kind=actionlint_guard_passed not found in ambient.jsonl"

    # ── 5. broken workflow (matrix-in-if class) → block ──────────────────────
    cat > "$TMP/.github/workflows/demo.yml" <<'EOF'
name: demo
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    if: ${{ matrix.os == 'linux' }}
    strategy:
      matrix:
        os: [ubuntu-latest]
    steps:
      - uses: actions/checkout@v4
EOF
    git -C "$TMP" add .github/workflows/demo.yml
    git -C "$TMP" commit -q -m "break workflow (matrix-in-if)"
    if run_guard >/tmp/actionlint-guard-test.out 2>&1; then
        fail "guard should block on matrix-in-if class"
        cat /tmp/actionlint-guard-test.out
    else
        ok "matrix-in-if workflow → guard exits 1 (blocked)"
    fi
    grep -q '"kind":"actionlint_guard_blocked"' "$AMB" 2>/dev/null \
        && ok "kind=actionlint_guard_blocked emitted" \
        || fail "kind=actionlint_guard_blocked not found in ambient.jsonl"
else
    if run_guard >/tmp/actionlint-guard-test.out 2>&1; then
        ok "actionlint absent → guard exits 0 (transient, non-blocking)"
    else
        fail "guard should not block when actionlint binary is absent"
        cat /tmp/actionlint-guard-test.out
    fi
    grep -q '"kind":"actionlint_guard_skipped"' "$AMB" 2>/dev/null \
        && ok "kind=actionlint_guard_skipped emitted" \
        || fail "kind=actionlint_guard_skipped not found in ambient.jsonl"
fi

git -C "$TMP" checkout -q main
git -C "$TMP" branch -q -D feat-workflow-skip

# ── 6. CHUMP_ACTIONLINT_GUARD=0 bypasses entirely ────────────────────────────
git -C "$TMP" checkout -q -b feat-bypass
mkdir -p "$TMP/.github/workflows"
cat > "$TMP/.github/workflows/demo2.yml" <<'EOF'
name: demo2
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    if: ${{ matrix.os == 'linux' }}
    steps:
      - uses: actions/checkout@v4
EOF
git -C "$TMP" add .github/workflows/demo2.yml
git -C "$TMP" commit -q -m "broken workflow under bypass"
if ( cd "$TMP" && CHUMP_ACTIONLINT_GUARD=0 bash "$GUARD" ) >/tmp/actionlint-guard-test.out 2>&1; then
    ok "CHUMP_ACTIONLINT_GUARD=0 bypasses the guard"
else
    fail "CHUMP_ACTIONLINT_GUARD=0 should bypass the guard entirely"
fi
git -C "$TMP" checkout -q main
git -C "$TMP" branch -q -D feat-bypass

# ── 7. EVENT_REGISTRY.yaml coverage ─────────────────────────────────────────
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for kind in actionlint_guard_blocked actionlint_guard_skipped actionlint_guard_passed; do
    grep -q "kind: $kind" "$REGISTRY" \
        && ok "kind=$kind registered in EVENT_REGISTRY.yaml" \
        || fail "kind=$kind missing from EVENT_REGISTRY.yaml"
done

echo
echo "=== $PASS passed, $FAIL failed ==="

# INFRA-1649: single-line machine-checkable summary. `guard: ok` on success;
# on any failure, `guard: fail class=<transient|permanent>` to stderr so a
# calling curator/CI step can tell "environment flake, re-run" from "the
# guard is actually broken" without parsing the PASS/FAIL log above.
if [[ "$FAIL" -eq 0 ]]; then
    echo "guard: ok"
    exit 0
else
    echo "guard: fail class=${FAIL_CLASS:-permanent}" >&2
    exit 1
fi
