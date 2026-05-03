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
#   FLEET_BACKEND           (default chump-local) "chump-local" runs each
#                           gap via `chump --execute-gap` so calls fan out
#                           through src/provider_cascade.rs (free tiers).
#                           "claude" preserves the original AUTO-013 path
#                           (`claude -p` with Anthropic API). Use claude
#                           for tasks the cascade can't carry yet.
#   CARGO_TARGET_DIR        recommended: shared target across worktrees
#                           (see INFRA-210 — exported below if unset)
#
# Stop:
#   tmux kill-session -t <FLEET_SESSION>
#   or: FLEET_SIZE=0 scripts/dispatch/run-fleet.sh
#   or: Ctrl-C inside any pane (only kills that one agent's loop)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts/dispatch"

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
FLEET_DRY_RUN="${FLEET_DRY_RUN:-0}"
FLEET_BACKEND="${FLEET_BACKEND:-chump-local}"
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
if [ -z "${CARGO_TARGET_DIR:-}" ]; then
    export CARGO_TARGET_DIR="$REPO_ROOT/target"
fi

# Tear-down-only path: FLEET_SIZE=0 means "stop the fleet, don't spawn".
if [ "$FLEET_SIZE" = "0" ]; then
    if tmux has-session -t "$FLEET_SESSION" 2>/dev/null; then
        echo "[run-fleet] tearing down tmux session: $FLEET_SESSION"
        tmux kill-session -t "$FLEET_SESSION"
    else
        echo "[run-fleet] no session named $FLEET_SESSION; nothing to do."
    fi
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
worker_env=(
    "REPO_ROOT=$REPO_ROOT"
    "FLEET_LOG_DIR=$FLEET_LOG_DIR"
    "FLEET_TIMEOUT_S=$FLEET_TIMEOUT_S"
    "FLEET_PRIORITY_FILTER=$FLEET_PRIORITY_FILTER"
    "FLEET_DOMAIN_FILTER=$FLEET_DOMAIN_FILTER"
    "FLEET_AGENT_DOMAINS=$FLEET_AGENT_DOMAINS"
    "FLEET_EFFORT_FILTER=$FLEET_EFFORT_FILTER"
    "FLEET_BACKEND=$FLEET_BACKEND"
    "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"
    # INFRA-371 token-burn defaults
    "FLEET_INLINE_BRIEFING=$FLEET_INLINE_BRIEFING"
    "CHUMP_LESSONS_AT_SPAWN_N=$CHUMP_LESSONS_AT_SPAWN_N"
    "CHUMP_AMBIENT_INSTALL_SKIP=$CHUMP_AMBIENT_INSTALL_SKIP"
)
env_prefix="$(printf '%s ' "${worker_env[@]}")"

# Pane 0 is the control pane (status dashboard). Agents start at index 1.
tmux new-session -d -s "$FLEET_SESSION" -n fleet -c "$REPO_ROOT" \
    "${env_prefix} FLEET_SESSION=$FLEET_SESSION FLEET_SIZE=$FLEET_SIZE $SCRIPT_DIR/control.sh"

for i in $(seq 1 "$FLEET_SIZE"); do
    log="$FLEET_LOG_DIR/agent-${i}.log"
    cmd="${env_prefix} AGENT_ID=$i $SCRIPT_DIR/worker.sh 2>&1 | tee -a '$log'"
    tmux split-window -t "$FLEET_SESSION:fleet" -c "$REPO_ROOT" "$cmd"
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
