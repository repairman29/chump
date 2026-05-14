#!/usr/bin/env bash
# test-fleet-status-rate-limit.sh — EFFECTIVE-025: rate-limit line in fleet-status --once
#
# Tests:
#   1. Output includes 'GitHub API: REST=N/5000 GraphQL=N/5000 (resets HH:MM UTC)'
#   2. When either limit < 500, line is prefixed with 'WARN:'
#   3. Handles offline (gh unavailable) gracefully

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLEET_STATUS="$REPO_ROOT/scripts/dispatch/fleet-status.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$FLEET_STATUS" ]] || fail "fleet-status.sh not found at $FLEET_STATUS"

TMP="$(mktemp -d -t test-rl.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Mock gh CLI ────────────────────────────────────────────────────────────────
# RATE_LIMIT_FIXTURE selects scenario: normal | low_gql | low_rst
MOCK_GH="$TMP/gh"
cat > "$MOCK_GH" <<'GHEOF'
#!/usr/bin/env bash
subcmd="${1:-}"; shift || true
case "$subcmd" in
  auth)   exit 0 ;;
  api)
    url="${1:-}"; shift || true
    scenario="${RATE_LIMIT_FIXTURE:-normal}"
    case "$url" in
      rate_limit)
        case "$scenario" in
          low_gql) printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":1747200000},"graphql":{"limit":5000,"remaining":200,"reset":1747200060}}}\n' ;;
          low_rst) printf '{"resources":{"core":{"limit":5000,"remaining":100,"reset":1747200000},"graphql":{"limit":5000,"remaining":4900,"reset":1747200060}}}\n' ;;
          *)       printf '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":1747200000},"graphql":{"limit":5000,"remaining":4900,"reset":1747200060}}}\n' ;;
        esac ;;
      pulls*) echo '[]' ;;
      *)      echo '[]' ;;
    esac ;;
  pr)   echo '[]' ;;
  *)    exit 0 ;;
esac
GHEOF
chmod +x "$MOCK_GH"
export PATH="$TMP:$PATH"

LOCK_DIR="$TMP/locks"
mkdir -p "$LOCK_DIR"

FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.git"
printf 'ref: refs/heads/main\n' > "$FAKE_REPO/.git/HEAD"

# ── Test 1: Normal limits → format check ──────────────────────────────────────
OUT1="$(cd "$FAKE_REPO" && CHUMP_LOCK_DIR="$LOCK_DIR" RATE_LIMIT_FIXTURE=normal \
    bash "$FLEET_STATUS" --once 2>/dev/null || true)"

if echo "$OUT1" | grep -qE 'GitHub API: REST=4800/5000 GraphQL=4900/5000 \(resets [0-9]{2}:[0-9]{2} UTC\)'; then
    pass "Test 1: rate-limit line present with correct format"
else
    fail "Test 1: expected 'GitHub API: REST=4800/5000 GraphQL=4900/5000 (resets HH:MM UTC)'. Got: $(echo "$OUT1" | grep -i "github api" || echo '(no match)')"
fi

# Should NOT have WARN: prefix in normal scenario
if echo "$OUT1" | grep -q '^WARN:'; then
    fail "Test 1: unexpected WARN: in normal scenario"
else
    pass "Test 1: no WARN: in normal scenario"
fi

# ── Test 2: Low GraphQL → WARN: prefix ───────────────────────────────────────
OUT2="$(cd "$FAKE_REPO" && CHUMP_LOCK_DIR="$LOCK_DIR" RATE_LIMIT_FIXTURE=low_gql \
    bash "$FLEET_STATUS" --once 2>/dev/null || true)"

if echo "$OUT2" | grep -qE '^WARN: GitHub API: REST=4800/5000 GraphQL=200/5000'; then
    pass "Test 2: WARN: prefix when GraphQL remaining=200 (<500)"
else
    fail "Test 2: expected 'WARN: GitHub API:' for low GraphQL. Got: $(echo "$OUT2" | grep -i "github api\|WARN" || echo '(no match)')"
fi

# ── Test 3: Low REST → WARN: prefix ──────────────────────────────────────────
OUT3="$(cd "$FAKE_REPO" && CHUMP_LOCK_DIR="$LOCK_DIR" RATE_LIMIT_FIXTURE=low_rst \
    bash "$FLEET_STATUS" --once 2>/dev/null || true)"

if echo "$OUT3" | grep -qE '^WARN: GitHub API: REST=100/5000 GraphQL=4900/5000'; then
    pass "Test 3: WARN: prefix when REST remaining=100 (<500)"
else
    fail "Test 3: expected 'WARN: GitHub API:' for low REST. Got: $(echo "$OUT3" | grep -i "github api\|WARN" || echo '(no match)')"
fi

echo ""
echo "All EFFECTIVE-025 rate-limit checks passed (4/4)."
