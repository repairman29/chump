#!/usr/bin/env bash
# test-gap-decompose-reslice-guard.sh — INFRA-8067
#
# Root-cause fix for RESILIENT-1437 (gap-store slice-bloat): the
# EFFECTIVE-310 decompose reflex in scripts/dispatch/worker.sh could
# re-slice the same parent gap repeatedly, because `chump gap decompose`
# only ever guarded on parent.status != "open" (RESILIENT-1364) and
# effort in {xs,s} — it never checked whether the parent ALREADY had open
# child slices (e.g. from a prior --apply run that filed slices but was
# killed/wedged before writing the parent's final status=decomposed +
# notes marker).
#
# This validates three things:
#  1. `chump gap decompose` source carries the new open-slice guard
#     (count_open_slices + a distinct refusal exit code) ahead of any
#     LLM/provider work.
#  2. `scripts/dispatch/worker.sh`'s EFFECTIVE-310 reflex pre-checks that
#     guard and skips both re-running decompose AND resetting strikes
#     when the parent is already sliced.
#  3. (runtime, requires CHUMP_BIN) a parent with one open slice already
#     filed is refused by `chump gap decompose --dry-run` with the
#     distinct exit code, and the fresh-parent path still works.
#
# The Rust-level regression test (parent sliced AT MOST ONCE) lives next
# to the other decompose tests in
# crates/chump-gap-store/src/lib.rs (tests::a_parent_with_open_slices_is_sliced_at_most_once)
# — this shell test covers the CLI/reflex wiring those unit tests cannot
# reach without building the 611-crate workspace binary.

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHUMP="${CHUMP_BIN:-chump}"

echo "=== INFRA-8067 gap decompose re-slice guard test ==="
echo

# ── Static source checks (always run — no binary required) ──────────────────

# 1. count_open_slices exists in the gap-store crate.
if grep -q 'pub fn count_open_slices' "$REPO_ROOT/crates/chump-gap-store/src/lib.rs"; then
    ok "count_open_slices defined in chump-gap-store"
else
    fail "count_open_slices missing from chump-gap-store/src/lib.rs"
fi

# 2. The decompose handler calls the guard before filing anything.
if grep -q 'store.count_open_slices(&gap_id)' "$REPO_ROOT/src/main.rs"; then
    ok "decompose handler calls count_open_slices"
else
    fail "decompose handler does not call count_open_slices"
fi

# 3. The guard fires BEFORE the provider is built (no wasted LLM call on
#    a refusal) — the guard's exit(11) must appear earlier in the file
#    than the provider_cascade::build_provider() call inside the same
#    decompose arm.
DECOMPOSE_START=$(grep -n '"decompose" => {' "$REPO_ROOT/src/main.rs" | head -1 | cut -d: -f1)
GUARD_LINE=$(awk -v start="$DECOMPOSE_START" 'NR>=start && /std::process::exit\(11\)/{print NR; exit}' "$REPO_ROOT/src/main.rs")
PROVIDER_LINE=$(awk -v start="$DECOMPOSE_START" 'NR>=start && /provider_cascade::build_provider\(\)/{print NR; exit}' "$REPO_ROOT/src/main.rs")
if [[ -n "$GUARD_LINE" && -n "$PROVIDER_LINE" && "$GUARD_LINE" -lt "$PROVIDER_LINE" ]]; then
    ok "re-slice guard (exit 11) runs before the LLM provider is built"
else
    fail "re-slice guard does not clearly precede provider_cascade::build_provider() (guard_line=$GUARD_LINE provider_line=$PROVIDER_LINE)"
fi

# 4. worker.sh's EFFECTIVE-310 reflex pre-checks the guard via --dry-run.
if grep -q 'chump gap decompose "\$GAP_ID" --dry-run' "$REPO_ROOT/scripts/dispatch/worker.sh"; then
    ok "worker.sh EFFECTIVE-310 reflex pre-checks decompose --dry-run"
else
    fail "worker.sh EFFECTIVE-310 reflex missing the --dry-run pre-check"
fi

# 5. worker.sh branches on the distinct refusal code (11) and returns
#    before the real --apply call / strike --reset.
if grep -q '_precheck_rc" -eq 11' "$REPO_ROOT/scripts/dispatch/worker.sh"; then
    ok "worker.sh branches on the distinct refusal exit code (11)"
else
    fail "worker.sh does not branch on the refusal exit code"
fi

# 6. On refusal, worker.sh does not execute `strike --reset`: the `return
#    0` for the refusal branch must appear strictly before the
#    `chump gap strike "$GAP_ID" --reset` call in the same function.
WORKER_REFLEX_START=$(grep -n '_effective_003_reflex() {' "$REPO_ROOT/scripts/dispatch/worker.sh" | head -1 | cut -d: -f1)
REFUSAL_RETURN_LINE=$(awk -v start="$WORKER_REFLEX_START" 'NR>=start && /_precheck_rc" -eq 11/{found=1} found && /return 0/{print NR; exit}' "$REPO_ROOT/scripts/dispatch/worker.sh")
RESET_LINE=$(awk -v start="$WORKER_REFLEX_START" 'NR>=start && /strike "\$GAP_ID" --reset/{print NR; exit}' "$REPO_ROOT/scripts/dispatch/worker.sh")
if [[ -n "$REFUSAL_RETURN_LINE" && -n "$RESET_LINE" && "$REFUSAL_RETURN_LINE" -lt "$RESET_LINE" ]]; then
    ok "refusal path returns before strike --reset can run"
else
    fail "refusal path does not clearly precede strike --reset (refusal_return=$REFUSAL_RETURN_LINE reset=$RESET_LINE)"
fi

# ── Runtime checks using a fixture gap (requires the chump binary) ──────────

if ! command -v "$CHUMP" &>/dev/null; then
    echo
    echo "  SKIP: chump binary not found at '${CHUMP}' — skipping runtime tests"
    echo "        Set CHUMP_BIN=<path> to enable (e.g. target/debug/chump after"
    echo "        'cargo build --bin chump')."
else
    TMPDB="$(mktemp -d)/test.db"
    FIXTURE_TITLE="INFRA-8067-test-fixture-reslice-guard"

    # --force bypasses the farmer-status/overlap-detection gates that are
    # about THIS machine's auth/dedup state, not about the fixture itself;
    # `gap reserve` prints the new ID as the last stdout line.
    FIXTURE_ID=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap reserve \
        --domain INFRA \
        --title "$FIXTURE_TITLE" \
        --force \
        2>/dev/null | tail -1) || true

    if [[ -z "$FIXTURE_ID" ]]; then
        echo "  SKIP: could not create fixture gap — skipping runtime tests"
    else
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap set "$FIXTURE_ID" --effort m 2>/dev/null || true

        # 7. A genuinely fresh parent is NOT refused (dry-run exits 0).
        set +e
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap decompose "$FIXTURE_ID" --dry-run >/dev/null 2>&1
        FRESH_RC=$?
        set -e
        if [[ "$FRESH_RC" -eq 0 ]]; then
            ok "fresh parent's --dry-run exits 0 (not refused)"
        else
            fail "fresh parent's --dry-run unexpectedly exited $FRESH_RC"
        fi

        # File one slice by hand using the exact title convention
        # `chump gap decompose --apply` uses, simulating a decompose run
        # that filed a slice but was interrupted before marking the
        # parent decomposed.
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap reserve \
            --domain INFRA \
            --title "INFRA: a slice (${FIXTURE_ID} slice)" \
            --force \
            2>/dev/null || true

        # 8. The same parent is now refused with the distinct exit code.
        set +e
        OUT=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap decompose "$FIXTURE_ID" --dry-run 2>&1)
        REFUSED_RC=$?
        set -e
        if [[ "$REFUSED_RC" -eq 11 ]]; then
            ok "parent with an open slice is refused with exit code 11"
        else
            fail "parent with an open slice exited $REFUSED_RC (expected 11); output: $OUT"
        fi

        # 9. The refusal message names the reason.
        if echo "$OUT" | grep -qi "already has.*open slice"; then
            ok "refusal message explains why (already has open slice(s))"
        else
            fail "refusal message missing a clear reason; output: $OUT"
        fi

        # 10. Calling --apply on the already-sliced parent does NOT file a
        #     second batch — exactly the regression this gap exists to
        #     prevent. Count open gaps carrying the slice suffix before
        #     and after.
        BEFORE_COUNT=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap list --status open --json 2>/dev/null \
            | grep -o "(${FIXTURE_ID} slice)" | wc -l | tr -d ' ')
        set +e
        CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap decompose "$FIXTURE_ID" --apply >/dev/null 2>&1
        set -e
        AFTER_COUNT=$(CHUMP_STATE_DB="$TMPDB" "$CHUMP" gap list --status open --json 2>/dev/null \
            | grep -o "(${FIXTURE_ID} slice)" | wc -l | tr -d ' ')
        if [[ "$BEFORE_COUNT" -eq "$AFTER_COUNT" ]]; then
            ok "parent sliced AT MOST ONCE — --apply on an already-sliced parent filed nothing new ($BEFORE_COUNT slice(s) before and after)"
        else
            fail "a second --apply filed more slices: $BEFORE_COUNT before, $AFTER_COUNT after"
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
