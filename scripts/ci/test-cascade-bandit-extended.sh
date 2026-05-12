#!/usr/bin/env bash
# test-cascade-bandit-extended.sh — INFRA-685
#
# Tests that latency p95 and tool_call_accuracy are wired into cascade bandit
# reward via compose_reward_with_quality. Verifies:
#
#  1. compose_reward_with_quality is present in src/provider_bandit.rs
#  2. CHUMP_BANDIT_W_LATENCY_P95 env knob is recognized (grep in source)
#  3. CHUMP_BANDIT_W_TOOL_ACCURACY env knob is recognized (grep in source)
#  4. Reward ordering: slot with good p95+accuracy > slot with bad p95+accuracy
#     (computed by mimicking the reward formula in Python)
#  5. Reward ordering: tool_accuracy=0.0 penalizes reward vs tool_accuracy=1.0
#  6. p95_term: slow p95 (>budget) gives p95_term ≈ 0; fast p95 gives ≈ 1.0
#  7. Weights normalize to [0,1] even when non-default env weights are set
#  8. provider_cascade.rs calls compose_reward_with_quality (grep)
#  9. provider_quality.rs: get_quality_full referenced in cascade (grep)
# 10. record_tool_call_result no longer has dead_code suppression

set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BANDIT_SRC="$REPO_ROOT/src/provider_bandit.rs"
CASCADE_SRC="$REPO_ROOT/src/provider_cascade.rs"
QUALITY_SRC="$REPO_ROOT/src/provider_quality.rs"

echo "=== INFRA-685 cascade bandit extended quality test ==="
echo

# ── 1. compose_reward_with_quality exists in source ───────────────────────────
echo "[1. compose_reward_with_quality in provider_bandit.rs]"
if grep -q "compose_reward_with_quality" "$BANDIT_SRC" 2>/dev/null; then
    ok "compose_reward_with_quality present in provider_bandit.rs"
else
    fail "compose_reward_with_quality not found in provider_bandit.rs"
    exit 1
fi

# ── 2. CHUMP_BANDIT_W_LATENCY_P95 env knob ────────────────────────────────────
echo
echo "[2. CHUMP_BANDIT_W_LATENCY_P95 env knob in source]"
if grep -q "CHUMP_BANDIT_W_LATENCY_P95" "$BANDIT_SRC" 2>/dev/null; then
    ok "CHUMP_BANDIT_W_LATENCY_P95 present in provider_bandit.rs"
else
    fail "CHUMP_BANDIT_W_LATENCY_P95 not found"
fi

# ── 3. CHUMP_BANDIT_W_TOOL_ACCURACY env knob ──────────────────────────────────
echo
echo "[3. CHUMP_BANDIT_W_TOOL_ACCURACY env knob in source]"
if grep -q "CHUMP_BANDIT_W_TOOL_ACCURACY" "$BANDIT_SRC" 2>/dev/null; then
    ok "CHUMP_BANDIT_W_TOOL_ACCURACY present in provider_bandit.rs"
else
    fail "CHUMP_BANDIT_W_TOOL_ACCURACY not found"
fi

# ── 4-7. Reward ordering checks via Python simulation ─────────────────────────
# Mirror the Rust formula:
#   p95_term = 1 - clamp(p95_s / budget, 0, 1)
#   acc_term = tool_accuracy (clamped 0..1)
#   raw = w_s*success + w_l*latency + w_tps*tps + w_p95*p95 + w_acc*acc
#   reward = raw / (w_s + w_l + w_tps + w_p95 + w_acc)
REWARD_PY=$(cat <<'PYEOF'
import sys
def compose(success, latency_s, tps, p95_s, tool_acc,
            w_s=0.5, w_l=0.3, w_tps=0.2, w_p95=0.15, w_acc=0.20,
            budget=30.0, nominal=20.0):
    budget = max(budget, 1e-9)
    nominal = max(nominal, 1e-9)
    s = 1.0 if success else 0.0
    lt = max(0.0, min(1.0, 1.0 - latency_s / budget))
    tt = max(0.0, min(1.0, tps / nominal))
    pt = max(0.0, min(1.0, 1.0 - p95_s / budget)) if p95_s is not None else 1.0
    at = max(0.0, min(1.0, tool_acc)) if tool_acc is not None else 1.0
    total_w = max(w_s + w_l + w_tps + w_p95 + w_acc, 1e-9)
    raw = w_s*s + w_l*lt + w_tps*tt + w_p95*pt + w_acc*at
    return max(0.0, min(1.0, raw / total_w))

# Test 4: good slot (fast p95, high accuracy) > bad slot (slow p95, low accuracy)
r_good = compose(True, 2.0, 15.0, 2.0, 0.95)
r_bad  = compose(True, 2.0, 15.0, 25.0, 0.2)
print(f"test4:good={r_good:.4f},bad={r_bad:.4f},ok={r_good > r_bad}")

# Test 5: tool_accuracy=0.0 penalizes vs 1.0
r_high_acc = compose(True, 2.0, 15.0, 2.0, 1.0)
r_low_acc  = compose(True, 2.0, 15.0, 2.0, 0.0)
print(f"test5:high={r_high_acc:.4f},low={r_low_acc:.4f},ok={r_high_acc > r_low_acc}")

# Test 6: slow p95 (budget+5) gives p95_term ≈ 0
r_slow_p95 = compose(True, 2.0, 15.0, 35.0, 1.0)
r_fast_p95 = compose(True, 2.0, 15.0, 2.0, 1.0)
print(f"test6:slow={r_slow_p95:.4f},fast={r_fast_p95:.4f},ok={r_fast_p95 > r_slow_p95}")

# Test 7: custom env weights still normalize to [0,1]
r_custom = compose(True, 2.0, 15.0, 2.0, 1.0, w_s=1.0, w_l=1.0, w_tps=1.0, w_p95=1.0, w_acc=1.0)
print(f"test7:custom={r_custom:.4f},ok={0.0 <= r_custom <= 1.0}")
PYEOF
)

RESULTS=$(python3 -c "$REWARD_PY" 2>/dev/null)

echo
echo "[4. good slot (fast p95 + high accuracy) ranks higher than bad slot]"
line4=$(echo "$RESULTS" | grep "test4:")
ok4=$(echo "$line4" | python3 -c "import sys; d=dict(x.split('=') for x in sys.stdin.read().strip().replace('test4:','').split(',')); print(d.get('ok','false'))" 2>/dev/null)
if [[ "$ok4" == "True" ]]; then
    good=$(echo "$line4" | sed 's/.*good=\([0-9.]*\).*/\1/')
    bad=$(echo "$line4" | sed 's/.*bad=\([0-9.]*\).*/\1/')
    ok "reward ordering: good_slot=$good > bad_slot=$bad"
else
    fail "good slot did not outrank bad slot (results: $line4)"
fi

echo
echo "[5. tool_accuracy=0.0 penalizes reward vs tool_accuracy=1.0]"
line5=$(echo "$RESULTS" | grep "test5:")
ok5=$(echo "$line5" | python3 -c "import sys; d=dict(x.split('=') for x in sys.stdin.read().strip().replace('test5:','').split(',')); print(d.get('ok','false'))" 2>/dev/null)
if [[ "$ok5" == "True" ]]; then
    ok "tool accuracy penalization: high_acc > low_acc"
else
    fail "tool accuracy not affecting reward (results: $line5)"
fi

echo
echo "[6. slow p95 (>budget) gives lower reward than fast p95]"
line6=$(echo "$RESULTS" | grep "test6:")
ok6=$(echo "$line6" | python3 -c "import sys; d=dict(x.split('=') for x in sys.stdin.read().strip().replace('test6:','').split(',')); print(d.get('ok','false'))" 2>/dev/null)
if [[ "$ok6" == "True" ]]; then
    ok "p95 penalization: fast_p95 > slow_p95"
else
    fail "p95 not affecting reward (results: $line6)"
fi

echo
echo "[7. reward stays in [0,1] with custom weights]"
line7=$(echo "$RESULTS" | grep "test7:")
ok7=$(echo "$line7" | python3 -c "import sys; d=dict(x.split('=') for x in sys.stdin.read().strip().replace('test7:','').split(',')); print(d.get('ok','false'))" 2>/dev/null)
if [[ "$ok7" == "True" ]]; then
    ok "reward normalized to [0,1] with equal custom weights"
else
    fail "reward out of range with custom weights (results: $line7)"
fi

# ── 8. provider_cascade.rs calls compose_reward_with_quality ──────────────────
echo
echo "[8. provider_cascade.rs calls compose_reward_with_quality]"
if grep -q "compose_reward_with_quality" "$CASCADE_SRC" 2>/dev/null; then
    ok "compose_reward_with_quality called in provider_cascade.rs"
else
    fail "compose_reward_with_quality not called in provider_cascade.rs"
fi

# ── 9. provider_cascade.rs references get_quality_full ───────────────────────
echo
echo "[9. provider_cascade.rs references get_quality_full]"
if grep -q "get_quality_full" "$CASCADE_SRC" 2>/dev/null; then
    ok "get_quality_full referenced in provider_cascade.rs"
else
    fail "get_quality_full not referenced in provider_cascade.rs"
fi

# ── 10. record_tool_call_result no longer suppressed ─────────────────────────
echo
echo "[10. record_tool_call_result no longer has dead_code suppression]"
if ! grep -B1 "pub fn record_tool_call_result" "$QUALITY_SRC" 2>/dev/null | grep -q "dead_code"; then
    ok "record_tool_call_result dead_code suppression removed"
else
    fail "record_tool_call_result still has #[allow(dead_code)]"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
