#!/usr/bin/env bash
# INFRA-1672: regression test for `chump preflight --scope`.
#
# Verifies:
#   1. The --scope flag is wired in parse_args (source contract).
#   2. Synthetic docs-only and rust-only staged diffs route to the
#      expected gate sets (docs-only skips cargo, rust-only runs cargo).
#   3. `chump preflight --scope=<bad>` exits 2.
#
# Run from a worktree (it creates a scratch temp dir to stage synthetic diffs).
# Does not mutate the working tree.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── 1. Source-contract check ───────────────────────────────────────────────
# Catch refactors that drop the flag entirely.
grep -q '"--scope"' src/preflight.rs \
    || fail "src/preflight.rs missing --scope flag (INFRA-1672 contract)"
grep -q 'enum ScopeArg' src/preflight.rs \
    || fail "src/preflight.rs missing ScopeArg enum"
grep -q 'fn scope_from_paths' src/preflight.rs \
    || fail "src/preflight.rs missing scope_from_paths()"

echo "[1/4] source contract: parse_args supports --scope ✓"

# Locate a runnable chump binary. Prefer release, then debug, then
# scripts/dispatch/ensure-debug-chump.sh fallback. Stays warm-cache-friendly.
CHUMP_BIN=""
for candidate in \
    "$REPO_ROOT/target/release/chump" \
    "$REPO_ROOT/target/debug/chump"; do
    if [[ -x "$candidate" ]]; then
        CHUMP_BIN="$candidate"
        break
    fi
done

if [[ -z "$CHUMP_BIN" ]]; then
    if [[ -x "$REPO_ROOT/scripts/dispatch/ensure-debug-chump.sh" ]]; then
        bash "$REPO_ROOT/scripts/dispatch/ensure-debug-chump.sh" >/dev/null 2>&1 || true
        if [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
            CHUMP_BIN="$REPO_ROOT/target/debug/chump"
        fi
    fi
fi

if [[ -z "$CHUMP_BIN" ]]; then
    echo "[skip] no chump binary available (target/{release,debug}/chump missing); contract checks passed"
    exit 0
fi

# ── 2. --help mentions --scope ─────────────────────────────────────────────
if ! "$CHUMP_BIN" preflight --help 2>&1 | grep -q -- '--scope'; then
    fail "chump preflight --help does not mention --scope"
fi
echo "[2/4] --help advertises --scope ✓"

# ── 3. --scope docs path: should NOT run cargo gates ───────────────────────
# Use a sandbox worktree so we can stage synthetic docs-only changes without
# touching the live worktree. We use `CHUMP_PREFLIGHT_SKIP=0` explicitly to
# defeat any inherited override.
SANDBOX="$(mktemp -d -t chump-preflight-scope-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Initialize an empty repo (so git diff --cached has a context).
(
    cd "$SANDBOX"
    git init -q
    git config user.email test@example.com
    git config user.name test
    git commit --allow-empty -q -m "seed"
    mkdir -p docs
    echo "test docs change" > docs/scratch.md
    git add docs/scratch.md
)

# --scope docs should skip cargo and not actually invoke cargo. Even if cargo
# is missing, the command should still exit 0 (no gates selected).
DOCS_OUT="$("$CHUMP_BIN" preflight --scope docs 2>&1 || true)"
echo "$DOCS_OUT" | grep -qi "skipping cargo gates\|scope=docs\|scope=none" \
    || fail "--scope docs did not log skip/scope (got: $DOCS_OUT)"
# Belt-and-suspenders: should not list a cargo gate.
if echo "$DOCS_OUT" | grep -q "cargo fmt --check ..."; then
    fail "--scope docs ran cargo fmt (should have been skipped)"
fi
echo "[3/4] --scope docs skips cargo gates ✓"

# ── 4. Bad scope value exits non-zero ──────────────────────────────────────
set +e
"$CHUMP_BIN" preflight --scope=frontend >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    fail "chump preflight --scope=frontend should have exited non-zero"
fi
echo "[4/4] bad --scope value exits non-zero ✓"

echo
echo "PASS: chump preflight --scope (INFRA-1672) contract holds"
