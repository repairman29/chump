#!/usr/bin/env bash
# scripts/ci/test-decompose-uses-ast.sh — INFRA-1719 smoke test
#
# Asserts that `chump gap decompose --dry-run` injects the structured AST
# block produced by the tree-sitter crawler into the LLM prompt. Uses a
# synthetic gap with a description pointing at known source files in the
# checkout; --dry-run prints the full prompt without spending tokens.
#
# Behavior verified:
#   1. Prompt contains the "Structured codebase shape" header (INFRA-1719).
#   2. Prompt names at least one of the files referenced in the gap
#      description (e.g. `crates/ast-crawler/src/lib.rs`).
#   3. CHUMP_DECOMPOSE_AST=0 cleanly opts out of the AST block (no header).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CHUMP_BIN="${CHUMP_BIN:-target/debug/chump}"
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[decompose-ast] building chump (CHUMP_BIN=$CHUMP_BIN missing)..."
    PATH="${HOME}/.cargo/bin:${PATH}" cargo build -q --bin chump
fi

# Seed an isolated state.db so the smoke test doesn't touch the live registry.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_STATE_DB="$TMP/state.db"
mkdir -p "$(dirname "$CHUMP_STATE_DB")"

# Reserve a synthetic gap that references real files in this checkout. The
# decompose path will surface them via extract_path_hints() → crawl_paths().
HINT_FILES="crates/ast-crawler/src/lib.rs crates/ambient-cli/src/ambient_emit.rs"
DESC="Test gap referencing $HINT_FILES — expect AST block."

# `gap reserve` does not accept --description; the field is set via a
# follow-up `gap update`. This is the canonical two-step pattern (INFRA-228).
GAP_ID=$(
    "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --title "test-decompose-ast smoke" \
        --effort m \
        --priority P2 \
        --force-duplicate \
        2>&1 | grep -Eo 'INFRA-[0-9]+' | head -1
)

if [[ -z "${GAP_ID:-}" ]]; then
    echo "[decompose-ast] failed to reserve gap"
    exit 1
fi
echo "[decompose-ast] reserved $GAP_ID"

# Set description + tighten ACs so decompose accepts the gap and the AST
# crawler sees a hint-rich payload.
"$CHUMP_BIN" gap update "$GAP_ID" \
    --description "$DESC" \
    --acceptance-criteria "ast block appears" >/dev/null 2>&1 || true

# Cleanup the stray yaml mirror that reserve writes into the working repo
# (the test-isolated state.db is the source of truth; the yaml is just a
# side-effect we don't want to leave behind).
rm -f "docs/gaps/$GAP_ID.yaml"

# ── (1) default: AST block present ───────────────────────────────────────
PROMPT=$("$CHUMP_BIN" gap decompose "$GAP_ID" --dry-run 2>&1 || true)
if ! grep -q "Structured codebase shape" <<<"$PROMPT"; then
    echo "[decompose-ast] FAIL: 'Structured codebase shape' header not in prompt"
    echo "--- prompt head ---"
    echo "$PROMPT" | head -50
    exit 1
fi
if ! grep -q "ast-crawler" <<<"$PROMPT"; then
    echo "[decompose-ast] FAIL: expected file ast-crawler missing from prompt"
    echo "--- prompt head ---"
    echo "$PROMPT" | head -80
    exit 1
fi

# ── (2) opt-out: CHUMP_DECOMPOSE_AST=0 suppresses the block ──────────────
PROMPT_OFF=$(CHUMP_DECOMPOSE_AST=0 "$CHUMP_BIN" gap decompose "$GAP_ID" --dry-run 2>&1 || true)
if grep -q "Structured codebase shape" <<<"$PROMPT_OFF"; then
    echo "[decompose-ast] FAIL: AST block leaked through CHUMP_DECOMPOSE_AST=0 opt-out"
    exit 1
fi

echo "[decompose-ast] PASS — AST block present by default, suppressed when opted out"
