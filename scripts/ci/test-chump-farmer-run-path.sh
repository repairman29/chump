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

[[ "$fail" -eq 0 ]] && echo "[test-chump-farmer-run-path] PASS" || { echo "[test-chump-farmer-run-path] FAIL"; exit 1; }
