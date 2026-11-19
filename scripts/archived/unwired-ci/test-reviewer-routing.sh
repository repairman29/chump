#!/usr/bin/env bash
# scripts/ci/test-reviewer-routing.sh — INFRA-1491 smoke test.
#
# Asserts the chump-reviewer-routing CLI surfaces work end-to-end:
#   - `show --files ...` computes from an ad-hoc file list (no PR query)
#   - operator override (.chump/reviewers.toml always_request) propagates
#   - CODEOWNERS rules match touched files
#   - exclude list filters reviewers
#   - max_reviewers cap honored
#   - --json output parseable
#   - `show` emits kind=reviewer_routing_computed structured event

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

echo "[setup] cargo build -p chump-reviewer-routing …"
PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" \
    cargo build -p chump-reviewer-routing --bin chump-reviewer-routing 2>&1 | tail -2

# Binary may land in worktree-local target/ OR workspace-shared target/.
BIN=""
for candidate in \
    "$REPO_ROOT/target/debug/chump-reviewer-routing" \
    "$HOME/Projects/Chump/target/debug/chump-reviewer-routing" \
    "$(PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH" cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["target_directory"])')/debug/chump-reviewer-routing"; do
    if [[ -x "$candidate" ]]; then
        BIN="$candidate"
        break
    fi
done
if [[ -z "$BIN" ]]; then
    echo "[FAIL] chump-reviewer-routing binary not found"
    exit 1
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CHUMP_REPO="$SANDBOX/repo"
mkdir -p "$CHUMP_REPO/.chump"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── Test 1: ad-hoc file list with operator override ────────────────────────
echo ""
echo "Test 1: --files with operator override emits the override reviewer"
cat > "$CHUMP_REPO/.chump/reviewers.toml" <<'EOF'
always_request = ["@marcus"]
max_reviewers = 5
recent_window_days = 90
top_n_recent = 3
EOF
out=$("$BIN" show --files src/lib.rs --json)
if echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'marcus' in [r['login'] for r in d['reviewers']]"; then
    pass "operator override propagates"
else
    fail "marcus not in $out"
fi

# ── Test 2: CODEOWNERS extension rule matches *.rs ─────────────────────────
echo ""
echo "Test 2: CODEOWNERS rule matches by file extension"
cat > "$CHUMP_REPO/CODEOWNERS" <<'EOF'
*.rs @rust-team
/docs/ @docs-team
EOF
out=$("$BIN" show --files src/lib.rs --json)
if echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); logins=[r['login'] for r in d['reviewers']]; assert 'rust-team' in logins, logins"; then
    pass "rust-team matched via *.rs CODEOWNERS"
else
    fail "rust-team not in $out"
fi

# ── Test 3: CODEOWNERS directory rule matches /docs/ ────────────────────────
echo ""
echo "Test 3: CODEOWNERS directory rule matches /docs/"
out=$("$BIN" show --files docs/foo.md --json)
if echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); logins=[r['login'] for r in d['reviewers']]; assert 'docs-team' in logins, logins"; then
    pass "docs-team matched via /docs/ CODEOWNERS"
else
    fail "docs-team not in $out"
fi

# ── Test 4: exclude list filters reviewers ─────────────────────────────────
echo ""
echo "Test 4: exclude list filters reviewers"
cat > "$CHUMP_REPO/.chump/reviewers.toml" <<'EOF'
always_request = ["@marcus", "@dependabot-bot"]
exclude = ["@dependabot-bot"]
max_reviewers = 5
recent_window_days = 90
top_n_recent = 3
EOF
out=$("$BIN" show --files src/lib.rs --json)
if echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); logins=[r['login'] for r in d['reviewers']]; assert 'dependabot-bot' not in logins and 'marcus' in logins, logins"; then
    pass "dependabot-bot excluded, marcus kept"
else
    fail "exclude not honored: $out"
fi

# ── Test 5: max_reviewers cap honored ──────────────────────────────────────
echo ""
echo "Test 5: max_reviewers=2 caps the suggestion list"
cat > "$CHUMP_REPO/.chump/reviewers.toml" <<'EOF'
always_request = ["@a", "@b", "@c", "@d"]
max_reviewers = 2
recent_window_days = 90
top_n_recent = 3
EOF
rm -f "$CHUMP_REPO/CODEOWNERS"
out=$("$BIN" show --files anything.txt --json)
if echo "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert len(d['reviewers']) == 2, len(d['reviewers'])"; then
    pass "capped at 2"
else
    fail "cap not honored: $out"
fi

# ── Test 6: emit structured event to STDERR ────────────────────────────────
echo ""
echo "Test 6: show emits kind=reviewer_routing_computed on stderr"
# Capture stderr separately; ambient consumers tail stderr to keep stdout
# pure for --json parsers.
stderr_out=$("$BIN" show --files anything.txt 2>&1 >/dev/null)
if echo "$stderr_out" | grep -q '"kind":"reviewer_routing_computed"'; then
    pass "structured event emitted on stderr"
else
    fail "missing kind on stderr: $stderr_out"
fi

# ── Test 7: rejects --pr without value ─────────────────────────────────────
echo ""
echo "Test 7: route without --pr exits non-zero"
if "$BIN" route 2>/dev/null; then
    fail "route accepted missing --pr"
else
    pass "route rejected missing --pr"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
