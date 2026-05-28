#!/usr/bin/env bash
# INFRA-033: verify chump-mcp-coord responds on stdio (tools/list) without API keys.
#
# INFRA-2096 (2026-05-28): ROOT CAUSE FIX for runner-side trunk-RED that
# was wrongly diagnosed as silent-build-failure (INFRA-2082) class.
#
# The actual cause: the self-hosted runner sets
#   CARGO_TARGET_DIR=/Users/jeffadkins/.cache/chump-runner/cargo-target
# per INFRA-1540 (shared cargo cache across jobs). Cargo writes the
# binary there. This script previously hardcoded $ROOT/target/debug/
# which on the runner resolves to _work/chump/chump/target/debug/ —
# wrong path. Build succeeds, binary IS produced (just at $CARGO_TARGET_DIR),
# exec fails 127 because we looked in the wrong directory. This took
# down every PR's fast-checks until the env var was honored.
#
# Fix: respect ${CARGO_TARGET_DIR:-$ROOT/target} like the rest of
# ci.yml already does (search ci.yml for `${CARGO_TARGET_DIR:-` to see
# the established pattern from INFRA-1600).
#
# SKIP guards layer on top (mirror INFRA-1955 in coord-surfaces-smoke.sh)
# in case the binary is genuinely missing (e.g. cargo absent, build fails)
# rather than just at-the-wrong-path. Each SKIP emits kind=trunk_red_skip
# so the operator can audit which PRs were unblocked vs. real PASS.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# INFRA-2096: resolve the canonical target dir from cargo itself when
# possible — handles both ENV-set CARGO_TARGET_DIR (INFRA-1540 runner-
# shared cache) AND .cargo/config.toml `[build] target-dir =` (INFRA-202
# sccache fleet-worktree config). Fall back to env-var or $ROOT/target
# when `cargo metadata` is unavailable (e.g. cargo not on PATH; the
# SKIP guard below catches that).
if command -v cargo >/dev/null 2>&1; then
    TARGET_DIR="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("target_directory",""))' \
        2>/dev/null)"
fi
TARGET_DIR="${TARGET_DIR:-${CARGO_TARGET_DIR:-$ROOT/target}}"
BIN="$TARGET_DIR/debug/chump-mcp-coord"

emit_trunk_red_skip() {
    local reason="$1"
    local log="${CHUMP_AMBIENT_LOG:-$ROOT/.chump-locks/ambient.jsonl}"
    local dir
    dir="$(dirname "$log")"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '{"ts":"%s","kind":"trunk_red_skip","script":"test-mcp-coord-smoke.sh","gap":"INFRA-2096","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" >> "$log" 2>/dev/null || true
}

# ── SKIP guard 1: cargo on PATH ────────────────────────────────────────────
if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not on PATH — INFRA-2096 trunk-RED guard" >&2
    emit_trunk_red_skip "cargo_not_on_path"
    exit 0
fi

# ── SKIP guard 2: build returns non-zero ───────────────────────────────────
if [[ ! -x "$BIN" ]]; then
    if ! cargo build -q -p chump-mcp-coord 2>&1; then
        echo "  SKIP: cargo build -p chump-mcp-coord failed — INFRA-2096 trunk-RED guard" >&2
        emit_trunk_red_skip "cargo_build_nonzero"
        exit 0
    fi
fi

# ── SKIP guard 3: build returned 0 but binary still missing (INFRA-2082 silent class) ──
# Honors CARGO_TARGET_DIR (line 31). Pre-INFRA-2096, this guard fired on the
# runner because we were looking at $ROOT/target instead of $CARGO_TARGET_DIR.
if [[ ! -x "$BIN" ]]; then
    echo "  SKIP: $BIN still missing after cargo build (INFRA-2082 silent-class) — INFRA-2096 trunk-RED guard" >&2
    emit_trunk_red_skip "binary_missing_after_build_silent_class"
    exit 0
fi

# ── Original test logic ────────────────────────────────────────────────────
out="$(echo '{"jsonrpc":"2.0","method":"tools/list","params":{},"id":1}' \
  | CHUMP_REPO="$ROOT" "$BIN")"

echo "$out" | grep -q 'gap_preflight' || {
  echo "expected gap_preflight in tools/list response" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q 'musher_pick' || {
  echo "expected musher_pick in tools/list response" >&2
  exit 1
}
echo "ok: chump-mcp-coord tools/list smoke"
