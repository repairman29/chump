#!/usr/bin/env bash
# scripts/coord/infra-watcher-loop.sh — SRE-lane substrate health auditor
# META-102: productize curator-opus-infra-watcher
#
# Harness-neutral CLI. Subcommands:
#   tick           — one full audit cycle (all subchecks in order)
#   audit-daemons  — launchd plist health (StartInterval / StartCalendarInterval)
#   check-runners  — self-hosted runner ghost-online detection
#   check-disk     — /tmp + /private/tmp + .chump-locks disk pressure
#   check-procs    — claude process count + load avg
#
# Emits kind=infra_watcher_finding with {category, severity, detail} to ambient.jsonl
#
# Rust-First-Bypass: bash-glue across launchctl/gh/df/pgrep; coherent with other
# curator-loop.sh shapes in scripts/coord/. No state mutation, no hot-path call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow REPO_ROOT override for testing
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"

# ── Helpers ──────────────────────────────────────────────────────────────────

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_emit_finding() {
    local category="$1"
    local severity="$2"  # critical | warning | ok
    local detail="$3"
    local ts
    ts="$(_ts)"
    # Sanitize detail for JSON (escape backslash, double-quote, newline)
    local safe_detail
    safe_detail="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')"
    printf '{"ts":"%s","kind":"infra_watcher_finding","category":"%s","severity":"%s","detail":"%s"}\n' \
        "$ts" "$category" "$severity" "$safe_detail" \
        >> "$AMBIENT_LOG"
    if [[ "$severity" == "critical" ]]; then
        printf '[infra-watcher] CRITICAL %s: %s\n' "$category" "$detail" >&2
    else
        printf '[infra-watcher] %s %s: %s\n' "$severity" "$category" "$detail"
    fi
}

_header() { printf '\n=== infra-watcher: %s ===\n' "$1"; }

# ── audit-daemons ─────────────────────────────────────────────────────────────
# Verify every com.chump.*.plist has StartInterval OR StartCalendarInterval.
# Optionally verify the associated process has heartbeated recently.
cmd_audit_daemons() {
    _header "audit-daemons"
    local plist_dir="${HOME}/Library/LaunchAgents"
    local found_any=0
    local findings=0

    if [[ ! -d "$plist_dir" ]]; then
        printf '[infra-watcher] audit-daemons: LaunchAgents dir not found: %s\n' "$plist_dir"
        return 0
    fi

    while IFS= read -r -d '' plist; do
        found_any=1
        local basename
        basename="$(basename "$plist" .plist)"

        # Check for StartInterval or StartCalendarInterval
        if grep -q "StartInterval\|StartCalendarInterval" "$plist" 2>/dev/null; then
            printf '[infra-watcher] OK daemon=%s has scheduling key\n' "$basename"
        else
            findings=$((findings + 1))
            _emit_finding "daemon_plist_missing_interval" "critical" \
                "plist ${plist} has neither StartInterval nor StartCalendarInterval — daemon will never fire automatically"
        fi
    done < <(find "${CHUMP_INFRA_WATCHER_PLIST_DIR:-$plist_dir}" \
                  -maxdepth 1 -name "com.chump.*.plist" -print0 2>/dev/null)

    if [[ "$found_any" -eq 0 ]]; then
        printf '[infra-watcher] audit-daemons: no com.chump.*.plist files found in %s\n' \
            "${CHUMP_INFRA_WATCHER_PLIST_DIR:-$plist_dir}"
    fi

    if [[ "$findings" -eq 0 && "$found_any" -gt 0 ]]; then
        printf '[infra-watcher] audit-daemons: all plists OK\n'
    fi
    return 0
}

# ── check-runners ─────────────────────────────────────────────────────────────
# Detect ghost-online: ≥1 job queued >5min AND ≥1 runner online+idle.
# Invokes META-100 detection script if it exists.
cmd_check_runners() {
    _header "check-runners"

    # Delegate to META-100 runner-monitor if it exists
    local runner_monitor="${REPO_ROOT}/scripts/ops/runner-ghost-monitor.sh"
    if [[ -x "$runner_monitor" ]]; then
        printf '[infra-watcher] check-runners: delegating to %s\n' "$runner_monitor"
        bash "$runner_monitor" && return 0 || true
    fi

    # Standalone ghost-online detection
    local gh_bin="${CHUMP_GH_BIN:-gh}"

    # Get runner state — fail gracefully if gh unavailable
    local runners_json
    if ! runners_json="$("$gh_bin" api repos/"$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||; s|\.git$||')" \
        /actions/runners --paginate 2>/dev/null)"; then
        printf '[infra-watcher] check-runners: gh api unavailable — skipping runner check\n'
        return 0
    fi

    # Count idle online runners
    local idle_count
    idle_count="$(printf '%s' "$runners_json" \
        | python3 -c "
import json,sys
d=json.load(sys.stdin)
runners=d.get('runners',d) if isinstance(d,dict) else d
print(sum(1 for r in runners if r.get('status')=='online' and r.get('busy')==False))
" 2>/dev/null || echo 0)"

    if [[ "$idle_count" -eq 0 ]]; then
        printf '[infra-watcher] check-runners: no idle online runners — cannot be ghost-online\n'
        return 0
    fi

    # Check for queued runs older than 5 minutes
    local queued_json
    if ! queued_json="$("$gh_bin" run list --status queued --limit 20 --json databaseId,createdAt,status 2>/dev/null)"; then
        printf '[infra-watcher] check-runners: cannot read queued runs — skipping\n'
        return 0
    fi

    local ghost_count
    ghost_count="$(printf '%s' "$queued_json" \
        | python3 -c "
import json,sys
from datetime import datetime, timezone, timedelta
runs=json.load(sys.stdin)
cutoff=datetime.now(timezone.utc) - timedelta(minutes=5)
old=[r for r in runs if datetime.fromisoformat(r['createdAt'].replace('Z','+00:00')) < cutoff]
print(len(old))
" 2>/dev/null || echo 0)"

    if [[ "$ghost_count" -gt 0 ]]; then
        _emit_finding "runner_ghost_online" "critical" \
            "${ghost_count} job(s) queued >5min with ${idle_count} runner(s) online+idle — ghost-online condition; runs may wedge indefinitely"
    else
        printf '[infra-watcher] check-runners: OK — %d idle runner(s), no queued runs >5min\n' "$idle_count"
    fi
    return 0
}

# ── check-disk ────────────────────────────────────────────────────────────────
# Flag any watched path >85% used.
cmd_check_disk() {
    _header "check-disk"

    local threshold="${CHUMP_INFRA_WATCHER_DISK_THRESHOLD:-85}"
    local locks_dir="${REPO_ROOT}/.chump-locks"

    # Paths to check — fall back gracefully if path missing
    local paths=()
    for p in /tmp /private/tmp "$locks_dir"; do
        [[ -e "$p" ]] && paths+=("$p")
    done

    if [[ "${#paths[@]}" -eq 0 ]]; then
        printf '[infra-watcher] check-disk: no paths to check\n'
        return 0
    fi

    local any_critical=0
    while IFS= read -r line; do
        # Parse df -h output: filesystem, size, used, avail, pct, mountpoint
        local pct
        pct="$(printf '%s' "$line" | awk '{print $5}' | tr -d '%')"
        local mountpoint
        mountpoint="$(printf '%s' "$line" | awk '{print $NF}')"
        if [[ "$pct" =~ ^[0-9]+$ ]] && [[ "$pct" -ge "$threshold" ]]; then
            any_critical=1
            local severity="warning"
            [[ "$pct" -ge 95 ]] && severity="critical"
            _emit_finding "disk_pressure" "$severity" \
                "path=${mountpoint} at ${pct}% (threshold=${threshold}%) — disk pressure detected"
        else
            printf '[infra-watcher] check-disk: OK %s at %s%%\n' "$mountpoint" "${pct:-?}"
        fi
    done < <("${CHUMP_DF_BIN:-df}" -h "${paths[@]}" 2>/dev/null | tail -n +2)

    [[ "$any_critical" -eq 0 ]] && printf '[infra-watcher] check-disk: all paths below %d%% threshold\n' "$threshold"
    return 0
}

# ── check-procs ───────────────────────────────────────────────────────────────
# Flag if claude proc count >100 OR load_avg_1m >10.
cmd_check_procs() {
    _header "check-procs"

    local proc_threshold="${CHUMP_INFRA_WATCHER_PROC_THRESHOLD:-100}"
    local load_threshold="${CHUMP_INFRA_WATCHER_LOAD_THRESHOLD:-10}"

    # Claude process count
    local claude_count=0
    if command -v pgrep >/dev/null 2>&1; then
        claude_count="$("${CHUMP_PGREP_BIN:-pgrep}" -f 'MacOS/claude' 2>/dev/null | wc -l | tr -d ' ')"
    fi

    # Load average (1-minute)
    local load_avg_1m="0"
    if [[ -f /proc/loadavg ]]; then
        load_avg_1m="$(awk '{print $1}' /proc/loadavg)"
    elif command -v sysctl >/dev/null 2>&1; then
        load_avg_1m="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || echo 0)"
    fi

    printf '[infra-watcher] check-procs: claude_count=%d load_avg_1m=%s\n' "$claude_count" "$load_avg_1m"

    local findings=0

    if [[ "$claude_count" -gt "$proc_threshold" ]]; then
        findings=$((findings + 1))
        _emit_finding "process_bloat" "critical" \
            "claude process count=${claude_count} exceeds threshold=${proc_threshold} — possible proc leak or runaway reaper"
    fi

    # Compare load avg as integer (truncate)
    local load_int
    load_int="${load_avg_1m%%.*}"
    load_int="${load_int:-0}"
    if [[ "$load_int" =~ ^[0-9]+$ ]] && [[ "$load_int" -gt "$load_threshold" ]]; then
        findings=$((findings + 1))
        _emit_finding "process_bloat" "warning" \
            "load_avg_1m=${load_avg_1m} exceeds threshold=${load_threshold} — system under heavy load"
    fi

    [[ "$findings" -eq 0 ]] && printf '[infra-watcher] check-procs: OK\n'
    return 0
}

# ── tick ──────────────────────────────────────────────────────────────────────
# One full audit cycle: all subchecks in order.
cmd_tick() {
    local ts
    ts="$(_ts)"
    printf '[infra-watcher] tick start ts=%s\n' "$ts"
    cmd_audit_daemons
    cmd_check_runners
    cmd_check_disk
    cmd_check_procs
    printf '[infra-watcher] tick complete ts=%s\n' "$(_ts)"
}

# ── main ──────────────────────────────────────────────────────────────────────
CMD="${1:-tick}"
shift || true

case "$CMD" in
    tick)           cmd_tick "$@" ;;
    audit-daemons)  cmd_audit_daemons "$@" ;;
    check-runners)  cmd_check_runners "$@" ;;
    check-disk)     cmd_check_disk "$@" ;;
    check-procs)    cmd_check_procs "$@" ;;
    *)
        printf 'Usage: %s {tick|audit-daemons|check-runners|check-disk|check-procs}\n' \
            "$(basename "$0")" >&2
        exit 1
        ;;
esac
