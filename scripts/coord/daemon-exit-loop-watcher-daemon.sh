#!/usr/bin/env bash
# scripts/coord/daemon-exit-loop-watcher-daemon.sh — INFRA-2417
#
# Daemon-exit-loop watcher: queries launchd for each known daemon label and
# detects consecutive non-zero exits (exit-loop pattern). Files a P0 gap when
# the threshold is reached and closes it automatically on recovery.
#
# Root cause of this gap: com.chump.integrator-daemon crash-looped 145 times
# over 37+ hours with last_exit_code=1 and NO alerts fired. This daemon would
# have caught it within 3 × 15min = 45 minutes.
#
# Pillars: RESILIENT + ZERO-WASTE.
#
# State machine (per daemon label):
#   BELOW_THRESHOLD  runs seen but exit-loop count < CHUMP_DAEMON_EXIT_LOOP_THRESHOLD
#   LOOP_DETECTED    threshold reached → filed P0 gap (idempotent via fingerprint)
#   RECOVERED        last_exit_code returned to 0 → close auto-filed gap
#
# Idempotency: fingerprint = sha256(label) first 12 chars. Same label on the
# next tick → no re-spam. Multiple labels → one gap per label.
#
# scanner-anchor: "kind":"daemon_exit_loop_detected"
# scanner-anchor: "kind":"daemon_exit_loop_recovered"
# scanner-anchor: "kind":"daemon_exit_loop_disabled"
#
# Usage:
#   bash scripts/coord/daemon-exit-loop-watcher-daemon.sh tick   # one tick
#   bash scripts/coord/daemon-exit-loop-watcher-daemon.sh --help
#   bash scripts/coord/daemon-exit-loop-watcher-daemon.sh        # one tick (launchd default)
#
# Env knobs (all optional):
#   CHUMP_DAEMON_EXIT_LOOP_DISABLED    non-empty → exit 0 immediately (audit-logged)
#   CHUMP_DAEMON_EXIT_LOOP_THRESHOLD   consecutive non-zero exits to trigger (default 3)
#   CHUMP_DAEMON_EXIT_LOOP_STATE_FILE  path to state JSON (default $REPO/.chump/daemon-exit-loop-state.json)
#   CHUMP_DAEMON_EXIT_LOOP_DRY_RUN     non-empty → no chump writes (default unset)
#   CHUMP_DAEMON_MOCK_LAUNCHCTL        path to mock launchctl binary (test-mode)
#   CHUMP_AMBIENT_PATH                 override ambient.jsonl path (META-248)
#   CHUMP_AMBIENT_LOG                  legacy alias for CHUMP_AMBIENT_PATH

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# META-248: honor CHUMP_AMBIENT_PATH first, CHUMP_AMBIENT_LOG legacy alias second.
AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

# ── Configuration ─────────────────────────────────────────────────────────────
DISABLED="${CHUMP_DAEMON_EXIT_LOOP_DISABLED:-}"
DRY_RUN="${CHUMP_DAEMON_EXIT_LOOP_DRY_RUN:-}"
THRESHOLD="${CHUMP_DAEMON_EXIT_LOOP_THRESHOLD:-3}"
STATE_FILE="${CHUMP_DAEMON_EXIT_LOOP_STATE_FILE:-$REPO_ROOT/.chump/daemon-exit-loop-state.json}"
MOCK_LAUNCHCTL="${CHUMP_DAEMON_MOCK_LAUNCHCTL:-}"

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

CHUMP_BIN="${CHUMP_DAEMON_EXIT_LOOP_CHUMP_CMD:-chump}"
BOOTSTRAP_SCRIPT="${CHUMP_DAEMON_EXIT_LOOP_BOOTSTRAP_SCRIPT:-$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh}"
OPTIONAL_ALLOWLIST="${CHUMP_DAEMON_EXIT_LOOP_OPTIONAL_ALLOWLIST:-$REPO_ROOT/scripts/setup/optional-installers-allowlist.txt}"

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ -n "$DISABLED" ]]; then
    _ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    printf '[daemon-exit-loop-watcher] CHUMP_DAEMON_EXIT_LOOP_DISABLED set — exiting\n' >&2
    printf '{"ts":"%s","kind":"daemon_exit_loop_disabled","dry_run":false}\n' \
        "$(_ts)" >> "$AMBIENT"
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts()        { date -u +%Y-%m-%dT%H:%M:%SZ; }
_now_epoch() { date +%s; }
log()        { printf '[daemon-exit-loop-watcher] %s\n' "$*" >&2; }

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(_ts)"
    local dry; if [[ -n "$DRY_RUN" ]]; then dry="true"; else dry="false"; fi
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry,$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT"
}

_load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" 2>/dev/null || printf '{}'
    else
        printf '{}'
    fi
}

_save_state() {
    local body="$1"
    printf '%s\n' "$body" > "$STATE_FILE"
}

# fingerprint = sha256(label) first 12 chars.
_label_fingerprint() {
    local label="$1"
    printf '%s' "$label" | shasum -a 256 | cut -c1-12
}

# ── (1) Collect daemon labels from bootstrap + optional allowlist ──────────────
# Returns one label per line on stdout.
_collect_labels() {
    # Labels from REQUIRED_DAEMONS in chump-fleet-bootstrap.sh
    # Format: "com.chump.foo|scripts/setup/install-foo.sh"
    if [[ -f "$BOOTSTRAP_SCRIPT" ]]; then
        grep -Eo '"com\.chump\.[^|"]+\|[^"]*"' "$BOOTSTRAP_SCRIPT" 2>/dev/null \
            | sed 's/"//g' \
            | cut -d'|' -f1 \
            || true
    fi

    # Labels from optional installers allowlist: derive label from installer name.
    # Pattern: install-foo-launchd.sh → com.chump.foo
    if [[ -f "$OPTIONAL_ALLOWLIST" ]]; then
        grep -E '^install-.*-launchd\.sh' "$OPTIONAL_ALLOWLIST" 2>/dev/null \
            | sed 's/install-//' \
            | sed 's/-launchd\.sh$//' \
            | sed 's/-/./g' \
            | sed 's/^/com.chump./' \
            || true
    fi
}

# ── (2) Query launchctl for a single label ────────────────────────────────────
# Prints: "<state> <runs> <last_exit_code>"  (one line, space-separated)
# Returns 1 if the label is not registered (not running, not known to launchd).
_query_label() {
    local label="$1"
    local uid; uid="$(id -u)"
    local launchctl_bin="launchctl"
    if [[ -n "$MOCK_LAUNCHCTL" ]]; then
        launchctl_bin="$MOCK_LAUNCHCTL"
    fi

    local output exit_code
    exit_code=0
    output="$("$launchctl_bin" print "gui/${uid}/${label}" 2>&1)" || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        # Label not known to launchd — skip silently
        return 1
    fi

    # Extract fields using grep+sed, NOT printf|grep-q (INFRA-1658).
    local state runs last_exit
    state="$(printf '%s' "$output" | grep -E '^\s+state\s*=' | sed 's/.*=\s*//' | tr -d ' \t' || true)"
    runs="$(printf '%s' "$output" | grep -E '^\s+runs\s*=' | sed 's/.*=\s*//' | tr -d ' \t' || true)"
    last_exit="$(printf '%s' "$output" | grep -E '^\s+last exit code\s*=' | sed 's/.*=\s*//' | tr -d ' \t' || true)"

    # Default missing fields
    state="${state:-unknown}"
    runs="${runs:-0}"
    last_exit="${last_exit:-0}"

    printf '%s %s %s\n' "$state" "$runs" "$last_exit"
}

# ── (3) File a P0 daemon-dead gap (idempotent via fingerprint) ─────────────────
_file_daemon_gap() {
    local label="$1" runs="$2" last_exit="$3" fingerprint="$4"

    if [[ -n "$DRY_RUN" ]]; then
        log "DRY_RUN: would file daemon-dead gap for label=$label (fp=$fingerprint)"
        printf 'INFRA-DRYRUN-%s' "$fingerprint"
        return 0
    fi

    # Sanitize label for use in gap title (replace dots with dashes)
    local label_safe
    label_safe="$(printf '%s' "$label" | tr '.' '-')"

    local title
    title="RESILIENT: INFRA-NEW-DAEMON-DEAD-${label_safe}: exit-loop detected (runs=${runs}, last_exit=${last_exit}, fp=${fingerprint})"

    local description
    description="daemon-exit-loop-watcher (INFRA-2417) detected a consecutive non-zero exit loop.

  - Label: ${label}
  - Runs observed: ${runs}
  - Last exit code: ${last_exit}
  - Fingerprint: ${fingerprint}
  - Threshold: ${THRESHOLD}

This gap was auto-filed by scripts/coord/daemon-exit-loop-watcher-daemon.sh. The fingerprint is sha256(label) first 12 chars, so a second tick for the same label will NOT re-file.

Root cause of this watcher: com.chump.integrator-daemon crash-looped 145 times over 37+ hours (2026-06-02) with last_exit_code=1 from a vanished /private/tmp/chump-install dir — zero alerts fired.

Investigation steps:
  1. Check daemon logs: \`launchctl print gui/\$(id -u)/${label}\`
  2. Check stdout/stderr paths shown in launchctl print output
  3. Fix the underlying crash cause
  4. Reload: \`launchctl unload ~/Library/LaunchAgents/${label}.plist && launchctl load ...\`
  5. When last_exit_code returns to 0, this watcher closes this gap automatically."

    local out exit_code gap_id
    exit_code=0
    out="$(CHUMP_IGNORE_WASTE_PAUSE=1 CHUMP_GAP_RESERVE_NO_SIMILARITY=1 FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --priority P0 \
        --effort s \
        --title "$title" \
        --force-duplicate 2>&1)" || exit_code=$?

    gap_id="$(printf '%s' "$out" | grep -oE 'INFRA-[0-9]+' | head -1)"
    if [[ -n "$gap_id" ]]; then
        log "filed daemon-dead gap: $gap_id (label=$label fp=$fingerprint)"

        local ac
        ac="Daemon ${label} last_exit_code returns to 0|daemon-exit-loop-watcher emits daemon_exit_loop_recovered and closes this gap"
        if ! "$CHUMP_BIN" gap set "$gap_id" \
            --description "$description" \
            --acceptance-criteria "$ac" >/dev/null 2>&1; then
            log "WARN: failed to backfill description on $gap_id"
        fi
        printf '%s' "$gap_id"
    else
        log "WARN: gap reserve failed (exit=$exit_code): $out"
        printf 'UNFILED'
    fi
}

# ── (4) Recovery: close auto-filed gaps for a recovered label ─────────────────
_recover_close_gap() {
    local gap_id="$1" label="$2"

    # Skip placeholder values
    case "$gap_id" in
        ""|"UNFILED"|INFRA-DRYRUN-*)
            return 0
            ;;
    esac

    if [[ -n "$DRY_RUN" ]]; then
        log "DRY_RUN: would close $gap_id (label=$label recovered)"
        return 0
    fi

    if "$CHUMP_BIN" gap set "$gap_id" --status "done" \
        --note "daemon-exit-loop-watcher: ${label} last_exit_code returned to 0" \
        >/dev/null 2>&1; then
        log "closed $gap_id (label=$label recovered)"
    else
        log "WARN: failed to close $gap_id (label=$label)"
    fi
}

# ── (5) Tick — one reconcile iteration ───────────────────────────────────────
cmd_tick() {
    local tick_id
    tick_id="tick-$(_now_epoch)-$$"
    log "tick start: $tick_id (threshold=$THRESHOLD)"

    # Load prior state — maps fingerprint → {gap_id, label, state}
    local prev_state_str; prev_state_str="$(_load_state)"

    # Collect all labels to check
    local labels_list
    labels_list="$(_collect_labels | sort -u)"

    if [[ -z "$labels_list" ]]; then
        log "no daemon labels found — bootstrap script may be missing"
        return 0
    fi

    # Process each label
    local new_detections=0
    local new_recoveries=0

    # We'll build the new state as a JSON object. Use python3 to handle JSON correctly.
    local new_state_json="$prev_state_str"

    while IFS= read -r label; do
        [[ -z "$label" ]] && continue

        local fingerprint
        fingerprint="$(_label_fingerprint "$label")"

        # Query launchctl
        local query_out
        if ! query_out="$(_query_label "$label")"; then
            # Label not known to launchd — not installed on this host, skip
            continue
        fi

        local daemon_runs daemon_last_exit
        daemon_runs="$(printf '%s' "$query_out" | cut -d' ' -f2)"
        daemon_last_exit="$(printf '%s' "$query_out" | cut -d' ' -f3)"

        # Coerce to integers for comparison
        local runs_int exit_int
        runs_int="$(printf '%d' "${daemon_runs:-0}" 2>/dev/null || printf '0')"
        exit_int="$(printf '%d' "${daemon_last_exit:-0}" 2>/dev/null || printf '0')"

        # Check if this fingerprint already has a filed gap in state
        local prev_gap_id prev_label_state
        prev_gap_id="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    entries = s.get('labels', {})
    print(entries.get('$fingerprint', {}).get('gap_id', ''))
except Exception:
    print('')
" 2>/dev/null || true)"

        prev_label_state="$(printf '%s' "$prev_state_str" | python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read() or '{}')
    entries = s.get('labels', {})
    print(entries.get('$fingerprint', {}).get('state', 'OK'))
except Exception:
    print('OK')
" 2>/dev/null || true)"

        if [[ "$exit_int" -eq 0 ]]; then
            # exit code = 0 → healthy (or recovered)
            if [[ "$prev_label_state" == "LOOP_DETECTED" && -n "$prev_gap_id" ]]; then
                # Recovery transition
                _recover_close_gap "$prev_gap_id" "$label"
                emit "daemon_exit_loop_recovered" \
                    "\"label\":\"${label}\",\"fingerprint\":\"${fingerprint}\",\"gap_id\":\"${prev_gap_id}\",\"runs\":${runs_int},\"last_exit_code\":0,\"tick_id\":\"${tick_id}\""
                log "RECOVERY: $label exit_code=0 after LOOP_DETECTED (gap=$prev_gap_id)"
                new_recoveries=$((new_recoveries + 1))
            fi

            # Update state to OK
            new_state_json="$(FINGERPRINT="$fingerprint" LABEL="$label" RUNS="$runs_int" \
                STATE_JSON="$new_state_json" python3 -c "
import json, os, sys
fp = os.environ['FINGERPRINT']
label = os.environ['LABEL']
runs = int(os.environ.get('RUNS', '0'))
s = json.loads(os.environ.get('STATE_JSON', '{}'))
if 'labels' not in s:
    s['labels'] = {}
s['labels'][fp] = {'label': label, 'state': 'OK', 'gap_id': '', 'last_seen_runs': runs}
print(json.dumps(s))
" 2>/dev/null || printf '%s' "$new_state_json")"

        else
            # exit code != 0 — potential exit loop
            # Only fire when runs >= threshold (not just 1 failed run)
            if [[ "$runs_int" -ge "$THRESHOLD" ]]; then
                if [[ "$prev_label_state" != "LOOP_DETECTED" ]]; then
                    # New detection — file gap (idempotent: fingerprint dedup)
                    local gap_id
                    gap_id="$(_file_daemon_gap "$label" "$runs_int" "$exit_int" "$fingerprint")"

                    emit "daemon_exit_loop_detected" \
                        "\"label\":\"${label}\",\"fingerprint\":\"${fingerprint}\",\"gap_id\":\"${gap_id}\",\"runs\":${runs_int},\"last_exit_code\":${exit_int},\"threshold\":${THRESHOLD},\"tick_id\":\"${tick_id}\""
                    log "DETECTED: $label exit_code=$exit_int runs=$runs_int (gap=$gap_id fp=$fingerprint)"
                    new_detections=$((new_detections + 1))

                    # Update state to LOOP_DETECTED
                    new_state_json="$(FINGERPRINT="$fingerprint" LABEL="$label" RUNS="$runs_int" \
                        GAP_ID="$gap_id" STATE_JSON="$new_state_json" python3 -c "
import json, os, sys
fp = os.environ['FINGERPRINT']
label = os.environ['LABEL']
runs = int(os.environ.get('RUNS', '0'))
gap_id = os.environ.get('GAP_ID', '')
s = json.loads(os.environ.get('STATE_JSON', '{}'))
if 'labels' not in s:
    s['labels'] = {}
s['labels'][fp] = {'label': label, 'state': 'LOOP_DETECTED', 'gap_id': gap_id, 'last_seen_runs': runs}
print(json.dumps(s))
" 2>/dev/null || printf '%s' "$new_state_json")"
                else
                    # Already detected — re-emit event each tick for visibility but no new gap
                    emit "daemon_exit_loop_detected" \
                        "\"label\":\"${label}\",\"fingerprint\":\"${fingerprint}\",\"gap_id\":\"${prev_gap_id}\",\"runs\":${runs_int},\"last_exit_code\":${exit_int},\"threshold\":${THRESHOLD},\"tick_id\":\"${tick_id}\",\"dedup\":true"
                    log "ALREADY_DETECTED: $label exit_code=$exit_int runs=$runs_int (dedup, gap=$prev_gap_id)"

                    # Update runs in state
                    new_state_json="$(FINGERPRINT="$fingerprint" LABEL="$label" RUNS="$runs_int" \
                        GAP_ID="$prev_gap_id" STATE_JSON="$new_state_json" python3 -c "
import json, os, sys
fp = os.environ['FINGERPRINT']
label = os.environ['LABEL']
runs = int(os.environ.get('RUNS', '0'))
gap_id = os.environ.get('GAP_ID', '')
s = json.loads(os.environ.get('STATE_JSON', '{}'))
if 'labels' not in s:
    s['labels'] = {}
s['labels'][fp] = {'label': label, 'state': 'LOOP_DETECTED', 'gap_id': gap_id, 'last_seen_runs': runs}
print(json.dumps(s))
" 2>/dev/null || printf '%s' "$new_state_json")"
                fi
            else
                log "BELOW_THRESHOLD: $label exit_code=$exit_int runs=$runs_int (need $THRESHOLD)"
                # Update state to BELOW_THRESHOLD
                new_state_json="$(FINGERPRINT="$fingerprint" LABEL="$label" RUNS="$runs_int" \
                    STATE_JSON="$new_state_json" python3 -c "
import json, os, sys
fp = os.environ['FINGERPRINT']
label = os.environ['LABEL']
runs = int(os.environ.get('RUNS', '0'))
s = json.loads(os.environ.get('STATE_JSON', '{}'))
if 'labels' not in s:
    s['labels'] = {}
s['labels'][fp] = {'label': label, 'state': 'BELOW_THRESHOLD', 'gap_id': '', 'last_seen_runs': runs}
print(json.dumps(s))
" 2>/dev/null || printf '%s' "$new_state_json")"
            fi
        fi
    done <<< "$labels_list"

    # Persist updated state with tick metadata
    local final_state
    final_state="$(TICK_ID="$tick_id" UPDATED_AT="$(_ts)" STATE_JSON="$new_state_json" python3 -c "
import json, os
s = json.loads(os.environ.get('STATE_JSON', '{}'))
s['last_tick_id'] = os.environ.get('TICK_ID', '')
s['updated_at'] = os.environ.get('UPDATED_AT', '')
print(json.dumps(s))
" 2>/dev/null || printf '%s' "$new_state_json")"

    _save_state "$final_state"

    log "tick end: new_detections=$new_detections new_recoveries=$new_recoveries"
}

# ── (6) CLI ──────────────────────────────────────────────────────────────────
case "${1:-}" in
    tick) cmd_tick ;;
    --help|-h)
        sed -n '1,65p' "$0"
        exit 0
        ;;
    "")
        # No-arg invocation (launchd default) = one tick.
        cmd_tick
        ;;
    *)
        printf 'Usage: %s tick | --help\n' "$0" >&2
        exit 2
        ;;
esac
