#!/usr/bin/env bash
# scripts/ci/test-toolchain-ratchet-detector.sh — INFRA-2036
#
# Validates scripts/coord/toolchain-ratchet-detector.sh (W-014 wedge class:
# toolchain-ratchet). Covers the observability contract from the gap's AC:
#   1. events emitted on success/failure/timeout
#   2. cost tracked (elapsed_ms, gh_calls) on every terminal event
#   3. failure-class taxonomy (transient vs permanent)
#   4. this file IS the smoke test command referenced in the detector's header
#
# Mocks git/gh via a PATH-prepended stub dir so the test never touches real
# network/gh state. W-013 immunization: unset workflow-injected env so this
# test's own fixtures are not hijacked by CI workflow paths.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-2036 toolchain-ratchet-detector tests ==="

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DETECTOR="$REPO_ROOT/scripts/coord/toolchain-ratchet-detector.sh"
[[ -x "$DETECTOR" ]] || { echo "FATAL: $DETECTOR not executable"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CHUMP_REPO CHUMP_LOCK_DIR

FAKE="$TMP/repo"
mkdir -p "$FAKE/.chump-locks"
AMBIENT="$FAKE/.chump-locks/ambient.jsonl"

BIN="$TMP/bin"
mkdir -p "$BIN"

run_detector() {
    > "$AMBIENT"
    env PATH="$BIN:$PATH" \
        CHUMP_REPO_ROOT="$FAKE" \
        CHUMP_AMBIENT_LOG="$AMBIENT" \
        CHUMP_W014_TIMEOUT_S="${W014_TIMEOUT_S:-20}" \
        "$@" \
        bash "$DETECTOR" ${W014_ARGS:-} 2>&1
}

# ── Test 2: no toolchain-file change → clean, cost fields present ──────────
echo "--- Test 2: no toolchain-defining file change → scan_completed result=clean ---"
cat > "$BIN/git" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "log" ]]; then
    exit 0   # empty output — no matching commits
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$BIN/git"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
echo "gh should not be called when no toolchain commit found" >&2
exit 1
EOF
chmod +x "$BIN/gh"

OUT=$(run_detector)
if grep -q '"kind":"toolchain_ratchet_scan_started"' "$AMBIENT" \
   && grep -q '"kind":"toolchain_ratchet_scan_completed"' "$AMBIENT" \
   && grep -q '"result":"clean"' "$AMBIENT" \
   && grep -q '"elapsed_ms":' "$AMBIENT" \
   && grep -q '"gh_calls":0' "$AMBIENT" \
   && ! grep -q 'wedge_detected' "$AMBIENT"; then
    ok "clean scan emits started+completed with cost fields, no wedge_detected"
else
    fail "expected clean scan (ambient=$(cat "$AMBIENT"))"
fi

# ── Test 3: toolchain file changed + <2 failing PRs → still clean ──────────
echo "--- Test 3: toolchain commit found but only 1 PR failing → clean (below threshold) ---"
cat > "$BIN/git" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "log" ]]; then
    echo "COMMIT:deadbeef1234"
    exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$BIN/git"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":1,"statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE"}]},{"number":2,"statusCheckRollup":[{"name":"unit-tests","conclusion":"FAILURE"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"

OUT=$(run_detector)
if grep -q '"result":"clean"' "$AMBIENT" && ! grep -q 'wedge_detected' "$AMBIENT"; then
    ok "1 failing PR stays below MIN_FAILING_PRS=2 threshold → clean"
else
    fail "expected clean below threshold (ambient=$(cat "$AMBIENT"))"
fi

# ── Test 4: toolchain file changed + ≥2 failing PRs → detected, permanent ──
echo "--- Test 4: toolchain commit + 2 PRs failing fmt/clippy → W-014 DETECTED ---"
cat > "$BIN/gh" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[{"number":1,"statusCheckRollup":[{"name":"clippy","conclusion":"FAILURE"}]},{"number":2,"statusCheckRollup":[{"name":"rustfmt","conclusion":"FAILURE"}]},{"number":3,"statusCheckRollup":[{"name":"unit-tests","conclusion":"SUCCESS"}]}]'
    exit 0
fi
exit 1
EOF
chmod +x "$BIN/gh"

OUT=$(run_detector)
if grep -q '"kind":"wedge_detected"' "$AMBIENT" \
   && grep -q '"wedge_class":"W-014"' "$AMBIENT" \
   && grep -q '"commit":"deadbeef1234"' "$AMBIENT" \
   && grep -q '"result":"detected"' "$AMBIENT" \
   && grep -q '"failure_class":"permanent"' "$AMBIENT" \
   && grep -q '"gh_calls":1' "$AMBIENT"; then
    ok "2 failing PRs → wedge_detected W-014 + scan_completed permanent, gh_calls=1"
else
    fail "expected W-014 detection (ambient=$(cat "$AMBIENT"))"
fi

# ── Test 5: --check-only never emits, exits 1 on detect ────────────────────
echo "--- Test 5: --check-only exits 1 on detection, emits nothing ---"
> "$AMBIENT"
env PATH="$BIN:$PATH" CHUMP_REPO_ROOT="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$DETECTOR" --check-only > /dev/null 2>&1
RC=$?
if [[ "$RC" -eq 1 ]] && [[ ! -s "$AMBIENT" ]]; then
    ok "--check-only: rc=1 on detect, no events emitted"
else
    fail "expected rc=1 + no emits (rc=$RC, ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 6: git command missing → transient failure ────────────────────────
echo "--- Test 6: git not on PATH → scan_completed error, failure_class=transient ---"
EMPTYBIN="$TMP/emptybin"
mkdir -p "$EMPTYBIN"
# Symlink the coreutils the detector itself needs (date/mkdir/grep/sed/head/
# cat/dirname) into a git-and-gh-free PATH — this simulates "git missing"
# without also removing the shell utilities the script depends on.
for tool in bash date mkdir grep sed head cat dirname mktemp rm cp mv basename; do
    src="$(command -v "$tool" 2>/dev/null)" && ln -sf "$src" "$EMPTYBIN/$tool"
done
> "$AMBIENT"
OUT=$(env PATH="$EMPTYBIN" CHUMP_REPO_ROOT="$FAKE" CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$DETECTOR" 2>&1)
if grep -q '"failure_class":"transient"' "$AMBIENT" && grep -q '"reason":"git not on PATH"' "$AMBIENT"; then
    ok "missing git → transient failure_class recorded"
else
    fail "expected transient failure (ambient=$(cat "$AMBIENT" 2>/dev/null))"
fi

# ── Test 7: timeout → transient, scan_timeout event ─────────────────────────
echo "--- Test 7: git log exceeds timeout budget → scan_timeout, failure_class=transient ---"
if command -v timeout >/dev/null 2>&1; then
    cat > "$BIN/git" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == "log" ]]; then
    sleep 3
    exit 0
fi
exec /usr/bin/git "$@"
EOF
    chmod +x "$BIN/git"
    W014_TIMEOUT_S=1 OUT=$(run_detector)
    if grep -q '"kind":"toolchain_ratchet_scan_timeout"' "$AMBIENT" \
       && grep -q '"failure_class":"transient"' "$AMBIENT"; then
        ok "slow git log → scan_timeout with failure_class=transient"
    else
        fail "expected scan_timeout (ambient=$(cat "$AMBIENT"))"
    fi
else
    echo "  SKIP: 'timeout' binary not available on this system"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
