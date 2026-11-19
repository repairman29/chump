#!/usr/bin/env bash
# test-unknown-subcommand-guard.sh — CREDIBLE-134
#
# An unknown / typo'd single-token subcommand must error with usage and exit
# NON-ZERO — never silently route to the model/agent path (which printed a
# hallucinated "Response from Agent: ..." reply and exited 0, a scripting
# footgun: a typo'd `chump <cmd>` in any fleet script would "succeed").
#
# Freeform NL stays available as a quoted multi-word string (e.g.
# `chump "summarize today"`), so the guard only fires on a single bare token.

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || { echo "FAIL: cd $REPO_ROOT"; exit 1; }

# Resolve a chump binary: prefer an already-built one, else build it.
CHUMP="${CHUMP_BIN:-}"
if [ -z "$CHUMP" ]; then
    for c in ./target/debug/chump ./target/release/chump "$(command -v chump 2>/dev/null || true)"; do
        if [ -n "$c" ] && [ -x "$c" ]; then CHUMP="$c"; break; fi
    done
fi
if [ -z "$CHUMP" ]; then
    echo "[unknown-subcmd-guard] no chump binary found — building…"
    cargo build --bin chump --quiet || { echo "FAIL: cargo build --bin chump"; exit 1; }
    CHUMP=./target/debug/chump
fi
echo "[unknown-subcmd-guard] using: $CHUMP"

fail=0

# 1. A typo'd subcommand must exit non-zero.
out="$("$CHUMP" zzznotacommand 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: 'chump zzznotacommand' exited 0 (must be non-zero)"; fail=1
else
    echo "PASS: 'chump zzznotacommand' exited $rc (non-zero)"
fi

# 2. It must NOT hallucinate a model reply.
if printf '%s' "$out" | grep -q 'Response from Agent'; then
    echo "FAIL: unknown subcommand routed to the model ('Response from Agent' present)"; fail=1
else
    echo "PASS: no model hallucination on unknown subcommand"
fi

# 3. It must say 'unknown subcommand'.
if printf '%s' "$out" | grep -q 'unknown subcommand'; then
    echo "PASS: prints 'unknown subcommand'"
else
    echo "FAIL: missing 'unknown subcommand' message"; fail=1
fi

# 4. A real flag (--version) must still work (exit 0) — guard must not over-match.
if "$CHUMP" --version >/dev/null 2>&1; then
    echo "PASS: 'chump --version' still exits 0"
else
    echo "FAIL: 'chump --version' regressed"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "OK: unknown-subcommand guard (CREDIBLE-134) holds"
    exit 0
fi
exit 1
