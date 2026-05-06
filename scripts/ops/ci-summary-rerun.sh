#!/usr/bin/env bash
# ci-summary-rerun.sh — INFRA-557: classify CI failures using the same logic
# as `chump ci-summary` (src/ci_summary.rs) and auto-rerun flake/infra-broken
# failures once per run-id.
#
# Differs from ci-flake-rerun.sh (INFRA-375) which matches a fixed allowlist.
# This script mirrors classify_log() from the Rust classifier:
#   infra-broken  → rerun (transient infra issue, not code fault)
#   flake         → rerun (transient test failure, same code passes on rerun)
#   test-coupling → skip  (snapshot/fixture divergence — needs code fix)
#   real-bug      → skip  (actual defect introduced by the PR)
#
# Cooldown: shares .chump-locks/ci-flake-cooldown/ with ci-flake-rerun.sh
# so the two scripts share state and never double-rerun the same run-id.
#
# In GitHub Actions (GITHUB_ACTIONS=true), no .chump-locks/ directory exists;
# cooldown falls back to /tmp/ci-summary-cooldown/. Budget also inactive in
# GitHub Actions context (per-run-id guard is sufficient there).
#
# Usage:
#   scripts/ops/ci-summary-rerun.sh                    # scan all open PRs
#   scripts/ops/ci-summary-rerun.sh --run-id <ID>      # single run (CI mode)
#   scripts/ops/ci-summary-rerun.sh --dry-run          # print, no reruns
#
# Environment:
#   CHUMP_CI_SUMMARY_RERUN=0    bypass — exit 0 immediately
#   CHUMP_FLAKE_BUDGET           max flake-class reruns per PR (default 3)
#   GITHUB_ACTIONS               set by GitHub Actions; switches cooldown dir

set -euo pipefail

if [[ "${CHUMP_CI_SUMMARY_RERUN:-1}" == "0" ]]; then
    echo "[ci-summary-rerun] CHUMP_CI_SUMMARY_RERUN=0 — bypass"
    exit 0
fi

# ── Arg parsing ──────────────────────────────────────────────────────────────

DRY_RUN=0
SINGLE_RUN_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --run-id)     SINGLE_RUN_ID="${2:?--run-id requires a value}"; shift ;;
        --run-id=*)   SINGLE_RUN_ID="${1#--run-id=}" ;;
        *)            ;;
    esac
    shift
done

# ── Reaper instrumentation (local context only) ───────────────────────────────

IN_GITHUB_ACTIONS="${GITHUB_ACTIONS:-false}"
if [[ "$IN_GITHUB_ACTIONS" != "true" ]]; then
    # shellcheck source=../lib/reaper-instrumentation.sh
    source "$(dirname "$0")/../lib/reaper-instrumentation.sh"
    reaper_setup ci-summary
    reaper_check_disk_headroom  # INFRA-453: exit 0 + ALERT if <5% free
    reaper_rotate_log /tmp/chump-ci-summary-rerun.out.log
    reaper_rotate_log /tmp/chump-ci-summary-rerun.err.log
    trap 'rc=$?; [[ $rc -ne 0 ]] && reaper_finish fail "{\"exit\":$rc}"' EXIT
    LOCK_DIR="$REAPER_LOCK_DIR"
    AMBIENT_LOG="$REAPER_LOCK_DIR/ambient.jsonl"
else
    LOCK_DIR="/tmp/ci-summary-cooldown"
    AMBIENT_LOG="/dev/null"
fi

COOLDOWN_DIR="$LOCK_DIR/ci-flake-cooldown"
mkdir -p "$COOLDOWN_DIR" 2>/dev/null || true

# ── Classifier — mirrors classify_log() in src/ci_summary.rs ─────────────────

# Usage: class=$(classify_run_log "$log_text")
# Pipes log via stdin to avoid ARG_MAX limits on large logs.
classify_run_log() {
    printf '%s' "$1" | python3 <<'PYEOF'
import sys

log = sys.stdin.read()
lower = log.lower()

def is_infra_broken():
    return (
        "no space left on device" in lower or
        "rustup: error" in lower or
        "error: toolchain '" in lower or
        "the runner has received a shutdown signal" in lower or
        "the operation was canceled" in lower or
        "rate limit exceeded" in lower or
        "error response from daemon" in lower or
        "runner exited" in lower or
        "github actions runner" in lower or
        ("failed to connect" in lower and "server" in lower) or
        "tls handshake timeout" in lower or
        "i/o timeout" in lower or
        "name resolution failed" in lower
    )

def is_test_coupling():
    return (
        "snapshot mismatch" in lower or
        "snapshot differs" in lower or
        ("snapshot" in lower and "outdated" in lower) or
        ("snapshot" in lower and "updated" in lower) or
        "golden file" in lower or
        ".snap" in lower or
        ("fixture" in lower and "fail" in lower) or
        "expected snapshot" in lower or
        "update snapshots" in lower
    )

def is_flake():
    return (
        "econnreset" in lower or
        "signal: killed" in lower or
        "oom killer" in lower or
        ("connection refused" in lower and "error[e" not in lower) or
        "operation timed out" in lower or
        "context deadline exceeded" in lower or
        "socket hang up" in lower or
        ("killed" in lower and "memory" in lower)
    )

if is_infra_broken():
    print("infra-broken")
elif is_test_coupling():
    print("test-coupling")
elif is_flake():
    print("flake")
else:
    print("real-bug")
PYEOF
}

# ── Helpers ───────────────────────────────────────────────────────────────────

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[0;33m  WARN: %s\033[0m\n' "$*"; }
dry()   { printf '  [dry-run] %s\n' "$*"; }

emit_ambient() {
    local event_json="$1"
    printf '%s\n' "$event_json" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── Per-run-id rerun logic ────────────────────────────────────────────────────

# Returns 0 if the run should be rerun, 1 otherwise.
# Sets RERUN_CLASS and SKIP_REASON as side-effects.
RERUN_CLASS=""
SKIP_REASON=""

try_rerun_run() {
    local pr_num="$1" run_id="$2" title="${3:-}"

    # Cooldown: have we already attempted rerun on this run-id?
    local cd_file="$COOLDOWN_DIR/run-${run_id}.ts"
    if [[ -f "$cd_file" ]]; then
        SKIP_REASON="already attempted rerun"
        return 1
    fi

    # Per-PR flake budget (local context only; GitHub Actions context skips).
    if [[ "$IN_GITHUB_ACTIONS" != "true" ]]; then
        local flake_budget="${CHUMP_FLAKE_BUDGET:-3}"
        local pr_count_file="$COOLDOWN_DIR/pr-${pr_num}.count"
        local pr_count=0
        [[ -f "$pr_count_file" ]] && pr_count=$(cat "$pr_count_file" 2>/dev/null || echo 0)
        if (( flake_budget > 0 )) && (( pr_count >= flake_budget )); then
            SKIP_REASON="flake-budget exceeded ($pr_count/$flake_budget)"
            # Post one-time comment and emit ambient alert.
            local comment_marker="$COOLDOWN_DIR/pr-${pr_num}.commented"
            if [[ ! -f "$comment_marker" ]] && [[ $DRY_RUN -eq 0 ]]; then
                gh pr comment "$pr_num" --body "⚠️ **ci-summary-rerun: flake budget exceeded** (${pr_count}/${flake_budget} reruns). The classifier kept seeing flake/infra-broken on distinct run-ids — likely a real intermittent failure. Consider filing a gap:
\`\`\`bash
chump gap reserve --domain INFRA --title 'flaky test on PR #${pr_num} — investigate'
\`\`\`
Bypass: \`CHUMP_FLAKE_BUDGET=0 scripts/ops/ci-summary-rerun.sh\`" >/dev/null 2>&1 \
                    && touch "$comment_marker" || true
            fi
            local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            emit_ambient "{\"event\":\"alert\",\"kind\":\"flake_budget_exceeded\",\"ts\":\"$ts\",\"pr\":$pr_num,\"count\":$pr_count,\"budget\":$flake_budget,\"source\":\"ci-summary-rerun\"}"
            return 1
        fi
    fi

    # Fetch the failed log and classify it.
    local log
    log=$(gh run view "$run_id" --log-failed 2>/dev/null | head -c 200000 || echo "")
    if [[ -z "$log" ]]; then
        SKIP_REASON="could not fetch log"
        return 1
    fi

    local class
    class=$(classify_run_log "$log" 2>/dev/null || echo "real-bug")
    RERUN_CLASS="$class"

    if [[ "$class" != "flake" && "$class" != "infra-broken" ]]; then
        SKIP_REASON="class=$class"
        return 1
    fi

    return 0
}

# ── Mode: single run-id (GitHub Actions) ─────────────────────────────────────

RERAN=0; SKIPPED=0

if [[ -n "$SINGLE_RUN_ID" ]]; then
    green "=== ci-summary-rerun (single run: $SINGLE_RUN_ID) ==="
    [[ $DRY_RUN -eq 1 ]] && info "Dry-run mode."

    RERUN_CLASS=""; SKIP_REASON=""
    if try_rerun_run "0" "$SINGLE_RUN_ID" ""; then
        if [[ $DRY_RUN -eq 1 ]]; then
            dry "would rerun run $SINGLE_RUN_ID (class: $RERUN_CLASS)"
            RERAN=$((RERAN+1))
        elif gh run rerun "$SINGLE_RUN_ID" --failed >/dev/null 2>&1; then
            date +%s > "$COOLDOWN_DIR/run-${SINGLE_RUN_ID}.ts"
            green "  reran run $SINGLE_RUN_ID (class: $RERUN_CLASS)"
            RERAN=$((RERAN+1))
            emit_ambient "{\"event\":\"alert\",\"kind\":\"ci_summary_rerun\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"run\":\"$SINGLE_RUN_ID\",\"class\":\"$RERUN_CLASS\",\"source\":\"ci-summary-rerun\"}"
        else
            warn "gh run rerun $SINGLE_RUN_ID failed"
            SKIPPED=$((SKIPPED+1))
        fi
    else
        info "run $SINGLE_RUN_ID: skip ($SKIP_REASON)"
        SKIPPED=$((SKIPPED+1))
    fi

    echo ""
    green "=== done: $RERAN reran, $SKIPPED skipped ==="
    if [[ "$IN_GITHUB_ACTIONS" != "true" ]]; then
        trap - EXIT
        reaper_finish ok "{\"reran\":$RERAN,\"skipped\":$SKIPPED}"
    fi
    exit 0
fi

# ── Mode: scan all open PRs ───────────────────────────────────────────────────

green "=== ci-summary-rerun (PR scan) ==="
[[ $DRY_RUN -eq 1 ]] && info "Dry-run mode — no jobs will be rerun."

PRS_JSON=$(gh pr list --state open --json number,title,headRefName,statusCheckRollup --limit 50 2>/dev/null || echo "[]")
if [[ "$PRS_JSON" == "[]" || -z "$PRS_JSON" ]]; then
    info "No open PRs."
    if [[ "$IN_GITHUB_ACTIONS" != "true" ]]; then
        trap - EXIT
        reaper_finish ok '{"reran":0,"skipped":0}'
    fi
    exit 0
fi

# Extract (pr_num, run_id, title) triples from failed check statusCheckRollup.
PRS=$(echo "$PRS_JSON" | python3 -c "
import json, sys, re
for p in json.load(sys.stdin):
    rollup = p.get('statusCheckRollup') or []
    failed = [c for c in rollup if (c.get('conclusion') or '').upper() in ('FAILURE','ERROR','CANCELLED','TIMED_OUT')]
    runs = set()
    for c in failed:
        url = c.get('targetUrl') or c.get('detailsUrl') or ''
        m = re.search(r'/actions/runs/(\d+)/', url)
        if m:
            runs.add(m.group(1))
    for r in runs:
        print(f\"{p['number']}\t{r}\t{p['title'][:60]}\")
")

while IFS=$'\t' read -r PR_NUM RUN_ID TITLE; do
    [[ -z "$PR_NUM" || -z "$RUN_ID" ]] && continue

    RERUN_CLASS=""; SKIP_REASON=""
    if ! try_rerun_run "$PR_NUM" "$RUN_ID" "$TITLE"; then
        info "PR #$PR_NUM run $RUN_ID: skip ($SKIP_REASON)  ($TITLE)"
        SKIPPED=$((SKIPPED+1))
        continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "would rerun PR #$PR_NUM run $RUN_ID (class: $RERUN_CLASS)  ($TITLE)"
        RERAN=$((RERAN+1))
        continue
    fi

    if gh run rerun "$RUN_ID" --failed >/dev/null 2>&1; then
        date +%s > "$COOLDOWN_DIR/run-${RUN_ID}.ts"
        # Increment per-PR counter.
        pr_count_file="$COOLDOWN_DIR/pr-${PR_NUM}.count"
        pr_count=0; [[ -f "$pr_count_file" ]] && pr_count=$(cat "$pr_count_file" 2>/dev/null || echo 0)
        echo $((pr_count + 1)) > "$pr_count_file"
        green "  reran PR #$PR_NUM run $RUN_ID (class: $RERUN_CLASS, PR-budget=$((pr_count+1))/${CHUMP_FLAKE_BUDGET:-3})"
        RERAN=$((RERAN+1))
        emit_ambient "{\"event\":\"alert\",\"kind\":\"ci_summary_rerun\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pr\":$PR_NUM,\"run\":\"$RUN_ID\",\"class\":\"$RERUN_CLASS\",\"source\":\"ci-summary-rerun\"}"
    else
        warn "PR #$PR_NUM run $RUN_ID: gh run rerun failed"
        SKIPPED=$((SKIPPED+1))
    fi
done <<<"$PRS"

echo ""
green "=== ci-summary-rerun done: $RERAN reran, $SKIPPED skipped ==="

if [[ "$IN_GITHUB_ACTIONS" != "true" ]]; then
    trap - EXIT
    reaper_finish ok "{\"reran\":$RERAN,\"skipped\":$SKIPPED}"
fi
