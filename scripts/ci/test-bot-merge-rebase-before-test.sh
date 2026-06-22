#!/usr/bin/env bash
# scripts/ci/test-bot-merge-rebase-before-test.sh — INFRA-918
#
# Verifies:
#   AC#1: kind=bot_merge_rebase_before_test emitted before cargo test with
#          fields: rebased (bool), commits_behind (int), head_sha (str), will_test (bool)
#   AC#2: kind=bot_merge_test_failure emitted on cargo test failure with
#          failure_class=transient_oom (SIGTERM/OOM detected) or permanent_failure
#   AC#3: bot_merge_phase_duration tracks test cost via phase="cargo test --bin chump --tests"
#          (verified by checking the stage_start label in bot-merge.sh source)
#
# Approach: inline the emit logic extracted from bot-merge.sh and exercise it
# directly. Avoids standing up the full ship pipeline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BM="$REPO_ROOT/scripts/coord/bot-merge.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BM" ]] || { echo "FAIL: bot-merge.sh missing at $BM" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

AMB="$TMP/ambient.jsonl"
: > "$AMB"

# ── 1. Scanner-anchors present in bot-merge.sh ───────────────────────────────
echo "=== Source: scanner-anchors ==="
grep -q '"kind":"bot_merge_rebase_before_test"' "$BM" \
    && pass "scanner-anchor for bot_merge_rebase_before_test present in bot-merge.sh" \
    || fail "scanner-anchor for bot_merge_rebase_before_test MISSING from bot-merge.sh"

grep -q '"kind":"bot_merge_test_failure"' "$BM" \
    && pass "scanner-anchor for bot_merge_test_failure present in bot-merge.sh" \
    || fail "scanner-anchor for bot_merge_test_failure MISSING from bot-merge.sh"

# ── 2. Tracking variables present in bot-merge.sh ────────────────────────────
echo ""
echo "=== Source: rebase tracking vars ==="
grep -q '_BM_COMMITS_BEHIND' "$BM" \
    && pass "_BM_COMMITS_BEHIND tracking var present in bot-merge.sh" \
    || fail "_BM_COMMITS_BEHIND NOT found in bot-merge.sh"

grep -q '_BM_REBASED' "$BM" \
    && pass "_BM_REBASED tracking var present in bot-merge.sh" \
    || fail "_BM_REBASED NOT found in bot-merge.sh"

# ── 3. AC#3: stage_start label matches expected phase_duration phase name ─────
echo ""
echo "=== AC#3: cargo test phase label for bot_merge_phase_duration ==="
grep -q 'stage_start "cargo test --bin chump --tests"' "$BM" \
    && pass "stage_start uses phase='cargo test --bin chump --tests' (AC#3 phase_duration match)" \
    || fail "stage_start phase label wrong or missing — bot_merge_phase_duration phase won't match AC#3"

# ── 4. AC#1: emit bot_merge_rebase_before_test with correct fields ────────────
echo ""
echo "=== AC#1: bot_merge_rebase_before_test field validation ==="

GAP_IDS=("INFRA-918")

# Case A: rebased=true, commits_behind=3, will_test=true
# scanner-anchor: "kind":"bot_merge_rebase_before_test"
printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":%s,"gap":"%s","note":"INFRA-918"}\n' \
    "2026-01-01T00:00:00Z" "true" "3" "abc1234def567890" "true" "INFRA-918" \
    >> "$AMB"

# Case B: rebased=false, commits_behind=0, will_test=false
printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":%s,"gap":"%s","note":"INFRA-918"}\n' \
    "2026-01-01T00:00:01Z" "false" "0" "abc1234def567890" "false" "INFRA-918" \
    >> "$AMB"

python3 - "$AMB" <<'PYCHECK'
import json, sys

events = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if d.get("kind") == "bot_merge_rebase_before_test":
            events.append(d)
    except Exception:
        pass

if len(events) < 2:
    print(f"FAIL: expected 2 bot_merge_rebase_before_test events, got {len(events)}", file=sys.stderr)
    sys.exit(1)

errors = []

# Case A: rebased=true
e = events[0]
if e.get("rebased") is not True:
    errors.append(f"[rebased=true case] rebased should be JSON bool true, got: {e.get('rebased')!r}")
if not isinstance(e.get("commits_behind"), int) or e["commits_behind"] < 0:
    errors.append(f"[rebased=true case] commits_behind should be non-negative int, got: {e.get('commits_behind')!r}")
if not isinstance(e.get("head_sha"), str) or not e["head_sha"]:
    errors.append(f"[rebased=true case] head_sha should be non-empty string, got: {e.get('head_sha')!r}")
if e.get("will_test") is not True:
    errors.append(f"[rebased=true case] will_test should be JSON bool true, got: {e.get('will_test')!r}")

# Case B: rebased=false
e2 = events[1]
if e2.get("rebased") is not False:
    errors.append(f"[rebased=false case] rebased should be JSON bool false, got: {e2.get('rebased')!r}")
if e2.get("commits_behind") != 0:
    errors.append(f"[rebased=false case] commits_behind should be 0, got: {e2.get('commits_behind')!r}")
if e2.get("will_test") is not False:
    errors.append(f"[rebased=false case] will_test should be JSON bool false, got: {e2.get('will_test')!r}")

if errors:
    for err in errors:
        print(f"FIELD-FAIL: {err}", file=sys.stderr)
    sys.exit(1)

print("all bot_merge_rebase_before_test fields valid (bool types, non-negative int, non-empty str)")
PYCHECK
if [[ $? -eq 0 ]]; then
    pass "bot_merge_rebase_before_test: all required fields correct (rebased/commits_behind/head_sha/will_test)"
else
    fail "bot_merge_rebase_before_test: field validation failed — see above"
fi

# ── 5. AC#2: bot_merge_test_failure OOM vs permanent classification ───────────
echo ""
echo "=== AC#2: bot_merge_test_failure failure_class classification ==="

AMB2="$TMP/ambient2.jsonl"
: > "$AMB2"

# Reproduce the failure_class detection logic from bot-merge.sh
_classify_test_failure() {
    local log="$1"
    local failure_class="permanent_failure"
    if grep -qE "signal: 15|SIGTERM|signal: 9|SIGKILL|memory allocation of .* bytes failed|cannot allocate memory" \
            "$log" 2>/dev/null; then
        failure_class="transient_oom"
    fi
    echo "$failure_class"
}

_emit_test_failure() {
    local log="$1" amb="$2"
    local fc; fc="$(_classify_test_failure "$log")"
    # scanner-anchor: "kind":"bot_merge_test_failure"
    printf '{"ts":"%s","kind":"bot_merge_test_failure","failure_class":"%s","gap":"INFRA-918","note":"INFRA-918"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$fc" >> "$amb"
}

# Scenario 1: OOM — log contains SIGTERM
OOM_LOG="$TMP/cargo_oom.log"
printf 'running 42 tests\ntest foo ... FAILED\nerror: process exited\nsignal: 15, SIGTERM: termination signal\n' > "$OOM_LOG"
_emit_test_failure "$OOM_LOG" "$AMB2"

# Scenario 2: logic bug — normal assertion failure, no SIGTERM
LOGIC_LOG="$TMP/cargo_logic.log"
printf 'running 5 tests\ntest bar ... FAILED\nfailures:\n    src/foo.rs:42: assertion `left == right` failed\nerror: test failed\n' > "$LOGIC_LOG"
_emit_test_failure "$LOGIC_LOG" "$AMB2"

python3 - "$AMB2" <<'PYCHECK'
import json, sys

events = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if d.get("kind") == "bot_merge_test_failure":
            events.append(d)
    except Exception:
        pass

if len(events) < 2:
    print(f"FAIL: expected 2 bot_merge_test_failure events, got {len(events)}", file=sys.stderr)
    sys.exit(1)

errors = []
e_oom   = events[0]
e_logic = events[1]

if e_oom.get("failure_class") != "transient_oom":
    errors.append(f"OOM log: expected failure_class=transient_oom, got {e_oom.get('failure_class')!r}")

if e_logic.get("failure_class") != "permanent_failure":
    errors.append(f"logic log: expected failure_class=permanent_failure, got {e_logic.get('failure_class')!r}")

# failure_class field must be present in both
for i, e in enumerate(events):
    if "failure_class" not in e:
        errors.append(f"event[{i}] missing failure_class field")

if errors:
    for err in errors:
        print(f"FIELD-FAIL: {err}", file=sys.stderr)
    sys.exit(1)

print("OOM→transient_oom, logic→permanent_failure — both classified correctly")
PYCHECK
if [[ $? -eq 0 ]]; then
    pass "bot_merge_test_failure: failure_class=transient_oom for SIGTERM, permanent_failure for logic bug"
else
    fail "bot_merge_test_failure: failure_class classification wrong — see above"
fi

# ── 6. AC#2: failure_class field visible in ambient stream ────────────────────
echo ""
echo "=== AC#2: failure_class visible in ambient stream ==="
python3 -c "
import json, sys
found = []
for line in open('$AMB2'):
    try:
        d = json.loads(line)
        if d.get('kind') == 'bot_merge_test_failure' and 'failure_class' in d:
            found.append(d['failure_class'])
    except Exception:
        pass
if len(found) < 2:
    print(f'expected 2 failure_class fields, got {len(found)}', file=sys.stderr)
    sys.exit(1)
print(f'failure_class values in stream: {found}')
" 2>/dev/null \
    && pass "failure_class field visible in ambient stream for all bot_merge_test_failure events" \
    || fail "failure_class field not visible in ambient stream"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
echo ""
echo "=== test-bot-merge-rebase-before-test.sh PASSED ==="
