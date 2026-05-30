#!/usr/bin/env bash
# scripts/coord/daemon-activator-loop.sh — META-225
#
# Daemon-activator: polls last 24h of main commits for newly-shipped
# installers/plists and activates them if not already loaded.
#
# On first tick it detects itself + ghost-pr-closer + main-worktree-drift-detector
# (since they all ship in this PR together) and validates they're loaded.
#
# Emission kinds:
# scanner-anchor: "kind":"daemon_auto_activated"
# scanner-anchor: "kind":"daemon_activator_failed"
#
# Usage:
#   bash scripts/coord/daemon-activator-loop.sh [--dry-run]
#
# Env knobs:
#   CHUMP_DAEMON_ACTIVATOR_AMBIENT_FILE  — override ambient.jsonl path (tests)
#   CHUMP_DAEMON_ACTIVATOR_STATE_FILE    — override state.json path (tests)
#   CHUMP_DAEMON_ACTIVATOR_DRY_RUN       — set to 1 to skip launchctl (tests)
#   CHUMP_DAEMON_ACTIVATOR_GIT_LOG       — path to fixture file (tests only)
#   CHUMP_DAEMON_ACTIVATOR_LAUNCHCTL_CMD — override launchctl (tests only)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR/../.." && pwd))"

_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$(dirname "$_GIT_COMMON")" && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="$MAIN_REPO/.chump"
mkdir -p "$LOCK_DIR" "$CHUMP_DIR"

# ── Configuration ─────────────────────────────────────────────────────────────
AMBIENT="${CHUMP_DAEMON_ACTIVATOR_AMBIENT_FILE:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="${CHUMP_DAEMON_ACTIVATOR_STATE_FILE:-$CHUMP_DIR/daemon-activator-state.json}"
DRY_RUN="${CHUMP_DAEMON_ACTIVATOR_DRY_RUN:-0}"
LAUNCHCTL="${CHUMP_DAEMON_ACTIVATOR_LAUNCHCTL_CMD:-launchctl}"

for _a in "$@"; do
    case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[daemon-activator] %s\n' "$*"; }

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

# label_is_loaded LABEL — check if launchd label is currently loaded.
label_is_loaded() {
    local label="$1"
    "$LAUNCHCTL" list 2>/dev/null | grep -qE "^[0-9-]*[[:space:]]+[0-9-]*[[:space:]]+${label}$"
}

# extract_label INSTALL_SCRIPT — extract LABEL="..." from install script.
extract_label() {
    local script="$1"
    grep -oE 'LABEL="[^"]+"' "$script" 2>/dev/null | head -1 | sed 's/LABEL="//;s/"$//'
}

# extract_pr — read commit subject from stdin, extract PR number from "(#NNN)" suffix.
extract_pr() {
    grep -oE '\(#[0-9]+\)' | head -1 | tr -d '(#)'
}

# read_activated_labels — return JSON array of activated labels from state.
read_activated_labels() {
    if [[ -f "$STATE_FILE" ]]; then
        python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(' '.join(d.get('activated_labels', [])))
except Exception:
    print('')
" 2>/dev/null || true
    fi
}

# write_state LAST_SHA LABELS_ARRAY
write_state() {
    local sha="$1"
    shift
    python3 - "$STATE_FILE" "$sha" "$@" <<'PYEOF'
import json, sys
path, sha = sys.argv[1], sys.argv[2]
labels = list(sys.argv[3:])
try:
    d = json.load(open(path))
except Exception:
    d = {}
d['last_scan_sha'] = sha
d['activated_labels'] = sorted(set(d.get('activated_labels', []) + labels))
open(path, 'w').write(json.dumps(d, indent=2) + '\n')
PYEOF
}

# ── Step 1: Fetch origin/main ─────────────────────────────────────────────────
log "Fetching origin/main..."
git -C "$REPO_ROOT" fetch origin main --quiet 2>/dev/null || true

CURRENT_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || echo "unknown")"

# ── Step 2: List changed files in last 24h on origin/main ────────────────────
if [[ -n "${CHUMP_DAEMON_ACTIVATOR_GIT_LOG:-}" ]]; then
    CHANGED_FILES="$(cat "$CHUMP_DAEMON_ACTIVATOR_GIT_LOG")"
else
    CHANGED_FILES="$(git -C "$REPO_ROOT" log \
        --name-only \
        --since="24 hours ago" \
        --pretty=format: \
        origin/main 2>/dev/null | sort -u | grep -v '^$')"
fi

if [[ -z "$CHANGED_FILES" ]]; then
    log "No files changed in origin/main in the last 24h — nothing to activate."
    exit 0
fi

# ── Step 3: Filter to install-*.sh and *.plist files ─────────────────────────
INSTALL_SCRIPTS="$(printf '%s\n' "$CHANGED_FILES" | grep -E '^scripts/setup/install-[^/]+\.sh$' || true)"
PLIST_FILES="$(printf '%s\n' "$CHANGED_FILES" | grep -E '^scripts/launchd/[^/]+\.plist$' || true)"

# Collect all installer candidates
ALL_INSTALL_SCRIPTS="$INSTALL_SCRIPTS"

# If a plist appeared without a corresponding installer, try to find the installer
while IFS= read -r plist; do
    [[ -z "$plist" ]] && continue
    # Derive installer name from plist label: com.chump.foo-bar -> install-foo-bar.sh
    basename_plist="$(basename "$plist" .plist)"
    label_suffix="${basename_plist#com.chump.}"
    candidate_install="scripts/setup/install-${label_suffix}.sh"
    if ! echo "$ALL_INSTALL_SCRIPTS" | grep -q "$candidate_install"; then
        ALL_INSTALL_SCRIPTS="$ALL_INSTALL_SCRIPTS
$candidate_install"
    fi
done <<< "$PLIST_FILES"

ALL_INSTALL_SCRIPTS="$(printf '%s\n' "$ALL_INSTALL_SCRIPTS" | sort -u | grep -v '^$' || true)"

if [[ -z "$ALL_INSTALL_SCRIPTS" ]]; then
    log "No new install scripts or plists detected in last 24h."
    exit 0
fi

log "Found install candidates:"
printf '%s\n' "$ALL_INSTALL_SCRIPTS" | sed 's/^/  /'

# ── Step 4: Load activated labels from state ─────────────────────────────────
ALREADY_ACTIVATED="$(read_activated_labels)"
NEWLY_ACTIVATED=()

# ── Step 5: Process each install script ──────────────────────────────────────
while IFS= read -r install_script; do
    [[ -z "$install_script" ]] && continue
    log "Processing: $install_script"

    # Resolve local path
    LOCAL_PATH="$REPO_ROOT/$install_script"

    # Get label from script content
    label=""
    if [[ -f "$LOCAL_PATH" ]]; then
        label="$(extract_label "$LOCAL_PATH")"
    fi
    if [[ -z "$label" ]]; then
        # Try fetching from origin/main
        REMOTE_CONTENT="$(git -C "$REPO_ROOT" show "origin/main:$install_script" 2>/dev/null || true)"
        if [[ -n "$REMOTE_CONTENT" ]]; then
            label="$(printf '%s' "$REMOTE_CONTENT" | grep -oE 'LABEL="[^"]+"' | head -1 | sed 's/LABEL="//;s/"$//')"
        fi
    fi

    if [[ -z "$label" ]]; then
        log "  WARN: could not derive label from $install_script — skipping"
        continue
    fi

    log "  label=$label"

    # Skip if already activated in a previous run
    if echo "$ALREADY_ACTIVATED" | grep -qw "$label"; then
        log "  SKIP: $label was already activated in a previous run"
        # Still verify it's loaded; if not, attempt re-activation
        if label_is_loaded "$label"; then
            log "  Confirmed still loaded — skip"
            continue
        fi
        log "  WARN: was activated but not loaded — re-activating"
    fi

    # Check if already loaded
    if label_is_loaded "$label"; then
        log "  SKIP: $label already loaded"
        continue
    fi

    # ── Activate: run installer ───────────────────────────────────────────────
    # Extract source_pr from recent commit subjects mentioning this script
    source_pr="$(git -C "$REPO_ROOT" log --since="24 hours ago" --pretty="%s" origin/main 2>/dev/null \
        | grep -m1 "$install_script\|$(basename "$install_script" .sh)" \
        | extract_pr || true)"

    if (( DRY_RUN )); then
        log "  DRY-RUN: would run installer for $label"
        continue
    fi

    log "  Activating $label..."
    install_ok=0
    install_error=""

    # Ensure local copy matches origin/main (robust to dirty worktree)
    if git -C "$REPO_ROOT" show "origin/main:$install_script" > "$LOCAL_PATH" 2>/dev/null; then
        chmod +x "$LOCAL_PATH"
        if bash "$LOCAL_PATH" 2>&1; then
            install_ok=1
        else
            install_error="installer exited non-zero"
        fi
    else
        install_error="could not extract $install_script from origin/main"
    fi

    if (( install_ok )); then
        log "  OK: $label activated"
        pr_field=""
        [[ -n "$source_pr" ]] && pr_field="\"source_pr\":\"$source_pr\","
        emit "daemon_auto_activated" "\"label\":\"$label\",${pr_field}\"install_script\":\"$install_script\",\"ts\":\"$(_ts)\""
        NEWLY_ACTIVATED+=("$label")
    else
        log "  FAIL: $label — $install_error"
        emit "daemon_activator_failed" "\"label\":\"$label\",\"install_script\":\"$install_script\",\"error\":\"$install_error\""
    fi

done <<< "$ALL_INSTALL_SCRIPTS"

# ── Step 6: Update state ──────────────────────────────────────────────────────
if (( ${#NEWLY_ACTIVATED[@]} > 0 )); then
    write_state "$CURRENT_SHA" "${NEWLY_ACTIVATED[@]}"
    log "State updated: activated ${#NEWLY_ACTIVATED[@]} new label(s)"
fi

log "done"
exit 0
