#!/usr/bin/env bash
# test-redundancy-gate.sh — META-063
#
# Exercises scripts/git-hooks/pre-commit-redundancy.sh against synthetic
# shell fixtures. Verifies:
#   - new file outside critical dirs: allowed (gate silent)
#   - new file in scripts/coord/ with NO similar siblings: allowed
#   - new file in scripts/coord/ that duplicates an existing file's fn names: blocked
#   - new file with < 3 functions: skipped (too small to score reliably)
#   - blocked file WITH Redundancy-OK: trailer: allowed + emits ambient
#   - CHUMP_REDUNDANCY_CHECK=0: silent
#   - modifying existing file: allowed (only ADDS trigger the gate)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-redundancy.sh"

echo "=== META-063 redundancy gate tests ==="
[[ -x "$GATE" ]] || { fail "gate not executable at $GATE"; exit 1; }
ok "gate present + executable"

mk_repo() {
    local d; d="$(mktemp -d -t redundancy-gate.XXXXXX)"
    (
        cd "$d"; git init -q
        git config user.email test@test.local
        git config user.name test
        git commit --allow-empty -q -m "init"
    )
    printf '%s\n' "$d"
}

run_gate() {
    local repo="$1" msg="${2:-tmp}"
    (
        cd "$repo"
        printf '%s\n' "$msg" > .git/COMMIT_EDITMSG
        git add -A 2>/dev/null
        bash "$GATE" 2>&1
    )
}

# ── Test 1: outside critical dirs → allowed ──────────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/dev"
cat > "$TR/scripts/dev/foo.sh" <<'EOF'
#!/bin/sh
alpha() { echo a; }
beta()  { echo b; }
gamma() { echo g; }
EOF
out="$(run_gate "$TR")"; rc=$?
[[ $rc -eq 0 ]] && ok "outside critical dirs: allowed" || fail "should not gate scripts/dev/"
rm -rf "$TR"

# ── Test 2: no similar siblings → allowed ────────────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/coord"
cat > "$TR/scripts/coord/foo.sh" <<'EOF'
#!/bin/sh
fresh_func_one()   { :; }
fresh_func_two()   { :; }
fresh_func_three() { :; }
EOF
out="$(run_gate "$TR")"; rc=$?
[[ $rc -eq 0 ]] && ok "no siblings: allowed" || fail "single-file dir: $out"
rm -rf "$TR"

# ── Test 3: duplicate of existing file → blocked ─────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/coord"
cat > "$TR/scripts/coord/existing.sh" <<'EOF'
#!/bin/sh
ambient_emit()  { :; }
lease_iter()    { :; }
fail()          { :; }
log()           { :; }
say()           { :; }
ok()            { :; }
warn()          { :; }
red()           { :; }
EOF
(cd "$TR" && git add scripts/coord/existing.sh && git commit -q -m "seed")
# New file with same function names → high Jaccard.
cat > "$TR/scripts/coord/dup.sh" <<'EOF'
#!/bin/sh
ambient_emit() { :; }
lease_iter()   { :; }
fail()         { :; }
log()          { :; }
say()          { :; }
ok()           { :; }
warn()         { :; }
EOF
out="$(run_gate "$TR")"; rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -q 'redundancy gate blocked'; then
    ok "duplicate function-name shape: blocked"
else
    fail "duplicate not detected (rc=$rc): $out"
fi
rm -rf "$TR"

# ── Test 4: < 3 functions → skipped (too small) ─────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/coord"
cat > "$TR/scripts/coord/big.sh" <<'EOF'
#!/bin/sh
a() { :; }
b() { :; }
c() { :; }
d() { :; }
EOF
(cd "$TR" && git add scripts/coord/big.sh && git commit -q -m "seed")
cat > "$TR/scripts/coord/tiny.sh" <<'EOF'
#!/bin/sh
a() { :; }
b() { :; }
EOF
out="$(run_gate "$TR")"; rc=$?
[[ $rc -eq 0 ]] && ok "< 3 functions: skipped (no false positive)" || fail "small file blocked: $out"
rm -rf "$TR"

# ── Test 5: bypass trailer + ambient log ────────────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/coord" "$TR/.chump-locks"
cat > "$TR/scripts/coord/existing.sh" <<'EOF'
#!/bin/sh
ambient_emit() { :; }
lease_iter()   { :; }
fail()         { :; }
log()          { :; }
ok()           { :; }
EOF
(cd "$TR" && git add scripts/coord/existing.sh && git commit -q -m "seed")
cat > "$TR/scripts/coord/dup.sh" <<'EOF'
#!/bin/sh
ambient_emit() { :; }
lease_iter()   { :; }
fail()         { :; }
log()          { :; }
ok()           { :; }
EOF
MSG="feat: add dup

Body line.

Redundancy-OK: helper file legitimately mirrors existing shape for X reason"
out="$(run_gate "$TR" "$MSG")"; rc=$?
[[ $rc -eq 0 ]] && ok "bypass trailer: allowed" || fail "bypass not honored: $out"
if [[ -f "$TR/.chump-locks/ambient.jsonl" ]] && grep -q 'redundancy_bypass_used' "$TR/.chump-locks/ambient.jsonl"; then
    ok "bypass logs kind=redundancy_bypass_used to ambient"
else
    fail "bypass not logged to ambient"
fi
rm -rf "$TR"

# ── Test 6: env hatch silences gate ─────────────────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/coord"
cat > "$TR/scripts/coord/existing.sh" <<'EOF'
#!/bin/sh
ambient_emit() { :; }
lease_iter()   { :; }
fail()         { :; }
log()          { :; }
ok()           { :; }
EOF
(cd "$TR" && git add scripts/coord/existing.sh && git commit -q -m "seed")
cat > "$TR/scripts/coord/dup.sh" <<'EOF'
#!/bin/sh
ambient_emit() { :; }
lease_iter()   { :; }
fail()         { :; }
log()          { :; }
ok()           { :; }
EOF
out="$(CHUMP_REDUNDANCY_CHECK=0 run_gate "$TR")"; rc=$?
[[ $rc -eq 0 ]] && ok "CHUMP_REDUNDANCY_CHECK=0: silent" || fail "env hatch not honored"
rm -rf "$TR"

# ── Test 7: modifying existing file → allowed ──────────────────────────────
TR="$(mk_repo)"
mkdir -p "$TR/scripts/coord"
cat > "$TR/scripts/coord/existing.sh" <<'EOF'
#!/bin/sh
a() { :; }
b() { :; }
c() { :; }
d() { :; }
EOF
(cd "$TR" && git add scripts/coord/existing.sh && git commit -q -m "seed")
echo '# modified' >> "$TR/scripts/coord/existing.sh"
out="$(run_gate "$TR")"; rc=$?
[[ $rc -eq 0 ]] && ok "modify-only: allowed (gate is add-only)" || fail "modify blocked"
rm -rf "$TR"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
