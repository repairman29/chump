#!/usr/bin/env bash
# worker.sh — INFRA-203 / INFRA-211: per-agent worker loop.
#
# One instance per fleet pane. Loops until killed:
#   1. git fetch + (best-effort) rebase main into a fresh worktree
#   2. ask musher.py / chump gap list for the next pickable gap
#      (filters: priority, domain, effort)
#   3. claim it via gap-claim.sh (atomic flock)
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

AGENT_ID="${AGENT_ID:-?}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# INFRA-461: derive a unique per-worker session ID so leases written by this
# worker (or any chump/coord subprocess it invokes) DO NOT stomp the
# operator's interactive session via the .chump-locks/.wt-session-id
# fallback in the gap-claim.sh resolution chain. Workers run with
# cwd=$REPO_ROOT (the main worktree); without this export, gap-claim.sh
# picks up `.wt-session-id` and every fleet worker writes the lease under
# the operator's interactive session ID — observed live 2026-05-04 with
# multiple SWARM-* claims overwriting an active interactive INFRA-458
# lease.
#
# Session ID shape: fleet-<tmux-session>-agent<N>-<pid>-<epoch>. tmux
# session name is unique per fleet spawn; PID + epoch make sibling
# workers in the same fleet collision-free.
if [[ -z "${CHUMP_SESSION_ID:-}" ]]; then
    export CHUMP_SESSION_ID="fleet-${FLEET_SESSION:-fleet}-agent${AGENT_ID}-$$-$(date +%s)"
fi
FLEET_LOG_DIR="${FLEET_LOG_DIR:-/tmp/chump-fleet-default}"
FLEET_TIMEOUT_S="${FLEET_TIMEOUT_S:-1800}"
FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_AGENT_DOMAINS="${FLEET_AGENT_DOMAINS:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"
FLEET_BACKEND="${FLEET_BACKEND:-claude}"
FLEET_MODEL="${FLEET_MODEL:-haiku}"
IDLE_SLEEP_S="${IDLE_SLEEP_S:-60}"

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

# Per-worker counter of consecutive empty picks. Reset on every
# successful pick.
_starve_count=0

mkdir -p "$FLEET_LOG_DIR"

log() { printf '[worker:%s %s] %s\n' "$AGENT_ID" "$(date -u +%H:%M:%S)" "$*"; }

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

trap 'log "interrupted; exiting loop"; exit 0' INT TERM

# Hard rule from CLAUDE.md: never auto-pickup these — they need human judgment.
EXCLUDE_PREFIXES_REGEX='^(EVAL-|RESEARCH-|META-)'

cd "$REPO_ROOT"

# INFRA-333: heal any wedged-inode chump binary before we touch chump gap.
# Idempotent — fast no-op (probe < 5s) when binary is healthy. When the
# inode is wedged (INFRA-275 syspolicyd hang), the doctor moves it aside
# and replaces it with a fresh-inode copy, so the worker loop's `chump
# gap list` invocation below doesn't hang at _dyld_start. Failure is
# logged but non-fatal: the loop will surface the real problem on the
# first `chump gap` call if the heal didn't work.
"$REPO_ROOT/scripts/dev/chump-doctor.sh" >&2 || {
    log "WARN: chump-doctor failed; chump gap calls may hang"
}

cycle=0
while :; do
    cycle=$((cycle + 1))
    log "cycle $cycle: fetching origin/main"
    git fetch origin main --quiet || log "WARN: git fetch failed; continuing"

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
    # as gap-claim.sh so the lease is scoped to this worker's session.
    gap_json_file="$(mktemp -t fleet-gaps.XXXXXX)"
    printf '%s' "$gap_json" > "$gap_json_file"
    pick="$(FLEET_PRIORITY_FILTER="$FLEET_PRIORITY_FILTER" \
            FLEET_DOMAIN_FILTER="$FLEET_DOMAIN_FILTER" \
            FLEET_EFFORT_FILTER="$FLEET_EFFORT_FILTER" \
            FLEET_MODEL="$FLEET_MODEL" \
            EXCLUDE_RE="$EXCLUDE_PREFIXES_REGEX" \
            GAP_JSON_FILE="$gap_json_file" \
            WORKER_INDEX="$AGENT_ID" \
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
            printf '{"ts":"%s","session":"%s","worktree":"worker-%s","event":"fleet_starved","agent_id":"%s","consecutive_empty":%d,"filters":"prio=%s domain=%s effort=%s","suggest":"%s"}\n' \
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
        # INFRA-315: jittered sleep — randomize ±CHUMP_POLL_JITTER% around
        # IDLE_SLEEP_S. e.g. with default 60s + 30%: window 42-78s. Breaks
        # phase-lock between sibling workers so they don't all wake up at
        # the same instant to race the same gap. python3 (already a
        # dependency above) for the random arithmetic; awk fallback if not.
        _sleep_s="$(IDLE="$IDLE_SLEEP_S" JIT="$CHUMP_POLL_JITTER" python3 -c '
import os, random
idle = float(os.environ.get("IDLE", "60"))
jit  = float(os.environ.get("JIT",  "30")) / 100.0
delta = idle * jit
print(max(1.0, idle + random.uniform(-delta, +delta)))
' 2>/dev/null || echo "$IDLE_SLEEP_S")"
        log "no pickable gap (filters: prio=$FLEET_PRIORITY_FILTER domain=${FLEET_DOMAIN_FILTER:-any} effort=$FLEET_EFFORT_FILTER); sleeping ${_sleep_s}s (starve=$_starve_count)"
        sleep "$_sleep_s"
        continue
    fi

    GAP_ID="$pick"
    # INFRA-315: clear starvation counter on a successful pick. The next
    # empty cycle starts the threshold over from zero.
    _starve_count=0
    log "picked gap $GAP_ID"

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
        continue
    fi

    # ── Worktree ──────────────────────────────────────────────────────────
    sid="$(date +%Y%m%d-%H%M%S)"
    gap_lower="$(printf '%s' "$GAP_ID" | tr '[:upper:]' '[:lower:]')"
    wt_name="${gap_lower}-fleet-${AGENT_ID}-${sid}"
    wt_path="$REPO_ROOT/.claude/worktrees/$wt_name"
    branch="chump/${wt_name}"

    log "creating worktree $wt_path on branch $branch"
    if ! git -C "$REPO_ROOT" worktree add -b "$branch" "$wt_path" origin/main >/dev/null 2>&1; then
        # INFRA-271: don't sleep 30s on worktree-add failure — most failures
        # here are transient (sibling worker briefly held a git lock, or the
        # branch we picked happened to collide with a stale leftover). Skip
        # the cycle and pick a different gap on the next iteration.
        log "WARN: worktree create failed for $GAP_ID; trying next pick"
        continue
    fi

    # ── Claim (already done by atomic picker) ─────────────────────────────
    # INFRA-415: the atomic picker (_pick_and_claim_gap.py) already claimed
    # the gap atomically before returning the gap ID. The lease file is
    # already written in .chump-locks/<session>.json, so we skip the separate
    # gap-claim.sh call and proceed directly to spawning the agent.

    # ── Spawn agent (claude or chump-local) ───────────────────────────────
    cycle_log="$FLEET_LOG_DIR/agent-${AGENT_ID}-cycle${cycle}-${GAP_ID}.log"

    # Pick `timeout` (linux) or `gtimeout` (mac brew coreutils); fall back to none.
    if command -v timeout >/dev/null 2>&1; then
        TO="timeout ${FLEET_TIMEOUT_S}s"
    elif command -v gtimeout >/dev/null 2>&1; then
        TO="gtimeout ${FLEET_TIMEOUT_S}s"
    else
        TO=""
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
- Ship via:   scripts/coord/bot-merge.sh --gap ${GAP_ID} --auto-merge
  (this rebases, runs tests, pushes, opens PR, arms auto-merge,
  auto-closes the gap with --update-yaml)
- If bot-merge.sh hangs/dies: fall back to manual ship —
    git push -u origin <branch>
    gh pr create --base main --title \"...\" --body \"...\"
    chump gap ship ${GAP_ID} --closed-pr <PR#> --update-yaml
    git push (commit the close)
    gh pr merge <PR#> --auto --squash
- Never push directly to main. Never use git commit --no-verify.
- Mutate gaps via 'chump gap set' / 'chump gap ship' (state.db canonical post-INFRA-498).
- If you spot a real bug along the way, file it: 'chump gap reserve --domain INFRA --title \"...\"'

When done, reply with the PR number only (e.g. \"#1234\")."
            else
                prompt="Ship gap $GAP_ID in this repository. Read CLAUDE.md and AGENTS.md first. The gap is already claimed for this session; the lease is in .chump-locks/. Implement the gap per its description, commit via scripts/coord/chump-commit.sh, and ship via scripts/coord/bot-merge.sh --gap $GAP_ID --auto-merge. Reply with the PR number only."
            fi
            # INFRA-364: default to haiku for cost. Operator had \$92 of unused
            # workspace API credit while the squad burned the \$20/mo subscription
            # cap. Sonnet is ~10× haiku per token; for fleet's "ship a small
            # gap" workload haiku is plenty. Override via FLEET_MODEL=sonnet
            # for harder gaps. Empty string = let claude config default win
            # (back-compat).
            FLEET_MODEL="${FLEET_MODEL-haiku}"
            _model_arg=()
            [[ -n "$FLEET_MODEL" ]] && _model_arg=(--model "$FLEET_MODEL")
            log "spawning claude -p (timeout ${FLEET_TIMEOUT_S}s, backend=claude, model=${FLEET_MODEL:-default}) → $cycle_log"
            # INFRA-492: wire INFRA-477 session-track. Pre-fix the cost
            # ledger CLI existed but nothing emitted session_start /
            # session_end, so briefing's "historical median elapsed"
            # was always "no data." Best-effort — silent if chump
            # binary is missing.
            chump session-track --start "$GAP_ID" >/dev/null 2>&1 || true
            (
                cd "$wt_path" || exit 99
                # Same surface as src/dispatch.rs WorkBackend::Headless.
                # shellcheck disable=SC2086
                $TO claude -p "$prompt" --dangerously-skip-permissions "${_model_arg[@]}"
            ) >"$cycle_log" 2>&1
            rc=$?
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

    # INFRA-483: detect "0-byte cycle log" as a strong wedge signal —
    # claude -p produced no stdout for the entire FLEET_TIMEOUT_S
    # window. Distinct from "claude worked but timed out" (cycle_log
    # has content) and "claude exited cleanly" (rc=0). Treat as wasted
    # compute; apply EXTRA cooldown so workers don't infinitely retry
    # the same wedged gap.
    _cycle_log_size=0
    if [ -f "$cycle_log" ]; then
        _cycle_log_size=$(wc -c < "$cycle_log" 2>/dev/null | tr -d ' ' || echo 0)
    fi
    _is_wedge=0
    if [ "$rc" -eq 124 ] && [ "$_cycle_log_size" -lt 100 ]; then
        # 100-byte threshold — anything smaller is essentially "no work
        # done"; legitimate work logs are always thousands of bytes.
        _is_wedge=1
    fi

    if [ $rc -eq 0 ]; then
        log "$FLEET_BACKEND exited cleanly for $GAP_ID"
    elif [ $rc -eq 124 ]; then
        if [ "$_is_wedge" -eq 1 ]; then
            log "WARN: $FLEET_BACKEND WEDGED (rc=124, cycle_log=${_cycle_log_size}B) on $GAP_ID — applying extended cooldown"
        else
            log "WARN: $FLEET_BACKEND timed out (${FLEET_TIMEOUT_S}s, cycle_log=${_cycle_log_size}B) on $GAP_ID"
        fi
    else
        log "WARN: $FLEET_BACKEND exited rc=$rc on $GAP_ID"

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
                _fallback_prompt="Ship gap ${GAP_ID} (P0 fallback from chump-local rc=$rc). The gap is already claimed for this session; lease in .chump-locks/. Worktree: ${wt_path}. Pre-flight has already run. Run 'chump gap show ${GAP_ID}' for the gap spec (post-INFRA-498). Implement, commit via scripts/coord/chump-commit.sh, ship via scripts/coord/bot-merge.sh --gap ${GAP_ID} --auto-merge."
                FLEET_MODEL="${FLEET_MODEL-haiku}"
                _model_arg=()
                [[ -n "$FLEET_MODEL" ]] && _model_arg=(--model "$FLEET_MODEL")
                (
                    cd "$wt_path" || exit 99
                    # shellcheck disable=SC2086
                    $TO claude -p "$_fallback_prompt" --dangerously-skip-permissions "${_model_arg[@]}"
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
        if [ $rc -ne 0 ]; then
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
            cooldown_dir="$REPO_ROOT/.chump-locks/cooldown"
            mkdir -p "$cooldown_dir" 2>/dev/null || true
            cooldown_until=$(( $(date +%s) + cooldown_s ))
            printf '{"gap_id":"%s","rc":%d,"kind":"%s","until":%d,"agent":"%s","ts":"%s"}\n' \
                "$GAP_ID" "$rc" "$_cooldown_kind" "$cooldown_until" "$AGENT_ID" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                > "$cooldown_dir/${GAP_ID}.json" 2>/dev/null || true
            log "cooldown: $GAP_ID skipped for ${cooldown_s}s (kind=$_cooldown_kind, rc=$rc)"

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

    # INFRA-492: emit session_end with outcome BEFORE the lease release.
    # Outcome derivation: branch-gone (= PR landed) is shipped; rc==124
    # is starved-as-timeout (close enough for the existing taxonomy);
    # everything else is abandoned. Best-effort — silent on chump fail.
    _outcome="abandoned"
    if git -C "$REPO_ROOT" branch -vv 2>/dev/null | grep -E "$branch" | grep -q ': gone\]'; then
        _outcome="shipped"
    elif [ "$rc" -eq 124 ]; then
        _outcome="starved"
    fi
    chump session-track --end "$GAP_ID" --outcome "$_outcome" >/dev/null 2>&1 || true

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
