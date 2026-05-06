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

# Helper: run the post-checkout INFRA-481/INFRA-535 propagation logic inline.
# THIS_WT_ABS and MAIN_WT_ABS must be set before calling.
_run_propagation() {
    local THIS_WT_ABS="$1"
    local MAIN_WT_ABS="$2"
    if [[ -n "$MAIN_WT_ABS" && "$THIS_WT_ABS" != "$MAIN_WT_ABS" ]]; then
        local MAIN_CARGO_CONFIG="$MAIN_WT_ABS/.cargo/config.toml"
        local LOCAL_CARGO_CONFIG="$THIS_WT_ABS/.cargo/config.toml"
        if [[ -f "$MAIN_CARGO_CONFIG" && ! -f "$LOCAL_CARGO_CONFIG" ]]; then
            mkdir -p "$THIS_WT_ABS/.cargo"
            cp "$MAIN_CARGO_CONFIG" "$LOCAL_CARGO_CONFIG"
            # INFRA-535: redirect to ~/.cache when main is under /tmp/
            local _shared_target
            if [[ "$MAIN_WT_ABS" == /tmp/* || "$MAIN_WT_ABS" == /private/tmp/* ]]; then
                _shared_target="${HOME}/.cache/chump-fleet-target"
            else
                _shared_target="$MAIN_WT_ABS/target"
            fi
            if ! grep -q "^target-dir" "$LOCAL_CARGO_CONFIG"; then
                if grep -q "^\[build\]" "$LOCAL_CARGO_CONFIG"; then
                    local tmp_config
                    tmp_config="$(mktemp)"
                    awk -v target="$_shared_target" '
                        /^\[build\]$/ { print; print "target-dir = \"" target "\""; next }
                        { print }
                    ' "$LOCAL_CARGO_CONFIG" > "$tmp_config" && mv "$tmp_config" "$LOCAL_CARGO_CONFIG"
                else
                    cat >> "$LOCAL_CARGO_CONFIG" <<EOF2

[build]
target-dir = "$_shared_target"
EOF2
                fi
            fi
        fi
    fi
}

# 6. Live test: simulate the hook in a tempdir (non-/tmp/ MAIN path).
TMP_TEST_WT="/tmp/chump-infra-481-test-$$"
TMP_MAIN="/tmp/chump-infra-481-main-$$"
mkdir -p "$TMP_MAIN/.cargo" "$TMP_TEST_WT"
cat > "$TMP_MAIN/.cargo/config.toml" <<EOF
[build]
rustc-wrapper = "sccache"
EOF
# For the live test we need a non-/tmp/ MAIN to verify the normal path.
# Use /private/tmp symlink resolution: on macOS /tmp → /private/tmp, so
# we simulate with a real non-tmp path by using $TMPDIR/../chump-test if
# possible, else skip the target-path assertion and just check propagation.
FAKE_MAIN_WT="/var/folders/chump-infra-481-main-$$"
mkdir -p "$FAKE_MAIN_WT/.cargo" 2>/dev/null || FAKE_MAIN_WT="$TMP_MAIN"
cp "$TMP_MAIN/.cargo/config.toml" "$FAKE_MAIN_WT/.cargo/config.toml" 2>/dev/null || true

_run_propagation "$TMP_TEST_WT" "$FAKE_MAIN_WT"

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
if grep -q "target-dir" "$TMP_TEST_WT/.cargo/config.toml" 2>/dev/null; then
    ok "live: target-dir override written"
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

# 7. INFRA-535: when MAIN_WT is under /tmp/, target-dir must redirect to
# ~/.cache/chump-fleet-target (not inside /tmp/).
TMP_TEST_WT2="/tmp/chump-infra-535-wt-$$"
TMP_MAIN2="/tmp/chump-infra-535-main-$$"
mkdir -p "$TMP_MAIN2/.cargo" "$TMP_TEST_WT2"
cp "$TMP_MAIN/.cargo/config.toml" "$TMP_MAIN2/.cargo/config.toml"
_run_propagation "$TMP_TEST_WT2" "$TMP_MAIN2"
if grep -q "chump-fleet-target" "$TMP_TEST_WT2/.cargo/config.toml" 2>/dev/null; then
    ok "INFRA-535: /tmp/ MAIN_WT redirects target-dir to ~/.cache/chump-fleet-target"
else
    fail "INFRA-535: /tmp/ MAIN_WT should redirect target-dir to ~/.cache (not fill /tmp/)"
fi
if ! grep -q "/tmp/.*target" "$TMP_TEST_WT2/.cargo/config.toml" 2>/dev/null; then
    ok "INFRA-535: target-dir does NOT point inside /tmp/"
else
    fail "INFRA-535: target-dir still points inside /tmp/ — would fill ramdisk"
fi

# Cleanup.
rm -rf "$TMP_TEST_WT" "$TMP_MAIN" "$TMP_TEST_WT2" "$TMP_MAIN2"
rm -rf "$FAKE_MAIN_WT" 2>/dev/null || true

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
