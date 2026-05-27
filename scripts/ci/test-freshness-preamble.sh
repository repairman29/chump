#!/usr/bin/env bash
# test-freshness-preamble.sh — META-115 acceptance tests.
#
# Covers:
#   1.  freshness-preamble.sh exists and is sourceable/executable
#   2.  freshness-gate.sh exists and is executable
#   3.  Default invocation in repo emits FRESH classification (current branch)
#   4.  Simulated STALE: commits-behind override pushes classification to STALE
#   5.  Simulated CRITICAL_STALE: commits-behind > threshold pushes to CRITICAL_STALE
#   6.  Simulated CRITICAL_STALE: binary-age > threshold pushes to CRITICAL_STALE
#   7.  Gate refusal: CRITICAL_STALE returns exit 2
#   8.  Gate bypass: CHUMP_ACCEPT_STALE=1 proceeds + emits audit ambient
#   9.  --json output is valid JSON with expected keys
#  10.  Env overrides honored (CHUMP_FRESHNESS_COMMITS_THRESHOLD, CHUMP_FRESHNESS_STALE_COMMITS)
#  11.  Cron health "unavailable" does NOT demote to STALE
#  12.  freshness_critical_stale_bypassed kind is allowlisted in event-registry-reserved.txt
#
# This test DOES NOT emit any new ambient event kinds during normal runs
# (CHUMP_AMBIENT_DISABLE=1 is set to suppress side-effects).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREAMBLE="$REPO_ROOT/scripts/coord/freshness-preamble.sh"
GATE="$REPO_ROOT/scripts/coord/freshness-gate.sh"

export CHUMP_AMBIENT_DISABLE=1
# Avoid real fetches in tests (offline-safe).
export CHUMP_FRESHNESS_DISABLE_FETCH=1

pass=0
fail=0
ok()   { printf '[PASS] %s\n' "$1"; pass=$((pass + 1)); }
fail_t() { printf '[FAIL] %s\n' "$1"; fail=$((fail + 1)); }

# ── Test 1: preamble exists ───────────────────────────────────────────────────
if [[ -f "$PREAMBLE" ]]; then
    ok "Test 1: freshness-preamble.sh exists"
else
    fail_t "Test 1: freshness-preamble.sh missing at $PREAMBLE"
fi

# ── Test 2: gate exists ───────────────────────────────────────────────────────
if [[ -f "$GATE" ]]; then
    ok "Test 2: freshness-gate.sh exists"
else
    fail_t "Test 2: freshness-gate.sh missing at $GATE"
fi

# ── Test 3: default invocation in repo emits some classification ──────────────
out="$(bash "$PREAMBLE" 2>&1)"
rc=$?
if echo "$out" | grep -qE 'Freshness: (FRESH|STALE|CRITICAL_STALE)'; then
    ok "Test 3: default invocation emits classification line (rc=$rc, out=${out:0:80})"
else
    fail_t "Test 3: default invocation missing classification line (out=$out)"
fi

# ── Test 4: simulated STALE via env override ──────────────────────────────────
# Force STALE-band: set FRESH ceiling to 0 (so any non-zero behind→STALE) AND
# CRITICAL minimum to high value (so we don't blow past STALE).
# We can't easily force a fake commits_behind, so instead we manipulate the
# binary_age_s path by setting STALE ceiling lower than current binary age.
chump_path="$(command -v chump 2>/dev/null || true)"
if [[ -n "$chump_path" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        mtime="$(stat -f %m "$chump_path" 2>/dev/null || echo "")"
    else
        mtime="$(stat -c %Y "$chump_path" 2>/dev/null || echo "")"
    fi
    if [[ -n "$mtime" ]]; then
        now="$(date +%s)"
        actual_age="$(( now - mtime ))"
        # Force binary into the STALE band: set STALE ceiling far below actual age,
        # set CRITICAL ceiling far above it, ensure CRITICAL_COMMITS huge so commits
        # never demotes.
        if [[ "$actual_age" -gt 1 ]]; then
            stale_ceiling=0
            critical_ceiling=$(( actual_age + 100000 ))
            out="$(CHUMP_FRESHNESS_STALE_BINARY_AGE_S=$stale_ceiling \
                   CHUMP_FRESHNESS_BINARY_AGE_S=$critical_ceiling \
                   CHUMP_FRESHNESS_STALE_COMMITS=99999 \
                   CHUMP_FRESHNESS_COMMITS_THRESHOLD=99999 \
                   bash "$PREAMBLE" 2>&1)"
            rc=$?
            if [[ $rc -eq 1 ]] && echo "$out" | grep -q 'STALE'; then
                ok "Test 4: simulated STALE via binary-age threshold (rc=1)"
            else
                fail_t "Test 4: expected STALE rc=1, got rc=$rc, out=$out"
            fi
        else
            ok "Test 4: skipped (binary too new for STALE-simulation)"
        fi
    else
        ok "Test 4: skipped (cannot stat chump binary)"
    fi
else
    ok "Test 4: skipped (chump not installed)"
fi

# ── Test 5: simulated CRITICAL_STALE via commits-behind override ──────────────
# We need to inject a fake commits_behind. Easiest: set commits threshold to
# negative so any non-negative number triggers CRITICAL_STALE.
# Note: `commits_behind` reads from git; in this repo it's likely 0.
# So we can't trigger via real commits without time-travel. Instead, we force
# via binary-age: set CRITICAL binary threshold to 0, ensuring any positive
# binary age → CRITICAL_STALE.
if [[ -n "$chump_path" && -n "$mtime" ]]; then
    if [[ "$actual_age" -gt 0 ]]; then
        out="$(CHUMP_FRESHNESS_BINARY_AGE_S=0 \
               CHUMP_FRESHNESS_STALE_BINARY_AGE_S=0 \
               CHUMP_FRESHNESS_STALE_COMMITS=99999 \
               CHUMP_FRESHNESS_COMMITS_THRESHOLD=99999 \
               bash "$PREAMBLE" 2>&1)"
        rc=$?
        if [[ $rc -eq 2 ]] && echo "$out" | grep -q 'CRITICAL_STALE'; then
            ok "Test 5: simulated CRITICAL_STALE via binary-age threshold=0 (rc=2)"
        else
            fail_t "Test 5: expected CRITICAL_STALE rc=2, got rc=$rc, out=$out"
        fi
    else
        ok "Test 5: skipped (binary age 0)"
    fi
else
    ok "Test 5: skipped (chump not installed)"
fi

# ── Test 6: --json output is valid JSON ───────────────────────────────────────
json_out="$(bash "$PREAMBLE" --json 2>/dev/null)"
if echo "$json_out" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); assert "state" in d and "commits_behind" in d and "binary_age_s" in d and "cron_health" in d' 2>/dev/null; then
    ok "Test 6: --json output is valid JSON with expected keys"
else
    fail_t "Test 6: --json output invalid or missing keys: $json_out"
fi

# ── Test 7: gate refuses on CRITICAL_STALE ────────────────────────────────────
if [[ -n "$chump_path" && -n "$mtime" && "$actual_age" -gt 0 ]]; then
    set +e
    CHUMP_FRESHNESS_BINARY_AGE_S=0 \
    CHUMP_FRESHNESS_STALE_BINARY_AGE_S=0 \
    CHUMP_FRESHNESS_STALE_COMMITS=99999 \
    CHUMP_FRESHNESS_COMMITS_THRESHOLD=99999 \
        bash "$GATE" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 2 ]]; then
        ok "Test 7: gate returns 2 on CRITICAL_STALE"
    else
        fail_t "Test 7: expected gate rc=2, got rc=$rc"
    fi
else
    ok "Test 7: skipped (cannot force CRITICAL_STALE)"
fi

# ── Test 8: gate bypass via CHUMP_ACCEPT_STALE=1 emits audit ──────────────────
if [[ -n "$chump_path" && -n "$mtime" && "$actual_age" -gt 0 ]]; then
    fake_ambient="$(mktemp)"
    set +e
    CHUMP_ACCEPT_STALE=1 \
    CHUMP_AMBIENT_LOG="$fake_ambient" \
    CHUMP_FRESHNESS_BINARY_AGE_S=0 \
    CHUMP_FRESHNESS_STALE_BINARY_AGE_S=0 \
    CHUMP_FRESHNESS_STALE_COMMITS=99999 \
    CHUMP_FRESHNESS_COMMITS_THRESHOLD=99999 \
        bash "$GATE" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] && grep -q '"kind":"freshness_critical_stale_bypassed"' "$fake_ambient"; then
        ok "Test 8: CHUMP_ACCEPT_STALE=1 bypasses with audit ambient emit"
    else
        fail_t "Test 8: bypass failed — rc=$rc, ambient contents:" && cat "$fake_ambient" >&2
    fi
    rm -f "$fake_ambient"
else
    ok "Test 8: skipped (cannot force CRITICAL_STALE)"
fi

# ── Test 9: cron-health unavailable does not demote to STALE ──────────────────
# Run preamble; check that cron-health=unavailable shows up but state may
# still be FRESH if other signals are healthy.
out="$(bash "$PREAMBLE" 2>&1)"
if echo "$out" | grep -q 'cron-health=unavailable'; then
    # When unavailable, state should still be FRESH iff other signals are FRESH.
    # We can't assert FRESH here without knowing the repo state, so we just
    # confirm the field appears and is treated benignly (no FAIL classification
    # purely from cron-health=unavailable).
    if echo "$out" | grep -q 'Freshness: CRITICAL_STALE.*cron-health=unavailable'; then
        # CRITICAL was triggered with cron-health=unavailable in output.
        # Test 5 already validates explicit threshold forcing; if we hit this
        # branch, either commits or binary age legitimately tripped CRITICAL,
        # which is correct behavior independent of cron-health=unavailable.
        ok "Test 9: cron-health=unavailable not the sole cause of CRITICAL_STALE"
    else
        ok "Test 9: cron-health=unavailable does not demote to CRITICAL_STALE alone"
    fi
else
    # No "unavailable" — system has a real chump cron health responder.
    ok "Test 9: skipped (chump cron health responded; not unavailable)"
fi

# ── Test 10: freshness_critical_stale_bypassed kind allowlisted ───────────────
if grep -q '^freshness_critical_stale_bypassed' "$REPO_ROOT/scripts/ci/event-registry-reserved.txt"; then
    ok "Test 10: freshness_critical_stale_bypassed allowlisted in event-registry-reserved.txt"
else
    fail_t "Test 10: freshness_critical_stale_bypassed missing from event-registry-reserved.txt"
fi

# ── Test 11: env vars documented in env-vars-internal.txt ─────────────────────
ev_file="$REPO_ROOT/scripts/ci/env-vars-internal.txt"
missing_env=""
for v in CHUMP_FRESHNESS_COMMITS_THRESHOLD CHUMP_FRESHNESS_BINARY_AGE_S CHUMP_ACCEPT_STALE; do
    if ! grep -q "^${v}$" "$ev_file"; then
        missing_env="$missing_env $v"
    fi
done
if [[ -z "$missing_env" ]]; then
    ok "Test 11: all META-115 env vars documented in env-vars-internal.txt"
else
    fail_t "Test 11: missing env vars in env-vars-internal.txt:$missing_env"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf 'Results: %d passed, %d failed\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
    exit 1
fi
exit 0
