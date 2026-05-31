#!/usr/bin/env bash
# scripts/ci/test-pr-shepherd-launchd-emission.sh — META-248
#
# Smoke test: kickstart the pr-shepherd launchd job and assert that at least
# one new event lands in ambient.jsonl within 15 seconds.
#
# This validates the META-248 keystone fix: CHUMP_AMBIENT_PATH env var in the
# plist ensures the daemon writes to the MAIN worktree's ambient.jsonl even
# when launchd resolves SCRIPT_DIR to a stale /tmp worktree.
#
# Usage:
#   bash scripts/ci/test-pr-shepherd-launchd-emission.sh
#
# Exit codes:
#   0 — at least 1 new event appeared in ambient.jsonl after kickstart
#   1 — no new events within timeout (daemon not emitting — plist bug)
#   2 — daemon not installed (skip gracefully in CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LABEL="com.chump.pr-shepherd"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
TIMEOUT_S=15
UID_VAL="$(id -u)"

# --- check daemon is installed ---
if ! launchctl list 2>/dev/null | grep -q "$LABEL"; then
    echo "[SKIP] $LABEL not loaded — install via scripts/setup/install-pr-shepherd-daemon.sh first" >&2
    exit 2
fi

# --- baseline ---
pre=0
if [[ -f "$AMBIENT" ]]; then
    pre=$(wc -l < "$AMBIENT")
fi
echo "[test-pr-shepherd-launchd-emission] baseline: $pre lines in ambient.jsonl"

# --- kickstart a fresh tick ---
launchctl kickstart -k "gui/${UID_VAL}/${LABEL}" 2>/dev/null || {
    echo "WARN: kickstart failed — trying kill signal instead" >&2
    launchctl kill TERM "gui/${UID_VAL}/${LABEL}" 2>/dev/null || true
}

# --- poll until delta >= 1 or timeout ---
elapsed=0
delta=0
while [[ $elapsed -lt $TIMEOUT_S ]]; do
    sleep 2
    elapsed=$((elapsed + 2))
    post=0
    if [[ -f "$AMBIENT" ]]; then
        post=$(wc -l < "$AMBIENT")
    fi
    delta=$((post - pre))
    echo "[test-pr-shepherd-launchd-emission] +${elapsed}s: delta=${delta} lines"
    if [[ $delta -ge 1 ]]; then
        break
    fi
done

if [[ $delta -ge 1 ]]; then
    echo "[PASS] pr-shepherd launchd emission: delta=${delta} events in ${elapsed}s"
    exit 0
else
    echo "[FAIL] pr-shepherd launchd emission: 0 new events in ${TIMEOUT_S}s — ambient path likely wrong" >&2
    echo "  Expected ambient file: $AMBIENT" >&2
    echo "  Installed plist: $HOME/Library/LaunchAgents/${LABEL}.plist" >&2
    echo "  Check CHUMP_AMBIENT_PATH in the plist EnvironmentVariables block." >&2
    exit 1
fi
