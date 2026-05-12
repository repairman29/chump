#!/usr/bin/env bash
# system-invariants-monitor.sh — META-033
#
# Single launchd job (10 min cadence) that asserts cross-cutting health
# properties. Each invariant is an independent function. On violation, emits
# kind=invariant_violation to ambient.jsonl and, after 2+ consecutive failures,
# auto-files an INFRA cleanup gap.
#
# Invariants:
#   INV-1: Open PRs failing on same CI step <= 2
#   INV-2: No domain has > 100 open gaps OR > 50% of total
#   INV-3: Every reaper heartbeat fresher than 4h
#   INV-4: Disk free >= 10% on /, /System/Volumes/Data, ~/Projects
#   INV-5: No two launchd plists baked under the same worktree subpath
#   INV-6: Every required CI shard green on origin/main in the last 4h
#   INV-7: No main-shipped commit reduces the green-test count
#
# Install: scripts/setup/install-system-invariants-launchd.sh
# State:   .chump-locks/invariant-state.json

set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$(realpath "$0")")" rev-parse --show-toplevel 2>/dev/null \
    || git rev-parse --git-common-dir 2>/dev/null | xargs -I{} dirname {} \
    || pwd)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="${CHUMP_INVARIANT_STATE:-$LOCK_DIR/invariant-state.json}"

mkdir -p "$LOCK_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────
ts()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
info()  { echo "[invariants] $*"; }
warn()  { echo "[invariants] WARN: $*" >&2; }

emit_violation() {
    local inv="$1" details="$2"
    printf '{"ts":"%s","kind":"invariant_violation","inv":"%s","details":"%s"}\n' \
        "$(ts)" "$inv" "${details//\"/\\\"}" >> "$AMBIENT_LOG" 2>/dev/null || true
    warn "$inv VIOLATED: $details"
}

emit_ok() {
    local inv="$1"
    printf '{"ts":"%s","kind":"invariant_ok","inv":"%s"}\n' \
        "$(ts)" "$inv" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# State: track consecutive failures per invariant for auto-gap-filing.
# Format: {"INV-1": 0, "INV-2": 3, ...}
get_fail_count() {
    local inv="$1"
    python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('$inv', 0))
except: print(0)
" 2>/dev/null || echo 0
}

set_fail_count() {
    local inv="$1" count="$2"
    python3 - "$STATE_FILE" "$inv" "$count" << 'PYEOF' 2>/dev/null || true
import json, sys, os
sf, inv, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    d = json.load(open(sf)) if os.path.exists(sf) else {}
except Exception:
    d = {}
d[inv] = count
json.dump(d, open(sf, 'w'), indent=2)
PYEOF
}

auto_file_gap() {
    local inv="$1" detail="$2"
    # Only file if chump is available and gap isn't already open
    command -v chump >/dev/null 2>&1 || return 0
    local title="invariant $inv broken: ${detail:0:60}"
    # Check for existing open gap with this title prefix
    if chump gap list --status open 2>/dev/null | grep -q "invariant $inv broken"; then
        info "auto-gap for $inv already open — skipping"
        return 0
    fi
    chump gap reserve --domain INFRA --title "RESILIENT: $title" 2>/dev/null || true
    info "auto-filed gap for $inv"
}

check_and_record() {
    local inv="$1" status="$2" detail="${3:-}"
    local prev_count
    prev_count=$(get_fail_count "$inv")
    if [[ "$status" == "ok" ]]; then
        set_fail_count "$inv" 0
        emit_ok "$inv"
        info "$inv OK"
    else
        local new_count=$(( prev_count + 1 ))
        set_fail_count "$inv" "$new_count"
        emit_violation "$inv" "$detail"
        if [[ "$new_count" -ge 2 ]]; then
            info "$inv: $new_count consecutive failures — auto-filing gap"
            auto_file_gap "$inv" "$detail"
        fi
    fi
}

# ── INV-1: Open PRs failing on same CI step <= 2 ─────────────────────────────
check_inv1() {
    info "INV-1: checking PR CI step cluster..."
    if ! command -v gh >/dev/null 2>&1; then
        info "INV-1: gh not available — skipping"
        return
    fi
    local worst_count detail
    worst_count=$(gh pr list --state open --limit 50 --json number,statusCheckRollup \
        --jq '
          [.[].statusCheckRollup[]?
           | select(.conclusion == "FAILURE")
           | .name] 
          | group_by(.)
          | map({step: .[0], count: length})
          | max_by(.count)
          | .count // 0
        ' 2>/dev/null || echo "0")
    worst_count="${worst_count//[[:space:]]/}"
    if [[ -z "$worst_count" || "$worst_count" == "null" ]]; then
        worst_count=0
    fi
    if [[ "$worst_count" -gt 2 ]]; then
        detail="$worst_count open PRs failing on same CI step"
        check_and_record "INV-1" "fail" "$detail"
    else
        check_and_record "INV-1" "ok"
    fi
}

# ── INV-2: No domain > 100 open gaps or > 50% of total ──────────────────────
check_inv2() {
    info "INV-2: checking gap domain distribution..."
    if ! command -v chump >/dev/null 2>&1; then
        info "INV-2: chump not available — skipping"
        return
    fi
    local result
    result=$(chump gap list --status open 2>/dev/null | python3 - << 'PYEOF'
import sys, re, collections
lines = sys.stdin.read().splitlines()
total = len(lines)
if total == 0:
    print("ok")
    sys.exit()
domains = collections.Counter()
for line in lines:
    m = re.match(r'\[open\] ([A-Z]+)-', line)
    if m:
        domains[m.group(1)] += 1
worst_domain, worst_count = domains.most_common(1)[0] if domains else ("", 0)
pct = worst_count * 100 // total
if worst_count > 100 or pct > 50:
    print(f"fail:{worst_domain}={worst_count}/{total} ({pct}%)")
else:
    print("ok")
PYEOF
)
    if [[ "$result" == ok ]]; then
        check_and_record "INV-2" "ok"
    else
        check_and_record "INV-2" "fail" "${result#fail:}"
    fi
}

# ── INV-3: Every reaper heartbeat fresher than 4h ────────────────────────────
check_inv3() {
    info "INV-3: checking reaper heartbeat freshness..."
    local heartbeat_file="$LOCK_DIR/reaper-heartbeat.json"
    if [[ ! -f "$heartbeat_file" ]]; then
        # No heartbeat file — reaper may never have run (not a violation if also no gaps)
        info "INV-3: no reaper heartbeat file at $heartbeat_file — skipping"
        return
    fi
    local age_secs max_age=14400  # 4h
    age_secs=$(python3 -c "
import json, time, datetime
try:
    d = json.load(open('$heartbeat_file'))
    ts_str = d.get('ts') or d.get('timestamp') or d.get('heartbeat_at', '')
    ts = datetime.datetime.fromisoformat(ts_str.rstrip('Z')).replace(
        tzinfo=datetime.timezone.utc)
    age = int((datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds())
    print(age)
except Exception as e:
    print(-1)
" 2>/dev/null || echo -1)
    if [[ "$age_secs" -lt 0 ]]; then
        info "INV-3: could not parse heartbeat timestamp — skipping"
        return
    fi
    if [[ "$age_secs" -gt "$max_age" ]]; then
        check_and_record "INV-3" "fail" "reaper heartbeat is ${age_secs}s old (threshold ${max_age}s)"
    else
        check_and_record "INV-3" "ok"
    fi
}

# ── INV-4: Disk free >= 10% on key paths ─────────────────────────────────────
check_inv4() {
    info "INV-4: checking disk space..."
    local paths=("/" "/System/Volumes/Data" "$HOME/Projects")
    local violations=()
    for p in "${paths[@]}"; do
        [[ -d "$p" ]] || continue
        local pct_used
        pct_used=$(df -P "$p" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}' || echo "")
        [[ -n "$pct_used" ]] || continue
        local pct_free=$(( 100 - pct_used ))
        if [[ "$pct_free" -lt 5 ]]; then
            violations+=("CRITICAL: $p ${pct_free}% free")
        elif [[ "$pct_free" -lt 10 ]]; then
            violations+=("$p ${pct_free}% free")
        fi
    done
    if [[ "${#violations[@]}" -gt 0 ]]; then
        check_and_record "INV-4" "fail" "${violations[*]}"
    else
        check_and_record "INV-4" "ok"
    fi
}

# ── INV-5: No two launchd plists under same worktree subpath ─────────────────
check_inv5() {
    info "INV-5: checking launchd plist path uniqueness..."
    local plist_dirs=("$HOME/Library/LaunchAgents" "/Library/LaunchDaemons")
    local all_paths=()
    for d in "${plist_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        while IFS= read -r plist; do
            # Extract ProgramArguments paths from plist
            local wt_path
            wt_path=$(python3 -c "
import plistlib, sys
try:
    with open('$plist', 'rb') as f:
        pl = plistlib.load(f)
    args = pl.get('ProgramArguments', [])
    for a in args:
        if '.claude/worktrees' in a or '.chump/worktrees' in a or '/tmp/chump-' in a:
            print(a)
            break
except: pass
" 2>/dev/null || true)
            [[ -n "$wt_path" ]] && all_paths+=("$wt_path")
        done < <(find "$d" -name "com.chump*.plist" -maxdepth 1 2>/dev/null)
    done
    if [[ "${#all_paths[@]}" -le 0 ]]; then
        check_and_record "INV-5" "ok"
        return
    fi
    # Check for duplicates
    local sorted_paths
    sorted_paths=$(printf '%s\n' "${all_paths[@]}" | sort)
    local unique_count dup_count
    unique_count=$(printf '%s\n' "${all_paths[@]}" | sort -u | wc -l | tr -d ' ')
    dup_count=$(printf '%s\n' "${all_paths[@]}" | wc -l | tr -d ' ')
    if [[ "$dup_count" -gt "$unique_count" ]]; then
        check_and_record "INV-5" "fail" "$((dup_count - unique_count)) duplicate worktree plist paths"
    else
        check_and_record "INV-5" "ok"
    fi
}

# ── INV-6: Required CI shards green on origin/main in last 4h ────────────────
check_inv6() {
    info "INV-6: checking required CI shards on origin/main..."
    if ! command -v gh >/dev/null 2>&1; then
        info "INV-6: gh not available — skipping"
        return
    fi
    local required_checks=("test" "audit" "ACP protocol smoke test (Zed / JetBrains compatible)")
    local main_sha
    main_sha=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null || true)
    [[ -n "$main_sha" ]] || { info "INV-6: can't resolve origin/main — skipping"; return; }

    local failed_checks=()
    for check in "${required_checks[@]}"; do
        local result
        result=$(gh api "repos/{owner}/{repo}/commits/$main_sha/check-runs" \
            --jq ".check_runs[] | select(.name == \"$check\") | .conclusion" \
            2>/dev/null | head -1 || true)
        if [[ "$result" != "success" && -n "$result" ]]; then
            failed_checks+=("$check: $result")
        fi
    done
    if [[ "${#failed_checks[@]}" -gt 0 ]]; then
        check_and_record "INV-6" "fail" "failing: ${failed_checks[*]}"
    else
        check_and_record "INV-6" "ok"
    fi
}

# ── INV-7: No main-shipped commit reduces green-test count ───────────────────
check_inv7() {
    info "INV-7: checking that origin/main hasn't reduced green tests..."
    # Quick heuristic: check if 'cargo test' count decreased by comparing
    # the last CI run's test summary on origin/main vs HEAD~10
    # Full nightly cargo-test run is too slow for 10-min monitor; use
    # a cached result file instead (written by the nightly CI job).
    local cache_file="$LOCK_DIR/inv7-test-count.json"
    if [[ ! -f "$cache_file" ]]; then
        info "INV-7: no test count cache at $cache_file — skipping (nightly job writes this)"
        return
    fi
    local result
    result=$(python3 - "$cache_file" << 'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    curr = d.get('current', 0)
    prev = d.get('baseline', 0)
    delta = curr - prev
    if delta < 0:
        print(f"fail:green-test count dropped by {-delta} (was {prev}, now {curr})")
    else:
        print("ok")
except Exception as e:
    print("ok")  # no cache = no violation
PYEOF
)
    if [[ "$result" == ok ]]; then
        check_and_record "INV-7" "ok"
    else
        check_and_record "INV-7" "fail" "${result#fail:}"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    info "=== system-invariants-monitor run at $(ts) ==="
    check_inv1
    check_inv2
    check_inv3
    check_inv4
    check_inv5
    check_inv6
    check_inv7
    info "=== done ==="
}

main "$@"
