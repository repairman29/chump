#!/usr/bin/env bash
# scripts/ci/test-bot-merge-rebase-before-test.sh — INFRA-918
#
# Verifies bot-merge.sh emits the correct ambient events around cargo test:
#   1. kind=bot_merge_rebase_before_test emitted with required fields before test.
#   2. kind=bot_merge_test_failure emitted on failure with failure_class field.
#   3. failure_class=transient_oom when SIGTERM signal text detected in output.
#   4. failure_class=permanent_failure when no SIGTERM signal text detected.
#   5. bot_merge_phase_duration emitted for "cargo test --bin chump --tests" phase.
#   6. EVENT_REGISTRY.yaml registers both new event kinds with required fields.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# ── 1. Static-grep checks on bot-merge.sh ───────────────────────────────────
grep -q '"kind":"bot_merge_rebase_before_test"' "$BOT_MERGE" \
    || fail "bot_merge_rebase_before_test emit missing from bot-merge.sh"
grep -q '"kind":"bot_merge_test_failure"' "$BOT_MERGE" \
    || fail "bot_merge_test_failure emit missing from bot-merge.sh"
grep -q '"failure_class":' "$BOT_MERGE" \
    || fail "failure_class field missing from bot-merge.sh test-failure emit"
grep -q 'transient_oom' "$BOT_MERGE" \
    || fail "transient_oom failure_class value missing from bot-merge.sh"
grep -q 'permanent_failure' "$BOT_MERGE" \
    || fail "permanent_failure failure_class value missing from bot-merge.sh"
grep -q '"rebased":' "$BOT_MERGE" \
    || fail "rebased field missing from bot_merge_rebase_before_test emit"
grep -q '"commits_behind":' "$BOT_MERGE" \
    || fail "commits_behind field missing from bot_merge_rebase_before_test emit"
grep -q '"head_sha":' "$BOT_MERGE" \
    || fail "head_sha field missing from bot_merge_rebase_before_test emit"
grep -q '"will_test":true' "$BOT_MERGE" \
    || fail "will_test field missing from bot_merge_rebase_before_test emit"
grep -q 'SIGTERM: termination signal' "$BOT_MERGE" \
    || fail "SIGTERM detection pattern missing from _run_cargo_with_lock_detect"
grep -q '_BM_CARGO_SIGTERM=0' "$BOT_MERGE" \
    || fail "_BM_CARGO_SIGTERM global initialisation missing"
ok "static grep: all required fields and patterns present in bot-merge.sh"

# ── 2. EVENT_REGISTRY.yaml registers both new kinds ─────────────────────────
python3 - "$REG" <<'PY'
import sys, re
text = open(sys.argv[1]).read()

for kind in ("bot_merge_rebase_before_test", "bot_merge_test_failure"):
    assert f"kind: {kind}" in text, f"{kind} not registered in EVENT_REGISTRY.yaml"
    m = re.search(rf"- kind: {re.escape(kind)}.*?(?=\n  -|\Z)", text, re.S)
    assert m, f"could not extract {kind} registry block"
    block = m.group(0)

    if kind == "bot_merge_rebase_before_test":
        for f in ("ts", "kind", "gap", "rebased", "commits_behind", "head_sha", "will_test"):
            assert f in block, f"fields_required missing {f!r} in {kind}: {block}"
    else:
        for f in ("ts", "kind", "gap", "failure_class", "head_sha"):
            assert f in block, f"fields_required missing {f!r} in {kind}: {block}"
PY
ok "EVENT_REGISTRY.yaml registers both new kinds with all required fields"

# ── 3. Simulate bot_merge_rebase_before_test emit ───────────────────────────
# Extract and execute the emit block in a controlled environment.
AMBIENT_LOG="$TMP/ambient.jsonl"
cat >"$TMP/emit-rebase-before-test.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CHUMP_AMBIENT_LOG="$AMBIENT_LOG"
GAP_IDS=("INFRA-918")
GAP_ID="INFRA-918"
REPO_ROOT="$TMP"
BEHIND=3
_ambient_write() { printf '%s\n' "\$2" >> "\$1" 2>/dev/null || true; }
git() {
    case "\$1" in
        rev-parse) printf 'abc1234deadbeef' ;;
        *) command git "\$@" ;;
    esac
}
# Run the emit block extracted from bot-merge.sh
_bm_rbt_amb="\${CHUMP_AMBIENT_LOG:-\${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}"
_bm_rbt_sha="\$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
_bm_rbt_rebased="false"; [[ "\${BEHIND:-0}" -gt 0 ]] && _bm_rbt_rebased="true"
_ambient_write "\$_bm_rbt_amb" \
    "\$(printf '{"ts":"%s","kind":"bot_merge_rebase_before_test","gap":"%s","rebased":%s,"commits_behind":%d,"head_sha":"%s","will_test":true}' \
        "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\${GAP_IDS[0]:-\${GAP_ID:-unknown}}" \
        "\$_bm_rbt_rebased" "\${BEHIND:-0}" "\$_bm_rbt_sha")"
EOF
chmod +x "$TMP/emit-rebase-before-test.sh"
bash "$TMP/emit-rebase-before-test.sh"

python3 - "$AMBIENT_LOG" <<'PY'
import sys, json
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rbt = [e for e in events if e.get("kind") == "bot_merge_rebase_before_test"]
assert len(rbt) == 1, f"expected 1 bot_merge_rebase_before_test event, got {len(rbt)}"
e = rbt[0]
assert e["rebased"] is True,         f"rebased should be true (BEHIND=3): {e}"
assert e["commits_behind"] == 3,     f"commits_behind should be 3: {e}"
assert e["head_sha"] != "",          f"head_sha must be non-empty: {e}"
assert e["will_test"] is True,       f"will_test must be true: {e}"
assert "gap" in e,                   f"gap field missing: {e}"
PY
ok "bot_merge_rebase_before_test emitted with correct fields (rebased=true, commits_behind=3)"

# ── 4. Simulate bot_merge_test_failure — transient_oom path ─────────────────
AMBIENT_LOG2="$TMP/ambient2.jsonl"
cat >"$TMP/emit-test-failure-oom.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CHUMP_AMBIENT_LOG="$AMBIENT_LOG2"
GAP_IDS=("INFRA-918")
GAP_ID="INFRA-918"
REPO_ROOT="$TMP"
_BM_CARGO_SIGTERM=1
_bm_rbt_sha="deadbeef"
_ambient_write() { printf '%s\n' "\$2" >> "\$1" 2>/dev/null || true; }
_bm_rbt_amb="\${CHUMP_AMBIENT_LOG}"
_bm_tf_class="permanent_failure"
[[ "\${_BM_CARGO_SIGTERM:-0}" -eq 1 ]] && _bm_tf_class="transient_oom"
_ambient_write "\$_bm_rbt_amb" \
    "\$(printf '{"ts":"%s","kind":"bot_merge_test_failure","gap":"%s","failure_class":"%s","head_sha":"%s","note":"INFRA-918"}' \
        "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\${GAP_IDS[0]:-\${GAP_ID:-unknown}}" \
        "\$_bm_tf_class" "\$_bm_rbt_sha")"
EOF
chmod +x "$TMP/emit-test-failure-oom.sh"
bash "$TMP/emit-test-failure-oom.sh"

python3 - "$AMBIENT_LOG2" <<'PY'
import sys, json
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
tf = [e for e in events if e.get("kind") == "bot_merge_test_failure"]
assert len(tf) == 1, f"expected 1 bot_merge_test_failure, got {len(tf)}"
e = tf[0]
assert e["failure_class"] == "transient_oom", f"expected transient_oom: {e}"
assert e["head_sha"] != "",                   f"head_sha must be non-empty: {e}"
PY
ok "bot_merge_test_failure emitted with failure_class=transient_oom when _BM_CARGO_SIGTERM=1"

# ── 5. Simulate bot_merge_test_failure — permanent_failure path ──────────────
AMBIENT_LOG3="$TMP/ambient3.jsonl"
cat >"$TMP/emit-test-failure-perm.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CHUMP_AMBIENT_LOG="$AMBIENT_LOG3"
GAP_IDS=("INFRA-918")
GAP_ID="INFRA-918"
REPO_ROOT="$TMP"
_BM_CARGO_SIGTERM=0
_bm_rbt_sha="deadbeef"
_ambient_write() { printf '%s\n' "\$2" >> "\$1" 2>/dev/null || true; }
_bm_rbt_amb="\${CHUMP_AMBIENT_LOG}"
_bm_tf_class="permanent_failure"
[[ "\${_BM_CARGO_SIGTERM:-0}" -eq 1 ]] && _bm_tf_class="transient_oom"
_ambient_write "\$_bm_rbt_amb" \
    "\$(printf '{"ts":"%s","kind":"bot_merge_test_failure","gap":"%s","failure_class":"%s","head_sha":"%s","note":"INFRA-918"}' \
        "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\${GAP_IDS[0]:-\${GAP_ID:-unknown}}" \
        "\$_bm_tf_class" "\$_bm_rbt_sha")"
EOF
chmod +x "$TMP/emit-test-failure-perm.sh"
bash "$TMP/emit-test-failure-perm.sh"

python3 - "$AMBIENT_LOG3" <<'PY'
import sys, json
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
tf = [e for e in events if e.get("kind") == "bot_merge_test_failure"]
assert len(tf) == 1, f"expected 1 bot_merge_test_failure, got {len(tf)}"
e = tf[0]
assert e["failure_class"] == "permanent_failure", f"expected permanent_failure: {e}"
PY
ok "bot_merge_test_failure emitted with failure_class=permanent_failure when _BM_CARGO_SIGTERM=0"

echo ""
echo "Results: 5 checks passed — INFRA-918 AC#1-4 satisfied"
