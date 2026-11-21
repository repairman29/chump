#!/usr/bin/env bash
# RESILIENT-243: acp-smoke must find the binary via .cargo/config.toml target-dir
# when <repo>/target is absent and CARGO_TARGET_DIR is unset.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts/ci" "$T/repo/.cargo" "$T/shared/debug"
cp "$ROOT/scripts/ci/test-acp-smoke.sh" "$T/repo/scripts/ci/"
printf '#!/bin/sh\nexit 0\n' > "$T/shared/debug/chump"; chmod +x "$T/shared/debug/chump"
printf '[build]\ntarget-dir = "%s"\n' "$T/shared" > "$T/repo/.cargo/config.toml"
out="$(cd "$T/repo" && env -u CARGO_TARGET_DIR -u CHUMP_BIN bash scripts/ci/test-acp-smoke.sh 2>&1 || true)"
if grep -q "using CHUMP_BIN=$T/shared/debug/chump" <<<"$out"; then
  echo "PASS: acp-smoke resolved binary from .cargo/config.toml target-dir"
else
  echo "FAIL: binary not resolved"; echo "$out"; exit 1
fi
