#!/usr/bin/env bash
# scripts/ci/test-cargo-test-rerun-skip.sh — INFRA-1612
#
# Verifies that cargo-test-with-rerun.sh preserves a second `--` in CMD
# when the caller passes: rerun.sh -- cargo test ... -- --skip NAME
# (the pre-push hook does exactly this when KNOWN_FLAKES.yaml has entries).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RERUN="$REPO_ROOT/scripts/ci/cargo-test-with-rerun.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -x "$RERUN" ]] || fail "cargo-test-with-rerun.sh missing or not executable: $RERUN"

# ── Test 1: second `--` is preserved in CMD ───────────────────────────────────
# Inject a stub "cargo" that echoes its args so we can inspect what CMD was run.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cargo" <<'EOF'
#!/usr/bin/env bash
# Stub: echo args separated by '|'
printf '%s' "$*"
EOF
chmod +x "$WORK/cargo"

# Simulate CHUMP_FLAKE_AUTORERUN=0 so the script just exec's CMD — no flake logic.
OUT=$(PATH="$WORK:$PATH" CHUMP_FLAKE_AUTORERUN=0 \
    bash "$RERUN" -- cargo test --quiet -- --skip some_test 2>/dev/null)

# Expected: "test --quiet -- --skip some_test"
if echo "$OUT" | grep -q -- "-- --skip some_test"; then
    ok "second '--' preserved in CMD: cargo test sees '-- --skip some_test'"
else
    fail "second '--' was dropped. CMD got: '$OUT' (expected '-- --skip some_test')"
fi

# ── Test 2: no --skip → CMD without any extra `--` ───────────────────────────
OUT2=$(PATH="$WORK:$PATH" CHUMP_FLAKE_AUTORERUN=0 \
    bash "$RERUN" -- cargo test --quiet 2>/dev/null)

if echo "$OUT2" | grep -q "test --quiet"; then
    ok "no --skip: CMD passes 'cargo test --quiet' correctly"
else
    fail "basic CMD broken. Got: '$OUT2'"
fi

# ── Test 3: missing `--` → usage error (exit 2) ───────────────────────────────
set +e
bash "$RERUN" cargo test --quiet 2>/dev/null
EXIT=$?
set -e
if [[ "$EXIT" -eq 2 ]]; then
    ok "missing '--' separator → exit 2 (usage error)"
else
    fail "expected exit 2 when '--' separator missing, got $EXIT"
fi

# ── Source check: INFRA-1612 guard present ────────────────────────────────────
grep -q 'SEP_FOUND.*==.*"0".*&&.*"--"' "$RERUN" \
    || fail "INFRA-1612 fix not found in $RERUN (missing SEP_FOUND==0 guard)"
ok "INFRA-1612 fix present in script (SEP_FOUND==0 guard)"

echo ""
echo "All 4 checks PASSED — INFRA-1612 --skip separator fix works"
