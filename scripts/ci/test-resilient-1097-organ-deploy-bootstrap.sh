#!/usr/bin/env bash
# scripts/ci/test-resilient-1097-organ-deploy-bootstrap.sh — RESILIENT-1097
#
# Regression test for the "~18 manifest organs never get unit files
# installed" hole: chump-node-install.sh's place_role_unit_files() needs
# root to write /etc/systemd/system and used to skip UNCONDITIONALLY when
# the install ran as a non-root user (the exact cuphead symptom — reconcile
# then backs off every role-matched organ forever because none of their
# unit files ever landed on disk).
#
# This proves bootstrap_organ_deploy_via_sudo() — the fix — actually places
# chump-organ-deploy.{service,timer} via `sudo` when running as non-root, so
# that organ's own root-run cycles can self-heal the rest of the roster.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }
bash -n "$INSTALLER" || { echo "FAIL: bash -n failed: $INSTALLER"; exit 1; }

fails=0
pass(){ printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[0;31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-resilient-1097-organ-deploy-bootstrap.sh ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1097-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fake repo tree with the two source unit files bootstrap needs.
REPO="$TMP/repo"
mkdir -p "$REPO/scripts/dispatch" "$REPO/scripts/ops/lib"
cp "$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh" "$REPO/scripts/ops/lib/organ-manifest-lib.sh"
cp "$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh" "$REPO/scripts/ops/lib/organ-unit-install-lib.sh"
cat > "$REPO/scripts/dispatch/chump-organ-deploy.service" <<'EOF'
[Unit]
Description=organ deploy
[Service]
User=root
Environment=HOME=/root
ExecStart=/root/Projects/chump/scripts/ops/organ-deploy.sh
EOF
cat > "$REPO/scripts/dispatch/chump-organ-deploy.timer" <<'EOF'
[Unit]
Description=organ deploy timer
[Timer]
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

# Fake `sudo` on PATH: non-interactive check succeeds, and it just execs the
# command directly (no real root needed) so the test is network/root-free.
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"
cat > "$BINDIR/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then shift; exec "$@"; fi
exec "$@"
EOF
chmod +x "$BINDIR/sudo"

DEST="$TMP/etc-systemd-system"
mkdir -p "$DEST"

# shellcheck disable=SC1090
set --
. "$INSTALLER"

# ── 1. sudo bootstrap places both unit files, keeps User=root, arms the timer ──
ROLE=brain
export CHUMP_NODE_INSTALL_SYSTEMD_DIR="$DEST"
SYSTEMCTL_CALLS="$TMP/systemctl-calls.log"
: > "$SYSTEMCTL_CALLS"
cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SYSTEMCTL_CALLS"
exit 0
EOF
chmod +x "$BINDIR/systemctl"
PATH="$BINDIR:$PATH" bootstrap_organ_deploy_via_sudo \
  "$REPO" "$REPO/scripts/ops/lib/organ-manifest-lib.sh" "$REPO/scripts/ops/lib/organ-unit-install-lib.sh" "$REPO/scripts/dispatch"

[ -f "$DEST/chump-organ-deploy.service" ] || fail "bootstrap did not place chump-organ-deploy.service via sudo"
[ -f "$DEST/chump-organ-deploy.timer" ] || fail "bootstrap did not place chump-organ-deploy.timer via sudo"
pass "bootstrap_organ_deploy_via_sudo placed both unit files under a non-root \$dest_dir via the stub sudo"

grep -q '^User=root$' "$DEST/chump-organ-deploy.service" || fail "placed service lost its keep-root User=root"
pass "placed chump-organ-deploy.service keeps User=root (RESILIENT-374 contract)"

grep -q 'daemon-reload' "$SYSTEMCTL_CALLS" || fail "bootstrap did not call systemctl daemon-reload"
grep -q 'enable --now chump-organ-deploy.timer' "$SYSTEMCTL_CALLS" || fail "bootstrap did not enable --now chump-organ-deploy.timer"
pass "bootstrap arms chump-organ-deploy.timer (daemon-reload + enable --now)"

# ── 2. muscle role never bootstraps organ-deploy (role=janitor, brain/all only) ─
rm -f "$DEST"/chump-organ-deploy.*
: > "$SYSTEMCTL_CALLS"
ROLE=muscle
PATH="$BINDIR:$PATH" bootstrap_organ_deploy_via_sudo \
  "$REPO" "$REPO/scripts/ops/lib/organ-manifest-lib.sh" "$REPO/scripts/ops/lib/organ-unit-install-lib.sh" "$REPO/scripts/dispatch"
[ -f "$DEST/chump-organ-deploy.service" ] && fail "muscle-role bootstrap should NOT place chump-organ-deploy (role=janitor is brain/all only)"
pass "muscle role correctly skips the organ-deploy bootstrap"

# ── 3. sudo present but NOT passwordless -> non-fatal skip, no files placed ────
rm -f "$DEST"/chump-organ-deploy.*
ROLE=brain
NOPASS_BIN="$TMP/nopass-bin"; mkdir -p "$NOPASS_BIN"
cat > "$NOPASS_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
# `sudo -n true` fails (no cached/passwordless credential) — the real-world
# shape on a fresh box nobody has granted NOPASSWD sudo to yet.
exit 1
EOF
chmod +x "$NOPASS_BIN/sudo"
PATH="$NOPASS_BIN:$PATH" bootstrap_organ_deploy_via_sudo \
  "$REPO" "$REPO/scripts/ops/lib/organ-manifest-lib.sh" "$REPO/scripts/ops/lib/organ-unit-install-lib.sh" "$REPO/scripts/dispatch" \
  2>&1 | grep -q "no passwordless sudo" || fail "no-passwordless-sudo case should log a clear non-fatal message"
[ -f "$DEST/chump-organ-deploy.service" ] && fail "no-passwordless-sudo case must not place any unit file"
pass "sudo present but not passwordless: non-fatal, logs clearly, places nothing"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
