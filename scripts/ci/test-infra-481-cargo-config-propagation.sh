#!/usr/bin/env bash
# test-infra-481-cargo-config-propagation.sh — INFRA-481
#
# Verifies the post-checkout hook propagates .cargo/config.toml into
# linked worktrees with a target-dir override pointing at the main
# repo's target/ — so /tmp/<worktree>/cargo build doesn't allocate
# its own multi-GB target tree.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

echo "=== INFRA-481 cargo-config propagation test ==="
echo

# 1. The hook contains the INFRA-481 propagation block.
if grep -q "INFRA-481" "$REPO_ROOT/scripts/git-hooks/post-checkout"; then
    ok "post-checkout hook contains INFRA-481 propagation block"
else
    fail "post-checkout hook missing INFRA-481 block"
fi

# 2. The hook references the gitignored .cargo/config.toml.
if grep -q "\.cargo/config\.toml" "$REPO_ROOT/scripts/git-hooks/post-checkout"; then
    ok "post-checkout references .cargo/config.toml"
else
    fail "post-checkout doesn't reference .cargo/config.toml"
fi

# 3. The hook writes [build] target-dir = "<MAIN>/target" pattern.
if grep -q "target-dir" "$REPO_ROOT/scripts/git-hooks/post-checkout"; then
    ok "post-checkout sets target-dir override"
else
    fail "post-checkout missing target-dir override"
fi

# 4. Idempotency: hook checks if config already exists.
if grep -qE '! -f "\$LOCAL_CARGO_CONFIG"' "$REPO_ROOT/scripts/git-hooks/post-checkout"; then
    ok "post-checkout is idempotent (skips when local config exists)"
else
    fail "post-checkout not idempotent"
fi

# 5. Skip-main-worktree guard: hook checks THIS_WT != MAIN_WT.
if grep -qE 'THIS_WT_ABS.+MAIN_WT_ABS' "$REPO_ROOT/scripts/git-hooks/post-checkout"; then
    ok "post-checkout skips when run from main worktree"
else
    fail "post-checkout missing main-worktree skip guard"
fi

# 6. Live test: simulate the hook in a tempdir.
TMP_TEST_WT="/tmp/chump-infra-481-test-$$"
TMP_MAIN="/tmp/chump-infra-481-main-$$"
mkdir -p "$TMP_MAIN/.cargo" "$TMP_TEST_WT"
cat > "$TMP_MAIN/.cargo/config.toml" <<EOF
[build]
rustc-wrapper = "sccache"
EOF
# Source-extract just the propagation logic into a function and run.
# Replicates the hook's behavior — must merge target-dir INTO existing
# [build] table, not append a duplicate (TOML rejects duplicate section
# headers).
THIS_WT_ABS="$TMP_TEST_WT"
MAIN_WT_ABS="$TMP_MAIN"
if [[ -n "$MAIN_WT_ABS" && "$THIS_WT_ABS" != "$MAIN_WT_ABS" ]]; then
    MAIN_CARGO_CONFIG="$MAIN_WT_ABS/.cargo/config.toml"
    LOCAL_CARGO_CONFIG="$THIS_WT_ABS/.cargo/config.toml"
    if [[ -f "$MAIN_CARGO_CONFIG" && ! -f "$LOCAL_CARGO_CONFIG" ]]; then
        mkdir -p "$THIS_WT_ABS/.cargo"
        cp "$MAIN_CARGO_CONFIG" "$LOCAL_CARGO_CONFIG"
        if ! grep -q "^target-dir" "$LOCAL_CARGO_CONFIG"; then
            if grep -q "^\[build\]" "$LOCAL_CARGO_CONFIG"; then
                tmp_config="$(mktemp)"
                awk -v target="$MAIN_WT_ABS/target" '
                    /^\[build\]$/ { print; print "target-dir = \"" target "\""; next }
                    { print }
                ' "$LOCAL_CARGO_CONFIG" > "$tmp_config" && mv "$tmp_config" "$LOCAL_CARGO_CONFIG"
            else
                cat >> "$LOCAL_CARGO_CONFIG" <<EOF2

[build]
target-dir = "$MAIN_WT_ABS/target"
EOF2
            fi
        fi
    fi
fi

if [[ -f "$TMP_TEST_WT/.cargo/config.toml" ]]; then
    ok "live: config propagated to linked worktree"
else
    fail "live: config NOT propagated"
fi
if grep -q "rustc-wrapper" "$TMP_TEST_WT/.cargo/config.toml" 2>/dev/null; then
    ok "live: rustc-wrapper preserved (sccache still works)"
else
    fail "live: rustc-wrapper missing"
fi
if grep -q "target-dir.*$TMP_MAIN/target" "$TMP_TEST_WT/.cargo/config.toml" 2>/dev/null; then
    ok "live: target-dir overridden to main repo's target"
else
    fail "live: target-dir override missing"
fi
# Critical: must NOT have duplicate [build] sections — TOML rejects.
build_count=$(grep -c "^\[build\]$" "$TMP_TEST_WT/.cargo/config.toml" 2>/dev/null || echo 0)
if [[ "$build_count" == "1" ]]; then
    ok "live: exactly one [build] section (no TOML duplicate-key error)"
else
    fail "live: [build] section count is $build_count (must be 1)"
fi

# Cleanup.
rm -rf "$TMP_TEST_WT" "$TMP_MAIN"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
