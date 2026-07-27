#!/usr/bin/env bash
# INFRA-2099: shared helper for scripts/ci/test-*.sh to resolve the canonical
# cargo target dir without hardcoding $ROOT/target.
#
# Prefer `cargo metadata --no-deps --format-version 1` which honors BOTH:
#   - $CARGO_TARGET_DIR env var (INFRA-1540 shared runner cache)
#   - .cargo/config.toml `[build] target-dir =` (INFRA-202 sccache fleet)
# Falls back to ${CARGO_TARGET_DIR:-$REPO_ROOT/target} when cargo is absent
# (callers handle the missing-cargo path themselves via SKIP guards).
#
# Usage:
#   source "$(dirname "$0")/lib/resolve-cargo-target-dir.sh"
#   TARGET_DIR="$(resolve_cargo_target_dir "$REPO_ROOT")"
#   BIN="$TARGET_DIR/debug/chump"

resolve_cargo_target_dir() {
    local repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local resolved=""

    if command -v cargo >/dev/null 2>&1; then
        resolved="$(cd "$repo_root" && cargo metadata --no-deps --format-version 1 2>/dev/null \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("target_directory",""))' \
            2>/dev/null)"
    fi

    if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    # Fall back to env-var or $repo_root/target — never hardcoded $ROOT/target.
    echo "${CARGO_TARGET_DIR:-$repo_root/target}"
}
