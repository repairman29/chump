#!/usr/bin/env bash
# INFRA-424 — verify CHUMP_LESSONS_AT_SPAWN_N is visible to the operator
# when set. Without this, the env can sit in a shell profile / .env and
# silently add N×~500 input tokens per spawn.
#
# We can't run the full Rust prompt assembler from a shell test without
# building chump, so this is a static check on the announce/visibility
# wiring + a one-shot semantic check (the announce function exists and
# is called from the spawn-lessons branch).

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASM="$REPO_ROOT/src/agent_loop/prompt_assembler.rs"

[[ -f "$ASM" ]] || { fail "prompt_assembler.rs missing"; exit 1; }
pass "prompt_assembler.rs exists"

# 1. announce_lessons_injection_active is defined.
grep -q 'fn announce_lessons_injection_active' "$ASM" \
    && pass "announce_lessons_injection_active() defined" \
    || fail "missing announce_lessons_injection_active() function"

# 2. ambient kind=lessons_injection_active emitted.
grep -q '"kind":"lessons_injection_active"' "$ASM" \
    && pass "ambient event kind=lessons_injection_active emitted" \
    || fail "missing kind=lessons_injection_active emit"

# 3. Process-once guard (so the announce fires once per process, not per
#    prompt assembly).
grep -q 'LESSONS_VISIBILITY_ONCE.*Once' "$ASM" \
    && pass "process-once guard wired" \
    || fail "missing once-per-process guard"

# 4. CHUMP_LESSONS_AT_SPAWN_ACK silences the warning when N>5.
grep -q 'CHUMP_LESSONS_AT_SPAWN_ACK' "$ASM" \
    && pass "CHUMP_LESSONS_AT_SPAWN_ACK env honored" \
    || fail "CHUMP_LESSONS_AT_SPAWN_ACK env not honored"

# 5. The announce is wired into the spawn_block branch (not just defined).
ANNOUNCE_LINE=$(grep -n 'announce_lessons_injection_active(n)' "$ASM" | head -1 | cut -d: -f1)
SPAWN_BRANCH_LINE=$(grep -n 'reflection_db::spawn_lessons_n' "$ASM" | head -1 | cut -d: -f1)
if [[ -n "$ANNOUNCE_LINE" && -n "$SPAWN_BRANCH_LINE" && "$ANNOUNCE_LINE" -gt "$SPAWN_BRANCH_LINE" ]]; then
    pass "announce called from spawn-lessons branch (line $ANNOUNCE_LINE)"
else
    fail "announce not called from spawn-lessons branch"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
