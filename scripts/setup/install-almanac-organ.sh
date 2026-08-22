#!/usr/bin/env bash
# install-almanac-organ.sh — INFRA-3635
#
# The missing from-0 step in the install-a-Trek epic: on a bare factory node
# that has NEVER touched almanac (no ~/Projects/almanac at all), clone
# repairman29/almanac, cargo build --release, and hardcopy the binary to
# ~/.cargo/bin/almanac so `almanac` FTUE hooks (chump-ftue-hook.sh) and
# `almanac init/repos/stats` work immediately.
#
# Mines: scripts/setup/chump-node-install.sh (detect_host + host-agnostic
# build), scripts/setup/refresh-runner-binary.sh (cargo build + hardcopy +
# SHA-idempotent skip), ~/Projects/almanac/scripts/chump-ftue-hook.sh (the
# ALMANAC_BIN=$HOME/Projects/almanac/target/release/almanac,
# ALMANAC_HOME=$HOME/.almanac env contract this script must produce).
#
# Idempotent: tracks the source SHA it last built against in a sidecar file
# next to the installed binary (almanac's own `--version` has no embedded
# build SHA to compare against, unlike chump's). If the sidecar SHA already
# matches origin/main HEAD, cargo is skipped entirely.
#
# Usage: scripts/setup/install-almanac-organ.sh [--verify-only]

set -uo pipefail

ALMANAC_SRC_DIR="${ALMANAC_SRC_DIR:-$HOME/Projects/almanac}"
ALMANAC_REPO_URL="${ALMANAC_REPO_URL:-https://github.com/repairman29/almanac.git}"
TARGET_BIN="${ALMANAC_TARGET_BIN:-$HOME/.cargo/bin/almanac}"
SHA_STATE_FILE="$(dirname "$TARGET_BIN")/.almanac-organ.sha"
export ALMANAC_HOME="${ALMANAC_HOME:-$HOME/.almanac}"

VERIFY_ONLY=0
[ "${1:-}" = "--verify-only" ] && VERIFY_ONLY=1

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
info(){ printf '\033[36m[%s]\033[0m %s\n' "$1" "$2"; }

# ---------- DETECT (host-agnostic, mirrors chump-node-install.sh) ----------
detect_host() {
  ARCH="$(uname -m)"; OS="$(uname -s)"
  if [ "$OS" = "Darwin" ]; then
    HOST_KIND="macos"
  elif command -v systemctl >/dev/null 2>&1; then
    HOST_KIND="linux-systemd"
  else
    HOST_KIND="linux-nosystemd"
  fi
  info DETECT "host=$HOST_KIND arch=$ARCH"
}

resolve_cargo() {
  for candidate in "$HOME/.cargo/bin/cargo" "$(command -v cargo 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      echo "$candidate"; return 0
    fi
  done
  return 1
}

# ---------- HOME: clone (or sync) the source repo ----------
ensure_src() {
  if [ -d "$ALMANAC_SRC_DIR/.git" ]; then
    ok "source present: $ALMANAC_SRC_DIR"
  else
    info CLONE "$ALMANAC_REPO_URL -> $ALMANAC_SRC_DIR"
    mkdir -p "$(dirname "$ALMANAC_SRC_DIR")"
    if ! git clone --quiet "$ALMANAC_REPO_URL" "$ALMANAC_SRC_DIR"; then
      no "clone FAILED: $ALMANAC_SRC_DIR"
      return 1
    fi
    ok "source cloned: $ALMANAC_SRC_DIR"
  fi
  git -C "$ALMANAC_SRC_DIR" fetch origin main --quiet 2>/dev/null || {
    info FETCH "offline or fetch failed; proceeding with local state"
  }
}

# ---------- BINARY: idempotent build + hardcopy ----------
ensure_binary() {
  local origin_sha stored_sha
  origin_sha="$(git -C "$ALMANAC_SRC_DIR" rev-parse origin/main 2>/dev/null || git -C "$ALMANAC_SRC_DIR" rev-parse HEAD)"
  stored_sha="$(cat "$SHA_STATE_FILE" 2>/dev/null || echo none)"

  if [ -x "$TARGET_BIN" ] && [ "$stored_sha" = "$origin_sha" ]; then
    ok "binary already current (sha $stored_sha) — skipping cargo"
    return 0
  fi

  local cargo
  if ! cargo="$(resolve_cargo)"; then
    no "cargo not found in PATH or ~/.cargo/bin — install rustup first"
    return 1
  fi
  info BUILD "using cargo: $cargo"

  if ! git -C "$ALMANAC_SRC_DIR" reset --hard origin/main --quiet 2>/dev/null; then
    info SYNC "reset to origin/main failed (offline?); building local HEAD"
  fi

  info BUILD "cargo build --release --bin almanac ($ALMANAC_SRC_DIR)"
  # Force CARGO_TARGET_DIR to the source tree's own target/ regardless of any
  # inherited env override (e.g. a shared build cache) so the built-binary
  # path below is deterministic.
  if ! PATH="$(dirname "$cargo"):$PATH" CARGO_TARGET_DIR="$ALMANAC_SRC_DIR/target" "$cargo" build --release --bin almanac \
      --manifest-path "$ALMANAC_SRC_DIR/Cargo.toml" 2>&1 | tail -40; then
    no "cargo build FAILED"
    return 1
  fi

  local built_bin="$ALMANAC_SRC_DIR/target/release/almanac"
  if [ ! -x "$built_bin" ]; then
    no "built binary missing: $built_bin"
    return 1
  fi

  mkdir -p "$(dirname "$TARGET_BIN")"
  cp -f "$built_bin" "$TARGET_BIN.new"
  chmod +x "$TARGET_BIN.new"
  if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$TARGET_BIN.new" 2>/dev/null || true
  fi
  mv -f "$TARGET_BIN.new" "$TARGET_BIN"

  local built_sha
  built_sha="$(git -C "$ALMANAC_SRC_DIR" rev-parse HEAD)"
  printf '%s\n' "$built_sha" > "$SHA_STATE_FILE"
  ok "installed: $TARGET_BIN (sha $built_sha)"
}

# ---------- VERIFY-LIVE: read-only, no side effects ----------
verify_live() {
  if [ ! -x "$TARGET_BIN" ]; then
    no "VERIFY: $TARGET_BIN missing"
    return 1
  fi
  local repos_out slug
  repos_out="$("$TARGET_BIN" repos 2>&1)"
  if ! printf '%s' "$repos_out" | grep -qE '^\s+\S+\s+[0-9a-f]{6,}'; then
    no "VERIFY: 'almanac repos' returned no registered repos"
    printf '%s\n' "$repos_out"
    return 1
  fi
  ok "'almanac repos' resolvable ($(printf '%s' "$repos_out" | head -1))"

  slug="$(printf '%s' "$repos_out" | awk 'NR==2{print $1}')"
  if [ -z "$slug" ]; then
    info VERIFY "no repo registered yet to stats-check (fresh node) — skipping stats probe"
    return 0
  fi

  local stats_out files
  stats_out="$("$TARGET_BIN" stats "$slug" 2>&1)"
  files="$(printf '%s' "$stats_out" | grep -oE 'files:\s+[0-9]+' | grep -oE '[0-9]+' || echo 0)"
  if [ "${files:-0}" -gt 0 ]; then
    ok "'almanac stats $slug' reports $files files (>0)"
  else
    no "VERIFY: 'almanac stats $slug' reports 0 files"
    printf '%s\n' "$stats_out"
    return 1
  fi
}

# ---------- main ----------
printf '\033[1m=== install-almanac-organ ===\033[0m\n'
detect_host

if [ "$VERIFY_ONLY" = 1 ]; then
  verify_live
  exit $?
fi

ensure_src || { no "HOME phase failed (repo clone/fetch) — fix and re-run"; exit 1; }
ensure_binary || { no "BINARY phase failed"; exit 1; }
verify_live || { no "VERIFY-LIVE failed post-install"; exit 1; }

echo
ok "almanac organ installed: $TARGET_BIN"
exit 0
