#!/usr/bin/env bash
# scripts/ci/test-organ-success-verifier.sh — RESILIENT-1108 (umbrella RESILIENT-1103)
#
# Proves the organ-success verifier catches the exact all-night incident: an
# organ whose payload .service last run FAILED with status=200/CHDIR while its
# timer's `systemctl is-active` stays GREEN. Before this organ, reconcile and
# watchdog both keyed on is-active and never read per-run Result, so a CHDIR-
# dead fleet hid indefinitely. Also covers a generic non-zero exit, a healthy
# organ (ok, no page), a not-loaded organ (skipped, no double-page with
# reconcile), and the per-(unit,status) dedup window.
#
# Test depth: adversarial for the DETECTION contract (the reconstructed tonight
# CHDIR case, non-zero exit, healthy, not-loaded, dedup all asserted against a
# stubbed systemctl reporting is-active=active-but-Result=failed). Gaps: uses a
# stubbed `systemctl` — it does not exercise a REAL systemd unit end to end (a
# CI runner has no persistent user systemd session), and it does not exercise
# the Discord REST leg of notify-operator (CURATE queue short-circuits before
# the network send, as in production for a page verdict).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/ops/organ-success-verifier.sh"

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "=== test-organ-success-verifier.sh (RESILIENT-1108) ==="

# ── 1. Source contract ────────────────────────────────────────────────────────
[[ -f "$VERIFIER" ]] || fail "verifier script missing: $VERIFIER"
[[ -x "$VERIFIER" ]] || fail "verifier script not executable: $VERIFIER"
bash -n "$VERIFIER" || fail "verifier bash -n failed"
for u in service timer; do
    f="$REPO_ROOT/scripts/dispatch/chump-organ-success-verifier.$u"
    [[ -f "$f" ]] || fail "missing unit file $f"
done
# The unit MUST NOT carry a WorkingDirectory — that is the exact directive that
# killed every organ at CHDIR tonight. It invokes the script by absolute path.
if grep -q '^WorkingDirectory=' "$REPO_ROOT/scripts/dispatch/chump-organ-success-verifier.service"; then
    fail "unit sets WorkingDirectory= — the CHDIR trap this organ exists to catch"
fi
# Manifest + installer roster coherence (RESILIENT-366 Roll-Call): the timer
# must be in BOTH or it is un-installable or un-revivable.
grep -q 'chump-organ-success-verifier.timer' "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    || fail "timer missing from organ-manifest.txt"
grep -q 'chump-organ-success-verifier.timer' "$REPO_ROOT/scripts/setup/install-helsinki-atc.sh" \
    || fail "timer missing from install-helsinki-atc.sh roster"
# organ_run_failed must be registered `page`.
grep -qE '^organ_run_failed[[:space:]]+page' "$REPO_ROOT/scripts/coord/operator-escalation-registry.txt" \
    || fail "organ_run_failed not registered as page in escalation registry"
pass "script + units present, no WorkingDirectory trap, manifest/roster/escalation wired"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stubbed `systemctl`. It answers `show <svc> -p ...` with the Key=Value block
# the verifier parses. The service state is looked up by unit name so we can
# stage a CHDIR-failed, a non-zero-exit, a healthy, and a not-loaded organ in
# ONE fleet. Crucially, it also answers is-active with `active` for the timers —
# reproducing the tonight lie: green timer, dead service.
STUB="$TMP/systemctl"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# args: show <unit> -p Result -p ExecMainStatus -p ActiveState -p SubState -p LoadState
if [[ "$1" == "is-active" ]]; then
    # Every timer reads ACTIVE (the green-timer lie). --quiet returns 0.
    exit 0
fi
if [[ "$1" == "show" ]]; then
    svc="$2"
    case "$svc" in
        chump-chdir-organ.service)
            # The exact tonight signature: killed at chdir(2) before ExecStart.
            printf 'Result=exit-code\nExecMainStatus=200\nActiveState=failed\nSubState=failed\nLoadState=loaded\n' ;;
        chump-crash-organ.service)
            # Generic non-zero exit.
            printf 'Result=exit-code\nExecMainStatus=1\nActiveState=failed\nSubState=failed\nLoadState=loaded\n' ;;
        chump-healthy-organ.service)
            # Ran and exited cleanly; timer still active. Must be OK.
            printf 'Result=success\nExecMainStatus=0\nActiveState=inactive\nSubState=dead\nLoadState=loaded\n' ;;
        chump-ghost-organ.service)
            # Declared enabled but never installed — reconcile's lane, skip.
            printf 'Result=\nExecMainStatus=\nActiveState=inactive\nSubState=dead\nLoadState=not-found\n' ;;
        *)
            printf 'Result=success\nExecMainStatus=0\nActiveState=active\nSubState=running\nLoadState=loaded\n' ;;
    esac
    exit 0
fi
exit 0
STUBEOF
chmod +x "$STUB"

# A focused manifest: four enabled organs, one of each class.
MANIFEST="$TMP/organ-manifest.txt"
cat > "$MANIFEST" <<'MEOF'
# test manifest
enabled     chump-chdir-organ.timer  role=brain
enabled     chump-crash-organ.timer  role=brain
enabled     chump-healthy-organ.timer  role=brain
enabled     chump-ghost-organ.timer  role=brain
MEOF

AMB="$TMP/ambient.jsonl"
STATE="$TMP/state"
: > "$AMB"

run_verifier() {
    CHUMP_ORGAN_SUCCESS_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_SUCCESS_MANIFEST="$MANIFEST" \
    CHUMP_ORGAN_SUCCESS_STATE_DIR="$STATE" \
    CHUMP_AMBIENT_LOG="$AMB" \
    "$VERIFIER" "$@" 2>&1
}

# ── 2. THE TONIGHT CASE: CHDIR-failed organ is detected + paged in one cycle ──
out="$(run_verifier)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "verifier exited $rc; output: $out"

grep -q '"kind":"organ_run_failed"' "$AMB" \
    || fail "expected organ_run_failed emitted; ambient: $(cat "$AMB")"
grep -q '"unit":"chump-chdir-organ.timer"' "$AMB" \
    || fail "CHDIR organ not named in a failure event; ambient: $(cat "$AMB")"
# The distinguishing receipt: it is classed as a CHDIR failure specifically.
grep -q '"failure_class":"chdir"' "$AMB" \
    || fail "CHDIR failure_class not tagged; ambient: $(cat "$AMB")"
grep -q '"exec_status":"200"' "$AMB" \
    || fail "status 200 not recorded; ambient: $(cat "$AMB")"
pass "reconstructed tonight case (200/CHDIR) DETECTED and flagged within one cycle"

# The whole point: is-active is GREEN yet the run is caught. Assert the stub
# really does report is-active=active (so this is not a trivially-inactive unit).
CHUMP_ORGAN_SUCCESS_SYSTEMCTL_BIN="$STUB" "$STUB" is-active --quiet chump-chdir-organ.timer \
    && pass "is-active reports GREEN for the CHDIR organ — yet its FAILED run is no longer invisible" \
    || fail "stub is-active did not return active — test premise broken"

# It PAGED (organ_run_failed is registered `page` → notify-operator emits operator_paged).
grep -q '"kind":"operator_paged"' "$AMB" \
    || fail "expected operator_paged (page verdict) for the failed organ; ambient: $(cat "$AMB")"
pass "duty officer PAGED on the failed organ (operator_paged emitted)"

# ── 3. Generic non-zero exit is also caught (failure_class=exit) ──────────────
grep -q '"unit":"chump-crash-organ.timer"' "$AMB" \
    || fail "generic non-zero-exit organ not flagged; ambient: $(cat "$AMB")"
grep -q '"exec_status":"1".*"failure_class":"exit"' "$AMB" \
    || fail "non-zero exit not classed failure_class=exit; ambient: $(cat "$AMB")"
pass "generic non-zero-exit organ caught (failure_class=exit)"

# ── 4. Healthy organ is OK, NOT paged; not-loaded organ is SKIPPED ────────────
grep -q '"unit":"chump-healthy-organ.timer"' "$AMB" \
    && fail "healthy organ wrongly flagged as failed; ambient: $(cat "$AMB")"
grep -q '"unit":"chump-ghost-organ.timer"' "$AMB" \
    && fail "not-loaded organ wrongly flagged (reconcile's lane — double-page); ambient: $(cat "$AMB")"
pass "healthy organ passes; not-loaded organ skipped (no double-page with reconcile)"

# ── 5. Summary receipt: N verified-ok / M enabled + who failed ────────────────
tick="$(grep '"kind":"organ_success_verify_tick"' "$AMB" | tail -1)"
[[ -n "$tick" ]] || fail "no organ_success_verify_tick summary emitted"
echo "$tick" | grep -q '"enabled_total":4' || fail "summary enabled_total != 4: $tick"
echo "$tick" | grep -q '"verified_ok":1'   || fail "summary verified_ok != 1: $tick"
echo "$tick" | grep -q '"failed":2'        || fail "summary failed != 2: $tick"
echo "$tick" | grep -q '"skipped_not_loaded":1' || fail "summary skipped_not_loaded != 1: $tick"
echo "$tick" | grep -q 'chump-chdir-organ' || fail "summary does not name the CHDIR failed unit: $tick"
pass "per-cycle summary receipt correct: 1 verified-ok / 4 enabled, 2 failed (named), 1 skipped"

# ── 6. Dedup: a still-broken organ pages once per window, not every cycle ──────
: > "$AMB"
out2="$(run_verifier)"; rc2=$?
[[ "$rc2" -eq 0 ]] || fail "second cycle exited $rc2; output: $out2"
# Same failures still present, but inside the dedup window → dedup_skip, NO new page.
grep -q '"kind":"organ_run_verify_dedup_skip"' "$AMB" \
    || fail "expected organ_run_verify_dedup_skip on the repeat cycle; ambient: $(cat "$AMB")"
if grep -q '"kind":"operator_paged"' "$AMB"; then
    fail "duty officer re-paged inside the dedup window (should be held); ambient: $(cat "$AMB")"
fi
pass "still-broken organ HELD (dedup) on the repeat cycle — one page per window, no spam"

# ── 7. --dry-run classifies but never pages ───────────────────────────────────
: > "$AMB"
rm -rf "$STATE"    # fresh state so dedup doesn't mask the dry-run
run_verifier --dry-run >/dev/null 2>&1
grep -q '"dry_run":true' "$AMB" || fail "--dry-run did not mark events dry_run:true"
if grep -q '"kind":"operator_paged"' "$AMB"; then
    fail "--dry-run paged the operator; ambient: $(cat "$AMB")"
fi
pass "--dry-run classifies + summarizes without paging"

echo "=== ALL PASS (RESILIENT-1108) ==="
