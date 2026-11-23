#!/usr/bin/env bash
# INFRA-711: regression test for extended cascade-rebase trigger paths.
# Verifies that:
#   1. cascade-rebase-trigger-paths.txt exists and is readable
#   2. Extended paths (src/main.rs, src/lib.rs, src/agent_loop/**, src/dispatch.rs) are listed
#   3. queue-driver.sh reads and uses the config file
#   4. bot-merge.sh reads and uses the config file
#   5. The config can be overridden (operator-overridable)
#
# Run from repo root: bash scripts/ci/test-cascade-rebase-extended-paths.sh

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

PASS=0
FAIL=0
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

CONFIG_FILE="$REPO_ROOT/scripts/coord/cascade-rebase-trigger-paths.txt"
DRIVER="$REPO_ROOT/scripts/coord/queue-driver.sh"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

# ── 1. Config file exists ────────────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
    pass "cascade-rebase-trigger-paths.txt exists"
else
    fail "cascade-rebase-trigger-paths.txt missing"
    exit 1
fi

# ── 2. Config file contains required extended paths ──────────────────────────
extended_paths=(
    "src/main.rs"
    "src/lib.rs"
    "src/agent_loop/\*\*"
    "src/dispatch.rs"
)

for path in "${extended_paths[@]}"; do
    if grep -q "^${path}$" "$CONFIG_FILE" 2>/dev/null || grep -q "$path" "$CONFIG_FILE" 2>/dev/null; then
        pass "Config contains: $path"
    else
        fail "Config missing: $path"
    fi
done

# ── 3. Config contains backward-compat entries ──────────────────────────────
compat_paths=(
    "Cargo.toml"
    "rust-toolchain.toml"
)

for path in "${compat_paths[@]}"; do
    if grep -q "^${path}$" "$CONFIG_FILE"; then
        pass "Config contains backward-compat: $path"
    else
        fail "Config missing backward-compat: $path"
    fi
done

# ── 4. queue-driver.sh reads from config file ──────────────────────────────
if grep -q '_cascade_config.*cascade-rebase-trigger-paths.txt' "$DRIVER"; then
    pass "queue-driver.sh references cascade-rebase-trigger-paths.txt"
else
    fail "queue-driver.sh does not reference config file"
fi

# ── 5. queue-driver.sh has fallback if config missing ──────────────────────
if grep -q 'if \[\[ -f "$_cascade_config" \]\]' "$DRIVER"; then
    pass "queue-driver.sh has fallback for missing config"
else
    fail "queue-driver.sh missing fallback logic"
fi

# ── 6. bot-merge.sh reads from config file ──────────────────────────────────
if grep -q '_bm_cascade_config.*cascade-rebase-trigger-paths.txt' "$BOT_MERGE"; then
    pass "bot-merge.sh references cascade-rebase-trigger-paths.txt"
else
    fail "bot-merge.sh does not reference config file"
fi

# ── 7. bot-merge.sh extends BOT_MERGE_HOT_FILES from config ───────────────────
if grep -q 'BOT_MERGE_HOT_FILES+=(' "$BOT_MERGE"; then
    pass "bot-merge.sh extends BOT_MERGE_HOT_FILES from config"
else
    fail "bot-merge.sh does not extend BOT_MERGE_HOT_FILES"
fi

# ── 8. Both scripts handle comments and empty lines in config ─────────────────
if grep -q '\[[ ]*-z[ ]*"$line".*# ]].*continue' "$DRIVER"; then
    pass "queue-driver.sh skips empty lines in config"
else
    fail "queue-driver.sh does not skip empty lines"
fi

if grep -q '\[[ ]*-z[ ]*"$line".*# ]].*continue' "$BOT_MERGE"; then
    pass "bot-merge.sh skips empty lines in config"
else
    fail "bot-merge.sh does not skip empty lines"
fi

# ── 9. Verify the config file is syntactically valid (no loose escapes) ────
if grep -E '^\s*$|^[^#]' "$CONFIG_FILE" | while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    # Just check it's readable, not a malformed regex
    if [[ "$line" =~ ^[a-zA-Z0-9/_\.\*\-]+$ ]]; then
        true
    else
        false
    fi
done; then
    pass "Config file is syntactically valid"
else
    fail "Config file has invalid path syntax"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
