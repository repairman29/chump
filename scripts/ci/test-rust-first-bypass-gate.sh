#!/usr/bin/env bash
# test-rust-first-bypass-gate.sh — INFRA-1580
#
# Exercises the STRICT machine-acknowledgment layer added to the
# Rust-first pre-commit gate. The original test-rust-first-gate.sh covers
# the basic gate (block / narrative-bypass-allow). This test focuses on
# the new INFRA-1580 behavior:
#
#   (a) Clean glue, no bypass needed   → ACCEPT (not in hot dir, no triggers)
#   (b) Hot-path violations + only-narrative Rust-First-Bypass: trailer
#       AND 2+ strict-criteria failures → REJECT
#   (c) Hot-path violations + narrative bypass + Rust-First-Bypass-Accept:
#       trailer covering all strict failures → ACCEPT
#
# Strict criteria checked: loc, state, hot, test (see hook header).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/git-hooks/pre-commit-rust-first.sh"

echo "=== INFRA-1580 Rust-first STRICT bypass gate tests ==="
[[ -x "$GATE" ]] || { fail "gate not executable at $GATE"; echo "FAIL"; exit 1; }
ok "gate present + executable"

mk_repo() {
    local d
    d="$(mktemp -d -t rust-first-strict.XXXXXX)"
    (
        cd "$d"
        git init -q
        git config user.email test@test.local
        git config user.name test
        mkdir -p .git/info
        git commit --allow-empty -q -m "init"
    )
    printf '%s\n' "$d"
}

run_gate() {
    local repo="$1" msg="$2"
    (
        cd "$repo"
        printf '%s\n' "$msg" > .git/COMMIT_EDITMSG
        git add -A 2>/dev/null
        bash "$GATE" 2>&1
    )
}

# Fixture builder: a "bad daemon" — > 200 LOC, hot loop, mutates state,
# no test sibling.
mk_bad_daemon() {
    local path="$1"
    {
        echo '#!/usr/bin/env bash'
        echo '# bad-daemon — hot daemon with state mutation'
        echo 'set -euo pipefail'
        echo 'while true; do'
        echo '    echo "{\"kind\":\"foo\"}" >> .chump-locks/ambient.jsonl'
        echo '    sleep 5'
        echo 'done'
        # Pad to > 200 LOC.
        for i in $(seq 1 250); do
            echo "# filler line $i"
        done
    } > "$path"
}

# ── Fixture (a): Clean glue, no bypass needed → ACCEPT ───────────────────────
echo ""
echo "Fixture (a): clean glue, no bypass needed"
TR_A="$(mk_repo)"
mkdir -p "$TR_A/scripts/ops"
cat > "$TR_A/scripts/ops/clean-glue.sh" <<'EOF'
#!/usr/bin/env bash
# Simple gh + jq glue, no state mutation, no hot loop, < 200 LOC.
gh pr list --json number,title | jq -r '.[] | "#\(.number) \(.title)"'
EOF
out_a="$(run_gate "$TR_A" "tmp: glue")"; rc_a=$?
if [[ $rc_a -eq 0 ]]; then
    ok "(a) clean glue: accepted (rc=0)"
else
    fail "(a) clean glue rejected unexpectedly (rc=$rc_a): $out_a"
fi
rm -rf "$TR_A"

# ── Fixture (b): Bad daemon + only narrative bypass → REJECT ─────────────────
echo ""
echo "Fixture (b): bad daemon + narrative-only bypass"
TR_B="$(mk_repo)"
mkdir -p "$TR_B/scripts/coord" "$TR_B/.chump-locks"
mk_bad_daemon "$TR_B/scripts/coord/bad-daemon.sh"
MSG_B="feat: add bad daemon

This is gh + jq glue, totally fine.

Rust-First-Bypass: glue between gh and jq, single-shot, additive"
out_b="$(run_gate "$TR_B" "$MSG_B")"; rc_b=$?
if [[ $rc_b -ne 0 ]] \
    && echo "$out_b" | grep -q 'STRICT gate (INFRA-1580)' \
    && echo "$out_b" | grep -q 'Rust-First-Bypass-Accept:'; then
    ok "(b) narrative-only bypass rejected with strict-gate message"
else
    fail "(b) narrative-only should be rejected by strict gate (rc=$rc_b)"
    echo "----- output:" >&2
    printf '%s\n' "$out_b" >&2
    echo "-----" >&2
fi
# Verify strict ambient emit fires on rejection.
if [[ -f "$TR_B/.chump-locks/ambient.jsonl" ]] \
    && grep -q '"kind":"rust_first_strict_blocked"' "$TR_B/.chump-locks/ambient.jsonl"; then
    ok "(b) emits kind=rust_first_strict_blocked to ambient"
else
    fail "(b) did not emit rust_first_strict_blocked"
fi
rm -rf "$TR_B"

# ── Fixture (c): Bad daemon + narrative + machine-acked bypass → ACCEPT ──────
echo ""
echo "Fixture (c): bad daemon + full Rust-First-Bypass-Accept coverage"
TR_C="$(mk_repo)"
mkdir -p "$TR_C/scripts/coord" "$TR_C/.chump-locks"
mk_bad_daemon "$TR_C/scripts/coord/bad-daemon.sh"
MSG_C="feat: add bad daemon, eyes wide open

We know it's a hot-path daemon mutating state; here are the tradeoffs:
- loc:  needed for stage gating (will port in INFRA-NEXT)
- state: writes ambient.jsonl per tick (audit signal)
- hot:  while-true is intentional; runs as launchd KeepAlive
- test: will land in INFRA-NEXT+1

Rust-First-Bypass: stage-gated migration script; full port tracked as INFRA-NEXT
Rust-First-Bypass-Accept: loc,state,hot,test"
out_c="$(run_gate "$TR_C" "$MSG_C")"; rc_c=$?
if [[ $rc_c -eq 0 ]]; then
    ok "(c) machine-acked bypass: accepted (rc=0)"
else
    fail "(c) machine-acked should be accepted (rc=$rc_c): $out_c"
fi
# bypass_used emit should still fire.
if [[ -f "$TR_C/.chump-locks/ambient.jsonl" ]] \
    && grep -q '"kind":"rust_first_bypass_used"' "$TR_C/.chump-locks/ambient.jsonl"; then
    ok "(c) emits kind=rust_first_bypass_used to ambient"
else
    fail "(c) did not emit rust_first_bypass_used"
fi
rm -rf "$TR_C"

# ── Fixture (d): Bad daemon + partial Rust-First-Bypass-Accept → REJECT ──────
echo ""
echo "Fixture (d): bad daemon + only partial machine-ack (missing 'test')"
TR_D="$(mk_repo)"
mkdir -p "$TR_D/scripts/coord" "$TR_D/.chump-locks"
mk_bad_daemon "$TR_D/scripts/coord/bad-daemon.sh"
MSG_D="feat: bad daemon partial ack

Rust-First-Bypass: stage-gated migration
Rust-First-Bypass-Accept: loc,state,hot"
out_d="$(run_gate "$TR_D" "$MSG_D")"; rc_d=$?
if [[ $rc_d -ne 0 ]] && echo "$out_d" | grep -q 'no scripts/ci/test-'; then
    ok "(d) partial-ack (missing test): rejected with unacknowledged-test reason"
else
    fail "(d) partial-ack should still reject for unacked 'test' (rc=$rc_d)"
    echo "----- output:" >&2
    printf '%s\n' "$out_d" >&2
    echo "-----" >&2
fi
rm -rf "$TR_D"

# ── Fixture (e): MODIFIED existing bypass file + insufficient ack → REJECT ────
echo ""
echo "Fixture (e): MODIFIED file with Rust-First-Bypass: header, 2+ criteria, no Accept"
TR_E="$(mk_repo)"
mkdir -p "$TR_E/scripts/coord" "$TR_E/.chump-locks"
# Commit the bad daemon (with bypass header) as an existing file first.
mk_bad_daemon "$TR_E/scripts/coord/bad-daemon.sh"
# Add a Rust-First-Bypass: header so the modified-gate recognises it.
echo "# Rust-First-Bypass: pre-existing bypass — glue script" \
    >> "$TR_E/scripts/coord/bad-daemon.sh"
(
    cd "$TR_E"
    git add scripts/coord/bad-daemon.sh
    CHUMP_RUST_FIRST_CHECK=0 git commit -q -m "init: add daemon"
)
# Now modify the file (add a comment line) so it shows up as diff-filter=M.
echo "# a small change" >> "$TR_E/scripts/coord/bad-daemon.sh"
MSG_E="fix: tweak bad daemon

Rust-First-Bypass: still just glue"
out_e="$(run_gate "$TR_E" "$MSG_E")"; rc_e=$?
if [[ $rc_e -ne 0 ]] && echo "$out_e" | grep -q 'STRICT gate (INFRA-1580)'; then
    ok "(e) MODIFIED file w/ bypass header, no Accept: rejected by strict gate"
else
    fail "(e) should reject MODIFIED file with 2+ unacked criteria (rc=$rc_e)"
    echo "----- output:" >&2
    printf '%s\n' "$out_e" >&2
    echo "-----" >&2
fi
rm -rf "$TR_E"

# ── Fixture (f): MODIFIED file + full Accept → ACCEPT ────────────────────────
echo ""
echo "Fixture (f): MODIFIED file with Rust-First-Bypass: header, full Accept → ACCEPT"
TR_F="$(mk_repo)"
mkdir -p "$TR_F/scripts/coord" "$TR_F/.chump-locks"
mk_bad_daemon "$TR_F/scripts/coord/bad-daemon.sh"
echo "# Rust-First-Bypass: pre-existing bypass — glue script" \
    >> "$TR_F/scripts/coord/bad-daemon.sh"
(
    cd "$TR_F"
    git add scripts/coord/bad-daemon.sh
    CHUMP_RUST_FIRST_CHECK=0 git commit -q -m "init: add daemon"
)
echo "# a small change" >> "$TR_F/scripts/coord/bad-daemon.sh"
MSG_F="fix: tweak bad daemon, eyes wide open

Rust-First-Bypass: stage-gated migration; port tracked as INFRA-NEXT
Rust-First-Bypass-Accept: loc,state,hot,test"
out_f="$(run_gate "$TR_F" "$MSG_F")"; rc_f=$?
if [[ $rc_f -eq 0 ]]; then
    ok "(f) MODIFIED file w/ full Accept: accepted"
else
    fail "(f) MODIFIED file w/ full Accept should be accepted (rc=$rc_f): $out_f"
fi
rm -rf "$TR_F"

# ── Fixture (g): CHUMP_RUST_FIRST_AUDIT=1 mode → emits audit events ──────────
echo ""
echo "Fixture (g): CHUMP_RUST_FIRST_AUDIT=1 emits kind=rust_first_bypass_audit"
TR_G="$(mk_repo)"
mkdir -p "$TR_G/scripts/coord" "$TR_G/.chump-locks"
mk_bad_daemon "$TR_G/scripts/coord/bad-daemon.sh"
# Add a Rust-First-Bypass: header to the file so the audit picks it up.
sed -i.bak '2a # Rust-First-Bypass: test bypass for audit' \
    "$TR_G/scripts/coord/bad-daemon.sh" 2>/dev/null \
    || { echo "# Rust-First-Bypass: test bypass for audit" >> "$TR_G/scripts/coord/bad-daemon.sh"; }
rm -f "$TR_G/scripts/coord/bad-daemon.sh.bak"
(
    cd "$TR_G"
    git add scripts/coord/bad-daemon.sh
    CHUMP_RUST_FIRST_CHECK=0 git commit -q -m "init: add daemon with bypass"
)
out_g="$(
    cd "$TR_G"
    CHUMP_RUST_FIRST_AUDIT=1 CHUMP_AMBIENT_LOG="$TR_G/.chump-locks/ambient.jsonl" \
        bash "$GATE" 2>&1
)"; rc_g=$?
if [[ $rc_g -eq 0 ]]; then
    ok "(g) audit mode exits 0"
else
    fail "(g) audit mode should exit 0 (rc=$rc_g): $out_g"
fi
if [[ -f "$TR_G/.chump-locks/ambient.jsonl" ]] \
    && grep -q '"kind":"rust_first_bypass_audit"' "$TR_G/.chump-locks/ambient.jsonl"; then
    ok "(g) audit mode emits kind=rust_first_bypass_audit to ambient"
else
    fail "(g) audit mode did not emit rust_first_bypass_audit"
    echo "ambient contents:" >&2
    cat "$TR_G/.chump-locks/ambient.jsonl" 2>/dev/null || echo "(missing)" >&2
fi
rm -rf "$TR_G"

echo ""
echo "=== Summary: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "OK"
exit 0
