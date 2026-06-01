#!/usr/bin/env bash
# INFRA-2258 AC6: test-voice-subcommand.sh
# Smoke test for `chump voice` subcommand:
#   1. Invoke with anonymized flags → assert VOA-NNNN.yaml written with correct shape
#   2. Assert no opt-in slug leak in gap entry or ambient event
#   3. Assert --ship --dry-run prints PR body without opening a PR
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[test-voice-subcommand] building chump binary..."
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet
fi

# ── Isolated test environment ──────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Fake repo root: contains docs/gaps/ and docs/voice/ and .chump-locks/
FAKE_ROOT="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_ROOT/docs/gaps"
mkdir -p "$FAKE_ROOT/docs/voice"
mkdir -p "$FAKE_ROOT/.chump-locks"

# Bootstrap a fake Cargo.toml with [workspace] so repo_root() detection works.
cat > "$FAKE_ROOT/Cargo.toml" << 'EOF'
[workspace]
members = []
EOF

AMBIENT_LOG="$FAKE_ROOT/.chump-locks/ambient.jsonl"

export CHUMP_REPO_ROOT="$FAKE_ROOT"
export CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
export CHUMP_SESSION_ID="test-voice-$$"
# Force a known VOA ID so tests are deterministic.
export CHUMP_VOICE_TEST_ID="VOA-002"

FAIL=0

# ── Test 1: anonymous filing, correct YAML shape ───────────────────────────────
echo "[test-voice-subcommand] Test 1: anonymous filing"

"$CHUMP_BIN" voice \
    --wedge-class "fmt-drift-queue-wide" \
    --minutes-lost 30 \
    --workaround "ran cargo fmt --all sweep" \
    --fix-shape "gate" \
    --fix "chump preflight mirrors CI parity (INFRA-2120)" \
    --target-repo "anonymous" \
    --evidence "PR #2769,INFRA-2120"

GAP_FILE="$FAKE_ROOT/docs/gaps/VOA-002.yaml"
FULL_FILE="$FAKE_ROOT/docs/voice/VOA-002-FULL.yaml"

if [[ ! -f "$GAP_FILE" ]]; then
    echo "FAIL: docs/gaps/VOA-002.yaml not written"
    FAIL=1
else
    echo "  PASS: docs/gaps/VOA-002.yaml exists"
fi

if [[ ! -f "$FULL_FILE" ]]; then
    echo "FAIL: docs/voice/VOA-002-FULL.yaml not written"
    FAIL=1
else
    echo "  PASS: docs/voice/VOA-002-FULL.yaml exists"
fi

# Assert correct fields in gap entry.
if ! grep -q "VOA-002" "$GAP_FILE" 2>/dev/null; then
    echo "FAIL: gap entry missing VOA-002 id"
    FAIL=1
else
    echo "  PASS: gap entry contains VOA-002"
fi

if ! grep -q "fmt-drift-queue-wide" "$GAP_FILE" 2>/dev/null; then
    echo "FAIL: gap entry missing wedge_class"
    FAIL=1
else
    echo "  PASS: gap entry contains wedge_class"
fi

if ! grep -q "minutes_lost=30" "$GAP_FILE" 2>/dev/null; then
    echo "FAIL: gap entry missing minutes_lost=30"
    FAIL=1
else
    echo "  PASS: gap entry contains minutes_lost=30"
fi

# Assert correct fields in full report.
if ! grep -q "wedge_class: fmt-drift-queue-wide" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report missing wedge_class"
    FAIL=1
else
    echo "  PASS: full report has wedge_class"
fi

if ! grep -q "minutes_lost: 30" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report missing minutes_lost"
    FAIL=1
else
    echo "  PASS: full report has minutes_lost"
fi

if ! grep -q "target_repo: \"anonymous\"" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report does not have target_repo: anonymous"
    FAIL=1
else
    echo "  PASS: full report target_repo is anonymous"
fi

if ! grep -q "target_repo_disclosure: anonymous" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: full report missing anonymous disclosure"
    FAIL=1
else
    echo "  PASS: full report disclosure is anonymous"
fi

# ── Test 2: No opt-in slug leak in anonymous mode ─────────────────────────────
echo "[test-voice-subcommand] Test 2: no opt-in slug leak in anonymous mode"

# Create a voice-opt-in.toml with opt-in:slug to ensure --target-repo anonymous
# takes precedence and we DON'T leak the slug.
FAKE_HOME="$TMPDIR_TEST/home"
mkdir -p "$FAKE_HOME/.chump"
cat > "$FAKE_HOME/.chump/voice-opt-in.toml" << 'EOF'
mode = "opt-in:slug"
github_identity = "testuser"
EOF
# Note: CHUMP_VOICE_TEST_ID is still set so we'd write VOA-002 again (overwrite),
# which is fine for the leak check.
export HOME="$FAKE_HOME"

"$CHUMP_BIN" voice \
    --wedge-class "some-wedge" \
    --minutes-lost 10 \
    --fix-shape "doc" \
    --fix "update docs" \
    --target-repo "anonymous"

# Ambient log must NOT contain a real repo slug.
if grep -q '"target_repo":"opt-in:slug\|repairman29\|example-corp' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient log leaks slug in anonymous mode"
    FAIL=1
else
    echo "  PASS: ambient log does not leak slug"
fi

# Gap file and full report must not contain target slug either.
if grep -q "repairman29\|example-corp" "$GAP_FILE" "$FULL_FILE" 2>/dev/null; then
    echo "FAIL: YAML files leak slug in anonymous mode"
    FAIL=1
else
    echo "  PASS: YAML files do not leak slug"
fi

# ── Test 3: ambient event shape ───────────────────────────────────────────────
echo "[test-voice-subcommand] Test 3: ambient event kind=voice_of_agent_filed"

if ! grep -q '"kind":"voice_of_agent_filed"' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient.jsonl missing kind=voice_of_agent_filed"
    FAIL=1
else
    echo "  PASS: ambient.jsonl has kind=voice_of_agent_filed"
fi

if ! grep -q '"wedge_class"' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient event missing wedge_class field"
    FAIL=1
else
    echo "  PASS: ambient event has wedge_class"
fi

if ! grep -q '"minutes_lost"' "$AMBIENT_LOG" 2>/dev/null; then
    echo "FAIL: ambient event missing minutes_lost field"
    FAIL=1
else
    echo "  PASS: ambient event has minutes_lost"
fi

# ── Test 4: --ship --dry-run prints PR body without opening PR ─────────────────
echo "[test-voice-subcommand] Test 4: --ship --dry-run"

SHIP_OUTPUT="$TMPDIR_TEST/ship-output.txt"
"$CHUMP_BIN" voice \
    --wedge-class "bot-merge-silent-wedge" \
    --minutes-lost 60 \
    --workaround "manual recovery" \
    --fix-shape "tooling" \
    --fix "wall-clock progress monitor with auto-bail" \
    --target-repo "anonymous" \
    --ship \
    --dry-run > "$SHIP_OUTPUT" 2>&1

if ! grep -q "VOA-002" "$SHIP_OUTPUT" 2>/dev/null; then
    echo "FAIL: --ship --dry-run output missing VOA ID"
    FAIL=1
else
    echo "  PASS: --ship --dry-run output contains VOA ID"
fi

if ! grep -q "PR BODY" "$SHIP_OUTPUT" 2>/dev/null; then
    echo "FAIL: --ship --dry-run did not print PR body marker"
    FAIL=1
else
    echo "  PASS: --ship --dry-run printed PR body"
fi

if ! grep -q "bot-merge-silent-wedge" "$SHIP_OUTPUT" 2>/dev/null; then
    echo "FAIL: --ship --dry-run PR body missing wedge class"
    FAIL=1
else
    echo "  PASS: --ship --dry-run PR body has wedge class"
fi

# Confirm no actual git branch was created (dry-run should not mutate).
if git -C "$REPO_ROOT" branch --list "voice/voa-002" | grep -q "voice/voa-002" 2>/dev/null; then
    echo "FAIL: --ship --dry-run created a real git branch"
    FAIL=1
else
    echo "  PASS: --ship --dry-run did not create a git branch"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "[test-voice-subcommand] ALL TESTS PASSED"
    exit 0
else
    echo "[test-voice-subcommand] SOME TESTS FAILED"
    exit 1
fi
