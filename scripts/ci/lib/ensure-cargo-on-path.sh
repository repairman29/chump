#!/usr/bin/env bash
# scripts/ci/lib/ensure-cargo-on-path.sh — INFRA-1619
#
# Sourceable helper: add $HOME/.cargo/bin to PATH if not already present.
#
# Self-hosted runner jobs launched via launchctl (macOS) inherit a stripped
# PATH that omits $HOME/.cargo/bin, even when rustup is installed (INFRA-1600).
# Sourcing this script before any `cargo` invocation guarantees the binary
# is found without requiring every workflow step to hard-code the path.
#
# Usage (source — do NOT execute directly):
#   source scripts/ci/lib/ensure-cargo-on-path.sh

if [[ ":${PATH}:" != *":${HOME}/.cargo/bin:"* ]]; then
  export PATH="${HOME}/.cargo/bin:${PATH}"
fi
