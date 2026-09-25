#!/usr/bin/env bash
# scripts/coord/state-audit-reconcile.sh — META-1030: the DETERMINISTIC
# state-audit / reconciliation organ. Diffs the fleet's SELF-REPORTS against
# GROUND TRUTH and PAGES (via operator-recall) on any DIVERGENCE.
#
# WHY THIS EXISTS (2026-09 evidence — the gauges lie BOTH ways, nothing caught
# it): worker cycle-kind labeled shipped-and-MERGED work `failed`/`timeout`/
# `unverified`; `worker_stuck`/`fleet_starved`/`AUTH_DEAD` over-alarmed while
# `claude -p` worked; gaps marked `done` that weren't running (RESILIENT-1450);
# merged-≠-running repeatedly; CJ went dark ~21h unpaged. The LLM `fresh-eyes`
# curator's whole mandate is this reconciliation and it caught NONE of it —
# because it is an LLM, it is neither reliable nor cheap enough to run on a
# tight cadence. THIS organ is the deterministic backstop: it uses ZERO
# inference — only file/db/git/systemd/tailscale reads and integer/string
# comparisons — so it is reliable, fast, and cheap enough to run every ~12 min.
#
# CONTRACT (matches the reaper/doctor/effect-verifier style):
#   * NO inference. No `claude`, no LLM, no network beyond `gh`/`tailscale`
#     read-only status the other organs already use.
#   * Read-only w.r.t. fleet state: appends advisory ambient lines and pages
#     through the EXISTING operator-recall.sh path. Never mutates gaps, PRs,
#     units, or the writer/backlog-sync/publish tree.
#   * Every check is INDEPENDENT and CHEAP. A check that cannot obtain its
#     ground truth reports UNKNOWN (itself a gap), NEVER a false AGREE.
#   * One glanceable report line per check:
#         check | self_report | ground_truth | AGREE|DIVERGE|UNKNOWN
#
# CHECKS (self-report vs ground truth):
#   1. cycle_kind_vs_pr    — a recent worker cycle labeled failure whose gap is
#                            actually shipped/merged = LIE (metric under-reports).
#   2. done_vs_running     — the running worker's start time vs the merge time of
#                            worker.sh on origin/main: committed-after-start =
#                            merged-not-running (the #1 disease).
#   3. organ_active_vs_work— an `enabled`+`is-active` organ that emitted NO
#                            expected heartbeat within its cadence = active≠doing.
#   4. node_last_seen      — a fleet node expected up that tailscale reports dark
#                            beyond threshold (the CJ-21h class).
#   5. auth_gauge_vs_probe — a recent AUTH_DEAD-class self-report contradicted by
#                            one cheap REAL auth probe = gauge lie (false AUTH_DEAD).
#   6. picker_vs_preflight — gaps the picker offers that fail pre-pick preflight
#                            (claimed/done/missing) = poison re-pick.  [UNKNOWN;
#                            deepen in follow-up — see NOTES at EOF]
#
# Usage:
#   state-audit-reconcile.sh [tick]     one cycle: run checks, PAGE on DIVERGE, exit 0
#   state-audit-reconcile.sh audit      like tick but print every check line to stdout
#   state-audit-reconcile.sh check-only exit 1 if any DIVERGE (no paging), 0 if clean
#   state-audit-reconcile.sh heartbeat  emit kind=state_audit_heartbeat, exit 0
#   state-audit-reconcile.sh help
#
# Env (all optional; defaults are safe/no-false-page):
#   CHUMP_AMBIENT_LOG                     ambient.jsonl path override
#   CHUMP_STATE_AUDIT_WINDOW_SECS         recency window for checks 1/5 (default 10800 = 3h)
#   CHUMP_STATE_AUDIT_WORKER_UNIT         worker unit for check 2 (default: auto-detect active chump-*worker*.service)
#   CHUMP_STATE_AUDIT_EXPECTED_NODES      comma list of tailscale hostnames expected up (check 4)
#   CHUMP_STATE_AUDIT_EXPECTED_NODES_FILE default .chump/state-audit/expected-nodes.txt (one hostname per line)
#   CHUMP_STATE_AUDIT_NODE_DARK_SECS      dark threshold for check 4 (default 10800 = 3h)
#   CHUMP_STATE_AUDIT_SHIPPED_FILE        test hook: newline list of gap_ids treated as shipped (check 1)
#   CHUMP_STATE_AUDIT_STATE_DB            state.db path (default .chump/state.db)
#   CHUMP_STATE_AUDIT_SYSTEMCTL           systemctl binary (test hook; default systemctl)
#   CHUMP_STATE_AUDIT_TAILSCALE           tailscale binary (test hook; default: first found)
#   CHUMP_STATE_AUDIT_AUTH_STATUS         auth-status.sh path (test hook)
#   CHUMP_STATE_AUDIT_RECALL              operator-recall.sh path (test hook)
#   CHUMP_STATE_AUDIT_NO_PAGE             set 1 to suppress paging even on DIVERGE (audit dry-run)
#
# Rust-First-Bypass: read-only glue over sqlite3 + git + systemctl + tailscale +
#   the existing operator-recall pager; no state mutation beyond append-idempotent
#   ambient lines; an operator/organ diagnostic on a timer, not a hot path. Port
#   to Rust if the comparator set outgrows the shell-OK criteria (META-064).

set -uo pipefail

# ── Locate the MAIN repo (organs run from the checkout; be worktree-safe) ─────
REPO_ROOT="${CHUMP_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
_GIT_COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" || "$_GIT_COMMON" == "$REPO_ROOT/.git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." 2>/dev/null && pwd || echo "$REPO_ROOT")"
fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
SESSION_ID="${CHUMP_SESSION_ID:-state-audit-$$}"
WINDOW_SECS="${CHUMP_STATE_AUDIT_WINDOW_SECS:-10800}"
NODE_DARK_SECS="${CHUMP_STATE_AUDIT_NODE_DARK_SECS:-10800}"
STATE_DB="${CHUMP_STATE_AUDIT_STATE_DB:-$MAIN_REPO/.chump/state.db}"
SYSTEMCTL="${CHUMP_STATE_AUDIT_SYSTEMCTL:-systemctl}"
AUTH_STATUS="${CHUMP_STATE_AUDIT_AUTH_STATUS:-$MAIN_REPO/scripts/coord/auth-status.sh}"
RECALL="${CHUMP_STATE_AUDIT_RECALL:-$MAIN_REPO/scripts/dispatch/operator-recall.sh}"
EXPECTED_NODES_FILE="${CHUMP_STATE_AUDIT_EXPECTED_NODES_FILE:-$MAIN_REPO/.chump/state-audit/expected-nodes.txt}"

_now() { date +%s; }
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── ambient emit (advisory only; append-idempotent; never fatal) ──────────────
# scanner-anchor: "kind":"state_audit_tick"
# scanner-anchor: "kind":"state_audit_divergence"
# scanner-anchor: "kind":"state_audit_heartbeat"
_emit() {
    # _emit <kind> [extra_json...]  (extra already `,"k":"v"` formatted)
    local kind="$1"; shift || true
    local extra="${1:-}"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","session":"%s"%s}\n' \
        "$(_now_iso)" "$kind" "$SESSION_ID" "$extra" >> "$AMBIENT" 2>/dev/null || true
}

_json_escape() {
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"
}

# Lexicographic ISO-8601-UTC compare works; compute the cutoff string once.
_iso_secs_ago() {
    local n="$1"
    date -u -d "@$(( $(_now) - n ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-"${n}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || _now_iso
}

# ── Result accumulation ───────────────────────────────────────────────────────
declare -a REPORT_LINES=()
declare -a DIVERGE_REASONS=()
_DIVERGE_COUNT=0
_UNKNOWN_COUNT=0
_AGREE_COUNT=0

_record() {
    # _record <check> <self_report> <ground_truth> <status> [diverge_reason]
    local check="$1" self="$2" truth="$3" status="$4" reason="${5:-}"
    REPORT_LINES+=("$(printf '%-22s | %-32s | %-32s | %s' "$check" "$self" "$truth" "$status")")
    case "$status" in
        DIVERGE)
            _DIVERGE_COUNT=$((_DIVERGE_COUNT+1))
            DIVERGE_REASONS+=("${check}: ${reason:-$self != $truth}")
            _emit state_audit_divergence \
                ",\"check\":\"$(_json_escape "$check")\",\"self_report\":\"$(_json_escape "$self")\",\"ground_truth\":\"$(_json_escape "$truth")\",\"detail\":\"$(_json_escape "${reason:-}")\""
            ;;
        UNKNOWN) _UNKNOWN_COUNT=$((_UNKNOWN_COUNT+1)) ;;
        AGREE)   _AGREE_COUNT=$((_AGREE_COUNT+1)) ;;
    esac
}

# ── CHECK 1: cycle_kind vs PR reality ─────────────────────────────────────────
# A recent worker_exit labeled a FAILURE whose gap is actually shipped/merged is
# a metric-under-reports-ships LIE. Ground truth of "shipped": state.db gap
# status in {done,closed,shipped,merged} OR shipped_in set OR closed_pr set
# (or, for tests, a gap_id in CHUMP_STATE_AUDIT_SHIPPED_FILE).
_check_cycle_kind_vs_pr() {
    [[ -f "$AMBIENT" ]] || { _record cycle_kind_vs_pr "no ambient log" "unreadable" UNKNOWN; return; }
    local cutoff; cutoff="$(_iso_secs_ago "$WINDOW_SECS")"
    # failure-labeled recent worker cycles → newline list of gap_ids
    local failed_gaps
    failed_gaps="$(awk -v cut="$cutoff" '
        {
            ts=""; if (match($0,/"ts":"[^"]+"/)) ts=substr($0,RSTART+6,RLENGTH-7)
            if (ts < cut) next
            if ($0 !~ /"(kind|event)":"worker_exit"/ && $0 !~ /"kind":"worker_cycle/) next
            # failure-labeled if exit_class is present and not CLEAN/SHIPPED, or rc!=0
            ec=""; if (match($0,/"exit_class":"[^"]*"/)) ec=substr($0,RSTART+14,RLENGTH-15)
            rc=""; if (match($0,/"rc":[0-9]+/)) rc=substr($0,RSTART+5,RLENGTH-5)
            ck=""; if (match($0,/"cycle_kind":"[^"]*"/)) ck=substr($0,RSTART+14,RLENGTH-15)
            failed=0
            if (ec != "" && ec != "CLEAN" && ec != "SHIPPED") failed=1
            if (rc != "" && rc != "0") failed=1
            if (ck ~ /fail|timeout|unverified|error/) failed=1
            if (!failed) next
            gid=""; if (match($0,/"gap_id":"[^"]*"/)) gid=substr($0,RSTART+10,RLENGTH-11)
            if (gid != "") print gid
        }' "$AMBIENT" 2>/dev/null | sort -u)"

    if [[ -z "$failed_gaps" ]]; then
        _record cycle_kind_vs_pr "0 failure-labeled cycles/${WINDOW_SECS}s" "n/a" AGREE
        return
    fi

    local lies=""
    local g
    while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        local shipped=0
        if [[ -n "${CHUMP_STATE_AUDIT_SHIPPED_FILE:-}" && -f "$CHUMP_STATE_AUDIT_SHIPPED_FILE" ]]; then
            grep -qxF "$g" "$CHUMP_STATE_AUDIT_SHIPPED_FILE" 2>/dev/null && shipped=1
        fi
        if [[ "$shipped" == 0 && -f "$STATE_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
            local row
            row="$(sqlite3 "$STATE_DB" \
                "SELECT status, COALESCE(shipped_in,''), COALESCE(closed_pr,'') FROM gaps WHERE id='$(printf '%s' "$g" | sed "s/'/''/g")' LIMIT 1;" 2>/dev/null)"
            if [[ -n "$row" ]]; then
                local st si cp
                st="$(printf '%s' "$row" | cut -d'|' -f1)"
                si="$(printf '%s' "$row" | cut -d'|' -f2)"
                cp="$(printf '%s' "$row" | cut -d'|' -f3)"
                case "$st" in done|closed|shipped|merged) shipped=1 ;; esac
                [[ -n "$si" ]] && shipped=1
                [[ -n "$cp" ]] && shipped=1
            fi
        fi
        [[ "$shipped" == 1 ]] && lies="${lies:+$lies,}$g"
    done <<< "$failed_gaps"

    if [[ -n "$lies" ]]; then
        _record cycle_kind_vs_pr "failure-labeled: $lies" "shipped/merged" DIVERGE \
            "worker cycle-kind under-reports ships: gap(s) [$lies] labeled failure but are shipped/merged"
    else
        _record cycle_kind_vs_pr "$(wc -w <<< "${failed_gaps//$'\n'/ }" | tr -d ' ') failure-labeled" "none shipped" AGREE
    fi
}

# ── CHECK 2: gap=done vs fix-actually-running (worker code freshness) ─────────
# The running worker's ActiveEnterTimestamp vs the merge (commit) time of
# scripts/dispatch/worker.sh on origin/main. If the file was committed to main
# AFTER the worker started, the live worker is executing STALE code — the
# merged-≠-running disease. Ground truth for "code the worker started with" =
# the worker's ActiveEnterTimestamp (systemd's own record of when the current
# invocation began), which never advances until the unit is restarted.
_check_done_vs_running() {
    local tracked_file="scripts/dispatch/worker.sh"
    # merge/commit time of the tracked file on origin/main
    local merged_epoch merged_sha
    merged_epoch="$(git -C "$MAIN_REPO" log -1 --format=%ct origin/main -- "$tracked_file" 2>/dev/null)"
    merged_sha="$(git -C "$MAIN_REPO" log -1 --format=%h origin/main -- "$tracked_file" 2>/dev/null)"
    if [[ -z "$merged_epoch" ]]; then
        _record done_vs_running "worker.sh@origin/main" "git log unavailable" UNKNOWN
        return
    fi

    # discover the running worker unit
    local unit="${CHUMP_STATE_AUDIT_WORKER_UNIT:-}"
    if [[ -z "$unit" ]]; then
        unit="$("$SYSTEMCTL" list-units --type=service --state=running --no-legend --no-pager 2>/dev/null \
            | awk '{print $1}' | grep -E '^chump-.*worker.*\.service$' | head -1)"
    fi
    if [[ -z "$unit" ]]; then
        _record done_vs_running "worker.sh@main ${merged_sha}" "no active worker unit" UNKNOWN
        return
    fi

    local aet
    aet="$("$SYSTEMCTL" show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null)"
    local started_epoch=""
    if [[ -n "$aet" && "$aet" != "n/a" ]]; then
        started_epoch="$(date -d "$aet" +%s 2>/dev/null || true)"
    fi
    if [[ -z "$started_epoch" ]]; then
        _record done_vs_running "worker.sh@main ${merged_sha}" "$unit start-time unreadable" UNKNOWN
        return
    fi

    if (( merged_epoch > started_epoch )); then
        local lag=$(( merged_epoch - started_epoch ))
        _record done_vs_running "worker.sh@main ${merged_sha} (t=${merged_epoch})" \
            "${unit} started t=${started_epoch}" DIVERGE \
            "merged-not-running: ${unit} started ${lag}s BEFORE worker.sh ${merged_sha} landed on origin/main — the live worker is executing stale code (needs restart)"
    else
        _record done_vs_running "worker.sh@main ${merged_sha}" "${unit} running >= merge" AGREE
    fi
}

# ── CHECK 3: organ active vs did-work ─────────────────────────────────────────
# For a known (unit -> heartbeat_kind -> max_age_secs) mapping: if the unit is
# is-active but emitted NO instance of its heartbeat kind within max_age, it is
# active-but-not-doing-its-job. Only VERIFIED heartbeat mappings are checked;
# organs without a known heartbeat kind are left to the follow-up (never a
# false AGREE). Extend ORGAN_HEARTBEATS as heartbeat kinds are confirmed.
_check_organ_active_vs_work() {
    # unit|heartbeat_kind|max_age_secs
    local -a ORGAN_HEARTBEATS=(
        "chump-organ-watchdog.timer|organ_watchdog_tick|3600"
        "chump-effect-verifier.timer|effect_verify_tick|5400"
        "chump-organ-success-verifier.timer|organ_success_verify_tick|5400"
    )
    [[ -f "$AMBIENT" ]] || { _record organ_active_vs_work "n/a" "no ambient log" UNKNOWN; return; }

    local diverged="" checked=0
    local entry unit hb maxage
    for entry in "${ORGAN_HEARTBEATS[@]}"; do
        IFS='|' read -r unit hb maxage <<< "$entry"
        # only evaluate organs that are actually active on THIS node
        "$SYSTEMCTL" is-active --quiet "$unit" 2>/dev/null || continue
        checked=$((checked+1))
        local cutoff; cutoff="$(_iso_secs_ago "$maxage")"
        local seen
        seen="$(awk -v cut="$cutoff" -v k="\"kind\":\"$hb\"" '
            { ts=""; if (match($0,/"ts":"[^"]+"/)) ts=substr($0,RSTART+6,RLENGTH-7)
              if (ts >= cut && index($0,k)>0) c++ } END{print c+0}' "$AMBIENT" 2>/dev/null)"
        if [[ "${seen:-0}" -eq 0 ]]; then
            diverged="${diverged:+$diverged; }${unit} active but 0 ${hb} in ${maxage}s"
        fi
    done

    if [[ "$checked" -eq 0 ]]; then
        _record organ_active_vs_work "no mapped organ active" "n/a" UNKNOWN
    elif [[ -n "$diverged" ]]; then
        _record organ_active_vs_work "active" "no heartbeat" DIVERGE "active≠doing-its-job: $diverged"
    else
        _record organ_active_vs_work "${checked} mapped organ(s) active" "all emitted heartbeat" AGREE
    fi
}

# ── CHECK 4: node last-seen vs should-be-up ───────────────────────────────────
# A fleet node EXPECTED up (from CHUMP_STATE_AUDIT_EXPECTED_NODES or the
# expected-nodes file) that tailscale reports offline beyond NODE_DARK_SECS =
# the CJ-21h-dark class. No expected-node config → UNKNOWN (never false-page:
# we will not decide on our own that someone's phone should be online).
_check_node_last_seen() {
    local expected="${CHUMP_STATE_AUDIT_EXPECTED_NODES:-}"
    if [[ -z "$expected" && -f "$EXPECTED_NODES_FILE" ]]; then
        expected="$(grep -vE '^\s*(#|$)' "$EXPECTED_NODES_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    fi
    if [[ -z "$expected" ]]; then
        _record node_last_seen "no expected-node config" "n/a" UNKNOWN
        return
    fi

    local ts_bin="${CHUMP_STATE_AUDIT_TAILSCALE:-}"
    if [[ -z "$ts_bin" ]]; then
        ts_bin="$(command -v tailscale 2>/dev/null || echo /usr/bin/tailscale)"
    fi
    local status_json
    status_json="$("$ts_bin" status --json 2>/dev/null)"
    if [[ -z "$status_json" ]] || ! command -v python3 >/dev/null 2>&1; then
        _record node_last_seen "expected: $expected" "tailscale status unavailable" UNKNOWN
        return
    fi

    # NOTE: the JSON is fed on STDIN; the Python program is passed via -c (a
    # heredoc would itself claim stdin and starve json.load — the pipe and a
    # `python3 - <<EOF` heredoc cannot both feed stdin).
    local _py_node_check
    _py_node_check='
import sys, json, datetime
expected = [h.strip() for h in sys.argv[1].split(",") if h.strip()]
dark_secs = int(sys.argv[2])
try:
    data = json.load(sys.stdin)
except Exception:
    print("__ERR__"); sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
peers = list((data.get("Peer") or {}).values())
selfnode = data.get("Self") or {}
by_host = {}
for p in peers + [selfnode]:
    h = (p.get("HostName") or "").lower()
    if h:
        by_host[h] = p
dark = []
for want in expected:
    p = by_host.get(want.lower())
    if p is None:
        dark.append(want + "(not-in-tailnet)"); continue
    if p.get("Online"):
        continue
    ls = p.get("LastSeen") or ""
    age = None
    if ls and not ls.startswith("0001"):
        try:
            import re
            # normalize: drop fractional seconds (".1Z"/".123456Z") so
            # fromisoformat parses on Python < 3.11 too, then force UTC.
            norm = re.sub(r"\.\d+", "", ls).replace("Z", "+00:00")
            t = datetime.datetime.fromisoformat(norm)
            age = int((now - t).total_seconds())
        except Exception:
            age = None
    if age is None:
        dark.append(want + "(offline,last-seen-unknown)")
    elif age >= dark_secs:
        dark.append(want + "(dark " + str(age) + "s)")
print(",".join(dark))
'
    local dark
    dark="$(printf '%s' "$status_json" | python3 -c "$_py_node_check" "$expected" "$NODE_DARK_SECS" 2>/dev/null)"

    if [[ "$dark" == "__ERR__" ]]; then
        _record node_last_seen "expected: $expected" "tailscale json parse failed" UNKNOWN
    elif [[ -n "$dark" ]]; then
        _record node_last_seen "expected up: $expected" "dark: $dark" DIVERGE \
            "node(s) expected up are dark beyond ${NODE_DARK_SECS}s: $dark"
    else
        _record node_last_seen "expected up: $expected" "all up/recent" AGREE
    fi
}

# ── CHECK 5: auth gauge vs real probe ─────────────────────────────────────────
# The `auth-status`/AUTH_DEAD gauge lies BOTH ways. We adjudicate the expensive
# direction cheaply: only when a recent AUTH_DEAD-class self-report exists do we
# spend ONE real probe (auth-status.sh --probe, exit 0 = a usable auth path).
# If the probe says usable while the gauge cried dead → the gauge LIED (false
# AUTH_DEAD) → DIVERGE. No recent dead-signal → nothing to adjudicate → AGREE
# (we do not burn a probe every tick; the sub is rate-limited).
_check_auth_gauge_vs_probe() {
    [[ -f "$AMBIENT" ]] || { _record auth_gauge_vs_probe "no ambient log" "unreadable" UNKNOWN; return; }
    local cutoff; cutoff="$(_iso_secs_ago "$WINDOW_SECS")"
    local dead_signals
    dead_signals="$(awk -v cut="$cutoff" '
        { ts=""; if (match($0,/"ts":"[^"]+"/)) ts=substr($0,RSTART+6,RLENGTH-7)
          if (ts < cut) next
          if ($0 ~ /"condition":"AUTH_DEAD"/ || $0 ~ /"kind":"fleet_auth_storm"/ || $0 ~ /"kind":"worker_sub_auth_dead"/ || $0 ~ /"kind":"auth_token_stale"/) c++ }
        END{print c+0}' "$AMBIENT" 2>/dev/null)"

    if [[ "${dead_signals:-0}" -eq 0 ]]; then
        _record auth_gauge_vs_probe "0 auth-dead signals/${WINDOW_SECS}s" "not probed (nothing claimed)" AGREE
        return
    fi

    if [[ ! -x "$AUTH_STATUS" ]]; then
        _record auth_gauge_vs_probe "${dead_signals} auth-dead signal(s)" "auth-status.sh unavailable" UNKNOWN
        return
    fi
    # one real probe
    "$AUTH_STATUS" --probe --quiet >/dev/null 2>&1
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
        _record auth_gauge_vs_probe "${dead_signals} AUTH_DEAD-class signal(s)" "probe: usable (exit 0)" DIVERGE \
            "gauge lie: ${dead_signals} AUTH_DEAD-class self-report(s) in window but a live auth probe returns USABLE — false AUTH_DEAD"
    else
        _record auth_gauge_vs_probe "${dead_signals} AUTH_DEAD-class signal(s)" "probe: NOT usable (exit ${rc})" AGREE
    fi
}

# ── CHECK 6: picker vs preflight ──────────────────────────────────────────────
# Gaps the picker offers that fail pre-pick preflight (claimed/done/missing)
# repeatedly = poison re-pick. Deterministic wiring (picker offer list vs
# preflight verdict) is not yet plumbed here — report UNKNOWN (a gap, never a
# false AGREE). Deepened in the META-1030 follow-up.
_check_picker_vs_preflight() {
    _record picker_vs_preflight "picker offer list" "preflight not yet wired (follow-up)" UNKNOWN
}

# ── Driver ────────────────────────────────────────────────────────────────────
_run_all_checks() {
    _check_cycle_kind_vs_pr
    _check_done_vs_running
    _check_organ_active_vs_work
    _check_node_last_seen
    _check_auth_gauge_vs_probe
    _check_picker_vs_preflight
}

_print_report() {
    printf '%-22s | %-32s | %-32s | %s\n' "check" "self_report" "ground_truth" "verdict"
    printf '%s\n' "-----------------------+----------------------------------+----------------------------------+--------"
    local l
    for l in "${REPORT_LINES[@]}"; do printf '%s\n' "$l"; done
    printf '%s\n' "-----------------------------------------------------------------------------------------------------"
    printf 'SUMMARY: %d AGREE, %d DIVERGE, %d UNKNOWN\n' "$_AGREE_COUNT" "$_DIVERGE_COUNT" "$_UNKNOWN_COUNT"
}

_page_if_diverged() {
    (( _DIVERGE_COUNT == 0 )) && return 0
    [[ "${CHUMP_STATE_AUDIT_NO_PAGE:-0}" == "1" ]] && { echo "[state-audit] NO_PAGE set — not paging ($_DIVERGE_COUNT divergence(s))"; return 0; }
    local reason="state-audit found ${_DIVERGE_COUNT} divergence(s): "
    local r first=1
    for r in "${DIVERGE_REASONS[@]}"; do
        if (( first )); then first=0; else reason="${reason} | "; fi
        reason="${reason}${r}"
    done
    if [[ -x "$RECALL" ]]; then
        # Pass REPO_ROOT + CHUMP_AMBIENT_LOG explicitly: operator-recall resolves
        # its ambient path from REPO_ROOT (falling back to `git rev-parse`/pwd),
        # and this organ runs as a systemd oneshot with CWD=/ where that
        # resolution lands on "/" (unwritable). Anchoring both to the main repo
        # makes the pager's ambient emit + cooldown land in the right place.
        REPO_ROOT="$MAIN_REPO" CHUMP_AMBIENT_LOG="$AMBIENT" \
            "$RECALL" --condition STATE_DIVERGENCE --reason "$reason" || \
            echo "[state-audit] WARNING: operator-recall invocation failed" >&2
    else
        echo "[state-audit] WARNING: operator-recall.sh not executable at $RECALL — cannot page" >&2
    fi
}

_cmd_tick() {
    local print_lines="${1:-0}"
    _run_all_checks
    _emit state_audit_tick \
        ",\"agree\":$_AGREE_COUNT,\"diverge\":$_DIVERGE_COUNT,\"unknown\":$_UNKNOWN_COUNT"
    [[ "$print_lines" == "1" ]] && _print_report
    _page_if_diverged
    return 0
}

case "${1:-tick}" in
    tick)        _cmd_tick 0 ;;
    audit)       _cmd_tick 1 ;;
    check-only)
        _run_all_checks
        _print_report
        (( _DIVERGE_COUNT > 0 )) && exit 1 || exit 0
        ;;
    heartbeat)   _emit state_audit_heartbeat; exit 0 ;;
    help|-h|--help)
        sed -n '2,60p' "$0"; exit 0 ;;
    *)
        echo "Usage: $0 [tick|audit|check-only|heartbeat|help]" >&2; exit 2 ;;
esac
