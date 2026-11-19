#!/usr/bin/env bash
# test-auto-merge-arm-watcher.sh — INFRA-2289
#
# Smoke test for scripts/coord/auto-merge-arm-watcher.sh.
# Uses synthetic fixtures and a mock `gh` to avoid real GitHub calls.
#
# Scenarios:
#   1. Basic re-arm:     unarmed PR + recent auto-rebase event → re-armed,
#                        emits auto_merge_arm_dropped + auto_merge_arm_restored.
#   2. CHUMP_HOLD:       PR labelled CHUMP_HOLD → skipped,
#                        emits auto_merge_arm_skipped reason=chump_hold_label.
#   3. Rate-limit cap:   11 re-arm attempts when cap=10 → 10 armed + 11th skipped,
#                        emits auto_merge_arm_skipped reason=rate_limit_reached.
#   4. No rebase event:  unarmed PR but no recent ambient rebase event → skipped silently.
#   5. Bypass:           CHUMP_AM_WATCHER=0 → exits 0 immediately, no events.
#
# All tests run fully offline: no gh, no real ambient.jsonl mutation.
#
# Run from repo root: bash scripts/ci/test-auto-merge-arm-watcher.sh
# Rust-First-Bypass: shell test harness for shell-only watcher; no state mutation
#   beyond temp files; < 200 LOC; no persistent test-*.sh maintenance burden.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WATCHER="${REPO_ROOT}/scripts/coord/auto-merge-arm-watcher.sh"

PASS=0; FAIL=0; declare -a FAILURES=()
pass() { printf '  [PASS] %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$(( FAIL + 1 )); FAILURES+=("$1"); }

# ── Sanity: script exists + is executable ─────────────────────────────────────
[[ -f "${WATCHER}" ]] \
    && pass "watcher script exists" \
    || { fail "watcher script missing: ${WATCHER}"; echo "FAIL: script missing"; exit 1; }
[[ -x "${WATCHER}" ]] \
    && pass "watcher script is executable" \
    || fail "watcher script not executable"

bash -n "${WATCHER}" && pass "watcher script passes bash -n" \
                     || fail "watcher script has syntax error"

[[ -f "${REPO_ROOT}/scripts/setup/install-auto-merge-arm-watcher.sh" ]] \
    && pass "install script exists" \
    || fail "install script missing"
bash -n "${REPO_ROOT}/scripts/setup/install-auto-merge-arm-watcher.sh" \
    && pass "install script passes bash -n" \
    || fail "install script has syntax error"

# ── Helper: set up an isolated fixture dir ────────────────────────────────────
make_fixture() {
    local dir
    dir="$(mktemp -d)"
    mkdir -p "${dir}/locks" "${dir}/mock-bin"
    printf '' > "${dir}/locks/ambient.jsonl"
    printf '' > "${dir}/locks/auto-merge-arm-watcher-rate.jsonl"
    printf '%s' "${dir}"
}

# Inject a recent auto-rebase event for a given sha into the fixture ambient log.
inject_rebase_event() {
    local ambient="$1" sha="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Use cascade_rebase_triggered — the registered kind emitted by queue-driver.sh.
    # stacked_pr_rebased carries a sha field; cascade_rebase_triggered does not
    # (it carries pr_ok count). Use stacked_pr_rebased here so the sha-match
    # path in _recent_auto_rebase is exercised.
    printf '{"ts":"%s","kind":"stacked_pr_rebased","sha":"%s","stacked_pr":0,"status":"ok"}\n' \
        "${ts}" "${sha}" >> "${ambient}"
}

# Run the watcher in one-shot mode against a fixture.
# Sets up mock PATH so `gh` and `date` are controlled.
run_watcher() {
    local fixture_dir="$1"
    shift
    # Export stubs into the watcher environment.
    CHUMP_REPO_ROOT="${fixture_dir}" \
    CHUMP_LOCK_DIR="${fixture_dir}/locks" \
    CHUMP_AM_WATCHER_ONE_SHOT=1 \
    CHUMP_AM_WATCHER=1 \
    GITHUB_REPOSITORY="test-owner/test-repo" \
    PATH="${fixture_dir}/mock-bin:${PATH}" \
        bash "${WATCHER}" "$@" 2>&1
}

# ── Scenario 1: Basic re-arm ──────────────────────────────────────────────────
echo ""
echo "Scenario 1: unarmed PR + recent rebase → re-arm"

FIX1="$(make_fixture)"
trap 'rm -rf "${FIX1}"' EXIT

# Recent rebase event for sha abc123
inject_rebase_event "${FIX1}/locks/ambient.jsonl" "abc123def456"

# Mock gh:
#   - graphql (fetch_unarmed_prs): return one PR with autoMergeRequest=null
#   - api repos/.../pulls/42/commits: no recent operator commits
#   - pr merge: succeed
cat > "${FIX1}/mock-bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    # Return one unarmed PR, sha matches abc123def456, no CHUMP_HOLD label.
    printf '{"number":42,"sha":"abc123def456","labels":[]}\n'
    exit 0
fi
if [[ "$1" == "api" && "$2" == *"commits"* ]]; then
    # No recent operator commits.
    printf '2020-01-01T00:00:00Z\n'
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    echo "[mock-gh] pr merge succeeded" >&2
    exit 0
fi
# Default: succeed silently.
exit 0
GHEOF
chmod +x "${FIX1}/mock-bin/gh"

run_watcher "${FIX1}" > /tmp/watcher-s1.out 2>&1 || true

if grep -q '"kind":"auto_merge_arm_dropped"' "${FIX1}/locks/ambient.jsonl"; then
    pass "S1: emits auto_merge_arm_dropped"
else
    fail "S1: missing auto_merge_arm_dropped event"
fi
if grep -q '"kind":"auto_merge_arm_restored"' "${FIX1}/locks/ambient.jsonl"; then
    pass "S1: emits auto_merge_arm_restored"
else
    fail "S1: missing auto_merge_arm_restored event"
fi
if ! grep -q '"kind":"auto_merge_arm_skipped"' "${FIX1}/locks/ambient.jsonl"; then
    pass "S1: no spurious auto_merge_arm_skipped"
else
    fail "S1: spurious auto_merge_arm_skipped on clean re-arm path"
fi
# Rate counter should have one entry.
if [[ -f "${FIX1}/locks/auto-merge-arm-watcher-rate.jsonl" ]] \
    && [[ "$(wc -l < "${FIX1}/locks/auto-merge-arm-watcher-rate.jsonl")" -ge 1 ]]; then
    pass "S1: rate-limit counter recorded"
else
    fail "S1: rate-limit counter not recorded"
fi

# ── Scenario 2: CHUMP_HOLD label ─────────────────────────────────────────────
echo ""
echo "Scenario 2: CHUMP_HOLD label → skipped"

FIX2="$(make_fixture)"
trap 'rm -rf "${FIX1}" "${FIX2}"' EXIT

inject_rebase_event "${FIX2}/locks/ambient.jsonl" "deadbeef0001"

cat > "${FIX2}/mock-bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    # PR 99 with CHUMP_HOLD label, autoMergeRequest null.
    printf '{"number":99,"sha":"deadbeef0001","labels":["CHUMP_HOLD"]}\n'
    exit 0
fi
# pr merge should NOT be called — if it is, fail loudly.
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    echo "[mock-gh] ERROR: gh pr merge called on CHUMP_HOLD PR!" >&2
    exit 1
fi
exit 0
GHEOF
chmod +x "${FIX2}/mock-bin/gh"

run_watcher "${FIX2}" > /tmp/watcher-s2.out 2>&1 || true

if grep -q '"kind":"auto_merge_arm_skipped"' "${FIX2}/locks/ambient.jsonl"; then
    pass "S2: emits auto_merge_arm_skipped for CHUMP_HOLD"
else
    fail "S2: missing auto_merge_arm_skipped for CHUMP_HOLD"
fi
if grep -q '"reason":"chump_hold_label"' "${FIX2}/locks/ambient.jsonl"; then
    pass "S2: skipped reason=chump_hold_label"
else
    fail "S2: wrong or missing reason in auto_merge_arm_skipped"
fi
if ! grep -q '"kind":"auto_merge_arm_dropped"' "${FIX2}/locks/ambient.jsonl"; then
    pass "S2: no arm_dropped emitted for CHUMP_HOLD PR"
else
    fail "S2: arm_dropped should not fire on CHUMP_HOLD PR"
fi

# ── Scenario 3: Rate-limit cap (11th attempt blocked) ────────────────────────
echo ""
echo "Scenario 3: rate-limit cap at 10/hr — 11th attempt blocked"

FIX3="$(make_fixture)"
trap 'rm -rf "${FIX1}" "${FIX2}" "${FIX3}"' EXIT

inject_rebase_event "${FIX3}/locks/ambient.jsonl" "cafebabe1234"

# Pre-populate 10 rate-limit entries all within the last 60 min.
for i in $(seq 1 10); do
    local_epoch=$(( $(date -u +%s) - i ))
    local_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts_epoch":%s,"ts":"%s","pr":%s}\n' \
        "${local_epoch}" "${local_iso}" "${i}" \
        >> "${FIX3}/locks/auto-merge-arm-watcher-rate.jsonl"
done

cat > "${FIX3}/mock-bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    # One unarmed PR — the 11th attempt.
    printf '{"number":11,"sha":"cafebabe1234","labels":[]}\n'
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    echo "[mock-gh] ERROR: gh pr merge called after rate cap reached!" >&2
    exit 1
fi
exit 0
GHEOF
chmod +x "${FIX3}/mock-bin/gh"

run_watcher "${FIX3}" > /tmp/watcher-s3.out 2>&1 || true

# Watcher should emit rate_limit_reached before even attempting re-arm.
if grep -q '"kind":"auto_merge_arm_skipped"' "${FIX3}/locks/ambient.jsonl"; then
    pass "S3: emits auto_merge_arm_skipped when rate cap reached"
else
    fail "S3: missing auto_merge_arm_skipped at rate cap"
fi
if grep -q '"reason":"rate_limit_reached"' "${FIX3}/locks/ambient.jsonl"; then
    pass "S3: skipped reason=rate_limit_reached"
else
    fail "S3: wrong or missing reason at rate cap"
fi
if ! grep -q '"kind":"auto_merge_arm_dropped"' "${FIX3}/locks/ambient.jsonl"; then
    pass "S3: no arm_dropped when rate cap active"
else
    fail "S3: arm_dropped must not fire when rate cap active"
fi

# ── Scenario 4: No recent rebase event — no action ───────────────────────────
echo ""
echo "Scenario 4: unarmed PR but no recent rebase event → no action"

FIX4="$(make_fixture)"
trap 'rm -rf "${FIX1}" "${FIX2}" "${FIX3}" "${FIX4}"' EXIT

# ambient.jsonl is empty — no rebase event injected.

cat > "${FIX4}/mock-bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
    printf '{"number":77,"sha":"0000000abcde","labels":[]}\n'
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "merge" ]]; then
    echo "[mock-gh] ERROR: pr merge called with no rebase event!" >&2
    exit 1
fi
exit 0
GHEOF
chmod +x "${FIX4}/mock-bin/gh"

run_watcher "${FIX4}" > /tmp/watcher-s4.out 2>&1 || true

if ! grep -q '"kind":"auto_merge_arm_dropped"' "${FIX4}/locks/ambient.jsonl" \
    && ! grep -q '"kind":"auto_merge_arm_restored"' "${FIX4}/locks/ambient.jsonl"; then
    pass "S4: no re-arm events when no recent rebase in ambient"
else
    fail "S4: spurious re-arm event emitted with no rebase event"
fi

# ── Scenario 5: CHUMP_AM_WATCHER=0 bypass ────────────────────────────────────
echo ""
echo "Scenario 5: CHUMP_AM_WATCHER=0 → bypass exits 0"

FIX5="$(make_fixture)"
trap 'rm -rf "${FIX1}" "${FIX2}" "${FIX3}" "${FIX4}" "${FIX5}"' EXIT

if CHUMP_REPO_ROOT="${FIX5}" \
   CHUMP_LOCK_DIR="${FIX5}/locks" \
   CHUMP_AM_WATCHER=0 \
   CHUMP_AM_WATCHER_ONE_SHOT=1 \
   GITHUB_REPOSITORY="test-owner/test-repo" \
   bash "${WATCHER}" > /tmp/watcher-s5.out 2>&1; then
    pass "S5: exits 0 with CHUMP_AM_WATCHER=0"
else
    fail "S5: should exit 0 with CHUMP_AM_WATCHER=0"
fi

if ! grep -q '"kind":"auto_merge_arm_' "${FIX5}/locks/ambient.jsonl" 2>/dev/null; then
    pass "S5: no ambient events emitted on bypass"
else
    fail "S5: spurious ambient event on bypass"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Passed: ${PASS}  Failed: ${FAIL}"

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo "Failures:"
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
fi

[[ "${FAIL}" -eq 0 ]]
