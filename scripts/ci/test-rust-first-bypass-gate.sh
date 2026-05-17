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

echo ""
echo "=== Summary: $PASS pass, $FAIL fail ==="
if (( FAIL > 0 )); then
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
echo "OK"
exit 0
