#!/usr/bin/env bash
# scripts/ci/test-self-deploy-audit.sh — INFRA-3598
#
# Proves the self-deploy-audit organ actually detects the three failure
# modes the gap names: a stale clone (helsinki clone not current — AC 5), a
# drifted unit (repo changed but live /etc/systemd/system didn't — AC 1),
# and a failed organ (the scorecard-recovers-to-green proof — AC 3). Also
# proves the healthy path passes clean and every check emits the single
# kind=self_deploy_audit board-verifiable event (AC 7).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT="$REPO_ROOT/scripts/ops/self-deploy-audit.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-self-deploy-audit.sh (INFRA-3598) ==="

[[ -f "$AUDIT" ]] || fail "audit script missing: $AUDIT"
[[ -x "$AUDIT" ]] || fail "audit script not executable: $AUDIT"
bash -n "$AUDIT" || fail "audit bash -n failed"
for unit in service timer; do
    f="$REPO_ROOT/scripts/dispatch/chump-self-deploy-audit.$unit"
    [[ -f "$f" ]] || fail "missing $f"
done
pass "script + unit files present, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Snapshot the real tracked chump-*.service/.timer files into a "live" unit
# dir so the baseline is drift-free without depending on a real helsinki box.
LIVE="$TMP/live-units"
mkdir -p "$LIVE"
cp "$REPO_ROOT"/scripts/dispatch/chump-*.service "$REPO_ROOT"/scripts/dispatch/chump-*.timer "$LIVE"/

STUB_HEALTHY="$TMP/systemctl-healthy"
cat > "$STUB_HEALTHY" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_HEALTHY"

# ── 1. Healthy path: no drift, no failed organs, clone "current" (real
#      fetch against the real origin, generous threshold) → pass, exit 0 ──
AMB1="$TMP/ambient1.jsonl"
out1="$(CHUMP_SELF_DEPLOY_REPO_ROOT="$REPO_ROOT" \
    CHUMP_SELF_DEPLOY_UNIT_DIR="$LIVE" \
    CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN="$STUB_HEALTHY" \
    CHUMP_SELF_DEPLOY_AMBIENT="$AMB1" \
    CHUMP_SELF_DEPLOY_STALE_MINUTES=999999 \
    "$AUDIT" 2>&1)"
rc1=$?
[[ "$rc1" -eq 0 ]] || fail "expected exit 0 on healthy path, got $rc1; output: $out1"
grep -q '"kind":"self_deploy_audit"' "$AMB1" || fail "expected self_deploy_audit emitted; ambient: $(cat "$AMB1")"
grep -q '"status":"pass"' "$AMB1" || fail "expected status=pass; ambient: $(cat "$AMB1")"
pass "healthy path: no drift, no failed organs, clone current → pass, exit 0"

# ── 2. Unit drift: mutate one live unit so it no longer matches the repo ───
AMB2="$TMP/ambient2.jsonl"
echo "# drifted — does not match repo" >> "$LIVE/chump-sla-scorecard.service"
out2="$(CHUMP_SELF_DEPLOY_REPO_ROOT="$REPO_ROOT" \
    CHUMP_SELF_DEPLOY_UNIT_DIR="$LIVE" \
    CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN="$STUB_HEALTHY" \
    CHUMP_SELF_DEPLOY_AMBIENT="$AMB2" \
    CHUMP_SELF_DEPLOY_STALE_MINUTES=999999 \
    "$AUDIT" 2>&1)"
rc2=$?
[[ "$rc2" -eq 1 ]] || fail "expected exit 1 on drifted-unit path, got $rc2; output: $out2"
echo "$out2" | grep -q "DRIFTED units" || fail "expected DRIFTED units line; got: $out2"
echo "$out2" | grep -q "chump-sla-scorecard.service" || fail "expected the drifted unit named; got: $out2"
grep -q '"status":"fail"' "$AMB2" || fail "expected status=fail; ambient: $(cat "$AMB2")"
grep -q 'unit_drift' "$AMB2" || fail "expected unit_drift in reasons; ambient: $(cat "$AMB2")"
grep -q 'chump-sla-scorecard.service' "$AMB2" || fail "expected the drifted unit named in ambient; ambient: $(cat "$AMB2")"
pass "unit drift: a live unit that doesn't match the repo copy fails the audit and names the unit"
# restore for subsequent tests
cp "$REPO_ROOT/scripts/dispatch/chump-sla-scorecard.service" "$LIVE/"

# ── 3. Failed organ: stub systemctl reports chump-sla-scorecard.service
#      failed — this is exactly how the board confirms the scorecard organ
#      recovered to green (AC 3) once it stops showing up here ─────────────
STUB_FAILED="$TMP/systemctl-failed"
cat > "$STUB_FAILED" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list-units" ]]; then
    echo "chump-sla-scorecard.service loaded failed failed Chump merge-SLA scorecard"
    exit 0
fi
exit 0
EOF
chmod +x "$STUB_FAILED"
AMB3="$TMP/ambient3.jsonl"
out3="$(CHUMP_SELF_DEPLOY_REPO_ROOT="$REPO_ROOT" \
    CHUMP_SELF_DEPLOY_UNIT_DIR="$LIVE" \
    CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN="$STUB_FAILED" \
    CHUMP_SELF_DEPLOY_AMBIENT="$AMB3" \
    CHUMP_SELF_DEPLOY_STALE_MINUTES=999999 \
    "$AUDIT" 2>&1)"
rc3=$?
[[ "$rc3" -eq 1 ]] || fail "expected exit 1 on failed-organ path, got $rc3; output: $out3"
grep -q '"status":"fail"' "$AMB3" || fail "expected status=fail; ambient: $(cat "$AMB3")"
grep -q 'organ_failed' "$AMB3" || fail "expected organ_failed in reasons; ambient: $(cat "$AMB3")"
grep -q 'chump-sla-scorecard.service' "$AMB3" || fail "expected failed organ named in ambient; ambient: $(cat "$AMB3")"
pass "failed organ: a failed chump-sla-scorecard.service fails the audit and is named (board's green-recovery proof)"

# ── 4. Stale clone: fixture bare repo where the mirror is behind origin ────
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$TMP/seed" 2>/dev/null
git -C "$TMP/seed" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
git -C "$TMP/seed" push -q origin HEAD:main 2>/dev/null
git clone -q "$ORIGIN" "$MIRROR" 2>/dev/null
git -C "$MIRROR" checkout -q -B main origin/main 2>/dev/null || true
mkdir -p "$MIRROR/scripts/dispatch" "$MIRROR/.chump-locks"
git -C "$TMP/seed" -c user.email=t@t -c user.name=t commit --allow-empty -q -m advance
git -C "$TMP/seed" push -q origin HEAD:main 2>/dev/null
# Real (local, file:// remote — no network needed) fetch is exercised here,
# NOT skipped: the mirror's origin/main ref must actually advance so the
# comparison against its unmoved local HEAD reveals genuine lag.
AMB4="$TMP/ambient4.jsonl"
out4="$(CHUMP_SELF_DEPLOY_REPO_ROOT="$MIRROR" \
    CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN="$STUB_HEALTHY" \
    CHUMP_SELF_DEPLOY_AMBIENT="$AMB4" \
    CHUMP_SELF_DEPLOY_STALE_MINUTES=-1 \
    "$AUDIT" 2>&1)"
rc4=$?
[[ "$rc4" -eq 1 ]] || fail "expected exit 1 on stale-clone path, got $rc4; output: $out4"
echo "$out4" | grep -q "STALE" || fail "expected STALE line; got: $out4"
grep -q '"status":"fail"' "$AMB4" || fail "expected status=fail; ambient: $(cat "$AMB4")"
grep -q 'clone_stale' "$AMB4" || fail "expected clone_stale in reasons; ambient: $(cat "$AMB4")"
pass "stale clone: a mirror behind origin/main past the threshold fails the audit"

# ── 5. systemctl unavailable: clone check still runs, drift/organ checks
#      skipped, exit 2 (not a hard failure — dev laptop context) ──────────
AMB5="$TMP/ambient5.jsonl"
out5="$(CHUMP_SELF_DEPLOY_REPO_ROOT="$REPO_ROOT" \
    CHUMP_SELF_DEPLOY_SYSTEMCTL_BIN="$TMP/no-such-systemctl-binary" \
    CHUMP_SELF_DEPLOY_AMBIENT="$AMB5" \
    CHUMP_SELF_DEPLOY_STALE_MINUTES=999999 \
    "$AUDIT" 2>&1)"
rc5=$?
[[ "$rc5" -eq 2 ]] || fail "expected exit 2 when systemctl unavailable, got $rc5; output: $out5"
echo "$out5" | grep -q "systemctl unavailable" || fail "expected systemctl-unavailable note; got: $out5"
pass "systemctl unavailable (dev context): clone check runs, drift/organ checks skip, exit 2"

echo "ALL PASS"
