#!/usr/bin/env bash
# test-default-flip-guard.sh — INFRA-762 unit tests.
#
# Verifies pre-commit-default-flip.sh detects:
#   1. unwrap_or(false) → unwrap_or(true) flip in *_flags.rs
#   2. const FOO: bool flip
#   3. Lists candidate stale tests in another file
#   4. Skips when no flip in scoped files
#   5. CHUMP_DEFAULT_FLIP_CHECK=0 silently skips
#   6. Skips when staged files don't match the *flags*/*config* glob
#
# The guard is advisory (exit 0 in all cases); we assert on its output
# being present/absent, not on the exit code.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-762 default-flip pre-commit guard tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-commit-default-flip.sh"

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: hook not executable: $HOOK"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/src"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t

# Helper: run hook from inside the test repo.
run_hook() {
    cd "$REPO" || return 2
    OUT=$("$HOOK" 2>&1)
    RC=$?
    cd - >/dev/null || true
    echo "$OUT"
    return "$RC"
}

# ── Seed: a flag file with `unwrap_or(false)` and a parallel test file ─────
cat > "$REPO/src/env_flags.rs" <<'RS'
pub fn chump_bypass_neuromod() -> bool {
    std::env::var("CHUMP_BYPASS_NEUROMOD")
        .map(|v| v == "1")
        .unwrap_or(false)
}
RS

cat > "$REPO/src/neuromodulation.rs" <<'RS'
pub fn neuromod_enabled() -> bool {
    !crate::env_flags::chump_bypass_neuromod()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn neuromod_enabled_default_on() {
        std::env::remove_var("CHUMP_NEUROMOD_ENABLED");
        assert!(neuromod_enabled());
    }
}
RS

git -C "$REPO" add . && git -C "$REPO" commit -q -m "seed"

# ── Test 1: flip unwrap_or(false) → unwrap_or(true) in env_flags.rs ─────────
echo "--- Test 1: unwrap_or(false)→(true) flip in env_flags.rs warns about parallel test ---"
sed -i.bak 's/unwrap_or(false)/unwrap_or(true)/' "$REPO/src/env_flags.rs"
rm -f "$REPO/src/env_flags.rs.bak"
git -C "$REPO" add src/env_flags.rs

OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] \
   && echo "$OUT" | grep -q "default-flip detected" \
   && echo "$OUT" | grep -q "chump_bypass_neuromod" \
   && echo "$OUT" | grep -q "neuromodulation.rs"; then
    ok "flip detected and parallel test file named"
else
    fail "expected flip warning citing neuromodulation.rs (rc=$RC, out=$OUT)"
fi

git -C "$REPO" reset -q HEAD src/env_flags.rs

# ── Test 2: const FOO: bool flip ────────────────────────────────────────────
echo "--- Test 2: const bool flip in *_config.rs ---"
cat > "$REPO/src/timing_config.rs" <<'RS'
pub const ENABLE_FAST_PATH: bool = false;

pub fn use_fast_path() -> bool { ENABLE_FAST_PATH }
RS
git -C "$REPO" add src/timing_config.rs
git -C "$REPO" commit -q -m "add config"

# Now flip the const.
sed -i.bak 's/ENABLE_FAST_PATH: bool = false/ENABLE_FAST_PATH: bool = true/' "$REPO/src/timing_config.rs"
rm -f "$REPO/src/timing_config.rs.bak"
git -C "$REPO" add src/timing_config.rs

OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] \
   && echo "$OUT" | grep -q "default-flip detected" \
   && echo "$OUT" | grep -q "ENABLE_FAST_PATH"; then
    ok "const bool flip detected and named"
else
    fail "expected const-flip warning naming ENABLE_FAST_PATH (rc=$RC, out=$OUT)"
fi

git -C "$REPO" reset -q HEAD src/timing_config.rs

# ── Test 3: no flip in scoped files → silent skip ───────────────────────────
echo "--- Test 3: edit unrelated file → no warning ---"
cat > "$REPO/src/unrelated.rs" <<'RS'
pub fn unrelated() {
    println!("hello");
}
RS
git -C "$REPO" add src/unrelated.rs

OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "unrelated file edit produced no warning"
else
    fail "unrelated file should be silent (rc=$RC, out=$OUT)"
fi

git -C "$REPO" reset -q HEAD src/unrelated.rs

# ── Test 4: bypass env silently skips ───────────────────────────────────────
echo "--- Test 4: CHUMP_DEFAULT_FLIP_CHECK=0 silences guard ---"
sed -i.bak 's/unwrap_or(true)/unwrap_or(false)/' "$REPO/src/env_flags.rs" 2>/dev/null || true
sed -i.bak 's/unwrap_or(false)/unwrap_or(true)/' "$REPO/src/env_flags.rs"
rm -f "$REPO/src/env_flags.rs.bak"
git -C "$REPO" add src/env_flags.rs

OUT=$(CHUMP_DEFAULT_FLIP_CHECK=0 run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "bypass env silenced the guard"
else
    fail "bypass env should silence (rc=$RC, out=$OUT)"
fi

git -C "$REPO" reset -q HEAD src/env_flags.rs

# ── Test 5: file outside the *flags*/*config* glob is ignored ───────────────
echo "--- Test 5: flip in src/util.rs (outside glob) → no warning ---"
cat > "$REPO/src/util.rs" <<'RS'
pub fn maybe() -> bool {
    std::env::var("X").map(|v| v == "1").unwrap_or(false)
}
RS
git -C "$REPO" add src/util.rs
git -C "$REPO" commit -q -m "util"

sed -i.bak 's/unwrap_or(false)/unwrap_or(true)/' "$REPO/src/util.rs"
rm -f "$REPO/src/util.rs.bak"
git -C "$REPO" add src/util.rs

OUT=$(run_hook 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && [[ -z "$OUT" ]]; then
    ok "out-of-glob file silently skipped"
else
    fail "util.rs (outside glob) should not warn (rc=$RC, out=$OUT)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
