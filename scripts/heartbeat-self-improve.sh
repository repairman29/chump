#!/usr/bin/env bash
# Self-improve heartbeat: run Chump in work rounds for a set duration.
# Each round gives Chump a dynamic prompt: check task queue → find work → do it → report.
# Unlike heartbeat-learn.sh (static web-search prompts), this drives real codebase work.
#
# Requires: Ollama on 11434 (default). TAVILY_API_KEY optional (for research fallback).
# For reliable runs, build first: cargo build --release
#
# Usage:
#   ./scripts/heartbeat-self-improve.sh                           # 8h, round every 8 min (default)
#   HEARTBEAT_INTERVAL=5m ./scripts/heartbeat-self-improve.sh     # go harder: round every 5 min
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=30m ./scripts/heartbeat-self-improve.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-self-improve.sh    # 2m, 30s interval
#   HEARTBEAT_RETRY=1 ./scripts/heartbeat-self-improve.sh         # retry once per round
#   HEARTBEAT_DRY_RUN=1 ./scripts/heartbeat-self-improve.sh       # skip git push / gh pr create
#
# Logs: logs/heartbeat-self-improve.log (append).
# Safety: By default Chump uses chump/* branches; PRs require human merge.
#         CHUMP_AUTO_PUBLISH=1: push to main and create releases (bump version, tag, push).
#         Set DRY_RUN=1 to skip push/PR/release entirely.
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
[[ "$CHUMP_TEST_CONFIG" == "max_m4" ]] && [[ -f "$ROOT/scripts/env-max_m4.sh" ]] && source "$ROOT/scripts/env-max_m4.sh"

# Default to Ollama only when OPENAI_API_BASE not set (max_m4 keeps 8000 from env-max_m4.sh).
if [[ -z "${OPENAI_API_BASE:-}" ]]; then
  export OPENAI_API_BASE="http://localhost:11434/v1"
  export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"
fi
export OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"
export OPENAI_MODEL="${OPENAI_MODEL:-qwen2.5:14b}"

# Pass DRY_RUN through so Chump's prompt knows not to push
export DRY_RUN="${HEARTBEAT_DRY_RUN:-${DRY_RUN:-0}}"

# Longer CLI timeout for heartbeat so cargo test / multi-step work don't hit 60s default
export CHUMP_CLI_TIMEOUT_SECS="${CHUMP_CLI_TIMEOUT_SECS:-120}"

# Quick test: short duration
if [[ -n "${HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-30s}"
else
  DURATION="${HEARTBEAT_DURATION:-8h}"
  # Throttle for 8000: longer interval when on vLLM-MLX (default 15m). Ollama default 8m.
  if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-15m}"
  else
    INTERVAL="${HEARTBEAT_INTERVAL:-8m}"
  fi
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

# --- Preflight: 8000 (vLLM-MLX) or 11434 (Ollama) ---
model_ready_8000() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || true
}
ollama_ready() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true
}

if [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
  if [[ "$(model_ready_8000)" == "200" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: model (8000) ready." >> "$LOG"
  else
    echo "Model server not reachable on 8000. Start vLLM-MLX: ./serve-vllm-mlx.sh" >&2
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: 8000 not ready." >> "$LOG"
    exit 1
  fi
else
  if [[ "$(ollama_ready)" == "200" ]]; then
    export OPENAI_API_BASE="http://localhost:11434/v1"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: Ollama (11434) ready." >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: Ollama down, attempting warm..." >> "$LOG"
    if [[ -x "$ROOT/scripts/warm-the-ovens.sh" ]]; then
      "$ROOT/scripts/warm-the-ovens.sh" >> "$LOG" 2>&1 || true
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 5
      if [[ "$(ollama_ready)" == "200" ]]; then
        export OPENAI_API_BASE="http://localhost:11434/v1"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: Ollama (11434) ready after warm." >> "$LOG"
        break
      fi
    done
  fi
  if [[ "$(ollama_ready)" != "200" ]]; then
    echo "Ollama not reachable on 11434. Start with: ollama serve" >&2
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: no Ollama." >> "$LOG"
    exit 1
  fi
fi

# --- The self-improve prompt (one per round). Commit/release rules depend on CHUMP_AUTO_PUBLISH. ---
AUTO_PUBLISH=0
[[ -n "${CHUMP_AUTO_PUBLISH:-}" ]] && [[ "$CHUMP_AUTO_PUBLISH" == "1" ]] && AUTO_PUBLISH=1

if [[ "$AUTO_PUBLISH" -eq 1 ]]; then
  COMMIT_STEP='6. COMMIT (only if not DRY_RUN and you have successful changes): run_cli "git diff --stat"; git_commit (reference task id); push to main (git_push with branch main). You may create releases: bump version in Cargo.toml, update CHANGELOG (move [Unreleased] to new version block), git tag vX.Y.Z, run_cli "git push origin main --tags". One release per logical batch. Notify when released.'
  RULES_LINE='RULES: Push to main allowed; release autonomy (bump version, tag, push); cargo test before commit; one meaningful change per round; DRY_RUN → no push; if unsure → set blocked and notify. Be concise.'
else
  COMMIT_STEP='6. COMMIT (only if not DRY_RUN and you have successful changes): run_cli "git diff --stat"; git_commit (reference task id); use chump/* branch (gh_create_branch if needed); git_push; optionally gh_create_pr. Never push to main.'
  RULES_LINE='RULES: chump/* branches only; cargo test before commit; one meaningful change per round; DRY_RUN → no push/PR, only log; if unsure → set blocked and notify. Be concise.'
fi

WORK_PROMPT="Self-improve round. You are Chump; work autonomously.

${MABEL_SUPERVISION_BLOCK}
1. START: ego read_all. task list (no status filter) to see open, in_progress, blocked.

2. CHECK YOUR OUTSTANDING WORK (if gh available): gh_list_my_prs to see your open PRs. For each open PR: gh_pr_checks (CI status); gh_pr_view_comments to read review comments. If CI failed: create or resume a task to fix. If PR has comments from Jeff: read them and respond or update the code. If a PR was merged: set the related task to done and episode log a win.

3. PICK WORK: in_progress first; else highest-priority open (task list orders by priority) → set in_progress; else re-check blocked. If queue empty → opportunity mode (step 4).

4. OPPORTUNITY MODE (no tasks): (a) read_file docs/ROADMAP.md and read_file docs/CHUMP_PROJECT_BRIEF.md to know what to work on; (b) run_cli \"grep -rn TODO src/ --include=\\\"*.rs\\\" | head -20\"; (c) run_cli \"cargo test 2>&1 | tail -30\"; (d) read an unexplored file for improvements. If you find work: task create, then do it.

5. DO THE WORK: read_file/list_dir; edit_file or write_file; then run_cli \"cargo test 2>&1 | tail -40\". If tests fail: fix up to 3 tries, else set task blocked and notify. If you cannot fix in 3 attempts: use git_stash (save) or git_revert (undo last commit) to restore a clean state, then set task blocked and notify. When stuck or need human help, notify Jeff right away with what you need.

$COMMIT_STEP

7. WRAP UP: Set task status (done/blocked/in_progress). episode log (summary, tags, sentiment). Update ego (current_focus, recent_wins, frustrations). notify if something is ready or you are blocked. If you need human help (unblocking, approval, or clarification), use the notify tool immediately to DM the configured user (CHUMP_READY_DM_USER_ID) with exactly what you need.

$RULES_LINE"

OPPORTUNITY_PROMPT="Self-improve round: find opportunities. ego read_all, task list.

Before creating new tasks, check recent failures: episode action=recent_by_sentiment sentiment=frustrating limit=5. If you see a pattern (same type of task keeps failing), avoid creating more like it; instead create a task to investigate WHY that type fails.

Scan (do at least 2): read_file docs/ROADMAP.md; read_file docs/CHUMP_PROJECT_BRIEF.md; run_cli \"grep -rn TODO src/ --include=\\\"*.rs\\\" | head -15\"; run_cli \"grep -rn unwrap src/ --include=\\\"*.rs\\\" | grep -v test | grep -v \\\"// ok\\\" | head -15\"; run_cli \"cargo clippy 2>&1 | head -30\"; list_dir src + read_file one unexplored module; run_cli \"cargo test 2>&1 | tail -20\".

Create tasks for real opportunities (max 3): task create with clear title (e.g. \"Fix unwrap in memory_tool\", \"Add unit test for delegate_tool\", or from an unchecked roadmap item). Work on the best one: same flow (edit, cargo test, commit, episode log, ego, notify). $RULES_LINE"

RESEARCH_PROMPT='Self-improve round: learning. ego read_all; episode recent limit 3.

Pick a topic (recent task, Rust/codebase pattern, or Chump-relevant: Discord, SQLite, FTS5, WASM, tool-using agents). web_search 1–2 focused queries. Store 3–5 concise learnings in memory (tag for recall). If a learning suggests a code change: task create. WRAP UP: episode log (what you learned), update ego (curiosities, recent_wins).'

DISCOVERY_PROMPT='Self-improve round: tool discovery. ego read_all (frustrations / gaps). web_search for CLI tools or crates ("best rust CLI tools for X", "brew install X alternative"). Evaluate: maintained, useful, safe. If promising: run_cli "brew install X" or "cargo install X", test. If it works: memory_brain write tools/<name>.md; store in memory; optional task create. Optional: run_cli "./scripts/verify-toolkit.sh --json" for toolkit status.'

# Battle QA self-heal: same motion as "run battle QA and fix yourself".
BATTLE_QA_PROMPT='Run battle QA and fix yourself. Call run_battle_qa with max_queries 20. If ok is false: read_file failures_path, fix (edit_file/write_file), re-run; up to 5 fix rounds. No clarification — full instruction. See docs/BATTLE_QA_SELF_FIX.md if needed.'

# Improve product and Chump–Cursor relationship: use Cursor to implement; optionally research first; write rules/docs so Cursor does better.
CURSOR_IMPROVE_PROMPT='Self-improve round: improve the product and the Chump–Cursor relationship. Do not run battle_qa this round. ego read_all; task list.

1. PICK A GOAL: read_file docs/ROADMAP.md and read_file docs/CHUMP_PROJECT_BRIEF.md. Pick from: an unchecked item in the roadmap, an open task, a codebase gap, or improving how Chump and Cursor work together (handoffs, prompts, rules). Do not invent your own roadmap—use the files. Use web_search if it helps (1–2 queries); store key findings in memory.

2. MAKE CURSOR BETTER: If it would help Cursor do better in this repo: write or update .cursor/rules/*.mdc, AGENTS.md, or docs Cursor sees (e.g. CURSOR_CLI_INTEGRATION.md, ROADMAP.md, CHUMP_PROJECT_BRIEF.md). Add rules that steer Cursor toward our conventions and the roadmap. Use write_file or edit_file.

3. USE CURSOR TO IMPLEMENT: run_cli with agent --model auto -p "<clear goal from roadmap or task; include 1–2 bullets of context or that Cursor should read docs/ROADMAP.md and docs/CHUMP_PROJECT_BRIEF.md>" --force. Pass enough context in -p so Cursor can plan and execute (code, tests, docs). Goal is real product improvement, not just research.

4. WRAP UP: episode log (what you improved, what Cursor did); update ego; set task status if relevant. If you completed a roadmap item, edit_file docs/ROADMAP.md to change that item from - [ ] to - [x]. notify if something is ready. If you need human help, use notify to DM the configured user immediately. Be concise.'

# Optional: mutual supervision — Chump checks Mabel's heartbeat when PIXEL_SSH_HOST is set (Mac .env).
PIXEL_HOST="${PIXEL_SSH_HOST:-}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"
MABEL_SUPERVISION_BLOCK=""
if [[ -n "$PIXEL_HOST" ]]; then
  MABEL_SUPERVISION_BLOCK="0. CHECK MABEL (mutual supervision): run_cli \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p ${PIXEL_PORT} ${PIXEL_HOST} 'tail -5 ~/chump/logs/heartbeat-mabel.log'\"
   If the last log line is older than 30 min or shows repeated failures: run_cli \"ssh -o StrictHostKeyChecking=no -p ${PIXEL_PORT} ${PIXEL_HOST} 'cd ~/chump && bash scripts/restart-mabel-heartbeat.sh'\"
   If that restart command exits non-zero, notify Jeff immediately with the error. If exit 0, Mabel heartbeat was restarted; note in episode.
"
fi

# Round types cycle: cursor_improve is a major factor (2 per cycle); work, opportunity, research, discovery, battle_qa
ROUND_TYPES=(work work cursor_improve opportunity work cursor_improve research work discovery battle_qa)

# Optional lock when on 8000 so only one agent round at a time (reduces OOM). HEARTBEAT_LOCK=0 to disable.
[[ -f "$ROOT/scripts/heartbeat-lock.sh" ]] && source "$ROOT/scripts/heartbeat-lock.sh"
use_heartbeat_lock=0
[[ "${HEARTBEAT_LOCK:-1}" == "1" ]] && [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && use_heartbeat_lock=1

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

  # Check for due scheduled items first (--chump-due prints prompt and marks fired)
  DUE_PROMPT=""
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    DUE_PROMPT=$(env "OPENAI_API_BASE=$OPENAI_API_BASE" "$ROOT/target/release/rust-agent" --chump-due 2>/dev/null || true)
  fi
  if [[ -n "$DUE_PROMPT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: running due scheduled item" >> "$LOG"
    prompt="$DUE_PROMPT"
  else
  case "$round_type" in
    work)            prompt="$WORK_PROMPT" ;;
    opportunity)     prompt="$OPPORTUNITY_PROMPT" ;;
    research)        prompt="$RESEARCH_PROMPT" ;;
    cursor_improve)  prompt="$CURSOR_IMPROVE_PROMPT" ;;
    discovery)       prompt="$DISCOVERY_PROMPT" ;;
    battle_qa)       prompt="$BATTLE_QA_PROMPT" ;;
    *)               prompt="$WORK_PROMPT" ;;
  esac
  fi

  if [[ "$use_heartbeat_lock" == "1" ]] && ! acquire_heartbeat_lock 120; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: skipped (lock timeout — another round or Discord using model)" >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  # Shared brain: pull at round start so Chump has latest from Mabel
  BRAIN_DIR="${CHUMP_BRAIN_PATH:-$ROOT/chump-brain}"
  if [[ -d "$BRAIN_DIR/.git" ]]; then
    git -C "$BRAIN_DIR" pull --rebase >> "$LOG" 2>&1 || true
  fi

  export CHUMP_HEARTBEAT_ROUND="$round"
  export CHUMP_HEARTBEAT_TYPE="${round_type:-work}"
  export CHUMP_HEARTBEAT_ELAPSED="$elapsed"
  export CHUMP_HEARTBEAT_DURATION="$DURATION_SEC"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): starting (OPENAI_API_BASE=$OPENAI_API_BASE)" >> "$LOG"
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    RUN_CMD=(env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/target/release/rust-agent" --chump "$prompt")
  else
    # Fallback: run-local.sh uses Ollama (11434); run-best.sh hardcodes 8000.
    RUN_CMD=(env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/run-local.sh" --chump "$prompt")
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

  [[ "$use_heartbeat_lock" == "1" ]] && release_heartbeat_lock

  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Sleeping $INTERVAL until next round..." >> "$LOG"
  sleep "$INTERVAL_SEC"
done

# Morning report: one final Chump invocation to summarize and notify
SUMMARY_PROMPT="This is the end of a self-improve heartbeat ($round rounds over $DURATION). First call the episode tool with action=recent and limit=$round to get recent episodes. Then check task status (task list) and if you opened any PRs (gh_list_my_prs). Write a concise report: tasks completed, tasks blocked (and why), PRs opened, errors encountered, things Jeff should know. Send this as a notification to Jeff (notify tool). Be concise — 5-10 lines max."
REPORT_FILE="$ROOT/logs/morning-report-$(date +%Y-%m-%d).md"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Generating morning report..." >> "$LOG"
if [[ -x "$ROOT/target/release/rust-agent" ]]; then
  env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/target/release/rust-agent" --chump "$SUMMARY_PROMPT" 2>&1 | tee -a "$REPORT_FILE" >> "$LOG" || true
else
  env "OPENAI_API_BASE=$OPENAI_API_BASE" "$ROOT/run-local.sh" --chump "$SUMMARY_PROMPT" 2>&1 | tee -a "$REPORT_FILE" >> "$LOG" || true
fi

echo "Self-improve heartbeat done. Log: $LOG"
