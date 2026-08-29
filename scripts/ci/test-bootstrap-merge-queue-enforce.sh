#!/usr/bin/env bash
# scripts/ci/test-bootstrap-merge-queue-enforce.sh — INFRA-1518
#
# Smoke test for scripts/setup/lib/merge-queue-enforce.sh (sourced by
# chump-fleet-bootstrap.sh). Stubs `gh` on PATH so no network/credentials
# are needed. Asserts:
#   1. PUT fires when merge queue is disabled (install mode)
#   2. no-op (no PUT) when merge queue is already enabled (install mode)
#   3. exit 1 in --check mode when disabled, with no mutation
#   4. exit 0 in --check mode when enabled

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/setup/lib/merge-queue-enforce.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found"; exit 1; }
# shellcheck source=scripts/setup/lib/merge-queue-enforce.sh
source "$LIB"

# ── Isolated fake repo with an origin remote (no network needed) ─────────────
FAKE_REPO="$(mktemp -d)"
trap 'rm -rf "$FAKE_REPO" "$STUB_DIR"' EXIT
git -C "$FAKE_REPO" init --quiet
git -C "$FAKE_REPO" remote add origin "https://github.com/acme/widgets.git"

# ── Stub `gh` on PATH ─────────────────────────────────────────────────────────
STUB_DIR="$(mktemp -d)"
GH_CALL_LOG="$STUB_DIR/gh-calls.log"
GH_ENABLED_FLAG="$STUB_DIR/enabled"

write_gh_stub() {
    cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
if [[ "$1" == "api" ]]; then
    shift
    if [[ "$1" == "--method" && "$2" == "PUT" ]]; then
        echo "PUT" >> "$GH_CALL_LOG"
        exit 0
    fi
    # GET protection
    if [[ -f "$GH_ENABLED_FLAG" ]]; then
        echo '{"required_pull_request_reviews":{"merge_queue":{"enabled":true}}}'
    else
        echo '{"required_pull_request_reviews":{}}'
    fi
    exit 0
fi
exit 1
STUB
    chmod +x "$STUB_DIR/gh"
}
write_gh_stub
export PATH="$STUB_DIR:$PATH"
export GH_CALL_LOG GH_ENABLED_FLAG

# ── 1. install mode, disabled → PUT fires ─────────────────────────────────────
rm -f "$GH_ENABLED_FLAG" "$GH_CALL_LOG"
if enforce_merge_queue "install" "$FAKE_REPO"; then
    if grep -q "^PUT$" "$GH_CALL_LOG"; then
        ok "install mode + disabled → PUT fired"
    else
        fail "install mode + disabled → PUT did NOT fire"
    fi
else
    fail "enforce_merge_queue returned non-zero on successful PUT"
fi

# ── 2. install mode, already enabled → no PUT (no-op / idempotent) ───────────
touch "$GH_ENABLED_FLAG"
rm -f "$GH_CALL_LOG"
if enforce_merge_queue "install" "$FAKE_REPO"; then
    if grep -q "^PUT$" "$GH_CALL_LOG"; then
        fail "install mode + enabled → PUT fired (should be no-op)"
    else
        ok "install mode + enabled → no PUT (idempotent)"
    fi
else
    fail "enforce_merge_queue returned non-zero when already enabled"
fi

# ── 3. check mode, disabled → exit 1, no mutation ─────────────────────────────
rm -f "$GH_ENABLED_FLAG"
rm -f "$GH_CALL_LOG"
if enforce_merge_queue "check" "$FAKE_REPO"; then
    fail "check mode + disabled → expected exit 1, got 0"
else
    if grep -q "^PUT$" "$GH_CALL_LOG"; then
        fail "check mode + disabled → PUT fired (check mode must not mutate)"
    else
        ok "check mode + disabled → exit 1, no mutation"
    fi
fi

# ── 4. check mode, enabled → exit 0 ───────────────────────────────────────────
touch "$GH_ENABLED_FLAG"
rm -f "$GH_CALL_LOG"
if enforce_merge_queue "check" "$FAKE_REPO"; then
    ok "check mode + enabled → exit 0"
else
    fail "check mode + enabled → expected exit 0, got non-zero"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
