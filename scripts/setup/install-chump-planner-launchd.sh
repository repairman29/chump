#!/usr/bin/env bash
# install-chump-planner-launchd.sh — INFRA-1257
#
# Installs a launchd plist that runs `chump-plan --format json` hourly,
# writing the ranked-gaps output to .chump-locks/gap-priority.json. The
# fleet picker (INFRA-1258) consumes this file to pick the best-scored
# gap available, rather than the first-matching one.
#
# Idempotent: re-running the installer overwrites the plist with the
# latest content + restarts the agent. Safe to run from CI.
#
# Usage:
#   bash scripts/setup/install-chump-planner-launchd.sh
#   bash scripts/setup/install-chump-planner-launchd.sh --uninstall
#   bash scripts/setup/install-chump-planner-launchd.sh --once    # one-shot run
#
# Env:
#   CHUMP_PLANNER_INTERVAL_S   override interval (default 3600 = 1h)
#   CHUMP_PLANNER_BIN          override chump-plan binary path
#   CHUMP_PLANNER_REPO_ROOT    override repo root (default: $(git rev-parse --show-toplevel))

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_PLANNER_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LABEL="dev.chump.planner"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs"
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$PLIST")"

# Resolve chump-plan binary — prefer cargo-installed path, fall back to
# the workspace target/debug version for fresh installs.
BIN="${CHUMP_PLANNER_BIN:-}"
if [[ -z "$BIN" ]]; then
    if command -v chump-plan >/dev/null 2>&1; then
        BIN="$(command -v chump-plan)"
    elif [[ -x "$REPO_ROOT/target/release/chump-plan" ]]; then
        BIN="$REPO_ROOT/target/release/chump-plan"
    elif [[ -x "$REPO_ROOT/target/debug/chump-plan" ]]; then
        BIN="$REPO_ROOT/target/debug/chump-plan"
    else
        echo "ERROR: chump-plan binary not found. Build it first with:" >&2
        echo "  cargo install --path $REPO_ROOT/crates/chump-planner --bin chump-plan" >&2
        echo "Or build into target/: cargo build --release -p chump-planner --bin chump-plan" >&2
        exit 1
    fi
fi

INTERVAL="${CHUMP_PLANNER_INTERVAL_S:-3600}"
GAPS_DIR="$REPO_ROOT/docs/gaps"
OUT_FILE="$REPO_ROOT/.chump-locks/gap-priority.json"
TMP_FILE="$OUT_FILE.tmp"

# --once: run a single iteration immediately and exit. Used by install and CI.
if [[ "${1:-}" == "--once" ]]; then
    echo "[chump-planner] one-shot: $BIN --gaps $GAPS_DIR --format json --agents 5" >&2
    mkdir -p "$(dirname "$OUT_FILE")"
    if "$BIN" --gaps "$GAPS_DIR" --format json --agents 5 > "$TMP_FILE"; then
        mv "$TMP_FILE" "$OUT_FILE"
        echo "[chump-planner] wrote $OUT_FILE ($(wc -c < "$OUT_FILE" | tr -d ' ') bytes)" >&2
    else
        rc=$?
        rm -f "$TMP_FILE"
        echo "[chump-planner] FAILED (rc=$rc)" >&2
        exit "$rc"
    fi
    # Ambient emit so the operator can see the run in the audit trail.
    if [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
        bash "$REPO_ROOT/scripts/dev/ambient-emit.sh" planner_rank_ran \
            out_file="$OUT_FILE" >/dev/null 2>&1 || true
    fi
    exit 0
fi

# --uninstall: tear down the agent and remove the plist.
if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "[chump-planner] uninstalled $PLIST"
    exit 0
fi

# Default: write the plist + bootstrap the agent.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/install-chump-planner-launchd.sh</string>
        <string>--once</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CHUMP_PLANNER_BIN</key>
        <string>${BIN}</string>
        <key>CHUMP_PLANNER_REPO_ROOT</key>
        <string>${REPO_ROOT}</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
    </dict>
    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/chump-planner.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/chump-planner.err.log</string>
</dict>
</plist>
EOF

echo "[chump-planner] wrote $PLIST"

# Boot the agent. bootstrap-then-kickstart so it loads even if a previous
# version is already running.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

echo "[chump-planner] installed; runs every ${INTERVAL}s; out=${OUT_FILE}"
echo "[chump-planner] logs: $LOG_DIR/chump-planner.{out,err}.log"
echo "[chump-planner] verify: launchctl list | grep ${LABEL}"
