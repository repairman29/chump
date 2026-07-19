#!/usr/bin/env bash
# install-integrator-daemon.sh — INFRA-2130 SCALE-A
#
# Idempotent installer for the chump-integrator-daemon launchd user agent.
# Installs com.chump.integrator-daemon.plist into ~/Library/LaunchAgents/
# with binary path, repo root, HOME, and log dir substituted.
#
# Default install is DRY-RUN (CHUMP_INTEGRATOR_LIVE=0). To enable LIVE mode
# the operator must pass --live or manually edit the installed plist and set
# CHUMP_INTEGRATOR_LIVE to 1, then reload.
#
# Usage:
#   install-integrator-daemon.sh               — install (idempotent, dry-run)
#   install-integrator-daemon.sh --live        — install + enable LIVE mode
#   install-integrator-daemon.sh --uninstall   — stop + remove plist
#   install-integrator-daemon.sh --status      — print launchctl status
#   install-integrator-daemon.sh --check       — exit 0 if installed, else 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-168: refuse to bake a temp-clone path into a persistent plist.
# The June outage's merge-queue-monitor pointed at /private/tmp/chump-install/
# which evaporated on reboot (exit 78 forever). Override: CHUMP_INSTALL_ALLOW_TMP=1.
case "$REPO_ROOT" in
    /tmp/*|/private/tmp/*|/var/folders/*)
        if [[ "${CHUMP_INSTALL_ALLOW_TMP:-0}" != "1" ]]; then
            echo "ERROR: refusing to install a persistent daemon from temp path $REPO_ROOT" >&2
            echo "  (plists baked from temp clones die on cleanup — run from the canonical checkout," >&2
            echo "   or set CHUMP_INSTALL_ALLOW_TMP=1 if you really mean it)" >&2
            exit 1
        fi
        ;;
esac

PLIST_TEMPLATE="$REPO_ROOT/.chump/launchd/com.chump.integrator-daemon.plist"
LABEL="com.chump.integrator-daemon"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
INSTALLED_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/.chump/logs"
UID_VAL="$(id -u)"
CARGO_BIN="${HOME}/.cargo/bin"

# ── resolve chump-integrator binary ──────────────────────────────────────────
_find_integrator() {
    if [[ -n "${CHUMP_INTEGRATOR_BIN:-}" ]] && [[ -x "$CHUMP_INTEGRATOR_BIN" ]]; then
        printf '%s' "$CHUMP_INTEGRATOR_BIN"
        return 0
    fi
    for candidate in \
        "$REPO_ROOT/target/release/chump-integrator" \
        "$REPO_ROOT/target/debug/chump-integrator" \
        "$CARGO_BIN/chump-integrator"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v chump-integrator &>/dev/null; then
        command -v chump-integrator
        return 0
    fi
    return 1
}

# ── launchctl helpers ─────────────────────────────────────────────────────────
_lctl_domain="gui/${UID_VAL}"
_lctl_svc="${_lctl_domain}/${LABEL}"

_is_loaded() {
    launchctl print "$_lctl_svc" &>/dev/null
}

_load_plist() {
    # RESILIENT-168: a service disabled in launchd's override DB survives every
    # reinstall — bootstrap silently fails (rc=5) and the daemon stays dead
    # through months of "fixes". Enable first, always.
    launchctl enable "$_lctl_svc" 2>/dev/null || true
    launchctl bootstrap "$_lctl_domain" "$INSTALLED_PLIST" 2>/dev/null || true
}

_unload_plist() {
    if _is_loaded; then
        launchctl bootout "$_lctl_domain" "$INSTALLED_PLIST" 2>/dev/null || \
            launchctl remove "$LABEL" 2>/dev/null || true
    fi
}

# ── subcommands ───────────────────────────────────────────────────────────────
LIVE_MODE=0
cmd="install"

for arg in "$@"; do
    case "$arg" in
        --live)       LIVE_MODE=1 ;;
        --uninstall)  cmd="uninstall" ;;
        --status)     cmd="status" ;;
        --check)      cmd="check" ;;
        install)      cmd="install" ;;
        *)
            echo "[install-integrator-daemon] unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

case "$cmd" in
    uninstall)
        echo "[install-integrator-daemon] Uninstalling ${LABEL}..."
        _unload_plist
        if [[ -f "$INSTALLED_PLIST" ]]; then
            rm -f "$INSTALLED_PLIST"
            echo "[install-integrator-daemon] Removed ${INSTALLED_PLIST}"
        fi
        echo "[install-integrator-daemon] Done."
        exit 0
        ;;

    status)
        if _is_loaded; then
            launchctl print "$_lctl_svc"
        else
            echo "[install-integrator-daemon] ${LABEL} is NOT loaded."
            exit 1
        fi
        exit 0
        ;;

    check)
        if _is_loaded; then
            echo "[install-integrator-daemon] ${LABEL} is installed and loaded."
            exit 0
        else
            echo "[install-integrator-daemon] ${LABEL} is NOT loaded."
            exit 1
        fi
        ;;

    install)
        ;;  # fall through to install logic below
esac

# ── verify template exists ────────────────────────────────────────────────────
if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    echo "[install-integrator-daemon] ERROR: plist template not found: $PLIST_TEMPLATE" >&2
    exit 1
fi

# ── resolve binary (warn if missing; install anyway for forward-compat) ───────
INTEGRATOR_BIN=""
if INTEGRATOR_BIN="$(_find_integrator)"; then
    echo "[install-integrator-daemon] Found binary: ${INTEGRATOR_BIN}"
else
    echo "[install-integrator-daemon] WARNING: chump-integrator binary not found." >&2
    echo "[install-integrator-daemon]   Build with: cargo build --release --bin chump-integrator" >&2
    echo "[install-integrator-daemon]   Proceeding with CARGO_BIN path (will fail at runtime until built)." >&2
    INTEGRATOR_BIN="${CARGO_BIN}/chump-integrator"
fi

# ── create log directory ──────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

# ── substitute placeholders in plist template ─────────────────────────────────
mkdir -p "$LAUNCH_AGENTS_DIR"

# INFRA-2302: substitute __CARGO_BIN__ with the DIRECTORY of the binary we
# actually found (via _find_integrator above), not the $CARGO_BIN env default.
# The default ~/.cargo/bin/chump-integrator is only correct for cargo-installed
# global binaries — most installs find the binary at target/{debug,release}/.
INTEGRATOR_BIN_DIR="$(dirname "$INTEGRATOR_BIN")"
sed \
    -e "s|__REPO_ROOT__|${REPO_ROOT}|g" \
    -e "s|__CARGO_BIN__|${INTEGRATOR_BIN_DIR}|g" \
    -e "s|__HOME__|${HOME}|g" \
    "$PLIST_TEMPLATE" > "$INSTALLED_PLIST"

# Apply --live flag: flip CHUMP_INTEGRATOR_LIVE from 0 to 1.
if [[ "$LIVE_MODE" -eq 1 ]]; then
    echo "[install-integrator-daemon] LIVE mode enabled (CHUMP_INTEGRATOR_LIVE=1)."
    echo "[install-integrator-daemon] WARNING: daemon will push branches and open PRs."
    # Replace the string value for CHUMP_INTEGRATOR_LIVE key.
    # The plist has: <key>CHUMP_INTEGRATOR_LIVE</key>\n<string>0</string>
    # Use python for reliable plist mutation without external deps.
    python3 - "$INSTALLED_PLIST" <<'PYEOF'
import sys, plistlib, pathlib
p = pathlib.Path(sys.argv[1])
with p.open('rb') as f:
    data = plistlib.load(f)
env = data.get('EnvironmentVariables', {})
env['CHUMP_INTEGRATOR_LIVE'] = '1'
data['EnvironmentVariables'] = env
with p.open('wb') as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_XML, sort_keys=False)
print(f"[install-integrator-daemon] Wrote LIVE=1 into {p}")
PYEOF
fi

# ── (re)load the plist ────────────────────────────────────────────────────────
if _is_loaded; then
    echo "[install-integrator-daemon] Reloading ${LABEL}..."
    _unload_plist
fi

_load_plist

# RunAtLoad=false so the daemon doesn't fire on first load.
# Operator starts the first cycle manually or waits for StartInterval.
echo "[install-integrator-daemon] Installed: ${INSTALLED_PLIST}"

LIVE_STATUS="DRY-RUN (safe default)"
[[ "$LIVE_MODE" -eq 1 ]] && LIVE_STATUS="LIVE (operator opted in)"
echo "[install-integrator-daemon] Mode: ${LIVE_STATUS}"
echo "[install-integrator-daemon] Cadence: every 15 minutes (StartInterval=900)"
echo "[install-integrator-daemon] Logs: ${LOG_DIR}/integrator-daemon.{out,err}"
echo "[install-integrator-daemon] Status: launchctl print ${_lctl_svc}"
echo ""
if [[ "$LIVE_MODE" -eq 0 ]]; then
    echo "[install-integrator-daemon] To enable LIVE mode later:"
    echo "    $0 --uninstall && $0 --live"
    echo "  OR set CHUMP_INTEGRATOR_LIVE=1 in the environment and reload."
fi
echo "[install-integrator-daemon] Done."
