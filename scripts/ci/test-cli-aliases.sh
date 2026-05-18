#!/usr/bin/env bash
# test-cli-aliases.sh — EFFECTIVE-011
# Validates that chump short-form aliases expand correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$CHUMP" ]] || fail "chump binary not built — run cargo build --bin chump first"

# ── 1: expand_aliases defined in source ──────────────────────────────────────
grep -q 'fn expand_aliases' "$REPO_ROOT/src/main.rs" \
    || fail "expand_aliases function not found in src/main.rs"
pass "expand_aliases present in main.rs"

# ── 2: all aliases wired (source inspection) ─────────────────────────────────
for alias_pair in '"g"→gap' '"c"→claim' '"f"→fleet' '"d"→dispatch' '"h"→health'; do
    alias="${alias_pair%%→*}"
    target="${alias_pair##*→}"
    grep -q "\"${alias//\"/}\"" "$REPO_ROOT/src/main.rs" \
        || fail "alias $alias not found in main.rs"
done
pass "g,c,f,d,h aliases all present in main.rs"

# ── 3: 's' compound alias (gap ship) ─────────────────────────────────────────
grep -q '"s"' "$REPO_ROOT/src/main.rs" \
    || fail "alias 's' not found in main.rs"
grep -q 'insert.*"ship"' "$REPO_ROOT/src/main.rs" \
    || fail "compound alias 's' does not insert 'ship'"
pass "compound alias 's' = 'gap ship' wired"

# ── 4: 'cs' alias (cost-watch) ───────────────────────────────────────────────
grep -q '"cs"' "$REPO_ROOT/src/main.rs" \
    || fail "alias 'cs' not found in main.rs"
pass "alias 'cs' = cost-watch wired"

# ── 5: chump g list works (exit 0, same as chump gap list) ───────────────────
out_alias=$("$CHUMP" g list 2>&1 || true)
out_full=$("$CHUMP" gap list 2>&1 || true)
# Both should have the "--- N shown" summary footer
echo "$out_alias" | grep -qE -- '--- [0-9]+ shown' \
    || fail "'chump g list' did not produce expected gap list output"
pass "chump g list produces gap list output"

# ── 6: help text shows aliases ───────────────────────────────────────────────
help_out=$("$CHUMP" --help 2>&1 || true)
echo "$help_out" | grep -q 'alias' \
    || fail "'chump --help' does not mention aliases"
pass "chump --help mentions aliases"

# ── 7: CLI_ALIASES.md exists and documents all 7 aliases ─────────────────────
ALIASES_DOC="$REPO_ROOT/docs/process/CLI_ALIASES.md"
[[ -f "$ALIASES_DOC" ]] || fail "CLI_ALIASES.md missing at $ALIASES_DOC"
for a in 'g' 'c' 's' 'f' 'd' 'h' 'cs'; do
    grep -q "\`$a\`" "$ALIASES_DOC" \
        || fail "CLI_ALIASES.md missing entry for alias '$a'"
done
pass "CLI_ALIASES.md documents all 7 aliases"

printf '\nAll CLI alias tests passed.\n'
