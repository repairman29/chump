#!/usr/bin/env bash
# scripts/ops/atomic-binary-swap.sh — RESILIENT-493 (slice of RESILIENT-345)
#
# Atomically replace the binary an organ executes with a newly built one.
# The new binary is staged to a temp file in the SAME directory as the target
# (same filesystem, so rename(2) is atomic), the prior binary is retained as
# <target>.prev (hardlink, for the RESILIENT-494 rollback), then the temp file
# is renamed over the target. Any failure leaves the previous binary in place.
#
# Usage: scripts/ops/atomic-binary-swap.sh <new-binary> <target-path>
#
# Env: CHUMP_BINARY_SWAP_AMBIENT  ambient stream override (tests)
#      CHUMP_BINARY_SWAP_MV_BIN   override for `mv` (tests: inject failure)
#
# Exit: 0 swapped; 1 swap failed (previous binary untouched)

set -uo pipefail

NEW="${1:-}"; TARGET="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT="${CHUMP_BINARY_SWAP_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
MV_BIN="${CHUMP_BINARY_SWAP_MV_BIN:-mv}"

emit() {
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$1" "$2" >> "$AMBIENT" 2>/dev/null || true
}
log_err() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# scanner-anchor (RESILIENT-493, docs/observability/EVENT_REGISTRY.yaml):
# scanner-anchor: "kind":"binary_swap_ok"
# scanner-anchor: "kind":"binary_swap_failed"

fail() {  # reason
    log_err "FATAL: atomic binary swap failed: $1 — previous binary left in place ($TARGET)"
    local esc; esc="$(printf '%s' "$1" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g')"
    emit binary_swap_failed "\"target\":\"$TARGET\",\"reason\":\"$esc\""
    [[ -n "${TMP:-}" ]] && rm -f "$TMP" 2>/dev/null
    exit 1
}

[[ -n "$NEW" && -n "$TARGET" ]] || { log_err "usage: $0 <new-binary> <target-path>"; exit 1; }
[[ -f "$NEW" && -x "$NEW" ]] || fail "new binary missing or not executable: $NEW"

TMP="$TARGET.new.$$"
cp -p "$NEW" "$TMP" 2>/dev/null || fail "cannot stage new binary at $TMP"
chmod +x "$TMP" 2>/dev/null || fail "cannot chmod staged binary"

if [[ -e "$TARGET" ]]; then
    ln -f "$TARGET" "$TARGET.prev" 2>/dev/null || cp -p "$TARGET" "$TARGET.prev" 2>/dev/null \
        || fail "cannot retain previous binary as $TARGET.prev"
fi

"$MV_BIN" -f "$TMP" "$TARGET" 2>/dev/null || fail "rename $TMP -> $TARGET failed"

emit binary_swap_ok "\"target\":\"$TARGET\""
exit 0
