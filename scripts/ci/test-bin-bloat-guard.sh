#!/usr/bin/env bash
# test-bin-bloat-guard.sh — EFFECTIVE-414
#
# Verifies the bin-bloat-guard pre-commit gate:
#   1. A new src/*.rs file over the threshold is flagged (stderr warning +
#      ambient emit) but the commit is NOT blocked (advisory-only, rc=0).
#   2. A new src/*.rs file under the threshold passes silently.
#   3. A new file under crates/ (not src/) is ignored regardless of size.
#   4. CHUMP_BIN_BLOAT_GUARD_CHECK=0 silences the gate entirely.
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-bin-bloat-guard.sh"

echo "=== EFFECTIVE-414 bin-bloat-guard tests ==="
[[ -x "$GATE" ]] || { fail "gate missing at $GATE"; echo "FAIL"; exit 1; }
ok "gate present + executable"

mk_repo() {
    local d
    d="$(mktemp -d -t bin-bloat-guard.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name test
        mkdir -p src
        echo seed > README.md
        git add README.md
        git commit -q -m "seed"
    )
    printf '%s\n' "$d"
}

# ── Test 1: new large src/*.rs → flagged, rc=0, ambient emit ────────────────
echo "--- Test 1: new 500-line src/*.rs → advisory flag, not blocked ---"
R1="$(mk_repo)"
mkdir -p "$R1/.chump-locks"
python3 -c "print('fn f() {}\n' * 500)" > "$R1/src/big_module.rs" 2>/dev/null \
    || yes 'fn f() {}' | head -500 > "$R1/src/big_module.rs"
(
    cd "$R1"
    git add src/big_module.rs
    out="$("$GATE" 2>&1)"; rc=$?
    echo "$out" | grep -q "bin-bloat-guard" && echo "$out" | grep -q "big_module.rs" \
        && [[ $rc -eq 0 ]]
) && ok "large new file: flagged + rc=0" || fail "expected flag + rc=0"
if grep -q '"kind":"bin_bloat_guard_flagged"' "$R1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "ambient emit present"
else
    fail "expected bin_bloat_guard_flagged in ambient.jsonl"
fi
rm -rf "$R1"

# ── Test 2: new small src/*.rs → silent pass ─────────────────────────────────
echo "--- Test 2: new 10-line src/*.rs → silent pass ---"
R2="$(mk_repo)"
mkdir -p "$R2/.chump-locks"
yes 'fn f() {}' | head -10 > "$R2/src/small_module.rs"
(
    cd "$R2"
    git add src/small_module.rs
    out="$("$GATE" 2>&1)"; rc=$?
    [[ -z "${out// }" ]] && [[ $rc -eq 0 ]]
) && ok "small new file: silent PASS" || fail "expected silent pass"
rm -rf "$R2"

# ── Test 3: new large file under crates/ (not src/) → ignored ───────────────
echo "--- Test 3: new large crates/*.rs file → ignored ---"
R3="$(mk_repo)"
mkdir -p "$R3/.chump-locks" "$R3/crates/chump-foo/src"
yes 'fn f() {}' | head -500 > "$R3/crates/chump-foo/src/lib.rs"
(
    cd "$R3"
    git add crates/chump-foo/src/lib.rs
    out="$("$GATE" 2>&1)"; rc=$?
    [[ -z "${out// }" ]] && [[ $rc -eq 0 ]]
) && ok "crates/ file ignored" || fail "expected crates/ file to be ignored"
rm -rf "$R3"

# ── Test 4: CHUMP_BIN_BLOAT_GUARD_CHECK=0 silences the gate ─────────────────
echo "--- Test 4: disable env var silences the gate ---"
R4="$(mk_repo)"
mkdir -p "$R4/.chump-locks"
yes 'fn f() {}' | head -500 > "$R4/src/big_module.rs"
(
    cd "$R4"
    git add src/big_module.rs
    out="$(CHUMP_BIN_BLOAT_GUARD_CHECK=0 "$GATE" 2>&1)"; rc=$?
    [[ -z "${out// }" ]] && [[ $rc -eq 0 ]]
) && ok "disable env var: silent PASS" || fail "expected silent pass with check disabled"
rm -rf "$R4"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
