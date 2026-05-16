#!/usr/bin/env bash
# test-chump-commit-auto-trailers.sh — INFRA-1467
#
# Verifies chump-commit.sh auto-injects bypass trailers when CHUMP_*_BYPASS
# env vars are set:
#   1. CHUMP_BYPASS_BOT_MERGE=1     → Bot-Merge-Bypass: trailer
#   2. CHUMP_TEST_GATE=0            → Test-Gate-Bypass: trailer
#   3. CHUMP_OBS_BUDGET_BYPASS=1    → Obs-Bypass-Reason: trailer
#   4. CHUMP_RUST_FIRST_CHECK=0     → Rust-First-Bypass: trailer
#   5. CHUMP_HARDCODED_DATE_CHECK=0 → Hardcoded-Date-Bypass: trailer
#   6. Existing trailer is NOT duplicated (idempotent)
#   7. CHUMP_BYPASS_REASON honored

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMIT="$REPO_ROOT/scripts/coord/chump-commit.sh"

echo "=== INFRA-1467 chump-commit auto-trailer tests ==="

[[ -f "$COMMIT" ]] || { echo "FAIL: $COMMIT missing"; exit 2; }

# ── Static checks: trailer-name + env-var pairs are all wired ──────────────
for pair in "CHUMP_BYPASS_BOT_MERGE:Bot-Merge-Bypass" \
            "CHUMP_TEST_GATE:Test-Gate-Bypass" \
            "CHUMP_OBS_BUDGET_BYPASS:Obs-Bypass-Reason" \
            "CHUMP_RUST_FIRST_CHECK:Rust-First-Bypass" \
            "CHUMP_HARDCODED_DATE_CHECK:Hardcoded-Date-Bypass"; do
    var="${pair%%:*}"
    trailer="${pair#*:}"
    if grep -qE "_inject_trailer \"$var\"\s+\"$trailer\"" "$COMMIT"; then
        ok "wired: $var → $trailer"
    else
        fail "wired: $var → $trailer (missing)"
    fi
done

# ── Static check: CHUMP_BYPASS_REASON honored ──────────────────────────────
if grep -q "CHUMP_BYPASS_REASON" "$COMMIT"; then
    ok "CHUMP_BYPASS_REASON env var consumed"
else
    fail "CHUMP_BYPASS_REASON not consumed"
fi

# ── Static check: idempotent (only injects when trailer not already present) ─
if grep -q 'grep -qE "\^\${trailer}:"' "$COMMIT"; then
    ok "idempotent: existing trailer not duplicated"
else
    fail "idempotent check missing — would duplicate trailer on re-invoke"
fi

# ── Functional: source the helpers into a fake env, run _inject_trailer ────
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build a wrapper that sources the inject_trailer fragment from the real
# chump-commit.sh and invokes it against a fake GIT_ARGS array.
wrapper="$TMP/wrapper.sh"
# Extract the _inject_trailer function definition + the calls from the real script.
awk '/^_bypass_reason=/,/^unset -f _inject_trailer/' "$COMMIT" > "$TMP/inject.sh"
cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -uo pipefail
GIT_ARGS=(-m "feat(TEST): some change")
$(cat "$TMP/inject.sh")
# Print the resulting -m value
for ((i=0; i<\${#GIT_ARGS[@]}; i++)); do
    if [[ "\${GIT_ARGS[\$i]}" == "-m" || "\${GIT_ARGS[\$i]}" == "--message" ]]; then
        echo "---MSG-START---"
        echo "\${GIT_ARGS[\$((i+1))]}"
        echo "---MSG-END---"
        break
    fi
done
EOF
chmod +x "$wrapper"

# Test each env-var individually.
test_inject() {
    local var_assignment="$1" expected_trailer="$2"
    local out
    out="$(env -i PATH="$PATH" bash -c "$var_assignment CHUMP_BYPASS_REASON='unit test' bash $wrapper" 2>&1 || true)"
    if echo "$out" | grep -qE "^${expected_trailer}: unit test"; then
        ok "functional: $var_assignment injects ${expected_trailer}"
    else
        fail "functional: $var_assignment did NOT inject ${expected_trailer}"
        echo "    out: $(echo "$out" | tr '\n' '|' | head -c 200)" >&2
    fi
}

test_inject "CHUMP_BYPASS_BOT_MERGE=1"      "Bot-Merge-Bypass"
test_inject "CHUMP_TEST_GATE=0"             "Test-Gate-Bypass"
test_inject "CHUMP_OBS_BUDGET_BYPASS=1"     "Obs-Bypass-Reason"
test_inject "CHUMP_RUST_FIRST_CHECK=0"      "Rust-First-Bypass"
test_inject "CHUMP_HARDCODED_DATE_CHECK=0"  "Hardcoded-Date-Bypass"

# ── Functional: no env set → no trailer injected ───────────────────────────
out_clean="$(env -i PATH="$PATH" bash "$wrapper" 2>&1 || true)"
if ! echo "$out_clean" | grep -qE '(Bot-Merge-Bypass|Test-Gate-Bypass|Obs-Bypass-Reason|Rust-First-Bypass|Hardcoded-Date-Bypass):'; then
    ok "functional: no env vars set → no trailer injected"
else
    fail "functional: trailer injected without env var set"
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
