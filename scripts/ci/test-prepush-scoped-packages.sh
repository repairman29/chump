#!/usr/bin/env bash
# scripts/ci/test-prepush-scoped-packages.sh — INFRA-8154 regression.
#
# Verifies:
#   1. Leaf/single-crate change selects that crate + its workspace reverse deps.
#   2. Workspace-wide files (Cargo.lock, root Cargo.toml, workspace-hack/,
#      scripts/git-hooks/pre-push) select the full workspace.
#   3. Docs-only or scripts-only diffs select MODE=none (no cargo test locally).
#   4. Mutant 1 (dropping reverse-dep expansion) fails the test.
#   5. Mutant 2 (dropping workspace-wide trigger) fails the test.

set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

echo "=== INFRA-8154: pre-push scoped Rust package selection ==="

select_for() {
    local files="$1"
    local hook_path="${2:-$HOOK}"
    CHUMP_PREPUSH_SELECT_PACKAGES_ONLY=1     CHUMP_PREPUSH_CHANGED_FILES="$files"         bash "$hook_path" origin "" </dev/null 2>/dev/null
}

# 1. One-crate change -> crate + workspace reverse deps
out="$(select_for "crates/chump-waste-tally/src/lib.rs")"
mode="$(awk -F= '/^MODE=/ {print $2}' <<<"$out")"
pkgs="$(awk -F= '/^PACKAGES=/ {sub(/^PACKAGES=/, ""); print}' <<<"$out")"
if [[ "$mode" == "scoped" && "$pkgs" == "chump chump-kpi-report chump-waste-tally" ]]; then
    ok "crates/chump-waste-tally/src/lib.rs selects [chump chump-kpi-report chump-waste-tally] (crate + rdeps)"
else
    fail "expected scoped [chump chump-kpi-report chump-waste-tally], got mode=$mode pkgs='$pkgs'"
fi

# 2. Leaf binary crate (chump-demo) -> only chump-demo (no rdeps)
out="$(select_for "crates/chump-demo/src/main.rs")"
mode="$(awk -F= '/^MODE=/ {print $2}' <<<"$out")"
pkgs="$(awk -F= '/^PACKAGES=/ {sub(/^PACKAGES=/, ""); print}' <<<"$out")"
if [[ "$mode" == "scoped" && "$pkgs" == "chump-demo" ]]; then
    ok "crates/chump-demo/src/main.rs selects [chump-demo] (leaf crate)"
else
    fail "expected scoped [chump-demo], got mode=$mode pkgs='$pkgs'"
fi

# 3. Workspace-wide triggers -> MODE=workspace
for wf in "Cargo.lock" "Cargo.toml" "workspace-hack/Cargo.toml" "scripts/git-hooks/pre-push"; do
    out="$(select_for "$wf")"
    mode="$(awk -F= '/^MODE=/ {print $2}' <<<"$out")"
    if [[ "$mode" == "workspace" ]]; then
        ok "workspace-wide trigger '$wf' selects MODE=workspace"
    else
        fail "workspace-wide trigger '$wf' should select MODE=workspace, got mode=$mode"
    fi
done

# 4. Docs-only and scripts-only -> MODE=none
for nf in "docs/ROADMAP.md" "scripts/coord/farmer.sh" ".github/workflows/ci.yml"; do
    out="$(select_for "$nf")"
    mode="$(awk -F= '/^MODE=/ {print $2}' <<<"$out")"
    pkgs="$(awk -F= '/^PACKAGES=/ {sub(/^PACKAGES=/, ""); print}' <<<"$out")"
    if [[ "$mode" == "none" && -z "$pkgs" ]]; then
        ok "non-Rust change '$nf' selects MODE=none"
    else
        fail "non-Rust change '$nf' should select MODE=none, got mode=$mode pkgs='$pkgs'"
    fi
done

# 5. Mutant checks
T="$(mktemp -d "${TMPDIR:-/tmp}/infra-8154-mutant.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# Mutant 1: drop reverse-dependency expansion
python3 - "$HOOK" "$T/hook-no-rdeps" <<'PY'
import sys
src = open(sys.argv[1]).read()
mut = src.replace("while queue:", "while False: # MUTANT_RDEPS_DROPPED")
assert mut != src
open(sys.argv[2], "w").write(mut)
PY
chmod +x "$T/hook-no-rdeps"
mut1_out="$(select_for "crates/chump-waste-tally/src/lib.rs" "$T/hook-no-rdeps")"
mut1_pkgs="$(awk -F= '/^PACKAGES=/ {sub(/^PACKAGES=/, ""); print}' <<<"$mut1_out")"
if [[ "$mut1_pkgs" != "chump chump-kpi-report chump-waste-tally" ]]; then
    ok "mutant 1 (drop reverse-dependency expansion) is killed (selected '$mut1_pkgs' instead of 'chump chump-kpi-report chump-waste-tally')"
else
    fail "mutant 1 survived: dropping rdeps still selected '$mut1_pkgs'"
fi

# Mutant 2: drop workspace-wide trigger
python3 - "$HOOK" "$T/hook-no-ws" <<'PY'
import sys
src = open(sys.argv[1]).read()
mut = src.replace('_ws_trigger="$(grep -E', '_ws_trigger="" #')
assert mut != src
open(sys.argv[2], "w").write(mut)
PY
chmod +x "$T/hook-no-ws"
mut2_out="$(select_for "Cargo.lock" "$T/hook-no-ws")"
mut2_mode="$(awk -F= '/^MODE=/ {print $2}' <<<"$mut2_out")"
if [[ "$mut2_mode" != "workspace" ]]; then
    ok "mutant 2 (drop workspace-wide trigger) is killed (Cargo.lock gave mode='$mut2_mode' instead of 'workspace')"
else
    fail "mutant 2 survived: dropping workspace-wide trigger still gave mode=workspace"
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
