#!/usr/bin/env bash
# scripts/ci/test-bootstrap-merge-queue-enforce.sh — INFRA-1518
#
# Tests scripts/setup/lib/merge-queue-enforce.sh in isolation (stubbed `gh`,
# no real GitHub calls, no full chump-fleet-bootstrap.sh run — that would
# also walk REQUIRED_DAEMONS and try to install real launchd/systemd units).
#
# Asserts:
#   1. mode=install + queue disabled -> PUT fires, prints "enabled"
#   2. mode=install + queue enabled  -> no PUT, prints "ok" (idempotent no-op)
#   3. mode=check    + queue disabled -> exits 1, prints "missing", no PUT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/setup/lib/merge-queue-enforce.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing" >&2; exit 1; }
# shellcheck source=scripts/setup/lib/merge-queue-enforce.sh
source "$LIB"

FAKE_BIN_DIR="$(mktemp -d)"
export PUT_LOG="$(mktemp -d)/put.log"
: > "$PUT_LOG"

# Stub gh: reads $MQ_STATE (enabled|disabled) env var to decide the
# protection-query response; logs any --method PUT call to $PUT_LOG.
cat > "$FAKE_BIN_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
combined="$*"
if [[ "$combined" == *"--method PUT"* ]]; then
    echo "$combined" >> "${PUT_LOG:?}"
    exit 0
elif [[ "$combined" == *"branches/main/protection"* ]]; then
    if [[ "${MQ_STATE:-disabled}" == "enabled" ]]; then
        echo "true"
    else
        echo "false"
    fi
    exit 0
else
    echo "stub-gh: unhandled: $combined" >&2
    exit 1
fi
GHEOF
chmod +x "$FAKE_BIN_DIR/gh"
export PATH="$FAKE_BIN_DIR:$PATH"

# ── 1. install mode, disabled -> PUT fires ───────────────────────────────────
echo "── 1. install mode, queue disabled ──"
: > "$PUT_LOG"
export MQ_STATE=disabled
set +e
result="$(enforce_merge_queue install "test-owner/test-repo")"
rc=$?
set -e
if [[ "$result" == "enabled" && "$rc" -eq 0 ]]; then
    ok "returns 'enabled' with exit 0"
else
    fail "expected 'enabled'/0, got '$result'/$rc"
fi
if [[ -s "$PUT_LOG" ]] && grep -q "grouping_strategy\]=ALLGREEN" "$PUT_LOG"; then
    ok "PUT fired with grouping_strategy=ALLGREEN"
else
    fail "expected a PUT call in log, got: $(cat "$PUT_LOG" 2>/dev/null)"
fi

# ── 2. install mode, already enabled -> no PUT (idempotent) ─────────────────
echo "── 2. install mode, queue already enabled ──"
: > "$PUT_LOG"
export MQ_STATE=enabled
set +e
result="$(enforce_merge_queue install "test-owner/test-repo")"
rc=$?
set -e
if [[ "$result" == "ok" && "$rc" -eq 0 ]]; then
    ok "returns 'ok' with exit 0 (no-op)"
else
    fail "expected 'ok'/0, got '$result'/$rc"
fi
if [[ ! -s "$PUT_LOG" ]]; then
    ok "no PUT call issued when already enabled"
else
    fail "unexpected PUT call when already enabled: $(cat "$PUT_LOG")"
fi

# ── 3. check mode, disabled -> exit 1, no PUT ────────────────────────────────
echo "── 3. check mode, queue disabled ──"
: > "$PUT_LOG"
export MQ_STATE=disabled
set +e
result="$(enforce_merge_queue check "test-owner/test-repo")"
rc=$?
set -e
if [[ "$result" == "missing" && "$rc" -eq 1 ]]; then
    ok "returns 'missing' with exit 1 in --check mode"
else
    fail "expected 'missing'/1, got '$result'/$rc"
fi
if [[ ! -s "$PUT_LOG" ]]; then
    ok "no PUT call issued in --check mode"
else
    fail "unexpected PUT call in --check mode: $(cat "$PUT_LOG")"
fi

# ── 4. check mode, enabled -> exit 0 ─────────────────────────────────────────
echo "── 4. check mode, queue enabled ──"
export MQ_STATE=enabled
set +e
result="$(enforce_merge_queue check "test-owner/test-repo")"
rc=$?
set -e
if [[ "$result" == "ok" && "$rc" -eq 0 ]]; then
    ok "returns 'ok' with exit 0 in --check mode"
else
    fail "expected 'ok'/0, got '$result'/$rc"
fi

rm -rf "$FAKE_BIN_DIR" "$(dirname "$PUT_LOG")"

echo
echo "── Results: $PASS passed, $FAIL failed ──"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
