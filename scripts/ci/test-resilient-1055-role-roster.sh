#!/usr/bin/env bash
# scripts/ci/test-resilient-1055-role-roster.sh — RESILIENT-1055
#
# The --role fresh-node bring-up now PLACES the role's manifest unit files (not
# just enables never-copied ones). This locks the load-bearing pieces of that:
#   1. organ_is_applicable's `file:` spec (the CJ-legacy-unit skip that keeps a
#      generic box from backing off a file-less unit forever).
#   2. organ-role-roster.sh's role filtering + kind classification (the is-active
#      receipt the FTUE and any real-box proof read).
#   3. the node-local exemption list (the units a role-scoped reconcile must
#      NEVER reap — worker/heartbeat/sentinel + the reconcile's own beat).
#   4. the shared host-rewrite lib's core transforms (root->run-user, bare
#      Environment=HOME rewrite, keep-root) — the byte-for-byte contract both
#      placers depend on.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB_MANIFEST="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
LIB_UNIT="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
ROSTER="$REPO_ROOT/scripts/ops/organ-role-roster.sh"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass(){ printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

for f in "$LIB_MANIFEST" "$LIB_UNIT" "$ROSTER" "$RECONCILE"; do
  [ -f "$f" ] || fail "missing $f"
  bash -n "$f" || fail "bash -n failed: $f"
done
pass "syntax integrity of the lib + roster + reconcile"

# ── 1. organ_is_applicable file: spec ────────────────────────────────────────
source "$LIB_MANIFEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
touch "$TMP/present-asset"
reason=""
organ_is_applicable "u.service" "file:$TMP/present-asset" reason \
  || fail "file: guard should be APPLICABLE when the file exists (got reason=$reason)"
pass "file: applicable when the asset exists"
reason=""
if organ_is_applicable "u.service" "file:$TMP/absent-asset" reason; then
  fail "file: guard should be NOT-applicable when the file is absent"
fi
[ "$reason" = "missing_file:$TMP/absent-asset" ] || fail "file: reason wrong: $reason"
pass "file: not-applicable (skipped) when the asset is absent — the CJ-legacy-unit skip"
# ~/ expansion
reason=""; HOME="$TMP" organ_is_applicable "u" "file:~/present-asset" reason \
  || fail "file:~/ should expand against HOME and be applicable (reason=$reason)"
pass "file:~/ expands against \$HOME"

# ── 2. organ-role-roster.sh filtering + kind ─────────────────────────────────
MAN="$TMP/manifest.txt"
cat > "$MAN" <<EOF
enabled  chump-brainy.timer     role=brain
enabled  chump-datum.service    role=data
enabled  chump-muscley.service  role=muscle
enabled  chump-gated.timer      role=brain requires=file:$TMP/absent-asset
EOF
# stub systemctl: cat -> ok (unit "present"), is-active -> active
STUB="$TMP/systemctl"; cat > "$STUB" <<'SH'
#!/usr/bin/env bash
case "$1" in
  cat) exit 0;;
  is-active) echo active; exit 0;;
  *) exit 0;;
esac
SH
chmod +x "$STUB"
out="$(CHUMP_ORGAN_MANIFEST="$MAN" CHUMP_ORGAN_RECONCILE_ROLE="brain,data,janitor,trust" \
       CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" bash "$ROSTER")"
echo "$out" | grep -qE '^active	chump-brainy\.timer	timer' || fail "roster: brainy timer should be active/timer; got: $out"
echo "$out" | grep -qE '^active	chump-datum\.service	service' || fail "roster: datum service should be active/service; got: $out"
echo "$out" | grep -q 'chump-muscley.service' && fail "roster: muscle-tagged unit must NOT appear under a brain filter; got: $out"
echo "$out" | grep -qE '^SKIP	chump-gated\.timer' || fail "roster: file:-gated timer should be SKIP; got: $out"
pass "organ-role-roster.sh: brain filter includes brain/data, excludes muscle, SKIPs a file-gated unit, classifies timer vs service"
# muscle filter shows only the muscle-tagged unit
outm="$(CHUMP_ORGAN_MANIFEST="$MAN" CHUMP_ORGAN_RECONCILE_ROLE="muscle" \
        CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" bash "$ROSTER")"
echo "$outm" | grep -qE '^active	chump-muscley\.service' || fail "muscle filter should show the muscle unit; got: $outm"
echo "$outm" | grep -q 'chump-brainy' && fail "muscle filter must NOT show brain units; got: $outm"
pass "organ-role-roster.sh: muscle filter scopes to muscle-tagged units only"

# ── 3. node-local exemption ──────────────────────────────────────────────────
# organ_is_node_local lives in organ-reconcile.sh; source just that function's
# definition by grepping it out is brittle — instead assert the list is present
# and covers the FTUE-verified reap victims.
for u in chump-organ-reconcile chump-worker chump-fleet-health-sentinel chump-process-organ-heal chump-node-heartbeat; do
  grep -qE "^\s*$u\$" "$RECONCILE" || fail "node-local exemption list must include $u (the role-scoped reconcile must never reap it)"
done
pass "node-local exemption list covers worker/heartbeat/sentinel/process-heal + the reconcile's own beat"

# ── 4. host-rewrite core transforms ──────────────────────────────────────────
# organ_unit_host_rewrite uses GNU `sed -i` (in-place append/insert), which is
# how the units are placed on their Linux deploy targets. On a non-GNU sed
# (macOS/BSD dev box) skip this part — the units never deploy there, and CI runs
# on ubuntu where it executes for real.
if ! sed --version 2>/dev/null | grep -qi gnu; then
  echo "SKIP host-rewrite transforms (non-GNU sed — Linux-deploy-only; runs for real on CI ubuntu)"
  echo "ALL PASS"; exit 0
fi
source "$LIB_UNIT"
SRCU="$TMP/root-unit.service"
cat > "$SRCU" <<'EOF'
[Unit]
Description=x
[Service]
User=root
Environment=HOME=/root
ExecStart=/root/Projects/chump/scripts/x.sh
EOF
DESTU="$TMP/out.service"
organ_unit_host_rewrite "$SRCU" "$DESTU" "ubuntu" "/home/ubuntu" 0 || fail "host_rewrite returned non-zero"
grep -q '^User=ubuntu$' "$DESTU" || fail "host_rewrite: User=root should become User=ubuntu"
grep -q '^Environment=HOME=/home/ubuntu$' "$DESTU" || fail "host_rewrite: bare Environment=HOME=/root should become /home/ubuntu (the instruments-lie keystone)"
# Legacy 5-arg call (no repo_root) preserves the historical $HOME/Projects/chump
# assumption — backward compat for any caller that hasn't opted into the fix.
grep -q '^ExecStart=/home/ubuntu/Projects/chump/scripts/x.sh$' "$DESTU" || fail "host_rewrite: /root path prefix should rewrite to run-home (legacy default)"
# keep-root
organ_unit_host_rewrite "$SRCU" "$DESTU" "ubuntu" "/home/ubuntu" 1 || fail "host_rewrite keep-root returned non-zero"
grep -q '^User=root$' "$DESTU" || fail "host_rewrite keep-root: User must stay root"
pass "organ_unit_host_rewrite: root->run-user, bare HOME rewrite, path-prefix rewrite, keep-root all hold"

# ── 5. RESILIENT-1102: repo_root rewrites the baked repo path to the REAL ────
# checkout, so units never point at a non-existent $HOME/Projects/chump (the
# owned-node 200/CHDIR root — this whole class had ZERO test coverage before).
SRCR="$TMP/repo-unit.service"
cat > "$SRCR" <<'EOF'
[Unit]
Description=x
[Service]
User=root
Environment=HOME=/root
Environment=CHUMP_REPO_ROOT=/root/Projects/chump
WorkingDirectory=/root/Projects/chump
ExecStart=/bin/bash -lc 'source /root/.chump/providers.env; cd /root/Projects/chump; exec /root/Projects/chump/scripts/ops/x.sh'
EOF
# The box's real repo lives at $HOME/chump (NO Projects segment) — and it EXISTS.
REAL_REPO="$TMP/home-ubuntu/chump"; mkdir -p "$REAL_REPO"
DESTR="$TMP/out-repo.service"
organ_unit_host_rewrite "$SRCR" "$DESTR" "ubuntu" "$TMP/home-ubuntu" 0 "$REAL_REPO" || fail "host_rewrite(repo_root) returned non-zero"
# Every repo reference resolves to the real checkout; home-only paths (.chump)
# still track the run-home.
grep -q "^WorkingDirectory=${REAL_REPO}\$" "$DESTR" || fail "repo_root: WorkingDirectory not rewritten to the real checkout: $(grep -n '^WorkingDirectory=' "$DESTR")"
grep -q "^Environment=CHUMP_REPO_ROOT=${REAL_REPO}\$" "$DESTR" || fail "repo_root: CHUMP_REPO_ROOT not rewritten: $(grep -n CHUMP_REPO_ROOT "$DESTR")"
grep -q "cd ${REAL_REPO};" "$DESTR" || fail "repo_root: inline 'cd <repo>' not rewritten: $(grep -n ExecStart "$DESTR")"
grep -q "exec ${REAL_REPO}/scripts/ops/x.sh" "$DESTR" || fail "repo_root: ExecStart repo path not rewritten: $(grep -n ExecStart "$DESTR")"
grep -q "source ${TMP}/home-ubuntu/.chump/providers.env" "$DESTR" || fail "repo_root: home-only .chump path should track run-home, not the repo: $(grep -n ExecStart "$DESTR")"
grep -q 'Projects/chump' "$DESTR" && fail "repo_root: a stale Projects/chump path leaked into the unit: $(grep -n 'Projects/chump' "$DESTR")"
# THE class that hid: the baked WorkingDirectory must be a directory that
# actually exists on disk (a non-existent cwd is status=200/CHDIR at runtime).
_wd="$(sed -n 's/^WorkingDirectory=//p' "$DESTR")"
[ -d "$_wd" ] || fail "repo_root: baked WorkingDirectory '$_wd' does not exist on disk (this is the 200/CHDIR bug)"
pass "organ_unit_host_rewrite: repo_root redirects every repo path to the real (existing) checkout — no Projects/chump ghost, WorkingDirectory exists"

echo "ALL PASS"
