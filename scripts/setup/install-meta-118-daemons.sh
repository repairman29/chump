#!/usr/bin/env bash
# scripts/setup/install-meta-118-daemons.sh — INFRA-2280
#
# Installs 2 launchd user agents that activate the META-118 scheduling chain:
#
#   com.chump.novel-wedge-classifier   — every 15 min (StartInterval 900s)
#     runs: scripts/coord/novel-wedge-classifier.sh
#
#   com.chump.cascade-unblock-detector — every 5 min (StartInterval 300s)
#     runs: scripts/coord/cascade-unblock-detector.sh
#
# Both plists install to ~/Library/LaunchAgents/.
# Logs go to ~/Library/Logs/chump/ (created on first install).
#
# Usage:
#   bash scripts/setup/install-meta-118-daemons.sh           # install
#   bash scripts/setup/install-meta-118-daemons.sh --dry-run # generate plists, don't load
#   bash scripts/setup/install-meta-118-daemons.sh --check   # exit 0 if both loaded
#   bash scripts/setup/install-meta-118-daemons.sh --uninstall
#
# Idempotent: re-running unloads + reloads cleanly.
#
# Kill switch (no plist edit needed):
#   CHUMP_META118_SKIP=1 set in env prevents both scripts from running at tick time.
#   To completely stop a daemon: launchctl unload ~/Library/LaunchAgents/<label>.plist

set -euo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PLIST_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/chump"

CLASSIFIER_LABEL="com.chump.novel-wedge-classifier"
CLASSIFIER_SCRIPT="$REPO_ROOT/scripts/coord/novel-wedge-classifier.sh"
CLASSIFIER_PLIST="$PLIST_DIR/${CLASSIFIER_LABEL}.plist"
CLASSIFIER_LOG="$LOG_DIR/novel-wedge-classifier.log"
CLASSIFIER_INTERVAL=900

UNBLOCK_LABEL="com.chump.cascade-unblock-detector"
UNBLOCK_SCRIPT="$REPO_ROOT/scripts/coord/cascade-unblock-detector.sh"
UNBLOCK_PLIST="$PLIST_DIR/${UNBLOCK_LABEL}.plist"
UNBLOCK_LOG="$LOG_DIR/cascade-unblock-detector.log"
UNBLOCK_INTERVAL=300

DRY_RUN=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --check)
            loaded_ok=0
            for label in "$CLASSIFIER_LABEL" "$UNBLOCK_LABEL"; do
                if launchctl list 2>/dev/null | grep -qE "[[:space:]]${label}$"; then
                    echo "  ok      $label"
                else
                    echo "  MISSING $label  (run: bash $0)"
                    loaded_ok=1
                fi
            done
            exit $loaded_ok
            ;;
        --help|-h)
            sed -n '2,26p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

log() { printf '[install-meta-118-daemons] %s\n' "$*"; }

# ── Uninstall ──────────────────────────────────────────────────────────────────

if [[ "$UNINSTALL" == "1" ]]; then
    for plist in "$CLASSIFIER_PLIST" "$UNBLOCK_PLIST"; do
        if [[ -f "$plist" ]]; then
            launchctl unload "$plist" 2>/dev/null || true
            rm -f "$plist"
            log "removed $plist"
        fi
    done
    log "uninstall complete"
    exit 0
fi

# ── Validate sources ───────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "0" ]]; then
    # In install mode, both scripts must exist and be executable.
    for s in "$CLASSIFIER_SCRIPT" "$UNBLOCK_SCRIPT"; do
        if [[ ! -x "$s" ]]; then
            log "ERROR: missing/non-executable: $s" >&2
            exit 1
        fi
    done
fi

mkdir -p "$PLIST_DIR" "$LOG_DIR"

# ── Build plist helper ─────────────────────────────────────────────────────────

write_plist() {
    local label="$1"
    local script="$2"
    local plist="$3"
    local logfile="$4"
    local interval="$5"

    cat > "$plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_ROOT}</string>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${logfile}</string>
    <key>StandardErrorPath</key>
    <string>${logfile}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:${HOME}/.cargo/bin</string>
        <key>CHUMP_REPO_ROOT</key>
        <string>${REPO_ROOT}</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <!-- INFRA-2340: auth pass-through for headless claude -p subprocesses. -->
        <key>CLAUDE_CODE_OAUTH_TOKEN</key>
        <string>${CLAUDE_CODE_OAUTH_TOKEN:-}</string>
        <key>ANTHROPIC_API_KEY</key>
        <string>${ANTHROPIC_API_KEY:-}</string>
    </dict>
</dict>
</plist>
PLIST_EOF
}

# ── com.chump.novel-wedge-classifier (900s / 15min) ───────────────────────────

write_plist "$CLASSIFIER_LABEL" "$CLASSIFIER_SCRIPT" \
    "$CLASSIFIER_PLIST" "$CLASSIFIER_LOG" "$CLASSIFIER_INTERVAL"

if [[ "$DRY_RUN" == "0" ]]; then
    launchctl unload "$CLASSIFIER_PLIST" 2>/dev/null || true
    launchctl load -w "$CLASSIFIER_PLIST"
    log "installed $CLASSIFIER_LABEL (${CLASSIFIER_INTERVAL}s / 15-min cadence)"
else
    log "dry-run: plist written to $CLASSIFIER_PLIST (not loaded)"
fi

# ── com.chump.cascade-unblock-detector (300s / 5min) ──────────────────────────

write_plist "$UNBLOCK_LABEL" "$UNBLOCK_SCRIPT" \
    "$UNBLOCK_PLIST" "$UNBLOCK_LOG" "$UNBLOCK_INTERVAL"

if [[ "$DRY_RUN" == "0" ]]; then
    launchctl unload "$UNBLOCK_PLIST" 2>/dev/null || true
    launchctl load -w "$UNBLOCK_PLIST"
    log "installed $UNBLOCK_LABEL (${UNBLOCK_INTERVAL}s / 5-min cadence)"
else
    log "dry-run: plist written to $UNBLOCK_PLIST (not loaded)"
fi

# ── Ambient emit ───────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "0" ]]; then
    AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"meta_118_daemon_started","source":"install-meta-118-daemons","labels":["%s","%s"]}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$CLASSIFIER_LABEL" \
        "$UNBLOCK_LABEL" \
        >> "$AMBIENT" 2>/dev/null || true
fi

# ── Summary ────────────────────────────────────────────────────────────────────

log "inspect novel-wedge-classifier:  launchctl print gui/$(id -u)/${CLASSIFIER_LABEL}"
log "inspect cascade-unblock-detector: launchctl print gui/$(id -u)/${UNBLOCK_LABEL}"
log "logs: tail -f $CLASSIFIER_LOG"
log "logs: tail -f $UNBLOCK_LOG"
log "stop:  launchctl unload $CLASSIFIER_PLIST"
log "stop:  launchctl unload $UNBLOCK_PLIST"
