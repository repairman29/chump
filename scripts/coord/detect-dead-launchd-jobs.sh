#!/usr/bin/env bash
# scripts/coord/detect-dead-launchd-jobs.sh — CREDIBLE-1020 (CREDIBLE-274 slice, candidate (a))
#
# CREDIBLE-274 candidate (a): every launchd/plist job declared in
# scripts/launchd or ~/Library/LaunchAgents that has ZERO running
# processes. A plist can sit installed and "enabled" forever after its
# daemon dies or its ProgramArguments target moves — CI stays green,
# nothing alarms, and the job is silently not doing its job
# (operator-recall was found dead this way, three months stale).
#
# Detection strategy: extract the <key>Label</key> string from each
# plist, then look for a matching running process. Prefer `launchctl
# list <label>` (authoritative — reports the actual PID launchd has for
# that label, "-" when not running) when launchctl is available;
# fall back to `pgrep -f <label>` otherwise (Linux dev boxes, CI, or
# any environment without a real launchd) so the sweep stays
# reportable/testable everywhere the fleet runs its scripts.
#
# Usage: detect-dead-launchd-jobs.sh [repo-root]   (defaults to cwd)
#
# Findings, not failures (per CREDIBLE-274 AC): reports the plist path
# and label for anything with zero matching processes and always exits
# 0. This is a queue for triage, not a CI gate — a plist can
# legitimately be for a job that only fires on rare events.

set -uo pipefail

ROOT="${1:-$(pwd)}"
if ! ROOT="$(cd "$ROOT" 2>/dev/null && pwd)"; then
    echo "detect-dead-launchd-jobs: repo root '$1' does not exist" >&2
    exit 1
fi

extract_label() {
    # Print the <string> value immediately following <key>Label</key>.
    awk '
        /<key>Label<\/key>/ { want = 1; next }
        want {
            if (match($0, /<string>.*<\/string>/)) {
                s = substr($0, RSTART, RLENGTH)
                gsub(/<string>|<\/string>/, "", s)
                gsub(/^[ \t]+|[ \t]+$/, "", s)
                print s
                exit
            }
            want = 0
        }
    ' "$1"
}

has_running_process() {
    local label="$1"
    if command -v launchctl >/dev/null 2>&1; then
        local pid_col
        pid_col="$(launchctl list "$label" 2>/dev/null | awk 'NR==1{print $1}')"
        if [[ -n "$pid_col" && "$pid_col" != "-" ]]; then
            return 0
        fi
        # launchctl present but job not loaded/not found — still fall
        # through to a process-list check in case it's running detached
        # from launchd (e.g. manually started for debugging).
    fi
    pgrep -f -- "$label" >/dev/null 2>&1
}

findings_count=0
findings_out=""

scan_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    while IFS= read -r -d '' plist; do
        local label
        label="$(extract_label "$plist")"
        [[ -n "$label" ]] || continue
        if ! has_running_process "$label"; then
            local rel="$plist"
            [[ "$plist" == "$ROOT"/* ]] && rel="${plist#"$ROOT"/}"
            findings_out+="${rel}  label=${label}
"
            findings_count=$((findings_count + 1))
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.plist' -print0 | sort -z)
}

scan_dir "$ROOT/scripts/launchd"
scan_dir "$HOME/Library/LaunchAgents"

if [[ "$findings_count" -gt 0 ]]; then
    echo "Dead launchd jobs found (declared, zero running processes):"
    printf '%s' "$findings_out"
fi

echo "Total dead launchd jobs: $findings_count"

exit 0
