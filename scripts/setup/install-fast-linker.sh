#!/usr/bin/env bash
# install-fast-linker.sh — EFFECTIVE-426
#
# Installs + wires a fast linker for this repo's cargo builds:
#   - Linux: mold (via apt)
#   - macOS: lld (via `brew install llvm`, invoked as ld64.lld)
#
# `.cargo/config.toml` is gitignored (per-developer machine differences —
# see .gitignore line 172), so a linker override placed only there never
# propagates to a fresh host. This script is the propagation path: it is
# invoked directly by a developer AND by scripts/setup/provision-chumpd-host.sh
# (so every freshly-provisioned fleet host, e.g. helsinki/closetjunky, gets
# the fast linker wired automatically instead of relying on a human to
# remember to hand-edit a gitignored file).
#
# Usage:
#   scripts/setup/install-fast-linker.sh            # install + wire (idempotent)
#   scripts/setup/install-fast-linker.sh --check     # report only, mutate nothing
#
# Rust-First-Bypass: one-shot host-setup wrapper around apt/brew + a TOML
# config write — pure CLI glue, no state.db/ambient.jsonl mutation, not a
# hot path (runs once per host). Per META-064 shell-OK criteria.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CARGO_CONFIG="$REPO_ROOT/.cargo/config.toml"
MODE="install"
[[ "${1:-}" == "--check" ]] && MODE="check"

log()  { echo "[install-fast-linker] $*"; }
warn() { echo "[install-fast-linker] WARN: $*" >&2; }

OS_KIND=""
case "$(uname -s)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
  *) warn "unsupported OS $(uname -s) — this script supports macOS and Linux only"; exit 1 ;;
esac

HOST_TRIPLE="$(rustc -vV 2>/dev/null | awk '/^host:/{print $2}')"
if [[ -z "$HOST_TRIPLE" ]]; then
  warn "could not determine host triple (is rustc on PATH?) — skipping"
  exit 1
fi

# ── Linux: mold ───────────────────────────────────────────────────────────
install_mold() {
  if command -v mold >/dev/null 2>&1; then
    log "OK: mold already installed ($(command -v mold), $(mold --version 2>/dev/null))"
    return 0
  fi
  if [[ "$MODE" == "check" ]]; then
    warn "mold not installed"
    return 1
  fi
  if command -v apt-get >/dev/null 2>&1; then
    log "installing mold via apt-get"
    local SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
    $SUDO apt-get update -y
    $SUDO apt-get install -y mold
  else
    warn "apt-get not found — install mold manually: https://github.com/rui314/mold#installation"
    return 1
  fi
}

# ── macOS: lld ────────────────────────────────────────────────────────────
install_lld() {
  if command -v ld64.lld >/dev/null 2>&1; then
    log "OK: ld64.lld already on PATH ($(command -v ld64.lld))"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    warn "brew not found — install Homebrew first, then: brew install llvm"
    return 1
  fi
  local llvm_prefix
  llvm_prefix="$(brew --prefix llvm 2>/dev/null || true)"
  if [[ -n "$llvm_prefix" && -x "$llvm_prefix/bin/ld64.lld" ]]; then
    log "OK: llvm keg present at $llvm_prefix (ld64.lld found)"
    return 0
  fi
  if [[ "$MODE" == "check" ]]; then
    warn "llvm/lld not installed (brew install llvm)"
    return 1
  fi
  log "installing llvm (provides lld) via brew"
  brew install llvm
}

case "$OS_KIND" in
  linux) install_mold || { [[ "$MODE" == "check" ]] && exit 1 || warn "mold install failed — leaving linker unwired"; exit 1; } ;;
  macos) install_lld  || { [[ "$MODE" == "check" ]] && exit 1 || warn "lld install failed — leaving linker unwired"; exit 1; } ;;
esac

if [[ "$MODE" == "check" ]]; then
  log "READY: fast linker present for $OS_KIND"
  exit 0
fi

# ── Wire .cargo/config.toml ─────────────────────────────────────────────
# gitignored (per-machine paths vary), so we generate it here rather than
# relying on a committed copy. scripts/setup/cargo-fast-linker.toml is the
# COMMITTED template documenting the exact content, for anyone who wants to
# apply it by hand or diff against what this script wrote.
mkdir -p "$REPO_ROOT/.cargo"

RUSTFLAGS_LINE=""
case "$OS_KIND" in
  linux) RUSTFLAGS_LINE='rustflags = ["-C", "link-arg=-fuse-ld=mold"]' ;;
  macos) RUSTFLAGS_LINE='rustflags = ["-C", "link-arg=-fuse-ld=lld"]' ;;
esac

if [[ -f "$CARGO_CONFIG" ]] && grep -q "\[target.$HOST_TRIPLE\]" "$CARGO_CONFIG" 2>/dev/null; then
  log "OK: [target.$HOST_TRIPLE] section already present in $CARGO_CONFIG — leaving as-is"
else
  log "writing [target.$HOST_TRIPLE] fast-linker section to $CARGO_CONFIG"
  {
    echo ""
    echo "# EFFECTIVE-426: fast linker (written by scripts/setup/install-fast-linker.sh)"
    echo "[target.$HOST_TRIPLE]"
    echo "$RUSTFLAGS_LINE"
  } >> "$CARGO_CONFIG"
fi

log "done. Verify with: cargo build -v 2>&1 | grep -o 'fuse-ld=[a-z]*' | head -1"
