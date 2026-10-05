#!/usr/bin/env bash
# RESILIENT-376: chump-farmer-run.sh must build a HOST-AWARE PATH.
# The prior hardcoded PATH="/root/...:/usr/bin:/bin" had zero Termux binaries
# (curl/python3/git/bash live under $PREFIX/bin on Android/Termux), which broke
# the auth-status.sh free-tier probe (curl -> 000 -> a false RED farmer gate) and
# every coreutils call on the Pixel node. This test pins BOTH directions:
#   (a) Termux (PREFIX set)  -> $PREFIX/bin is on PATH (Termux binaries reachable)
#   (b) Helsinki (PREFIX unset) -> the Linux-root defaults are preserved, unchanged
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
SCRIPT="$ROOT/scripts/dispatch/chump-farmer-run.sh"
[[ -f "$SCRIPT" ]] || { echo "[test] FAIL: chump-farmer-run.sh missing"; exit 1; }
[[ "$(bash -n "$SCRIPT" 2>&1)" == "" ]] || { echo "[test] FAIL: syntax error"; exit 1; }

# Extract the single `export PATH=...` line and evaluate it in isolation under
# each host shape, so we test the real assignment without running the farmer.
PATH_LINE="$(grep -E '^export PATH=' "$SCRIPT" | tail -1)"
[[ -n "$PATH_LINE" ]] || { echo "[test] FAIL: no 'export PATH=' line found"; exit 1; }

fail=0

# (a) Termux shape: PREFIX set, HOME under Termux.
out_termux="$(env -i HOME=/data/data/com.termux/files/home \
    PREFIX=/data/data/com.termux/files/usr \
    bash -c "$PATH_LINE; printf '%s' \"\$PATH\"")"
if printf '%s' "$out_termux" | grep -q '/data/data/com.termux/files/usr/bin'; then
    echo "[test] PASS: Termux PATH includes \$PREFIX/bin"
else
    echo "[test] FAIL: Termux PATH missing \$PREFIX/bin: $out_termux"; fail=1
fi
# $PREFIX/bin must come BEFORE /usr/bin so Termux's curl/bash win over any stub.
if [[ "$out_termux" == *"/data/data/com.termux/files/usr/bin"*"/usr/bin"* ]] \
   || ! printf '%s' "$out_termux" | grep -q ':/usr/bin'; then
    echo "[test] PASS: \$PREFIX/bin precedes /usr/bin"
else
    echo "[test] FAIL: \$PREFIX/bin must precede /usr/bin: $out_termux"; fail=1
fi

# (b) Helsinki shape: PREFIX unset, HOME=/root. Root defaults must be preserved.
out_helsinki="$(env -i HOME=/root \
    bash -c "$PATH_LINE; printf '%s' \"\$PATH\"")"
if printf '%s' "$out_helsinki" | grep -q '/root/.cargo/bin' \
   && printf '%s' "$out_helsinki" | grep -q '/usr/bin'; then
    echo "[test] PASS: Helsinki PATH preserves root + /usr/bin defaults"
else
    echo "[test] FAIL: Helsinki PATH lost root/usr defaults: $out_helsinki"; fail=1
fi
# Blast-radius: no stray Termux path leaks onto a non-Termux host.
if printf '%s' "$out_helsinki" | grep -q '/data/data/com.termux'; then
    echo "[test] FAIL: Helsinki PATH leaked a Termux path: $out_helsinki"; fail=1
else
    echo "[test] PASS: Helsinki PATH has no Termux leakage"
fi

# ── REPO_ROOT derivation (RESILIENT-313 residue) ─────────────────────────────
# The farmer must derive REPO_ROOT from its OWN location, never default to a
# hardcoded /root/Projects/chump. That helsinki(root)-shaped default made the
# organ exit 1 every tick on an owned node (User=ubuntu): cd /root/Projects/chump
# -> Permission denied -> the worker-gate heartbeat this organ keeps fresh went
# stale. Pin both the regression (no hardcoded /root default) and the behavior
# (BASH_SOURCE derivation resolves to the repo root and collapses a symlink).
if grep -qE '^REPO_ROOT="\$\{CHUMP_REPO:-/root/Projects/chump\}"' "$SCRIPT"; then
    echo "[test] FAIL: REPO_ROOT still hardcodes the /root/Projects/chump default (breaks owned nodes)"; fail=1
else
    echo "[test] PASS: REPO_ROOT no longer hardcodes /root/Projects/chump"
fi

# Behavioral: extract the actual derivation lines from the script and run them
# from a SYMLINKED checkout path, proving they resolve to the REAL repo root.
DERIV_DIR="$(grep -E '^_FARMER_SCRIPT_DIR=' "$SCRIPT" | tail -1)"
DERIV_ROOT="$(grep -E '^REPO_ROOT=' "$SCRIPT" | tail -1)"
if [[ -n "$DERIV_DIR" && -n "$DERIV_ROOT" ]]; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/realrepo/scripts/dispatch"
    ln -s "$TMP/realrepo" "$TMP/link"
    PROBE="$TMP/realrepo/scripts/dispatch/chump-farmer-run.sh"   # same relative depth
    { printf '%s\n' "$DERIV_DIR" "$DERIV_ROOT" 'printf "%s" "$REPO_ROOT"'; } > "$PROBE"
    got="$(env -u CHUMP_REPO bash "$TMP/link/scripts/dispatch/chump-farmer-run.sh")"
    real="$(cd "$TMP/realrepo" && pwd -P)"
    if [[ "$got" == "$real" ]]; then
        echo "[test] PASS: REPO_ROOT derives to the real checkout from a symlinked path ($got)"
    else
        echo "[test] FAIL: REPO_ROOT derivation gave '$got', expected real checkout '$real'"; fail=1
    fi
else
    echo "[test] FAIL: could not find _FARMER_SCRIPT_DIR / REPO_ROOT derivation lines to test"; fail=1
fi

[[ "$fail" -eq 0 ]] && echo "[test-chump-farmer-run-path] PASS" || { echo "[test-chump-farmer-run-path] FAIL"; exit 1; }
