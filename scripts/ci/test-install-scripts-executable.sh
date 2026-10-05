#!/usr/bin/env bash
# test-install-scripts-executable.sh — INFRA-1808
#
# Asserts every scripts/setup/install-*.sh file is mode 0755 (owner-exec bit
# set). Prevents recurrence of install-bot-merge-watchdog.sh shipping as
# 0644 and silently never running via chump-fleet-bootstrap.sh, which sat
# undetected for days (2026-05-23, curator-opus-shepherd).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP_DIR="$REPO_ROOT/scripts/setup"

PASS=0
FAIL=0
FAILS=()

echo "=== INFRA-1808 install-*.sh executable-bit gate ==="

shopt -s nullglob
files=("$SETUP_DIR"/install-*.sh)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
    echo "FATAL: no install-*.sh files found under $SETUP_DIR"
    exit 2
fi

for f in "${files[@]}"; do
    if [[ -x "$f" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILS+=("${f#"$REPO_ROOT"/} is not executable ($(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo '?'))")
    fi
done

echo
echo "=== Summary: $PASS executable, $FAIL not executable (of ${#files[@]} install-*.sh) ==="
if (( FAIL > 0 )); then
    echo "FAILURES:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    echo
    echo "Fix: chmod +x <file>"
    exit 1
fi
echo "PASS"
