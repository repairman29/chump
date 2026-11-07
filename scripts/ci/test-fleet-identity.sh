#!/usr/bin/env bash
# test-fleet-identity.sh — INFRA-8652 regression test.
#
# Verifies the GH_TOKEN_FLEET / GH_TOKEN split:
#   - with GH_TOKEN_FLEET set, fleet_identity_init exports GH_TOKEN to it and
#     sets local git user.name/user.email to the machine account's identity
#     (so commits + the PR author login are the machine account, not
#     whatever `gh` was already logged in as).
#   - without GH_TOKEN_FLEET, fleet_identity_init is a complete no-op except
#     for emitting kind=fleet_identity_missing exactly once per boot.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/coord/lib/fleet-identity.sh"

if [[ ! -f "$LIB" ]]; then
    echo "[FAIL] fleet-identity.sh not found at $LIB"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SANDBOX="$TMP_DIR/repo"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" config user.email "preexisting@example.com"
git -C "$SANDBOX" config user.name "Preexisting Operator"

# Fake `gh` binary on PATH: `gh api user --jq '.login'` returns a fixed
# machine-account login whenever GH_TOKEN == the fleet token.
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "user" ]]; then
    if [[ "${GH_TOKEN:-}" == "fake-fleet-token-xyz" ]]; then
        echo "chump-fleet-bot"
        exit 0
    fi
    echo "wrong-token" >&2
    exit 1
fi
echo "unsupported fake gh invocation: $*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

AMBIENT_LOG="$TMP_DIR/ambient.jsonl"
SENTINEL="$TMP_DIR/fleet-identity-missing-sentinel"

run_case() {
    (
        cd "$SANDBOX"
        PATH="$FAKE_BIN:$PATH"
        export PATH
        export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
        export CHUMP_FLEET_IDENTITY_SENTINEL="$SENTINEL"
        # shellcheck disable=SC1090
        source "$LIB"
        fleet_identity_init
        echo "GH_TOKEN=${GH_TOKEN:-}"
        echo "FLEET_IDENTITY_ACTIVE=$FLEET_IDENTITY_ACTIVE"
        echo "FLEET_IDENTITY_LOGIN=$FLEET_IDENTITY_LOGIN"
        echo "user.name=$(git config user.name)"
        echo "user.email=$(git config user.email)"
    )
}

# --------------------------------------------------------------------
# Test 1: GH_TOKEN_FLEET set → GH_TOKEN takes its value, git identity
# flips to the machine account.
# --------------------------------------------------------------------
OUT="$(GH_TOKEN_FLEET="fake-fleet-token-xyz" run_case)"

if ! grep -q "^GH_TOKEN=fake-fleet-token-xyz$" <<<"$OUT"; then
    echo "[FAIL] Test 1: GH_TOKEN not set to GH_TOKEN_FLEET value"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^FLEET_IDENTITY_ACTIVE=1$" <<<"$OUT"; then
    echo "[FAIL] Test 1: FLEET_IDENTITY_ACTIVE not 1"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^FLEET_IDENTITY_LOGIN=chump-fleet-bot$" <<<"$OUT"; then
    echo "[FAIL] Test 1: FLEET_IDENTITY_LOGIN not resolved to machine account login"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^user.name=chump-fleet-bot$" <<<"$OUT"; then
    echo "[FAIL] Test 1: git user.name not rewritten to machine account login"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^user.email=chump-fleet-bot@users.noreply.github.com$" <<<"$OUT"; then
    echo "[FAIL] Test 1: git user.email not rewritten to machine account noreply address"
    echo "$OUT"
    exit 1
fi
echo "[PASS] Test 1: GH_TOKEN_FLEET set → GH_TOKEN + git identity flip to machine account"

# --------------------------------------------------------------------
# Test 2: GH_TOKEN_FLEET unset → complete fallback, no git identity touch,
# fleet_identity_missing emitted exactly once.
# --------------------------------------------------------------------
git -C "$SANDBOX" config user.name "Preexisting Operator"
git -C "$SANDBOX" config user.email "preexisting@example.com"
rm -f "$AMBIENT_LOG" "$SENTINEL"

unset GH_TOKEN_FLEET
OUT="$(run_case)"

if ! grep -q "^GH_TOKEN=$" <<<"$OUT"; then
    echo "[FAIL] Test 2: GH_TOKEN was set despite GH_TOKEN_FLEET being unset"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^FLEET_IDENTITY_ACTIVE=0$" <<<"$OUT"; then
    echo "[FAIL] Test 2: FLEET_IDENTITY_ACTIVE not 0 in fallback"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^user.name=Preexisting Operator$" <<<"$OUT"; then
    echo "[FAIL] Test 2: fallback mutated pre-existing git user.name"
    echo "$OUT"
    exit 1
fi
if ! grep -q "^user.email=preexisting@example.com$" <<<"$OUT"; then
    echo "[FAIL] Test 2: fallback mutated pre-existing git user.email"
    echo "$OUT"
    exit 1
fi
if [[ ! -f "$AMBIENT_LOG" ]] || ! grep -q '"kind":"fleet_identity_missing"' "$AMBIENT_LOG"; then
    echo "[FAIL] Test 2: kind=fleet_identity_missing not emitted on fallback"
    cat "$AMBIENT_LOG" 2>/dev/null || true
    exit 1
fi
echo "[PASS] Test 2: GH_TOKEN_FLEET unset → clean fallback + fleet_identity_missing emitted"

# --------------------------------------------------------------------
# Test 3: once-per-boot debounce — calling init again in fallback mode
# does not emit a second fleet_identity_missing event.
# --------------------------------------------------------------------
run_case >/dev/null

MISSING_COUNT="$(grep -c '"kind":"fleet_identity_missing"' "$AMBIENT_LOG")"
if [[ "$MISSING_COUNT" != "1" ]]; then
    echo "[FAIL] Test 3: expected exactly 1 fleet_identity_missing event, got $MISSING_COUNT"
    cat "$AMBIENT_LOG"
    exit 1
fi
echo "[PASS] Test 3: once-per-boot debounce holds across repeated fallback calls"

# --------------------------------------------------------------------
# Test 4: bot-merge.sh sources the lib and calls fleet_identity_init
# --------------------------------------------------------------------
if ! grep -q 'source "\$(dirname "\$0")/lib/fleet-identity.sh"' "$REPO_ROOT/scripts/coord/bot-merge.sh"; then
    echo "[FAIL] Test 4: bot-merge.sh does not source lib/fleet-identity.sh"
    exit 1
fi
if ! grep -q '^fleet_identity_init$' "$REPO_ROOT/scripts/coord/bot-merge.sh"; then
    echo "[FAIL] Test 4: bot-merge.sh does not call fleet_identity_init"
    exit 1
fi
echo "[PASS] Test 4: bot-merge.sh wires fleet_identity_init into the ship pipeline"

echo "[PASS] all fleet-identity tests passed"
