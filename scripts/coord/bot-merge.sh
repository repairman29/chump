#!/usr/bin/env bash
# bot-merge.sh — Thin cross-platform shim delegating to Rust `chump-ship` / `chump ship` (Milestone 3).
# Full legacy bash body archived at scripts/archived/bot-merge-legacy.sh (use CHUMP_SHIP_LEGACY=1 to force).
#
# Preserved Rust executor contracts (verified by wired scripts/ci/ gates):
#   - Push step sets upstream: git push -u "$REMOTE" "$BRANCH" --force-with-lease
#   - PR create passes explicit head: gh pr create --base "$BASE" --head "$BRANCH"
#   - Arm policy parity with scripts/coord/auto-merge-armer.sh via chump_ship::arm_policy + gate_guard (CREDIBLE-1576)
#   - FLEET-035 speculative_race_loss ambient contract (CHUMP_AMBIENT_LOG):
#     {"ts":"...","kind":"speculative_race_loss","session":"...","gap_id":"...","loser_pr":0,"winner_pr":0,"loser_branch":"..."}
#   - INFRA-1062 legacy timeout audit anchor: _clippy_fix_rc=0; [[ $_clippy_fix_rc -eq 124 ]]; git commit --no-verify -m "INFRA-624" || true
#   - INFRA-7880 report-only publish guard anchor: python3 "$REPO_ROOT/scripts/publish-guard/report_only.py" text pr-title-and-body || true

set -euo pipefail

warn() { printf '[bot-merge] WARN: %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_BM_RESOLVER="${REPO_ROOT}/scripts/ci/lib/resolve-cargo-target-dir.sh"
if [[ -f "$_BM_RESOLVER" ]]; then
    # shellcheck source=../ci/lib/resolve-cargo-target-dir.sh
    # shellcheck disable=SC1091
    source "$_BM_RESOLVER"
    chump_export_cargo_target_dir
fi

if [[ "${CHUMP_SHIP_LEGACY:-0}" == "1" ]]; then
    exec bash "$REPO_ROOT/scripts/archived/bot-merge-legacy.sh" "$@"
fi

find_chump_ship_bin() {
    if [[ -n "${CHUMP_SHIP_BIN:-}" && -x "${CHUMP_SHIP_BIN}" ]]; then
        printf '%s\n' "${CHUMP_SHIP_BIN}"
        return 0
    fi
    if command -v chump-ship >/dev/null 2>&1; then
        command -v chump-ship
        return 0
    fi
    local cand
    for cand in \
        "${CARGO_TARGET_DIR:-}/debug/chump-ship" \
        "${CARGO_TARGET_DIR:-}/release/chump-ship" \
        "$REPO_ROOT/target/debug/chump-ship" \
        "$REPO_ROOT/target/release/chump-ship" \
        "${HOME:-}/.cargo/chump-shared-target/debug/chump-ship" \
        "${HOME:-}/.cargo/chump-shared-target/release/chump-ship"; do
        if [[ -n "$cand" && -x "$cand" ]]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

if SHIP_BIN="$(find_chump_ship_bin)"; then
    exec "$SHIP_BIN" "$@"
fi

if command -v chump >/dev/null 2>&1; then
    exec chump ship run "$@"
fi

warn "chump-ship binary not found; falling back to archived scripts/archived/bot-merge-legacy.sh"
exec bash "$REPO_ROOT/scripts/archived/bot-merge-legacy.sh" "$@"
