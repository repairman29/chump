#!/usr/bin/env bash
# test-ship-assist-context-hook.sh — INFRA-2278
#
# Smoke test for the ship-assist context block in ambient-context-inject.sh.
# Three cases:
#   Case 1: synth 3 fixture VOAs with distinct wedge_class + minutes_lost;
#           assert top-3 block + correct ranking + kind=ship_assist_context_surfaced emit.
#   Case 2: empty-VOA fallback — assert "No real VOAs yet" + 7 seed classes shown.
#   Case 3: CHUMP_SHIP_ASSIST_HOOK=0 bypass — assert block NOT rendered.
#
# Usage: bash scripts/ci/test-ship-assist-context-hook.sh
# Exit:  0 all pass, 1 any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$(cd "$SCRIPT_DIR/../coord" && pwd)/ambient-context-inject.sh"

PASS=0
FAIL=0

_pass() { echo "  PASS: $1"; ((PASS++)) || true; }
_fail() { echo "  FAIL: $1"; ((FAIL++)) || true; }
_header() { echo ""; echo "=== $1 ==="; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Set up a minimal fake repo root with a valid ambient.jsonl so the hook
# doesn't short-circuit before reaching the ship-assist block.
_make_repo_root() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/.chump-locks"
    # Minimal ambient.jsonl so the hook doesn't emit_empty
    printf '{"ts":"2026-05-30T00:00:00Z","kind":"session_start","session":"test-session"}\n' \
        > "$tmpdir/.chump-locks/ambient.jsonl"
    echo "$tmpdir"
}

# Write a fixture VOA yaml with the given wedge_class and minutes_lost.
# $1=dir $2=id $3=wedge_class $4=minutes_lost
_write_voa() {
    local dir="$1" id="$2" wc="$3" ml="$4"
    mkdir -p "$dir/docs/voice"
    cat > "$dir/docs/voice/${id}.yaml" << YAML
id: $id
filed_at: "2026-05-30T01:00:00Z"
wedge_observations:
  - wedge_class: $wc
    minutes_lost: $ml
    reproducibility: deterministic
YAML
}

# Run the hook with CHUMP_AMBIENT_INJECT=1 but all the fleet-brief / inbox /
# roadmap features disabled so we get a deterministic, fast output.
# Returns combined stdout (the JSON blob) for inspection.
_run_hook() {
    local repo_root="$1"
    shift
    env \
    CHUMP_AMBIENT_LOG="$repo_root/.chump-locks/ambient.jsonl" \
    CHUMP_AMBIENT_SESSION_START_EMIT=0 \
    CHUMP_ROADMAP_INJECT=0 \
    CHUMP_A2A_INBOX_INJECT=0 \
    CHUMP_OPUS_INBOX_HOOK=0 \
    CHUMP_FLEET_BRIEF_INJECT=0 \
    CHUMP_SHIP_ASSIST_REPO="$repo_root" \
    "$@" \
    bash "$HOOK_SCRIPT" SessionStart 2>/dev/null
}

# ── Case 1: 3 fixture VOAs → top-3 ranked block ───────────────────────────────
_header "Case 1: 3 fixture VOAs → top-3 ranked block + ambient emit"

REPO1="$(_make_repo_root)"
# Rank should be: alpha (3×20=60) > beta (2×15=30) > gamma (1×10=10)
# But alpha has count=2 from two VOAs, beta count=1, gamma count=1
# Let's make: VOA-T01 has alpha(40), VOA-T02 has alpha(30) and beta(50), VOA-T03 has gamma(10)
# alpha: count=2 total_minutes_lost=70 score=140
# beta:  count=1 total_minutes_lost=50 score=50
# gamma: count=1 total_minutes_lost=10 score=10
# => alpha > beta > gamma

mkdir -p "$REPO1/docs/voice"
cat > "$REPO1/docs/voice/VOA-T01.yaml" << YAML
id: VOA-T01
filed_at: "2026-05-30T01:00:00Z"
wedge_observations:
  - wedge_class: alpha-wedge
    minutes_lost: 40
    reproducibility: deterministic
YAML

cat > "$REPO1/docs/voice/VOA-T02.yaml" << YAML
id: VOA-T02
filed_at: "2026-05-30T02:00:00Z"
wedge_observations:
  - wedge_class: alpha-wedge
    minutes_lost: 30
  - wedge_class: beta-wedge
    minutes_lost: 50
YAML

cat > "$REPO1/docs/voice/VOA-T03.yaml" << YAML
id: VOA-T03
filed_at: "2026-05-30T03:00:00Z"
wedge_observations:
  - wedge_class: gamma-wedge
    minutes_lost: 10
YAML

OUTPUT1="$(_run_hook "$REPO1")"

# Assert top-3 block present
if echo "$OUTPUT1" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d['hookSpecificOutput']['additionalContext']; assert 'Ship-assist context' in ctx" 2>/dev/null; then
    _pass "Ship-assist context header present"
else
    _fail "Ship-assist context header missing"
fi

# Assert alpha-wedge is first (highest score)
if echo "$OUTPUT1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ctx=d['hookSpecificOutput']['additionalContext']
lines=[l for l in ctx.splitlines() if 'alpha-wedge' in l or 'beta-wedge' in l or 'gamma-wedge' in l]
assert lines, 'no wedge class lines found'
assert 'alpha-wedge' in lines[0], f'alpha not first: {lines}'
assert 'beta-wedge' in lines[1], f'beta not second: {lines}'
assert 'gamma-wedge' in lines[2], f'gamma not third: {lines}'
" 2>/dev/null; then
    _pass "Ranking correct: alpha > beta > gamma"
else
    _fail "Ranking incorrect — expected alpha > beta > gamma"
    echo "$OUTPUT1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['hookSpecificOutput']['additionalContext'])" 2>/dev/null | grep -E "wedge|Ship-assist" || true
fi

# Assert filing prompt present
if echo "$OUTPUT1" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d['hookSpecificOutput']['additionalContext']; assert 'chump voice' in ctx and '--wedge-class' in ctx" 2>/dev/null; then
    _pass "Filing prompt (chump voice --wedge-class) present"
else
    _fail "Filing prompt missing"
fi

# Assert SHIP_ASSIST_PLAYBOOK.md pointer present
if echo "$OUTPUT1" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d['hookSpecificOutput']['additionalContext']; assert 'SHIP_ASSIST_PLAYBOOK.md' in ctx" 2>/dev/null; then
    _pass "SHIP_ASSIST_PLAYBOOK.md pointer present"
else
    _fail "SHIP_ASSIST_PLAYBOOK.md pointer missing"
fi

# Assert kind=ship_assist_context_surfaced was emitted to ambient.jsonl
if grep -q '"kind":"ship_assist_context_surfaced"' "$REPO1/.chump-locks/ambient.jsonl" 2>/dev/null; then
    _pass "kind=ship_assist_context_surfaced emitted to ambient.jsonl"
else
    _fail "kind=ship_assist_context_surfaced NOT emitted"
fi

# Assert emit is aggregate-only (no per-VOA identifiers like VOA-T01, VOA-T02, VOA-T03)
if python3 -c "
import json
with open('$REPO1/.chump-locks/ambient.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        d = json.loads(line)
        if d.get('kind') == 'ship_assist_context_surfaced':
            # Must have voa_count_last_7d and top_class_count
            assert 'voa_count_last_7d' in d, 'missing voa_count_last_7d'
            assert 'top_class_count' in d, 'missing top_class_count'
            # Must NOT contain VOA IDs in the payload
            payload_str = json.dumps(d)
            assert 'VOA-T01' not in payload_str, 'per-VOA ID leaked'
            assert 'VOA-T02' not in payload_str, 'per-VOA ID leaked'
            assert 'VOA-T03' not in payload_str, 'per-VOA ID leaked'
" 2>/dev/null; then
    _pass "Ambient emit is aggregate-only (no per-VOA IDs)"
else
    _fail "Ambient emit missing required fields or contains per-VOA IDs"
fi

rm -rf "$REPO1"

# ── Case 2: no VOAs → fallback seed classes ────────────────────────────────────
_header "Case 2: no VOAs → fallback seed classes"

REPO2="$(_make_repo_root)"
# No docs/voice/ directory at all → fallback path

OUTPUT2="$(_run_hook "$REPO2")"

if echo "$OUTPUT2" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d['hookSpecificOutput']['additionalContext']; assert 'No real VOAs yet' in ctx" 2>/dev/null; then
    _pass "'No real VOAs yet' fallback text present"
else
    _fail "'No real VOAs yet' fallback text missing"
fi

# Assert all 7 seed classes are listed
SEED_CLASSES=(
    "fmt-drift-queue-wide"
    "raw-gh-allowlist-miss"
    "sccache-R2-pair-mismatch"
    "bot-merge-silent-wedge"
    "sonnet-mid-task-stall"
    "claim-force-recover-wip-loss"
    "gap-status-auto-flip-silent-noop"
)
ALL_SEEDS_PRESENT=1
for wc in "${SEED_CLASSES[@]}"; do
    if ! echo "$OUTPUT2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ctx=d['hookSpecificOutput']['additionalContext']
assert '$wc' in ctx, 'missing: $wc'
" 2>/dev/null; then
        _fail "Seed class missing: $wc"
        ALL_SEEDS_PRESENT=0
    fi
done
[[ "$ALL_SEEDS_PRESENT" == "1" ]] && _pass "All 7 seed classes present in fallback"

rm -rf "$REPO2"

# ── Case 3: CHUMP_SHIP_ASSIST_HOOK=0 bypass ───────────────────────────────────
_header "Case 3: CHUMP_SHIP_ASSIST_HOOK=0 bypass"

REPO3="$(_make_repo_root)"
mkdir -p "$REPO3/docs/voice"
_write_voa "$REPO3" "VOA-B01" "some-wedge" 99

OUTPUT3="$(_run_hook "$REPO3" CHUMP_SHIP_ASSIST_HOOK=0)"

if echo "$OUTPUT3" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d['hookSpecificOutput']['additionalContext']; assert 'Ship-assist context' not in ctx" 2>/dev/null; then
    _pass "Ship-assist block NOT rendered when CHUMP_SHIP_ASSIST_HOOK=0"
else
    _fail "Ship-assist block rendered despite CHUMP_SHIP_ASSIST_HOOK=0"
fi

# Existing blocks still present — check FLEET-019 header
if echo "$OUTPUT3" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d['hookSpecificOutput']['additionalContext']; assert 'Ambient stream (FLEET-019' in ctx" 2>/dev/null; then
    _pass "FLEET-019 ambient stream block still present"
else
    _fail "FLEET-019 ambient stream block missing (regression)"
fi

rm -rf "$REPO3"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} PASS, ${FAIL} FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    echo "SMOKE TEST FAILED"
    exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
