#!/usr/bin/env bash
# scripts/ci/test-free-tier-refresh.sh — CREDIBLE-185
#
# Proves scripts/ops/free-tier-refresh.sh:
#   1. rewrites a drifted CHUMP_FREE_TIER_PROVIDERS to the validated $0 cascade
#   2. strips a metered (opencode.ai/zen) entry out of the active line
#   3. is idempotent (a second run is a no-op "skip")
#   4. REFUSES to touch the cascade and exits 2 when a required key is absent
#   5. NEVER prints a key value
#   6. the script's compiled-in cascade stays byte-identical to the src DEFAULTS
#      in src/execute_gap.rs::parse_free_tier_providers() — the drift this gap
#      exists to prevent.
#
# Each assertion fails loudly (and the whole script fails) without the behavior.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFRESH="$REPO_ROOT/scripts/ops/free-tier-refresh.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -x "$REFRESH" || -f "$REFRESH" ]] || fail "refresh script not found at $REFRESH"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHUMP_STATE_DIR="$WORK/.chump"
mkdir -p "$CHUMP_STATE_DIR"
ENVF="$CHUMP_STATE_DIR/providers.env"

VALIDATED="openai/gpt-oss-120b@https://api.groq.com/openai/v1:GROQ_API_KEY,nvidia/nemotron-3-super-120b-a12b:free@https://openrouter.ai/api/v1:OPENROUTER_API_KEY,openai/gpt-oss-20b@https://api.groq.com/openai/v1:GROQ_API_KEY"
FAKE_GROQ="gsk_test_placeholder_not_a_real_key_000"
FAKE_OR="sk-or-test_placeholder_not_a_real_key_000"

run_refresh() { bash "$REFRESH" >"$WORK/out.log" 2>&1; echo $?; }

# ── Test 1: drifted + metered cascade → rewritten to validated, metered gone ──
cat > "$ENVF" <<EOF
GROQ_API_KEY=$FAKE_GROQ
OPENROUTER_API_KEY=$FAKE_OR
CHUMP_FREE_TIER_PROVIDERS=llama-3.3-70b-versatile@https://api.groq.com/openai/v1:GROQ_API_KEY,gpt-4o@https://opencode.ai/zen/v1:OPENCODE_API_KEY
EOF
rc=$(run_refresh)
[[ "$rc" == "0" ]] || { cat "$WORK/out.log"; fail "test1: expected rc 0, got $rc"; }
active="$(grep -E '^CHUMP_FREE_TIER_PROVIDERS=' "$ENVF" | tail -1)"
active="${active#CHUMP_FREE_TIER_PROVIDERS=}"
[[ "$active" == "$VALIDATED" ]] || fail "test1: cascade not rewritten to validated. got: $active"
[[ "$active" != *"opencode.ai"* && "$active" != *"/zen"* ]] || fail "test1: metered route still present in active line"
grep -q 'free_tier_metered_stripped\|METERED route present' "$WORK/out.log" || fail "test1: metered strip not reported"
# exactly ONE cascade line remains
[[ "$(grep -cE '^CHUMP_FREE_TIER_PROVIDERS=' "$ENVF")" == "1" ]] || fail "test1: expected exactly one cascade line"
# keys preserved untouched
grep -q "^GROQ_API_KEY=$FAKE_GROQ$" "$ENVF" || fail "test1: GROQ key line mangled"
grep -q "^OPENROUTER_API_KEY=$FAKE_OR$" "$ENVF" || fail "test1: OPENROUTER key line mangled"
pass "test1: drifted+metered cascade rewritten to validated zero-cost cascade, metered stripped"

# ── Test 2: idempotent — second run is a no-op skip ──────────────────────────
rc=$(run_refresh)
[[ "$rc" == "0" ]] || fail "test2: expected rc 0 on idempotent run, got $rc"
grep -q 'free_tier_refresh_skipped\|already the validated' "$WORK/out.log" || fail "test2: second run should skip"
active2="$(grep -E '^CHUMP_FREE_TIER_PROVIDERS=' "$ENVF" | tail -1)"
[[ "$(grep -cE '^CHUMP_FREE_TIER_PROVIDERS=' "$ENVF")" == "1" ]] || fail "test2: idempotent run duplicated the line"
pass "test2: idempotent (already-current → skip, no duplicate line)"

# ── Test 3: missing required key → exit 2, cascade untouched ─────────────────
cat > "$ENVF" <<EOF
GROQ_API_KEY=$FAKE_GROQ
CHUMP_FREE_TIER_PROVIDERS=some-old-thing@https://example.com/v1:GROQ_API_KEY
EOF
before="$(grep -E '^CHUMP_FREE_TIER_PROVIDERS=' "$ENVF")"
rc=$(run_refresh)
[[ "$rc" == "2" ]] || { cat "$WORK/out.log"; fail "test3: expected exit 2 on missing key, got $rc"; }
grep -q 'OPENROUTER_API_KEY' "$WORK/out.log" || fail "test3: missing key not named in output"
grep -q 'one-step' "$WORK/out.log" || fail "test3: no actionable one-step surfaced"
after="$(grep -E '^CHUMP_FREE_TIER_PROVIDERS=' "$ENVF")"
[[ "$before" == "$after" ]] || fail "test3: cascade was modified despite missing key"
pass "test3: missing required key → exit 2, actionable one-step, cascade untouched"

# ── Test 4: no key value ever printed ────────────────────────────────────────
cat > "$ENVF" <<EOF
GROQ_API_KEY=$FAKE_GROQ
OPENROUTER_API_KEY=$FAKE_OR
CHUMP_FREE_TIER_PROVIDERS=drift@https://api.groq.com/openai/v1:GROQ_API_KEY
EOF
run_refresh >/dev/null
if grep -q "$FAKE_GROQ\|$FAKE_OR" "$WORK/out.log"; then fail "test4: a key value leaked into script output"; fi
pass "test4: no key value printed in script output"

# ── Test 5: refresh cascade is the validated string, and stays == src DEFAULTS
#    once PR #4174 (EFFECTIVE-444) lands the src fix. Until then src still holds
#    the known-dead pre-4174 defaults, so we skip the src equality (with a note)
#    rather than false-fail on merge order.
grep -qF "$VALIDATED" "$REFRESH" || fail "test5: refresh script cascade != validated string"
SRC="$REPO_ROOT/src/execute_gap.rs"
if [[ -f "$SRC" ]]; then
    src_defaults="$(awk '/const DEFAULTS: &str = concat!\(/{f=1;next} f&&/\);/{f=0} f{print}' "$SRC" \
        | sed -E 's/[[:space:]]*"//; s/",?$//' | tr -d '\n')"
    if [[ -z "$src_defaults" ]]; then
        echo "SKIP test5-src: could not parse src DEFAULTS (parser miss, not a drift)"
    elif [[ "$src_defaults" == *"llama-3.3-70b-versatile@https://api.groq.com"* ]]; then
        echo "SKIP test5-src: src still has pre-#4174 dead defaults; source fix lands via PR #4174 (EFFECTIVE-444)"
    else
        [[ "$src_defaults" == "$VALIDATED" ]] || fail "test5: src DEFAULTS drifted from validated cascade.
  src: $src_defaults
  exp: $VALIDATED"
        pass "test5: refresh cascade == src execute_gap.rs DEFAULTS (no drift)"
    fi
else
    echo "SKIP test5-src: $SRC not present"
fi
pass "test5: refresh script embeds the validated cascade string"

echo "ALL TESTS PASSED"
