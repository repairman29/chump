#!/usr/bin/env bash
# install-gap-substrate.sh — INFRA-3631 (install-a-Trek-from-0 epic, MISSION-010).
#
# Codifies the S0 substrate: self-hosted Postgres + PostgREST as the fleet's
# shared, cross-machine gap store. Mines the hand-cranked artifacts that were
# live on CJ (/etc/systemd/system/chump-postgrest.service,
# ~/.chump/postgrest.conf) into one idempotent script.
#
# Schema: applies the CHECKED-IN supabase/migrations/0001_team_foundation.sql
# + 0002_shared_gaps.sql verbatim — 0001_team_foundation.sql's own header
# documents "Self-hosted (future) — supabase start locally on the team's
# hardware; same migration applies" as a first-class deployment model, and
# that's exactly what's already live on CJ (verified against the running
# chump_fleet database: same shared_gaps/shared_claims/worker_capabilities
# shape, same fleet-default sentinel team, RLS disabled). Self-hosted has no
# Supabase Auth issuing JWTs, so this script additionally disables RLS on the
# gap-store-facing tables (auth.uid()-gated policies would deny every anon
# request) and seeds a single sentinel "fleet-default" team row so the
# team_id NOT NULL column has something single-tenant callers can reference.
#
# Phases: POSTGRES -> DB+ROLES -> SCHEMA -> POSTGREST -> SERVICE -> SELF-TEST
# Idempotent: safe to re-run on an already-provisioned box (every step checks
# existing state first). Linux (systemd, apt) is the primary target; macOS
# (launchd, brew) is supported via the same supervisor-abstraction pattern as
# scripts/setup/chump-node-install.sh's svc_install().
#
# Usage:
#   bash scripts/setup/install-gap-substrate.sh
#   bash scripts/setup/install-gap-substrate.sh --dry-run
#   CHUMP_SUBSTRATE_DB_NAME=chump_fleet CHUMP_SUBSTRATE_PORT=3000 bash ...
#
# Re-run safety: every write step reads existing state first (existing
# postgrest.conf port, existing binary location, existing systemd ExecStart)
# and only fills in what's missing — it never overwrites a working config
# with fresh defaults. This matters because provisioning may already exist
# by hand (the exact CJ artifacts this script was written to codify).
set -uo pipefail

log() { printf '[install-gap-substrate] %s\n' "$*"; }
die() { printf '[install-gap-substrate] ERROR: %s\n' "$*" >&2; exit 1; }
_sudo() { if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $a";;
  esac
done
run() { [ "$DRY" = 1 ] && { echo "  DRY: $*"; return 0; }; eval "$*"; }

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
CREDS="$STATE_DIR/providers.env"
DB_NAME="${CHUMP_SUBSTRATE_DB_NAME:-chump_fleet}"
DB_PORT="${CHUMP_SUBSTRATE_DB_PORT:-5432}"
DB_HOST="${CHUMP_SUBSTRATE_DB_HOST:-localhost}"
PG_AUTHENTICATOR="chump_authenticator"
PG_ANON="chump_anon"
FLEET_TEAM_ID="00000000-0000-0000-0000-000000000000"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATIONS=(
  "$REPO_ROOT/supabase/migrations/0001_team_foundation.sql"
  "$REPO_ROOT/supabase/migrations/0002_shared_gaps.sql"
)
NODE_DIR="${CHUMP_NODE_DIR:-$HOME/.chumpnode}"
POSTGREST_CONF="$STATE_DIR/postgrest.conf"

# If a postgrest.conf already exists (hand-provisioned or a prior run), its
# server-port is the port already wired into the running service — reuse it
# rather than silently re-pointing a live service at a new port. Otherwise
# fall back to the CJ hand-cranked default of 3000.
if [[ -f "$POSTGREST_CONF" ]]; then
  REST_PORT="${CHUMP_SUBSTRATE_PORT:-$(grep -E '^server-port' "$POSTGREST_CONF" | head -1 | grep -oE '[0-9]+')}"
fi
REST_PORT="${REST_PORT:-${CHUMP_SUBSTRATE_PORT:-3000}}"

# ---------- canonical gap-store URL (INFRA-3634) ----------
# Single var this script (provision side) and chump-node-install.sh's
# env-pin (connect side, INFRA-3633's pin block) both read, so provisioner
# and client can never drift on which host is the canonical shared gap
# store. Canonical home resolved 2026-08-22: CJ (100.90.52.126) — where S0
# was actually hand-cranked and this script's SERVICE phase installs to —
# not the Pixel address docs/strategy/DATA_HOME_PLAN.md's Phase-0 plan
# named; see that doc's dated note. CHUMP_GAP_STORE_TAILNET_HOST lets a
# re-run on a different box (e.g. the eventual Pixel migration, INFRA-2092)
# override without editing this script.
GAP_STORE_TAILNET_HOST="${CHUMP_GAP_STORE_TAILNET_HOST:-100.90.52.126}"
CHUMP_GAP_STORE_URL="${CHUMP_GAP_STORE_URL:-http://${GAP_STORE_TAILNET_HOST}:${REST_PORT}}"

mkdir -p "$STATE_DIR" "$NODE_DIR/bin"

# ---------- host detection + supervisor abstraction (mirrors chump-node-install.sh svc_install) ----------
OS="$(uname -s)"
if [[ "$OS" == "Darwin" ]]; then
  SUPERVISOR="launchd"
elif [[ "$OS" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; then
  SUPERVISOR="systemd"
else
  SUPERVISOR="none"
fi
log "host=$OS supervisor=$SUPERVISOR db=$DB_NAME rest_port=$REST_PORT"

svc_install() {  # <name> <exec-command>
  # Idempotent by construction: never overwrite a unit/plist that's already
  # there (it may be hand-provisioned and actively serving a running
  # process — clobbering it mid-flight breaks the live service on next
  # restart without visibly failing anything *right now*). Re-run is a no-op.
  local name="$1" cmd="$2"
  case "$SUPERVISOR" in
    systemd)
      if [[ -f "/etc/systemd/system/chump-$name.service" ]]; then
        log "systemd unit chump-$name.service already exists — leaving as-is (no-op)"
        return 0
      fi
      run "_sudo bash -c 'cat > /etc/systemd/system/chump-$name.service' <<EOF
[Unit]
Description=Chump self-hosted gap-store REST layer (PostgREST -> $DB_NAME)
After=network-online.target postgresql.service
[Service]
ExecStart=$cmd
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF"
      run "_sudo systemctl daemon-reload"
      ;;
    launchd)
      local plist="$HOME/Library/LaunchAgents/com.chump.$name.plist"
      if [[ -f "$plist" ]]; then
        log "launchd plist com.chump.$name already exists — leaving as-is (no-op)"
        return 0
      fi
      run "cat > '$plist' <<EOF
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\"><dict>
  <key>Label</key><string>com.chump.$name</string>
  <key>ProgramArguments</key><array>$(printf '<string>%s</string>' $cmd)</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF"
      ;;
    *) log "no supported supervisor on this host — run manually: $cmd";;
  esac
}
svc_up() {
  local name="$1"
  case "$SUPERVISOR" in
    systemd) run "_sudo systemctl enable --now 'chump-$name' 2>/dev/null || true";;
    launchd) run "launchctl load -w '$HOME/Library/LaunchAgents/com.chump.$name.plist' 2>/dev/null || true";;
    *) :;;
  esac
}
svc_status() {  # prints "up" or "down"
  local name="$1"
  case "$SUPERVISOR" in
    systemd) systemctl is-active "chump-$name" 2>/dev/null | grep -q '^active' && echo up || echo down;;
    launchd) launchctl list 2>/dev/null | grep -q "com.chump.$name" && echo up || echo down;;
    *) command -v "$name" >/dev/null 2>&1 && echo up || echo down;;
  esac
}

# ---------- 1. POSTGRES ----------
ensure_postgres() {
  if command -v psql >/dev/null 2>&1 && (pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1 || true); then
    :  # keep going; pg_isready non-zero just means "not up yet", handled below
  fi
  if ! command -v psql >/dev/null 2>&1; then
    log "postgres client not found — installing"
    if [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
      run "brew install postgresql@16"
      run "brew services start postgresql@16"
    elif [[ "$OS" == "Linux" ]] && command -v apt-get >/dev/null 2>&1; then
      run "_sudo apt-get update -qq && _sudo apt-get install -y -qq postgresql postgresql-contrib"
      run "_sudo systemctl enable --now postgresql"
    else
      die "no supported package manager found — install Postgres manually, then re-run"
    fi
  fi
  if [[ "$DRY" != 1 ]]; then
    for i in $(seq 1 10); do
      pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1 && break
      sleep 1
    done
    pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1 || die "postgres not accepting connections on $DB_HOST:$DB_PORT"
  fi
  log "postgres reachable at $DB_HOST:$DB_PORT"
}

# psql as the postgres superuser, portable across Linux (peer auth via `sudo -u postgres`) and
# macOS (brew installs run as the invoking user, no `postgres` OS account exists).
psql_admin() {
  if [[ "$OS" == "Linux" ]] && id postgres >/dev/null 2>&1; then
    _sudo -u postgres psql -v ON_ERROR_STOP=1 -qtA "$@"
  else
    psql -v ON_ERROR_STOP=1 -qtA -h "$DB_HOST" -p "$DB_PORT" -U "$(whoami)" "$@"
  fi
}

# ---------- 2. DB + ROLES (password from providers.env, generated once, never hardcoded) ----------
ensure_db_and_roles() {
  touch "$CREDS"; chmod 600 "$CREDS"
  local pw
  pw="$(grep -E '^CHUMP_SUBSTRATE_DB_PASSWORD=' "$CREDS" 2>/dev/null | tail -1 | cut -d= -f2-)"
  if [[ -z "$pw" ]]; then
    pw="$(openssl rand -hex 24)"
    run "printf 'CHUMP_SUBSTRATE_DB_PASSWORD=%s\n' '$pw' >> '$CREDS'"
    chmod 600 "$CREDS"
    log "generated + persisted CHUMP_SUBSTRATE_DB_PASSWORD (not printed)"
  else
    log "reusing existing CHUMP_SUBSTRATE_DB_PASSWORD from $CREDS"
  fi
  SUBSTRATE_PW="$pw"

  if [[ "$DRY" == 1 ]]; then
    log "DRY: would ensure db=$DB_NAME + roles chump_anon/chump_authenticator"
    return 0
  fi

  local exists
  exists="$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
  if [[ -z "$exists" ]]; then
    log "creating database $DB_NAME"
    psql_admin -c "CREATE DATABASE $DB_NAME"
  else
    log "database $DB_NAME already exists (no-op)"
  fi

  # Roles: chump_anon is a NOLOGIN grant-target (PostgREST's anon-role pattern);
  # chump_authenticator is the login role in postgrest.conf's db-uri. Escaping the
  # password: openssl-hex output is alnum-only, safe to interpolate into SQL literal.
  psql_admin -d "$DB_NAME" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_ANON') THEN
    CREATE ROLE $PG_ANON NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_AUTHENTICATOR') THEN
    CREATE ROLE $PG_AUTHENTICATOR NOINHERIT LOGIN PASSWORD '$SUBSTRATE_PW';
  ELSE
    ALTER ROLE $PG_AUTHENTICATOR PASSWORD '$SUBSTRATE_PW';
  END IF;
END
\$\$;
GRANT $PG_ANON TO $PG_AUTHENTICATOR;
SQL
  log "roles ensured: $PG_ANON (nologin), $PG_AUTHENTICATOR (login)"
}

# ---------- 3. SCHEMA (checked-in migrations, idempotent, applied via init_schema — INFRA-4775) ----------
# Builds (once) and invokes the chump-gap-store binary's `init-schema`
# subcommand, which wraps `apply_shared_gap_store_migrations` (Rust,
# crates/chump-gap-store/src/backend/postgres.rs) — the same checked-in
# supabase/migrations/0001+0002 files, applied idempotently, but through
# one Rust entrypoint instead of this script piping SQL through psql by
# hand. Falls back to the old psql-pipe path if cargo/build is unavailable
# (e.g. a stripped-down provisioning box with no Rust toolchain).
ensure_gap_store_binary() {
  for f in "${MIGRATIONS[@]}"; do
    [[ -f "$f" ]] || die "migration file missing: $f"
  done
  if [[ "$DRY" == 1 ]]; then
    log "DRY: would build chump-gap-store (postgres-backend feature)"
    return 0
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    log "cargo not found — falling back to direct psql migration apply"
    GAP_STORE_BIN=""
    return 0
  fi
  log "building chump-gap-store (postgres-backend feature) — first run may take a minute"
  if (cd "$REPO_ROOT" && cargo build --release --quiet -p chump-gap-store --features postgres-backend --bin chump-gap-store); then
    GAP_STORE_BIN="$REPO_ROOT/target/release/chump-gap-store"
  else
    log "chump-gap-store build failed — falling back to direct psql migration apply"
    GAP_STORE_BIN=""
  fi
}

apply_schema() {
  ensure_gap_store_binary
  if [[ "$DRY" == 1 ]]; then
    log "DRY: would apply ${MIGRATIONS[*]} to $DB_NAME"
    return 0
  fi

  if [[ -n "${GAP_STORE_BIN:-}" ]]; then
    # CREATE TABLE needs admin/owner privileges the anon-facing
    # chump_authenticator role doesn't have (Postgres 15+ revoked the
    # default PUBLIC CREATE grant on schema public) — connect as the same
    # admin identity psql_admin() uses: local peer auth via the `postgres`
    # OS user on Linux, or the invoking user on macOS/brew installs.
    local db_url out
    if [[ "$OS" == "Linux" ]] && id postgres >/dev/null 2>&1; then
      db_url="host=/var/run/postgresql user=postgres dbname=$DB_NAME"
      out="$(_sudo -u postgres "$GAP_STORE_BIN" init-schema --db-url "$db_url" --migrations-dir "$REPO_ROOT/supabase/migrations" 2>&1)" \
        || die "chump-gap-store init-schema failed: $out"
    else
      db_url="host=$DB_HOST port=$DB_PORT user=$(whoami) dbname=$DB_NAME"
      out="$("$GAP_STORE_BIN" init-schema --db-url "$db_url" --migrations-dir "$REPO_ROOT/supabase/migrations" 2>&1)" \
        || die "chump-gap-store init-schema failed: $out"
    fi
    log "chump-gap-store init-schema: $out"
  else
    # Coarse idempotency: the migration files themselves aren't safe to
    # re-run (CREATE POLICY has no IF NOT EXISTS in Postgres), so gate the
    # whole apply on whether the schema is already there.
    local have_schema
    have_schema="$(psql_admin -d "$DB_NAME" -c "SELECT to_regclass('public.shared_gaps')")"
    if [[ -n "$have_schema" && "$have_schema" != "" ]]; then
      log "schema already present (shared_gaps exists) — skipping migration apply (no-op)"
    else
      for f in "${MIGRATIONS[@]}"; do
        log "applying $(basename "$f")"
        # Pipe via stdin rather than `-f <path>`: when psql_admin runs as
        # `sudo -u postgres`, the postgres OS user has no read access into an
        # arbitrary caller's worktree/home directory, so `-f` fails with
        # "Permission denied" even though the invoking user can read the file.
        psql_admin -d "$DB_NAME" < "$f"
      done
      log "schema applied (teams, shared_gaps, shared_claims, worker_capabilities, ...)"
    fi
  fi

  # Self-hosted has no Supabase Auth issuing JWTs — auth.uid()-gated RLS
  # policies on these tables would deny every anon request, so disable RLS
  # on the gap-store-facing tables (idempotent: ALTER ... DISABLE is a no-op
  # if already disabled). team_members/team_api_keys are untouched — they're
  # not part of the gap-store PostgREST surface.
  psql_admin -d "$DB_NAME" -c "
    ALTER TABLE teams DISABLE ROW LEVEL SECURITY;
    ALTER TABLE shared_gaps DISABLE ROW LEVEL SECURITY;
    ALTER TABLE shared_claims DISABLE ROW LEVEL SECURITY;
    ALTER TABLE worker_capabilities DISABLE ROW LEVEL SECURITY;
  " >/dev/null
  log "RLS disabled on gap-store tables (self-hosted, no Supabase Auth)"

  # Single-tenant sentinel team: every self-hosted row hangs off this one
  # fixed team_id instead of standing up real multi-tenant membership.
  psql_admin -d "$DB_NAME" -c "
    INSERT INTO teams (id, name, slug) VALUES ('$FLEET_TEAM_ID', 'fleet-default', 'fleet-default')
    ON CONFLICT (id) DO NOTHING;
  " >/dev/null
  log "sentinel team ensured: fleet-default ($FLEET_TEAM_ID)"

  # PostgREST's anon role needs direct table privileges — GRANT is naturally
  # idempotent (re-granting an already-held privilege is a no-op, not an error).
  psql_admin -d "$DB_NAME" -c "
    GRANT USAGE ON SCHEMA public TO $PG_ANON;
    GRANT SELECT ON teams TO $PG_ANON;
    GRANT SELECT, INSERT, UPDATE, DELETE ON shared_gaps, shared_claims, worker_capabilities TO $PG_ANON;
  " >/dev/null
  log "grants ensured for $PG_ANON on gap-store tables"
}

# ---------- 4. POSTGREST (binary + config) ----------
ensure_postgrest_binary() {
  POSTGREST_BIN="$NODE_DIR/bin/postgrest"
  local candidate
  for candidate in "$(command -v postgrest 2>/dev/null)" "$HOME/.local/bin/postgrest" "$POSTGREST_BIN"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      POSTGREST_BIN="$candidate"
      log "postgrest binary already installed: $POSTGREST_BIN"
      return 0
    fi
  done
  log "installing postgrest binary"
  local arch os_tag
  arch="$(uname -m)"
  if [[ "$OS" == "Darwin" ]]; then
    os_tag="macos"
  else
    os_tag="linux-static-x64"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && os_tag="linux-static-arm64"
  fi
  local ver="v12.2.8"
  local url="https://github.com/PostgREST/postgrest/releases/download/${ver}/postgrest-${ver}-${os_tag}.tar.xz"
  if [[ "$DRY" == 1 ]]; then
    log "DRY: would download $url -> $POSTGREST_BIN"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  curl -sL "$url" -o "$tmp/postgrest.tar.xz" || die "failed to download postgrest from $url"
  tar xf "$tmp/postgrest.tar.xz" -C "$tmp"
  install -m 0755 "$tmp/postgrest" "$POSTGREST_BIN"
  rm -rf "$tmp"
  log "postgrest installed: $POSTGREST_BIN"
}

write_postgrest_conf() {
  if [[ -f "$POSTGREST_CONF" ]]; then
    log "postgrest.conf already exists — leaving as-is (no-op): $POSTGREST_CONF"
    return 0
  fi
  local uri="postgres://${PG_AUTHENTICATOR}:${SUBSTRATE_PW:-REDACTED}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  run "cat > '$POSTGREST_CONF' <<CONF
db-uri = \"$uri\"
db-schema = \"public\"
db-anon-role = \"$PG_ANON\"
server-host = \"127.0.0.1\"
server-port = $REST_PORT
CONF"
  run "chmod 600 '$POSTGREST_CONF'"
  log "postgrest.conf written: $POSTGREST_CONF (contains DB password — 0600)"
}

# ---------- 5. SERVICE ----------
install_service() {
  svc_install "postgrest" "$POSTGREST_BIN $POSTGREST_CONF"
  svc_up "postgrest"
  if [[ "$DRY" != 1 ]]; then
    for i in $(seq 1 10); do
      [[ "$(svc_status postgrest)" == "up" ]] && break
      sleep 1
    done
  fi
  log "postgrest service: $(svc_status postgrest 2>/dev/null || echo unknown)"
}

# ---------- 6. SELF-TEST (real round-trip; must catch the up-but-empty facade) ----------
self_test() {
  if [[ "$DRY" == 1 ]]; then
    log "DRY: skipping self-test"
    return 0
  fi
  local base="http://127.0.0.1:$REST_PORT"
  local probe_id="PROBE-SUBSTRATE-$$"
  local code body

  # Empty-but-present collection must return 200 (not PGRST205 "table not found").
  code="$(curl -s -o /tmp/gap-substrate-selftest.$$ -w '%{http_code}' "$base/shared_gaps?limit=1")"
  body="$(cat /tmp/gap-substrate-selftest.$$ 2>/dev/null)"; rm -f /tmp/gap-substrate-selftest.$$
  [[ "$code" == "200" ]] || die "self-test: GET /shared_gaps returned $code (expected 200): $body"
  [[ "$body" == *PGRST205* ]] && die "self-test: schema cache doesn't know shared_gaps (PGRST205) — up-but-empty facade"

  # Real round-trip: insert -> read back -> delete.
  code="$(curl -s -o /tmp/gap-substrate-insert.$$ -w '%{http_code}' -X POST "$base/shared_gaps" \
    -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
    -d "{\"id\":\"$probe_id\",\"team_id\":\"$FLEET_TEAM_ID\",\"created_by_user_id\":\"$FLEET_TEAM_ID\",\"domain\":\"PROBE\",\"title\":\"substrate self-test\",\"priority\":\"P3\",\"effort\":\"xs\"}")"
  body="$(cat /tmp/gap-substrate-insert.$$ 2>/dev/null)"; rm -f /tmp/gap-substrate-insert.$$
  [[ "$code" == "201" ]] || die "self-test: POST insert returned $code (expected 201): $body"

  code="$(curl -s -o /tmp/gap-substrate-read.$$ -w '%{http_code}' "$base/shared_gaps?id=eq.$probe_id")"
  body="$(cat /tmp/gap-substrate-read.$$ 2>/dev/null)"; rm -f /tmp/gap-substrate-read.$$
  [[ "$code" == "200" ]] || die "self-test: GET probe returned $code (expected 200): $body"
  [[ "$body" == *"$probe_id"* ]] || die "self-test: probe row not found after insert — round-trip broken"

  code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$base/shared_gaps?id=eq.$probe_id")"
  [[ "$code" == "204" ]] || die "self-test: DELETE probe returned $code (expected 204)"

  log "self-test PASSED: insert -> read -> delete round-trip verified against $base/shared_gaps"
}

# ---------- 7. PIN (persist CHUMP_GAP_STORE_URL for the connect side) ----------
pin_gap_store_url() {
  touch "$CREDS"; chmod 600 "$CREDS"
  if grep -q '^CHUMP_GAP_STORE_URL=' "$CREDS" 2>/dev/null; then
    log "CHUMP_GAP_STORE_URL already pinned in $CREDS (no-op)"
    return 0
  fi
  run "printf 'CHUMP_GAP_STORE_URL=%s\n' '$CHUMP_GAP_STORE_URL' >> '$CREDS'"
  chmod 600 "$CREDS"
  log "CHUMP_GAP_STORE_URL pinned: $CHUMP_GAP_STORE_URL -> $CREDS"
}

# ---------- run ----------
ensure_postgres
ensure_db_and_roles
apply_schema
ensure_postgrest_binary
write_postgrest_conf
install_service
self_test
pin_gap_store_url
log "DONE. Substrate live: postgres db=$DB_NAME, PostgREST on 127.0.0.1:$REST_PORT (service via $SUPERVISOR). CHUMP_GAP_STORE_URL=$CHUMP_GAP_STORE_URL"
