#!/usr/bin/env bash
# scripts/ci/test-prepush-sccache-probe.sh — EFFECTIVE-097
#
# Guards the fix for the sccache liveness probe in the pre-push test gate.
#
# THE BUG (INFRA-2184 era): the probe ran `$RUSTC_WRAPPER --version` to decide
# whether the wrapper was usable. For sccache, `--version` is a CLIENT-only call
# that prints the version and exits 0 EVEN WHEN THE COMPILE SERVER IS DEAD. So a
# flapped server (the recurring "0 compile requests / os error 2" failure) sailed
# past the probe, cargo handed every compile to a dead wrapper, the full test gate
# false-failed, and the fleet learned to push with CHUMP_TEST_GATE=0. A gate that
# lies when infra hiccups is worse than no gate — it trains the bypass.
#
# THE FIX (EFFECTIVE-097): HEAL, don't just probe.
#   1. `--start-server` — idempotent heal (starts a dead server; exits 2 when one
#      is already running, so its exit is ignored, never the liveness signal).
#   2. `--show-stats`   — the real liveness check (0 iff the server responds).
#   Disable the wrapper ONLY when the binary is missing, or unhealable AND
#   --version-dead. The gate then always runs against a TRUE signal.
#
# This test asserts (a) the hook still parses, (b) the heal logic is present and
# the old sole `--version` disable is gone, and (c) — when sccache is installed —
# the heal sequence actually revives a stopped server instead of false-failing.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
HOOK=scripts/git-hooks/pre-push
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-prepush-sccache-probe.sh (EFFECTIVE-097) ==="

# 1. The hook parses (no syntax regression from the edit).
if bash -n "$HOOK" 2>/dev/null; then p "pre-push parses"; else f "pre-push FAILS bash -n"; fi

# 2. The heal logic is present: --start-server (heal) + --show-stats (liveness),
#    inside the wrapper-probe block.
if grep -q -- '--start-server' "$HOOK" && grep -q -- '--show-stats' "$HOOK"; then
  p "heal logic present (--start-server + --show-stats)"
else
  f "heal logic missing — wrapper block does not heal/liveness-probe"
fi

# 3. The defective pattern is gone: the OLD probe disabled the wrapper SOLELY on
#    `! "$_PREPUSH_WRAPPER_BIN" --version`. That exact construct must not remain as
#    the gating condition (a bare --version probe is the bug we removed).
if grep -qE '\|\|[[:space:]]*!.*_PREPUSH_WRAPPER_BIN.*--version' "$HOOK"; then
  f "old --version-only disable still present (the bug) at: $(grep -nE '\|\|[[:space:]]*!.*--version' "$HOOK" | head -1)"
else
  p "old --version-only disable removed"
fi

# 4. EFFECTIVE-097 attribution comment present (intent is documented in-line).
if grep -q 'EFFECTIVE-097' "$HOOK"; then p "fix attributed in-hook (EFFECTIVE-097)"; else f "no EFFECTIVE-097 attribution"; fi

# 5. BEHAVIORAL — only when sccache is actually installed (CI runners may not have
#    it). Stop the server, run the EXACT heal sequence the hook uses, and assert
#    the server ends up LIVE (healed) — i.e. --show-stats returns 0 and the wrapper
#    would NOT be disabled. Always restore the server on exit.
WRAPPER="${RUSTC_WRAPPER:-$(awk -F\" '/^[[:space:]]*rustc-wrapper[[:space:]]*=/ {print $2; exit}' "$ROOT/.cargo/config.toml" 2>/dev/null)}"
WRAPPER="${WRAPPER:-sccache}"
if command -v "$WRAPPER" >/dev/null 2>&1 && "$WRAPPER" --version >/dev/null 2>&1 && [[ "$(basename "$WRAPPER")" == sccache* ]]; then
  # Restore a running server no matter how we exit (don't leave the dev box server down).
  trap '"$WRAPPER" --start-server >/dev/null 2>&1 || true' EXIT
  "$WRAPPER" --stop-server >/dev/null 2>&1 || true
  sleep 1
  # The hook's heal sequence, verbatim in spirit:
  "$WRAPPER" --start-server >/dev/null 2>&1 || true   # heal; exit ignored
  if "$WRAPPER" --show-stats >/dev/null 2>&1; then
    p "behavioral: stopped server was HEALED (–show-stats=0 after heal) — no false-fail"
  else
    f "behavioral: server NOT live after heal sequence — fix ineffective"
  fi
  # Counter-check: confirm the OLD probe would have wrongly passed on a dead server
  # (documents WHY --version is the wrong signal). Informational, not scored.
  "$WRAPPER" --stop-server >/dev/null 2>&1 || true; sleep 1
  if "$WRAPPER" --version >/dev/null 2>&1; then
    echo "[note] confirmed: '$WRAPPER --version' exits 0 with the server DOWN — that is why the old probe false-passed."
  fi
  "$WRAPPER" --start-server >/dev/null 2>&1 || true
else
  echo "[skip] sccache not installed/usable here — behavioral heal check skipped (static checks above still enforce the fix shape)."
fi

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
