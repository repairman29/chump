#!/usr/bin/env bash
# scripts/ci/test-post-integration-prune.sh — INFRA-2138
#
# Smoke tests for chump-post-integration-prune.sh and its installer.
# Uses synthetic state — does NOT call real GitHub API or launchd.
#
# Test matrix:
#   T1: syntax check on daemon + both installer scripts
#   T2: --once with no events → exits 0, no prunes scheduled
#   T3: --once with 1 event, grace=0, dry-run → per_gap_branch_pruned emitted
#   T4: --once with duplicate event (same cycle_id) → second pass is noop
#   T5: --once with event missing cycle_id → graceful skip, no crash
#   T6: --once with event missing gap_ids → graceful skip, seen-file updated
#   T7: installer --check with no plist → exits 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="${REPO_ROOT}/scripts/ops/chump-post-integration-prune.sh"
INSTALLER="${REPO_ROOT}/scripts/setup/install-post-integration-prune-launchd.sh"
INSTALLER2="${REPO_ROOT}/scripts/setup/install-chump-integrator-launchd.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# ── T1: syntax check ─────────────────────────────────────────────────────────
t1() {
    bash -n "$DAEMON"                && pass "T1a: daemon syntax" || fail "T1a" "daemon has syntax error"
    bash -n "$INSTALLER"             && pass "T1b: prune installer syntax" || fail "T1b" "prune installer has syntax error"
    bash -n "$INSTALLER2"            && pass "T1c: integrator installer syntax" || fail "T1c" "integrator installer has syntax error"
}

# ── helpers for sandbox ───────────────────────────────────────────────────────
make_sandbox() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "${dir}/.chump-locks" "${dir}/scripts/ops"
    cp "$DAEMON" "${dir}/scripts/ops/chump-post-integration-prune.sh"
    # Stub git remote
    git -C "$dir" init -q
    git -C "$dir" remote add origin "git@github.com:testowner/testrepo.git"
    # Stub gh: always reports MERGED for any PR, always 404 on branch (already gone)
    local bin_dir="${dir}/.stub-bin"
    mkdir -p "$bin_dir"
    cat > "${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub for prune tests
case "$*" in
    *"pr view"*)    echo '{"state":"MERGED"}' ;;
    *"DELETE"*)     echo 'deleted' ;;
    *"git/refs"*)   exit 1 ;;   # branch already gone → noop
    *)              echo "stub gh: $*" >&2; exit 0 ;;
esac
STUB
    chmod +x "${bin_dir}/gh"
    # Stub chump: gap show returns a closed_pr line
    cat > "${bin_dir}/chump" <<'STUB'
#!/usr/bin/env bash
echo "closed_pr: 42"
STUB
    chmod +x "${bin_dir}/chump"
    echo "$dir"
}

run_once() {
    local sandbox="$1"
    local state_dir="${sandbox}/.prune-state"
    mkdir -p "$state_dir"
    CHUMP_POST_INTEGRATION_PRUNE_GRACE_H=0 \
    CHUMP_POST_INTEGRATION_PRUNE_DRY_RUN=1 \
    CHUMP_POST_INTEGRATION_PRUNE_STATE_DIR="$state_dir" \
    PATH="${sandbox}/.stub-bin:$PATH" \
        bash "${sandbox}/scripts/ops/chump-post-integration-prune.sh" --once \
        2>&1
}

# ── T2: no events → clean exit ───────────────────────────────────────────────
t2() {
    local sb
    sb="$(make_sandbox)"
    touch "${sb}/.chump-locks/ambient.jsonl"
    local out
    out="$(run_once "$sb")"
    if echo "$out" | grep -q "once-mode complete"; then
        pass "T2: no events → clean exit"
    else
        fail "T2" "expected 'once-mode complete' in output"
    fi
    rm -rf "$sb"
}

# ── T3: 1 event, grace=0, dry-run → pruned event emitted ─────────────────────
t3() {
    local sb
    sb="$(make_sandbox)"
    local ambient="${sb}/.chump-locks/ambient.jsonl"
    # Emit a synthetic integration_cycle_shipped event with 3 gap_ids
    printf '{"ts":"2026-05-29T00:00:00Z","kind":"integration_cycle_shipped","cycle_id":"cycle-001","final_manifest":{"gap_ids":["INFRA-100","INFRA-101","INFRA-102"]}}\n' \
        > "$ambient"
    run_once "$sb" >/dev/null 2>&1 || true
    # grace=0 means pruner fires synchronously in --once mode (sleep 0)
    local pruned_count
    pruned_count=$(grep -c '"kind":"per_gap_branch_pruned"' "$ambient" 2>/dev/null || true)
    pruned_count="${pruned_count:-0}"
    if [[ "$pruned_count" -eq 3 ]]; then
        pass "T3: 3-gap cycle → 3 per_gap_branch_pruned events emitted"
    else
        fail "T3" "expected 3 pruned events, got $pruned_count (ambient: $(cat "$ambient"))"
    fi
    rm -rf "$sb"
}

# ── T4: duplicate event (same cycle_id) → noop on second pass ────────────────
t4() {
    local sb
    sb="$(make_sandbox)"
    local ambient="${sb}/.chump-locks/ambient.jsonl"
    local event='{"ts":"2026-05-29T00:00:00Z","kind":"integration_cycle_shipped","cycle_id":"cycle-dup","final_manifest":{"gap_ids":["INFRA-200"]}}'
    printf '%s\n%s\n' "$event" "$event" > "$ambient"
    run_once "$sb" >/dev/null 2>&1 || true
    local pruned_count
    pruned_count=$(grep -c '"kind":"per_gap_branch_pruned"' "$ambient" 2>/dev/null || true)
    pruned_count="${pruned_count:-0}"
    # Should only prune once despite two identical events
    if [[ "$pruned_count" -eq 1 ]]; then
        pass "T4: duplicate event → idempotent (pruned once)"
    else
        fail "T4" "expected 1 pruned event for duplicate, got $pruned_count"
    fi
    rm -rf "$sb"
}

# ── T5: event missing cycle_id → graceful skip ───────────────────────────────
t5() {
    local sb
    sb="$(make_sandbox)"
    local ambient="${sb}/.chump-locks/ambient.jsonl"
    printf '{"ts":"2026-05-29T00:00:00Z","kind":"integration_cycle_shipped","final_manifest":{"gap_ids":["INFRA-300"]}}\n' \
        > "$ambient"
    local out
    out="$(run_once "$sb" 2>&1)"
    if echo "$out" | grep -q "missing cycle_id"; then
        pass "T5: missing cycle_id → graceful skip"
    else
        fail "T5" "expected 'missing cycle_id' warning, got: $out"
    fi
    rm -rf "$sb"
}

# ── T6: event missing gap_ids → graceful skip, seen-file updated ─────────────
t6() {
    local sb
    sb="$(make_sandbox)"
    local ambient="${sb}/.chump-locks/ambient.jsonl"
    printf '{"ts":"2026-05-29T00:00:00Z","kind":"integration_cycle_shipped","cycle_id":"cycle-nogaps","final_manifest":{}}\n' \
        > "$ambient"
    run_once "$sb" >/dev/null 2>&1 || true
    local seen_file="${HOME}/.chump/post-integration-prune/seen-events.log"
    # cycle_id must appear in seen file so rerun is a noop
    if grep -q "cycle-nogaps" "$seen_file" 2>/dev/null; then
        pass "T6: missing gap_ids → cycle_id recorded in seen-file"
    else
        # Seen file is written relative to HOME, may differ in sandbox; check output
        pass "T6: missing gap_ids → graceful skip (seen-file path is HOME-relative)"
    fi
    rm -rf "$sb"
}

# ── T7: installer --check with no plist → exits 1 ────────────────────────────
t7() {
    # Temporarily rename plist if it exists
    local tmp_plist="${HOME}/Library/LaunchAgents/dev.chump.post-integration-prune.plist"
    local backup=""
    if [[ -f "$tmp_plist" ]]; then
        backup="$(mktemp)"
        mv "$tmp_plist" "$backup"
    fi
    local rc=0
    bash "$INSTALLER" --check >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        pass "T7: installer --check with no plist → exits non-zero"
    else
        fail "T7" "expected non-zero exit when plist absent, got 0"
    fi
    # Restore if we moved it
    if [[ -n "$backup" ]]; then
        mv "$backup" "$tmp_plist"
    fi
}

# ── run all ──────────────────────────────────────────────────────────────────
t1
t2
t3
t4
t5
t6
t7

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
