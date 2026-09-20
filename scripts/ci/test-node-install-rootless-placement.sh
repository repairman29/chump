#!/usr/bin/env bash
# scripts/ci/test-node-install-rootless-placement.sh — INFRA-7757
#
# Regression test for the one-command-install keystone fix: a fresh,
# genuinely non-root box previously converged 3 of ~40 organs because BOTH
# unit-placement write sites in chump-node-install.sh hard-required root
# (place_role_unit_files() checked `id -u` and skipped entirely; svc_install/
# svc_up/svc_down/svc_status had NO root-check at all and silently wrote to
# /etc/systemd/system, which fails on a non-root box via a swallowed
# `2>/dev/null || true`). This proves the fix WITHOUT touching real systemd
# or requiring root in CI: a stubbed `systemctl`/`loginctl` on PATH, and
# every unit destination overridden to a tmp dir.
#
#   1. place_role_unit_files() places the FULL role-matched roster (not just
#      3 hand-coded organs) as systemd --user units when SYSTEMD_USER_SCOPE=1
#      — including a role=brain organ — under $HOME/.config/systemd/user
#      (CHUMP_NODE_INSTALL_SYSTEMD_DIR override here, same code path).
#   2. loginctl enable-linger runs exactly once, idempotently.
#   3. svc_install/svc_up/svc_down/svc_status target the SAME --user dest and
#      call `systemctl --user`, for a common organ (heartbeat-style).
#   4. chump-organ-deploy.{service,timer} (the root-only _KEEP_ROOT pair) is
#      SKIPPED on the rootless box and does NOT block any other organ from
#      placing.
#   5. role-gating is unaffected: a role=muscle organ is excluded from a
#      --role brain placement, exactly as before this fix.
#   6. the existing root-available path (SYSTEMD_USER_SCOPE=0) is unaffected:
#      system-wide dest dir, plain `systemctl` (no --user), and the
#      chump-organ-deploy pair IS placed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }
bash -n "$INSTALLER" || { echo "FAIL: bash -n failed: $INSTALLER"; exit 1; }

fails=0
pass(){ printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '\033[0;31mFAIL\033[0m %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-node-install-rootless-placement.sh (INFRA-7757) ==="

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-7757-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---- fake repo tree: manifest + libs (the REAL, just-edited libs — this is
# an integration test of the actual fix, not a re-implementation of it) +
# dispatch unit files for a small but representative role roster.
REPO="$TMP/node/repo"
mkdir -p "$REPO/scripts/dispatch" "$REPO/scripts/ops/lib"
cp "$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh" "$REPO/scripts/ops/lib/organ-manifest-lib.sh"
cp "$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh" "$REPO/scripts/ops/lib/organ-unit-install-lib.sh"

cat > "$REPO/scripts/ops/organ-manifest.txt" <<'EOF'
enabled  chump-board-cycle.service   role=brain
enabled  chump-duty-officer.service  role=brain
enabled  chump-gap-drain.service     role=data
enabled  chump-worker.service        role=muscle
enabled  chump-organ-deploy.service  role=janitor
enabled  chump-organ-deploy.timer    role=janitor
EOF

write_fake_service() {  # write_fake_service <path> [wanted_by]
  local path="$1" wanted="${2:-multi-user.target}"
  cat > "$path" <<EOF
[Unit]
Description=fake organ
[Service]
User=root
Environment=HOME=/root
ExecStart=/root/Projects/chump/scripts/x.sh
[Install]
WantedBy=${wanted}
EOF
}
write_fake_timer() {
  cat > "$1" <<'EOF'
[Unit]
Description=fake timer
[Timer]
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF
}
write_fake_service "$REPO/scripts/dispatch/chump-board-cycle.service"
write_fake_service "$REPO/scripts/dispatch/chump-duty-officer.service"
write_fake_service "$REPO/scripts/dispatch/chump-gap-drain.service"
write_fake_service "$REPO/scripts/dispatch/chump-worker.service"
write_fake_service "$REPO/scripts/dispatch/chump-organ-deploy.service"
write_fake_timer   "$REPO/scripts/dispatch/chump-organ-deploy.timer"
# organ-reconcile is force-added for every role (self-heal beat) regardless
# of the manifest — the placer must find its own dispatch files.
write_fake_service "$REPO/scripts/dispatch/chump-organ-reconcile.service"
write_fake_timer   "$REPO/scripts/dispatch/chump-organ-reconcile.timer"

# ---- stub systemctl + loginctl on PATH, logging every call ----------------
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"
SYSTEMCTL_LOG="$TMP/systemctl-calls.log"
LOGINCTL_LOG="$TMP/loginctl-calls.log"
cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$BINDIR/systemctl"
cat > "$BINDIR/loginctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$LOGINCTL_LOG"
exit 0
EOF
chmod +x "$BINDIR/loginctl"
export PATH="$BINDIR:$PATH"

# ---- source the installer (BASH_SOURCE guard prevents a real install run) -
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin" "$CHUMP_STATE_DIR"
touch "$CHUMP_NODE_DIR/bin/chump"; chmod +x "$CHUMP_NODE_DIR/bin/chump"
set --
# shellcheck disable=SC1090
. "$INSTALLER"

# ═══════════════════════════════════════════════════════════════════════
# PART 1 — rootless (SYSTEMD_USER_SCOPE=1): the keystone case.
# ═══════════════════════════════════════════════════════════════════════
ROLE=brain
HOST_KIND=linux-systemd
SYSTEMD_USER_SCOPE=1
DRY=0
USER_DEST="$TMP/user-systemd-dir"
export CHUMP_NODE_INSTALL_SYSTEMD_DIR="$USER_DEST"
: > "$SYSTEMCTL_LOG"; : > "$LOGINCTL_LOG"
_LINGER_ENSURED=0

# NB: captured via redirect-to-file, NOT $(...) command substitution — a
# command-substitution subshell would isolate _LINGER_ENSURED's mutation
# from this (parent) shell, breaking the idempotency check a few lines down
# that relies on the SAME shell seeing _LINGER_ENSURED already set to 1.
place_role_unit_files > "$TMP/place1.log" 2>&1
out="$(cat "$TMP/place1.log")"

# 1. A role=brain organ is placed (proves it's not stuck at the old 3
#    hand-coded organs — board-cycle is ATC brain-plane work).
[ -f "$USER_DEST/chump-board-cycle.service" ] \
  && pass "rootless: role=brain organ (chump-board-cycle) placed as a --user unit" \
  || fail "rootless: chump-board-cycle.service was NOT placed — brain plane still dark. Output: $out"
[ -f "$USER_DEST/chump-duty-officer.service" ] \
  && pass "rootless: second role=brain organ (chump-duty-officer) placed" \
  || fail "rootless: chump-duty-officer.service was NOT placed"
[ -f "$USER_DEST/chump-gap-drain.service" ] \
  && pass "rootless: role=data organ (chump-gap-drain) placed (role filter brain includes data)" \
  || fail "rootless: chump-gap-drain.service was NOT placed"
[ -f "$USER_DEST/chump-organ-reconcile.service" ] && [ -f "$USER_DEST/chump-organ-reconcile.timer" ] \
  && pass "rootless: self-heal beat (chump-organ-reconcile) placed for every role" \
  || fail "rootless: chump-organ-reconcile not placed"

placed_count=$(find "$USER_DEST" -maxdepth 1 -name 'chump-*.service' -o -name 'chump-*.timer' 2>/dev/null | grep -vc '\.d$')
[ "$placed_count" -gt 3 ] \
  && pass "rootless: placed $placed_count unit file(s) — more than the pre-fix 3-organ ceiling" \
  || fail "rootless: only placed $placed_count unit file(s) — still stuck at the old ceiling. Output: $out"

# 2. role-gating unaffected: role=muscle organ excluded from --role brain.
[ -f "$USER_DEST/chump-worker.service" ] \
  && fail "rootless: role=muscle organ (chump-worker) must NOT be placed under --role brain" \
  || pass "rootless: role-gating unaffected — role=muscle organ correctly excluded"

# 3. chump-organ-deploy pair (root-only _KEEP_ROOT) is SKIPPED, and its
#    absence does not block anything else from placing.
[ -f "$USER_DEST/chump-organ-deploy.service" ] || [ -f "$USER_DEST/chump-organ-deploy.timer" ] \
  && fail "rootless: chump-organ-deploy.{service,timer} must NOT be placed as a --user unit (root-only, additive-when-root-available)" \
  || pass "rootless: chump-organ-deploy pair correctly skipped (root-only, additive)"
echo "$out" | grep -qi "root-only unit(s) skipped" \
  && pass "rootless: place_role_unit_files reports the root-only skip explicitly" \
  || fail "rootless: no explicit note about the root-only skip; output: $out"

# 4. placed units carry the --user shape: no User=, WantedBy=default.target.
grep -q '^User=' "$USER_DEST/chump-board-cycle.service" \
  && fail "rootless: placed unit still carries User= (must be stripped for --user scope)" \
  || pass "rootless: placed unit has User= stripped (systemd --user scope)"
grep -q '^WantedBy=default\.target$' "$USER_DEST/chump-board-cycle.service" \
  && pass "rootless: placed unit's WantedBy swapped to default.target" \
  || fail "rootless: placed unit's WantedBy was not swapped to default.target: $(grep '^WantedBy=' "$USER_DEST/chump-board-cycle.service")"

# 5. systemctl was invoked with --user, never bare.
grep -q -- '--user daemon-reload' "$SYSTEMCTL_LOG" \
  && pass "rootless: place_role_unit_files calls systemctl --user daemon-reload" \
  || fail "rootless: no 'systemctl --user daemon-reload' call logged: $(cat "$SYSTEMCTL_LOG")"
grep -qE '^daemon-reload$|^enable --now' "$SYSTEMCTL_LOG" \
  && fail "rootless: a bare (non --user) systemctl call leaked through: $(cat "$SYSTEMCTL_LOG")" \
  || pass "rootless: no bare (non --user) systemctl calls leaked through"

# 6. loginctl enable-linger ran, exactly once, idempotently.
linger_calls=$(grep -o "enable-linger" "$LOGINCTL_LOG" 2>/dev/null | wc -l | tr -d ' ')
[ "$linger_calls" = 1 ] \
  && pass "rootless: loginctl enable-linger called exactly once" \
  || fail "rootless: loginctl enable-linger called $linger_calls time(s), expected exactly 1"
# A second placement call in the same process must NOT re-invoke linger.
place_role_unit_files >/dev/null 2>&1
linger_calls2=$(grep -o "enable-linger" "$LOGINCTL_LOG" 2>/dev/null | wc -l | tr -d ' ')
[ "$linger_calls2" = 1 ] \
  && pass "rootless: loginctl enable-linger is idempotent across repeated placement calls (still 1 total)" \
  || fail "rootless: loginctl enable-linger called again on a second placement call ($linger_calls2 total) — not idempotent"

# ═══════════════════════════════════════════════════════════════════════
# PART 2 — svc_install/svc_up/svc_down/svc_status rootless scope.
# ═══════════════════════════════════════════════════════════════════════
SVC_DIR="$TMP/user-svc-dir"
SUPERVISOR=systemd
SYSTEMD_USER_SCOPE=1
DRY=0
: > "$SYSTEMCTL_LOG"
svc_install heartbeat "/bin/true"
[ -f "$SVC_DIR/chump-heartbeat.service" ] \
  && pass "svc_install: rootless placement lands at \$SVC_DIR (systemd --user dir), not /etc/systemd/system" \
  || fail "svc_install: chump-heartbeat.service not found at $SVC_DIR"
grep -q '^WantedBy=default\.target$' "$SVC_DIR/chump-heartbeat.service" 2>/dev/null \
  && pass "svc_install: rootless unit's WantedBy=default.target" \
  || fail "svc_install: rootless unit missing WantedBy=default.target"
grep -q -- '--user daemon-reload' "$SYSTEMCTL_LOG" \
  && pass "svc_install: calls systemctl --user daemon-reload" \
  || fail "svc_install: no 'systemctl --user daemon-reload' logged: $(cat "$SYSTEMCTL_LOG")"

: > "$SYSTEMCTL_LOG"
svc_up heartbeat
grep -qF -- '--user enable --now chump-heartbeat' "$SYSTEMCTL_LOG" \
  && pass "svc_up: calls systemctl --user enable --now" \
  || fail "svc_up: expected --user enable --now call, got: $(cat "$SYSTEMCTL_LOG")"

: > "$SYSTEMCTL_LOG"
svc_down heartbeat
grep -qF -- '--user disable --now chump-heartbeat' "$SYSTEMCTL_LOG" \
  && pass "svc_down: calls systemctl --user disable --now" \
  || fail "svc_down: expected --user disable --now call, got: $(cat "$SYSTEMCTL_LOG")"

cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SYSTEMCTL_LOG"
if [ "\$1" = "--user" ] && [ "\$2" = "is-active" ]; then echo active; exit 0; fi
exit 3
EOF
chmod +x "$BINDIR/systemctl"
: > "$SYSTEMCTL_LOG"
st="$(svc_status heartbeat)"
[ "$st" = "up" ] \
  && pass "svc_status: rootless status query uses systemctl --user is-active" \
  || fail "svc_status: expected 'up' via --user is-active, got '$st'"

# ═══════════════════════════════════════════════════════════════════════
# PART 3 — root-available path (SYSTEMD_USER_SCOPE=0) stays exactly as
# before: system-wide dest dir, plain systemctl, deploy pair IS placed.
# ═══════════════════════════════════════════════════════════════════════
cat > "$BINDIR/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$BINDIR/systemctl"
ROLE=brain
HOST_KIND=linux-systemd
SYSTEMD_USER_SCOPE=0
ROOT_DEST="$TMP/root-systemd-dir"
export CHUMP_NODE_INSTALL_SYSTEMD_DIR="$ROOT_DEST"
: > "$SYSTEMCTL_LOG"; : > "$LOGINCTL_LOG"
_LINGER_ENSURED=0

out2="$(place_role_unit_files 2>&1)"
[ -f "$ROOT_DEST/chump-organ-deploy.service" ] && [ -f "$ROOT_DEST/chump-organ-deploy.timer" ] \
  && pass "root-available: chump-organ-deploy pair IS placed when root is available (unaffected by this fix)" \
  || fail "root-available: chump-organ-deploy pair should still be placed when root is available. Output: $out2"
grep -q '^User=root$' "$ROOT_DEST/chump-organ-deploy.service" \
  && pass "root-available: chump-organ-deploy.service keeps User=root (RESILIENT-374 contract, unaffected)" \
  || fail "root-available: chump-organ-deploy.service lost User=root"
linger_calls3=$(grep -o 'enable-linger' "$LOGINCTL_LOG" 2>/dev/null | wc -l | tr -d ' ')
[ "${linger_calls3:-0}" = 0 ] \
  && pass "root-available: loginctl enable-linger is never called (system-wide units don't need linger)" \
  || fail "root-available: loginctl enable-linger was called $linger_calls3 time(s) when root was available"
grep -q -- '--user' "$SYSTEMCTL_LOG" \
  && fail "root-available: a --user systemctl call leaked through the root-available path: $(cat "$SYSTEMCTL_LOG")" \
  || pass "root-available: no --user systemctl calls — plain systemctl throughout, unchanged behavior"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: rootless placement holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
