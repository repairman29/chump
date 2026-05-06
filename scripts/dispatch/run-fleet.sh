#!/usr/bin/env bash
# run-fleet.sh — INFRA-203 / INFRA-211: canonical fleet launcher.
#
# Spawns N tmux panes, one per Claude Code agent, plus a control pane that
# tails ambient.jsonl, the PR queue, and per-agent activity. Each agent runs
# `worker.sh` which loops: pick highest-priority unclaimed gap → claim →
# create worktree → spawn `claude -p` (the same surface as
# WorkBackend::Headless from src/dispatch.rs, INFRA-191 Phase 2) → ship via
# bot-merge.sh → release → loop.
#
# Usage:
#   scripts/dispatch/run-fleet.sh                  # default FLEET_SIZE=8
#   FLEET_SIZE=4 scripts/dispatch/run-fleet.sh
#   FLEET_DOMAIN_FILTER=INFRA scripts/dispatch/run-fleet.sh
#   FLEET_SIZE=0 scripts/dispatch/run-fleet.sh     # tear down only
#
# Env knobs:
#   FLEET_SIZE              (default 8)   number of agent panes; 0 = stop only
#   FLEET_TIMEOUT_S         (default 1800) per-agent claude -p timeout
#   FLEET_PRIORITY_FILTER   (default "P0,P1") comma-separated priorities
#   FLEET_DOMAIN_FILTER     (default "")  e.g. "INFRA" or "INFRA,DOC"; "" = all
#   FLEET_AGENT_DOMAINS     (default "")  comma-separated domain list; agent K
#                           is assigned domains[(K-1) % N]. E.g. "INFRA,EVAL,DOC"
#                           makes agent-1=INFRA, agent-2=EVAL, agent-3=DOC (wraps
#                           round-robin). Overrides FLEET_DOMAIN_FILTER per-agent.
#                           "" = all agents use the fleet-wide FLEET_DOMAIN_FILTER.
#                           (INFRA-206)
#   FLEET_EFFORT_FILTER     (default "xs,s,m") comma-separated efforts
#   FLEET_SESSION           (default "chump-fleet") tmux session name
#   FLEET_LOG_DIR           (default /tmp/chump-fleet-<sid>) per-agent logs
#   FLEET_DRY_RUN           (default 0)   if 1, print plan and exit
#   FLEET_BACKEND           (default claude) "claude" runs each gap via
#                           `claude -p` with Anthropic API (AUTO-013 path).
#                           "chump-local" fans calls through
#                           src/provider_cascade.rs (free tiers) — requires
#                           CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1 (INFRA-459:
#                           cascade bank too small for dev workload 2026-05-04).
#   FLEET_MODEL             (default haiku) model passed to claude -p. Use
#                           sonnet/opus for harder gaps.
#   CARGO_TARGET_DIR        recommended: shared target across worktrees
#                           (see INFRA-210 — exported below if unset)
#
# Stop:
#   FLEET_SIZE=0 scripts/dispatch/run-fleet.sh   ← preferred (cascade-kills orphans, INFRA-581)
#   tmux kill-session -t <FLEET_SESSION>          ← safe: orphan-reaper sentinel fires (INFRA-602)
#   or: Ctrl-C inside any pane (only kills that one agent's loop)
#
# INFRA-602: a sentinel watcher process (outside tmux) is spawned at fleet start.
# It polls `tmux has-session` every 3s; when the fleet session disappears for any
# reason it runs: pkill -f "timeout [0-9]*s claude -p "
# If you bypass tmux entirely (e.g. SIGKILL on the tmux server), follow with:
#   pkill -f "timeout [0-9]*s claude -p "
#
# INFRA-581: tmux kill-session kills the pane shell + worker.sh but
# already-spawned `timeout Ns claude -p ...` grandchildren may have
# setsid'd and survive as PPID=1 orphans consuming compute + racing new
# fleet picks. FLEET_SIZE=0 teardown reads ~/.chump/fleet-pids-<session>.txt
# (written at spawn) to cascade-kill worker subtrees; then pkill finishes
# off any survivors. If you must use raw `tmux kill-session`, follow with:
#   pkill -f "timeout [0-9]*s claude -p "

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts/dispatch"
# INFRA-469: route every `chump` invocation through the wedge-heal shim.
export PATH="$REPO_ROOT/bin:$PATH"

# INFRA-351: source $REPO_ROOT/.env (if present) so spawned worker panes
# inherit ANTHROPIC_API_KEY / OPENAI_API_KEY / TOGETHER_API_KEY etc. and
# `claude -p` consumes workspace API credit instead of falling back to
# the launcher's claude.ai subscription cap. Caught 2026-05-02 22:27:
# Jeff had $92.71 unused workspace credit while the squad burned the
# $20 monthly subscription cap. Bypass: CHUMP_FLEET_NOENV=1.
if [[ -f "$REPO_ROOT/.env" && "${CHUMP_FLEET_NOENV:-0}" != "1" ]]; then
    # set -a auto-exports every assignment; matches the standard "source .env"
    # idiom used in tools like docker-compose. set +a restores prior behavior.
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
    echo "[run-fleet] sourced $REPO_ROOT/.env (INFRA-351) — set CHUMP_FLEET_NOENV=1 to skip"
fi

FLEET_SIZE="${FLEET_SIZE:-8}"
# INFRA-371: timeout default lowered 1800→600. Most INFRA gaps that ship
# do so in 5–10min on hot cargo cache; the rest are usually wedged
# (claude churning) and just burn tokens until the kill. Raise via
# FLEET_TIMEOUT_S=1800 for substantive work or harder gaps.
FLEET_TIMEOUT_S="${FLEET_TIMEOUT_S:-600}"
FLEET_PRIORITY_FILTER="${FLEET_PRIORITY_FILTER:-P0,P1}"
FLEET_DOMAIN_FILTER="${FLEET_DOMAIN_FILTER:-}"
FLEET_AGENT_DOMAINS="${FLEET_AGENT_DOMAINS:-}"
FLEET_EFFORT_FILTER="${FLEET_EFFORT_FILTER:-xs,s,m}"
FLEET_SESSION="${FLEET_SESSION:-chump-fleet}"
# INFRA-581: per-session PID file so teardown can cascade-kill orphaned workers.
FLEET_PIDS_FILE="${FLEET_PIDS_FILE:-$HOME/.chump/fleet-pids-${FLEET_SESSION}.txt}"
FLEET_DRY_RUN="${FLEET_DRY_RUN:-0}"
FLEET_BACKEND="${FLEET_BACKEND:-claude}"
# INFRA-459: default model is haiku — cost-efficient for xs/s/m fleet gaps.
# Override via FLEET_MODEL=sonnet for harder tasks.
FLEET_MODEL="${FLEET_MODEL:-sonnet}"
# INFRA-371: token-burn defaults applied to every fleet worker unless
# the caller overrides. These cut per-spawn token cost without losing
# capability — workers can still re-enable for harder workloads.
#   FLEET_INLINE_BRIEFING=1   inline gap YAML in prompt instead of
#                              forcing claude to read CLAUDE.md/AGENTS.md
#   CHUMP_LESSONS_AT_SPAWN_N=0 disable lessons block prepend at every
#                              prompt assembly (default OFF in COG-024
#                              but defensive here for any inherited env)
#   CHUMP_AMBIENT_INSTALL_SKIP=1 skip the install-ambient-hooks idempotent
#                              re-run on every session start (~500 tokens
#                              of bash output saved per cycle)
export FLEET_INLINE_BRIEFING="${FLEET_INLINE_BRIEFING:-1}"
export CHUMP_LESSONS_AT_SPAWN_N="${CHUMP_LESSONS_AT_SPAWN_N:-0}"
export CHUMP_AMBIENT_INSTALL_SKIP="${CHUMP_AMBIENT_INSTALL_SKIP:-1}"

# INFRA-459: inverted cost-guard (was INFRA-420). Default is now claude+haiku.
# chump-local (cascade) is blocked unless the operator explicitly opts in —
# the free-tier cascade bank was too small for dev workload (2026-05-04) and
# attempts silently stall instead of failing loud. Use claude (haiku) instead.
if [[ "$FLEET_BACKEND" == "chump-local" \
        && "${CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND:-0}" != "1" ]]; then
    echo "[run-fleet] REFUSING to start fleet on backend=chump-local" >&2
    echo "[run-fleet]   cascade bank is too small for dev workload (INFRA-459," >&2
    echo "[run-fleet]   2026-05-04); calls stall silently instead of failing." >&2
    echo "[run-fleet]   To override:    CHUMP_FLEET_ALLOW_CHUMP_LOCAL_BACKEND=1 $0" >&2
    echo "[run-fleet]   Recommended:    unset FLEET_BACKEND  (defaults to claude+haiku)" >&2
    exit 2
fi

case "$FLEET_BACKEND" in
    claude|chump-local) ;;
    *)
        echo "[run-fleet] ERROR: FLEET_BACKEND must be 'claude' or 'chump-local' (got: $FLEET_BACKEND)" >&2
        exit 2
        ;;
esac

SID="$(date +%Y%m%d-%H%M%S)-$$"
FLEET_LOG_DIR="${FLEET_LOG_DIR:-/tmp/chump-fleet-${SID}}"

# INFRA-210: every worktree compiling its own target/ is the #1 disk hog.
# Default to a shared target dir unless the caller explicitly set their own.
# INFRA-535: when the fleet is launched from a /tmp/ clone (common pattern
# for fleet worktrees), $REPO_ROOT/target fills /tmp/ and causes disk-full.
# Redirect to ~/.cache/chump-fleet-target/ instead — outside /tmp/ — so
# the shared cache survives across sessions and doesn't blow the ramdisk.
if [ -z "${CARGO_TARGET_DIR:-}" ]; then
    if [[ "$REPO_ROOT" == /tmp/* || "$REPO_ROOT" == /private/tmp/* ]]; then
        export CARGO_TARGET_DIR="$HOME/.cache/chump-fleet-target"
    else
        export CARGO_TARGET_DIR="$REPO_ROOT/target"
    fi
fi

# Tear-down-only path: FLEET_SIZE=0 means "stop the fleet, don't spawn".
if [ "$FLEET_SIZE" = "0" ]; then
    # INFRA-581: cascade-kill pane subtrees BEFORE tmux kill-session so
    # worker.sh → timeout → claude children receive SIGTERM while still
    # reachable via the pane shell's process group. Post-session pkill
    # catches any that already setsid'd (PPID=1 orphans).
    if [[ -f "$FLEET_PIDS_FILE" ]]; then
        echo "[run-fleet] cascade-killing fleet worker subtrees (INFRA-581): $FLEET_PIDS_FILE"
        while IFS= read -r _pid; do
            [[ "$_pid" =~ ^[0-9]+$ ]] || continue
            # Try process-group kill first (tmux panes typically get their own pgid).
            kill -TERM "-${_pid}" 2>/dev/null || true
            # Also kill direct children in case pgid differs.
            pkill -TERM -P "$_pid" 2>/dev/null || true
            kill -TERM "$_pid" 2>/dev/null || true
        done < "$FLEET_PIDS_FILE"
        rm -f "$FLEET_PIDS_FILE"
    fi
    if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
        echo "[run-fleet] tearing down tmux session: $FLEET_SESSION"
        tmux kill-session -t "$FLEET_SESSION"
    else
        echo "[run-fleet] no session named $FLEET_SESSION; nothing to do."
    fi
    # Belt-and-suspenders: pkill any timeout+claude orphans that setsid'd
    # before the SIGTERM above reached them (INFRA-581).
    pkill -f "timeout [0-9]*s claude -p " 2>/dev/null || true
    exit 0
fi

# Sanity checks before we open tmux.
if ! command -v tmux >/dev/null 2>&1; then
    echo "[run-fleet] ERROR: tmux not on PATH (brew install tmux)" >&2
    exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "[run-fleet] ERROR: claude CLI not on PATH" >&2
    exit 1
fi
if [ ! -x "$SCRIPT_DIR/worker.sh" ]; then
    echo "[run-fleet] ERROR: $SCRIPT_DIR/worker.sh not executable" >&2
    exit 1
fi
if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
    echo "[run-fleet] ERROR: tmux session '$FLEET_SESSION' already exists." >&2
    echo "  Stop it first:  tmux kill-session -t $FLEET_SESSION" >&2
    echo "  Or attach:      tmux attach -t $FLEET_SESSION" >&2
    exit 2
fi

mkdir -p "$FLEET_LOG_DIR"

# INFRA-519: reap stale fleet-* leases before spawning new panes.
# tmux-kill bypasses worker.sh exit-cleanup, leaving orphaned lease files whose
# PIDs are no longer alive. Stale leases block the picker (treated as live
# within TTL), starving a fresh fleet of pickable gaps.
# session_id format: fleet-<FLEET_SESSION>-agent<N>-<PID>-<epoch>
# PID is the second-to-last dash-separated field — safe even if FLEET_SESSION
# contains dashes because the trailing <PID>-<epoch> suffix is always numeric.
_stale_reaped=0
for _lease in "$REPO_ROOT/.chump-locks"/fleet-*.json; do
    [[ -f "$_lease" ]] || continue
    _sid="$(basename "$_lease" .json)"
    _pid="$(printf '%s' "$_sid" | rev | cut -d- -f2 | rev)"
    if [[ "$_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_pid" 2>/dev/null; then
        echo "[run-fleet] reaping stale lease (pid $_pid dead): $(basename "$_lease")"
        rm -f "$_lease"
        (( _stale_reaped++ )) || true
    fi
done
if (( _stale_reaped > 0 )); then
    echo "[run-fleet] reaped $_stale_reaped stale fleet lease(s) — picker unblocked"
fi

# INFRA-465: seed state.db before spawning workers so fresh worktrees have
# pickable gaps. Compare state.db open-gap count against origin/main's
# state.sql line count as a cheap drift signal; run 'chump gap import' if
# state.db appears empty or behind. chump gap import is idempotent (skips
# already-present rows) so running it on an up-to-date db is safe.
_db="$REPO_ROOT/.chump/state.db"
_db_open=0
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db" ]]; then
    _db_open=$(sqlite3 "$_db" "SELECT COUNT(*) FROM gaps WHERE status='open';" 2>/dev/null || echo 0)
fi
# Count open gaps visible on origin/main via the tracked state.sql mirror.
_sql_open=$(git show "origin/main:.chump/state.sql" 2>/dev/null \
    | grep -c "^INSERT.*'open'" 2>/dev/null || echo 0)
if (( _db_open < _sql_open )); then
    echo "[run-fleet] INFRA-465: state.db has $_db_open open gaps, origin/main has $_sql_open — running 'chump gap import'"
    (cd "$REPO_ROOT" && chump gap import) \
        && echo "[run-fleet] gap import complete — state.db seeded" \
        || echo "[run-fleet] WARNING: 'chump gap import' failed; workers may see no pickable gaps"
else
    echo "[run-fleet] state.db looks current ($_db_open open gaps) — skipping import"
fi

cat <<EOF
[run-fleet] starting fleet
  session       : $FLEET_SESSION
  size          : $FLEET_SIZE
  timeout/agent : ${FLEET_TIMEOUT_S}s
  priority      : $FLEET_PRIORITY_FILTER
  domain        : ${FLEET_DOMAIN_FILTER:-<any>}
  agent-domains : ${FLEET_AGENT_DOMAINS:-<uniform>}
  effort        : $FLEET_EFFORT_FILTER
  log dir       : $FLEET_LOG_DIR
  backend       : $FLEET_BACKEND
  CARGO_TARGET_DIR : $CARGO_TARGET_DIR
EOF

if [ "$FLEET_DRY_RUN" = "1" ]; then
    echo "[run-fleet] FLEET_DRY_RUN=1 — exiting before tmux."
    exit 0
fi

# Build the worker env once; passed into every pane via the launch command.
# INFRA-417: API keys must be in this list explicitly. INFRA-351 sources
# .env into the launcher process, but `tmux split-window` runs the new
# pane under the long-lived tmux server (not the launcher) — exported
# vars in the launcher do NOT propagate. Without these lines, claude -p
# in the worker pane falls back to the user's claude.ai subscription
# cap instead of consuming workspace API credit, the exact failure mode
# INFRA-351 set out to fix.
worker_env=(
    "REPO_ROOT=$REPO_ROOT"
    "FLEET_LOG_DIR=$FLEET_LOG_DIR"
    "FLEET_TIMEOUT_S=$FLEET_TIMEOUT_S"
    "FLEET_PRIORITY_FILTER=$FLEET_PRIORITY_FILTER"
    "FLEET_DOMAIN_FILTER=$FLEET_DOMAIN_FILTER"
    "FLEET_AGENT_DOMAINS=$FLEET_AGENT_DOMAINS"
    "FLEET_EFFORT_FILTER=$FLEET_EFFORT_FILTER"
    "FLEET_BACKEND=$FLEET_BACKEND"
    "FLEET_MODEL=${FLEET_MODEL:-}"
    # INFRA-461: pass FLEET_SESSION so worker.sh can build a unique
    # CHUMP_SESSION_ID per pane and not stomp the operator's interactive
    # lease via the .wt-session-id fallback.
    "FLEET_SESSION=$FLEET_SESSION"
    "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"
    # INFRA-371 token-burn defaults
    "FLEET_INLINE_BRIEFING=$FLEET_INLINE_BRIEFING"
    "CHUMP_LESSONS_AT_SPAWN_N=$CHUMP_LESSONS_AT_SPAWN_N"
    "CHUMP_AMBIENT_INSTALL_SKIP=$CHUMP_AMBIENT_INSTALL_SKIP"
    # INFRA-417 API keys — only added when actually set in the launcher
    # env (so we don't pollute panes with empty values that would mask a
    # legitimately-set system-level key).
    ${ANTHROPIC_API_KEY:+"ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"}
    ${OPENAI_API_KEY:+"OPENAI_API_KEY=$OPENAI_API_KEY"}
    ${TOGETHER_API_KEY:+"TOGETHER_API_KEY=$TOGETHER_API_KEY"}
    ${GROQ_API_KEY:+"GROQ_API_KEY=$GROQ_API_KEY"}
    ${MISTRAL_API_KEY:+"MISTRAL_API_KEY=$MISTRAL_API_KEY"}
    ${FIREWORKS_API_KEY:+"FIREWORKS_API_KEY=$FIREWORKS_API_KEY"}
)
env_prefix="$(printf '%s ' "${worker_env[@]}")"

# Pane 0 is the control pane (status dashboard). Agents start at index 1.
tmux new-session -d -s "$FLEET_SESSION" -n fleet -c "$REPO_ROOT" \
    "${env_prefix} FLEET_SESSION=$FLEET_SESSION FLEET_SIZE=$FLEET_SIZE $SCRIPT_DIR/control.sh"

mkdir -p "$(dirname "$FLEET_PIDS_FILE")"
# Truncate any stale pids file from a prior run of the same session name.
: > "$FLEET_PIDS_FILE"

# INFRA-602: orphan-reaper sentinel. Runs outside tmux; polls until the fleet
# session disappears (for ANY reason — kill-session, server crash, Ctrl-C), then
# pkills any surviving timeout+claude workers. Covers the path FLEET_SIZE=0
# teardown misses: a raw `tmux kill-session` by the operator.
(
    while tmux has-session -t "$FLEET_SESSION" 2>/dev/null; do
        sleep 3
    done
    pkill -f "timeout [0-9]*s claude -p " 2>/dev/null || true
) &
_sentinel_pid=$!
echo "$_sentinel_pid" >> "$FLEET_PIDS_FILE"

for i in $(seq 1 "$FLEET_SIZE"); do
    log="$FLEET_LOG_DIR/agent-${i}.log"
    cmd="${env_prefix} AGENT_ID=$i $SCRIPT_DIR/worker.sh 2>&1 | tee -a '$log'"
    tmux split-window -t "$FLEET_SESSION:fleet" -c "$REPO_ROOT" "$cmd"
    # INFRA-581: capture the newly-created pane's shell PID so teardown can
    # cascade-kill worker.sh → timeout → claude subtrees on FLEET_SIZE=0.
    _pane_pid="$(tmux display-message -t "$FLEET_SESSION:fleet" -p '#{pane_pid}' 2>/dev/null || true)"
    [[ "$_pane_pid" =~ ^[0-9]+$ ]] && echo "$_pane_pid" >> "$FLEET_PIDS_FILE"
    tmux select-layout -t "$FLEET_SESSION:fleet" tiled >/dev/null
done

tmux select-layout -t "$FLEET_SESSION:fleet" tiled >/dev/null
tmux select-pane -t "$FLEET_SESSION:fleet.0"

cat <<EOF
[run-fleet] fleet up.
  attach :  tmux attach -t $FLEET_SESSION
  stop   :  tmux kill-session -t $FLEET_SESSION
  logs   :  tail -f $FLEET_LOG_DIR/agent-*.log
EOF
