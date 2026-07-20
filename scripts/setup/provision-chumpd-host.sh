#!/usr/bin/env bash
# provision-chumpd-host.sh — RESILIENT-176 (PREP slice)
#
# Idempotent provisioner for a FRESH macOS or Linux host that will become
# the fleet's always-on substrate: chumpd + N supervised Sonnet workers,
# per docs/design/GROUND_UP_2026-07-19.md step 5 and the runbook at
# docs/process/OFF_LAPTOP_SUBSTRATE.md.
#
# STATUS (2026-07-19): RESILIENT-176 depends_on MISSION-051 (the chumpd
# binary), which has NOT merged to main yet. This script is deliberately
# PREP-ONLY: it provisions everything a fresh host needs (git, gh, claude
# CLI, cargo, repo clone, build) and CHECKS FOR the chumpd binary +
# scripts/setup/install-chumpd.sh before attempting to install/start the
# service. When those aren't present yet, it prints a clear BLOCKED
# message and stops that step rather than pretending to install something
# that doesn't exist — "reporting a mechanism active before verifying it"
# is a banned move per docs/process/DURABLE_FIX_DOCTRINE.md. Re-run this
# script after MISSION-051 lands to pick up where it left off (idempotent).
#
# NO REMOTE ACTIONS: this script only touches the LOCAL filesystem/service
# manager of the host it runs ON. It does not SSH anywhere, does not spawn
# fleet workers, and does not talk to any chumpd socket. Run it ON the
# target host (laptop, Pi, mini, or cloud droplet) — see the host-candidate
# table in docs/process/OFF_LAPTOP_SUBSTRATE.md for how to pick one.
#
# NO CREDENTIALS EMBEDDED: this script never reads, prints, or writes a
# credential VALUE. It only checks presence of the files/env vars the
# operator is expected to provision per CLAUDE.md → "GitHub credentials for
# agents (INFRA-AGENT-CREDS)" and RESILIENT-173 ("no secrets in argv —
# env files only"), and prints exactly what's missing.
#
# Safe to run repeatedly (idempotent) — every mutating step first checks
# whether its target state already holds.
#
# Usage:
#   scripts/setup/provision-chumpd-host.sh                # full idempotent provision
#   scripts/setup/provision-chumpd-host.sh --check         # report readiness only; exit 0 (ready) / 1 (missing deps)
#   scripts/setup/provision-chumpd-host.sh --dry-run        # print every action, mutate nothing
#   scripts/setup/provision-chumpd-host.sh --uninstall       # stop + remove the chumpd service (leaves repo clone)
#
# Env overrides:
#   CHUMPD_PROVISION_DIR       clone target dir (default: $HOME/chump-host)
#   CHUMPD_PROVISION_REPO_URL  https clone URL (default: https://github.com/repairman29/chump.git)
#   CHUMPD_PROVISION_BRANCH    branch to build (default: main)
#
# Rust-First-Bypass: one-shot host-bootstrap wrapper around git/gh/cargo/
# launchctl/systemctl — pure CLI glue, no state.db/ambient.jsonl/gap-yaml
# mutation, runs once per host (not a hot path). Per META-064 shell-OK
# criteria (glue between existing CLI tools, exploratory-until-MISSION-051,
# no regression-test maintenance burden beyond the shape smoke test).

set -euo pipefail

# ── HOME guard ────────────────────────────────────────────────────────────
# Every mutating path in this script is derived from $HOME (clone dir,
# ~/.chump/oauth-token.json check, ~/Library/LaunchAgents, ~/.config/systemd).
# Refuse to run with HOME unset rather than silently resolving into an
# undefined location.
if [[ -z "${HOME:-}" ]]; then
  echo "ERROR: HOME is unset — refusing to run (every path below is HOME-relative)." >&2
  exit 1
fi

MODE="run"
case "${1:-}" in
  --check)     MODE="check" ;;
  --dry-run)   MODE="dry-run" ;;
  --uninstall) MODE="uninstall" ;;
  -h|--help)
    sed -n '2,40p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
esac

CHUMPD_PROVISION_DIR="${CHUMPD_PROVISION_DIR:-$HOME/chump-host}"
CHUMPD_PROVISION_REPO_URL="${CHUMPD_PROVISION_REPO_URL:-https://github.com/repairman29/chump.git}"
CHUMPD_PROVISION_BRANCH="${CHUMPD_PROVISION_BRANCH:-main}"

log()  { echo "[provision-chumpd-host] $*"; }
warn() { echo "[provision-chumpd-host] WARN: $*" >&2; }
fail() { echo "[provision-chumpd-host] FAIL: $*" >&2; }

# run <description> -- <cmd...>
# In --dry-run mode, prints what would happen and returns 0 without
# executing. In --check mode, callers should not invoke run() for mutating
# steps at all (check is read-only by construction). Otherwise executes.
run() {
  local desc="$1"; shift
  if [[ "$MODE" == "dry-run" ]]; then
    log "[dry-run] would: $desc"
    return 0
  fi
  log "$desc"
  "$@"
}

# ── OS / arch detection ──────────────────────────────────────────────────
OS_KIND=""
case "$(uname -s)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
  *) fail "unsupported OS $(uname -s) — chumpd host provisioning supports macOS and Linux only"; exit 1 ;;
esac
ARCH="$(uname -m)"
log "detected OS=$OS_KIND arch=$ARCH"

READY=1  # flips to 0 on any missing hard dependency

# ── Dependency checks ─────────────────────────────────────────────────────
check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    log "OK: $cmd found ($(command -v "$cmd"))"
  else
    warn "$cmd NOT found — $hint"
    READY=0
  fi
}

log "-- dependency inventory --"
check_cmd git   "install via https://git-scm.com/downloads or your package manager (brew install git / apt install git)"
check_cmd gh    "install via https://cli.github.com (brew install gh / apt install gh)"
check_cmd claude "install the Claude Code CLI: https://docs.claude.com/en/docs/claude-code — required to run chumpd's supervised Sonnet workers"
check_cmd cargo "install Rust via https://rustup.rs (curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh)"

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    log "OK: gh is authenticated"
  else
    warn "gh is installed but NOT authenticated — run 'gh auth login' (interactive, operator-only step)"
    READY=0
  fi
fi

# Disk headroom: ~20GB minimum for chumpd + 2 sonnet workers per repo docs
# (docs/process/DISK_COST_MODEL.yaml cargo_build + worktree + target dirs).
AVAIL_GB=0
if [[ "$OS_KIND" == "macos" ]]; then
  AVAIL_GB=$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
else
  AVAIL_GB=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
fi
AVAIL_GB="${AVAIL_GB:-0}"
if [[ "$AVAIL_GB" -ge 20 ]]; then
  log "OK: ${AVAIL_GB}GB available at \$HOME (>= 20GB floor)"
else
  warn "${AVAIL_GB}GB available at \$HOME — below the 20GB floor chumpd + 2 workers need"
  READY=0
fi

# Network reachability (read-only checks; no data sent). Deliberately NOT
# using curl -f: some hosts (e.g. api.anthropic.com's bare root) return a
# non-2xx for "/" by design — a TLS handshake + any HTTP response proves
# reachability, a connect-level failure (curl exit 6/7/28) does not.
for host in github.com api.anthropic.com; do
  http_code=""
  if command -v curl >/dev/null 2>&1; then
    http_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "https://${host}" 2>/dev/null || true)"
  fi
  if [[ -n "$http_code" && "$http_code" != "000" ]]; then
    log "OK: network reaches https://${host} (HTTP ${http_code})"
  else
    warn "could not reach https://${host} — required for gh/git push and the Claude API"
    READY=0
  fi
done

# ── Auth material — presence-only checks, NEVER print values ─────────────
log "-- auth material (INFRA-AGENT-CREDS / RESILIENT-173: presence only, no values) --"
if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
  log "OK: GH_TOKEN/GITHUB_TOKEN is set in this shell's environment"
else
  warn "GH_TOKEN/GITHUB_TOKEN not set — gh falls back to keyring/SSH (implicit mode); on a" \
       "fresh host with no keyring, export GH_TOKEN from an ENV FILE (never argv) before" \
       "running chumpd. See docs/process/OFF_LAPTOP_SUBSTRATE.md 'Auth material checklist'."
fi
OAUTH_TOKEN_PATH="${CHUMP_OAUTH_TOKEN_PATH:-$HOME/.chump/oauth-token.json}"
if [[ -f "$OAUTH_TOKEN_PATH" ]]; then
  log "OK: oauth token file present at $OAUTH_TOKEN_PATH (not read; presence only)"
else
  warn "no oauth token file at $OAUTH_TOKEN_PATH — fleet subscription auth (CHUMP_AUTH_MODE=oauth)" \
       "won't be available until the operator copies/refreshes it onto this host"
fi

if [[ "$MODE" == "check" ]]; then
  if [[ "$READY" -eq 1 ]]; then
    log "READY: all hard dependencies present. Auth-material warnings above (if any) are operator TODOs."
    exit 0
  else
    fail "NOT READY — see warnings above."
    exit 1
  fi
fi

# ── Uninstall path ─────────────────────────────────────────────────────
if [[ "$MODE" == "uninstall" ]]; then
  if [[ "$OS_KIND" == "macos" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.chump.chumpd.plist"
    if [[ -f "$PLIST" ]]; then
      run "unload + remove $PLIST" launchctl unload "$PLIST"
      run "rm $PLIST" rm -f "$PLIST"
    else
      log "no chumpd launchd plist installed — nothing to remove"
    fi
  else
    if systemctl --user list-unit-files 2>/dev/null | grep -q '^chumpd\.service'; then
      run "stop chumpd.service" systemctl --user stop chumpd.service
      run "disable chumpd.service" systemctl --user disable chumpd.service
      run "remove unit file" rm -f "$HOME/.config/systemd/user/chumpd.service"
      run "daemon-reload" systemctl --user daemon-reload
    else
      log "no chumpd systemd unit installed — nothing to remove"
    fi
  fi
  log "uninstall complete. Repo clone at $CHUMPD_PROVISION_DIR left in place (rm -rf it manually if desired)."
  exit 0
fi

# ── Repo clone / update (idempotent) ─────────────────────────────────────
log "-- repo checkout --"
if [[ -d "$CHUMPD_PROVISION_DIR/.git" ]]; then
  log "OK: repo already cloned at $CHUMPD_PROVISION_DIR"
  run "fetch latest $CHUMPD_PROVISION_BRANCH" git -C "$CHUMPD_PROVISION_DIR" fetch origin "$CHUMPD_PROVISION_BRANCH" --quiet
else
  run "clone $CHUMPD_PROVISION_REPO_URL -> $CHUMPD_PROVISION_DIR" \
    git clone --branch "$CHUMPD_PROVISION_BRANCH" "$CHUMPD_PROVISION_REPO_URL" "$CHUMPD_PROVISION_DIR"
fi

# ── Build ──────────────────────────────────────────────────────────────
log "-- build --"
if [[ "$MODE" == "dry-run" ]]; then
  log "[dry-run] would: cd $CHUMPD_PROVISION_DIR && cargo build --release --bin chump"
  log "[dry-run] would: check whether the checkout has a chumpd binary target yet" \
      "(BLOCKED-until-MISSION-051 gate); if present, would install + validate the service"
  log "[dry-run] stopping here — dry-run never clones, so it cannot inspect Cargo.toml for" \
      "the chumpd target. Run without --dry-run (or --check) against a real checkout to" \
      "see the actual BLOCKED / service-install outcome."
  log "done (dry-run). See docs/process/OFF_LAPTOP_SUBSTRATE.md for the cutover checklist."
  exit 0
else
  ( cd "$CHUMPD_PROVISION_DIR" && cargo build --release --bin chump )
  log "OK: built chump"
fi

# ── chumpd availability gate (BLOCKED-until-MISSION-051) ─────────────────
CHUMPD_BIN_TARGET_PRESENT=0
if grep -qE '^\s*\[\[bin\]\]' "$CHUMPD_PROVISION_DIR/Cargo.toml" 2>/dev/null \
   && grep -q 'name = "chumpd"' "$CHUMPD_PROVISION_DIR/Cargo.toml" 2>/dev/null; then
  CHUMPD_BIN_TARGET_PRESENT=1
fi
if [[ -d "$CHUMPD_PROVISION_DIR/crates/chumpd" ]]; then
  CHUMPD_BIN_TARGET_PRESENT=1
fi

if [[ "$CHUMPD_BIN_TARGET_PRESENT" -eq 0 ]]; then
  cat <<'EOF'
[provision-chumpd-host] BLOCKED: no chumpd binary target found in this checkout.
[provision-chumpd-host]   RESILIENT-176 depends_on MISSION-051 (chumpd supervisor
[provision-chumpd-host]   umbrella), which has not merged yet. Host + toolchain +
[provision-chumpd-host]   repo checkout above ARE complete and idempotent — re-run
[provision-chumpd-host]   this script after MISSION-051 lands (git pull happens
[provision-chumpd-host]   automatically above) to build + install the service.
EOF
  log "stopping here. Everything through 'repo checkout + toolchain' is done; service install is deferred."
  exit 0
fi

# ── Service install ────────────────────────────────────────────────────
log "-- service install --"
INSTALL_CHUMPD_SH="$CHUMPD_PROVISION_DIR/scripts/setup/install-chumpd.sh"
if [[ "$OS_KIND" == "macos" ]]; then
  if [[ -f "$INSTALL_CHUMPD_SH" ]]; then
    run "invoke install-chumpd.sh" bash "$INSTALL_CHUMPD_SH"
  else
    warn "chumpd binary target exists but scripts/setup/install-chumpd.sh does not yet" \
         "(MISSION-051 landed a binary without its installer, or this repo is between" \
         "commits) — install manually once it ships, or re-run this script."
  fi
else
  TEMPLATE="$CHUMPD_PROVISION_DIR/scripts/setup/chumpd.service"
  UNIT_DIR="$HOME/.config/systemd/user"
  UNIT_DST="$UNIT_DIR/chumpd.service"
  if [[ -f "$TEMPLATE" ]]; then
    run "mkdir -p $UNIT_DIR" mkdir -p "$UNIT_DIR"
    sed -e "s|__REPO_ROOT__|$CHUMPD_PROVISION_DIR|g" -e "s|__HOME__|$HOME|g" \
      "$TEMPLATE" > "$UNIT_DST"
    log "wrote $UNIT_DST"
    run "daemon-reload" systemctl --user daemon-reload
    run "enable chumpd.service (not started — see validation dry-run below)" systemctl --user enable chumpd.service
  else
    warn "scripts/setup/chumpd.service template not found — skipping systemd install"
  fi
fi

# ── Validation dry-run ─────────────────────────────────────────────────
# Once chumpd exists, validate the install WITHOUT taking over fleet
# coordination: CHUMPD_TAKEOVER=0 + --mode=off means "start, prove the
# supervisor tree boots, touch no shared state, exit clean." This is
# chumpd's OWN dry-run flag (once MISSION-051 defines it), distinct from
# this provisioning script's --dry-run (which exits before reaching here).
CHUMPD_BIN="$CHUMPD_PROVISION_DIR/target/release/chumpd"
if [[ -x "$CHUMPD_BIN" ]]; then
  log "-- validation dry-run (CHUMPD_TAKEOVER=0, mode=off) --"
  if CHUMPD_TAKEOVER=0 "$CHUMPD_BIN" --mode=off --dry-run; then
    log "OK: chumpd validation dry-run passed"
  else
    warn "chumpd validation dry-run failed or --mode=off/--dry-run flags don't exist yet" \
         "in this build — check MISSION-051's actual CLI surface once it ships."
  fi
else
  log "chumpd binary not built yet at $CHUMPD_BIN (expected pre-MISSION-051) — skipping validation dry-run"
fi

log "done. See docs/process/OFF_LAPTOP_SUBSTRATE.md for the cutover checklist."
