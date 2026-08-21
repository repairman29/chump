#!/usr/bin/env bash
# chump-node-install.sh — COTG: one command to turn an OWNED box into a clean,
# reproducible, self-supervising, self-testing ChumpOS node.
#
# Host-agnostic: Termux(Android/aarch64, runit) / systemd-Linux / macOS(launchd).
# Replaces hand-assembly (helsinki's bespoke organs; the RESILIENT-336 Pixel node)
# with an INSTALLED node whose organs all come from a manifest — never hand-placed.
# See docs/process/COTG_NODE_INSTALL.md.  RESILIENT-318 / RESILIENT-364.
#
# Usage:
#   chump-node-install.sh --role brain|muscle|all [--home DIR] [--self-test-only] [--dry-run]
#                          [--creds-file PATH]
#
# Zero-touch creds (INFRA-3629, the "bot told to do it" path — no human ever
# opens an editor): supply creds from exactly ONE source and the CREDS phase
# materializes ~/.chump/providers.env itself:
#   --creds-file PATH          path to a ready-made providers.env (KEY=VALUE lines)
#   $CHUMP_BOOTSTRAP_CREDS     the same file body, inline, e.g.:
#     CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=%s\n' "$OAUTH" "$GH")" \
#       curl -fsSL .../chump-node-install.sh | bash -s -- --role brain
# Neither source's VALUES ever appear in `ps`, argv, or this script's logs —
# only the source used and which required keys are present/missing are logged.
# If ~/.chump/providers.env already exists it is left alone (idempotent).
#
# Phases: DETECT -> HOME -> CREDS -> BINARY -> ORGANS -> SUPERVISE -> SELF-TEST
# Idempotent + non-destructive: installs into $NODE_DIR (default ~/.chumpnode) and
# supervises via the host's native supervisor; state stays at ~/.chump.
set -uo pipefail

# ---------- args ----------
ROLE="brain"; NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"; SELF_TEST_ONLY=0; DRY=0; CREDS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --home) NODE_DIR="$2"; shift 2;;
    --self-test-only) SELF_TEST_ONLY=1; shift;;
    --dry-run) DRY=1; shift;;
    --creds-file) CREDS_FILE="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$ROLE" in brain|muscle|all) ;; *) echo "role must be brain|muscle|all" >&2; exit 2;; esac

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
CREDS="$STATE_DIR/providers.env"
LOG_DIR="$NODE_DIR/logs"
ORGAN_DIR="$NODE_DIR/organs"
BIN="$NODE_DIR/bin/chump"
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[%s]\033[0m %s\n' "$1" "$2"; }
run(){ [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

# ---------- 1. DETECT ----------
detect_host() {
  ARCH="$(uname -m)"; OS="$(uname -s)"
  if [ -n "${PREFIX:-}" ] && printf '%s' "$PREFIX" | grep -q 'com.termux'; then
    HOST_KIND="termux"; SUPERVISOR="runit"
    BOOT_DIR="$HOME/.termux/boot"; SVC_DIR="$PREFIX/var/service"
  elif [ "$OS" = "Darwin" ]; then
    HOST_KIND="macos"; SUPERVISOR="launchd"; BOOT_DIR=""; SVC_DIR="$HOME/Library/LaunchAgents"
  elif command -v systemctl >/dev/null 2>&1; then
    HOST_KIND="linux-systemd"; SUPERVISOR="systemd"; BOOT_DIR=""; SVC_DIR="/etc/systemd/system"
  else
    HOST_KIND="linux-nosystemd"; SUPERVISOR="nohup"; BOOT_DIR=""; SVC_DIR="$NODE_DIR/services"
  fi
  info DETECT "host=$HOST_KIND arch=$ARCH supervisor=$SUPERVISOR"
}

# ---------- supervisor abstraction (the reusable core) ----------
# svc_install <name> <exec-command>   — define a supervised, restart-always service
# svc_up <name> / svc_status <name>   — start / query
svc_install() {
  local name="$1" cmd="$2"
  case "$SUPERVISOR" in
    runit)
      run "mkdir -p '$SVC_DIR/$name/log'"
      run "printf '#!/data/data/com.termux/files/usr/bin/sh\nexec 2>&1\ntermux-wake-lock 2>/dev/null || true\nexec %s\n' \"$cmd\" > '$SVC_DIR/$name/run'"
      run "chmod +x '$SVC_DIR/$name/run'"
      run "printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s\n' \"$LOG_DIR/$name\" > '$SVC_DIR/$name/log/run'"
      run "chmod +x '$SVC_DIR/$name/log/run'"; run "mkdir -p '$LOG_DIR/$name'"
      ;;
    systemd)
      run "cat > '$SVC_DIR/chump-$name.service' <<EOF
[Unit]
Description=ChumpOS organ $name
[Service]
ExecStart=$cmd
Restart=always
Environment=CHUMP_NODE_DIR=$NODE_DIR
[Install]
WantedBy=multi-user.target
EOF"
      run "systemctl daemon-reload"
      ;;
    *) run "mkdir -p '$SVC_DIR'"; run "echo '$cmd' > '$SVC_DIR/$name.cmd'";;
  esac
}
svc_up() {
  local name="$1"
  case "$SUPERVISOR" in
    # explicit service path: Termux leaves SVDIR unset, so bare names hit sv's
    # compiled default (/var/service) which doesn't exist. runsvdir also auto-starts
    # new dirs within ~5s, so this `sv up` is just a nudge — give runsvdir a moment.
    runit) run "sleep 6; sv up '$SVC_DIR/$name' 2>/dev/null || true";;
    systemd) run "systemctl enable --now 'chump-$name' 2>/dev/null || true";;
    *) :;;
  esac
}
svc_status() {  # prints "up" or "down"
  local name="$1"
  case "$SUPERVISOR" in
    runit) sv status "$SVC_DIR/$name" 2>/dev/null | grep -q '^run:' && echo up || echo down;;
    systemd) systemctl is-active "chump-$name" 2>/dev/null | grep -q '^active' && echo up || echo down;;
    *) [ -f "$SVC_DIR/$name.cmd" ] && echo up || echo down;;
  esac
}

# ---------- 2. HOME ----------
ensure_home() {
  run "mkdir -p '$NODE_DIR/bin' '$ORGAN_DIR' '$LOG_DIR' '$STATE_DIR'"
  if [ -d "$NODE_DIR/repo/.git" ]; then ok "repo present ($NODE_DIR/repo)"
  else info HOME "repo checkout expected at $NODE_DIR/repo (clone chump there; skipping in v1)"; fi
  ok "node home: $NODE_DIR"
}

# ---------- 3. CREDS ----------
REQUIRED_CRED_KEYS="CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN"

# Zero-touch acquire (INFRA-3629): materialize $CREDS from --creds-file or
# $CHUMP_BOOTSTRAP_CREDS. Never echoes secret VALUES — only which source was
# used. Leaves an existing file untouched (idempotent, no clobber).
materialize_creds() {
  [ -f "$CREDS" ] && return 0
  if [ -n "$CREDS_FILE" ]; then
    [ -f "$CREDS_FILE" ] || { no "--creds-file not found: $CREDS_FILE"; return 1; }
    if [ "$DRY" = 1 ]; then echo "  DRY: install '$CREDS_FILE' -> '$CREDS' (mode 600)"; return 0; fi
    mkdir -p "$STATE_DIR"
    install -m 600 "$CREDS_FILE" "$CREDS"
    ok "materialized creds from --creds-file (path only; values not logged)"
  elif [ -n "${CHUMP_BOOTSTRAP_CREDS:-}" ]; then
    if [ "$DRY" = 1 ]; then echo "  DRY: write \$CHUMP_BOOTSTRAP_CREDS -> '$CREDS' (mode 600)"; return 0; fi
    mkdir -p "$STATE_DIR"
    ( umask 077; printf '%s\n' "$CHUMP_BOOTSTRAP_CREDS" > "$CREDS" )
    ok "materialized creds from \$CHUMP_BOOTSTRAP_CREDS (env var; values not logged)"
  fi
}

check_creds() {
  materialize_creds
  [ -f "$CREDS" ] || { no "creds missing: $CREDS (supply --creds-file PATH or \$CHUMP_BOOTSTRAP_CREDS)"; return 1; }
  local missing=""
  for k in $REQUIRED_CRED_KEYS; do
    grep -qE "^(export )?$k=" "$CREDS" || missing="$missing $k"
  done
  [ -n "$missing" ] && { no "creds present but missing keys:$missing — supply via --creds-file/\$CHUMP_BOOTSTRAP_CREDS and re-run"; return 1; }
  ok "creds ok ($(grep -cE '^(export )?[A-Z_]+=' "$CREDS") keys, incl OAuth+GH)"
}

# ---------- 4. BINARY ----------
ensure_binary() {
  local found=""
  for c in "$BIN" "$HOME/chump/chump" "$(command -v chump 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { found="$c"; break; }
  done
  [ -z "$found" ] && { no "no chump binary found (build via deploy-pixel-node.sh / cargo)"; return 1; }
  [ "$found" != "$BIN" ] && run "ln -sf '$found' '$BIN'"
  ok "binary: $found -> $BIN"
}

# ---------- 5. ORGANS (from manifest) ----------
brain_organs() {  # name|exec
  echo "node-heartbeat|$ORGAN_DIR/node-heartbeat.sh"
}
muscle_organs() { echo "worker|$ORGAN_DIR/worker.sh"; }
install_organs() {
  # write the heartbeat organ (brain's proof-of-life: refresh heartbeat + node profile)
  run "cat > '$ORGAN_DIR/node-heartbeat.sh' <<'HB'
#!/data/data/com.termux/files/usr/bin/env bash
STATE=\"\${CHUMP_STATE_DIR:-\$HOME/.chump}\"
while true; do
  date -u +%Y-%m-%dT%H:%M:%SZ > \"\$STATE/node-heartbeat\"
  sleep 60
done
HB"
  run "chmod +x '$ORGAN_DIR/node-heartbeat.sh'"
  local list; case "$ROLE" in brain) list="$(brain_organs)";; muscle) list="$(muscle_organs)";; all) list="$(brain_organs; muscle_organs)";; esac
  echo "$list" | while IFS='|' read -r name exec; do
    [ -z "$name" ] && continue
    svc_install "$name" "$exec"; svc_up "$name"; ok "organ installed+up: $name"
  done
}

# ---------- 6. SUPERVISE (survive reboot) ----------
install_supervise() {
  case "$HOST_KIND" in
    termux)
      run "mkdir -p '$BOOT_DIR'"
      run "cat > '$BOOT_DIR/10-chump-node.sh' <<'BT'
#!/data/data/com.termux/files/usr/bin/sh
sshd 2>/dev/null; termux-wake-lock 2>/dev/null
# runit (termux-services) auto-restores services on boot
BT"
      run "chmod +x '$BOOT_DIR/10-chump-node.sh'"; ok "reboot hook: $BOOT_DIR/10-chump-node.sh"
      ;;
    linux-systemd) ok "systemd enables organs on boot (done in svc_up)";;
    *) info SUPERVISE "manual supervision on $HOST_KIND";;
  esac
}

# ---------- 7. SELF-TEST (defines 'installed') ----------
self_test() {
  info SELF-TEST "verifying node is installed & healthy"
  local fail=0
  [ -n "$HOST_KIND" ] && ok "host detected: $HOST_KIND/$ARCH" || { no "host detect"; fail=1; }
  check_creds || fail=1
  if [ -x "$BIN" ]; then ok "binary linked: $BIN"; else no "binary"; fail=1; fi
  # each role organ supervised & up
  local list; case "$ROLE" in brain) list="$(brain_organs)";; muscle) list="$(muscle_organs)";; all) list="$(brain_organs; muscle_organs)";; esac
  echo "$list" | while IFS='|' read -r name _; do [ -z "$name" ] && continue
    if [ "$(svc_status "$name")" = up ]; then ok "organ up: $name"; else no "organ DOWN: $name"; fi
  done
  # heartbeat freshness (< 180s old)
  local hb="$STATE_DIR/node-heartbeat"
  if [ -f "$hb" ]; then
    local age=$(( $(date -u +%s) - $(date -u -d "$(cat "$hb")" +%s 2>/dev/null || echo 0) ))
    [ "$age" -lt 180 ] 2>/dev/null && ok "heartbeat fresh (${age}s)" || no "heartbeat stale (${age}s)"
  else no "no heartbeat yet (organ just started; re-run --self-test-only in ~70s)"; fi
  # aggregate organ-down check (subshell above can't set fail; re-check here)
  echo "$list" | while IFS='|' read -r name _; do [ -z "$name" ] && continue; [ "$(svc_status "$name")" = up ] || exit 1; done || fail=1
  echo
  if [ "$fail" = 0 ]; then printf '\033[42m INSTALLED ✓ \033[0m role=%s host=%s\n' "$ROLE" "$HOST_KIND"; return 0
  else printf '\033[41m NOT FULLY INSTALLED \033[0m — fix the ✗ above\n'; return 1; fi
}

# ---------- run ----------
printf '\033[1m=== chump-node-install: role=%s home=%s ===\033[0m\n' "$ROLE" "$NODE_DIR"
detect_host
if [ "$SELF_TEST_ONLY" = 1 ]; then self_test; exit $?; fi
ensure_home
check_creds || info CREDS "fix creds before organs will authenticate"
ensure_binary || info BINARY "install a binary, then re-run"
install_organs
install_supervise
# RESILIENT-318: install the self-management suite (orchestrator + reapers + disk-monitor)
[ "$SELF_TEST_ONLY" = 1 ] || bash "$(dirname "$0")/install-node-housekeeping.sh" || info ORGANS "housekeeping install skipped"
echo
self_test
