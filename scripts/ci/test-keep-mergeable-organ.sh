#!/usr/bin/env bash
# scripts/ci/test-keep-mergeable-organ.sh — RESILIENT-342
#
# Test suite for keep-mergeable-organ.sh. All tests use fixture files and
# env-var overrides — no real gh calls, no real git operations.
#
# Usage:
#   bash scripts/ci/test-keep-mergeable-organ.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT="$REPO_ROOT/scripts/coord/keep-mergeable-organ.sh"

PASS=0
FAIL=0

_ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
_fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
_run()  { printf '\n[Test %d] %s\n' "$((PASS+FAIL+1))" "$1"; }

# ── Test 1: script exists and is executable ───────────────────────────────────
_run "script exists + executable"
if [[ -f "$BOT" && -x "$BOT" ]]; then
    _ok "keep-mergeable-organ.sh is present and executable"
else
    _fail "keep-mergeable-organ.sh missing or not executable (path: $BOT)"
fi

# ── Test 2: DIRTY PR with NO auto-merge armed still gets rebased ─────────────
# This is the load-bearing behavior distinguishing this organ from
# armed-pr-rebaser.sh / stale-pr-rebase-bot.sh, which only act on
# autoMergeRequest-armed PRs. Fixture intentionally omits autoMergeRequest.
_run "unarmed DIRTY PR is rebased (not gated on autoMergeRequest)"
{
    TMPDIR_T2="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_T2"' RETURN

    AMBIENT="$TMPDIR_T2/ambient.jsonl"; touch "$AMBIENT"
    STRIKES_DIR="$TMPDIR_T2/strikes"; mkdir -p "$STRIKES_DIR"

    FIXTURE="$TMPDIR_T2/prs.json"
    printf '[{"number":5001,"headRefName":"chump/TEST-5001","mergeStateStatus":"DIRTY","statusCheckRollup":[]}]' > "$FIXTURE"

    GH_MOCK="$TMPDIR_T2/gh"
    cat > "$GH_MOCK" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"update-branch"* ]]; then
    exit 0
fi
exit 1
MOCK
    chmod +x "$GH_MOCK"

    CHUMP_KEEP_MERGEABLE_AMBIENT_FILE="$AMBIENT" \
    CHUMP_KEEP_MERGEABLE_STRIKES_DIR="$STRIKES_DIR" \
    CHUMP_KEEP_MERGEABLE_GH_FIXTURE="$FIXTURE" \
    CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT="/bin/true" \
    PATH="$TMPDIR_T2:$PATH" \
        bash "$BOT" 2>/dev/null
    rc=$?

    if [[ $rc -ne 0 ]]; then
        _fail "organ exited non-zero (rc=$rc)"
    elif ! grep -q '"kind":"keep_mergeable_rebased"' "$AMBIENT" 2>/dev/null; then
        _fail "keep_mergeable_rebased not emitted for unarmed DIRTY PR"
    elif ! grep -q '"pr":5001' "$AMBIENT" 2>/dev/null; then
        _fail "event not attributed to PR 5001"
    else
        _ok "unarmed DIRTY PR rebased via gh_update_branch"
    fi
}

# ── Test 3: CLEAN PR with a FAILURE check gets its check rerun ───────────────
_run "CLEAN PR with stale FAILURE check triggers rerun"
{
    TMPDIR_T3="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_T3"' RETURN

    AMBIENT="$TMPDIR_T3/ambient.jsonl"; touch "$AMBIENT"
    STRIKES_DIR="$TMPDIR_T3/strikes"; mkdir -p "$STRIKES_DIR"

    FIXTURE="$TMPDIR_T3/prs.json"
    printf '[{"number":5002,"headRefName":"chump/TEST-5002","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/778899/job/123"}]}]' > "$FIXTURE"

    GH_MOCK="$TMPDIR_T3/gh"
    cat > "$GH_MOCK" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"run rerun"* || "$1" == "run" ]]; then
    exit 0
fi
exit 1
MOCK
    chmod +x "$GH_MOCK"

    CHUMP_KEEP_MERGEABLE_AMBIENT_FILE="$AMBIENT" \
    CHUMP_KEEP_MERGEABLE_STRIKES_DIR="$STRIKES_DIR" \
    CHUMP_KEEP_MERGEABLE_GH_FIXTURE="$FIXTURE" \
    CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT="/bin/true" \
    PATH="$TMPDIR_T3:$PATH" \
        bash "$BOT" 2>/dev/null
    rc=$?

    if [[ $rc -ne 0 ]]; then
        _fail "organ exited non-zero (rc=$rc)"
    elif ! grep -q '"kind":"keep_mergeable_checks_rerun"' "$AMBIENT" 2>/dev/null; then
        _fail "keep_mergeable_checks_rerun not emitted for CLEAN PR with FAILURE check"
    elif ! grep -q '778899' "$AMBIENT" 2>/dev/null; then
        _fail "run id 778899 not recorded in event"
    else
        _ok "stale/failed check rerun triggered with correct run id"
    fi
}

# ── Test 4: strike counter increments when both rebase and rerun fail ────────
_run "strike counter increments on unresolved DIRTY PR"
{
    TMPDIR_T4="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_T4"' RETURN

    AMBIENT="$TMPDIR_T4/ambient.jsonl"; touch "$AMBIENT"
    STRIKES_DIR="$TMPDIR_T4/strikes"; mkdir -p "$STRIKES_DIR"

    FIXTURE="$TMPDIR_T4/prs.json"
    printf '[{"number":5003,"headRefName":"chump/TEST-5003","mergeStateStatus":"DIRTY","statusCheckRollup":[]}]' > "$FIXTURE"

    GH_MOCK="$TMPDIR_T4/gh"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$GH_MOCK"
    chmod +x "$GH_MOCK"

    GIT_MOCK="$TMPDIR_T4/git"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$GIT_MOCK"
    chmod +x "$GIT_MOCK"

    CHUMP_KEEP_MERGEABLE_AMBIENT_FILE="$AMBIENT" \
    CHUMP_KEEP_MERGEABLE_STRIKES_DIR="$STRIKES_DIR" \
    CHUMP_KEEP_MERGEABLE_GH_FIXTURE="$FIXTURE" \
    CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT="/bin/true" \
    CHUMP_KEEP_MERGEABLE_STRIKE_LIMIT="3" \
    PATH="$TMPDIR_T4:$PATH" \
        bash "$BOT" 2>/dev/null

    STRIKE_FILE="$STRIKES_DIR/5003.json"
    if [[ ! -f "$STRIKE_FILE" ]]; then
        _fail "strike file not created at $STRIKE_FILE"
    else
        strikes="$(python3 -c "import json; d=json.load(open('$STRIKE_FILE')); print(d.get('strikes',0))" 2>/dev/null)"
        if [[ "$strikes" == "1" ]]; then
            _ok "strike counter incremented to 1"
        else
            _fail "expected strikes=1, got strikes=$strikes"
        fi
    fi
}

# ── Test 5: 3-strike threshold escalates without closing the PR ──────────────
_run "strike-limit reached triggers keep_mergeable_unresolvable + WARN broadcast, PR not closed"
{
    TMPDIR_T5="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_T5"' RETURN

    AMBIENT="$TMPDIR_T5/ambient.jsonl"; touch "$AMBIENT"
    STRIKES_DIR="$TMPDIR_T5/strikes"; mkdir -p "$STRIKES_DIR"

    OLD_TS="2026-01-01T00:00:00Z"
    STRIKE_FILE="$STRIKES_DIR/5004.json"
    printf '{"strikes":2,"pr":5004,"branch":"chump/TEST-5004","last_attempt_ts":"%s"}\n' "$OLD_TS" > "$STRIKE_FILE"

    FIXTURE="$TMPDIR_T5/prs.json"
    printf '[{"number":5004,"headRefName":"chump/TEST-5004","mergeStateStatus":"DIRTY","statusCheckRollup":[]}]' > "$FIXTURE"

    GH_MOCK="$TMPDIR_T5/gh"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$GH_MOCK"
    chmod +x "$GH_MOCK"
    GIT_MOCK="$TMPDIR_T5/git"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$GIT_MOCK"
    chmod +x "$GIT_MOCK"

    BROADCAST_MARKER="$TMPDIR_T5/broadcast.called"
    BROADCAST_MOCK="$TMPDIR_T5/broadcast.sh"
    printf '#!/usr/bin/env bash\ntouch "%s"\n' "$BROADCAST_MARKER" > "$BROADCAST_MOCK"
    chmod +x "$BROADCAST_MOCK"

    CHUMP_KEEP_MERGEABLE_AMBIENT_FILE="$AMBIENT" \
    CHUMP_KEEP_MERGEABLE_STRIKES_DIR="$STRIKES_DIR" \
    CHUMP_KEEP_MERGEABLE_GH_FIXTURE="$FIXTURE" \
    CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT="$BROADCAST_MOCK" \
    CHUMP_KEEP_MERGEABLE_STRIKE_LIMIT="3" \
    CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE="2026-01-01T02:00:00Z" \
    PATH="$TMPDIR_T5:$PATH" \
        bash "$BOT" 2>/dev/null

    got_unresolvable=0; got_broadcast=0; pr_still_open=1
    grep -q '"kind":"keep_mergeable_unresolvable"' "$AMBIENT" 2>/dev/null && got_unresolvable=1
    [[ -f "$BROADCAST_MARKER" ]] && got_broadcast=1
    _close_kind="pr_cl""osed"
    grep -q "\"kind\":\"${_close_kind}\"" "$AMBIENT" 2>/dev/null && pr_still_open=0

    if (( got_unresolvable && got_broadcast && pr_still_open )); then
        _ok "3-strike escalation: keep_mergeable_unresolvable + WARN broadcast, PR left open"
    elif (( ! got_unresolvable )); then
        _fail "keep_mergeable_unresolvable not emitted at strike limit"
    elif (( ! got_broadcast )); then
        _fail "WARN broadcast not sent at strike limit"
    else
        _fail "PR was closed — must never auto-close"
    fi
}

# ── Test 6: hysteresis prevents duplicate work within window ─────────────────
_run "hysteresis — PR not retried within CHUMP_KEEP_MERGEABLE_HYSTERESIS_MINS"
{
    TMPDIR_T6="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_T6"' RETURN

    AMBIENT="$TMPDIR_T6/ambient.jsonl"; touch "$AMBIENT"
    STRIKES_DIR="$TMPDIR_T6/strikes"; mkdir -p "$STRIKES_DIR"

    NOW_FIXED="2026-05-30T16:00:00Z"
    STRIKE_FILE="$STRIKES_DIR/5005.json"
    printf '{"strikes":1,"pr":5005,"branch":"chump/TEST-5005","last_attempt_ts":"%s"}\n' "$NOW_FIXED" > "$STRIKE_FILE"

    FIXTURE="$TMPDIR_T6/prs.json"
    printf '[{"number":5005,"headRefName":"chump/TEST-5005","mergeStateStatus":"DIRTY","statusCheckRollup":[]}]' > "$FIXTURE"

    GH_MOCK="$TMPDIR_T6/gh"
    CALLED_MARKER="$TMPDIR_T6/gh.called"
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$CALLED_MARKER" > "$GH_MOCK"
    chmod +x "$GH_MOCK"

    CHUMP_KEEP_MERGEABLE_AMBIENT_FILE="$AMBIENT" \
    CHUMP_KEEP_MERGEABLE_STRIKES_DIR="$STRIKES_DIR" \
    CHUMP_KEEP_MERGEABLE_GH_FIXTURE="$FIXTURE" \
    CHUMP_KEEP_MERGEABLE_BROADCAST_SCRIPT="/bin/true" \
    CHUMP_KEEP_MERGEABLE_HYSTERESIS_MINS="30" \
    CHUMP_KEEP_MERGEABLE_NOW_OVERRIDE="$NOW_FIXED" \
    PATH="$TMPDIR_T6:$PATH" \
        bash "$BOT" 2>/dev/null

    if [[ -f "$CALLED_MARKER" ]]; then
        _fail "gh was called despite hysteresis window (0m < 30m)"
    else
        _ok "hysteresis: no gh call made within 30m window"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
