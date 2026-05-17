#!/usr/bin/env bash
# pr-failure-auto-rescue.sh — INFRA-1600 MVP.
#
# Linchpin daemon for PR-merge automation. Watches the operator's open
# PRs, pattern-matches CI failure logs against known handlers, and
# auto-applies the corresponding fix. Tonight's manual cascade-fix
# pattern (cargo fmt / adjacent-string-literal / cargo-not-on-PATH /
# chump-binary-not-found / tauri-flake-timeout) is encoded here.
#
# Usage:
#   bash scripts/coord/pr-failure-auto-rescue.sh           # one-shot
#   bash scripts/coord/pr-failure-auto-rescue.sh --loop    # daemon (60s)
#   bash scripts/coord/pr-failure-auto-rescue.sh --dry-run # diagnose only
#
# Env:
#   AUTO_RESCUE_AUTHOR     gh @me or specific user (default: @me)
#   AUTO_RESCUE_COOLDOWN_S 30 min between rescues per (PR, handler) (default 1800)
#   AUTO_RESCUE_MAX_PER_PR 3 lifetime rescues per PR (default 3)
#   GH_TOKEN               must be set
#
# Cool-down + max-per-PR safety: no infinite-loop fix-fix-fix.

set -uo pipefail

DRY_RUN=0
LOOP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --loop)      LOOP=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

AUTHOR="${AUTO_RESCUE_AUTHOR:-@me}"
COOLDOWN_S="${AUTO_RESCUE_COOLDOWN_S:-1800}"
MAX_PER_PR="${AUTO_RESCUE_MAX_PER_PR:-3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESCUE_LOG="$REPO_ROOT/.chump-locks/pr-rescue.log"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

mkdir -p "$(dirname "$RESCUE_LOG")"

say() { echo "[pr-rescue $(date -u +%H:%M:%S)] $*"; }

# Emit an ambient event.
emit_event() {
    local kind="$1"; shift
    local fields="$*"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ $DRY_RUN -eq 1 ]]; then
        say "[dry] would emit kind=$kind $fields"
        return 0
    fi
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$fields" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# Append a rescue-log line. JSON per line for parseability.
log_rescue() {
    local pr="$1"; local handler="$2"; local outcome="$3"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"ts":"%s","pr":%s,"handler":"%s","outcome":"%s"}\n' \
        "$ts" "$pr" "$handler" "$outcome" >> "$RESCUE_LOG"
}

# Count past rescue actions for a PR (max-per-PR enforcement).
# NOTE: grep -c outputs "0" on zero-match AND exits 1; piping `|| echo 0`
# triggers another `0` write → captures "0\n0". Use awk for clean count.
count_past_rescues() {
    local pr="$1"
    [[ ! -f "$RESCUE_LOG" ]] && { echo 0; return; }
    awk -v pr="$pr" 'BEGIN{n=0} index($0,"\"pr\":"pr",")>0 {n++} END{print n}' "$RESCUE_LOG"
}

# Check if a (PR, handler) is in cool-down.
in_cooldown() {
    local pr="$1"; local handler="$2"
    [[ ! -f "$RESCUE_LOG" ]] && return 1
    local last_ts
    last_ts=$(grep "\"pr\":$pr," "$RESCUE_LOG" 2>/dev/null \
              | grep "\"handler\":\"$handler\"" \
              | tail -1 \
              | sed -nE 's/.*"ts":"([^"]+)".*/\1/p')
    [[ -z "$last_ts" ]] && return 1
    local last_epoch now_epoch
    last_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" "+%s" 2>/dev/null \
                 || date -u -d "$last_ts" "+%s" 2>/dev/null || echo 0)
    now_epoch=$(date -u +%s)
    local delta=$((now_epoch - last_epoch))
    [[ $delta -lt $COOLDOWN_S ]]
}

# Fetch first FAILURE check's job ID for a PR.
first_failed_job_id() {
    local pr="$1"
    gh pr view "$pr" --json statusCheckRollup 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for c in d.get('statusCheckRollup',[]):
        if c.get('conclusion') == 'FAILURE':
            u = c.get('detailsUrl','')
            if '/job/' in u:
                print(u.split('/job/')[1].split('?')[0])
                break
except Exception:
    pass
"
}

# Fetch log excerpt for a job.
fetch_log_excerpt() {
    local job_id="$1"
    [[ -z "$job_id" ]] && return 1
    curl -sL "https://api.github.com/repos/repairman29/chump/actions/jobs/${job_id}/logs" \
        -H "Authorization: token $(gh auth token 2>/dev/null)" 2>/dev/null | tail -200
}

# Resolve branch + headRefName for a PR.
pr_branch() {
    gh pr view "$1" --json headRefName --jq '.headRefName' 2>/dev/null
}

# ── HANDLERS ──────────────────────────────────────────────────────────────────
# Each returns 0 on success, non-zero on failure. Each is responsible for
# its OWN rebase / commit / push. Cool-down + max enforced by main loop.

handle_cargo_fmt_drift() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "^Diff in .*\.rs:"; then
        return 99  # not my pattern
    fi
    say "  → handler: cargo_fmt_drift on PR $pr"
    [[ $DRY_RUN -eq 1 ]] && { log_rescue "$pr" "cargo_fmt_drift" "dry_run_skip"; return 0; }
    local branch wt
    branch=$(pr_branch "$pr")
    wt="/tmp/auto-rescue-${pr}"
    rm -rf "$wt"
    git clone --shared "$REPO_ROOT" "$wt" 2>&1 >/dev/null
    (
        cd "$wt" || return 1
        git remote remove origin 2>/dev/null
        git remote add chump https://github.com/repairman29/chump.git
        git fetch chump "$branch" 2>&1 >/dev/null
        git checkout -B "$branch" "chump/$branch" 2>&1 >/dev/null
        export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
        cargo fmt 2>&1 >/dev/null
        if ! git diff --quiet; then
            git -c commit.gpgsign=false commit --no-verify -am "fix(ci): cargo fmt (auto-rescue INFRA-1600)" 2>&1 >/dev/null
            git push --force-with-lease chump "HEAD:refs/heads/$branch" 2>&1 >/dev/null
            log_rescue "$pr" "cargo_fmt_drift" "fixed"
            emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"cargo_fmt_drift\",\"outcome\":\"fixed\""
        else
            log_rescue "$pr" "cargo_fmt_drift" "noop"
        fi
    )
    rm -rf "$wt"
    return 0
}

handle_cargo_not_found() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "cargo: command not found"; then
        return 99
    fi
    say "  → handler: cargo_not_found on PR $pr — needs ensure-cargo-on-path.sh helper"
    # Just emit info — actual fix is to wait for #2266 to land + rebase.
    # Future iteration: cherry-pick the helper file from main if it exists on main.
    [[ $DRY_RUN -eq 1 ]] && return 0
    log_rescue "$pr" "cargo_not_found" "awaiting_pr_2266_merge"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"cargo_not_found\",\"outcome\":\"awaiting_pr_2266_merge\""
    return 0
}

handle_chump_bin_not_found() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "chump binary not found"; then
        return 99
    fi
    say "  → handler: chump_bin_not_found on PR $pr"
    [[ $DRY_RUN -eq 1 ]] && return 0
    log_rescue "$pr" "chump_bin_not_found" "awaiting_pr_2266_merge"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"chump_bin_not_found\",\"outcome\":\"awaiting_pr_2266_merge\""
    return 0
}

handle_tauri_flake() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -q "Wait timed out.*chump-chat"; then
        return 99
    fi
    say "  → handler: tauri_flake on PR $pr — rerunning failed checks"
    [[ $DRY_RUN -eq 1 ]] && return 0
    local run_id
    run_id=$(gh pr view "$pr" --json statusCheckRollup 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin).get('statusCheckRollup',[]):
    if c.get('conclusion')=='FAILURE' and 'tauri' in (c.get('name','') or '').lower():
        u=c.get('detailsUrl','')
        if '/runs/' in u: print(u.split('/runs/')[1].split('/')[0]); break
")
    if [[ -n "$run_id" ]]; then
        gh run rerun "$run_id" --failed --repo repairman29/chump 2>&1 | tail -1
        log_rescue "$pr" "tauri_flake" "rerun_triggered"
        emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"tauri_flake\",\"outcome\":\"rerun_triggered\""
    fi
    return 0
}

handle_adjacent_string_eprintln() {
    local pr="$1"; local log="$2"
    if ! echo "$log" | grep -qE "expected.*\`,\`.*found.*\"Usage:"; then
        return 99
    fi
    say "  → handler: adjacent_string_eprintln on PR $pr — needs manual diagnosis"
    # This pattern is from union-merge. Auto-fix would need to identify the
    # specific eprintln! call and combine the strings. Punt to operator for now.
    [[ $DRY_RUN -eq 1 ]] && return 0
    log_rescue "$pr" "adjacent_string_eprintln" "operator_alert"
    emit_event "pr_auto_rescue_invoked" "\"pr\":$pr,\"handler\":\"adjacent_string_eprintln\",\"outcome\":\"operator_alert\""
    return 0
}

# ── MAIN LOOP ─────────────────────────────────────────────────────────────────
run_once() {
    say "scanning open PRs by $AUTHOR…"
    local pr_list
    pr_list=$(gh pr list --repo repairman29/chump --state open \
              --author "$AUTHOR" --limit 50 \
              --json number,title 2>/dev/null) || {
        say "ERROR: gh pr list failed"
        return 1
    }
    local prs
    prs=$(echo "$pr_list" | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    print(p['number'])
")
    local seen=0 rescued=0
    for pr in $prs; do
        seen=$((seen + 1))
        local past=$(count_past_rescues "$pr")
        if [[ "$past" -ge "$MAX_PER_PR" ]]; then
            continue
        fi
        local job_id
        job_id=$(first_failed_job_id "$pr")
        [[ -z "$job_id" ]] && continue

        local log
        log=$(fetch_log_excerpt "$job_id")
        [[ -z "$log" ]] && continue

        say "PR $pr: examining failure (past rescues: $past)"

        # Dispatch in order; each handler self-checks pattern.
        for handler in cargo_fmt_drift tauri_flake cargo_not_found chump_bin_not_found adjacent_string_eprintln; do
            if in_cooldown "$pr" "$handler"; then
                continue
            fi
            "handle_$handler" "$pr" "$log"
            local rc=$?
            if [[ $rc -eq 0 ]]; then
                rescued=$((rescued + 1))
                break  # one handler per PR per scan
            fi
        done
    done
    say "scan complete: $seen PRs, $rescued action(s) taken"
}

if [[ $LOOP -eq 1 ]]; then
    say "starting loop mode (interval 60s)…"
    while true; do
        run_once
        sleep 60
    done
else
    run_once
fi
