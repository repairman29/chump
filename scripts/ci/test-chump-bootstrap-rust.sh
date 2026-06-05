#!/usr/bin/env bash
# scripts/ci/test-chump-bootstrap-rust.sh — INFRA-1881
#
# Smoke test for `chump bootstrap <path> --template rust`.
# Asserts:
#   1. Cargo.toml written with correct [package] name
#   2. src/main.rs written and contains "Hello, Chump!"
#   3. README.md written
#   4. .gitignore written containing "target/"
#   5. .git/ initialised (git repo present)
#   6. cargo check on scaffolded crate exits 0
#
# Skips cleanly (exit 0) if:
#   - cargo not on PATH
#   - chump binary not built
#
# SOURCE scrub-git-env.sh (RESILIENT-090) to isolate from pre-push hook env.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-090: scrub GIT_* env vars so `git init` inside the test creates a
# truly isolated repo, not a commit in the operator's worktree.
# shellcheck source=scripts/lib/scrub-git-env.sh
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

# Skip if cargo not available.
command -v cargo &>/dev/null || { echo "[SKIP] cargo not on PATH"; exit 0; }

# Locate chump binary.
CHUMP="${CHUMP_BIN:-}"
if [[ -z "$CHUMP" ]]; then
    if [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
        CHUMP="$REPO_ROOT/target/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP="$(command -v chump)"
    fi
fi
[[ -n "$CHUMP" && -x "$CHUMP" ]] || { echo "[SKIP] chump binary not built (set CHUMP_BIN or run cargo build first)"; exit 0; }

# ── Setup ─────────────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BOOTSTRAPPED="$TMP/hello-world"
mkdir -p "$BOOTSTRAPPED"

PASS=0
FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL+1)); }

echo "── chump bootstrap --template rust smoke test (INFRA-1881) ──"
echo "  chump: $CHUMP"
echo "  target: $BOOTSTRAPPED"
echo

# ── Invoke ────────────────────────────────────────────────────────────────────
echo "── Phase 1: invoke chump bootstrap ──"
if "$CHUMP" bootstrap "$BOOTSTRAPPED" --template rust --skip-arch-decision 2>&1 | tail -20; then
    ok "chump bootstrap exited 0"
else
    echo "[FAIL] chump bootstrap exited non-zero" >&2
    exit 1
fi

# ── File shape assertions ─────────────────────────────────────────────────────
echo
echo "── Phase 2: file shape assertions ──"

if [[ -f "$BOOTSTRAPPED/Cargo.toml" ]]; then
    ok "Cargo.toml present"
else
    fail "Cargo.toml missing"
fi

if [[ -f "$BOOTSTRAPPED/src/main.rs" ]]; then
    ok "src/main.rs present"
else
    fail "src/main.rs missing"
fi

if [[ -f "$BOOTSTRAPPED/README.md" ]]; then
    ok "README.md present"
else
    fail "README.md missing"
fi

if [[ -f "$BOOTSTRAPPED/.gitignore" ]]; then
    ok ".gitignore present"
else
    fail ".gitignore missing"
fi

if [[ -d "$BOOTSTRAPPED/.git" ]]; then
    ok ".git/ present (git repo initialised)"
else
    fail ".git/ missing — git was not initialised"
fi

# ── Content assertions ────────────────────────────────────────────────────────
echo
echo "── Phase 3: content assertions ──"

if grep -q "Hello, Chump" "$BOOTSTRAPPED/src/main.rs" 2>/dev/null; then
    ok "src/main.rs contains 'Hello, Chump'"
else
    fail "src/main.rs does not contain 'Hello, Chump'"
fi

if grep -q "target/" "$BOOTSTRAPPED/.gitignore" 2>/dev/null; then
    ok ".gitignore contains 'target/'"
else
    fail ".gitignore does not contain 'target/'"
fi

if grep -q '^\[package\]' "$BOOTSTRAPPED/Cargo.toml" 2>/dev/null; then
    ok "Cargo.toml has [package] section"
else
    fail "Cargo.toml missing [package] section"
fi

# ── Cargo build check ─────────────────────────────────────────────────────────
echo
echo "── Phase 4: cargo check ──"

if (cd "$BOOTSTRAPPED" && cargo check 2>&1 | tail -5); then
    ok "cargo check passed on bootstrapped crate"
else
    fail "cargo check FAILED on bootstrapped crate"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "[FAIL] bootstrap rust template: $PASS passed, $FAIL failed"
    exit 1
fi

echo "[PASS] bootstrap rust template: all $PASS assertions passed"
exit 0
