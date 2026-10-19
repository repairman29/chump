#!/usr/bin/env bash
# architect-tick.sh — RESILIENT-1634 (PHASE-R).
#
# Parent umbrella: the architect standing loop (the fleet's Chief-of-Staff /
# Air-Traffic-Control beat) was hand-work in a Mac desktop session. When the
# Mac hibernated on 2026-10-18 the loop went silent 05:15-14:50Z while trunk
# sat red and cuphead hit 99% disk — the "hand-work for an organ" class the
# owner named. This beat is the organ: ONE bounded `claude -p --model opus`
# tick on cuphead, fired by a user-scope systemd timer every 30 minutes, with
# zero desktop session required. Sibling of board-cycle-beat.sh (INFRA-3590)
# and the duty-officer judgment-tick (RESILIENT-1497); a more guarded cousin —
# the architect's tool allowlist forbids every ship-side mutation (no
# admin-merge, no --no-verify, no push to main, no bypass env var), so the
# worst a wedged tick can do is read, rerun, rebase-behind, and file findings.
#
# THE TICK (the agent does the judgment; this script only fires it, bounds it,
# guards admission, and writes/emits the proof):
#   1. Measure the BOARD (merge SLA / armed-PR health), TRUNK (is main green),
#      the NODES (fleet health), and the gap ROLLUP (done / total).
#   2. Unstick ONLY by rebase-behind or CI rerun — never admin-merge, never
#      hand-implement a gap, never push to main.
#   3. File findings as gaps / A2A proposals.
#   4. End the turn by printing the structured report block this script parses.
#
# ADMISSION (AC3): refuses to start when another `claude` is already running on
# the node (the one-claude-per-node "wait_quiet" rule the chains use), when free
# disk is under the floor (reaper first, then refuse under 20G), or when the
# single-architect lock is already held (so it never races a desktop architect
# session). Each refusal is a clean skip (exit 0) with an ambient emit.
#
# OUTPUTS (AC2): ~/.chump/architect/ticks/<UTC>.md plus a stable latest.md the
# Mac session or the operator reads — board, trunk, nodes, rollup done+total.
#
# Runs on cuphead via chump-architect-tick.{service,timer} (shipped DISABLED;
# enabling it is the operator's decision — see the PR body). Idempotent, safe to
# run by hand. A step failing never aborts observability: the ambient emit always
# fires so the tick's execution is provable, not assumed (DURABLE_FIX_DOCTRINE).
#
# Usage:
#   bash scripts/dispatch/architect-tick.sh
#
# Off-switch: CHUMP_ARCHITECT_TICK_ENABLED=0 (default on).
set -uo pipefail

[[ "${CHUMP_ARCHITECT_TICK_ENABLED:-1}" == "0" ]] && { echo "[architect-tick] disabled via CHUMP_ARCHITECT_TICK_ENABLED=0 — exit"; exit 0; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[architect-tick] cannot cd repo root" >&2; exit 1; }

TIMEOUT_S="${CHUMP_ARCHITECT_TICK_TIMEOUT_S:-900}"
MIN_DISK_G="${CHUMP_ARCHITECT_TICK_MIN_DISK_G:-20}"
MODEL="${CHUMP_ARCHITECT_TICK_MODEL:-opus}"
BUDGET_USD="${CHUMP_ARCHITECT_TICK_BUDGET_USD:-2.00}"
CLAUDE_BIN="${CHUMP_ARCHITECT_TICK_CLAUDE_BIN:-claude}"

# Base dir under the invoking user's HOME (CHUMP_ARCHITECT_HOME overrides for
# tests). Per crates/chump-provision no host literal lives here — HOME is
# resolved at run time from the systemd user manager.
ARCH_BASE="${CHUMP_ARCHITECT_HOME:-$HOME/.chump/architect}"
TICKS_DIR="$ARCH_BASE/ticks"
LATEST_MD="$ARCH_BASE/latest.md"
LOCK_FILE="$ARCH_BASE/architect.lock"
mkdir -p "$TICKS_DIR" 2>/dev/null || true

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[architect-tick %s] %s\n' "$(ts)" "$*"; }

# emit_skip <reason-slug> <detail> — one ambient architect_tick line marking a
# refused/aborted tick (admission guard). rollup numbers are -1 (not measured).
emit_skip() {
    local reason="$1" detail="${2:-}"
    printf '{"ts":"%s","kind":"architect_tick","node":"%s","outcome":"skipped","reason":"%s","rollup_done":-1,"rollup_total":-1,"detail":"%s"}\n' \
        "$(ts)" "$(hostname -s 2>/dev/null || echo node)" "$reason" "$detail" \
        >> "$AMBIENT" 2>/dev/null || true
}
# scanner-anchor: "kind":"architect_tick" — emitted by emit_skip above and by
# the terminal emit below (both this script's own printf, RESILIENT-1634).

# ── ADMISSION GUARD 1: single-architect lock (AC3) ──────────────────────────
# A desktop architect session or a prior still-running tick holds this lock.
# Non-blocking flock: if we cannot take it, another architect is live — skip.
exec {LOCK_FD}>"$LOCK_FILE" 2>/dev/null || true
if [[ -n "${LOCK_FD:-}" ]] && ! flock -n "$LOCK_FD"; then
    log "single-architect lock held ($LOCK_FILE) — another architect is running; skip"
    emit_skip single_architect_lock_held "$LOCK_FILE"
    exit 0
fi

# ── ADMISSION GUARD 2: one claude per node, the wait_quiet rule (AC3) ────────
# Count live `claude` processes on the node OTHER than this script's own
# subshell. The tick is the fleet's quiet-window beat: it must not add a
# second concurrent claude. CHUMP_ARCHITECT_TICK_CLAUDE_COUNT overrides the
# live count for tests (no real claude needed to prove the refusal).
claude_live_count() {
    if [[ -n "${CHUMP_ARCHITECT_TICK_CLAUDE_COUNT:-}" ]]; then
        echo "${CHUMP_ARCHITECT_TICK_CLAUDE_COUNT}"
        return 0
    fi
    pgrep -fc '(^|/)claude( |$)|claude -p' 2>/dev/null || echo 0
}
_claude_n="$(claude_live_count)"
case "$_claude_n" in '' | *[!0-9]*) _claude_n=0 ;; esac
if (( _claude_n > 0 )); then
    log "another claude is running on the node (count=$_claude_n) — wait_quiet rule; skip"
    emit_skip claude_already_running "count=$_claude_n"
    exit 0
fi

# ── ADMISSION GUARD 3: disk floor — reaper first, refuse under 20G (AC3) ─────
# CHUMP_ARCHITECT_TICK_FREE_G overrides the measured free space for tests.
free_disk_g() {
    if [[ -n "${CHUMP_ARCHITECT_TICK_FREE_G:-}" ]]; then
        echo "${CHUMP_ARCHITECT_TICK_FREE_G}"
        return 0
    fi
    # Available GiB on the filesystem holding the repo (portable: df -k, /1024/1024).
    df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}' || echo 0
}
_free_g="$(free_disk_g)"
case "$_free_g" in '' | *[!0-9]*) _free_g=0 ;; esac
if (( _free_g < MIN_DISK_G )); then
    log "free disk ${_free_g}G < floor ${MIN_DISK_G}G — running disk-pressure reaper first"
    REAPER="$REPO_ROOT/scripts/coord/disk-pressure-reaper.sh"
    [[ -x "$REAPER" || -f "$REAPER" ]] && bash "$REAPER" >/dev/null 2>&1 || true
    _free_g="$(free_disk_g)"
    case "$_free_g" in '' | *[!0-9]*) _free_g=0 ;; esac
    if (( _free_g < MIN_DISK_G )); then
        log "free disk still ${_free_g}G < ${MIN_DISK_G}G after reaper — refuse tick"
        emit_skip disk_below_floor "free=${_free_g}G floor=${MIN_DISK_G}G"
        exit 0
    fi
    log "reaper recovered disk to ${_free_g}G — proceeding"
fi

# ── Credentials (INFRA-3602 pattern): this beat runs from a bare systemd user
# process, not an interactive claude session, so CLAUDE_CODE_OAUTH_TOKEN is not
# inherited. Load the fleet's refreshed copy if neither auth env var is set. ──
if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" && -z "${ANTHROPIC_API_KEY:-}" && -r "$HOME/.chump/oauth-token.json" ]]; then
    _token=$(python3 -c "import json,sys; print(json.load(open('$HOME/.chump/oauth-token.json')).get('token',''))" 2>/dev/null)
    [[ -n "${_token:-}" ]] && export CLAUDE_CODE_OAUTH_TOKEN="$_token"
    unset _token
fi

git fetch origin main -q 2>/dev/null || true

# ── BRIEF: latest architect handoff + the previous tick report (the memory the
# organ carries between runs). Newest HANDOFF.md wins; missing is fine. ───────
HANDOFF_GLOB="${CHUMP_ARCHITECT_HANDOFF_GLOB:-$HOME/.chump/architect-handoff-*/HANDOFF.md}"
HANDOFF_TEXT="(no architect handoff found)"
# shellcheck disable=SC2086
_latest_handoff="$(ls -1t $HANDOFF_GLOB 2>/dev/null | head -1 || true)"
if [[ -n "${_latest_handoff:-}" && -r "$_latest_handoff" ]]; then
    HANDOFF_TEXT="$(sed -n '1,120p' "$_latest_handoff")"
fi
PREV_TICK_TEXT="(no previous tick report)"
[[ -r "$LATEST_MD" ]] && PREV_TICK_TEXT="$(sed -n '1,80p' "$LATEST_MD")"

RUN_UTC="$(ts)"
TICK_FILE="$TICKS_DIR/${RUN_UTC//[:]/-}.md"

# The structured block the agent prints LAST and this script extracts. Keeping
# the write in the shell (not an agent Write tool) is what lets the allowlist
# stay read-only + unstick-only (AC4) while AC2's files are always produced.
BEGIN_MARK="===ARCHITECT-TICK-REPORT==="
END_MARK="===END-ARCHITECT-TICK-REPORT==="

ARCH_PROMPT="You are the Chump architect / Air-Traffic-Control standing loop \
running ONE bounded tick on the node, no desktop session, per \
docs/strategy/PHASE_R_ARCHITECTURE_PROGRAM_2026-10-15.md and CLAUDE.md's ATC \
role. Do the work below and then STOP — do not loop, do not call \
ScheduleWakeup.

Your carried memory from the latest architect handoff:
${HANDOFF_TEXT}

Your previous tick report:
${PREV_TICK_TEXT}

THE TICK:
1. BOARD: read open PRs cache-first (.chump/github_cache.db before any 'gh pr' \
call, per CLAUDE.md) and score the 30-minute merge SLA — armed, all-green PRs \
past 30m are breaches.
2. TRUNK: is origin/main green right now? Name the single dominant cause if red.
3. NODES: quick fleet-health read (disk, ship-rate, dead daemons, orphaned \
leases) from ambient + chump health.
4. ROLLUP: count open vs done gaps ('chump gap list').
5. UNSTICK — ONLY by rebase-behind or CI rerun. You may rerun a failed check \
and rebase a BEHIND PR against its base. You must NOT: admin-merge (gh pr \
merge --admin), use --no-verify, push to main, or set any bypass env var. Arm \
auto-merge ONLY through the normal review-held predicate \
(scripts/coord/lib/arm-policy.sh, CREDIBLE-1526) — never by hand. Do NOT \
hand-implement any gap; file it and let the fleet build it.
6. FILE FINDINGS as gaps ('chump gap reserve') or A2A proposals \
('scripts/coord/broadcast.sh').
7. LAST, print EXACTLY this block to stdout (and nothing after it):
${BEGIN_MARK}
board: <one line: SLA breaches / armed-PR health>
trunk: <one line: green|red + dominant cause>
nodes: <one line: fleet health>
rollup: done=<int> total=<int>
findings: <one terse line: what you filed / unstuck, or 'clean tick'>
${END_MARK}

Read + rerun + rebase-behind + file-findings only. Never merge, never push \
code, never modify gap status beyond 'chump gap reserve'. If gh/cache access \
fails entirely, say so in the block rather than silently exiting."

# ── Tool allowlist IS the enforcement (AC4), not just the prompt. --permission-mode
# dontAsk default-denies everything NOT listed, so the absence of any merge /
# push / --admin / bypass entry is what forbids them. Keep this list read-only,
# rerun, rebase-behind, and file-findings — audited by scripts/ci/test-architect-tick.sh.
ARCH_ALLOWED_TOOLS=(
    'Bash(git log*)' 'Bash(git status*)' 'Bash(git diff*)' 'Bash(git fetch*)'
    'Bash(gh pr list*)' 'Bash(gh pr view*)' 'Bash(gh pr checks*)'
    'Bash(gh run list*)' 'Bash(gh run view*)' 'Bash(gh run rerun*)'
    'Bash(sqlite3*)' 'Bash(jq*)' 'Bash(cat*)' 'Bash(tail*)' 'Bash(head*)'
    'Bash(printf*)' 'Bash(echo*)'
    'Bash(chump gap list*)' 'Bash(chump gap show*)' 'Bash(chump gap reserve*)'
    'Bash(chump health*)' 'Bash(chump kpi*)'
    'Bash(scripts/coord/queue-tender-loop.sh*)'
    'Bash(scripts/coord/broadcast.sh*)'
)

# `claude -p --dangerously-skip-permissions` refuses to run as root unless
# IS_SANDBOX=1 (LINUX_NODE_ONBOARDING.md). This beat runs under a user-scope
# unit (never root on cuphead), but keep the sibling-beat guard for safety.
[[ "$(id -u)" == "0" ]] && export IS_SANDBOX=1

log "tick start (model=$MODEL timeout=${TIMEOUT_S}s free_disk=${_free_g}G)"
cycle_output=""
cycle_rc=0
CLAUDE_ARGS=(-p "$ARCH_PROMPT"
    --tools "Read,Grep,Glob,Bash"
    --allowedTools "${ARCH_ALLOWED_TOOLS[@]}"
    --disallowedTools "Edit,Write,NotebookEdit"
    --permission-mode dontAsk
    --max-budget-usd "$BUDGET_USD"
    --model "$MODEL")

if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
        cycle_output="$(timeout "${TIMEOUT_S}s" "$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" 2>&1)"
        cycle_rc=$?
    else
        cycle_output="$("$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" 2>&1)"
        cycle_rc=$?
    fi
else
    log "WARN: claude binary '$CLAUDE_BIN' not on PATH — recording a no-agent tick"
    cycle_rc=127
fi
printf '%s\n' "$cycle_output"

# ── Extract the structured block; fall back to a minimal report so AC2's files
# always exist even on agent failure/timeout. ────────────────────────────────
report_body="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {f=1; next} $0==e {f=0} f' <<< "$cycle_output")"
if [[ -z "${report_body// }" ]]; then
    report_body=$(printf 'board: (not measured — agent rc=%s)\ntrunk: unknown\nnodes: unknown\nrollup: done=-1 total=-1\nfindings: tick produced no structured report (rc=%s)\n' "$cycle_rc" "$cycle_rc")
fi

rollup_done="$(sed -n 's/.*rollup:.*done=\([0-9-]*\).*/\1/p' <<< "$report_body" | head -1)"
rollup_total="$(sed -n 's/.*rollup:.*total=\([0-9-]*\).*/\1/p' <<< "$report_body" | head -1)"
[[ -n "${rollup_done:-}" ]] || rollup_done=-1
[[ -n "${rollup_total:-}" ]] || rollup_total=-1
trunk_line="$(sed -n 's/^trunk:[[:space:]]*//p' <<< "$report_body" | head -1)"

{
    printf '# architect tick — %s\n\n' "$RUN_UTC"
    printf 'node: %s\n' "$(hostname -s 2>/dev/null || echo node)"
    printf 'agent_rc: %s\n\n' "$cycle_rc"
    printf '%s\n' "$report_body"
} > "$TICK_FILE" 2>/dev/null || log "WARN: could not write $TICK_FILE"
cp -f "$TICK_FILE" "$LATEST_MD" 2>/dev/null || log "WARN: could not update $LATEST_MD"

# ── Terminal emit (AC5): always fires, carries the rollup numbers. ───────────
printf '{"ts":"%s","kind":"architect_tick","node":"%s","outcome":"ran","agent_rc":%s,"rollup_done":%s,"rollup_total":%s,"trunk":"%s","tick_file":"%s"}\n' \
    "$(ts)" "$(hostname -s 2>/dev/null || echo node)" "$cycle_rc" "$rollup_done" "$rollup_total" \
    "${trunk_line//\"/}" "$TICK_FILE" \
    >> "$AMBIENT" 2>/dev/null || true

log "tick done (rc=$cycle_rc rollup=${rollup_done}/${rollup_total}) → $TICK_FILE"
exit 0
