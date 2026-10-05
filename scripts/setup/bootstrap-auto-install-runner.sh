#!/usr/bin/env bash
# bootstrap-auto-install-runner.sh — INFRA-1808
#
# Invoked hourly by the com.chump.bootstrap-auto-install LaunchAgent
# (scripts/setup/install-bootstrap-auto-launchd.sh). Runs
# chump-fleet-bootstrap.sh --install, then a --check pass to count what's
# still missing, and emits a single kind=fleet_bootstrap_auto_install
# ambient event per run so the auto-install cadence is auditable the same
# way every other launchd daemon's activity is.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# CHUMP_BOOTSTRAP_SCRIPT override lets scripts/ci/test-bootstrap-auto-install.sh
# point this at a stub script without touching the real installer state.
BOOTSTRAP="${CHUMP_BOOTSTRAP_SCRIPT:-$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

INSTALL_OUT="$(bash "$BOOTSTRAP" --install 2>&1)"
INSTALLED_COUNT="$(printf '%s\n' "$INSTALL_OUT" | grep -oE '^=== bootstrap done: [0-9]+ installed' | grep -oE '[0-9]+' | head -1)"
INSTALLED_COUNT="${INSTALLED_COUNT:-0}"

CHECK_OUT="$(bash "$BOOTSTRAP" --check 2>&1)"
MANIFEST_MISSING="$(printf '%s\n' "$CHECK_OUT" | grep -oE '[0-9]+ manifest-missing' | grep -oE '^[0-9]+' | head -1)"
MANIFEST_MISSING="${MANIFEST_MISSING:-0}"
DAEMON_MISSING="$(printf '%s\n' "$CHECK_OUT" | grep -oE '[0-9]+ daemon-missing' | grep -oE '^[0-9]+' | head -1)"
DAEMON_MISSING="${DAEMON_MISSING:-0}"

if [[ -d "$(dirname "$AMBIENT")" ]]; then
    printf '{"ts":"%s","kind":"fleet_bootstrap_auto_install","installed_count":%d,"manifest_missing_count":%d,"daemon_missing_count":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$INSTALLED_COUNT" \
        "$MANIFEST_MISSING" \
        "$DAEMON_MISSING" \
        >> "$AMBIENT" 2>/dev/null || true
fi

echo "[bootstrap-auto-install] installed=$INSTALLED_COUNT manifest_missing=$MANIFEST_MISSING daemon_missing=$DAEMON_MISSING"
exit 0
