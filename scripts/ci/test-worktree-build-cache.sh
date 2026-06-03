#!/usr/bin/env bash
# scripts/ci/test-worktree-build-cache.sh — INFRA-2183
#
# Validates atomic_claim::provision_worktree_build_cache: a claimed worktree
# gets a .cargo/config.toml carrying the shared sccache `rustc-wrapper` PLUS a
# per-worktree CARGO_TARGET_DIR (isolated, predictably named so the
# cargo-target-reaper INFRA-2125/2188 can reap it). Without this, /tmp worktrees
# build COLD (the gitignored host .cargo/config.toml doesn't propagate via
# `git worktree add`), which is what was reaping dispatched Sonnets on long
# cold builds.
#
# Structure: fast grep invariants first (no build), then the faithful Rust unit
# tests (which actually call provision_worktree_build_cache against a temp dir
# and assert the written config.toml — exactly AC#4's "creates a temp worktree
# ... asserts .cargo/config.toml present with rustc-wrapper and CARGO_TARGET_DIR").

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || exit 2
SRC="src/worktree_build_cache.rs"
REG="docs/observability/EVENT_REGISTRY.yaml"
PASS=0; FAIL=0
_p() { echo "[PASS] $1"; PASS=$((PASS+1)); }
_f() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== test-worktree-build-cache.sh (INFRA-2183) ==="

# ── Fast structural invariants (no build) ───────────────────────────────────
[[ -f "$SRC" ]] && _p "src: worktree_build_cache.rs present" || _f "src: worktree_build_cache.rs MISSING"
grep -q 'pub fn provision_worktree_build_cache' "$SRC" 2>/dev/null \
    && _p "api: provision_worktree_build_cache() exists" || _f "api: provision fn MISSING"
grep -qE 'CARGO_TARGET_DIR|target-dir' "$SRC" 2>/dev/null \
    && _p "isolation: per-worktree target-dir wired (no parallel-Sonnet collision)" || _f "isolation: target-dir MISSING"
grep -q 'rustc-wrapper' "$SRC" 2>/dev/null \
    && _p "cache: rustc-wrapper (shared sccache) preserved into the worktree config" || _f "cache: rustc-wrapper handling MISSING"
grep -q 'worktree_build_cache_provisioned' "$SRC" 2>/dev/null \
    && _p "obs: worktree_build_cache_provisioned emitted" || _f "obs: provisioned event MISSING"
grep -q 'worktree_build_cache_skip' "$SRC" 2>/dev/null \
    && _p "obs: worktree_build_cache_skip (with reason) emitted" || _f "obs: skip event MISSING"
grep -q 'provision_worktree_build_cache' src/atomic_claim.rs 2>/dev/null \
    && _p "wiring: atomic_claim invokes the provisioner on worktree creation" || _f "wiring: atomic_claim does NOT call provisioner"
{ grep -q 'kind: worktree_build_cache_provisioned' "$REG" && grep -q 'kind: worktree_build_cache_skip' "$REG"; } 2>/dev/null \
    && _p "registry: both event kinds registered in EVENT_REGISTRY.yaml" || _f "registry: event kind(s) NOT registered"

# ── Faithful behavior: the Rust unit tests provision a temp worktree + assert ─
# the written .cargo/config.toml. Skippable in cargo-less CI lanes via env.
if [[ "${CHUMP_WTBC_CARGO_DISABLED:-0}" == "1" ]]; then
    echo "[SKIP] cargo unit tests (CHUMP_WTBC_CARGO_DISABLED=1)"
elif command -v cargo >/dev/null 2>&1; then
    if PATH="$HOME/.cargo/bin:$PATH" cargo test worktree_build_cache 2>&1 | tail -25 | grep -qE 'test result: ok'; then
        _p "rust: worktree_build_cache unit tests pass (provision + config.toml + unique target-dir)"
    else
        _f "rust: worktree_build_cache unit tests FAILED"
    fi
else
    echo "[SKIP] cargo not on PATH — structural checks only"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
