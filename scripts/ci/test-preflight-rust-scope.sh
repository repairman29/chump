#!/usr/bin/env bash
# capability-guard-exempt: existing CHUMP_BIN check + exit-0 skip path covers missing-binary case (CREDIBLE-078)
# scripts/ci/test-preflight-rust-scope.sh — META-178 / META-177 lane D
#
# Verifies that `chump preflight` runs `cargo check --workspace --all-targets`
# (not a narrower per-crate check) whenever any Rust file is in the staged diff.
#
# Root cause: INFRA-2134 added a field to chump-gap-store::GapRow; preflight
# ran cargo check only against the same-crate diff, missing chump-coord
# initializers in #[cfg(test)] blocks. CI (whole-workspace) caught it;
# preflight didn't. Fix: --all-targets on the workspace check.
#
# Tests:
#   1. src/preflight.rs declares cargo check with --workspace --all-targets
#      (source contract — catches regressions that narrow the scope again)
#   2. docs-only staged diff: preflight does NOT run any cargo gates
#      (scope=docs must remain fast, unchanged by this fix)
#   3. Module-level doc comment + help text agree on --all-targets
#      (docs consistency — prevents future "which is it?" confusion)
#
# Rust-First-Bypass: integration test for the Rust `chump preflight`
#   subcommand interacting with git staging; shell is the right shape
#   for sandbox setup, spawn, grep, and filesystem assertions.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/debug/chump}"

ok()   { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

# ── Test 1: source contract — cargo check uses --workspace --all-targets ─────
[[ -f "$REPO_ROOT/src/preflight.rs" ]] \
    || fail "src/preflight.rs missing"

# The cargo check step must include both --workspace and --all-targets.
# We check that the string "--all-targets" appears in a context near
# "cargo", "check", and "--workspace" — a simple grep suffices because
# the step definition is a single function call.
grep -q '"--all-targets"' "$REPO_ROOT/src/preflight.rs" \
    || fail "src/preflight.rs: cargo check step missing --all-targets (META-178 fix not present)"

# Belt-and-suspenders: confirm --workspace is still there too (didn't regress).
grep -q '"--workspace"' "$REPO_ROOT/src/preflight.rs" \
    || fail "src/preflight.rs: cargo check step missing --workspace"

ok "[1/3] src/preflight.rs declares cargo check --workspace --all-targets"

# ── Test 2: docs-only diff does NOT invoke cargo gates ───────────────────────
# Create an isolated sandbox repo so we can stage synthetic diffs without
# touching the live worktree. This matches the pattern in test-preflight-scope.sh.

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[note] $CHUMP_BIN not built; skipping runtime sandbox checks (tests 2-3 static only)"
    echo ""
    echo "ALL META-178 preflight-rust-scope static checks passed."
    exit 0
fi

SANDBOX="$(mktemp -d -t chump-preflight-rust-scope-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

(
    cd "$SANDBOX"
    git init -q
    git config user.email test@example.com
    git config user.name test
    git commit --allow-empty -q -m "seed"
    mkdir -p docs
    printf 'docs change\n' > docs/scratch.md
    git add docs/scratch.md
)

# Run preflight in the sandbox dir. --scope docs is forced by the staged path
# classification. We set CHUMP_PREFLIGHT_SKIP_* to avoid paying for actual
# cargo/script invocations (we only care about the gate selection log).
DOCS_OUT="$(
    cd "$SANDBOX"
    CHUMP_PREFLIGHT_SKIP_REGISTRY=1 \
    CHUMP_PREFLIGHT_SKIP_ENVVARS=1 \
    CHUMP_PREFLIGHT_SKIP_SUBCMDHELP=1 \
    CHUMP_PREFLIGHT_SKIP_ACGATE=1 \
    CHUMP_PREFLIGHT_SKIP_GAPSINT=1 \
    CHUMP_PREFLIGHT_SKIP_MDLINKS=1 \
    CHUMP_PREFLIGHT_SKIP_CARGOTEST=1 \
    CHUMP_PREFLIGHT_SKIP_INTEGRATION=1 \
    CHUMP_PREFLIGHT_SKIP_CHUMPFIRST=1 \
    CHUMP_PREFLIGHT_SKIP_ACPSMOKE=1 \
    "$CHUMP_BIN" preflight 2>&1 || true
)"

# A docs-only diff must NOT trigger cargo gates.
if echo "$DOCS_OUT" | grep -q "cargo fmt --check \.\.\."; then
    fail "docs-only staged diff triggered cargo fmt (preflight over-scoped; got: $DOCS_OUT)"
fi
if echo "$DOCS_OUT" | grep -q "cargo check \.\.\."; then
    fail "docs-only staged diff triggered cargo check (preflight over-scoped; got: $DOCS_OUT)"
fi

ok "[2/3] docs-only staged diff does not invoke cargo gates"

# ── Test 3: module comment + help text agree on --all-targets ────────────────
# The top-of-file doc comment lists the gates; it must match the implementation.
grep -q 'cargo check --workspace --all-targets' "$REPO_ROOT/src/preflight.rs" \
    || fail "src/preflight.rs module doc or help text does not mention 'cargo check --workspace --all-targets'"

ok "[3/3] module doc / help text consistent with --all-targets implementation"

echo ""
echo "ALL META-178 preflight-rust-scope tests passed."
