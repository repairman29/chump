#!/usr/bin/env bash
# test-modern-rust-toolchain.sh — INFRA-2242.
#
# Validates the 3-modernization bundle:
#   1. rust-toolchain.toml exists at repo root, pins stable channel +
#      required components (rustfmt, clippy, llvm-tools-preview).
#   2. scripts/setup/install-sccache.sh emits mold linker rustflags for
#      both Linux targets (x86_64 + aarch64) — gated, NOT global, so
#      macOS isn't broken.
#   3. scripts/setup/install-sccache.sh emits cranelift codegen-backend
#      configured for [profile.dev] only — release stays llvm.
#
# Exit 0 — all three assertions hold.
# Exit 1 — any assertion fails (prints which one).
# Exit 2 — bad environment (missing file).
#
# This is a static-content check; does not invoke cargo, so it runs in
# <1s and is preflight-eligible. The actual compile-speed measurement
# happens out-of-band per AC item 7 (operator tags 3 PRs, compares
# cold-cache wall-clock).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

fail=0

# ── Assertion 1: rust-toolchain.toml ─────────────────────────────────────────
toolchain_file="rust-toolchain.toml"
if [[ ! -f "$toolchain_file" ]]; then
    echo "[test-modern-rust-toolchain] FAIL: $toolchain_file missing"
    exit 1
fi

if ! grep -qE '^channel\s*=\s*"stable"' "$toolchain_file"; then
    echo "[test-modern-rust-toolchain] FAIL: $toolchain_file does not pin channel=\"stable\""
    fail=1
fi

for component in rustfmt clippy llvm-tools-preview; do
    if ! grep -q "\"$component\"" "$toolchain_file"; then
        echo "[test-modern-rust-toolchain] FAIL: $toolchain_file missing component \"$component\""
        fail=1
    fi
done

# ── Assertion 2: mold linker gated on Linux targets only ─────────────────────
sccache_script="scripts/setup/install-sccache.sh"
if [[ ! -f "$sccache_script" ]]; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing"
    exit 2
fi

if ! grep -q '\[target.x86_64-unknown-linux-gnu\]' "$sccache_script"; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing [target.x86_64-unknown-linux-gnu]"
    fail=1
fi

if ! grep -q '\[target.aarch64-unknown-linux-gnu\]' "$sccache_script"; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing [target.aarch64-unknown-linux-gnu]"
    fail=1
fi

if ! grep -q 'fuse-ld=mold' "$sccache_script"; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing fuse-ld=mold rustflag"
    fail=1
fi

# Negative assertion: mold must NOT appear in a global [build] section.
# We check by ensuring fuse-ld=mold lines all sit under a [target.*-linux-*]
# heading (closest preceding [section] header is a Linux target).
mold_lines=$(grep -n 'fuse-ld=mold' "$sccache_script" | cut -d: -f1)
for ln in $mold_lines; do
    preceding_section=$(awk -v ln="$ln" 'NR<ln && /^\[/ {sec=$0} END {print sec}' "$sccache_script")
    if [[ "$preceding_section" != "[target.x86_64-unknown-linux-gnu]" && "$preceding_section" != "[target.aarch64-unknown-linux-gnu]" ]]; then
        echo "[test-modern-rust-toolchain] FAIL: fuse-ld=mold at line $ln is under '$preceding_section', must be under [target.*-linux-gnu]"
        fail=1
    fi
done

# ── Assertion 3: cranelift on dev only ───────────────────────────────────────
if ! grep -qE '^\s*\[profile\.dev\]' "$sccache_script"; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing [profile.dev] section"
    fail=1
fi

if ! grep -q 'codegen-backend\s*=\s*"cranelift"' "$sccache_script"; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing codegen-backend=\"cranelift\""
    fail=1
fi

# Negative assertion: cranelift must NOT appear in [profile.release].
release_lines=$(awk '/^\[profile\.release\]/,/^\[/' "$sccache_script" | grep -c 'cranelift' || true)
if [[ "${release_lines:-0}" != "0" ]]; then
    echo "[test-modern-rust-toolchain] FAIL: cranelift codegen leaked into [profile.release] — release must stay llvm"
    fail=1
fi

# Required [unstable] codegen-backend = true enabler for per-profile syntax.
if ! grep -qE '^\s*\[unstable\]' "$sccache_script"; then
    echo "[test-modern-rust-toolchain] FAIL: $sccache_script missing [unstable] section (required for per-profile codegen-backend)"
    fail=1
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "[test-modern-rust-toolchain] OK — rust-toolchain.toml pinned, mold gated to Linux, cranelift dev-only."
exit 0
