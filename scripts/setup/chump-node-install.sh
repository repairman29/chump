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
# INFRA-3633: pin the canonical gap store here, once, so every phase below
# (and every organ this script launches) resolves the same state.db instead
# of some falling back to a repo-local $NODE_DIR/repo/.chump/state.db that
# would silently diverge from the machine's real gap backlog.
STATE_DB="${CHUMP_STATE_DB:-$STATE_DIR/state.db}"
export CHUMP_STATE_DB="$STATE_DB"
CREDS="$STATE_DIR/providers.env"
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
  [ -z "$found" ] && { no "no chump binary found (build via deploy-pixel-node.sh / cargo)"; return 1; }
  [ "$found" != "$BIN" ] && run "ln -sf '$found' '$BIN'"
  ok "binary: $found -> $BIN"
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

# ---------- 5. ORGANS (from manifest, INFRA-3641) ----------
NODE_ORGAN_MANIFEST="${CHUMP_NODE_ORGAN_MANIFEST:-$(cd "$(dirname "$0")" && pwd)/node-organ-manifest.txt}"

# Mirrors scripts/ops/organ-reconcile.sh's organ_is_applicable: same bin:/
# env:/dep: requires= spec kinds and skip-don't-fail semantics, adapted to
# this script's generic svc_status() supervisor abstraction (organ-reconcile.sh's
# dep: check is systemd-only via systemctl; there is no systemd-only assumption
# here since this script also targets runit/launchd/nohup hosts).
organ_is_applicable() {
  local name="$1" requires="$2" reason_var="$3"
  [ -z "$requires" ] && return 0
  local tok
  local IFS=','
  for tok in $requires; do
    case "$tok" in
      bin:*)
        local b="${tok#bin:}"
        if [ "$b" = chump ] && [ -x "$BIN" ]; then continue; fi
        command -v "$b" >/dev/null 2>&1 && continue
        printf -v "$reason_var" 'missing_bin:%s' "$b"; return 1
        ;;
      env:*)
        local v="${tok#env:}"
        eval "[ -n \"\${$v:-}\" ]" && continue
        printf -v "$reason_var" 'missing_env:%s' "$v"; return 1
        ;;
      dep:*)
        local d="${tok#dep:}"
        [ "$(svc_status "$d")" = up ] && continue
        printf -v "$reason_var" 'missing_dep:%s' "$d"; return 1
        ;;
      *)
        printf -v "$reason_var" 'unknown_requires_spec:%s' "$tok"; return 1
        ;;
    esac
  done
  return 0
}

# Manifest-derived set of organs applicable to THIS host for role $1
# (brain|muscle|all). Prints "name|exec-path" lines — the single source
# install_organs() and self_test() both read (AC3: no hardcoded organ lists).
# Skip reasons go to stderr so `list="$(applicable_organs ...)"` stays clean.
applicable_organs() {
  local want_role="$1"
  [ -f "$NODE_ORGAN_MANIFEST" ] || return 0
  local state name rest
  while read -r state name rest; do
    [ -z "${state:-}" ] && continue
    case "$state" in \#*) continue;; esac
    [ "$state" != enabled ] && continue
    local role="" requires="" ex="" tok
    for tok in $rest; do
      case "$tok" in
        role=*) role="${tok#role=}";;
        requires=*) requires="${tok#requires=}";;
        exec=*) ex="${tok#exec=}";;
      esac
    done
    role="${role:-brain}"
    [ -z "$ex" ] && ex="$name.sh"
    [ "$want_role" != all ] && [ "$role" != "$want_role" ] && continue
    local reason=""
    if ! organ_is_applicable "$name" "$requires" reason; then
      info ORGANS "skip $name (not applicable: $reason)" >&2
      continue
    fi
    echo "$name|$ORGAN_DIR/$ex"
  done < "$NODE_ORGAN_MANIFEST"
}

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

  # write the worker organ (muscle's fleet-work loop; INFRA-3641 — ported
  # from scripts/setup/pixel-worker.sh's loop, generalized off Termux +
  # $HOME/chump onto this node's own $NODE_DIR layout so a muscle install no
  # longer has a dangling worker.sh referenced-but-never-written). The script
  # self-computes NODE_DIR from its own location, so it stays correct even if
  # $NODE_DIR moves.
  if [ "$DRY" = 1 ]; then
    echo "  DRY: write $ORGAN_DIR/worker.sh (COTG muscle loop, ported from pixel-worker.sh)"
  else
    cat > "$ORGAN_DIR/worker.sh" <<'WK'
#!/usr/bin/env bash
# worker.sh — COTG muscle organ: fleet worker loop (INFRA-3641; ported from
# scripts/setup/pixel-worker.sh, generalized onto this node's own layout).
set -uo pipefail

NODE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHUMP_STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
export CHUMP_STATE_DIR
export CHUMP_STATE_DB="${CHUMP_STATE_DB:-$CHUMP_STATE_DIR/state.db}"
BIN="$NODE_DIR/bin/chump"
REPO="$NODE_DIR/repo"
cd "$REPO" || { echo "[worker] no repo at $REPO" >&2; exit 1; }

CREDS_FILE="$CHUMP_STATE_DIR/providers.env"
[ -f "$CREDS_FILE" ] && { set -a; . "$CREDS_FILE"; set +a; }

export WORKER_SKILLS="${WORKER_SKILLS:-docs,shell,scripts,md}"
export WORKER_MACHINE="${WORKER_MACHINE:-$(hostname 2>/dev/null || echo node)}"
export CHUMP_WORK_BACKEND="${CHUMP_WORK_BACKEND:-chump-local}"
export FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P1,P2}"

IDLE_S="${NODE_WORKER_IDLE_S:-60}"
COOLDOWN_S="${NODE_WORKER_COOLDOWN_S:-3600}"
REFRESH_S="${NODE_WORKER_REFRESH_S:-1800}"
FAILED_FILE="$CHUMP_STATE_DIR/worker-failed.tsv"
LAST_REFRESH=0

[ -x "$BIN" ] || { echo "[worker] chump binary not found at $BIN" >&2; exit 1; }

echo "[worker] up: skills=$WORKER_SKILLS machine=$WORKER_MACHINE backend=$CHUMP_WORK_BACKEND bin=$BIN cooldown=${COOLDOWN_S}s"

while true; do
  echo "[worker] $(date -u +%FT%TZ) tick"
  NOW=$(date +%s)

  # Periodic state refresh (mirrors pixel-worker.sh): the node's local
  # registry drifts from origin/main. Reconcile every REFRESH_S by pulling
  # fresh docs/gaps and syncing state.db from the per-file mirror.
  if [ $(( NOW - LAST_REFRESH )) -ge "$REFRESH_S" ]; then
    echo "[worker] refreshing state from origin/main..."
    git -C "$REPO" fetch origin main --depth 1 >/dev/null 2>&1 \
      && git -C "$REPO" reset --hard origin/main >/dev/null 2>&1
    "$BIN" gap sync --pull >/dev/null 2>&1 || true
    LAST_REFRESH="$NOW"
    echo "[worker] state refreshed"
  fi

  # Prune expired cooldown entries (gap_id<TAB>epoch, keep only still-cooling).
  if [ -f "$FAILED_FILE" ]; then
    awk -v now="$NOW" -v cd="$COOLDOWN_S" 'now - $2 < cd {print}' "$FAILED_FILE" > "$FAILED_FILE.tmp" 2>/dev/null
    mv "$FAILED_FILE.tmp" "$FAILED_FILE" 2>/dev/null || rm -f "$FAILED_FILE"
  fi

  GAP="$("$BIN" gap list --status open --json 2>/dev/null | COOLDOWN_FILE="$FAILED_FILE" python3 -c '
import sys, json, os
skills = {s.strip() for s in os.environ.get("WORKER_SKILLS", "").split(",") if s.strip()}
prio = set(os.environ.get("FLEET_PRIORITY_FILTER", "P1,P2").split(","))
cool = set()
cf = os.environ.get("COOLDOWN_FILE", "")
if cf and os.path.exists(cf):
    for line in open(cf):
        p = line.strip().split("\t")
        if p:
            cool.add(p[0])
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for g in rows:
    gid = g.get("id", "")
    if gid in cool:
        continue
    req = {s.strip() for s in (g.get("skills_required") or "").split(",") if s.strip()}
    if any(r.startswith("external_repo:") for r in req):
        continue
    if "workspace_scope" in req:
        continue
    if "rust" in req:
        continue
    if req and not (req & skills):
        continue
    if g.get("effort") not in ("xs", "s"):
        continue
    if prio and g.get("priority") not in prio:
        continue
    print(gid)
    break
')"

  if [ -z "$GAP" ]; then
    NCOOL=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    echo "[worker] no pickable gap (${NCOOL} in cooldown); sleep ${IDLE_S}s"
    sleep "$IDLE_S"
    continue
  fi

  echo "[worker] executing gap=$GAP"
  "$BIN" --execute-gap "$GAP" 2>&1 | tail -40
  rc=${PIPESTATUS[0]}

  if [ "$rc" -eq 0 ]; then
    echo "[worker] gap=$GAP shipped (rc=0)"
    if [ -f "$FAILED_FILE" ]; then
      grep -v "^${GAP}	" "$FAILED_FILE" > "$FAILED_FILE.tmp" 2>/dev/null && mv "$FAILED_FILE.tmp" "$FAILED_FILE" 2>/dev/null || true
    fi
  else
    echo "[worker] gap=$GAP failed rc=$rc; cooldown ${COOLDOWN_S}s"
    printf "%s\t%s\n" "$GAP" "$(date +%s)" >> "$FAILED_FILE"
  fi
  sleep "$IDLE_S"
done
WK
    chmod +x "$ORGAN_DIR/worker.sh"
  fi

  local list; list="$(applicable_organs "$ROLE")"
  if [ "$DRY" = 1 ]; then
    echo "  DRY: would supervise:"
    echo "$list" | while IFS='|' read -r name _; do [ -z "$name" ] && continue; echo "    - $name"; done
  fi
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
  # each applicable organ (manifest-derived, INFRA-3641) supervised & up
  local list; list="$(applicable_organs "$ROLE")"
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
ensure_home || { no "HOME phase failed (repo clone/fetch) — fix and re-run"; exit 1; }
check_creds || info CREDS "fix creds before organs will authenticate"
ensure_binary || info BINARY "install a binary, then re-run"
ensure_seed
install_organs
install_supervise
# RESILIENT-318: install the self-management suite (orchestrator + reapers + disk-monitor)
[ "$SELF_TEST_ONLY" = 1 ] || bash "$(dirname "$0")/install-node-housekeeping.sh" || info ORGANS "housekeeping install skipped"
echo
self_test
