#!/usr/bin/env bash
# Mabel heartbeat: autonomous rounds (patrol, research, report, intel, verify, peer_sync) on the Pixel.
# Runs in Termux; uses Mabel's local model (llama-server). The heartbeat IS the farmer — patrol
# runs mabel-farmer.sh then an agent round for Chump heartbeat check and episode/ego.
#
# Requires: CHUMP_CLI_ALLOWLIST on Pixel includes curl, ssh, and optionally sqlite3 for report round.
# Env (in ~/chump/.env): MAC_TAILSCALE_IP, MAC_TAILSCALE_USER, MAC_SSH_PORT, MAC_CHUMP_HOME,
#   MABEL_HEARTBEAT_DURATION=8h, MABEL_HEARTBEAT_INTERVAL=5m, MABEL_HEARTBEAT_RETRY=1 (optional).
#   MABEL_HEAVY_MODEL_BASE (optional): for research/report rounds use this API URL (e.g. Mac 14B); patrol/intel/peer_sync/verify stay on local 3B.
# Pause: touch ~/chump/logs/pause or CHUMP_PAUSED=1 to skip rounds.
#
# Usage:
#   ./scripts/heartbeat-mabel.sh
#   MABEL_HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-mabel.sh   # 2m duration, 30s interval
#
# Logs: logs/heartbeat-mabel.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

# Mac SSH (for prompts and optional mabel-farmer)
MAC_IP="${MAC_TAILSCALE_IP:-}"
MAC_USER="${MAC_TAILSCALE_USER:-$USER}"
MAC_SSH_PORT="${MAC_SSH_PORT:-22}"
MAC_HOME="${MAC_CHUMP_HOME:-$HOME/Projects/Chump}"
LOCAL_PORT="${MABEL_LOCAL_PORT:-8000}"

# Duration and interval
if [[ -n "${MABEL_HEARTBEAT_QUICK_TEST:-}" ]]; then
  DURATION="${MABEL_HEARTBEAT_DURATION:-2m}"
  INTERVAL="${MABEL_HEARTBEAT_INTERVAL:-30s}"
else
  DURATION="${MABEL_HEARTBEAT_DURATION:-8h}"
  INTERVAL="${MABEL_HEARTBEAT_INTERVAL:-5m}"
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
LOG="$ROOT/logs/heartbeat-mabel.log"

# --- Preflight: local llama-server (no Mac dependency so Mabel can start when Mac is down) ---
local_model_ok() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${LOCAL_PORT}/v1/models" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

if local_model_ok; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: local model (${LOCAL_PORT}) ready." >> "$LOG"
else
  echo "Local llama-server not reachable on ${LOCAL_PORT}. Start it first (e.g. start-companion.sh)." >&2
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight failed: local model not ready." >> "$LOG"
  exit 1
fi

# --- Binary: Pixel uses chump, Mac test uses target/release/rust-agent ---
CHUMP_BIN=""
if [[ -x "$ROOT/chump" ]]; then
  CHUMP_BIN="$ROOT/chump"
elif [[ -x "$ROOT/target/release/rust-agent" ]]; then
  CHUMP_BIN="$ROOT/target/release/rust-agent"
fi
if [[ -z "$CHUMP_BIN" ]]; then
  echo "No chump binary found (tried $ROOT/chump and $ROOT/target/release/rust-agent)." >&2
  exit 1
fi

# --- Build prompts (inject Mac SSH so agent can run them) ---
# Escape for embedding in double-quoted prompt: MAC_HOME and paths must be safe (no spaces in typical use).
PATROL_PROMPT="Mabel patrol round. You are Mabel; work autonomously.
1. START: ego read_all. task list.
2. HEALTH CHECK: run_cli to check local llama-server: curl -s localhost:${LOCAL_PORT}/v1/models | head -1.
   Then SSH to Mac (use this exact command, replace if your env differs): run_cli \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'curl -s localhost:11434/api/tags | head -1'\"
   and run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'pgrep -f rust-agent.*--discord | head -1'\"
   If anything is down, try fix via SSH: run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && bash scripts/farmer-brown.sh'\"
   If still down after fix attempt, notify Jeff immediately.
3. CHECK CHUMP HEARTBEAT: run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'tail -5 ${MAC_HOME}/logs/heartbeat-self-improve.log'\"
   If the last round was >30 min ago or shows repeated failures: restart via script: run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && bash scripts/restart-chump-heartbeat.sh'\"
   If that command exits non-zero (restart failed), notify Jeff immediately with the error. If it exits 0, Chump heartbeat was restarted; log in episode.
4. WRAP UP: episode log (health status, any issues found/fixed). Update ego."

RESEARCH_PROMPT="Mabel research round. You are Mabel; research autonomously.
1. ego read_all. task list.
2. CHECK CONTEXT: What is Chump working on? run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && sqlite3 sessions/chump_memory.db \"SELECT content FROM chump_episodes ORDER BY created_at DESC LIMIT 3\"'\"
3. PICK TOPIC: Based on Chump's recent work OR your task queue OR project needs, pick ONE topic to research. Good topics: updates to tools we use (llama.cpp, Ollama, Termux, serenity-rs, Tailscale), Rust patterns relevant to current work, competitors or similar projects, solutions to recent blockers.
4. RESEARCH: web_search (1-2 focused queries). read_url on the most relevant result.
5. STORE: memory store key=research/<topic> with a concise summary. memory_brain write intel/<topic>.md with full notes.
6. ACT: If the finding is actionable (new version to upgrade, pattern to adopt, bug fix available), create a task for Chump. message_peer Chump with a one-liner: 'Research finding: <summary>. Created task #<id>.'
7. WRAP UP: episode log (topic, finding, actionable y/n)."

# Report prompt: REPORT_FILE is set per round so the filename has today's date
REPORT_PROMPT_BASE="Mabel report round. You are Mabel; produce a unified fleet report.
1. Pull Chump's recent state via SSH: run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && tail -20 logs/heartbeat-self-improve.log'\"
   and run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && sqlite3 sessions/chump_memory.db \"SELECT id, title, status FROM chump_tasks WHERE status != \\\"done\\\" ORDER BY id DESC LIMIT 10\"'\"
2. Combine with your own patrol/research state (episode recent, task list). Build one consolidated report with: FLEET HEALTH (Mac: Ollama, model, embed, Discord, heartbeat; Pixel: llama-server, Mabel bot, heartbeat), CHUMP (last 4h: completed/in progress/blocked, PRs), MABEL (last 4h: patrols, research, tasks created for Chump), NEEDS ATTENTION.
3. Send the report to Jeff via notify (use the notify tool with the full report text).
4. Write the same report using write_file to path REPLACE_REPORT_PATH (relative to repo root).
5. WRAP UP: episode log (report sent)."

INTEL_PROMPT="Mabel intel round. You are Mabel; gather project-relevant intel.
1. ego read_all. task list.
2. Web search for 1-2 topics relevant to the project: Rust agent patterns, llama.cpp updates, Discord bot best practices (serenity), Termux tips, new CLI tools, Tailscale, SQLite FTS5.
3. Store findings in memory_brain under intel/ (e.g. intel/llama-cpp-updates.md). Store concise bullets in memory.
4. If something is actionable (version to upgrade, pattern to adopt), create a task for Chump and message_peer him with a one-liner.
5. WRAP UP: episode log (topics researched, actionable y/n)."

PEER_SYNC_PROMPT="Mabel peer_sync round. You are Mabel; coordinate with Chump.
1. READ CHUMP'S LAST REPLY from the shared brain: memory_brain read_file a2a/chump-last-reply.md. Summarize what he last said in one line. Include it in your episode log ('Chump said: …').
   Also check the a2a message channel (message_peer read_latest if available) for any newer messages.
2. Summarize what you did since last sync: patrol results, research findings (check brain/research/latest.md if it exists), tasks you created for Chump, any anomalies.
3. Use message_peer to send Chump a concise message with: (a) that summary, (b) any tasks you created for him, (c) anything that needs his attention. Keep it short; Chump will reply in the a2a channel and you can read it next sync.
4. WRAP UP: episode log (peer_sync sent; include 'Chump said: …' when you have a recent peer reply)."

VERIFY_PROMPT="Mabel verify round (QA). You are Mabel; independently verify Chump's last code change.
1. Check Chump's last episode: run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && sqlite3 sessions/chump_memory.db \"SELECT summary, detail FROM chump_episodes ORDER BY created_at DESC LIMIT 1\"'\"
   If the last episode was a code change (commit, PR, edit_file, cargo, git): proceed to step 2. Otherwise skip to step 5.
2. SSH to Mac and run tests: run_cli \"ssh -o StrictHostKeyChecking=no -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_IP} 'cd ${MAC_HOME} && cargo test 2>&1 | tail -20'\"
3. If tests failed: create a task for Chump (title e.g. 'Fix failing tests after last change'). notify Jeff with the tail output so he knows tests are red.
4. Optionally check Discord bot / endpoints (curl) and note in episode.
5. WRAP UP: episode log (verify ran, pass/fail)."

# Round type cycle (verify after patrol so we have a chance to see Chump's latest episode)
ROUND_TYPES=(patrol patrol research report patrol intel patrol verify peer_sync)

start_ts=$(date +%s)
round=0
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat started: duration=$DURATION, interval=$INTERVAL" >> "$LOG"

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Heartbeat finished after $round rounds." >> "$LOG"
    break
  fi

  if [[ -f "$ROOT/logs/pause" ]] || [[ "${CHUMP_PAUSED:-0}" == "1" ]] || [[ "${CHUMP_PAUSED:-}" == "true" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round skipped (paused)" >> "$LOG"
    sleep "$INTERVAL_SEC"
    continue
  fi

  # Shared brain: pull at round start so Mabel has latest from Chump
  BRAIN_DIR="${CHUMP_BRAIN_PATH:-$ROOT/chump-brain}"
  if [[ -d "$BRAIN_DIR/.git" ]]; then
    git -C "$BRAIN_DIR" pull --rebase >> "$LOG" 2>&1 || true
  fi

  round=$((round + 1))
  idx=$(( (round - 1) % ${#ROUND_TYPES[@]} ))
  round_type="${ROUND_TYPES[$idx]}"

  case "$round_type" in
    patrol)
      # Run mabel-farmer.sh once (diagnose + optional fix), then agent for Chump heartbeat check + episode/ego
      if [[ -x "$ROOT/scripts/mabel-farmer.sh" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round (patrol): running mabel-farmer.sh" >> "$LOG"
        MABEL_FARMER_DIAGNOSE_ONLY=0 "$ROOT/scripts/mabel-farmer.sh" >> "$LOG" 2>&1 || true
      fi
      prompt="$PATROL_PROMPT"
      ;;
    research)  prompt="$RESEARCH_PROMPT" ;;
    report)
      REPORT_PATH="logs/mabel-report-$(date +%Y-%m-%d).md"
      prompt="${REPORT_PROMPT_BASE/REPLACE_REPORT_PATH/$REPORT_PATH}"
      ;;
    intel)     prompt="$INTEL_PROMPT" ;;
    verify)    prompt="$VERIFY_PROMPT" ;;
    peer_sync) prompt="$PEER_SYNC_PROMPT" ;;
    *)         prompt="$PATROL_PROMPT" ;;
  esac

  # Hybrid inference: research/report use heavy model (Mac 14B) when MABEL_HEAVY_MODEL_BASE set
  if [[ "$round_type" == "research" ]] || [[ "$round_type" == "report" ]]; then
    API_BASE="${MABEL_HEAVY_MODEL_BASE:-${OPENAI_API_BASE:-http://127.0.0.1:${LOCAL_PORT}/v1}}"
  else
    API_BASE="${OPENAI_API_BASE:-http://127.0.0.1:${LOCAL_PORT}/v1}"
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): starting" >> "$LOG"
  if env OPENAI_API_BASE="$API_BASE" \
      OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" \
      OPENAI_MODEL="${OPENAI_MODEL:-default}" \
      "$CHUMP_BIN" --chump "$prompt" >> "$LOG" 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): ok" >> "$LOG"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): exit non-zero" >> "$LOG"
    if [[ -n "${MABEL_HEARTBEAT_RETRY:-}" ]] && [[ "${MABEL_HEARTBEAT_RETRY}" != "0" ]]; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: retry" >> "$LOG"
      if env OPENAI_API_BASE="$API_BASE" \
          OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" \
          OPENAI_MODEL="${OPENAI_MODEL:-default}" \
          "$CHUMP_BIN" --chump "$prompt" >> "$LOG" 2>&1; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: ok (after retry)" >> "$LOG"
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: retry failed" >> "$LOG"
      fi
    fi
  fi

  # Shared brain: push at round end so Chump gets Mabel's intel/updates
  if [[ -d "$BRAIN_DIR/.git" ]]; then
    if git -C "$BRAIN_DIR" diff --quiet 2>/dev/null && git -C "$BRAIN_DIR" diff --cached --quiet 2>/dev/null; then
      :
    else
      git -C "$BRAIN_DIR" add -A >> "$LOG" 2>&1 || true
      git -C "$BRAIN_DIR" commit -m "mabel sync" >> "$LOG" 2>&1 || true
      git -C "$BRAIN_DIR" push >> "$LOG" 2>&1 || true
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

echo "Mabel heartbeat done. Log: $LOG"
