#!/usr/bin/env bash
# Bootstrap Chump's CLI toolkit. Run once on a fresh machine. Idempotent.
# Usage: ./scripts/setup/bootstrap-toolkit.sh
#        SKIP_CARGO=1 ./scripts/setup/bootstrap-toolkit.sh   # skip cargo installs (slow)
#        SKIP_BREW=1 ./scripts/setup/bootstrap-toolkit.sh     # skip brew installs
#        INCLUDE_OLLAMA=1 ./scripts/setup/bootstrap-toolkit.sh # also install ollama

set -e

echo "=== Chump toolkit bootstrap ==="

# --- Homebrew ---
if [[ -z "${SKIP_BREW:-}" ]]; then
  if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  BREW_PKGS=(
    # Code search & navigation
    ripgrep fd tree
    # Data processing
    jq yq
    # System monitoring
    bottom
    # Git
    git-delta gh gitleaks
    # Network
    dog
    # Docs
    pandoc
    # Shell
    nushell
  )

  echo ""
  echo "--- Brew packages ---"
  for pkg in "${BREW_PKGS[@]}"; do
    if brew list "$pkg" &>/dev/null 2>&1; then
      echo "  ✅ $pkg"
    else
      echo "  📦 Installing $pkg..."
      brew install "$pkg" || echo "  ⚠️  $pkg install failed (non-fatal)"
    fi
  done

  if [[ -n "${INCLUDE_OLLAMA:-}" ]]; then
    if ! command -v ollama &>/dev/null; then
      echo "  📦 Installing ollama..."
      brew install ollama
    else
      echo "  ✅ ollama"
    fi
  fi
fi

# --- Cargo packages ---
if [[ -z "${SKIP_CARGO:-}" ]]; then
  if ! command -v cargo &>/dev/null; then
    echo "Rust not installed. Install via: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
  fi

  # Map of cargo-package → binary-name (for checking if already installed)
  # Format: "package:binary" or just "package" if binary == package
  CARGO_PKGS=(
    "tokei:tokei"
    "ast-grep:ast-grep"
    "cargo-nextest:cargo-nextest"
    "cargo-audit:cargo-audit"
    "cargo-outdated:cargo-outdated"
    "cargo-deny:cargo-deny"
    "cargo-tarpaulin:cargo-tarpaulin"
    "cargo-expand:cargo-expand"
    "cargo-watch:cargo-watch"
    "flamegraph:flamegraph"
    "xsv:xsv"
    "sd:sd"
    "htmlq:htmlq"
    "du-dust:dust"
    "procs:procs"
    "bandwhich:bandwhich"
    "xh:xh"
    "just:just"
    "watchexec-cli:watchexec"
    "hyperfine:hyperfine"
    "mdbook:mdbook"
    "git-absorb:git-absorb"
  )

  echo ""
  echo "--- Cargo packages (this may take a while) ---"
  for entry in "${CARGO_PKGS[@]}"; do
    pkg="${entry%%:*}"
    bin="${entry##*:}"
    if command -v "$bin" &>/dev/null; then
      echo "  ✅ $pkg ($bin)"
    else
      echo "  📦 Installing $pkg..."
      cargo install "$pkg" 2>/dev/null || echo "  ⚠️  $pkg install failed (non-fatal)"
    fi
  done
fi

# --- Python tools (optional, lightweight) ---
if command -v pip3 &>/dev/null; then
  echo ""
  echo "--- Python tools ---"
  if command -v llm &>/dev/null; then
    echo "  ✅ llm"
  else
    echo "  📦 Installing llm..."
    pip3 install --user llm 2>/dev/null || echo "  ⚠️  llm install failed (non-fatal)"
  fi
fi

echo ""
echo "=== Bootstrap complete ==="
echo "Run ./scripts/ci/verify-toolkit.sh to check what's available."
echo "Run with INCLUDE_OLLAMA=1 to also install Ollama (large download)."
