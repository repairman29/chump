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
    --self-test-only|--check) SELF_TEST_ONLY=1; shift;;
    --dry-run) DRY=1; shift;;
    --creds-file) CREDS_FILE="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$ROLE" in brain|muscle|all) ;; *) echo "role must be brain|muscle|all" >&2; exit 2;; esac

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
# INFRA-3633: pin the canonical gap store here, once, so every phase below
# (and every organ this script launches) resolves the same state.db instead
# of some falling back to a repo-local $NODE_DIR/repo/.chump/state.db that
# would silently diverge from the machine's real gap backlog.
STATE_DB="${CHUMP_STATE_DB:-$STATE_DIR/state.db}"
export CHUMP_STATE_DB="$STATE_DB"
CREDS="$STATE_DIR/providers.env"
# INFRA-3634: pin the canonical *shared* gap store (PostgREST-fronted
# Postgres, currently CJ per docs/strategy/DATA_HOME_PLAN.md's dated note)
# the same way CHUMP_STATE_DB pins the local sqlite path above — one var,
# read here on the connect side and by install-gap-substrate.sh on the
# provision side, so the two never drift on which host is canonical.
# Precedence: explicit env > providers.env pin > CJ default.
GAP_STORE_URL="${CHUMP_GAP_STORE_URL:-}"
if [ -z "$GAP_STORE_URL" ] && [ -f "$CREDS" ]; then
  GAP_STORE_URL="$(grep -E '^CHUMP_GAP_STORE_URL=' "$CREDS" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
GAP_STORE_URL="${GAP_STORE_URL:-http://100.90.52.126:3000}"
export CHUMP_GAP_STORE_URL="$GAP_STORE_URL"
REPO_URL="${CHUMP_NODE_REPO_URL:-https://github.com/repairman29/chump.git}"
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

# ---------- 1.5 TOOLCHAIN PREFLIGHT (INFRA-3621) ----------
# Runs before HOME so a partial install never happens on a box missing a
# basic tool. Host-agnostic: termux pkg / linux apt|dnf / macos brew hints,
# reusing detect_host()'s HOST_KIND rather than re-detecting.
install_hint() {
  local tool="$1"
  case "$HOST_KIND" in
    termux) echo "pkg install -y $tool";;
    macos) echo "brew install $tool";;
    linux-systemd|linux-nosystemd)
      if command -v apt >/dev/null 2>&1; then echo "sudo apt install -y $tool"
      elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install -y $tool"
      else echo "install $tool via your distro's package manager"; fi
      ;;
    *) echo "install $tool";;
  esac
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    ok "rust toolchain present ($(rustc --version 2>/dev/null))"
    return 0
  fi
  info TOOLCHAIN "cargo/rustc missing — installing for host=$HOST_KIND"
  case "$HOST_KIND" in
    termux) run "pkg install -y rust";;
    macos|linux-systemd|linux-nosystemd)
      run "curl https://sh.rustup.rs -sSf | sh -s -- -y"
      # shellcheck disable=SC1091
      [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
      ;;
  esac
  if command -v cargo >/dev/null 2>&1; then ok "rust toolchain installed"
  else no "rust toolchain install failed ($(install_hint rust))"; return 1; fi
}

toolchain_preflight() {
  info PREFLIGHT "checking required tools (host=$HOST_KIND)"
  local required="git jq curl" missing=""
  for t in $required; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    for t in $missing; do no "missing: $t -> install with: $(install_hint "$t")"; done
    echo "fix missing tools above, then re-run" >&2
    exit 1
  fi
  ok "required tools present (git, jq, curl)"
  ensure_rust || { echo "fix rust toolchain above (see hint), then re-run" >&2; exit 1; }
}

# ---------- 2. HOME ----------
ensure_home() {
  run "mkdir -p '$NODE_DIR/bin' '$ORGAN_DIR' '$LOG_DIR' '$STATE_DIR'"
  # GH_TOKEN from providers.env, if present, for an authenticated clone of a
  # private repo. Never pass the token through run()'s echo path (--dry-run
  # would leak it) — build the token-injected URL only on the execute path.
  local gh_token=""
  if [ -f "$CREDS" ]; then
    gh_token="$(grep -E '^(export )?GH_TOKEN=' "$CREDS" | tail -1 | sed -E 's/^(export )?GH_TOKEN=//; s/^"(.*)"$/\1/')"
  fi
  local clone_url="$REPO_URL"
  case "$REPO_URL" in
    https://github.com/*) [ -n "$gh_token" ] && clone_url="https://x-access-token:${gh_token}@${REPO_URL#https://}";;
  esac
  if [ -d "$NODE_DIR/repo/.git" ]; then
    if [ "$DRY" = 1 ]; then
      echo "  DRY: git -C '$NODE_DIR/repo' fetch origin main --quiet"
      echo "  DRY: git -C '$NODE_DIR/repo' reset --hard origin/main --quiet"
    elif git -C "$NODE_DIR/repo" fetch origin main --quiet && git -C "$NODE_DIR/repo" reset --hard origin/main --quiet; then
      ok "repo present ($NODE_DIR/repo), synced to origin/main"
    else
      no "repo fetch/reset FAILED ($NODE_DIR/repo)"; return 1
    fi
  else
    if [ "$DRY" = 1 ]; then
      echo "  DRY: git clone --quiet '$REPO_URL' '$NODE_DIR/repo'  # authenticated via GH_TOKEN from $CREDS if present"
    else
      [ -z "$gh_token" ] && info HOME "no GH_TOKEN in $CREDS; attempting unauthenticated clone (public repos only)"
      if git clone --quiet "$clone_url" "$NODE_DIR/repo"; then
        ok "repo cloned: $NODE_DIR/repo"
      else
        no "repo clone FAILED: $NODE_DIR/repo"; return 1
      fi
    fi
  fi
  ok "node home: $NODE_DIR"
}

# ---------- 3. CREDS ----------
REQUIRED_CRED_KEYS="CLAUDE_CODE_OAUTH_TOKEN GH_TOKEN"
# INFRA-3657: DISCORD_TOKEN is optional (not every node needs to page) but is
# self-provisioned the same zero-touch way when supplied, so the walk-away
# pager path (scripts/discord.sh) actually has a token to read once the
# operator does wire one in — no separate manual step or editor.
OPTIONAL_CRED_KEYS="DISCORD_TOKEN CHUMP_TEAM_URL CHUMP_TEAM_API_KEY"

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

# Interactive acquire (INFRA-3688): prompt user for GitHub auth method and
# run claude setup-token to obtain CLAUDE_CODE_OAUTH_TOKEN. Writes
# ~/.chump/providers.env with CHUMP_AUTH_MODE=oauth and the acquired tokens.
# Never echoes secret values to stdout or logs. File created with mode 0600.
# Returns 0 on success, non-zero on failure.
acquire_creds() {
  [ -f "$CREDS" ] && { ok "creds already exist at $CREDS — skipping acquire"; return 0; }
  echo
  printf '\033[1m=== Interactive Credential Acquisition ===\033[0m\n'
  printf 'No pre-supplied creds found. Two ways to authenticate:\n'
  printf '  1) GitHub Device Flow (gh auth login) — recommended\n'
  printf '  2) Paste a GH_TOKEN directly\n'
  printf '\n'
  local choice=""
  while [ -z "$choice" ]; do
    printf 'Choose method [1/2]: '
    read -r choice
    case "$choice" in
      1|2) ;;
      *) choice="";;
    esac
  done

  local gh_token=""
  if [ "$choice" = 1 ]; then
    info ACQUIRE "running gh auth login --hostname github.com --git-protocol https --web"
    if command -v gh >/dev/null 2>&1; then
      gh auth login --hostname github.com --git-protocol https --web || {
        no "gh auth login failed"
        return 1
      }
      gh_token="$(gh auth token 2>/dev/null)" || {
        no "failed to retrieve GH_TOKEN from gh"
        return 1
      }
    else
      no "gh CLI not found — install GitHub CLI first, then re-run"
      return 1
    fi
  else
    printf 'Paste your GitHub personal access token (will not echo): '
    stty -echo 2>/dev/null
    read -r gh_token
    stty echo 2>/dev/null
    printf '\n'
    if [ -z "$gh_token" ]; then
      no "empty token — aborting"
      return 1
    fi
  fi

  info ACQUIRE "running claude setup-token to obtain CLAUDE_CODE_OAUTH_TOKEN..."
  local oauth_token=""
  if command -v claude >/dev/null 2>&1; then
    oauth_token="$(claude setup-token 2>/dev/null)" || {
      no "claude setup-token failed"
      return 1
    }
  else
    no "claude CLI not found — install Claude Code CLI first, then re-run"
    return 1
  fi

  if [ -z "$oauth_token" ]; then
    no "claude setup-token returned empty token"
    return 1
  fi

  # Write providers.env with mode 0600, never echoing values
  mkdir -p "$STATE_DIR"
  (
    umask 077
    cat > "$CREDS" <<EOF
CHUMP_AUTH_MODE=oauth
GH_TOKEN=$gh_token
CLAUDE_CODE_OAUTH_TOKEN=$oauth_token
EOF
  )
  chmod 600 "$CREDS" 2>/dev/null || true
  ok "creds written to $CREDS (mode 600; values not logged)"
  return 0
}

# ---------- 3b. CREDS CHECK ----------
check_creds() {
  materialize_creds
  [ -f "$CREDS" ] || { no "creds missing: $CREDS (supply --creds-file PATH or \$CHUMP_BOOTSTRAP_CREDS)"; return 1; }
  local missing=""
  for k in $REQUIRED_CRED_KEYS; do
    grep -qE "^(export )?$k=" "$CREDS" || missing="$missing $k"
  done
  [ -n "$missing" ] && { no "creds present but missing keys:$missing — supply via --creds-file/\$CHUMP_BOOTSTRAP_CREDS and re-run"; return 1; }
  ok "creds ok ($(grep -cE '^(export )?[A-Z_]+=' "$CREDS") keys, incl OAuth+GH, mode $(stat -c %a "$CREDS" 2>/dev/null || stat -f %Lp "$CREDS" 2>/dev/null))"
  local opt_missing=""
  for k in $OPTIONAL_CRED_KEYS; do
    grep -qE "^(export )?$k=" "$CREDS" || opt_missing="$opt_missing $k"
  done
  # INFRA-3657 AC2: DISCORD_TOKEN missing is a WARNING, not a failure — the
  # node is fully installed either way, but the walk-away pager is dead
  # until it's supplied. Surface loudly so that's not discovered at 3am.
  [ -n "$opt_missing" ] && info CREDS "optional creds not set:$opt_missing (pager dead without DISCORD_TOKEN — supply via --creds-file/\$CHUMP_BOOTSTRAP_CREDS)"
}

# ---------- 3c. NODE ENV (INFRA-3703: canonical store env file) ----------
# Writes ~/.chump/node.env with the canonical store settings every organ and
# later step needs, then sources it so subsequent phases (SEED/SUBSTRATE/
# ORGANS) all resolve the same values instead of re-deriving them. Values come
# from the environment first, then providers.env, then the canonical defaults
# already pinned above — and the API-key value is never echoed to stdout/logs
# (written straight to the file).
write_node_env() {
  local node_env="$STATE_DIR/node.env"
  local team_url="${CHUMP_TEAM_URL:-}"
  local team_api_key="${CHUMP_TEAM_API_KEY:-}"
  if [ -z "$team_url" ] && [ -f "$CREDS" ]; then
    team_url="$(grep -E '^(export )?CHUMP_TEAM_URL=' "$CREDS" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_TEAM_URL=//; s/^"(.*)"$/\1/')"
  fi
  if [ -z "$team_api_key" ] && [ -f "$CREDS" ]; then
    team_api_key="$(grep -E '^(export )?CHUMP_TEAM_API_KEY=' "$CREDS" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_TEAM_API_KEY=//; s/^"(.*)"$/\1/')"
  fi
  team_url="${team_url:-$GAP_STORE_URL}"
  local store_backend="${CHUMP_STORE_BACKEND:-postgrest}"
  mkdir -p "$STATE_DIR"
  ( umask 077
    {
      printf 'export CHUMP_STATE_DIR=%s\n' "$STATE_DIR"
      printf 'export CHUMP_TEAM_URL=%s\n' "$team_url"
      printf 'export CHUMP_TEAM_API_KEY=%s\n' "$team_api_key"
      printf 'export CHUMP_STORE_BACKEND=%s\n' "$store_backend"
    } > "$node_env"
  )
  # Source now so subsequent phases inherit the canonical settings.
  # shellcheck disable=SC1090
  . "$node_env"
  export CHUMP_STATE_DIR CHUMP_TEAM_URL CHUMP_TEAM_API_KEY CHUMP_STORE_BACKEND
  ok "node.env written + sourced: $node_env"
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

# ---------- 4b. SEED (INFRA-3633: first-boot canonical-store bootstrap) ----------
# One-shot YAML -> DB sync so a freshly-cloned box boots with the real
# backlog (docs/gaps/*.yaml) instead of an empty state.db. Reuses
# `chump gap sync --pull`, which already respects the INFRA-3606
# terminal-status guard (never reverts a done/superseded/etc row back to
# open), so this is safe to re-run on every install.
ensure_seed() {
  local gaps_dir="$NODE_DIR/repo/docs/gaps"
  local bin=""
  for c in "$BIN" "$HOME/chump/chump" "$(command -v chump 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { bin="$c"; break; }
  done
  if [ -z "$bin" ]; then
    info SEED "no chump binary yet — skipping (BINARY phase hasn't installed one); re-run after it does"
    return 0
  fi
  if [ ! -d "$gaps_dir" ]; then
    info SEED "no $gaps_dir — skipping (repo clone missing docs/gaps?)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    echo "  DRY: '$bin' gap sync --pull --state-db '$STATE_DB' --gaps-dir '$gaps_dir' --json"
    return 0
  fi
  local out
  if out="$("$bin" gap sync --pull --state-db "$STATE_DB" --gaps-dir "$gaps_dir" --json 2>&1)"; then
    ok "seed: canonical store synced from docs/gaps ($out)"
  else
    # AC2: substrate-unreachable (missing state.db dir, locked db, etc.) is a
    # clear warning, not a hard install failure — the node is still usable
    # without a seeded backlog (organs/CREDS/BINARY phases already ran).
    no "seed: gap sync --pull FAILED — substrate unreachable, continuing without seed"
    info SEED "$out"
  fi
}

# ---------- 5. ORGANS (from manifest) ----------
brain_organs() {  # name|exec
  echo "node-heartbeat|$ORGAN_DIR/node-heartbeat.sh"
}
muscle_organs() { echo "worker|$ORGAN_DIR/worker.sh"; }
# INFRA-3650 (PEER-HEAL-03): organs every role needs regardless of brain vs
# muscle — currently just the process-organ heal loop (revives raw
# background bash procs like almanac-vision-keeper that aren't systemd
# units, so it must land on every owned node, not be a hand-op per role).
common_organs() { echo "process-organ-heal|$ORGAN_DIR/process-organ-heal.sh"; }
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
  # INFRA-3650: the process-organ heal loop itself — a plain while-true
  # wrapper around the tracked scripts/ops/process-organ-heal.sh (one pass
  # per invocation, testable in isolation), same shape as node-heartbeat.sh
  # above so it installs identically across supervisors (systemd/runit/
  # fallback).
  run "cat > '$ORGAN_DIR/process-organ-heal.sh' <<'PH'
#!/usr/bin/env bash
STATE=\"\${CHUMP_STATE_DIR:-\$HOME/.chump}\"
REPO=\"\${CHUMP_NODE_REPO:-$NODE_DIR/repo}\"
while true; do
  CHUMP_REPO_ROOT=\"\$REPO\" \\
    bash \"\$REPO/scripts/ops/process-organ-heal.sh\" >> \"$LOG_DIR/process-organ-heal.log\" 2>&1 || true
  sleep \"\${CHUMP_PROCESS_ORGAN_HEAL_INTERVAL_S:-300}\"
done
PH"
  run "chmod +x '$ORGAN_DIR/process-organ-heal.sh'"
  local list; case "$ROLE" in brain) list="$(brain_organs; common_organs)";; muscle) list="$(muscle_organs; common_organs)";; all) list="$(brain_organs; muscle_organs; common_organs)";; esac
  echo "$list" | while IFS='|' read -r name exec; do
    [ -z "$name" ] && continue
    svc_install "$name" "$exec"; svc_up "$name"; ok "organ installed+up: $name"
  done
}

# ---------- 5b. SUBSTRATE (INFRA-3631, via INFRA-3657) ----------
# Calls the checked-in substrate provisioner so a bare-box install ends with
# a live, self-hosted Postgres+PostgREST gap store instead of the provisioner
# sitting on disk unwired (the exact "designed but never called" gap this
# ships closes). Non-fatal: a substrate failure must not block BINARY/ORGANS
# from having already installed a usable node — self_test surfaces it.
ensure_substrate() {
  local script="$NODE_DIR/repo/scripts/setup/install-gap-substrate.sh"
  [ -f "$script" ] || script="$(dirname "$0")/install-gap-substrate.sh"
  if [ ! -x "$script" ]; then
    info SUBSTRATE "install-gap-substrate.sh not found — skipping"
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "  DRY: bash '$script'"; return 0; fi
  info SUBSTRATE "provisioning gap store (postgres+postgrest)..."
  if bash "$script" >"$LOG_DIR/substrate-install-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1; then
    ok "substrate provisioned + self-tested (gap-store round-trip verified)"
  else
    no "substrate provisioning FAILED — see $LOG_DIR/substrate-install-*.log; node still usable, re-run to retry"
  fi
}

# ---------- 5c. EYES (almanac liveness/refresh organ, INFRA-3657) ----------
# Brings up the almanac fusion-search "eyes" so a fresh node isn't blind —
# closes the "ZERO almanac/eyes phase" gap in this ship's description.
ensure_eyes() {
  local script="$NODE_DIR/repo/scripts/setup/install-almanac-organ.sh"
  [ -f "$script" ] || script="$(dirname "$0")/install-almanac-organ.sh"
  if [ ! -x "$script" ]; then
    info EYES "install-almanac-organ.sh not found — skipping"
    return 0
  fi
  if [ "$DRY" = 1 ]; then echo "  DRY: bash '$script'"; return 0; fi
  info EYES "installing almanac liveness/refresh organ..."
  if bash "$script" >"$LOG_DIR/eyes-install-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1; then
    ok "eyes organ installed + supervised"
  else
    no "eyes organ install had issues — see $LOG_DIR/eyes-install-*.log; node still usable, re-run to retry"
  fi
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
  if [ -d "$NODE_DIR/repo/.git" ]; then
    local head_sha origin_sha
    head_sha="$(git -C "$NODE_DIR/repo" rev-parse HEAD 2>/dev/null)"
    origin_sha="$(git -C "$NODE_DIR/repo" rev-parse origin/main 2>/dev/null)"
    if [ -n "$head_sha" ] && [ "$head_sha" = "$origin_sha" ]; then ok "repo HEAD at origin/main ($head_sha)"
    else no "repo HEAD not at origin/main (HEAD=$head_sha origin/main=$origin_sha)"; fail=1; fi
  else no "repo missing: $NODE_DIR/repo/.git"; fail=1; fi
  if [ -x "$BIN" ]; then ok "binary linked: $BIN"; else no "binary"; fail=1; fi
  # INFRA-3633: post-seed sanity — canonical store should have picked up the
  # real backlog from docs/gaps/*.yaml, not sit empty. Compare PICKABLE
  # (non-terminal) counts on both sides: sync_pull's insert path (a brand
  # new DB row has nothing to guard) faithfully copies every YAML's status,
  # terminal or not, so a fresh box's total row count equals yaml_total —
  # but the number of rows a picker would ever see (status not in the
  # terminal set — see is_terminal_status in chump-gap-store::sync) is the
  # meaningful "did the real backlog show up" signal.
  local terminal_status_re='^\s*status:\s*"?(done|superseded|wontfix|wont_fix|closed|closed_not_a_bug|already_satisfied|obsolete|duplicate)"?\s*$'
  if command -v sqlite3 >/dev/null 2>&1 && [ -f "$STATE_DB" ] && [ -d "$NODE_DIR/repo/docs/gaps" ]; then
    local db_total db_pickable yaml_total yaml_terminal yaml_pickable
    db_total="$(sqlite3 "$STATE_DB" 'SELECT COUNT(*) FROM gaps;' 2>/dev/null || echo 0)"
    db_pickable="$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps WHERE status NOT IN ('done','superseded','wontfix','wont_fix','closed','closed_not_a_bug','already_satisfied','obsolete','duplicate');" 2>/dev/null || echo 0)"
    yaml_total="$(find "$NODE_DIR/repo/docs/gaps" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
    yaml_terminal="$(grep -lE "$terminal_status_re" "$NODE_DIR/repo/docs/gaps"/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
    yaml_pickable=$(( yaml_total - yaml_terminal ))
    if [ "$db_total" -gt 0 ] 2>/dev/null; then
      if [ "$db_pickable" -eq "$yaml_pickable" ] 2>/dev/null; then
        ok "seed: canonical store has $db_total gaps, $db_pickable pickable (matches docs/gaps: $yaml_pickable non-terminal of $yaml_total)"
      else
        ok "seed: canonical store has $db_total gaps, $db_pickable pickable (docs/gaps: $yaml_pickable non-terminal of $yaml_total — drift expected if state.db has rows not sourced from this box's YAML)"
      fi
    else
      no "seed: canonical store empty (0 gaps) — SEED phase may have failed; re-run chump-node-install.sh"
      fail=1
    fi
  fi
  # each role organ supervised & up (INFRA-3650: common_organs, e.g.
  # process-organ-heal, must be part of the "installed" bar for every role)
  local list; case "$ROLE" in brain) list="$(brain_organs; common_organs)";; muscle) list="$(muscle_organs; common_organs)";; all) list="$(brain_organs; muscle_organs; common_organs)";; esac
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
  # INFRA-3657 AC3: SUBSTRATE + EYES are part of the FACTORY INSTALLED bar,
  # not optional add-ons — a node without a gap store or almanac eyes is not
  # "factory installed" per this gap's AC. Best-effort: --check reports the
  # phase's own verdict rather than re-implementing its self-test.
  local substrate_script="$NODE_DIR/repo/scripts/setup/install-gap-substrate.sh"
  [ -f "$substrate_script" ] || substrate_script="$(dirname "$0")/install-gap-substrate.sh"
  if [ -x "$substrate_script" ]; then
    if command -v pgrep >/dev/null 2>&1 && pgrep -f postgrest >/dev/null 2>&1; then
      ok "substrate: postgrest running"
    else no "substrate: postgrest not running (re-run: bash $substrate_script)"; fail=1; fi
  fi
  local eyes_script="$NODE_DIR/repo/scripts/setup/install-almanac-organ.sh"
  [ -f "$eyes_script" ] || eyes_script="$(dirname "$0")/install-almanac-organ.sh"
  if [ -x "$eyes_script" ]; then
    if bash "$eyes_script" --check >/dev/null 2>&1; then ok "eyes: almanac organ supervised"
    else no "eyes: almanac organ incomplete (re-run: bash $eyes_script)"; fail=1; fi
  fi
  echo
  if [ "$fail" = 0 ]; then printf '\033[42m INSTALLED ✓ \033[0m role=%s host=%s\n' "$ROLE" "$HOST_KIND"; return 0
  else printf '\033[41m NOT FULLY INSTALLED \033[0m — fix the ✗ above\n'; return 1; fi
}

# ---------- run ----------
printf '\033[1m=== chump-node-install: role=%s home=%s ===\033[0m\n' "$ROLE" "$NODE_DIR"
info GAP-STORE "canonical shared gap store pinned: CHUMP_GAP_STORE_URL=$CHUMP_GAP_STORE_URL"
detect_host
if [ "$SELF_TEST_ONLY" = 1 ]; then self_test; exit $?; fi
toolchain_preflight
ensure_home || { no "HOME phase failed (repo clone/fetch) — fix and re-run"; exit 1; }
check_creds || info CREDS "fix creds before organs will authenticate"
write_node_env
ensure_binary || info BINARY "install a binary, then re-run"
ensure_seed
install_organs
ensure_substrate
ensure_eyes
install_supervise
# RESILIENT-318: install the self-management suite (orchestrator + reapers + disk-monitor)
[ "$SELF_TEST_ONLY" = 1 ] || bash "$(dirname "$0")/install-node-housekeeping.sh" || info ORGANS "housekeeping install skipped"
echo
self_test
