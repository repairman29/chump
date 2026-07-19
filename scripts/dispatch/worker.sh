#!/usr/bin/env bash
# worker.sh — INFRA-203 / INFRA-211: per-agent worker loop.
#
# One instance per fleet pane. Loops until killed:
#   1. git fetch + (best-effort) rebase main into a fresh worktree
#   2. ask musher.py / chump gap list for the next pickable gap
#      (filters: priority, domain, effort)
#   3. claim it via chump claim (atomic flock)
#   4. create a worktree at .claude/worktrees/<gap-id>-<sid>
#   5. spawn `claude -p <focused-prompt> --dangerously-skip-permissions`
#      with FLEET_TIMEOUT_S timeout — same surface as WorkBackend::Headless
#      in src/dispatch.rs (INFRA-191 Phase 2), used directly here because
#      `chump dispatch` does not yet expose the backend on the CLI.
#   6. on exit (success or failure): release lease, prune the worktree,
#      sleep IDLE_SLEEP_S if no gap was found, loop back.
#
# Env (set by run-fleet.sh, but each is overridable):
#   AGENT_ID                pane index (used in session id + logs)
#   REPO_ROOT               main checkout
#   FLEET_LOG_DIR           where to write per-cycle logs
#   FLEET_TIMEOUT_S         per-claude-call timeout (default 1800)
#   FLEET_PRIORITY_FILTER   default P0,P1
#   FLEET_DOMAIN_FILTER     default "" = any
#   FLEET_EFFORT_FILTER     default xs,s,m
#   FLEET_BACKEND           default claude — runs `claude -p` (AUTO-013 path,
#                           Anthropic API, haiku by default). "chump-local"
#                           fans calls through the free-tier cascade (INFRA-259)
#                           but requires CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1
#                           (INFRA-459: cascade bank too small 2026-05-04).
#   IDLE_SLEEP_S            default 60 — sleep when no pickable gap

set -uo pipefail   # NOT -e: we want the loop to recover from individual cycle failures

# INFRA-2002 / META-107 sub-gap #6 — Rust port feature flag.
# When CHUMP_WORKER_RUST=1, exec the chump-worker binary and skip the
# legacy bash body below. Default 0 = run legacy body inline (parallel-run
# discipline mirroring INFRA-1997 / INFRA-1998 / INFRA-1999 / INFRA-2000).
if [[ "${CHUMP_WORKER_RUST:-0}" = "1" ]]; then
    # Prefer co-located binary, then PATH lookup. chump-worker is built
    # from crates/chump-coord/src/bin/chump-worker.rs.
    _chump_worker_bin="${CHUMP_WORKER_BIN:-}"
    if [[ -z "$_chump_worker_bin" ]]; then
        for _cand in \
            "$(git rev-parse --show-toplevel 2>/dev/null)/target/debug/chump-worker" \
            "$(git rev-parse --show-toplevel 2>/dev/null)/target/release/chump-worker" \
            "$(command -v chump-worker 2>/dev/null || true)"; do
            if [[ -n "$_cand" && -x "$_cand" ]]; then
                _chump_worker_bin="$_cand"
                break
            fi
        done
    fi
    if [[ -n "$_chump_worker_bin" && -x "$_chump_worker_bin" ]]; then
        exec "$_chump_worker_bin" "$@"
    fi
    echo "[worker.sh] CHUMP_WORKER_RUST=1 but chump-worker binary not found; falling back to bash body" >&2
fi

# INFRA-569: --dry-run flag. When set, pick a gap, print the would-be claim,
# and exit 0 without writing a lease, creating a worktree, or spawning claude.
# Activated by --dry-run CLI flag or CHUMP_FLEET_DRY_RUN=1 env var.
DRY_RUN="${CHUMP_FLEET_DRY_RUN:-0}"
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=1 ;;
    esac
done
export CHUMP_FLEET_DRY_RUN="$DRY_RUN"

AGENT_ID="${AGENT_ID:-?}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# INFRA-461: derive a unique per-worker session ID so leases written by this
# worker (or any chump/coord subprocess it invokes) DO NOT stomp the
# operator's interactive session via the .chump-locks/.wt-session-id
# fallback in the chump claim resolution chain. Workers run with
# cwd=$REPO_ROOT (the main worktree); without this export, chump claim
# picks up `.wt-session-id` and every fleet worker writes the lease under
# the operator's interactive session ID — observed live 2026-05-04 with
# multiple SWARM-* claims overwriting an active interactive INFRA-458
# lease.
#
# Session ID shape: fleet-<tmux-session>-agent<N>-<pid>-<epoch>. tmux
# session name is unique per fleet spawn; PID + epoch make sibling
# workers in the same fleet collision-free.
if [[ -z "${CHUMP_SESSION_ID:-}" ]]; then
    # shellcheck disable=SC2155  # single-use identifier; masking return value acceptable
    export CHUMP_SESSION_ID="fleet-${FLEET_SESSION:-fleet}-agent${AGENT_ID}-$$-$(date +%s)"
fi
FLEET_LOG_DIR="${FLEET_LOG_DIR:-/tmp/chump-fleet-default}"
FLEET_TIMEOUT_S="${FLEET_TIMEOUT_S:-1800}"
# RESILIENT-135: immutable base for per-cycle effort scaling. The scaler MUST
# derive from THIS each cycle, never from the (already-scaled) FLEET_TIMEOUT_S —
# otherwise consecutive xs gaps compound the x0.5 multiplier and collapse the
# claude -p budget toward 0s (the timeout death-spiral that zeroed completion).
FLEET_TIMEOUT_BASE_S="$FLEET_TIMEOUT_S"
if [ -r "$REPO_ROOT/scripts/dispatch/lib/worker-timeout.sh" ]; then
    # shellcheck source=lib/worker-timeout.sh
    source "$REPO_ROOT/scripts/dispatch/lib/worker-timeout.sh"
fi
FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_AGENT_DOMAINS="${FLEET_AGENT_DOMAINS:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"
# INFRA-738 + INFRA-1717: auto-detect backend by checking all claude auth paths.
# Pre-INFRA-1717 only ANTHROPIC_API_KEY was checked, so OAUTH-subscription
# sessions (token in env CLAUDE_CODE_OAUTH_TOKEN or refreshed to
# ~/.chump/oauth-token.json by parent app) mis-routed to chump-local even
# though `claude -p` would have worked fine via the OAUTH path.
if [[ -z "${ANTHROPIC_API_KEY:-}" \
   && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" \
   && ! -s "${HOME}/.chump/oauth-token.json" ]]; then
    FLEET_BACKEND="${FLEET_BACKEND:-chump-local}"
else
    FLEET_BACKEND="${FLEET_BACKEND:-claude}"
fi
FLEET_MODEL="${FLEET_MODEL:-sonnet}"
IDLE_SLEEP_S="${IDLE_SLEEP_S:-60}"
# INFRA-525: how many seconds before FLEET_TIMEOUT_S to fire the WIP checkpoint.
CHUMP_TIMEOUT_CHECKPOINT_SECS="${CHUMP_TIMEOUT_CHECKPOINT_SECS:-30}"

# INFRA-1045: harness dispatch — which AI tool drives this worker.
# Values: claude (default) / opencode / codex / manual
# Each harness defines HARNESS_SPAWN_PROGRAM, HARNESS_SPAWN_MODE,
# HARNESS_GIT_EMAIL, HARNESS_GIT_NAME in scripts/dispatch/harnesses/<name>.sh.
CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-claude}"
export CHUMP_AGENT_HARNESS
HARNESS_SPAWN_PROGRAM="claude"
HARNESS_SPAWN_MODE="claude-p"
HARNESS_GIT_EMAIL=""
HARNESS_GIT_NAME=""
_harness_cfg="${BASH_SOURCE[0]%/*}/harnesses/${CHUMP_AGENT_HARNESS}.sh"
if [[ -f "$_harness_cfg" ]]; then
    # shellcheck source=/dev/null
    source "$_harness_cfg"
fi

# INFRA-315: poll-jitter + idle-backpressure. Without jitter, N workers
# wake up at the same instant and stampede the same gap (observed live
# 2026-05-02 cascade fleet run: 4 workers all picked INFRA-187 because
# their poll loops were phase-locked). Default ±30% randomization breaks
# the synchronization without adding much wall-clock overhead.
CHUMP_POLL_JITTER="${CHUMP_POLL_JITTER:-30}"
# After this many consecutive empty picks, the worker emits a
# kind=fleet_starved ambient event so the operator sees that the fleet
# is idle (filters too tight, queue actually empty, etc.) instead of
# guessing why workers are quiet.
CHUMP_STARVE_THRESHOLD="${CHUMP_STARVE_THRESHOLD:-3}"
# INFRA-613: After this many consecutive empty picks, the worker emits
# kind=worker_stand_down and exits cleanly so the fleet auto-restart daemon
# (INFRA-611) can optionally respawn with relaxed filters or scale down.
CHUMP_STAND_DOWN_THRESHOLD="${CHUMP_STAND_DOWN_THRESHOLD:-5}"

# INFRA-1933: shared Cargo target dir — all worktrees reuse one build cache
# instead of each creating its own 5-11 GB target/ tree. Callers may override
# by setting CARGO_TARGET_DIR before sourcing this file.
if [[ -z "${CARGO_TARGET_DIR:-}" ]]; then
    export CARGO_TARGET_DIR="${CHUMP_SHARED_CARGO_TARGET:-$HOME/.cargo/chump-shared-target}"
    mkdir -p "$CARGO_TARGET_DIR" 2>/dev/null || true
    printf '{"ts":"%s","kind":"cargo_target_dir_shared","source":"worker.sh","target_dir":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CARGO_TARGET_DIR" \
        >> "${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}" 2>/dev/null || true
else
    printf '{"ts":"%s","kind":"cargo_target_dir_external","source":"worker.sh","target_dir":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CARGO_TARGET_DIR" \
        >> "${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-.}/.chump-locks/ambient.jsonl}" 2>/dev/null || true
fi

# Per-worker counter of consecutive empty picks. Reset on every
# successful pick.
_starve_count=0
# Per-worker counter of consecutive dispatch failures. Reset on successful ship.
_dispatch_fail_count=0
# Exponential backoff state for empty picks: tracks current backoff multiplier.
_backoff_multiplier=1
# FLEET-042: heartbeat state for health monitoring.
_last_heartbeat=$(date +%s)
_heartbeat_interval=60

# INFRA-823: per-worker wedge tracking for first-output watchdog and storm detection.
# INFRA-828: CHUMP_FIRST_OUTPUT_WATCHDOG=0 disables the watchdog entirely.
_wedge_retries=0
_wedge_count=0
_wedge_storm_threshold="${CHUMP_WEDGE_STORM_THRESHOLD:-5}"
_first_output_timeout="${CHUMP_FIRST_OUTPUT_TIMEOUT_S:-120}"
# INFRA-705: stall-detector threshold (seconds of no new output before kill).
# Distinct from FIRST_OUTPUT_TIMEOUT: fires on mid-cycle stalls, not just zero initial output.
_stall_threshold_default="${CHUMP_STALL_THRESHOLD_S:-120}"

mkdir -p "$FLEET_LOG_DIR"

log() { printf '[worker:%s %s] %s\n' "$AGENT_ID" "$(date -u +%H:%M:%S)" "$*"; }

# INFRA-2029: emit kind=worker_stuck to ambient.jsonl whenever this worker
# exits a cycle without shipping (claim failed, preflight fail, no pickable
# gap, lease collision, worktree create fail, stand-down, etc.).
# Usage: _emit_worker_stuck "reason_string"
_emit_worker_stuck() {
    local _reason="${1:-unknown}"
    local _amb_stuck="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$_amb_stuck")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"worker_stuck","agent_id":"%s","session":"%s","gap_id":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$AGENT_ID" \
        "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
        "${GAP_ID:-none}" \
        "$_reason" \
        >> "$_amb_stuck" 2>/dev/null || true
    log "INFRA-2029: kind=worker_stuck reason=$_reason"
}

# FLEET-042: write heartbeat file with current epoch + gap_id.
write_heartbeat() {
    local gap_id="${1:-none}"
    local now; now=$(date +%s)
    local heartbeat_file="/tmp/chump-fleet-worker-${AGENT_ID}.heartbeat"
    printf '%s %s\n' "$now" "$gap_id" > "$heartbeat_file" 2>/dev/null || true
}

# INFRA-620: re-read CLAUDE_CODE_OAUTH_TOKEN from ~/.chump/oauth-token.json
# before each claude -p spawn. Prevents auth_storm when the inherited token
# expires after ~30-60min in subscription mode (the parent Claude Code app
# refreshes its token in-process; already-spawned workers keep the OLD value
# unless we actively re-read a file that run-fleet.sh's refresher keeps current).
# Falls back to ANTHROPIC_API_KEY when token file is missing/empty/expired.
refresh_oauth_token() {
    local token_file="${CHUMP_OAUTH_TOKEN_FILE:-}"
    [[ -z "$token_file" ]] && return 0  # api_key mode — nothing to do
    local tok=""
    if [[ -f "$token_file" ]]; then
        tok=$(python3 -c "
import json, sys
try:
    d = json.load(open('$token_file'))
    print(d.get('token',''))
except Exception:
    pass
" 2>/dev/null || true)
    fi
    if [[ -n "$tok" ]]; then
        export CLAUDE_CODE_OAUTH_TOKEN="$tok"
        # CREDIBLE-137: a valid subscription token is present — drop any inherited
        # ANTHROPIC_API_KEY so `claude -p` uses OAuth, not a key claude PREFERS but
        # which may be depleted (api_error_status=400 "Credit balance is too low"
        # → rc=1 → circuit-break). Operator pays a flat subscription, not metered
        # API credits. Mirrors run-fleet.sh's OAuth-first unset (line ~207) at the
        # per-spawn level, where the inherited launchd/tmux env still carries the key.
        unset ANTHROPIC_API_KEY 2>/dev/null || true
        return 0
    fi
    # Token file missing or empty — fall back to ANTHROPIC_API_KEY if available.
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log "WARN INFRA-620: oauth token file unreadable or empty; falling back to ANTHROPIC_API_KEY"
        unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
        return 0
    fi
    log "WARN INFRA-620: oauth token file unreadable and no ANTHROPIC_API_KEY — auth may fail"
    return 0  # non-fatal; let claude -p surface the auth error naturally
}

# INFRA-572: map exit code to a named class for log scanning + waste-tally.
classify_rc() {
    case "$1" in
        0)   echo "CLEAN" ;;
        124) echo "TIMEOUT" ;;
        130) echo "INTERRUPT" ;;
        137) echo "OOM_KILL" ;;
        *)   echo "ERROR_$1" ;;
    esac
}

# INFRA-206: per-agent domain affinity. If FLEET_AGENT_DOMAINS is set (comma-
# separated, e.g. "INFRA,EVAL,DOC"), agent K is assigned domains[(K-1) % N],
# overriding the fleet-wide FLEET_DOMAIN_FILTER for this worker only.
if [ -n "$FLEET_AGENT_DOMAINS" ] && [ "${AGENT_ID:-?}" != "?" ]; then
    _aff="$(DOMAINS="$FLEET_AGENT_DOMAINS" IDX="$AGENT_ID" python3 -c \
        "import os; d=[x.strip() for x in os.environ['DOMAINS'].split(',') if x.strip()]; \
print(d[(int(os.environ['IDX'])-1)%len(d)] if d else '')" 2>/dev/null || true)"
    if [ -n "$_aff" ]; then
        log "domain affinity: agent $AGENT_ID → $_aff (INFRA-206)"
        FLEET_DOMAIN_FILTER="$_aff"
    fi
fi

# INFRA-686: graceful SIGTERM handler — commit WIP + push + release lease before exit.
# Reads global vars set by the gap dispatch loop (GAP_ID, branch, wt_path).
_sigterm_wip_checkpoint() {
    log "SIGTERM received — running WIP checkpoint (INFRA-686)"
    local _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    # Only act if we're mid-gap (GAP_ID and wt_path set by the loop)
    if [[ -n "${GAP_ID:-}" && -n "${wt_path:-}" && -d "${wt_path:-/nonexistent}" ]]; then
        local _has_changes=0
        git -C "$wt_path" diff --quiet HEAD 2>/dev/null || _has_changes=1
        git -C "$wt_path" diff --cached --quiet 2>/dev/null || _has_changes=1
        [[ -n "$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null)" ]] && _has_changes=1
        if [[ "$_has_changes" -eq 1 ]]; then
            git -C "$wt_path" add -A 2>/dev/null || true
            if git -C "$wt_path" commit -m "WIP-${GAP_ID}: sigterm-rescue (INFRA-686)" --no-verify 2>/dev/null; then
                mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
                printf '{"ts":"%s","kind":"wip_sigterm_checkpoint","agent_id":"%s","gap_id":"%s","branch":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    "$AGENT_ID" "$GAP_ID" "${branch:-}" >> "$_amb" 2>/dev/null || true
                if git -C "$wt_path" push -u origin "${branch:-chump/${GAP_ID}}" 2>/dev/null; then
                    log "INFRA-686: WIP commit pushed for $GAP_ID → origin/${branch:-}"
                else
                    log "INFRA-686: WIP commit created but push failed for $GAP_ID (offline or no remote)"
                fi
            fi
        fi
    fi
    # Release lease before exit
    if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
        rm -f "$REPO_ROOT/.chump-locks/${CHUMP_SESSION_ID}.json" 2>/dev/null || true
    fi
    log "interrupted; exiting loop (after WIP checkpoint)"
    exit 0
}
trap '_sigterm_wip_checkpoint' INT TERM

# Hard rule from CLAUDE.md: never auto-pickup these — they need human judgment.
# 2026-05-08: SWARM-* added — that domain belongs to chump-proprietary
# (private repo). The public fleet picked up SWARM-007/010 and pushed
# branches before this guard landed; closed manually as PRs #1283/#1284.
# META-044: META-* removed from blanket exclude. The picker (_pick_and_claim_gap.py)
# now enforces: META-* only if effort=xs|s (concrete, actionable ACs). META-* with
# effort=m/l/xl or vague ACs remain un-picked — those need human judgment.
EXCLUDE_PREFIXES_REGEX='^(EVAL-|RESEARCH-|SWARM-)'

cd "$REPO_ROOT" || exit 1

# INFRA-333: heal any wedged-inode chump binary before we touch chump gap.
# Idempotent — fast no-op (probe < 5s) when binary is healthy. When the
# inode is wedged (INFRA-275 syspolicyd hang), the doctor moves it aside
# and replaces it with a fresh-inode copy, so the worker loop's `chump
# gap list` invocation below doesn't hang at _dyld_start. Failure is
# logged but non-fatal: the loop will surface the real problem on the
# first `chump gap` call if the heal didn't work.
"$REPO_ROOT/scripts/dev/chump-binary-unwedge.sh" >&2 || {
    log "WARN: chump-doctor failed; chump gap calls may hang"
}

# RESILIENT-001: per-worktree target-dir guard.
# Detect when target/debug/chump is stale relative to src/main.rs.
# Emits kind=stale_binary_detected to ambient.jsonl; continues (warn-only).
_check_binary_freshness() {
    local max_age_secs="${CHUMP_BINARY_MAX_AGE_SECS:-7200}"
    local binary="$REPO_ROOT/target/debug/chump"
    local source="$REPO_ROOT/src/main.rs"
    [[ -f "$binary" ]] || return 0
    [[ -f "$source" ]] || return 0
    local bin_mtime src_mtime
    # GNU stat (Linux) -c %Y vs BSD stat (macOS) -f %m. On Linux, `stat -f` means
    # filesystem info and returns the mount point, not the mtime. Try GNU first;
    # fall back to BSD; require numeric result.
    bin_mtime=$(stat -c '%Y' "$binary" 2>/dev/null || stat -f '%m' "$binary" 2>/dev/null || echo 0)
    src_mtime=$(stat -c '%Y' "$source" 2>/dev/null || stat -f '%m' "$source" 2>/dev/null || echo 0)
    [[ "$bin_mtime" =~ ^[0-9]+$ ]] || return 0
    [[ "$src_mtime" =~ ^[0-9]+$ ]] || return 0
    local age=$(( src_mtime - bin_mtime ))
    if [[ "$age" -gt "$max_age_secs" ]]; then
        local ambient="$REPO_ROOT/.chump-locks/ambient.jsonl"
        local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        printf '{"ts":"%s","kind":"stale_binary_detected","source":"worker.sh","age_secs":%s,"max_age_secs":%s,"note":"target/debug/chump is %ss behind src/main.rs; rebuild with cargo build"}\n' \
            "$ts" "$age" "$max_age_secs" "$age" >> "$ambient" 2>/dev/null || true
        log "WARN RESILIENT-001: target/debug/chump is ${age}s stale (threshold ${max_age_secs}s). Rebuild with: cargo build"
    fi
}
_check_binary_freshness

cycle=0
while :; do
    cycle=$((cycle + 1))

    # ── RESILIENT-073: fleet kill switch — AUTONOMY_LEVEL check ─────────────
    # Pure file read: ~/.chump/AUTONOMY_LEVEL must be >= 1 to proceed.
    # Fail-closed: missing / unreadable / non-numeric / 0 → skip cycle (STOP).
    # NO shared failure mode: no chump-op, no DB, no NATS, no network.
    # The operator halt works even when the fleet is deadlocked.
    _al_file="${HOME:-/tmp}/.chump/AUTONOMY_LEVEL"
    _al_level=0
    if [[ -r "$_al_file" ]]; then
        _al_raw="$(tr -d '[:space:]' < "$_al_file" 2>/dev/null || true)"
        if [[ "$_al_raw" =~ ^[0-9]+$ ]] && [[ "$_al_raw" -gt 0 ]]; then
            _al_level="$_al_raw"
        fi
    fi
    if [[ "$_al_level" -eq 0 ]]; then
        log "RESILIENT-073: fleet stopped (AUTONOMY_LEVEL=${_al_level}) — sleeping ${IDLE_SLEEP_S:-60}s before retry"
        _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        printf '{"ts":"%s","kind":"fleet_stopped_kill_switch","source":"worker","agent_id":"%s","autonomy_level":%s,"note":"RESILIENT-073"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT_ID" "${_al_level}" >> "$_amb" 2>/dev/null || true
        sleep "${IDLE_SLEEP_S:-60}"
        continue
    fi
    # ── end RESILIENT-073 ────────────────────────────────────────────────────

    # FLEET-054: auto-pause when waste rate spikes. Workers check for the
    # .chump/fleet-paused sentinel before each claim cycle. The sentinel blocks
    # claim (work); it does NOT block gap reserve (filing is always allowed).
    # See INFRA-2424 for the reserve/claim split rationale.
    _pause_file="${CHUMP_FLEET_PAUSE_FILE:-$REPO_ROOT/.chump/fleet-paused}"
    if [[ -f "$_pause_file" ]]; then
        log "FLEET-054: fleet-paused sentinel present ($( cat "$_pause_file" | head -1 )) — waste spike in progress; sleeping ${IDLE_SLEEP_S}s before retry"
        _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        printf '{"ts":"%s","kind":"worker_paused_waste_spike","agent_id":"%s","pause_file":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT_ID" "$_pause_file" >> "$_amb" 2>/dev/null || true
        sleep "${IDLE_SLEEP_S:-60}"
        continue
    fi

    # ── INFRA-2008: pre-claim floor-signal reads ──────────────────────────
    # Read both THE FLOOR Phase 1+2 signals before spending any cycle budget.
    # (1) fleet-hold-check.sh — exits 2 if cluster-detector wrote fleet-hold.txt
    #     (INFRA-1987 Phase 2). On hold: pivot to triage/docs work; don't ship.
    # (2) chump health --temp — exits 0=COLD, 1=WARM, 2=HOT (INFRA-1992).
    #     HOT: restrict to xs/docs gaps; WARM: double-verify; COLD: normal.
    _amb_pre="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$_amb_pre")" 2>/dev/null || true

    # (1) Fleet-hold check
    _hold_active=0
    _fleet_hold_check="${REPO_ROOT}/scripts/coord/fleet-hold-check.sh"
    if [[ -x "$_fleet_hold_check" ]]; then
        if ! bash "$_fleet_hold_check" --quiet 2>/dev/null; then
            _hold_active=1
        fi
        printf '{"ts":"%s","kind":"worker_floor_signal_read","agent_id":"%s","signal":"fleet_hold","hold":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT_ID" "$_hold_active" \
            >> "$_amb_pre" 2>/dev/null || true
        if [[ "$_hold_active" -eq 1 ]]; then
            log "INFRA-2008: fleet-hold ACTIVE (cluster-detector signal) — skipping shipping work; next cycle"
            # Count hold-cycles toward stand-down so the worker doesn't spin
            # forever if the hold persists and no gaps can be claimed.
            _starve_count=$((_starve_count + 1))
            if [ "$_starve_count" -ge "$CHUMP_STAND_DOWN_THRESHOLD" ]; then
                _emit_worker_stuck "fleet_hold_stand_down: hold persisted >= $CHUMP_STAND_DOWN_THRESHOLD cycles"
                log "INFRA-2008: fleet-hold persistent ($CHUMP_STAND_DOWN_THRESHOLD cycles) — standing down"
                exit 0
            fi
            sleep "${IDLE_SLEEP_S:-60}"
            continue
        fi
    fi

    # (2) Floor-temperature check
    _floor_temp="COLD"
    if chump health --temp >/dev/null 2>&1; then
        _floor_temp="COLD"
    else
        _temp_rc=$?
        case "$_temp_rc" in
            1) _floor_temp="WARM" ;;
            2) _floor_temp="HOT" ;;
            *) _floor_temp="COLD" ;;  # unknown / chump not available — proceed normally
        esac
    fi
    printf '{"ts":"%s","kind":"worker_floor_signal_read","agent_id":"%s","signal":"floor_temp","temp":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT_ID" "$_floor_temp" \
        >> "$_amb_pre" 2>/dev/null || true
    if [[ "$_floor_temp" == "HOT" ]]; then
        log "INFRA-2008: floor temp HOT — restricting to xs/docs gaps this cycle"
        # Narrow effort filter to xs only; restore after cycle
        _saved_effort="$FLEET_EFFORT_FILTER"
        _saved_domain="$FLEET_DOMAIN_FILTER"
        FLEET_EFFORT_FILTER="xs"
        # Allow any domain but prefer docs by removing domain restriction
        FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
    elif [[ "$_floor_temp" == "WARM" ]]; then
        log "INFRA-2008: floor temp WARM — double-verify mode; proceeding normally"
        _saved_effort=""
        _saved_domain=""
    else
        _saved_effort=""
        _saved_domain=""
    fi
    # ── End INFRA-2008 floor-signal prelude ───────────────────────────────

    log "cycle $cycle: fetching origin/main"
    git fetch origin main --quiet || log "WARN: git fetch failed; continuing"

    # ── INFRA-727: repair stuck PRs before picking new work ──────────────
    # Rebase open fleet PRs with CI failures onto latest main. Many failures
    # are stale-branch issues (missing clippy fixes, test fixture updates)
    # that a rebase resolves. Lightweight — skips PRs under 10min old and
    # respects a 30min cooldown per PR. Only agent 1 runs this to avoid
    # 3 workers all rebasing the same PRs simultaneously.
    if [[ "${AGENT_ID:-1}" == "1" ]] && [[ "${CHUMP_PR_REPAIR:-1}" != "0" ]]; then
        "$REPO_ROOT/scripts/ops/pr-repair-rebase.sh" 2>&1 | while read -r line; do
            log "$line"
        done || true
    fi

    # ── Pick a gap ────────────────────────────────────────────────────────
    # We use `chump gap list --json` directly (musher.py has its own cooldown
    # heuristics; for fleet workers we want the simplest "highest-priority
    # unclaimed open gap matching filters" semantics so behavior is debuggable).
    gap_json="$(chump gap list --status open --json 2>/dev/null || echo '[]')"

    # Active leases (so we never try to claim something a sibling has).
    active_gaps="$(
        python3 - "$REPO_ROOT/.chump-locks" <<'PY' 2>/dev/null || true
import glob, json, sys, os
base = sys.argv[1]
for f in glob.glob(os.path.join(base, '*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    g = d.get('gap_id') or (d.get('pending_new_gap') or {}).get('id')
    if g:
        print(g)
PY
    )"

    # INFRA-415: atomic gap picker+claimer. This picker filters candidates
    # AND claims the gap atomically before returning, preventing concurrent
    # workers from picking the same gap. Uses the same session-ID resolution
    # as chump claim so the lease is scoped to this worker's session.
    gap_json_file="$(mktemp -t fleet-gaps.XXXXXX)"
    printf '%s' "$gap_json" > "$gap_json_file"
    pick="$(FLEET_PRIORITY_FILTER="$FLEET_PRIORITY_FILTER" \
            FLEET_DOMAIN_FILTER="$FLEET_DOMAIN_FILTER" \
            FLEET_EFFORT_FILTER="$FLEET_EFFORT_FILTER" \
            FLEET_MODEL="$FLEET_MODEL" \
            EXCLUDE_RE="$EXCLUDE_PREFIXES_REGEX" \
            ACTIVE_GAPS="$active_gaps" \
            GAP_JSON_FILE="$gap_json_file" \
            WORKER_INDEX="$AGENT_ID" \
            WORKER_ID="$AGENT_ID" \
            COOLDOWN_DIR="$REPO_ROOT/.chump-locks/cooldown" \
            python3 "$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py" 2>/dev/null || true)"
    rm -f "$gap_json_file"

    if [ -z "$pick" ]; then
        # INFRA-315: increment starvation counter; emit ambient ALERT once
        # the fleet has been quiet for STARVE_THRESHOLD consecutive cycles.
        _starve_count=$((_starve_count + 1))
        if [ "$_starve_count" = "$CHUMP_STARVE_THRESHOLD" ]; then
            # INFRA-391: compute the suggested next filter set so the
            # operator (or the auto-relax path below) knows what to widen.
            # Order: drop FLEET_DOMAIN_FILTER first → bump effort tier →
            # bump priority tier. Each step is the smallest increase in
            # blast radius that's still meaningful.
            _suggest_domain="$FLEET_DOMAIN_FILTER"
            _suggest_effort="$FLEET_EFFORT_FILTER"
            _suggest_prio="$FLEET_PRIORITY_FILTER"
            if [ -n "$_suggest_domain" ]; then
                _suggest_domain=""
                _suggest_action="drop FLEET_DOMAIN_FILTER (was: $FLEET_DOMAIN_FILTER)"
            elif [ "$_suggest_effort" = "xs,s" ] || [ "$_suggest_effort" = "xs" ]; then
                _suggest_effort="xs,s,m"
                _suggest_action="bump FLEET_EFFORT_FILTER → $_suggest_effort"
            elif [ "$_suggest_effort" = "xs,s,m" ]; then
                _suggest_effort="xs,s,m,l"
                _suggest_action="bump FLEET_EFFORT_FILTER → $_suggest_effort"
            elif [ "$_suggest_prio" = "P0,P1" ] || [ "$_suggest_prio" = "P0" ] || [ "$_suggest_prio" = "P1" ]; then
                _suggest_prio="P0,P1,P2"
                _suggest_action="bump FLEET_PRIORITY_FILTER → $_suggest_prio"
            elif [ "$_suggest_prio" = "P0,P1,P2" ]; then
                _suggest_prio="P0,P1,P2,P3"
                _suggest_action="bump FLEET_PRIORITY_FILTER → $_suggest_prio (everything left)"
            else
                _suggest_action="filters already maximally relaxed — backlog truly empty for this agent"
            fi

            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _amb_path="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
            mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
            printf '{"ts":"%s","session":"%s","worktree":"worker-%s","kind":"fleet_starved","event":"fleet_starved","agent_id":"%s","consecutive_empty":%d,"filters":"prio=%s domain=%s effort=%s","suggest":"%s"}\n' \
                "$_ts" \
                "${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-fleet-worker-$AGENT_ID}}" \
                "$AGENT_ID" \
                "$AGENT_ID" \
                "$_starve_count" \
                "$FLEET_PRIORITY_FILTER" \
                "${FLEET_DOMAIN_FILTER:-any}" \
                "$FLEET_EFFORT_FILTER" \
                "$_suggest_action" \
                >> "$_amb_path" 2>/dev/null || true
            log "ALERT kind=fleet_starved (consecutive_empty=$_starve_count; filters: prio=$FLEET_PRIORITY_FILTER domain=${FLEET_DOMAIN_FILTER:-any} effort=$FLEET_EFFORT_FILTER); suggest: $_suggest_action"

            # INFRA-391 mode (a): opt-in auto-relax — apply the suggestion
            # in-place and reset the starve counter so we get another
            # STARVE_THRESHOLD cycles to find work under the new filter.
            if [ "${CHUMP_STARVE_AUTO_RELAX:-0}" = "1" ]; then
                FLEET_DOMAIN_FILTER="$_suggest_domain"
                FLEET_EFFORT_FILTER="$_suggest_effort"
                FLEET_PRIORITY_FILTER="$_suggest_prio"
                _starve_count=0
                log "INFRA-391: auto-relaxed filter (CHUMP_STARVE_AUTO_RELAX=1) — now: prio=$FLEET_PRIORITY_FILTER domain=${FLEET_DOMAIN_FILTER:-any} effort=$FLEET_EFFORT_FILTER"
            fi

            # INFRA-391 mode (b): opt-in auto-shutdown — exit clean so the
            # tmux pane / launchd job stops consuming wakeups + tokens.
            if [ "${CHUMP_STARVE_AUTO_SHUTDOWN:-0}" = "1" ]; then
                log "INFRA-391: auto-shutdown (CHUMP_STARVE_AUTO_SHUTDOWN=1) — exiting cleanly"
                exit 0
            fi
        fi

        # INFRA-613: worker stand-down on persistent starvation. After
        # STAND_DOWN_THRESHOLD consecutive empty cycles, emit worker_stand_down
        # event and exit cleanly. The auto-restart daemon (INFRA-611) picks up
        # the signal and optionally respawns with relaxed filters or scales down.
        if [ "$_starve_count" -ge "$CHUMP_STAND_DOWN_THRESHOLD" ]; then
            # Compute stand-down reasoning: which filter tier is exhausted?
            _stand_down_reason=""
            if [ -n "$FLEET_DOMAIN_FILTER" ]; then
                _stand_down_reason="filter=DOMAIN=${FLEET_DOMAIN_FILTER} exhausted; try dropping domain restriction"
            elif [ "$FLEET_EFFORT_FILTER" != "xs,s,m,l" ]; then
                _stand_down_reason="filter=EFFORT=${FLEET_EFFORT_FILTER} exhausted; try expanding to include larger efforts"
            elif [ "$FLEET_PRIORITY_FILTER" != "P0,P1,P2,P3" ]; then
                _stand_down_reason="filter=PRIORITY=${FLEET_PRIORITY_FILTER} exhausted; try expanding to include lower priorities"
            else
                _stand_down_reason="filters maximally relaxed (prio=P0-P3, effort=xs-l, domain=any); backlog truly empty"
            fi

            _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            _amb_path="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
            mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
            printf '{"ts":"%s","session":"%s","worktree":"worker-%s","event":"worker_stand_down","kind":"worker_stand_down","agent_id":"%s","consecutive_empty":%d,"filters":"prio=%s domain=%s effort=%s","reason":"%s"}\n' \
                "$_ts" \
                "${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-fleet-worker-$AGENT_ID}}" \
                "$AGENT_ID" \
                "$AGENT_ID" \
                "$_starve_count" \
                "$FLEET_PRIORITY_FILTER" \
                "${FLEET_DOMAIN_FILTER:-any}" \
                "$FLEET_EFFORT_FILTER" \
                "$_stand_down_reason" \
                >> "$_amb_path" 2>/dev/null || true
            log "INFRA-613: worker_stand_down (consecutive_empty=$_starve_count >= STAND_DOWN_THRESHOLD=$CHUMP_STAND_DOWN_THRESHOLD); reason: $_stand_down_reason"
            _emit_worker_stuck "stand_down: $_stand_down_reason"
            exit 0
        fi

        # FLEET-043: exponential backoff on empty picks.
        # After CHUMP_STARVE_THRESHOLD, backoff multiplier ramps: 1x → 2x → 4x → 8x.
        # Each missed pick multiplies IDLE_SLEEP_S by the current multiplier, up to 600s cap.
        if [ "$_starve_count" -gt "$CHUMP_STARVE_THRESHOLD" ]; then
            _max_backoff="${CHUMP_BACKOFF_MAX_SECS:-600}"
            # Ramp multiplier: starve_count=4 → 2x, 5 → 4x, 6 → 8x (min multiplier at threshold)
            _ramp=$((_starve_count - CHUMP_STARVE_THRESHOLD))
            _backoff_multiplier=$((2 ** _ramp))  # 2^0=1, 2^1=2, 2^2=4, 2^3=8, ...
            if [ "$_backoff_multiplier" -gt 8 ]; then
                _backoff_multiplier=8  # cap at 8x
            fi
            _raw_sleep=$(( IDLE_SLEEP_S * _backoff_multiplier ))
            _sleep_s=$(( _raw_sleep > _max_backoff ? _max_backoff : _raw_sleep ))
        else
            # Pre-threshold: use jittered sleep as before.
            _sleep_s="$(IDLE="$IDLE_SLEEP_S" JIT="$CHUMP_POLL_JITTER" python3 -c '
import os, random
idle = float(os.environ.get("IDLE", "60"))
jit  = float(os.environ.get("JIT",  "30")) / 100.0
delta = idle * jit
print(max(1.0, idle + random.uniform(-delta, +delta)))
' 2>/dev/null || echo "$IDLE_SLEEP_S")"
        fi
        log "no pickable gap (filters: prio=$FLEET_PRIORITY_FILTER domain=${FLEET_DOMAIN_FILTER:-any} effort=$FLEET_EFFORT_FILTER); sleeping ${_sleep_s}s (starve=$_starve_count, backoff_mult=${_backoff_multiplier}x)"
        # FLEET-042: heartbeat during idle with short sleeps to keep file fresh.
        _sleep_remaining=$(printf '%.0f' "$_sleep_s")
        while [ "$_sleep_remaining" -gt 0 ]; do
            _this_sleep=$(( _sleep_remaining > 10 ? 10 : _sleep_remaining ))
            sleep "$_this_sleep"
            write_heartbeat "idle"
            _sleep_remaining=$(( _sleep_remaining - _this_sleep ))
        done
        continue
    fi

    GAP_ID="$pick"

    # INFRA-2008: restore effort/domain filters narrowed by HOT floor-temp.
    # The filter narrowing served its purpose during pick; restore now so
    # downstream logic (timeout scaling, model selection) uses saved values.
    if [[ -n "${_saved_effort:-}" ]]; then
        FLEET_EFFORT_FILTER="$_saved_effort"
        _saved_effort=""
    fi
    if [[ -n "${_saved_domain:-}" ]]; then
        FLEET_DOMAIN_FILTER="$_saved_domain"
        _saved_domain=""
    fi

    # INFRA-975: disk-pressure gate. After picker has identified a gap but
    # BEFORE we commit any resources (worktree, cargo, lease), pause the
    # worker if the filesystem is critically full. Without this gate, a
    # runaway parallel fleet can fill /private/tmp to <1Gi (we observed
    # this 2026-05-13) and every claim/build/test fails opaquely.
    # shellcheck source=../lib/disk-check.sh
    if [ -r "$REPO_ROOT/scripts/lib/disk-check.sh" ]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/scripts/lib/disk-check.sh"
        if ! chump_disk_check_pause_worker; then
            log "worker paused on disk_critical — sleeping 5min then re-checking"
            sleep 300
            continue
        fi
    fi

    # FLEET-042: update heartbeat with picked gap.
    write_heartbeat "$GAP_ID"

    # INFRA-471: per-pick model class from routing.yaml.
    # FLEET_MODEL is the worker's base model class (used for effort filtering);
    # _resolve_model.py walks routing.yaml to find the best model for THIS gap,
    # overriding FLEET_MODEL locally for the current cycle only.
    # gap_json is still in scope here (written before picker, not yet deleted).
    # shellcheck disable=SC2097,SC2098  # subprocess inherits env; inline vars intentional
    _resolved_model="$(printf '%s' "$gap_json" | \
        GAP_ID="$GAP_ID" \
        REPO_ROOT="$REPO_ROOT" \
        FLEET_MODEL="$FLEET_MODEL" \
        python3 "$REPO_ROOT/scripts/dispatch/_resolve_model.py" 2>/dev/null \
        || true)"
    if [[ -n "$_resolved_model" ]] && [[ "$_resolved_model" != "$FLEET_MODEL" ]]; then
        log "INFRA-471: routing gap=$GAP_ID model $FLEET_MODEL → $_resolved_model (routing.yaml)"
        FLEET_MODEL="$_resolved_model"
    fi

    # INFRA-843: gap.required_model takes precedence over routing.yaml resolution.
    # If the gap's required_model is set, use it as the model for this cycle;
    # emit kind=model_selected so observers can verify routing correctness.
    _gap_required_model="$(printf '%s' "$gap_json" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); g=next((x for x in d.get('gaps',[]) if x.get('id')=='$GAP_ID'),None) or next((x for x in [d] if x.get('id')=='$GAP_ID'),{}); print(g.get('required_model','') or '')" \
        2>/dev/null || true)"
    _model_selected_reason="fleet_model_default"
    if [[ -n "$_gap_required_model" ]]; then
        _model_selected_reason="gap_required_model"
        if [[ "$_gap_required_model" != "$FLEET_MODEL" ]]; then
            log "INFRA-843: gap=$GAP_ID required_model=$_gap_required_model (overrides FLEET_MODEL=$FLEET_MODEL)"
            FLEET_MODEL="$_gap_required_model"
        fi
    fi
    # MISSION-048: P0-MISSION gaps with effort>=m must run on a capable model.
    # The routing.yaml cost-downgrade (INFRA-471, above) sends them to haiku,
    # which stalls on m+ effort (INFRA-705 stall-detector kills the cycle; 30-min
    # timeouts) — so the picker now CLAIMS them (MISSION-047) but they never
    # finish. Force sonnet for P0 + domain=MISSION + effort in m/l/xl when the
    # resolution landed on haiku. Sibling of MISSION-047 (pickability vs capability).
    if [[ "$FLEET_MODEL" == "haiku" ]]; then
        _m048_override="$(printf '%s' "$gap_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
g = next((x for x in d.get('gaps', []) if x.get('id') == '$GAP_ID'), None) \
    or next((x for x in [d] if x.get('id') == '$GAP_ID'), {})
p = (g.get('priority') or '').upper()
dom = (g.get('domain') or '').upper()
e = (g.get('effort') or '').lower()
print('1' if (p == 'P0' and dom == 'MISSION' and e in ('m', 'l', 'xl')) else '0')
" 2>/dev/null || echo 0)"
        if [[ "$_m048_override" == "1" ]]; then
            log "MISSION-048: P0-MISSION gap=$GAP_ID effort>=m — forcing model haiku → sonnet (haiku stalls on m+ effort; mission work bypasses the cost-downgrade)"
            FLEET_MODEL="sonnet"
            _model_selected_reason="mission_048_capability_override"
        fi
    fi
    # Emit kind=model_selected for observability (INFRA-843)
    _amb_ms="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$_amb_ms")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"model_selected","gap_id":"%s","requested":"%s","actual":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$GAP_ID" \
        "${_gap_required_model:-}" \
        "$FLEET_MODEL" \
        "$_model_selected_reason" \
        >> "$_amb_ms" 2>/dev/null || true

    # PRODUCT-063: export model class so provider_cascade prefers matching tier
    export CHUMP_PREFERRED_MODEL_CLASS="${FLEET_MODEL}"

    # INFRA-315: clear starvation counter on a successful pick. The next
    # empty cycle starts the threshold over from zero.
    _starve_count=0
    # FLEET-043: reset backoff multiplier when a gap is picked.
    _backoff_multiplier=1
    # INFRA-536: cycle timing — record wall-clock start so we can emit
    # elapsed_s in the cycle_end ambient event for p90 measurement.
    _cycle_start_s=$(date +%s)
    log "picked gap $GAP_ID"

    # INFRA-569: dry-run mode — preview without committing resources.
    if [ "$DRY_RUN" = "1" ]; then
        sid="$(date +%Y%m%d-%H%M%S)"
        gap_lower="$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')"
        wt_name="${gap_lower}-fleet-${AGENT_ID}-${sid}"
        # INFRA-1053: honor CHUMP_WORKTREE_BASE for harness-agnostic placement.
        wt_path="${CHUMP_WORKTREE_BASE:-$REPO_ROOT/.claude/worktrees}/$wt_name"
        branch="chump/${wt_name}"
        printf 'WOULD claim %s and spawn claude in %s\n' "$GAP_ID" "$wt_path"
        printf 'branch: %s\n' "$branch"
        printf 'worktree: %s\n' "$wt_path"
        exit 0
    fi

    # ── INFRA-361: pre-pick preflight ─────────────────────────────────────
    # Cheap check (~50ms) before paying the worktree-create + cold-cargo
    # cost (5–15min). If the gap is no longer available (claimed by a
    # sibling, done on main, ID missing from registry), skip and pick
    # again next cycle. Pre-fix worker.sh order was pick → worktree →
    # claim/preflight, which ate the build cost on every dead pick.
    # INFRA-379: use direct `chump gap preflight` instead of gap-preflight.sh
    # which has a rare hanging issue (likely race condition in file I/O).
    if ! timeout 3 chump gap preflight "$GAP_ID" >/dev/null 2>&1; then
        log "skipping $GAP_ID: failed pre-pick preflight (claimed/done/missing); next cycle"
        # INFRA-544: picker wrote .gap-<ID>.lock; release it on pivot so siblings can pick.
        rm -f "${CHUMP_REPO:-$REPO_ROOT}/.chump-locks/.gap-${GAP_ID}.lock" 2>/dev/null || true
        _emit_worker_stuck "preflight_fail: gap=$GAP_ID claimed/done/missing"
        continue
    fi

    # ── FLEET-040: also check origin/main for status:done ────────────────
    # The pre-pick preflight above reads .chump/state.db (per-worktree).
    # state.db lags origin/main until the next `chump gap import` runs,
    # so a gap that landed on main since fleet start can still appear
    # "open" to the worker. Without this check, worker 6 picked
    # INFRA-310 in cycle 1, timed out 600s, picked it AGAIN in cycle 2 —
    # even though it had already shipped as PR #1021 between cycles.
    # `git fetch origin main` is cheap; `git show` per candidate is ~50ms.
    ( cd "$REPO_ROOT" && git fetch origin main --quiet 2>/dev/null ) || true
    _origin_status=$( cd "$REPO_ROOT" && \
        git show "origin/main:docs/gaps/${GAP_ID}.yaml" 2>/dev/null \
        | awk '/^[[:space:]]*status:[[:space:]]*/{print $2; exit}' )
    if [ "$_origin_status" = "done" ]; then
        log "skipping $GAP_ID: already done on origin/main (state.db stale); rotating"
        # Cooldown so siblings + future cycles don't re-pick.
        if [ -d "$REPO_ROOT/.chump-locks/cooldown" ]; then
            _cd_until=$(( $(date +%s) + 1800 ))
            printf '{"gap_id":"%s","rc":0,"until":%d,"agent":"%s","ts":"%s","reason":"shipped_on_main"}\n' \
                "$GAP_ID" "$_cd_until" "$AGENT_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                > "$REPO_ROOT/.chump-locks/cooldown/${GAP_ID}.json"
        fi
        # INFRA-544: release gap lock on pivot so siblings can pick.
        rm -f "${CHUMP_REPO:-$REPO_ROOT}/.chump-locks/.gap-${GAP_ID}.lock" 2>/dev/null || true
        _emit_worker_stuck "gap_already_done: gap=$GAP_ID done on origin/main"
        continue
    fi

    # ── Worktree ──────────────────────────────────────────────────────────
    sid="$(date +%Y%m%d-%H%M%S)"
    gap_lower="$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')"
    wt_name="${gap_lower}-fleet-${AGENT_ID}-${sid}"
    # INFRA-1053: honor CHUMP_WORKTREE_BASE for harness-agnostic placement.
    wt_path="${CHUMP_WORKTREE_BASE:-$REPO_ROOT/.claude/worktrees}/$wt_name"
    branch="chump/${wt_name}"

    log "creating worktree $wt_path on branch $branch"
    if ! git -C "$REPO_ROOT" worktree add -b "$branch" "$wt_path" origin/main >/dev/null 2>&1; then
        # INFRA-271: don't sleep 30s on worktree-add failure — most failures
        # here are transient (sibling worker briefly held a git lock, or the
        # branch we picked happened to collide with a stale leftover). Skip
        # the cycle and pick a different gap on the next iteration.
        log "WARN: worktree create failed for $GAP_ID; trying next pick"
        # INFRA-544: release gap lock on pivot so siblings can pick.
        rm -f "${CHUMP_REPO:-$REPO_ROOT}/.chump-locks/.gap-${GAP_ID}.lock" 2>/dev/null || true
        _emit_worker_stuck "worktree_create_fail: gap=$GAP_ID git worktree add failed"
        continue
    fi

    # ── Claim (already done by atomic picker) ─────────────────────────────
    # INFRA-415: the atomic picker (_pick_and_claim_gap.py) already claimed
    # the gap atomically before returning the gap ID. The lease file is
    # already written in .chump-locks/<session>.json, so we skip the separate
    # chump claim call and proceed directly to spawning the agent.

    # ── Spawn agent (claude or chump-local) ───────────────────────────────
    cycle_log="$FLEET_LOG_DIR/agent-${AGENT_ID}-cycle${cycle}-${GAP_ID}.log"

    # INFRA-1160 + RESILIENT-135: scale the per-cycle claude -p timeout by gap
    # effort, derived from the IMMUTABLE base (FLEET_TIMEOUT_BASE_S) via the
    # sourceable, unit-tested compute_scaled_timeout() helper. Deriving from the
    # mutable FLEET_TIMEOUT_S here was the death-spiral bug: it compounded the
    # multiplier every cycle and collapsed the budget to ~0s.
    _gap_effort="$(printf '%s' "$gap_json" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); gs=d if isinstance(d,list) else [d]; g=next((x for x in gs if x.get('id')=='$GAP_ID'),{}); print(g.get('effort','') or '')" \
        2>/dev/null || true)"
    if command -v compute_scaled_timeout >/dev/null 2>&1; then
        _scaled_timeout="$(compute_scaled_timeout "${FLEET_TIMEOUT_BASE_S:-$FLEET_TIMEOUT_S}" "${_gap_effort:-s}")"
    else
        # Defensive fallback if the lib is unavailable: use the base, never compound.
        _scaled_timeout="${FLEET_TIMEOUT_BASE_S:-$FLEET_TIMEOUT_S}"
    fi
    if [ "$_scaled_timeout" -ne "$FLEET_TIMEOUT_S" ]; then
        log "INFRA-1160: timeout scaled by effort=${_gap_effort:-s}: base ${FLEET_TIMEOUT_BASE_S:-$FLEET_TIMEOUT_S}s → ${_scaled_timeout}s"
        FLEET_TIMEOUT_S="$_scaled_timeout"
    fi
    # Emit telemetry
    printf '{"ts":"%s","kind":"worker_timeout_scaled","gap_id":"%s","effort":"%s","base_timeout_s":%d,"scaled_timeout_s":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$GAP_ID" \
        "${_gap_effort:-s}" \
        "$(( FLEET_TIMEOUT_BASE_S ))" \
        "$_scaled_timeout" \
        >> "${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}" 2>/dev/null || true

    # Pick `timeout` (linux) or `gtimeout` (mac brew coreutils); fall back to none.
    if command -v timeout >/dev/null 2>&1; then
        TO="timeout ${FLEET_TIMEOUT_S}s"
    elif command -v gtimeout >/dev/null 2>&1; then
        TO="gtimeout ${FLEET_TIMEOUT_S}s"
    else
        TO=""
    fi

    # ── INFRA-525: timeout-checkpoint watchdog ───────────────────────────────
    # Fires at T - CHUMP_TIMEOUT_CHECKPOINT_SECS (default 30s before fleet
    # timeout). Commits any WIP edits and pushes the branch to origin so work
    # survives when the outer `timeout` kills the agent before it can ship.
    # The watchdog is killed immediately if the agent exits cleanly first.
    _ckpt_delay=$(( FLEET_TIMEOUT_S - CHUMP_TIMEOUT_CHECKPOINT_SECS ))
    _watchdog_pid=0
    if [ "$_ckpt_delay" -gt 0 ]; then
        (
            sleep "$_ckpt_delay"
            # Nothing to save if the tree is clean.
            _wip_untracked="$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null)"
            if git -C "$wt_path" diff --quiet HEAD 2>/dev/null \
               && git -C "$wt_path" diff --cached --quiet 2>/dev/null \
               && [ -z "$_wip_untracked" ]; then
                exit 0
            fi
            git -C "$wt_path" add -A 2>/dev/null || true
            if git -C "$wt_path" commit -m "WIP-${GAP_ID}: timeout-rescue" 2>/dev/null; then
                if git -C "$wt_path" push -u origin "$branch" 2>/dev/null; then
                    printf '[worker:%s %s] INFRA-525: WIP checkpoint pushed for %s → origin/%s\n' \
                        "$AGENT_ID" "$(date -u +%H:%M:%S)" "$GAP_ID" "$branch" >&2
                    _amb_path="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                    mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true
                    printf '{"ts":"%s","session":"%s","worktree":"%s","event":"wip_checkpoint","kind":"timeout_rescue","agent_id":"%s","gap_id":"%s","branch":"%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
                        "$wt_name" "$AGENT_ID" "$GAP_ID" "$branch" \
                        >> "$_amb_path" 2>/dev/null || true
                else
                    printf '[worker:%s %s] INFRA-525: WIP commit created but push failed for %s\n' \
                        "$AGENT_ID" "$(date -u +%H:%M:%S)" "$GAP_ID" >&2
                fi
            fi
        ) &
        _watchdog_pid=$!
    fi

    case "$FLEET_BACKEND" in
        claude)
            # ── INFRA-371: inline gap briefing (cut token burn) ──────────
            # Pre-fix: prompt was "Ship gap X. Read CLAUDE.md and AGENTS.md
            # first..." which forced ~30K tokens of mandatory reads on every
            # spawn before any productive work. Squad on cycle 100+ wastes
            # this on every cycle.
            #
            # Post-fix: pre-assemble a tight briefing inline so claude has
            # everything it needs to ship without exploring the repo for
            # discipline rules. CLAUDE.md is still on disk and claude is
            # told it CAN read it for unusual cases — so back-compat for
            # genuinely tricky gaps.
            #
            # Estimated savings: ~20-25K tokens per spawn × 4 workers ×
            # 100+ cycles/day = $50-150/day at sonnet rates, even more
            # at haiku scale.
            #
            # Bypass: FLEET_INLINE_BRIEFING=0 reverts to the old terse-prompt
            # behavior (forces claude to discover everything itself).
            if [[ "${FLEET_INLINE_BRIEFING:-1}" == "1" ]]; then
                # INFRA-502: post-INFRA-498 docs/gaps/*.yaml is deleted.
                # Use 'chump gap show <ID>' as the canonical gap-content
                # source. State.db is canonical, the show subcommand
                # renders the full gap dict in YAML format.
                #
                # Legacy paths preserved for back-compat with branches
                # that pre-date INFRA-498 (e.g. an old worktree still
                # has docs/gaps/<ID>.yaml on disk).
                gap_yaml_path="$wt_path/docs/gaps/${GAP_ID}.yaml"
                gap_yaml_main_path="$REPO_ROOT/docs/gaps/${GAP_ID}.yaml"
                gap_yaml="(gap content not found — run 'chump gap show ${GAP_ID}')"
                if chump_show_out="$(chump gap show "$GAP_ID" 2>/dev/null)" && [[ -n "$chump_show_out" ]]; then
                    gap_yaml="$chump_show_out"
                elif [[ -f "$gap_yaml_path" ]]; then
                    gap_yaml=$(cat "$gap_yaml_path")
                    log "INFRA-502: legacy: gap YAML still in linked worktree"
                elif [[ -f "$gap_yaml_main_path" ]]; then
                    gap_yaml=$(cat "$gap_yaml_main_path")
                    log "INFRA-502: legacy: gap YAML in main repo (pre-INFRA-498)"
                fi
                prompt="Ship gap ${GAP_ID}.

The gap is already claimed for this session; lease is in .chump-locks/.
You are in worktree ${wt_path}. Pre-flight has already run — do NOT re-run
'chump gap list', 'gap-doctor', 'install-ambient-hooks', or 'chump-coord
watch'. Spend tokens on the implementation, not on discovery.

══ GAP YAML (canonical) ══
${gap_yaml}

══ HARD RULES (full text in CLAUDE.md if you need it) ══
- Work ONLY in this worktree: ${wt_path}
- Commit via: scripts/coord/chump-commit.sh <files…> -m \"msg\"
- Ship via:   scripts/coord/bot-merge.sh --gap ${GAP_ID} --auto-merge --fast
  (--fast skips local cargo clippy/test — CI is the gate; saves 5-10 min
  per cycle so you finish well inside the ${FLEET_TIMEOUT_S}s budget.
  This rebases, pushes, opens PR, arms auto-merge, auto-closes the gap.)
- If bot-merge.sh hangs/dies: fall back to manual ship —
    git push -u origin <branch>
    gh pr create --base main --title \"...\" --body \"...\"
    chump gap ship ${GAP_ID} --closed-pr <PR#> --update-yaml
    git push (commit the close)
    gh pr merge <PR#> --auto --squash
- Never push directly to main. Never use git commit --no-verify.
- Mutate gaps via 'chump gap set' / 'chump gap ship' (state.db canonical post-INFRA-498).
- If you spot a real bug along the way, file it: 'chump gap reserve --domain INFRA --title \"...\"'

══ BEFORE CALLING BOT-MERGE: Self-Verify (INFRA-717) ══
REQUIRED: Before shipping, run these 3 self-verify steps. Reject any code
that fails these checks.
1. cargo check --workspace
   Verify no compilation errors.
2. cargo clippy --workspace --fix --allow-dirty
   Apply clippy fixes and verify no clippy warnings remain.
3. Symbol-resolution check
   Grep your diff for new method/fn calls (lines with . or :: followed by
   identifier). For each new call, verify it is defined in either:
     - Your diff (same PR), or
     - On main (git show main:<file> | grep -q 'def\|fn ')
   If a new call is undefined in both places, REJECT the code and explain
   the orphan call.

When done, reply with the PR number only (e.g. \"#1234\")."
            else
                prompt="Ship gap $GAP_ID in this repository. Read CLAUDE.md and AGENTS.md first. The gap is already claimed for this session; the lease is in .chump-locks/. Implement the gap per its description, commit via scripts/coord/chump-commit.sh, and ship via scripts/coord/bot-merge.sh --gap $GAP_ID --auto-merge. Reply with the PR number only."
            fi
            # INFRA-515 (2026-05-06): default flipped haiku → sonnet.
            # Live fleet validation found haiku asks "should I implement
            # or clarify?" instead of doing the work; --dangerously-skip-
            # permissions has no stdin to answer, so claude -p sits 600s
            # and times out. Throughput: 1 ship out of 9 cycles on haiku.
            # Sonnet is ~3× per-token but actually ships → net cheaper.
            # Override for cost-sensitive sweeps: FLEET_MODEL=haiku.
            # INFRA-471's per-pick routing still bumps m/l/xl to sonnet
            # explicitly; xs/s used to fall to haiku, now defaults sonnet.
            FLEET_MODEL="${FLEET_MODEL-sonnet}"
            _model_arg=()
            [[ -n "$FLEET_MODEL" ]] && _model_arg=(--model "$FLEET_MODEL")

            # INFRA-1045: apply harness git identity (opencode-bigpickle, etc.)
            if [[ -n "${HARNESS_GIT_EMAIL:-}" ]]; then
                git -C "$wt_path" config user.email "$HARNESS_GIT_EMAIL" 2>/dev/null || true
                git -C "$wt_path" config user.name "${HARNESS_GIT_NAME:-$CHUMP_AGENT_HARNESS}" 2>/dev/null || true
                log "harness identity: ${HARNESS_GIT_NAME:-$CHUMP_AGENT_HARNESS} <${HARNESS_GIT_EMAIL}>"
            fi

            # INFRA-1045: dispatch non-claude harnesses before the full claude
            # machinery (no oauth token, no token-parser FIFO, no wedge retries).
            if [[ "${HARNESS_SPAWN_MODE:-claude-p}" != "claude-p" ]]; then
                _rc_harness=0
                case "${HARNESS_SPAWN_MODE}" in
                    opencode-prompt)
                        log "spawning ${HARNESS_SPAWN_PROGRAM:-opencode} (harness=${CHUMP_AGENT_HARNESS}, timeout ${FLEET_TIMEOUT_S}s) → $cycle_log"
                        ( cd "$wt_path" || exit 99
                          # shellcheck disable=SC2086
                          $_TO "${HARNESS_SPAWN_PROGRAM:-opencode}" "${_model_arg[@]}" "$prompt"
                        ) >"$cycle_log" 2>&1
                        _rc_harness=$?
                        ;;
                    codex-prompt)
                        log "spawning ${HARNESS_SPAWN_PROGRAM:-codex} (harness=${CHUMP_AGENT_HARNESS}, timeout ${FLEET_TIMEOUT_S}s) → $cycle_log"
                        ( cd "$wt_path" || exit 99
                          # shellcheck disable=SC2086
                          $_TO "${HARNESS_SPAWN_PROGRAM:-codex}" --approval-mode auto-edit "${_model_arg[@]}" "$prompt"
                        ) >"$cycle_log" 2>&1
                        _rc_harness=$?
                        ;;
                    manual-result-file)
                        _mrf="${CHUMP_MANUAL_RESULT:-/tmp/chump-manual-${GAP_ID}.result}"
                        log "MANUAL HARNESS — awaiting ${_mrf}"
                        printf '\n══ MANUAL GAP: %s ══\n%s\n══ END PROMPT ══\n' "$GAP_ID" "$prompt"
                        rm -f "$_mrf"
                        printf 'Create %s (write "done" or PR number) when complete.\n' "$_mrf"
                        until [[ -f "$_mrf" ]]; do sleep 5; done
                        _rc_harness=0
                        ;;
                    *)
                        log "ERROR: unknown HARNESS_SPAWN_MODE=${HARNESS_SPAWN_MODE} for harness=${CHUMP_AGENT_HARNESS}"
                        _rc_harness=2
                        ;;
                esac
                rc=$_rc_harness
            else
            # INFRA-620: re-read oauth token from file before each spawn so
            # subscription-mode workers don't use the stale launch-time token.
            refresh_oauth_token
            log "spawning claude -p (timeout ${FLEET_TIMEOUT_S}s, backend=claude, model=${FLEET_MODEL:-default}) → $cycle_log"
            # INFRA-492: wire INFRA-477 session-track. Pre-fix the cost
            # ledger CLI existed but nothing emitted session_start /
            # session_end, so briefing's "historical median elapsed"
            # was always "no data." Best-effort — silent if chump
            # binary is missing.
            chump session-track --start "$GAP_ID" >/dev/null 2>&1 || true

            # INFRA-639: per-cycle token attribution via tee+parse.
            # Start a background python3 process that reads claude's stdout
            # JSON stream through a named pipe and emits token_usage_partial
            # ambient events for each line carrying a .usage field.  If the
            # worker is killed before session_end fires, the partial events
            # already persisted to ambient.jsonl so waste-tally can attribute
            # the burned tokens (aggregated in src/waste_tally.rs).
            _cycle_id="${AGENT_ID}-${GAP_ID}-${sid}"
            _tok_fifo=""
            _tok_parser_pid=0
            _tok_parse_script="$REPO_ROOT/scripts/dispatch/_parse_token_usage.py"
            _amb_for_tok="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
            if [[ -f "$_tok_parse_script" ]] && command -v mkfifo >/dev/null 2>&1; then
                _tok_fifo_candidate="$(mktemp -u -t chump-tok.XXXXXX 2>/dev/null || true)"
                if [[ -n "$_tok_fifo_candidate" ]] && mkfifo "$_tok_fifo_candidate" 2>/dev/null; then
                    _tok_fifo="$_tok_fifo_candidate"
                    python3 "$_tok_parse_script" \
                        "$_tok_fifo" "$_amb_for_tok" "$GAP_ID" "$_cycle_id" \
                        "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
                        >/dev/null 2>&1 &
                    _tok_parser_pid=$!
                fi
            fi

            # INFRA-525: checkpoint-on-timeout watchdog. Sonnet workers
            # routinely write the fix + tests + run cargo build, then
            # timeout at 600s before getting to 'gh pr create + bot-merge'.
            # Result: 9-10min of completed work is silently discarded.
            #
            # Watchdog: at T - CHUMP_TIMEOUT_CHECKPOINT_SECS (default 30s)
            # before claude -p hits FLEET_TIMEOUT_S, force a WIP commit +
            # push the worktree's branch. Operator OR a sibling worker can
            # rescue from origin/<branch>. Default ON; set
            # CHUMP_TIMEOUT_CHECKPOINT_SECS=0 to disable.
            _checkpoint_secs="${CHUMP_TIMEOUT_CHECKPOINT_SECS:-30}"
            _checkpoint_at=$(( FLEET_TIMEOUT_S - _checkpoint_secs ))
            _checkpoint_pid=""
            if (( _checkpoint_at > 0 )); then
                # Background watchdog: sleeps to T-30s, then commits+pushes.
                (
                    sleep "$_checkpoint_at"
                    cd "$wt_path" 2>/dev/null || exit 0
                    # Stage everything (tracked + untracked). Skip if no diff.
                    git add -A 2>/dev/null || true
                    if ! git diff --cached --quiet 2>/dev/null; then
                        git -c user.name='chump-fleet-checkpoint' \
                            -c user.email='chump-fleet@noreply.bot' \
                            commit -m "WIP-${GAP_ID}: timeout-rescue checkpoint (INFRA-525)

Auto-saved by worker.sh checkpoint-on-timeout watchdog at
T-${_checkpoint_secs}s before FLEET_TIMEOUT_S=${FLEET_TIMEOUT_S}s.
Operator or sibling worker can rescue this branch via:
  gh pr create --base main --head ${branch} --title '${GAP_ID}: <title>' --body '...'
" 2>/dev/null || true
                        git push -u origin "$branch" 2>/dev/null || true
                        # Emit ALERT so operator sees the rescue point.
                        _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                        printf '{"event":"ALERT","kind":"fleet_timeout_checkpoint","ts":"%s","agent":"%s","gap_id":"%s","branch":"%s","note":"WIP commit pushed; rescue via gh pr create"}\n' \
                            "$_ts" "$AGENT_ID" "$GAP_ID" "$branch" \
                            >> "$_amb" 2>/dev/null || true
                    fi
                ) &
                _checkpoint_pid=$!
            fi

            # FLEET-042: heartbeat background process while claude is running.
            _heartbeat_pid=0
            (
                sleep 1  # Let claude process start
                while kill -0 $$ 2>/dev/null; do
                    write_heartbeat "$GAP_ID"
                    # INFRA-1116 AC5: refresh INTENT announcement every heartbeat cycle
                    # so other sessions' overlap gates see us as live.
                    if [[ -n "${GAP_ID:-}" && -n "${CHUMP_SESSION_ID:-}" ]]; then
                        _amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
                        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                        printf '{"ts":"%s","kind":"intent_refreshed","gap_id":"%s","session_id":"%s"}\n' \
                            "$_ts" "$GAP_ID" "$CHUMP_SESSION_ID" >> "$_amb" 2>/dev/null || true
                    fi
                    sleep "$_heartbeat_interval"
                done
            ) &
            _heartbeat_pid=$!

            # INFRA-823: first-output watchdog + wedge retry loop.
            # Kills and retries if claude produces no stdout within
            # FIRST_OUTPUT_TIMEOUT_S (default 120s). Max 2 retries.
            _wedge_retries=0
            _wedge_retry_max=2
            _prompt="$prompt"
            while [ "$_wedge_retries" -le "$_wedge_retry_max" ]; do
                # Use shorter timeout for retries (300s) vs initial (FLEET_TIMEOUT_S).
                if [ "$_wedge_retries" -gt 0 ]; then
                    _retry_to_s="${CHUMP_RETRY_TIMEOUT_S:-300}"
                    if command -v timeout >/dev/null 2>&1; then
                        _TO="timeout ${_retry_to_s}s"
                    elif command -v gtimeout >/dev/null 2>&1; then
                        _TO="gtimeout ${_retry_to_s}s"
                    else
                        _TO="$TO"
                    fi
                else
                    _TO="$TO"
                fi
                # INFRA-831: capture HEAD SHA before spawn so we can detect
                # whether claude produced any commit before FLEET_TIMEOUT_S fired.
                _pre_cycle_sha="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")"
                : > "$cycle_log"
                (
                    cd "$wt_path" || exit 99
                    # Same surface as src/dispatch.rs WorkBackend::Headless.
                    # INFRA-639: tee stdout through the token-parser fifo when
                    # available so partial usage events are captured mid-flight.
                    # pipefail (inherited) propagates claude's exit code through tee.
                    # shellcheck disable=SC2086
                    if [[ -n "$_tok_fifo" ]]; then
                        $_TO claude -p "$_prompt" --dangerously-skip-permissions --output-format stream-json --verbose "${_model_arg[@]}" \
                            | tee "$_tok_fifo"
                    else
                        $_TO claude -p "$_prompt" --dangerously-skip-permissions --output-format stream-json --verbose "${_model_arg[@]}"
                    fi
                ) >"$cycle_log" 2>&1 &
                _claude_pid=$!

                # INFRA-828: First-output watchdog — kills claude if no stdout within
                # CHUMP_FIRST_OUTPUT_TIMEOUT_S (default 120s). CHUMP_FIRST_OUTPUT_WATCHDOG=0 disables.
                _fo_watchdog_pid=0
                if [[ "${CHUMP_FIRST_OUTPUT_WATCHDOG:-1}" != "0" ]]; then
                    (
                        sleep "$_first_output_timeout"
                        if [ -f "$cycle_log" ] && [ "$(wc -c < "$cycle_log" 2>/dev/null || echo 0)" -lt 10 ]; then
                            kill "-TERM" "$_claude_pid" 2>/dev/null || true
                            sleep 2
                            kill "-KILL" "$_claude_pid" 2>/dev/null || true
                        fi
                    ) &
                    _fo_watchdog_pid=$!
                fi

                # INFRA-705: stall-detector — kills cycle if no new output for
                # CHUMP_STALL_THRESHOLD_S consecutive seconds (default 120).
                # Complements the first-output watchdog: that one fires on zero
                # initial output; this one fires on mid-cycle output stalls.
                _stall_threshold="${CHUMP_STALL_THRESHOLD_S:-120}"
                # RESILIENT-157: true (0) if a cargo/rustc/clippy-driver/sccache
                # build is an ACTIVE DESCENDANT of $1 (the claude -p pid) — i.e.
                # the cycle is silently COMPILING (a workspace clippy/build can run
                # 3-5min streaming no output to claude stdout), not stuck. Walks the
                # process tree breadth-first (claude → sh → cargo → rustc).
                _has_build_descendant() {
                    local frontier="$1" next pid kid cmd
                    local -i depth=0
                    while [[ -n "${frontier// /}" && $depth -lt 8 ]]; do
                        next=""
                        for pid in $frontier; do
                            for kid in $(pgrep -P "$pid" 2>/dev/null); do
                                cmd=$(ps -o comm= -p "$kid" 2>/dev/null)
                                case "$cmd" in
                                    *cargo*|*rustc*|*clippy-driver*|*sccache*) return 0 ;;
                                esac
                                next="$next $kid"
                            done
                        done
                        frontier="$next"
                        depth=$((depth+1))
                    done
                    return 1
                }
                (
                    _sd_last_sz=0
                    _sd_last_active=$SECONDS
                    while kill -0 "$_claude_pid" 2>/dev/null; do
                        sleep 10
                        _sd_cur_sz=$(wc -c < "$cycle_log" 2>/dev/null | tr -d ' ' || echo 0)
                        if [[ "$_sd_cur_sz" -gt "$_sd_last_sz" ]]; then
                            _sd_last_sz=$_sd_cur_sz
                            _sd_last_active=$SECONDS
                        fi
                        _sd_idle=$(( SECONDS - _sd_last_active ))
                        if [[ $_sd_idle -ge $_stall_threshold ]]; then
                            # RESILIENT-157: a clippy/cargo build streams no output
                            # for minutes — that's compiling, not stalled. Defer the
                            # kill while a build descendant is live; reset the idle
                            # clock and re-check next interval. A genuinely-hung
                            # claude has no active build child → still killed below.
                            if _has_build_descendant "$_claude_pid"; then
                                printf '{"ts":"%s","kind":"stall_deferred_build","gap_id":"%s","agent_id":"%s","idle_s":%d}\n' \
                                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                    "${GAP_ID:-unknown}" "${AGENT_ID:-unknown}" "$_sd_idle" \
                                    >> "${CHUMP_LOCKS_DIR:-.chump-locks}/ambient.jsonl" 2>/dev/null || true
                                log "INFRA-705/RESILIENT-157: ${_sd_idle}s no-output but a cargo/rustc build is active — deferring stall kill (compiling, not stuck)"
                                _sd_last_active=$SECONDS
                                continue
                            fi
                            printf '{"ts":"%s","kind":"cycle_stall_killed","gap_id":"%s","agent_id":"%s","idle_s":%d}\n' \
                                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                "${GAP_ID:-unknown}" \
                                "${AGENT_ID:-unknown}" \
                                "$_sd_idle" \
                                >> "${CHUMP_LOCKS_DIR:-.chump-locks}/ambient.jsonl" 2>/dev/null || true
                            log "INFRA-705: stall-detector firing (no output for ${_sd_idle}s ≥ threshold ${_stall_threshold}s) — killing cycle"
                            kill "-TERM" "$_claude_pid" 2>/dev/null || true
                            sleep 2
                            kill "-KILL" "$_claude_pid" 2>/dev/null || true
                            break
                        fi
                    done
                ) &
                _stall_detector_pid=$!

                wait "$_claude_pid" 2>/dev/null
                rc=$?
                [[ "$_fo_watchdog_pid" -ne 0 ]] && kill "$_fo_watchdog_pid" 2>/dev/null || true
                [[ "$_fo_watchdog_pid" -ne 0 ]] && wait "$_fo_watchdog_pid" 2>/dev/null || true
                kill "$_stall_detector_pid" 2>/dev/null || true
                wait "$_stall_detector_pid" 2>/dev/null || true

                # Check for wedge: near-empty log + timeout or clean exit.
                _log_sz=0
                [ -f "$cycle_log" ] && _log_sz=$(wc -c < "$cycle_log" 2>/dev/null | tr -d ' ' || echo 0)
                if [ "$_log_sz" -lt 100 ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; }; then
                    _wedge_retries=$((_wedge_retries + 1))
                    _wedge_count=$((_wedge_count + 1))
                    if [ "$_wedge_retries" -le "$_wedge_retry_max" ]; then
                        log "INFRA-823: wedge detected (rc=$rc, log=${_log_sz}B) — retry $_wedge_retries/$_wedge_retry_max with unstick prompt"
                        _prompt="You appear to be stuck producing output. Start working immediately. ${_prompt}"
                        continue
                    fi
                    # INFRA-828: retry budget exhausted — emit first-output timeout alert.
                    _elapsed_s=$(( $(date +%s) - _cycle_start_s ))
                    printf '{"ts":"%s","kind":"worker_first_output_timeout","agent_id":"%s","gap_id":"%s","elapsed_s":%d,"retries":%d}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        "${AGENT_ID:-unknown}" \
                        "${GAP_ID:-unknown}" \
                        "$_elapsed_s" \
                        "$_wedge_retries" \
                        >> "${CHUMP_AMBIENT_LOG:-${CHUMP_LOCKS_DIR:-.chump-locks}/ambient.jsonl}" 2>/dev/null || true
                    log "INFRA-828: worker_first_output_timeout after $_wedge_retries retries (${_elapsed_s}s elapsed)"
                fi
                break
            done

            # FLEET-042: kill heartbeat background process after claude exits.
            if [[ "$_heartbeat_pid" -ne 0 ]]; then
                kill "$_heartbeat_pid" 2>/dev/null || true
                wait "$_heartbeat_pid" 2>/dev/null || true
            fi

            # INFRA-639: tear down token parser after claude exits.
            if [[ "$_tok_parser_pid" -ne 0 ]]; then
                wait "$_tok_parser_pid" 2>/dev/null || true
                _tok_parser_pid=0
            fi
            rm -f "$_tok_fifo" 2>/dev/null || true
            _tok_fifo=""

            # INFRA-525: kill the checkpoint watchdog if claude exited
            # cleanly before T-30s — no rescue needed.
            if [[ -n "$_checkpoint_pid" ]]; then
                kill "$_checkpoint_pid" 2>/dev/null || true
                wait "$_checkpoint_pid" 2>/dev/null || true
            fi
            fi  # INFRA-1045: end of claude-p harness block
            ;;
        chump-local)
            log "spawning chump --execute-gap $GAP_ID (timeout ${FLEET_TIMEOUT_S}s, backend=chump-local) → $cycle_log"
            (
                cd "$wt_path" || exit 99
                # COG-025: route inference through src/provider_cascade.rs
                # so this gap is carried by free-tier providers (Cerebras,
                # Groq, Together, etc.). Reflection rows tag backend=chump-local
                # so COG-026 A/B can split outcomes.
                # shellcheck disable=SC2086
                $TO chump --execute-gap "$GAP_ID"
            ) >"$cycle_log" 2>&1
            rc=$?
            ;;
        *)
            log "ERROR: unknown FLEET_BACKEND=$FLEET_BACKEND; skipping cycle"
            rc=2
            ;;
    esac

    # ── INFRA-525: reap watchdog if agent exited before checkpoint fired ─────
    if [ "$_watchdog_pid" -ne 0 ] && kill -0 "$_watchdog_pid" 2>/dev/null; then
        kill "$_watchdog_pid" 2>/dev/null || true
        wait "$_watchdog_pid" 2>/dev/null || true
    fi

    # ── INFRA-572: classify exit code and emit worker_exit ambient event ──
    exit_class="$(classify_rc "$rc")"
    _amb_we="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$_amb_we")" 2>/dev/null || true
    printf '{"ts":"%s","session":"%s","worktree":"%s","event":"worker_exit","kind":"worker_exit","agent_id":"%s","gap_id":"%s","rc":%d,"exit_class":"%s","backend":"%s","model":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
        "$wt_name" "$AGENT_ID" "$GAP_ID" "$rc" "$exit_class" \
        "$FLEET_BACKEND" "${FLEET_MODEL:-default}" \
        >> "$_amb_we" 2>/dev/null || true

    # ── INFRA-666: pre-ship-clippy-fix phase ──────────────────────────────
    # After claude exits cleanly (rc=0), run cargo clippy + fmt to fix any
    # auto-fixable lints BEFORE bot-merge opens the PR. Opt-out: set
    # CHUMP_SKIP_PRESHIP_CLIPPY=1. If clippy/fmt fails, log and continue
    # (the PR is already open; we just won't have lint fixes).
    if [[ "$rc" -eq 0 ]] && [[ "${CHUMP_SKIP_PRESHIP_CLIPPY:-0}" != "1" ]]; then
        log "INFRA-666: pre-ship-clippy-fix phase starting"
        (
            cd "$wt_path" || exit 0
            # Apply clippy fixes (allow-dirty for staged changes, allow-staged for both).
            cargo clippy --workspace --all-targets --fix --allow-dirty --allow-staged 2>/dev/null || {
                log "WARN INFRA-666: cargo clippy --fix failed (continuing)"
                exit 0
            }
            # Format code.
            cargo fmt --all 2>/dev/null || {
                log "WARN INFRA-666: cargo fmt failed (continuing)"
                exit 0
            }
            # If there are new changes, amend the last commit and push.
            if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
                git add -A 2>/dev/null || true
                git -c user.name='chump-fleet' \
                    -c user.email='chump-fleet@noreply.bot' \
                    commit --amend --no-edit 2>/dev/null || {
                    log "WARN INFRA-666: amend commit failed (continuing)"
                    exit 0
                }
                # Force-push so the PR on GitHub gets updated (auto-merge is already armed).
                git push --force-with-lease origin "$branch" 2>/dev/null || {
                    log "WARN INFRA-666: force-push failed (PR may have stale lints)"
                    exit 0
                }
                log "INFRA-666: clippy fixes pushed (amend + force-push)"
            else
                log "INFRA-666: no clippy fixes needed"
            fi
        ) || true  # non-fatal — PR is already open
    fi

    # ── INFRA-464: 401-storm detector ─────────────────────────────────────
    # Background: the 2026-05-03 Haiku fleet ran 875/911 cycles (96%) into
    # `Failed to authenticate. API Error: 401` for hours undetected. The
    # `claude` CLI's auth token had been revoked (likely $20/mo cap hit
    # mid-fleet); every subsequent pane inherited the dead state and burned
    # CPU on retry loops. Nothing alerted.
    #
    # Fix: scan the cycle log for auth-failure indicators after every
    # invocation. Track consecutive failures per agent in a counter file.
    # Two thresholds:
    #   CHUMP_AUTH_STORM_PAUSE (default 3): ALERT + sleep
    #     CHUMP_AUTH_STORM_PAUSE_SECS (default 1800 = 30min)
    #   CHUMP_AUTH_STORM_EXIT  (default 5): ALERT + exit the worker loop
    # Reset the counter on any cycle whose log has NO auth-failure marker.
    _auth_counter_file="$FLEET_LOG_DIR/agent-${AGENT_ID}.auth-fails"
    _auth_storm_pause_threshold="${CHUMP_AUTH_STORM_PAUSE:-3}"
    _auth_storm_exit_threshold="${CHUMP_AUTH_STORM_EXIT:-5}"
    _auth_storm_pause_secs="${CHUMP_AUTH_STORM_PAUSE_SECS:-1800}"
    if [ -f "$cycle_log" ] \
       && grep -qE 'Invalid authentication credentials|"type":"authentication_error"|API Error: 401' "$cycle_log" 2>/dev/null; then
        _n=$(cat "$_auth_counter_file" 2>/dev/null || echo 0)
        _n=$((_n + 1))
        echo "$_n" > "$_auth_counter_file"
        log "WARN: auth failure detected in cycle log (consecutive=$_n)"

        _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _amb_path="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$_amb_path")" 2>/dev/null || true

        if [ "$_n" -ge "$_auth_storm_exit_threshold" ]; then
            printf '{"ts":"%s","session":"%s","worktree":"worker-%s","event":"ALERT","kind":"fleet_auth_storm","agent_id":"%s","consecutive_failures":%d,"action":"worker_exit"}\n' \
                "$_ts" \
                "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
                "$AGENT_ID" "$AGENT_ID" "$_n" \
                >> "$_amb_path" 2>/dev/null || true
            log "ALERT kind=fleet_auth_storm consecutive=$_n — exiting worker loop (auth tokens appear dead; restart fleet after re-authenticating)"
            exit 3
        elif [ "$_n" -ge "$_auth_storm_pause_threshold" ]; then
            printf '{"ts":"%s","session":"%s","worktree":"worker-%s","event":"ALERT","kind":"fleet_auth_storm","agent_id":"%s","consecutive_failures":%d,"action":"worker_pause","pause_secs":%d}\n' \
                "$_ts" \
                "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
                "$AGENT_ID" "$AGENT_ID" "$_n" "$_auth_storm_pause_secs" \
                >> "$_amb_path" 2>/dev/null || true
            log "ALERT kind=fleet_auth_storm consecutive=$_n — pausing ${_auth_storm_pause_secs}s before next cycle"
            sleep "$_auth_storm_pause_secs"
        fi
    else
        # Cycle had no auth failure — reset the counter (transient blips
        # don't accumulate forever).
        [ -f "$_auth_counter_file" ] && rm -f "$_auth_counter_file"
    fi

    # INFRA-823: detect "0-byte cycle log" as a strong wedge signal —
    # claude -p produced no stdout for the entire timeout window.
    # Also catches rc=0 + 0-byte (claude exited cleanly having done
    # nothing — missed by the original rc=124-only check). Emit
    # ambient alert so operators see it, not just a log line.
    _cycle_log_size=0
    if [ -f "$cycle_log" ]; then
        _cycle_log_size=$(wc -c < "$cycle_log" 2>/dev/null | tr -d ' ' || echo 0)
    fi
    _is_wedge=0
    if [ "$_cycle_log_size" -lt 100 ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; }; then
        _is_wedge=1
    fi

    if [ "$_is_wedge" -eq 1 ]; then
        _wedge_count=$((_wedge_count + 1))
        _ts_w="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _amb_w="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$_amb_w")" 2>/dev/null || true
        printf '{"ts":"%s","session":"%s","worktree":"%s","event":"ALERT","kind":"worker_wedge_detected","agent_id":"%s","gap_id":"%s","rc":%d,"cycle_log_size":%d,"wedge_count":%d}\n' \
            "$_ts_w" \
            "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
            "$wt_name" "$AGENT_ID" "$GAP_ID" "$rc" "$_cycle_log_size" "$_wedge_count" \
            >> "$_amb_w" 2>/dev/null || true
        log "ALERT kind=worker_wedge_detected agent=$AGENT_ID gap=$GAP_ID rc=$rc log=${_cycle_log_size}B wedge_count=$_wedge_count"

        # INFRA-823: wedge storm detection — if N+ wedges in rolling 1h window,
        # emit fleet_wedge_storm. This indicates a systemic issue (auth down,
        # API incompatibility, prompt format break) rather than per-gap bad luck.
        _wedge_storm_file="/tmp/chump-fleet-worker-${AGENT_ID}.wedge-count"
        _now_ts=$(date +%s)
        _one_hour_ago=$(( _now_ts - 3600 ))
        # Append current wedge timestamp to rolling window file.
        printf '%d\n' "$_now_ts" >> "$_wedge_storm_file" 2>/dev/null || true
        # Count timestamps within the last hour; prune older ones.
        _recent_wedges=0
        if [ -f "$_wedge_storm_file" ]; then
            _tmp_pruned="/tmp/chump-fleet-worker-${AGENT_ID}.wedge-pruned"
            awk -v cutoff="$_one_hour_ago" '$1 > cutoff' "$_wedge_storm_file" > "$_tmp_pruned" 2>/dev/null || true
            mv "$_tmp_pruned" "$_wedge_storm_file" 2>/dev/null || true
            _recent_wedges=$(wc -l < "$_wedge_storm_file" 2>/dev/null | tr -d ' ' || echo 0)
        fi
        if [ "$_recent_wedges" -ge "$_wedge_storm_threshold" ]; then
            printf '{"ts":"%s","session":"%s","worktree":"%s","event":"ALERT","kind":"fleet_wedge_storm","agent_id":"%s","recent_wedges":%d,"threshold":%d,"window_h":1}\n' \
                "$_ts_w" \
                "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
                "$wt_name" "$AGENT_ID" "$_recent_wedges" "$_wedge_storm_threshold" \
                >> "$_amb_w" 2>/dev/null || true
            log "ALERT kind=fleet_wedge_storm agent=$AGENT_ID recent_wedges=$_recent_wedges >= threshold=$_wedge_storm_threshold"
        fi
    fi

    # FLEET-043: track consecutive dispatch failures for circuit breaker.
    # Reset on success, increment on any failure.
    if [ "$rc" -eq 0 ]; then
        log "$FLEET_BACKEND exited CLEAN (rc=0) for $GAP_ID"
        _dispatch_fail_count=0
    elif [ "$rc" -eq 124 ]; then
        _dispatch_fail_count=$((_dispatch_fail_count + 1))
        if [ "$_is_wedge" -eq 1 ]; then
            log "WARN: $FLEET_BACKEND exited TIMEOUT/WEDGED (rc=124, cycle_log=${_cycle_log_size}B) on $GAP_ID — applying extended cooldown"
        else
            log "WARN: $FLEET_BACKEND exited TIMEOUT (rc=124, ${FLEET_TIMEOUT_S}s, cycle_log=${_cycle_log_size}B) on $GAP_ID"
        fi
    else
        log "WARN: $FLEET_BACKEND exited $exit_class (rc=$rc) on $GAP_ID"
        _dispatch_fail_count=$((_dispatch_fail_count + 1))

        # ── INFRA-267: P0 fallback to Anthropic ─────────────────────────────
        # When the chump-local backend (free-tier cascade) fails on a P0 gap,
        # fall through to the Anthropic claude path so high-priority work
        # doesn't silently fail just because the cascade is exhausted /
        # unsupported / hung. Only applies to:
        #   - FLEET_BACKEND=chump-local (the fallback target is `claude`)
        #   - rc != 0 AND rc != 124 (genuine failure, not timeout)
        #   - gap priority == P0 (read from the per-file YAML mirror)
        #   - CHUMP_P0_FALLBACK=1 (default on; set to 0 to disable for
        #     budget-strict environments where ANY Anthropic spend is
        #     unwelcome)
        #
        # The claude branch above already holds the inline-briefing logic;
        # we re-invoke claude here with a minimal prompt rather than
        # duplicating that whole block.
        if [[ "$FLEET_BACKEND" == "chump-local" ]] \
           && [[ "${CHUMP_P0_FALLBACK:-1}" != "0" ]] \
           && command -v claude >/dev/null 2>&1; then
            # INFRA-502: priority lookup via 'chump gap show' (state.db
            # canonical post-INFRA-498). Fall back to legacy YAML path
            # if the show CLI fails (very old chump binary).
            _gap_priority=""
            if _gs="$(chump gap show "$GAP_ID" 2>/dev/null)" && [[ -n "$_gs" ]]; then
                _gap_priority=$(echo "$_gs" | grep -E '^\s*priority:' \
                    | head -1 | sed -E 's/.*priority:\s*//;s/["'\''"]//g' | tr -d ' ')
            fi
            if [[ -z "$_gap_priority" ]]; then
                _gap_yaml_path="$wt_path/docs/gaps/${GAP_ID}.yaml"
                if [[ -f "$_gap_yaml_path" ]]; then
                    _gap_priority=$(grep -E '^\s*priority:' "$_gap_yaml_path" 2>/dev/null \
                        | head -1 | sed -E 's/.*priority:\s*//;s/["'\''"]//g' | tr -d ' ')
                fi
            fi
            if [[ "$_gap_priority" == "P0" ]]; then
                log "INFRA-267: P0 gap $GAP_ID failed on chump-local rc=$rc — falling back to claude"
                _fallback_prompt="Ship gap ${GAP_ID} (P0 fallback from chump-local rc=$rc). The gap is already claimed for this session; lease in .chump-locks/. Worktree: ${wt_path}. Pre-flight has already run. Run 'chump gap show ${GAP_ID}' for the gap spec (post-INFRA-498). Implement, commit via scripts/coord/chump-commit.sh, ship via scripts/coord/bot-merge.sh --gap ${GAP_ID} --auto-merge --fast."
                FLEET_MODEL="${FLEET_MODEL-sonnet}"
                _model_arg=()
                [[ -n "$FLEET_MODEL" ]] && _model_arg=(--model "$FLEET_MODEL")
                (
                    cd "$wt_path" || exit 99
                    # shellcheck disable=SC2086
                    $TO claude -p "$_fallback_prompt" --dangerously-skip-permissions --output-format stream-json --verbose "${_model_arg[@]}"
                ) >>"$cycle_log" 2>&1
                rc=$?
                if [ $rc -eq 0 ]; then
                    log "INFRA-267: P0 fallback succeeded for $GAP_ID via claude"
                else
                    log "INFRA-267: P0 fallback ALSO failed for $GAP_ID (claude rc=$rc) — proceeding to cooldown"
                fi
            fi
        fi

        # INFRA-361: write cooldown record so siblings + future cycles
        # don't immediately re-pick this gap. Worker 4 was observed
        # re-picking INFRA-340 6 times in 5 minutes pre-fix.
        #
        # INFRA-483 (2026-05-05): cooldown now also fires on rc=124
        # (timeout). Pre-INFRA-483 timeouts skipped cooldown entirely,
        # so a worker that hit a wedged claude -p call would re-pick
        # the same gap and burn 600s × N cycles forever. Observed live
        # 2026-05-05: sonnet fleet, 2 workers, 2-3 cycles each, all
        # 0-byte cycle logs, ~40min total compute wasted.
        #
        # Two cooldown durations:
        #   FLEET_RC1_COOLDOWN_S        rc!=0 ordinary failure (default 30min)
        #   FLEET_TIMEOUT_COOLDOWN_S    rc=124 timeout (default 60min)
        #   FLEET_WEDGE_COOLDOWN_S      rc=124 + cycle_log<100B (default 4h)
        #     — wedge means claude -p produced no output AT ALL; the gap
        #     is likely incompatible with the current backend or hit a
        #     systemic issue (auth, API down, MCP startup hang).
        if [ "$rc" -ne 0 ]; then
            if [ "${_is_wedge:-0}" -eq 1 ]; then
                cooldown_s="${FLEET_WEDGE_COOLDOWN_S:-14400}"  # 4h default
                _cooldown_kind="wedge"
            elif [ "$rc" -eq 124 ]; then
                cooldown_s="${FLEET_TIMEOUT_COOLDOWN_S:-3600}"  # 1h default
                _cooldown_kind="timeout"
            else
                cooldown_s="${FLEET_RC1_COOLDOWN_S:-1800}"
                _cooldown_kind="rc=$rc"
            fi
            # FLEET-051: per-worker cooldown — file keyed ${AGENT_ID}-${GAP_ID}.json
            # so sibling workers are not blocked by this worker's failure.
            cooldown_dir="$REPO_ROOT/.chump-locks/cooldown"
            mkdir -p "$cooldown_dir" 2>/dev/null || true
            cooldown_until=$(( $(date +%s) + cooldown_s ))
            _safe_agent="${AGENT_ID:-0}"
            printf '{"gap_id":"%s","rc":%d,"kind":"%s","until":%d,"agent":"%s","ts":"%s","worker_id":"%s"}\n' \
                "$GAP_ID" "$rc" "$_cooldown_kind" "$cooldown_until" "$AGENT_ID" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_safe_agent" \
                > "$cooldown_dir/${_safe_agent}-${GAP_ID}.json" 2>/dev/null || true
            log "cooldown: worker $AGENT_ID cooling $GAP_ID for ${cooldown_s}s (kind=$_cooldown_kind)"

            # FLEET-051: cluster-wide block if >= FLEET_COOLDOWN_THRESHOLD distinct
            # workers have all cooled on this gap. Default threshold = 3.
            _cooldown_threshold="${FLEET_COOLDOWN_THRESHOLD:-3}"
            # shellcheck disable=SC2012  # glob patterns with * work reliably here; find is overkill
            _distinct_workers=$(ls "$cooldown_dir"/*"-${GAP_ID}.json" 2>/dev/null | wc -l | tr -d ' ')
            if [ "${_distinct_workers:-0}" -ge "$_cooldown_threshold" ]; then
                printf '{"gap_id":"%s","cooldown_kind":"cluster_wide","until":%d,"agent":"%s","ts":"%s","worker_count":%d}\n' \
                    "$GAP_ID" "$cooldown_until" "$AGENT_ID" \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_distinct_workers" \
                    > "$cooldown_dir/${GAP_ID}.json" 2>/dev/null || true
                _ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                printf '{"ts":"%s","session":"%s","kind":"worker_cooldown_cluster_wide","gap_id":"%s","worker_count":%d,"until":%d}\n' \
                    "$_ts_now" "${CHUMP_SESSION_ID:-fleet}" "$GAP_ID" "$_distinct_workers" "$cooldown_until" \
                    >> "$_amb" 2>/dev/null || true
                log "cooldown: cluster-wide block on $GAP_ID ($_distinct_workers workers failed)"
            else
                _ts_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                printf '{"ts":"%s","session":"%s","kind":"worker_cooldown","gap_id":"%s","worker_id":"%s","until":%d,"cooldown_kind":"%s"}\n' \
                    "$_ts_now" "${CHUMP_SESSION_ID:-fleet}" "$GAP_ID" "$_safe_agent" "$cooldown_until" "$_cooldown_kind" \
                    >> "$_amb" 2>/dev/null || true
            fi

            # INFRA-826 / FLEET-043: circuit breaker on consecutive non-ship cycles.
            # After CHUMP_DISPATCH_FAIL_THRESHOLD (default 3) consecutive wedge/fail/
            # timeout cycles, worker pauses CHUMP_CIRCUIT_PAUSE_SECS (default 300 = 5min)
            # and emits kind=worker_circuit_open to ambient.jsonl.
            # Disable entirely: CHUMP_CIRCUIT_BREAKER=0.
            if [[ "${CHUMP_CIRCUIT_BREAKER:-1}" != "0" ]]; then
                _dispatch_fail_threshold="${CHUMP_DISPATCH_FAIL_THRESHOLD:-3}"
                if [ "$_dispatch_fail_count" -ge "$_dispatch_fail_threshold" ]; then
                    _circuit_pause_secs="${CHUMP_CIRCUIT_PAUSE_SECS:-300}"  # 5min default
                    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                    mkdir -p "$(dirname "$_amb")" 2>/dev/null || true
                    printf '{"ts":"%s","session":"%s","worktree":"worker-%s","event":"ALERT","kind":"worker_circuit_open","agent_id":"%s","consecutive_failures":%d,"pause_secs":%d}\n' \
                        "$_ts" \
                        "${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-fleet-worker-$AGENT_ID}}" \
                        "$AGENT_ID" "$AGENT_ID" "$_dispatch_fail_count" "$_circuit_pause_secs" \
                        >> "$_amb" 2>/dev/null || true
                    log "ALERT kind=worker_circuit_open consecutive_dispatch_failures=$_dispatch_fail_count — pausing ${_circuit_pause_secs}s before next cycle"
                    _dispatch_fail_count=0  # reset after emitting alert
                    sleep "$_circuit_pause_secs"
                fi
            fi

            # INFRA-483: emit ALERT to ambient.jsonl on wedge so the
            # operator sees pure-waste cycles surface in the standard
            # tail -30 .chump-locks/ambient.jsonl pre-flight glance.
            if [ "${_is_wedge:-0}" -eq 1 ]; then
                _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
                _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                printf '{"event":"ALERT","kind":"fleet_wedge","ts":"%s","agent":"%s","gap_id":"%s","cycle_log":"%s","cycle_log_bytes":%d,"backend":"%s","model":"%s","cooldown_secs":%d,"hint":"claude -p produced no stdout in %ds — likely API/MCP wedge; check ANTHROPIC_API_KEY + reduce timeout"}\n' \
                    "$_ts" "$AGENT_ID" "$GAP_ID" "$cycle_log" "$_cycle_log_size" "$FLEET_BACKEND" "${FLEET_MODEL:-default}" "$cooldown_s" "$FLEET_TIMEOUT_S" \
                    >> "$_amb" 2>/dev/null || true
            fi
        fi
    fi

    # ── INFRA-831: timeout-no-commit rescue ──────────────────────────────────
    # Detect rc=124 (FLEET_TIMEOUT_S exhausted) where claude produced no
    # commit during the cycle. The INFRA-525 checkpoint watchdog fires at
    # T-30s and commits WIP, but it may be disabled
    # (CHUMP_TIMEOUT_CHECKPOINT_SECS=0) or the worktree may have had no
    # staged changes. INFRA-831 fills this gap: after the cycle completes
    # with rc=124 and no new commit, attempt a WIP rescue commit and emit
    # kind=worker_timeout_no_commit to ambient.jsonl.
    # Disable: CHUMP_TIMEOUT_RESCUE=0.
    if [[ "$rc" -eq 124 ]] && [[ "${CHUMP_TIMEOUT_RESCUE:-1}" != "0" ]]; then
        _post_cycle_sha="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")"
        # INFRA-1715: _pre_cycle_sha is only set on the success path at line 1006.
        # When the cycle short-circuits earlier (claim race, dispatch error,
        # etc.) it stays unbound, and `set -u` higher up makes the next line
        # crash the worker on rc=124 with "_pre_cycle_sha: unbound variable".
        # Default to empty so the comparison is a clean no-rescue path.
        if [[ -n "${_pre_cycle_sha:-}" ]] && [[ "${_pre_cycle_sha:-}" == "$_post_cycle_sha" ]]; then
            # No new commit since cycle start — attempt rescue
            _rescue_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            log "INFRA-831: rc=124 + no WIP commit — attempting rescue via chump-commit.sh"
            _rescue_committed=0
            (
                cd "$wt_path" || exit 1
                # Skip if nothing to commit
                if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
                    exit 0
                fi
                bash scripts/coord/chump-commit.sh . \
                    -m "WIP: timeout rescue [skip ci] (INFRA-831, ${FLEET_TIMEOUT_S:-600}s elapsed, agent=${AGENT_ID:-unknown})" \
                    2>/dev/null
            ) && _rescue_committed=1 || true
            # Double-check: verify a new SHA was created regardless of exit code
            _rescue_sha="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")"
            if [[ -n "$_rescue_sha" ]] && [[ "$_rescue_sha" != "$_post_cycle_sha" ]]; then
                _rescue_committed=1
            fi
            _amb831="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
            mkdir -p "$(dirname "$_amb831")" 2>/dev/null || true
            printf '{"ts":"%s","session":"%s","kind":"worker_timeout_no_commit","agent_id":"%s","gap_id":"%s","timeout_s":%d,"rescue_committed":%d}\n' \
                "$_rescue_ts" \
                "${CHUMP_SESSION_ID:-fleet-worker-$AGENT_ID}" \
                "${AGENT_ID:-unknown}" \
                "${GAP_ID:-unknown}" \
                "${FLEET_TIMEOUT_S:-600}" \
                "$_rescue_committed" \
                >> "$_amb831" 2>/dev/null || true
            log "INFRA-831: kind=worker_timeout_no_commit agent=${AGENT_ID:-unknown} gap=${GAP_ID:-unknown} timeout_s=${FLEET_TIMEOUT_S:-600} rescue_committed=$_rescue_committed"
        fi
    fi

    # INFRA-492 / INFRA-583: emit session_end with outcome BEFORE the lease
    # release. Outcome derivation:
    # - rc==0          = bot-merge.sh succeeded (PR created + auto-merge armed)
    #                    → shipped. The original ': gone' branch-status check
    #                    only flips AFTER GitHub deletes the merged remote
    #                    branch — many seconds AFTER bot-merge returns. That
    #                    mis-classified every just-shipped session as
    #                    abandoned (~14m/hr false-positive in waste-tally).
    # - rc==124        = timeout → starved
    # - rc==137 / 139  = OOM / segfault → abandoned (legitimate)
    # - other          = abandoned
    # Best-effort — silent on chump fail.
    _outcome="abandoned"
    if [ "$rc" -eq 0 ]; then
        _outcome="shipped"
    elif [ "$rc" -eq 124 ]; then
        _outcome="starved"
    fi
    chump session-track --end "$GAP_ID" --outcome "$_outcome" >/dev/null 2>&1 || true

    # INFRA-536: emit cycle_end timing event so p90 can be computed from
    # ambient.jsonl (e.g. jq 'select(.event=="cycle_end")|.elapsed_s').
    # Classifies: shipped / timeout / wedge / failed.
    _cycle_end_s=$(date +%s)
    _cycle_elapsed=$(( _cycle_end_s - ${_cycle_start_s:-_cycle_end_s} ))
    _cycle_kind="failed"
    if [ "$rc" -eq 0 ]; then
        # CREDIBLE-154: rc==0 is a CLAIM, not an outcome. "shipped" requires
        # evidence a PR actually exists for this gap's branch (2 of the first
        # 3 "ships" after the 2026-07-19 revival were phantoms: Mode A marked
        # ready_to_ship in the worktree-local db and no PR was ever created).
        # Evidence, cheapest first: webhook cache by head_ref → canonical-db
        # gap status → gh fallback. No evidence → kind=unverified_ship.
        _ship_branch="chump/$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')-claim"
        _ship_evidence=""
        _cache_db="${REPO_ROOT}/.chump/github_cache.db"
        if [ -f "$_cache_db" ]; then
            _ship_evidence="$(sqlite3 "$_cache_db" \
                "SELECT number FROM pr_state WHERE head_ref='${_ship_branch}' LIMIT 1" 2>/dev/null || true)"
        fi
        if [ -z "$_ship_evidence" ]; then
            _gap_now="$(CHUMP_REPO="$REPO_ROOT" chump gap show "$GAP_ID" 2>/dev/null \
                | grep -m1 -oE 'status: *[a-z_]+' | awk '{print $2}' || true)"
            case "$_gap_now" in ready_to_ship|done|shipped) _ship_evidence="status:$_gap_now" ;; esac
        fi
        if [ -z "$_ship_evidence" ]; then
            _ship_evidence="$(gh pr list --head "$_ship_branch" --state all --json number \
                --jq '.[0].number // empty' 2>/dev/null || true)"
        fi
        if [ -n "$_ship_evidence" ]; then
            _cycle_kind="shipped"
        else
            _cycle_kind="unverified_ship"
            log "CREDIBLE-154: rc=0 but NO ship evidence (branch=${_ship_branch}, no PR in cache/gh, gap not ready_to_ship) — classifying unverified_ship"
        fi
    elif [ "${_is_wedge:-0}" -eq 1 ]; then
        _cycle_kind="wedge"
    elif [ "$rc" -eq 124 ]; then
        _cycle_kind="timeout"
    fi
    _amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    printf '{"event":"cycle_end","ts":"%s","agent":"%s","gap_id":"%s","elapsed_s":%d,"rc":%d,"kind":"%s","model":"%s","cycle_log_bytes":%d}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$AGENT_ID" "$GAP_ID" "$_cycle_elapsed" "$rc" \
        "$_cycle_kind" "${FLEET_MODEL:-default}" "${_cycle_log_size:-0}" \
        >> "$_amb" 2>/dev/null || true
    log "cycle_end: elapsed=${_cycle_elapsed}s rc=$rc kind=$_cycle_kind"

    # ── INFRA-771: author-agent re-engagement loop ────────────────────────
    # Before releasing the lease, scan own open PRs for trusted handoff
    # comments (containing [handoff:apply]) that are newer than the PR HEAD
    # commit. If found: apply the diff, run tests, push if green.
    # Cap: 1 re-engagement per PR per worker session (tracked in _reh_done).
    # Lease remains live throughout. Best-effort: never fail the cycle.
    if [[ "${CHUMP_HANDOFF_REENGAGE:-1}" != "0" ]] && command -v gh >/dev/null 2>&1; then
        _reh_amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        _reh_done_file="${TMPDIR:-/tmp}/chump-reh-done-${AGENT_ID:-$$}"

        # List own open PRs (numbers only)
        _own_prs="$(gh pr list --author "@me" --state open --json number \
            --jq '.[].number' 2>/dev/null || true)"

        for _pr_num in $_own_prs; do
            # Skip if we already re-engaged this PR in this session
            if [[ -f "$_reh_done_file" ]] && grep -qxF "$_pr_num" "$_reh_done_file" 2>/dev/null; then
                continue
            fi

            # Get the PR HEAD sha and comments in one call
            _pr_json="$(gh pr view "$_pr_num" \
                --json headRefOid,comments,headRefName 2>/dev/null || true)"
            [[ -z "$_pr_json" ]] && continue

            _head_sha="$(printf '%s' "$_pr_json" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('headRefOid',''))" \
                2>/dev/null || true)"
            _head_branch="$(printf '%s' "$_pr_json" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('headRefName',''))" \
                2>/dev/null || true)"
            [[ -z "$_head_sha" ]] && continue

            # Find the timestamp of the HEAD commit
            _head_ts="$(gh api "repos/{owner}/{repo}/commits/$_head_sha" \
                --jq '.commit.committer.date' 2>/dev/null || true)"
            [[ -z "$_head_ts" ]] && continue

            # Scan comments for [handoff:apply] newer than HEAD commit
            # shellcheck disable=SC2259  # heredoc is the Python script; pipe feeds argv
            _handoff_body="$(printf '%s' "$_pr_json" | python3 - "$_head_ts" 2>/dev/null <<'PYEOF' || true
import sys, json
from datetime import datetime, timezone

head_ts_str = sys.argv[1]
try:
    head_ts = datetime.fromisoformat(head_ts_str.replace("Z", "+00:00"))
except Exception:
    sys.exit(0)

data = json.load(sys.stdin)
comments = data.get("comments", [])
for c in reversed(comments):
    body = c.get("body", "")
    if "[handoff:apply]" not in body:
        continue
    created = c.get("createdAt", "")
    try:
        c_ts = datetime.fromisoformat(created.replace("Z", "+00:00"))
    except Exception:
        continue
    if c_ts > head_ts:
        print(body)
        break
PYEOF
)"

            [[ -z "$_handoff_body" ]] && continue

            log "INFRA-771: handoff comment found on PR #$_pr_num — attempting re-engagement"

            # Extract diff block from the handoff comment
            _diff_block="$(printf '%s' "$_handoff_body" | python3 -c "
import sys, re
body = sys.stdin.read()
m = re.search(r'\`\`\`diff\s*\n(.*?)\n\`\`\`', body, re.DOTALL)
if m:
    print(m.group(1))
" 2>/dev/null || true)"

            if [[ -z "$_diff_block" ]]; then
                log "INFRA-771: no diff block in handoff comment for PR #$_pr_num — skipping"
                continue
            fi

            # ── INFRA-778: branch-diverged guard ────────────────────────────
            # If file overlap between the handoff diff target files and the
            # files changed in this PR branch (vs merge-base with main) is
            # < 50%, the branch was likely recycled for unrelated work.
            # Skip auto-apply and emit review_handoff_branch_diverged.
            # shellcheck disable=SC2259  # heredoc is the Python script; pipe feeds argv
            _778_overlap_pct="$(printf '%s' "$_diff_block" \
                | python3 - "$_head_sha" "$REPO_ROOT" <<'PY778' 2>/dev/null || echo 100
import sys, subprocess, re

head_sha = sys.argv[1]
repo    = sys.argv[2]
diff_block = sys.stdin.read()

target_files = set()
for line in diff_block.splitlines():
    m = re.match(r'^(?:---|\+\+\+) [ab]/(.+)$', line)
    if m and m.group(1) != '/dev/null':
        target_files.add(m.group(1))

if not target_files:
    print("100"); sys.exit(0)

try:
    mb = subprocess.check_output(
        ['git', '-C', repo, 'merge-base', 'HEAD', 'origin/main'],
        stderr=subprocess.DEVNULL, text=True).strip()
    branch_files = set(subprocess.check_output(
        ['git', '-C', repo, 'diff', '--name-only', mb, head_sha],
        stderr=subprocess.DEVNULL, text=True).splitlines())
except Exception:
    print("100"); sys.exit(0)

if not branch_files:
    print("100"); sys.exit(0)

union = target_files | branch_files
pct   = int(len(target_files & branch_files) * 100 / len(union))
print(str(pct))
PY778
)" || true
            _778_overlap_pct="${_778_overlap_pct:-100}"

            if [[ "$_778_overlap_pct" =~ ^[0-9]+$ ]] && [[ "$_778_overlap_pct" -lt 50 ]]; then
                log "INFRA-778: branch diverged on PR #$_pr_num (file overlap ${_778_overlap_pct}%) — skipping auto-apply"
                printf '{"ts":"%s","kind":"review_handoff_branch_diverged","pr_number":%s,"overlap_pct":%s,"agent_id":"%s","gap_id":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_pr_num" "$_778_overlap_pct" \
                    "${AGENT_ID:-unknown}" "${GAP_ID:-unknown}" \
                    >> "$_reh_amb" 2>/dev/null || true
                continue
            fi
            # ── End INFRA-778 branch-diverged guard ──────────────────────────

            # Record this PR as attempted (cap at 1 per session)
            printf '%s\n' "$_pr_num" >> "$_reh_done_file" 2>/dev/null || true

            # Apply diff to the worktree containing that branch
            _reh_wt="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
                | grep -B2 "branch refs/heads/$_head_branch" \
                | grep "^worktree " | head -1 | sed 's/^worktree //' || true)"
            # Fall back to current worktree if branch matches
            if [[ -z "$_reh_wt" ]]; then
                _cur_branch="$(git -C "${wt_path:-$REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
                [[ "$_cur_branch" == "$_head_branch" ]] && _reh_wt="${wt_path:-$REPO_ROOT}"
            fi
            [[ -z "$_reh_wt" ]] && { log "INFRA-771: can't locate worktree for $_head_branch — skipping"; continue; }

            # Apply and test
            _reh_ok=0
            if printf '%s\n' "$_diff_block" | git -C "$_reh_wt" apply --check - 2>/dev/null; then
                printf '%s\n' "$_diff_block" | git -C "$_reh_wt" apply - 2>/dev/null && {
                    # Run fast tests (INFRA-761 style: clippy + cargo test)
                    if cargo test --manifest-path "$_reh_wt/Cargo.toml" --bin chump --tests \
                            --quiet 2>/dev/null; then
                        git -C "$_reh_wt" add -u 2>/dev/null || true
                        git -C "$_reh_wt" commit -m "INFRA-771: apply handoff fix from PR #$_pr_num review" \
                            --no-verify 2>/dev/null && {
                            git -C "$_reh_wt" push origin "$_head_branch" --force-with-lease \
                                2>/dev/null && _reh_ok=1
                        }
                    fi
                }
            fi

            _reh_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            if [[ "$_reh_ok" -eq 1 ]]; then
                log "INFRA-771: handoff applied and pushed for PR #$_pr_num"
                printf '{"ts":"%s","kind":"review_handoff_applied","event":"review_handoff_applied","session":"%s","pr":%s,"gap_id":"%s","agent":"%s"}\n' \
                    "$_reh_ts" "${CHUMP_SESSION_ID:-$AGENT_ID}" "$_pr_num" "$GAP_ID" "$AGENT_ID" \
                    >> "$_reh_amb" 2>/dev/null || true
            else
                log "INFRA-771: handoff apply or tests failed for PR #$_pr_num"
                printf '{"ts":"%s","kind":"review_handoff_failed","event":"review_handoff_failed","session":"%s","pr":%s,"gap_id":"%s","agent":"%s","reason":"apply_or_test_failure"}\n' \
                    "$_reh_ts" "${CHUMP_SESSION_ID:-$AGENT_ID}" "$_pr_num" "$GAP_ID" "$AGENT_ID" \
                    >> "$_reh_amb" 2>/dev/null || true
            fi
        done

        rm -f "$_reh_done_file" 2>/dev/null || true
    fi
    # ── End INFRA-771 re-engagement loop ─────────────────────────────────

    # ── Release lease + prune worktree ────────────────────────────────────
    # INFRA-490: pre-fix this used the glob `*${GAP_ID}*.json` which was
    # case-sensitive — but lease files are named after the session ID
    # (e.g. `infra-470-fix.json`, `fleet-chump-fleet-agent1-NNNN.json`),
    # not the gap ID. The glob only matched leases whose session name
    # happened to contain the uppercase gap ID; the fleet's session
    # naming convention never produces such a match. Result: every
    # fleet cycle leaked its lease, the lease lingered to TTL, and the
    # watcher emitted `silent_agent` + `lease_expired_server` alerts —
    # the dominant kinds in the post-INFRA-489 waste-tally baseline
    # (26 + 23 = 49/93 incidents).
    #
    # Fix: delete the exact lease file by the known session ID. Fall
    # back to the legacy glob for any non-fleet caller that didn't
    # export CHUMP_SESSION_ID (best-effort, won't make things worse).
    if [[ -n "${CHUMP_SESSION_ID:-}" ]]; then
        rm -f "$REPO_ROOT/.chump-locks/${CHUMP_SESSION_ID}.json" 2>/dev/null || true
    fi
    # Legacy fallback (also catches any non-session-named leases this
    # gap may have under older code paths).
    rm -f "$REPO_ROOT/.chump-locks/"*"${GAP_ID}"*.json 2>/dev/null || true
    # INFRA-527: remove the gap-preflight lock so sibling workers aren't
    # blocked by a stale lock from a cycle that timed out or failed mid-run.
    rm -f "$REPO_ROOT/.chump-locks/.gap-${GAP_ID}.lock" 2>/dev/null || true

    # Worktree cleanup — keep it on disk if claude actually shipped a PR
    # (operator may want to inspect), otherwise remove. Simple proxy: if the
    # branch has been pushed (gone-status), prune; else leave for inspection.
    if git -C "$REPO_ROOT" branch -vv 2>/dev/null | grep -E "$branch" | grep -q ': gone\]'; then
        git -C "$REPO_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null || true
        log "cleaned up worktree $wt_name (branch was gone — PR landed)"
    else
        log "leaving worktree $wt_name on disk (rc=$rc; inspect if needed)"
    fi

    # Brief gap between cycles so we don't hammer the API on a hot-loop bug.
    sleep 5
done
