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
#
# Phases: DETECT -> HOME -> CREDS -> BINARY -> ORGANS -> SUPERVISE -> SELF-TEST
# Idempotent + non-destructive: installs into $NODE_DIR (default ~/.chumpnode) and
# supervises via the host's native supervisor; state stays at ~/.chump.
set -uo pipefail

# ---------- args ----------
ROLE="brain"; NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"; SELF_TEST_ONLY=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --home) NODE_DIR="$2"; shift 2;;
    --self-test-only) SELF_TEST_ONLY=1; shift;;
    --dry-run) DRY=1; shift;;
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
check_creds() {
  [ -f "$CREDS" ] || { no "creds missing: $CREDS"; return 1; }
  local missing=""
  for k in CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN; do
    grep -qE "^(export )?$k=" "$CREDS" || missing="$missing $k"
  done
  [ -n "$missing" ] && { no "creds present but missing keys:$missing"; return 1; }
  ok "creds ok ($(grep -cE '^(export )?[A-Z_]+=' "$CREDS") keys, incl OAuth+GH)"
}

# ---------- 4. BINARY ----------
ensure_binary() {
  local found=""
  for c in "$BIN" "$HOME/chump/chump" "$(command -v chump 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { found="$c"; break; }
  done
  if [ -n "$found" ]; then
    [ "$found" != "$BIN" ] && run "ln -sf '$found' '$BIN'"
    ok "binary: $found -> $BIN"
    return 0
  fi
  build_binary_from_repo
}

# No binary found: build it from $NODE_DIR/repo. Reuses the resolve+build
# logic already hardened in refresh-runner-binary.sh (linux/macos — worktree
# @ origin/main, warm shared target dir, codesign) and build-android.sh
# (termux cross-compile) instead of reimplementing cargo invocation here.
# Gates the artifact behind a WARM smoke (mirrors deploy-pixel-node.sh) before
# it is ever symlinked to $BIN.
build_binary_from_repo() {
  local repo="$NODE_DIR/repo"
  if [ ! -d "$repo/.git" ]; then
    no "no binary and no repo checkout at $repo — clone chump there first"
    return 1
  fi
  local staged="$NODE_DIR/bin/chump.new"
  run "mkdir -p '$LOG_DIR'"
  local build_log="$LOG_DIR/binary-build-$(date -u +%Y%m%dT%H%M%SZ).log"

  if [ "$DRY" = 1 ]; then
    case "$HOST_KIND" in
      termux) echo "  DRY: (cd '$repo' && bash scripts/setup/build-android.sh)  # then cp -> $staged";;
      *) echo "  DRY: CHUMP_REPO_ROOT='$repo' CHUMP_RUNNER_BIN='$staged' bash '$repo/scripts/setup/refresh-runner-binary.sh'";;
    esac
    echo "  DRY: WARM smoke ('$staged' --version) before symlink -> $BIN"
    return 0
  fi

  info BINARY "no binary found — building from $repo (log: $build_log)"
  case "$HOST_KIND" in
    termux)
      if ! ( cd "$repo" && bash scripts/setup/build-android.sh ) >"$build_log" 2>&1; then
        no "android cross-build failed — see $build_log"
        return 1
      fi
      local built="$repo/target-android/aarch64-linux-android/release/chump"
      [ -f "$built" ] || built="$repo/target/aarch64-linux-android/release/chump"
      if [ ! -f "$built" ]; then
        no "build reported success but no binary at $built — see $build_log"
        return 1
      fi
      cp -f "$built" "$staged"
      ;;
    *)
      if ! CHUMP_REPO_ROOT="$repo" CHUMP_RUNNER_BIN="$staged" \
           bash "$repo/scripts/setup/refresh-runner-binary.sh" >"$build_log" 2>&1; then
        no "cargo build failed — see $build_log"
        return 1
      fi
      if [ ! -x "$staged" ]; then
        no "build reported success but binary missing at $staged — see $build_log"
        return 1
      fi
      ;;
  esac
  chmod +x "$staged"

  # WARM: the built binary must answer a trivial prompt before it's trusted.
  info BINARY "warming freshly built binary (WARM smoke)..."
  local warm_out
  warm_out="$("$staged" --version 2>&1)"
  if [ -z "$warm_out" ]; then
    no "WARM smoke failed — '$staged --version' produced no output; see $build_log"
    rm -f "$staged"
    return 1
  fi
  ok "WARM smoke ok: $warm_out"

  mv -f "$staged" "$BIN"
  chmod +x "$BIN"
  ok "binary built + warm-verified: $BIN"
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
