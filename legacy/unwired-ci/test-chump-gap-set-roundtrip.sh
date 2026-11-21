#!/usr/bin/env bash
# test-chump-gap-set-roundtrip.sh — INFRA-2022
#
# End-to-end CLI test: `chump gap set <ID> acceptance_criteria "..."` (positional
# bare-field syntax) must persist the operator-provided value to state.db and
# reflect it in `chump gap show`. Prior to INFRA-2022 the positional field name
# was silently ignored, leaving whatever TODO stubs `chump gap reserve` installed.
#
# Covers:
#   1. Positional snake_case:  gap set ID acceptance_criteria "text"
#   2. Positional kebab-case:  gap set ID acceptance-criteria "text"
#   3. Flag form still works:  gap set ID --acceptance-criteria "text"
#   4. Unrecognised bare positional exits non-zero (typo guard)

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Prefer debug over release: the debug build incorporates the latest worktree
# changes; the release binary may pre-date the fix and would give false-negative
# results. Operators running the full pre-push suite will have built debug.
CHUMP="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP" ]]; then
    CHUMP="$REPO_ROOT/target/release/chump"
fi
if [[ ! -x "$CHUMP" ]]; then
    echo "FATAL: chump binary not built; run 'cargo build --bin chump' first"
    exit 2
fi

echo "=== INFRA-2022 chump gap set acceptance_criteria roundtrip test ==="
echo

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE="$TMPDIR_BASE/repo"
mkdir -p "$FAKE/docs/gaps" "$FAKE/.chump" "$FAKE/.chump-locks"
git -C "$FAKE" init -q -b main
git -C "$FAKE" config user.email t@t.com
git -C "$FAKE" config user.name t
git -C "$FAKE" commit --allow-empty -q -m seed

cd "$FAKE"

reserve_gap() {
    local label="$1"
    local out
    out=$(CHUMP_REPO="$FAKE" CHUMP_RESERVE_SCAN_OPEN_PRS=0 "$CHUMP" gap reserve --force \
        --domain TEST --priority P2 --effort xs \
        --title "INFRA-2022 ${label} $(date +%s%N)" 2>&1)
    local id
    id=$(echo "$out" | grep -oE 'TEST-[0-9]+' | head -1)
    if [[ -z "$id" ]]; then
        echo "FATAL: chump gap reserve did not produce a gap ID. Output: $out" >&2
        exit 2
    fi
    echo "$id"
}

ac_value_from_show() {
    # Returns the raw JSON acceptance_criteria value from state.db via gap show.
    # Correct arg order: gap show <GAP_ID> --field <field>
    local gap_id="$1"
    CHUMP_REPO="$FAKE" "$CHUMP" gap show "$gap_id" --field acceptance_criteria 2>/dev/null || true
}

# ─── Test 1: positional snake_case `acceptance_criteria` ────────────────────
GAP1=$(reserve_gap "snake-positional")
TARGET1="operator text via snake_case positional"
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP1" acceptance_criteria "$TARGET1" >/dev/null 2>&1
STORED1=$(ac_value_from_show "$GAP1")
if echo "$STORED1" | grep -qF "$TARGET1"; then
    ok "snake_case positional: value persisted"
else
    fail "snake_case positional: got '${STORED1}', expected to contain '${TARGET1}'"
fi

# ─── Test 2: positional kebab-case `acceptance-criteria` ────────────────────
GAP2=$(reserve_gap "kebab-positional")
TARGET2="operator text via kebab-case positional"
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP2" acceptance-criteria "$TARGET2" >/dev/null 2>&1
STORED2=$(ac_value_from_show "$GAP2")
if echo "$STORED2" | grep -qF "$TARGET2"; then
    ok "kebab-case positional: value persisted"
else
    fail "kebab-case positional: got '${STORED2}', expected to contain '${TARGET2}'"
fi

# ─── Test 3: canonical flag form still works unchanged ───────────────────────
GAP3=$(reserve_gap "flag-form")
TARGET3="canonical flag form still works"
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP3" --acceptance-criteria "$TARGET3" >/dev/null 2>&1
STORED3=$(ac_value_from_show "$GAP3")
if echo "$STORED3" | grep -qF "$TARGET3"; then
    ok "canonical flag form: value persisted"
else
    fail "canonical flag form: got '${STORED3}', expected to contain '${TARGET3}'"
fi

# ─── Test 4: positional overwrites TODO stubs left by reserve ───────────────
GAP4=$(reserve_gap "overwrite-todos")
# Seed with explicit TODOs
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP4" --acceptance-criteria "TODO: placeholder" >/dev/null 2>&1
TARGET4="real criterion replacing TODO"
CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP4" acceptance_criteria "$TARGET4" >/dev/null 2>&1
STORED4=$(ac_value_from_show "$GAP4")
if echo "$STORED4" | grep -qF "$TARGET4"; then
    ok "positional overwrites TODO stubs: value persisted"
else
    fail "positional overwrites TODO stubs: got '${STORED4}', expected '${TARGET4}'"
fi

# ─── Test 5: unrecognised bare positional exits non-zero (typo guard) ────────
GAP5=$(reserve_gap "typo-guard")
if CHUMP_REPO="$FAKE" "$CHUMP" gap set "$GAP5" typo_field_name "some value" >/dev/null 2>&1; then
    fail "typo guard: unrecognised positional field name should exit non-zero"
else
    ok "typo guard: unrecognised positional field exits non-zero"
fi

cd "$REPO_ROOT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
