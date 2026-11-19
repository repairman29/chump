#!/usr/bin/env bash
# test-bot-merge-hook-auto-install.sh — INFRA-209 unit tests.
#
# Verifies the auto-install block in scripts/coord/bot-merge.sh:
#   (1) Missing .git/hooks/pre-commit → install-hooks.sh runs
#   (2) Existing .git/hooks/pre-commit → install does NOT run (idempotent skip)
#   (3) CHUMP_AUTO_INSTALL_HOOKS=0 → suppressed even when missing
#   (4) Stale symlink → install runs (target missing)

set -euo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-209 bot-merge.sh hook auto-install tests ==="
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

if [ ! -x "$BOT_MERGE" ]; then
    echo "FATAL: $BOT_MERGE not executable"
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Extract just the auto-install block from bot-merge.sh and run it
# in isolation against a synthetic fake repo. Lets us avoid actually
# pushing or running cargo.
extract_install_block() {
    awk '/^# ── INFRA-209: ensure pre-commit hooks/,/^fi$/' "$BOT_MERGE"
}

setup_fake_repo() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir/scripts/setup"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name T
    # Stub install-hooks.sh as a logger so we can detect invocation.
    cat > "$dir/scripts/setup/install-hooks.sh" <<INSTALL_EOF
#!/usr/bin/env bash
echo "INSTALL_RAN" > "$dir/.install-receipt"
INSTALL_EOF
    chmod +x "$dir/scripts/setup/install-hooks.sh"
    rm -f "$dir/.install-receipt"
}

run_block() {
    local dir="$1"
    shift
    (
        cd "$dir"
        # Inherit env mutations (CHUMP_AUTO_INSTALL_HOOKS) from caller.
        eval "$(extract_install_block)"
    )
}

# ── Test 1: missing pre-commit → install runs ────────────────────────────────
echo "--- Test 1: missing .git/hooks/pre-commit → install runs ---"
DIR="$TMPDIR_BASE/repo1"
setup_fake_repo "$DIR"
[[ ! -f "$DIR/.git/hooks/pre-commit" ]] || rm -f "$DIR/.git/hooks/pre-commit"
run_block "$DIR" >/dev/null 2>&1
if [[ -f "$DIR/.install-receipt" ]]; then
    ok "Test 1: install-hooks.sh ran when pre-commit was missing"
else
    fail "Test 1: install-hooks.sh did NOT run when pre-commit was missing"
fi

# ── Test 2: existing pre-commit → install SKIPPED ────────────────────────────
echo "--- Test 2: existing .git/hooks/pre-commit → install SKIPPED ---"
DIR="$TMPDIR_BASE/repo2"
setup_fake_repo "$DIR"
echo "#!/bin/sh" > "$DIR/.git/hooks/pre-commit"
chmod +x "$DIR/.git/hooks/pre-commit"
run_block "$DIR" >/dev/null 2>&1
if [[ ! -f "$DIR/.install-receipt" ]]; then
    ok "Test 2: install-hooks.sh did NOT run when pre-commit was already present"
else
    fail "Test 2: install-hooks.sh ran spuriously"
fi

# ── Test 3: CHUMP_AUTO_INSTALL_HOOKS=0 suppresses even when missing ─────────
echo "--- Test 3: CHUMP_AUTO_INSTALL_HOOKS=0 suppresses install ---"
DIR="$TMPDIR_BASE/repo3"
setup_fake_repo "$DIR"
rm -f "$DIR/.git/hooks/pre-commit"
(
    export CHUMP_AUTO_INSTALL_HOOKS=0
    run_block "$DIR" >/dev/null 2>&1
)
if [[ ! -f "$DIR/.install-receipt" ]]; then
    ok "Test 3: kill-switch env suppressed install"
else
    fail "Test 3: kill-switch ignored — install ran despite env=0"
fi

# ── Test 4: stale symlink → install runs ─────────────────────────────────────
echo "--- Test 4: stale symlink (target missing) → install runs ---"
DIR="$TMPDIR_BASE/repo4"
setup_fake_repo "$DIR"
ln -s "$DIR/nonexistent-source" "$DIR/.git/hooks/pre-commit"
run_block "$DIR" >/dev/null 2>&1
if [[ -f "$DIR/.install-receipt" ]]; then
    ok "Test 4: install ran for stale symlink"
else
    fail "Test 4: install did NOT run for stale symlink"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
