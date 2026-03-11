#!/usr/bin/env bash
# Self-improve heartbeat: run Chump in work rounds for a set duration.
# Each round gives Chump a dynamic prompt: check task queue → find work → do it → report.
# Unlike heartbeat-learn.sh (static web-search prompts), this drives real codebase work.
#
# Requires: model server on 8000 or 8001. TAVILY_API_KEY optional (for research fallback).
# For reliable runs, build first: cargo build --release
#
# Usage:
#   ./scripts/heartbeat-self-improve.sh                           # 8h, round every 45 min
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=30m ./scripts/heartbeat-self-improve.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-self-improve.sh    # 2m, 30s interval
#   HEARTBEAT_RETRY=1 ./scripts/heartbeat-self-improve.sh         # retry once per round
#   HEARTBEAT_DRY_RUN=1 ./scripts/heartbeat-self-improve.sh       # skip git push / gh pr create
#
# Logs: logs/heartbeat-self-improve.log (append).
# Safety: Chump works on chump/* branches; PRs require human merge.
#         Set DRY_RUN=1 to skip push/PR creation entirely.
#         Kill switch: touch logs/pause or CHUMP_PAUSED=1.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

export OPENAI_API_BASE="${OPENAI_API_BASE:-http://localhost:8000/v1}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-default}"

# Pass DRY_RUN through so Chump's prompt knows not to push
export DRY_RUN="${HEARTBEAT_DRY_RUN:-${DRY_RUN:-0}}"

# Quick test: short duration
if [[ -n "${HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-30s}"
else
  DURATION="${HEARTBEAT_DURATION:-8h}"
  INTERVAL="${HEARTBEAT_INTERVAL:-45m}"
fi

duration_sec() {
  local v=$1
  if [[ "$v" =~ ^([0-9]+)h$ ]]; then
    echo $((${BASH_REMATCH[1]} * 3600))
  elif [[ "$v" =~ ^([0-9]+)m$ ]]; then
    echo $((${BASH_REMATCH[1]} * 60))
  elif [[ "$v" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 3600
  fi
}
DURATION_SEC=$(duration_sec "$DURATION")
INTERVAL_SEC=$(duration_sec "$INTERVAL")

mkdir -p "$ROOT/logs"
LOG="$ROOT/logs/heartbeat-self-improve.log"

# --- Preflight: find a model server (same logic as heartbeat-learn.sh) ---
model_ready() {
  local port=$1
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${port}/v1/models" 2>/dev/null || true
}

CHOSEN_PORT=""
if [[ "$(model_ready 8000)" == "200" ]]; then
  CHOSEN_PORT=8000
  export OPENAI_API_BASE="http://localhost:8000/v1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: port 8000 ready." >> "$LOG"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: 8000 down, attempting warm..." >> "$LOG"
  if [[ -x "$ROOT/scripts/warm-the-ovens.sh" ]]; then
    "$ROOT/scripts/warm-the-ovens.sh" >> "$LOG" 2>&1 || true
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 5
    if [[ "$(model_ready 8000)" == "200" ]]; then
      CHOSEN_PORT=8000
      export OPENAI_API_BASE="http://localhost:8000/v1"
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: port 8000 ready after warm." >> "$LOG"
      break
    fi
  done
  if [[ -z "$CHOSEN_PORT" ]] && [[ "$(model_ready 8001)" == "200" ]]; then
    CHOSEN_PORT=8001
    export OPENAI_API_BASE="http://localhost:8001/v1"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: using fallback port 8001." >> "$LOG"
  fi
fi

if [[ -z "$CHOSEN_PORT" ]]; then
  echo "No model server on 8000 or 8001." >&2
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: no server." >> "$LOG"
  exit 1
fi

# --- The self-improve prompt ---
# This is ONE prompt per round. Chump has all the tools; the prompt tells him the workflow.
# The prompt alternates between "work the queue" and "find opportunities" rounds.

WORK_PROMPT='This is a self-improve round. You are working autonomously. Follow this workflow:

1. START: Read your ego state (ego read_all). Check your task queue (task list — no status filter to see open, in_progress, and blocked).

2. PICK WORK:
   - If there are in_progress tasks: resume the first one.
   - If there are open tasks: pick the highest-priority one (lowest id), set it to in_progress.
   - If there are blocked tasks: re-evaluate whether the blocker is resolved; if so, set to in_progress.
   - If the queue is empty: skip to step 3 (opportunity mode).

3. IF NO TASKS (opportunity mode): Find something useful to do. Options:
   a. Read docs/CHUMP_PROJECT_BRIEF.md — check "Current focus" for unchecked items.
   b. Run: run_cli "grep -rn TODO src/ --include=\"*.rs\" | head -20" — find TODOs to fix.
   c. Run: run_cli "cargo test 2>&1 | tail -30" — check if any tests are failing.
   d. Read a source file you have not explored and look for improvements (missing error handling, dead code, missing docs).
   e. If you find something worth doing, create a task for it (task create), then work on it.

4. DO THE WORK:
   - Use read_file / list_dir to understand the relevant code.
   - Use edit_file (preferred) or write_file to make changes. edit_file is safer (exact string match).
   - After changes, ALWAYS run: run_cli "cargo test 2>&1 | tail -40" to verify.
   - If tests fail, diagnose and fix. Up to 3 attempts, then set task to blocked with notes.

5. COMMIT (if DRY_RUN is not set and you made successful changes):
   - run_cli "git diff --stat" to see what changed.
   - git_commit with a clear message (reference task id if applicable).
   - Only push to a chump/* branch. If not on one, create it: gh_create_branch "chump/task-{id}-{short-desc}"
   - git_push to the branch. Do NOT push to main directly.
   - Optionally: gh_create_pr with a clear title and body.

6. WRAP UP:
   - Update the task status: done (if complete), blocked (if stuck), or in_progress (if partially done with notes on what is left).
   - Log an episode: episode log with a summary of what you did, tags, and sentiment (win/loss/blocked).
   - Update your ego state: write current_focus, recent_wins (if applicable), frustrations (if stuck).
   - If you accomplished something or got blocked: notify the owner with a short summary.

SAFETY RULES:
- Never push to main. Always use chump/* branches.
- Always run cargo test before committing.
- If DRY_RUN=1 is set, skip git push and gh_create_pr — just log what you would have done.
- If unsure about a change, set the task to blocked and notify rather than guessing.
- Max 1 meaningful change per round. Do not try to do everything at once.
- Be concise in your tool calls and reasoning.'

OPPORTUNITY_PROMPT='This is a self-improve round focused on finding opportunities. You are working autonomously.

1. START: Read your ego state (ego read_all). Check your task queue (task list).

2. SCAN FOR OPPORTUNITIES (do at least 2 of these):
   a. run_cli "grep -rn TODO src/ --include=\"*.rs\" | head -15" — find TODOs worth fixing.
   b. run_cli "grep -rn unwrap src/ --include=\"*.rs\" | grep -v test | grep -v \"// ok\" | head -15" — find unwrap() calls that could panic.
   c. run_cli "cargo clippy 2>&1 | head -30" — find lint warnings.
   d. Read docs/CHUMP_PROJECT_BRIEF.md and one roadmap doc — find unchecked items.
   e. list_dir "src" and read_file on a module you have not explored — look for missing tests, error handling, or dead code.
   f. run_cli "cargo test 2>&1 | tail -20" — check for failing tests.

3. CREATE TASKS: For each real opportunity found (not trivial), create a task:
   task create with a clear title like "Fix unwrap in memory_tool fallback path" or "Add unit test for delegate_tool timeout".
   Limit: create at most 3 new tasks per round so the queue does not grow uncontrollably.

4. WORK ON ONE: Pick the most impactful new task (or an existing open one) and do it. Follow the same work + test + commit flow as a normal self-improve round.

5. WRAP UP: Update task status, log an episode, update ego, notify if notable.

SAFETY: Same rules — chump/* branches only, cargo test before commit, max 1 change, DRY_RUN respected.'

RESEARCH_PROMPT='This is a self-improve round focused on learning. You are working autonomously.

1. START: Read your ego state (ego read_all). Check what you have been working on recently (episode recent, limit 3).

2. RESEARCH: Pick a topic relevant to your current work or the Chump codebase. Use web_search with 1–2 focused queries. Good topics:
   - Something related to a recent task or blocker.
   - A Rust pattern or library you encountered in the codebase.
   - Best practices for something Chump does (Discord bots, SQLite, FTS5, WASM, tool-using agents).

3. STORE: Save 3–5 concise, actionable learnings in memory. Tag them so recall surfaces them when relevant.

4. APPLY (optional): If a learning directly suggests an improvement to the codebase, create a task for it.

5. WRAP UP: Log an episode (summary of what you learned), update ego (curiosities, recent_wins).'

# Round types cycle: work, work, opportunity, work, work, research
ROUND_TYPES=(work work opportunity work work research)

start_ts=$(date +%s)
round=0

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat started: duration=$DURATION, interval=$INTERVAL, dry_run=$DRY_RUN" >> "$LOG"

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  # Kill switch
  if [[ -f "$ROOT/logs/pause" ]] || [[ "${CHUMP_PAUSED:-0}" == "1" ]] || [[ "${CHUMP_PAUSED:-}" == "true" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (paused)" >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  round=$((round + 1))
  idx=$(( (round - 1) % ${#ROUND_TYPES[@]} ))
  round_type="${ROUND_TYPES[$idx]}"

  case "$round_type" in
    work)        prompt="$WORK_PROMPT" ;;
    opportunity) prompt="$OPPORTUNITY_PROMPT" ;;
    research)    prompt="$RESEARCH_PROMPT" ;;
    *)           prompt="$WORK_PROMPT" ;;
  esac

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): starting" >> "$LOG"
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    RUN_CMD=("$ROOT/target/release/rust-agent" --chump "$prompt")
  else
    RUN_CMD=(./run-best.sh --chump "$prompt")
  fi
  if "${RUN_CMD[@]}" >> "$LOG" 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): ok" >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): exit non-zero" >> "$LOG"
    if [[ -n "${HEARTBEAT_RETRY:-}" ]]; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: retry" >> "$LOG"
      if "${RUN_CMD[@]}" >> "$LOG" 2>&1; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: ok (after retry)" >> "$LOG"
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: retry failed" >> "$LOG"
      fi
    fi
  fi

  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping $INTERVAL until next round..." >> "$LOG"
  sleep "$INTERVAL_SEC"
done

echo "Self-improve heartbeat done. Log: $LOG"
