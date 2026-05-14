#!/usr/bin/env bash
# test-rust-first-gate.sh — META-064
#
# Exercises the Rust-first pre-commit gate against synthetic shell files.
# Verifies:
#   - new file outside hot-path dirs: allowed (gate is silent)
#   - new file in scripts/coord/: blocked
#   - new file in scripts/dispatch/: blocked
#   - new file in scripts/ops/ that writes to state.db: blocked
#   - new file in scripts/ops/ that's pure glue (gh + jq): allowed
#   - new file in scripts/ops/ > 200 LOC: blocked
#   - blocked file WITH Rust-First-Bypass: trailer: allowed
#   - bypass emission to ambient.jsonl: present
#   - CHUMP_RUST_FIRST_CHECK=0 env: silent
#   - existing (not new) shell modification: allowed

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-rust-first.sh"

echo "=== META-064 Rust-first gate tests ==="
[[ -x "$GATE" ]] || { fail "gate not executable at $GATE"; echo "FAIL"; exit 1; }
ok "gate present + executable"

# Build a fresh repo each test so the staged diff is clean.
mk_repo() {
    local d
    d="$(mktemp -d -t rust-first-gate.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name test
        mkdir -p .git/info
        # Empty commit so HEAD exists.
        git commit --allow-empty -q -m "init"
    )
    printf '%s\n' "$d"
}

run_gate() {
    local repo="$1" msg="$2"
    (
        cd "$repo"
        # Write COMMIT_EDITMSG so the gate can read the trailer.
        printf '%s\n' "$msg" > .git/COMMIT_EDITMSG
        # Stage everything that's pending.
        git add -A 2>/dev/null
        bash "$GATE" 2>&1
    )
}

# ── Test 1: new shell outside hot path → allowed ─────────────────────────────
TR1="$(mk_repo)"
mkdir -p "$TR1/scripts/dev"
echo '#!/bin/sh' > "$TR1/scripts/dev/hello.sh"
out="$(run_gate "$TR1" "tmp")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "outside hot-path: allowed"; else fail "outside hot-path blocked: $out"; fi
rm -rf "$TR1"

# ── Test 2: new shell in scripts/coord/ → blocked ────────────────────────────
TR2="$(mk_repo)"
mkdir -p "$TR2/scripts/coord"
echo '#!/bin/sh' > "$TR2/scripts/coord/foo.sh"
out="$(run_gate "$TR2" "tmp")"; rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "Rust-first gate blocked"; then
    ok "scripts/coord/ new file: blocked"
else
    fail "scripts/coord/ new file should be blocked (rc=$rc)"
fi
rm -rf "$TR2"

# ── Test 3: new shell in scripts/dispatch/ → blocked ─────────────────────────
TR3="$(mk_repo)"
mkdir -p "$TR3/scripts/dispatch"
echo '#!/bin/sh' > "$TR3/scripts/dispatch/foo.sh"
out="$(run_gate "$TR3" "tmp")"; rc=$?
if [[ $rc -ne 0 ]]; then ok "scripts/dispatch/ new file: blocked"; else fail "should be blocked"; fi
rm -rf "$TR3"

# ── Test 4: scripts/ops/ + state.db write → blocked ──────────────────────────
TR4="$(mk_repo)"
mkdir -p "$TR4/scripts/ops"
cat > "$TR4/scripts/ops/state-mutator.sh" <<'EOF'
#!/bin/sh
sqlite3 .chump/state.db "INSERT INTO foo VALUES (1)"
echo "{\"kind\":\"foo\"}" >> .chump-locks/ambient.jsonl
EOF
out="$(run_gate "$TR4" "tmp")"; rc=$?
if [[ $rc -ne 0 ]]; then ok "scripts/ops/ state-mutator: blocked"; else fail "state-mutator should be blocked"; fi
rm -rf "$TR4"

# ── Test 5: scripts/ops/ pure glue (no state, <200 LOC) → allowed ────────────
TR5="$(mk_repo)"
mkdir -p "$TR5/scripts/ops"
cat > "$TR5/scripts/ops/pure-glue.sh" <<'EOF'
#!/bin/sh
gh pr list --json number,title | jq -r '.[] | "PR #\(.number) \(.title)"'
EOF
out="$(run_gate "$TR5" "tmp")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "scripts/ops/ pure glue: allowed"; else fail "pure glue blocked: $out"; fi
rm -rf "$TR5"

# ── Test 6: scripts/ops/ > 200 LOC → blocked ─────────────────────────────────
TR6="$(mk_repo)"
mkdir -p "$TR6/scripts/ops"
{ echo '#!/bin/sh'; for i in $(seq 1 250); do echo "# line $i"; done; } > "$TR6/scripts/ops/big.sh"
out="$(run_gate "$TR6" "tmp")"; rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -q '> 200 threshold'; then
    ok "scripts/ops/ > 200 LOC: blocked with size reason"
else
    fail "big shell should trigger size rule"
fi
rm -rf "$TR6"

# ── Test 7: blocked file + Rust-First-Bypass: trailer → allowed ──────────────
TR7="$(mk_repo)"
mkdir -p "$TR7/scripts/coord" "$TR7/.chump-locks"
echo '#!/bin/sh' > "$TR7/scripts/coord/foo.sh"
MSG="feat: add foo

Body of the commit message.

Rust-First-Bypass: 30-line gh+jq glue shim, not state-mutating"
out="$(run_gate "$TR7" "$MSG")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "blocked file with bypass trailer: allowed"; else fail "bypass trailer not honored: $out"; fi
# Confirm ambient emit.
if [[ -f "$TR7/.chump-locks/ambient.jsonl" ]] && grep -q 'rust_first_bypass_used' "$TR7/.chump-locks/ambient.jsonl"; then
    ok "bypass logs kind=rust_first_bypass_used to ambient"
else
    fail "bypass not logged to ambient"
fi
rm -rf "$TR7"

# ── Test 8: CHUMP_RUST_FIRST_CHECK=0 → silent ────────────────────────────────
TR8="$(mk_repo)"
mkdir -p "$TR8/scripts/coord"
echo '#!/bin/sh' > "$TR8/scripts/coord/foo.sh"
out="$(CHUMP_RUST_FIRST_CHECK=0 run_gate "$TR8" "tmp")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "CHUMP_RUST_FIRST_CHECK=0 disables the gate"; else fail "env hatch not honored"; fi
rm -rf "$TR8"

# ── Test 9: modifying existing shell in scripts/coord/ → allowed ─────────────
TR9="$(mk_repo)"
mkdir -p "$TR9/scripts/coord"
echo '#!/bin/sh' > "$TR9/scripts/coord/existing.sh"
(cd "$TR9" && git add scripts/coord/existing.sh && git commit -q -m "seed")
echo '# modified' >> "$TR9/scripts/coord/existing.sh"
out="$(run_gate "$TR9" "tmp")"; rc=$?
if [[ $rc -eq 0 ]]; then ok "modifying existing file: allowed (only adds blocked)"; else fail "modify-only blocked: $out"; fi
rm -rf "$TR9"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
