#!/usr/bin/env bash
# fleet-doctor-strict.sh — INFRA-1427
#
# Single command exits non-zero if ANY fleet health check fails.
# "One number for: is the fleet healthy?"
#
# Usage
#   scripts/coord/fleet-doctor-strict.sh [--json] [--verbose]
#
# Checks (all must pass for exit 0)
#   1. binary           — chump binary exists and is not stale vs source
#   2. leases           — no expired leases older than LEASE_STALE_HOURS (default 2)
#   3. disk             — free disk >= DISK_MIN_GB (default 5)
#   4. dirty-prs        — no open PRs in DIRTY state for > DIRTY_PR_HOURS (default 24)
#   5. gap-drift        — no unresolved gap-drift (open gaps with closed PRs, etc.)
#   6. p0-budget        — open P0 gap count <= P0_MAX (default 5)
#   7. pillar-cover     — every pillar has >= PILLAR_MIN (default 2) pickable gaps
#   8. silent-fleet-death — INFRA-2040: last-merge-mtime >12h AND any com/dev.chump.*
#                           launchd daemon has last exit code != 0 → emit
#                           kind=silent_fleet_death; optional auto-heal via
#                           CHUMP_DOCTOR_AUTOHEAL=1
#
# Thresholds (override via env)
#   LEASE_STALE_HOURS         default 2    — leases older than N hours are flagged
#   DISK_MIN_GB               default 5    — fail if free disk below N GB
#   DIRTY_PR_HOURS            default 24   — DIRTY PRs older than N hours are flagged
#   P0_MAX                    default 5    — fail if more than N open P0 gaps
#   PILLAR_MIN                default 2    — fail if any pillar has fewer than N pickable gaps
#   SILENT_DEATH_MERGE_HOURS  default 12   — last-merge older than N hours triggers check 1
#   CHUMP_DOCTOR_AUTOHEAL     default 0    — set 1 to auto-restore missing scripts + bounce daemons
#
# Bypass: CHUMP_FLEET_DOCTOR=0 exits 0 (for scripted contexts that want raw signal).
#
# Rust-First-Bypass: read-only health aggregator over existing CLI tools; no
#   state mutation; operator diagnostic called on demand, not in hot path.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
AMBIENT_EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
CHUMP_BIN="${CHUMP_BIN:-chump}"

# ── Thresholds ─────────────────────────────────────────────────────────────────
LEASE_STALE_HOURS="${LEASE_STALE_HOURS:-2}"
DISK_MIN_GB="${DISK_MIN_GB:-5}"
DIRTY_PR_HOURS="${DIRTY_PR_HOURS:-24}"
P0_MAX="${P0_MAX:-5}"
PILLAR_MIN="${PILLAR_MIN:-2}"
SILENT_DEATH_MERGE_HOURS="${SILENT_DEATH_MERGE_HOURS:-12}"
CHUMP_DOCTOR_AUTOHEAL="${CHUMP_DOCTOR_AUTOHEAL:-0}"

# ── Arg parsing ────────────────────────────────────────────────────────────────
OUTPUT="human"     # or "json"
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    OUTPUT="json"; shift ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_FLEET_DOCTOR:-1}" == "0" ]]; then
    exit 0
fi

# ── Check harness ─────────────────────────────────────────────────────────────
CHECKS=()       # parallel arrays: CHECK_NAME, CHECK_STATUS, CHECK_DETAIL, CHECK_REMEDY
STATUSES=()
DETAILS=()
REMEDIES=()
PASS_COUNT=0
FAIL_COUNT=0

register_check() {
    local name="$1" status="$2" detail="$3" remedy="$4"
    CHECKS+=("$name")
    STATUSES+=("$status")
    DETAILS+=("$detail")
    REMEDIES+=("$remedy")
    if [[ "$status" == "pass" ]]; then
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
}

# ── Check 1: Binary staleness ──────────────────────────────────────────────────
check_binary() {
    local binary_path
    binary_path="$(command -v "$CHUMP_BIN" 2>/dev/null || true)"
    if [[ -z "$binary_path" ]]; then
        register_check "binary" "fail" \
            "chump binary not found in PATH" \
            "cd $REPO_ROOT && cargo build --bin chump"
        return
    fi

    # Compare binary mtime vs most recent src/ change.
    local src_newest_mtime
    src_newest_mtime="$(find "$REPO_ROOT/src" -name '*.rs' -newer "$binary_path" \
        2>/dev/null | head -1)"

    if [[ -n "$src_newest_mtime" ]]; then
        register_check "binary" "fail" \
            "binary is older than src/*.rs (source changed since last build)" \
            "cd $REPO_ROOT && cargo build --bin chump"
    else
        register_check "binary" "pass" \
            "binary is up to date ($binary_path)" \
            ""
    fi
}

# ── Check 2: Expired leases ────────────────────────────────────────────────────
check_leases() {
    local stale=()
    local now_ts
    now_ts="$(date -u +%s)"
    local cutoff_ts=$(( now_ts - LEASE_STALE_HOURS * 3600 ))

    for lock in "$REPO_ROOT"/.chump-locks/claim-*.json; do
        [[ -f "$lock" ]] || continue
        local expires gap_id
        expires="$(python3 -c "import sys,json; d=json.load(open('$lock')); print(d.get('expires_at',''))" 2>/dev/null || true)"
        gap_id="$(python3 -c "import sys,json; d=json.load(open('$lock')); print(d.get('gap_id','?'))" 2>/dev/null || true)"
        [[ -z "$expires" ]] && continue

        local expires_ts
        expires_ts="$(date -u -d "$expires" +%s 2>/dev/null \
            || python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('${expires%Z}').timestamp()))" 2>/dev/null \
            || echo 0)"

        # Lease is stale if it expired more than LEASE_STALE_HOURS ago.
        if [[ "$expires_ts" -lt "$cutoff_ts" ]]; then
            stale+=("$gap_id (expired $expires)")
        fi
    done

    if [[ "${#stale[@]}" -gt 0 ]]; then
        register_check "leases" "fail" \
            "${#stale[@]} lease(s) expired >$LEASE_STALE_HOURS h ago: ${stale[*]}" \
            "ls $REPO_ROOT/.chump-locks/claim-*.json | xargs -I{} chump --release --lease {}"
    else
        register_check "leases" "pass" \
            "no stale leases (threshold: >${LEASE_STALE_HOURS}h expired)" \
            ""
    fi
}

# ── Check 3: Disk space ────────────────────────────────────────────────────────
check_disk() {
    local free_kb free_gb
    free_kb="$(df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    free_gb=$(( free_kb / 1024 / 1024 ))

    if [[ "$free_gb" -lt "$DISK_MIN_GB" ]]; then
        register_check "disk" "fail" \
            "only ${free_gb} GB free (threshold: >=${DISK_MIN_GB} GB)" \
            "bash $REPO_ROOT/scripts/coord/chump-target-reaper.sh --apply  # or manual cleanup"
    else
        register_check "disk" "pass" \
            "${free_gb} GB free (threshold: >=${DISK_MIN_GB} GB)" \
            ""
    fi
}

# ── Check 4: DIRTY PRs older than DIRTY_PR_HOURS ──────────────────────────────
check_dirty_prs() {
    local dirty_old=()
    local cutoff_ts
    cutoff_ts="$(date -u -v-"${DIRTY_PR_HOURS}"H +%s 2>/dev/null \
        || date -u -d "$DIRTY_PR_HOURS hours ago" +%s 2>/dev/null \
        || echo 0)"

    # Use GitHub cache if available, else gh pr list.
    local db="$REPO_ROOT/.chump/github_cache.db"
    if [[ -f "$db" ]]; then
        # Query for DIRTY PRs with updated_at older than threshold.
        while IFS=$'\t' read -r pr_num pr_title updated_at; do
            [[ -z "$pr_num" ]] && continue
            local updated_ts
            updated_ts="$(python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('${updated_at%Z}').timestamp()))" 2>/dev/null || echo 0)"
            if [[ "$updated_ts" -lt "$cutoff_ts" && "$updated_ts" -gt 0 ]]; then
                dirty_old+=("#$pr_num ($pr_title)")
            fi
        done < <(sqlite3 -separator $'\t' "$db" \
            "SELECT number, COALESCE(title,''), COALESCE(updated_at,'') \
             FROM pr_state \
             WHERE mergeable_state = 'DIRTY' AND merged_at IS NULL \
             ORDER BY number DESC" 2>/dev/null || true)
    else
        # Fallback: direct gh api (expensive).
        while IFS=$'\t' read -r pr_num pr_title updated_at; do
            [[ -z "$pr_num" ]] && continue
            dirty_old+=("#$pr_num")
        done < <(gh pr list --repo repairman29/chump --state open \
            --json number,title,updatedAt,mergeStateStatus \
            --jq '.[] | select(.mergeStateStatus=="DIRTY") | [.number|tostring, .title, .updatedAt] | @tsv' \
            2>/dev/null || true)
    fi

    if [[ "${#dirty_old[@]}" -gt 0 ]]; then
        register_check "dirty-prs" "fail" \
            "${#dirty_old[@]} PR(s) DIRTY >$DIRTY_PR_HOURS h: ${dirty_old[*]}" \
            "scripts/coord/chump-pr-triage.sh --all | grep rebase  # then --apply <pr> rebase"
    else
        register_check "dirty-prs" "pass" \
            "no PRs DIRTY >$DIRTY_PR_HOURS h" \
            ""
    fi
}

# ── Check 5: Gap drift ─────────────────────────────────────────────────────────
check_gap_drift() {
    # Use chump gap audit-priorities if available — it detects open-with-closed-pr,
    # double-encoded depends_on, missing-dep refs, etc.
    if ! command -v "$CHUMP_BIN" &>/dev/null; then
        register_check "gap-drift" "skip" "chump binary not found — skipping" ""
        return
    fi

    local audit_out audit_rc
    audit_rc=0
    audit_out="$("$CHUMP_BIN" gap audit-priorities --json 2>/dev/null)" || audit_rc=$?

    if [[ "$audit_rc" -ne 0 ]]; then
        register_check "gap-drift" "fail" \
            "gap audit-priorities exited $audit_rc — drift detected" \
            "$CHUMP_BIN gap audit-priorities  # review output; fix open-with-closed-pr via 'chump gap ship'"
    else
        local open_closed_count
        open_closed_count="$(echo "$audit_out" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('open_with_closed_pr',0))
except:
    print(0)
" 2>/dev/null || echo 0)"
        if [[ "$open_closed_count" -gt 0 ]]; then
            register_check "gap-drift" "fail" \
                "$open_closed_count gap(s) have status=open but closed_pr set" \
                "$CHUMP_BIN gap audit-priorities  # then 'chump gap ship <ID>' per flagged gap"
        else
            register_check "gap-drift" "pass" \
                "no gap drift detected" \
                ""
        fi
    fi
}

# ── Check 6: P0 budget ─────────────────────────────────────────────────────────
check_p0_budget() {
    if ! command -v "$CHUMP_BIN" &>/dev/null; then
        register_check "p0-budget" "skip" "chump binary not found — skipping" ""
        return
    fi

    # Note: chump gap list --priority P0 flag is not reliably filtered by the CLI;
    # grep for the "(P0/" pattern in output instead.
    local p0_count
    p0_count="$("$CHUMP_BIN" gap list --status open 2>/dev/null \
        | grep -c "(P0/")" || p0_count=0

    if [[ "$p0_count" -gt "$P0_MAX" ]]; then
        register_check "p0-budget" "fail" \
            "$p0_count open P0 gaps (threshold: <=$P0_MAX)" \
            "$CHUMP_BIN gap audit-priorities  # demote inflated P0s to P1"
    else
        register_check "p0-budget" "pass" \
            "$p0_count open P0 gaps (threshold: <=$P0_MAX)" \
            ""
    fi
}

# ── Check 7: Pillar coverage ───────────────────────────────────────────────────
check_pillar_coverage() {
    if ! command -v "$CHUMP_BIN" &>/dev/null; then
        register_check "pillar-cover" "skip" "chump binary not found — skipping" ""
        return
    fi

    local starved_pillars=()
    for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        # Count open P0/P1 xs/s/m gaps for this pillar (pickable pool).
        local count
        count="$("$CHUMP_BIN" gap list --status open 2>/dev/null \
            | grep -i "$pillar:" \
            | grep -E "P[01].*(xs|s|m)" \
            | grep -cv "⚠")" || count=0
        if [[ "$count" -lt "$PILLAR_MIN" ]]; then
            starved_pillars+=("$pillar($count)")
        fi
        [[ "$VERBOSE" -eq 1 ]] && echo "[fleet-doctor] pillar $pillar: $count pickable gaps" >&2
    done

    if [[ "${#starved_pillars[@]}" -gt 0 ]]; then
        register_check "pillar-cover" "fail" \
            "pillar(s) below $PILLAR_MIN pickable gaps: ${starved_pillars[*]}" \
            "$CHUMP_BIN gap reserve --domain INFRA --title '<pillar>: <feature>'  # file gaps to rebalance"
    else
        register_check "pillar-cover" "pass" \
            "all pillars have >=$PILLAR_MIN pickable gaps" \
            ""
    fi
}

# ── Check 8: Silent fleet death (INFRA-2040) ───────────────────────────────────
# Condition: last merge into origin/main is >SILENT_DEATH_MERGE_HOURS old
#            AND at least one com.chump.* / dev.chump.* launchd daemon has
#            last exit code != 0.
# When BOTH conditions hold, emit kind=silent_fleet_death to ambient and
# register as FAIL.  Either condition alone is only a warning (skip level).
#
# Optional auto-heal (CHUMP_DOCTOR_AUTOHEAL=1):
#   For each daemon with exit=127 (command not found), check if the plist's
#   ProgramArguments script path exists; if missing but reachable in
#   origin/main, restore via `git checkout origin/main -- <path>` and bounce
#   the daemon with `launchctl kickstart`.
check_silent_fleet_death() {
    # ── Sub-check A: last-merge age ──────────────────────────────────────────
    local last_merge_ts
    last_merge_ts="$(git -C "$REPO_ROOT" log origin/main -1 --format="%ct" 2>/dev/null || echo 0)"
    local now_ts
    now_ts="$(date -u +%s)"
    local merge_age_h=$(( (now_ts - last_merge_ts) / 3600 ))
    local merge_stale=0
    if [[ "$last_merge_ts" -eq 0 || "$merge_age_h" -ge "$SILENT_DEATH_MERGE_HOURS" ]]; then
        merge_stale=1
    fi

    # ── Sub-check B: daemon exit codes ───────────────────────────────────────
    # Only meaningful on macOS with launchctl available.
    local dead_daemons=()
    local dead_exit_codes=()
    local daemon_scan_available=0
    if command -v launchctl &>/dev/null && [[ "$(uname)" == "Darwin" ]]; then
        daemon_scan_available=1
        # List all loaded com.chump.* and dev.chump.* labels.
        local labels=()
        while IFS= read -r label; do
            [[ -z "$label" ]] && continue
            labels+=("$label")
        done < <(launchctl list 2>/dev/null \
            | awk '{print $3}' \
            | grep -E '^(com|dev)\.chump\.' \
            || true)

        for label in "${labels[@]}"; do
            # launchctl print gui/<uid>/<label> or system/<label>.
            local uid
            uid="$(id -u)"
            local print_out
            print_out="$(launchctl print "gui/$uid/$label" 2>/dev/null \
                || launchctl print "system/$label" 2>/dev/null \
                || true)"

            # Extract "last exit code = N" from print output.
            local exit_code
            exit_code="$(echo "$print_out" \
                | grep -E 'last exit code\s*=' \
                | grep -oE '[-]?[0-9]+' \
                | head -1 \
                || true)"
            [[ -z "$exit_code" ]] && continue
            if [[ "$exit_code" != "0" ]]; then
                dead_daemons+=("$label")
                dead_exit_codes+=("$exit_code")
            fi
        done
    fi

    local daemon_fail=0
    [[ "${#dead_daemons[@]}" -gt 0 ]] && daemon_fail=1

    # ── Decision: BOTH conditions needed for silent_fleet_death ──────────────
    if [[ "$merge_stale" -eq 1 && "$daemon_fail" -eq 1 ]]; then
        local dead_list
        dead_list="$(printf '%s(exit=%s) ' "${dead_daemons[@]}" 2>/dev/null || true)"
        # Emit ambient event.
        local event_ts
        event_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local ambient_log="$REPO_ROOT/.chump-locks/ambient.jsonl"
        if [[ -x "$AMBIENT_EMIT" ]]; then
            bash "$AMBIENT_EMIT" silent_fleet_death \
                merge_age_h="$merge_age_h" \
                dead_daemon_count="${#dead_daemons[@]}" \
                dead_daemons="${dead_list}" \
                2>/dev/null || true
        else
            # Fallback: direct printf.
            printf '{"ts":"%s","kind":"silent_fleet_death","merge_age_h":%d,"dead_daemon_count":%d,"dead_daemons":"%s","source":"fleet-doctor-strict.sh"}\n' \
                "$event_ts" "$merge_age_h" "${#dead_daemons[@]}" "${dead_list}" \
                >> "$ambient_log" 2>/dev/null || true
        fi

        # ── Optional auto-heal (CHUMP_DOCTOR_AUTOHEAL=1) ─────────────────────
        local healed_daemons=()
        if [[ "$CHUMP_DOCTOR_AUTOHEAL" == "1" ]] && command -v launchctl &>/dev/null; then
            local uid
            uid="$(id -u)"
            for i in "${!dead_daemons[@]}"; do
                local label="${dead_daemons[$i]}"
                local exit_code="${dead_exit_codes[$i]}"
                [[ "$exit_code" != "127" ]] && continue  # only heal "command not found"

                # Find the plist for this label.
                local plist_path="$HOME/Library/LaunchAgents/${label}.plist"
                [[ -f "$plist_path" ]] || continue

                # Extract ProgramArguments script path from plist.
                # Write the python snippet to a temp file to avoid heredoc-inside-$()
                # which shellcheck (SC1073) cannot parse.
                local _py_extract
                _py_extract="$(mktemp /tmp/chump-plist-extract-XXXXXX.py)"
                printf '%s\n' \
                    'import sys, plistlib' \
                    'with open(sys.argv[1], "rb") as f: pl = plistlib.load(f)' \
                    'args = pl.get("ProgramArguments", [])' \
                    'for a in args:' \
                    '    if a.startswith("/") and not a.startswith("/bin/") and not a.startswith("/usr/"):' \
                    '        print(a); break' \
                    > "$_py_extract"
                local script_path
                script_path="$(python3 "$_py_extract" "$plist_path" 2>/dev/null || true)"
                rm -f "$_py_extract"
                [[ -z "$script_path" ]] && continue
                [[ -f "$script_path" ]] && continue  # script already exists — skip

                # Check if the script exists in origin/main.
                local rel_path="${script_path#"$REPO_ROOT"/}"
                if git -C "$REPO_ROOT" cat-file -e "origin/main:${rel_path}" 2>/dev/null; then
                    [[ "$VERBOSE" -eq 1 ]] && echo "[fleet-doctor] auto-heal: restoring $rel_path from origin/main" >&2
                    git -C "$REPO_ROOT" checkout origin/main -- "$rel_path" 2>/dev/null || continue
                    chmod +x "$script_path" 2>/dev/null || true
                    # Bounce the daemon.
                    launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
                    healed_daemons+=("$label")
                    # Emit autoheal event.
                    if [[ -x "$AMBIENT_EMIT" ]]; then
                        bash "$AMBIENT_EMIT" silent_fleet_death_autohealed \
                            label="$label" \
                            script_path="$script_path" \
                            2>/dev/null || true
                    else
                        printf '{"ts":"%s","kind":"silent_fleet_death_autohealed","label":"%s","script_path":"%s","source":"fleet-doctor-strict.sh"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$script_path" \
                            >> "$ambient_log" 2>/dev/null || true
                    fi
                fi
            done
        fi

        local detail="last merge ${merge_age_h}h ago (threshold: >=${SILENT_DEATH_MERGE_HOURS}h); ${#dead_daemons[@]} daemon(s) with exit!=0: ${dead_list}"
        local remedy="launchctl list | grep -E '(com|dev)\.chump'; git pull origin main; then launchctl kickstart -k gui/\$(id -u)/<label>"
        if [[ "${#healed_daemons[@]}" -gt 0 ]]; then
            detail="${detail}; auto-healed: ${healed_daemons[*]}"
            remedy="auto-heal ran — verify daemons are now running"
        fi

        register_check "silent-fleet-death" "fail" \
            "ALERT: silent-fleet-death — $detail" \
            "$remedy"

    elif [[ "$merge_stale" -eq 1 && "$daemon_scan_available" -eq 1 ]]; then
        # Merge stale but daemons OK — softer warning only (pass, with note).
        register_check "silent-fleet-death" "pass" \
            "last merge ${merge_age_h}h ago (>=${SILENT_DEATH_MERGE_HOURS}h) but all daemons exit=0 — stale branch, fleet alive" \
            ""
    elif [[ "$daemon_fail" -eq 1 ]]; then
        # Daemons failing but recent merge — likely a transient issue, not dead-floor.
        local dead_list
        dead_list="$(printf '%s(exit=%s) ' "${dead_daemons[@]}" 2>/dev/null || true)"
        register_check "silent-fleet-death" "fail" \
            "${#dead_daemons[@]} daemon(s) with exit!=0 (recent merge OK): ${dead_list}" \
            "launchctl kickstart -k gui/\$(id -u)/<label>  # or check daemon logs"
    elif [[ "$daemon_scan_available" -eq 0 ]]; then
        register_check "silent-fleet-death" "skip" \
            "launchctl not available (non-macOS or not loaded) — skipping daemon exit scan" \
            ""
    else
        register_check "silent-fleet-death" "pass" \
            "last merge ${merge_age_h}h ago; all com/dev.chump.* daemons exit=0" \
            ""
    fi
}

# ── Check 9: Required status checks non-empty (INFRA-2201) ─────────────────────
#
# admin-merge-cycle drops required_status_checks during merge; if the restore
# step fails or is skipped, main is silently unprotected. No ambient emit
# fires when this happens — only this check catches the bad state.
#
# Verifies BOTH branch-protection AND ruleset 15133729's
# required_status_checks lists are non-empty. Either being empty is a
# critical resilience breach: any operator with admin can merge unverified
# code without realizing the gate is open.
#
# Bypass: CHUMP_FLEET_DOCTOR_SKIP_REQUIRED_CHECKS=1 (use only when
# intentionally testing the empty-state pattern, e.g. CI for INFRA-2201).
check_required_status_checks() {
    if [[ "${CHUMP_FLEET_DOCTOR_SKIP_REQUIRED_CHECKS:-0}" == "1" ]]; then
        register_check "required-checks" "skip" \
            "CHUMP_FLEET_DOCTOR_SKIP_REQUIRED_CHECKS=1 bypass active" ""
        return
    fi
    if ! command -v gh &>/dev/null; then
        register_check "required-checks" "skip" "gh CLI not in PATH" ""
        return
    fi
    local repo
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
    if [[ -z "$repo" ]]; then
        register_check "required-checks" "skip" \
            "could not resolve repo (no remote OR offline)" ""
        return
    fi

    # Sub-check A: branch-protection required_status_checks
    local bp_count
    bp_count="$(gh api "repos/$repo/branches/main/protection" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    c=d.get("required_status_checks",{}).get("checks",[])
    print(len(c))
except Exception:
    print(0)' || echo 0)"

    # Sub-check B: ruleset required_status_checks (the rule may sit in any
    # active ruleset; sum across all rulesets matching ~DEFAULT_BRANCH).
    local rs_count=0
    local rs_ids
    rs_ids="$(gh api "repos/$repo/rulesets" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    rs=json.load(sys.stdin)
    for r in rs:
        if r.get("enforcement")=="active":
            print(r.get("id",""))
except Exception:
    pass' || true)"
    while IFS= read -r rid; do
        [[ -z "$rid" ]] && continue
        local n
        n="$(gh api "repos/$repo/rulesets/$rid" 2>/dev/null \
            | python3 -c 'import json,sys
try:
    r=json.load(sys.stdin)
    for rule in r.get("rules",[]):
        if rule.get("type")=="required_status_checks":
            print(len(rule.get("parameters",{}).get("required_status_checks",[])))
            break
    else:
        print(0)
except Exception:
    print(0)' || echo 0)"
        rs_count=$(( rs_count + n ))
    done <<< "$rs_ids"

    # Resilience invariant: at least ONE of (branch-prot, ruleset) must
    # have a non-empty required-checks list. Both empty = silent open.
    local total=$(( bp_count + rs_count ))
    if [[ "$total" -eq 0 ]]; then
        # Emit ambient signal so peers / watchdogs see the open state even
        # if fleet-doctor isn't tailed. scanner-anchor: "kind":"required_status_checks_empty" (INFRA-2201)
        local _amb_path="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        local _ts; _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"required_status_checks_empty","bp_count":%d,"ruleset_count":%d,"source":"fleet-doctor-strict"}\n' \
            "$_ts" "$bp_count" "$rs_count" >> "$_amb_path" 2>/dev/null || true
        register_check "required-checks" "fail" \
            "BOTH branch-protection AND ruleset required_status_checks are EMPTY — main is silently UNPROTECTED" \
            "Restore required checks: see scripts/ops/admin-merge-cycle.sh or docs/process/SHEPHERD_LOOP_PLAYBOOK.md Pattern 14"
    else
        register_check "required-checks" "pass" \
            "branch-prot=$bp_count, ruleset=$rs_count (≥1 required for non-empty invariant)" \
            ""
    fi
}

# ── Run all checks ─────────────────────────────────────────────────────────────
check_binary
check_leases
check_disk
check_dirty_prs
check_gap_drift
check_p0_budget
check_pillar_coverage
check_silent_fleet_death
check_required_status_checks

# ── Render output ──────────────────────────────────────────────────────────────
if [[ "$OUTPUT" == "json" ]]; then
    python3 - <<PYEOF
import json, sys
checks = []
names   = $(python3 -c "import json; print(json.dumps(${CHECKS[*]+\"${CHECKS[*]}\"})" 2>/dev/null || echo "[]")
stats   = $(python3 -c "import json; print(json.dumps(${STATUSES[*]+\"${STATUSES[*]}\"})" 2>/dev/null || echo "[]")
details = $(python3 -c "import json; print(json.dumps(${DETAILS[*]+\"${DETAILS[*]}\"})" 2>/dev/null || echo "[]")
PYEOF
    # Simpler JSON render using bash arrays directly.
    printf '{"pass":%d,"fail":%d,"checks":[' "$PASS_COUNT" "$FAIL_COUNT"
    for i in "${!CHECKS[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        python3 -c "import json; print(json.dumps({'name':'${CHECKS[$i]}','status':'${STATUSES[$i]}','detail':'${DETAILS[$i]}','remedy':'${REMEDIES[$i]}'}))" 2>/dev/null \
            || printf '{"name":"%s","status":"%s"}' "${CHECKS[$i]}" "${STATUSES[$i]}"
    done
    printf ']}\n'
else
    echo "=== chump fleet doctor --strict (INFRA-1427) ==="
    echo
    for i in "${!CHECKS[@]}"; do
        local_status="${STATUSES[$i]}"
        if [[ "$local_status" == "pass" ]]; then
            printf '  \033[0;32m✓ PASS\033[0m  %-14s %s\n' "${CHECKS[$i]}" "${DETAILS[$i]}"
        elif [[ "$local_status" == "skip" ]]; then
            printf '  \033[0;33m– SKIP\033[0m  %-14s %s\n' "${CHECKS[$i]}" "${DETAILS[$i]}"
        else
            printf '  \033[0;31m✗ FAIL\033[0m  %-14s %s\n' "${CHECKS[$i]}" "${DETAILS[$i]}"
            if [[ -n "${REMEDIES[$i]}" ]]; then
                printf '             \033[0;33m↳ Fix:\033[0m  %s\n' "${REMEDIES[$i]}"
            fi
        fi
    done
    echo
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "  ✅ Fleet is healthy ($PASS_COUNT checks passed)"
    else
        echo "  ❌ $FAIL_COUNT check(s) failed — fleet needs attention"
    fi
fi

# Emit ambient telemetry (INFRA-755 / kind=fleet_doctor_run).
if [[ -x "$AMBIENT_EMIT" ]]; then
    bash "$AMBIENT_EMIT" fleet_doctor_run \
        pass_count="$PASS_COUNT" fail_count="$FAIL_COUNT" \
        2>/dev/null || true
fi

# Exit non-zero if any check failed (the core contract of --strict).
[[ "$FAIL_COUNT" -eq 0 ]]
