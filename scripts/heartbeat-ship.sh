#!/usr/bin/env bash
# heartbeat-ship.sh — Product-shipping heartbeat. Chump works on the portfolio, not on himself.
# Drop in scripts/ alongside heartbeat-self-improve.sh. Uses the same env vars and conventions.
#
# Usage:
#   ./scripts/heartbeat-ship.sh                          # 8h, 5m rounds (cascade) or 45m (local)
#   HEARTBEAT_DURATION=24h ./scripts/heartbeat-ship.sh   # 24h autonomy (one run then exit; restart via ensure-ship-heartbeat or cron)
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=10m ./scripts/heartbeat-ship.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/heartbeat-ship.sh   # 2 min, 30s rounds
#   HEARTBEAT_DRY_RUN=1 ./scripts/heartbeat-ship.sh      # No push/PR, log only
#   HEARTBEAT_ONE_ROUND=1 ./scripts/heartbeat-ship.sh     # One ship round then exit (no wait)
#   CHUMP_AUTOPILOT=1 ./scripts/heartbeat-ship.sh        # Short sleep between rounds (default 5s). More rounds = more API use.
#   HEARTBEAT_STRICT_LOG=1 ./scripts/heartbeat-ship.sh   # Warn when ship round ok but no project log updated.
#   HEARTBEAT_DEBUG=1 ./scripts/heartbeat-ship.sh        # Write last 80 lines of each round to logs/heartbeat-ship-round-N.log.
#
# Requires: docs/PROJECT_PLAYBOOKS.md, docs/process/PROACTIVE_SHIPPING.md, chump-brain/portfolio.md
# See those docs for the full system design.
#
# Environment: Start from repo root (or set CHUMP_HOME) so the script can load .env.
# If you see "Preflight FAIL: no model reachable" in the log, run ./scripts/check-heartbeat-preflight.sh
# and ./scripts/check-providers.sh from the same shell after sourcing .env; ensure cascade keys/scopes (e.g. GitHub models:read) are valid.
# With cascade on, set CHUMP_CLOUD_ONLY=1 to skip local preflight and run rounds using cascade only (e.g. when vLLM-MLX on 8000 is down).

set -euo pipefail
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
[[ -f .env ]] && set -a && source .env && set +a

LOG="$ROOT/logs/heartbeat-ship.log"
LOCK="$ROOT/logs/heartbeat-ship.lock"
mkdir -p "$ROOT/logs"

# --- Single-instance: only one long-running ship heartbeat at a time (skip for one-round) ---
ONE_ROUND=0
[[ "${HEARTBEAT_ONE_ROUND:-0}" == "1" ]] && ONE_ROUND=1
if [[ $ONE_ROUND -eq 0 ]]; then
  if [[ -f "$LOCK" ]]; then
    lock_pid=$(cat "$LOCK" 2>/dev/null)
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ship heartbeat already running (pid $lock_pid). Exiting." >> "$LOG"
      exit 0
    fi
    rm -f "$LOCK"
  fi
  echo $$ > "$LOCK"
  trap 'rm -f "$LOCK"' EXIT
fi

# --- Duration / interval ---
CASCADE_ON=0
[[ "${CHUMP_CASCADE_ENABLED:-0}" == "1" ]] && CASCADE_ON=1

if [[ "${HEARTBEAT_QUICK_TEST:-0}" == "1" ]]; then
  DURATION="${HEARTBEAT_DURATION:-2m}"
  INTERVAL="${HEARTBEAT_INTERVAL:-30s}"
else
  DURATION="${HEARTBEAT_DURATION:-8h}"
  if [[ "${CHUMP_AUTOPILOT:-0}" == "1" ]]; then
    # Autopilot: short sleep between rounds (e.g. 5s), repeat. More rounds = more API/cascade use.
    INTERVAL="${HEARTBEAT_INTERVAL:-${AUTOPILOT_SLEEP_SECS:-5}s}"
  elif [[ $CASCADE_ON -eq 1 ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-5m}"
  else
    INTERVAL="${HEARTBEAT_INTERVAL:-45m}"
  fi
fi

to_seconds() {
  local val="$1"
  if [[ "$val" =~ ^([0-9]+)s$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$val" =~ ^([0-9]+)m$ ]]; then echo $(( ${BASH_REMATCH[1]} * 60 ))
  elif [[ "$val" =~ ^([0-9]+)h$ ]]; then echo $(( ${BASH_REMATCH[1]} * 3600 ))
  else echo "$val"; fi
}
DURATION_SEC=$(to_seconds "$DURATION")
INTERVAL_SEC=$(to_seconds "$INTERVAL")

DRY_RUN=0
[[ -n "${HEARTBEAT_DRY_RUN:-}" ]] && [[ "$HEARTBEAT_DRY_RUN" == "1" ]] && DRY_RUN=1
[[ -n "${DRY_RUN:-}" ]] && [[ "$DRY_RUN" == "1" ]] && DRY_RUN=1

# --- Binary ---
if [[ -x "$ROOT/target/release/chump" ]]; then
  BIN="$ROOT/target/release/chump"
elif [[ -x "$ROOT/target/release/chump" ]]; then
  BIN="$ROOT/target/release/chump"
else
  echo "Release binary not found (tried chump). Run: cargo build --release" >&2
  exit 1
fi

# timeout: use timeout or gtimeout (Homebrew coreutils) so script works on macOS
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
fi

run_chump() {
  local prompt="$1"
  local timeout_s=$(( INTERVAL_SEC > 60 ? INTERVAL_SEC - 30 : INTERVAL_SEC ))
  # Prefer cascade when enabled; only fall back to Ollama if no cascade and no API base set.
  local api_base="${OPENAI_API_BASE:-http://localhost:11434/v1}"
  local api_key="${OPENAI_API_KEY:-ollama}"
  local model="${OPENAI_MODEL:-qwen2.5:14b}"
  local run_env=(
    CHUMP_HOME="$ROOT"
    OPENAI_API_BASE="$api_base"
    OPENAI_MODEL="$model"
    OPENAI_API_KEY="$api_key"
    CHUMP_CASCADE_ENABLED="${CHUMP_CASCADE_ENABLED:-0}"
    CHUMP_CASCADE_STRATEGY="${CHUMP_CASCADE_STRATEGY:-priority}"
    CHUMP_CASCADE_RPM_HEADROOM="${CHUMP_CASCADE_RPM_HEADROOM:-80}"
    CHUMP_HEARTBEAT_ROUND="$round"
    CHUMP_HEARTBEAT_TYPE="$round_type"
    CHUMP_HEARTBEAT_ELAPSED="$elapsed"
    CHUMP_HEARTBEAT_DURATION="$DURATION_SEC"
  )
  # Pass through GitHub token and repo allowlist so ship rounds can git_push and check PRs.
  # Use a PAT in .env with repo (or full) scope for private repos; restart ship heartbeat after changing .env.
  [[ -n "${GITHUB_TOKEN:-}" ]] && run_env+=( "GITHUB_TOKEN=$GITHUB_TOKEN" )
  [[ -n "${CHUMP_GITHUB_REPOS:-}" ]] && run_env+=( "CHUMP_GITHUB_REPOS=$CHUMP_GITHUB_REPOS" )
  # Debug: pass Cursor session log path so memory_brain append_file can write NDJSON for ship-round diagnosis.
  [[ -n "${CHUMP_DEBUG_LOG_PATH:-}" ]] && run_env+=( "CHUMP_DEBUG_LOG_PATH=$CHUMP_DEBUG_LOG_PATH" )
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "${timeout_s}s" env "${run_env[@]}" "$BIN" --chump "$prompt" 2>&1 || true
  else
    env "${run_env[@]}" "$BIN" --chump "$prompt" 2>&1 || true
  fi
}

# --- Prompts ---

AUTO_PUBLISH=0
[[ "${CHUMP_AUTO_PUBLISH:-}" == "1" ]] && AUTO_PUBLISH=1

if [[ "$AUTO_PUBLISH" -eq 1 ]]; then
  COMMIT_RULES='Push to main allowed; release autonomy; cargo test before commit; one step per round; DRY_RUN → no push.'
else
  COMMIT_RULES='chump/* branches only; create branch with git checkout -b chump/<name> before first push to that branch; cargo test before commit; one step per round; DRY_RUN → no push/PR.'
fi

# Optional: force this round to a single product (e.g. CHUMP_SHIP_TARGET=chump-chassis for testing)
SHIP_TARGET_PREFIX=""
if [[ -n "${CHUMP_SHIP_TARGET:-}" ]]; then
  SHIP_TARGET_PREFIX="MANDATORY: This round the product slug is ${CHUMP_SHIP_TARGET}. Use slug=${CHUMP_SHIP_TARGET} for all steps. Do NOT pick from portfolio; skip to step 2 with this slug.

"
fi

SHIP_PROMPT="${SHIP_TARGET_PREFIX}Product-shipping round. You are Chump; work autonomously on the portfolio.

1. READ PORTFOLIO: memory_brain read_file portfolio.md
   Parse the active products. Skip any marked Blocked: Yes.
   Pick the highest-priority non-blocked product${CHUMP_SHIP_TARGET:+ (unless MANDATORY slug above: then use ${CHUMP_SHIP_TARGET})}.

2. LOAD PLAYBOOK: memory_brain read_file projects/{slug}/playbook.md
   (Replace {slug} with the product slug from portfolio.md, e.g. beast-mode.)
   If no playbook exists: follow the Playbook Creation Protocol from docs/PROJECT_PLAYBOOKS.md.
   Create the playbook FIRST using the appropriate template (Product Research for research-phase products, Code Implementation for build-phase). That counts as this round's work. Log it and stop.

3. FIND YOUR PLACE: memory_brain read_file projects/{slug}/log.md
   Find the last step completed. The next step is your work for this round.
   If no log exists: start at Step 1 of the playbook.

3.5. ENSURE REPO READY (if product has a Repo): If portfolio says Repo: owner/name (not \"none\" or \"(none)\"):
   - run_cli \"ls repos/\" to check. Clone dir is repos/owner_name (e.g. repairman29_chump-chassis for repairman29/chump-chassis).
   - If repo dir exists but has no Cargo.toml (only .git): skip clone/pull; set_working_repo and proceed. Empty remotes cause pull to fail.
   - If repo dir missing or empty: github_clone_or_pull repo=owner/name. Use the returned local path.
   - set_working_repo with path = repos/owner_name (or the path from clone). File ops (write_file, patch_file, run_cli, git_commit) operate on the working repo; without this they hit Chump repo.
   - Research-phase products with no repo: skip this step.

4. EXECUTE ONE STEP: Follow the playbook step exactly. Use the named tool(s).
   Respect the exit condition. If the step passes, log it. If it fails, follow On Failure from the playbook.
   If the step's condition is already satisfied (e.g. Cargo.toml exists for Step 1, or cargo check passes), do not retry the action that would fail. Log 'Step N done. Next: Step N+1' and stop; the next round will do Step N+1.
   ONE STEP PER ROUND. Do not try to do the whole playbook in one round.

5. LOG PROGRESS: memory_brain append_file projects/{slug}/log.md. You MUST append exactly once every ship round.
   - If you EXECUTED a step (run_cli, write_file, patch_file, etc.): append with
     ## Session {N} — {date}
     Step {N}: {description}
     Outcome: {pass/fail/partial}
     Next: Step {N+1} or {blocked reason}
   - If you did NOT execute a step (blocked, no next step, wrong product, or could not proceed): append
     ## Session {N} — {date}
     No step executed. Reason: {one short line}. Next: {same step or blocked}.
   No log entry = round failure. Do NOT log progress until you have actually executed the step; logging without execution is a failure. If you did not execute a step, you must still append the \"No step executed. Reason: ...\" line.
   Do not invent step numbers beyond what the playbook defines (e.g. if playbook has Steps 1–5, there is no Step 6 or 7). If you completed the last step of the playbook, log that and run Quality Checks / notify instead of inventing a new step.

6. CHECK PHASE COMPLETION: If you completed the last step in the current phase, check Quality Checks from the playbook.
   If all pass: notify Jeff that the phase is complete and ask about promotion. Do NOT self-promote.

7. TASK + EGO: Create follow-up tasks if needed. Update ego current_focus to '{product}: step {next}'.

8. WRAP UP: episode log (product, step, outcome, sentiment). If blocked: notify Jeff immediately with what you need.
   End your final message with one short line (e.g. \"Done.\" or \"Logged.\"); do not end with an empty message.

RULES: One step per round. Playbook is the plan. $COMMIT_RULES If playbook is wrong, update it and note the change. Never promote a product phase without Jeff. Be concise. Every ship round ends with exactly one append to the chosen product's log.md (either step outcome or \"No step executed. Reason: ...\"). Your last tool call must be memory_brain append_file to that log.
Then reply with exactly: Done."

REVIEW_PROMPT="Review round. Check on all active product work.

1. READ PORTFOLIO: memory_brain read_file portfolio.md

2. FOR EACH PRODUCT WITH A REPO (skip if no repo):
   - gh_list_my_prs to check open PRs.
   - For each PR: gh_pr_checks (CI), gh_pr_view_comments (review feedback).
   - CI failed → create task to fix. Comments from Jeff → respond or update code. Merged → task done, episode log win.

3. TASK HYGIENE: task list. Any in_progress for >3 sessions with no log progress? Re-evaluate: still relevant, or abandon?

4. PLAYBOOK PROGRESS: For the top product, read log.md. Same step for >2 rounds? The step is too big — break it down in the playbook. Or it's blocked — notify Jeff.

5. WRAP UP: episode log (review summary). Update ego if priorities changed."

RESEARCH_PROMPT="Research round. Feed the top product.

1. READ PORTFOLIO: memory_brain read_file portfolio.md. Pick top non-blocked product.

2. What does the product need? Read playbook.md and log.md for that product.
   - Research phase: market data, competitors, user pain points.
   - Build phase: technical docs, API references, library comparisons.
   - No obvious need: search for news/updates in the product's niche.

3. RESEARCH (2-3 web_search calls max): Search, read_url the best results, store in projects/{slug}/research/findings.md (memory_brain append_file).

4. If research changes the playbook (new competitor, pivot, technical constraint): update the playbook. Note the change in the log.

5. WRAP UP: episode log (what you learned, for which product)."

MAINTAIN_PROMPT="Maintenance round. Self-improvement on Chump, capped to one item.

1. Is battle QA green? If not: run_battle_qa max_queries 20, fix one round. Stop after that.
2. Any Chump-repo tasks open? Pick highest priority, do one step. Test. Commit if green.
3. Nothing urgent? Read docs/strategy/ROADMAP.md, find one small unchecked item, do it.
4. DO NOT do more than one item. This is maintenance, not the main job.
5. WRAP UP: episode log."

# --- Round cycle: 60% ship, 10% review, 10% research, 10% maintain, 10% ship ---
ROUND_TYPES=(ship ship ship review ship ship research ship ship maintain)

# Optional Mabel supervision
PIXEL_HOST="${PIXEL_SSH_HOST:-}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"
if [[ -n "$PIXEL_HOST" ]]; then
  MABEL_CHECK="0. CHECK MABEL: run_cli \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p ${PIXEL_PORT} ${PIXEL_HOST} 'tail -5 ~/chump/logs/heartbeat-mabel.log'\"
   If last log >30 min old or repeated failures: run_cli \"ssh -p ${PIXEL_PORT} ${PIXEL_HOST} 'cd ~/chump && bash scripts/restart-mabel-heartbeat.sh'\"
   If restart fails: notify Jeff immediately.
"
  SHIP_PROMPT="${MABEL_CHECK}${SHIP_PROMPT}"
fi

# --- Preflight: ensure at least one model provider is reachable ---
# Re-source .env so env -i CHUMP_HOME=... bash heartbeat-ship.sh still picks up keys
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
port=""
if port=$("$ROOT/scripts/check-heartbeat-preflight.sh" 2>/dev/null); then
  : # preflight ok
elif [[ -n "${CHUMP_CLOUD_ONLY:-}" ]] && [[ "$CHUMP_CLOUD_ONLY" == "1" ]] && [[ "$CASCADE_ON" -eq 1 ]]; then
  port="cloud-only"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight: skipped (CHUMP_CLOUD_ONLY=1); using cascade only." >> "$LOG"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Preflight FAIL: no model reachable. Run ./scripts/check-providers.sh to verify cascade keys (401 = missing models scope, e.g. GitHub needs models:read)." >> "$LOG"
  echo "Preflight FAIL: no model reachable. Run ./scripts/check-providers.sh to verify keys." >&2
  exit 1
fi
[[ "$CASCADE_ON" -eq 1 ]] && ./scripts/check-providers.sh 2>&1 | head -30 >> "$LOG" || true

# --- Main loop ---
start_ts=$(date +%s)
round=0
CASCADE_STATUS="off"
[[ "$CASCADE_ON" -eq 1 ]] && CASCADE_STATUS="on (strategy=${CHUMP_CASCADE_STRATEGY:-priority})"
AUTOPILOT_STATUS=""
[[ "${CHUMP_AUTOPILOT:-0}" == "1" ]] && AUTOPILOT_STATUS=", autopilot=1 (sleep ${INTERVAL})"
STRICT_LOG_STATUS=""
[[ "${HEARTBEAT_STRICT_LOG:-0}" == "1" ]] && STRICT_LOG_STATUS=", strict_log=1"
DEBUG_STATUS=""
[[ "${HEARTBEAT_DEBUG:-0}" == "1" ]] && DEBUG_STATUS=", debug=1"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ship heartbeat started: duration=$DURATION, interval=$INTERVAL, dry_run=$DRY_RUN, cascade=$CASCADE_STATUS, api_base=${OPENAI_API_BASE:-localhost:11434}, preflight=$port${AUTOPILOT_STATUS}${STRICT_LOG_STATUS}${DEBUG_STATUS}" >> "$LOG"

while true; do
  now=$(date +%s)
  elapsed=$((now - start_ts))
  if [[ $elapsed -ge $DURATION_SEC ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ship heartbeat finished after $round rounds." >> "$LOG"
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

  # Check for due scheduled items first
  DUE_PROMPT=""
  if [[ -x "$BIN" ]]; then
    DUE_PROMPT=$(env "OPENAI_API_BASE=$OPENAI_API_BASE" "$BIN" --chump-due 2>/dev/null || true)
  fi
  if [[ -n "$DUE_PROMPT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: running due scheduled item" >> "$LOG"
    prompt="$DUE_PROMPT"
    round_type="scheduled"
  else
    case "$round_type" in
      ship)      prompt="$SHIP_PROMPT" ;;
      review)    prompt="$REVIEW_PROMPT" ;;
      research)  prompt="$RESEARCH_PROMPT" ;;
      maintain)  prompt="$MAINTAIN_PROMPT" ;;
      *)         prompt="$SHIP_PROMPT" ;;
    esac
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type) starting" >> "$LOG"

  # Capture mtimes of project log files before ship round so we can report which were updated
  SHIP_LOG_MTIMES=""
  if [[ "$round_type" == "ship" ]] && [[ -d "$ROOT/chump-brain/projects" ]]; then
    SHIP_LOG_MTIMES=$(mktemp -t chump-ship-mtimes.XXXXXX)
    for f in "$ROOT/chump-brain/projects/"/*/log.md; do
      [[ -f "$f" ]] || continue
      mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true)
      [[ -n "$mtime" ]] && echo "$f $mtime" >> "$SHIP_LOG_MTIMES"
    done
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    export HEARTBEAT_DRY_RUN=1
  fi

  out=$(run_chump "$prompt" 2>&1) || true
  exit_code=$?
  status="ok"
  [[ $exit_code -ne 0 ]] && status="fail(exit=$exit_code)"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type) $status" >> "$LOG"
  # After a ship round: report which project logs were updated this round (mtime increased or new file)
  if [[ "$round_type" == "ship" ]] && [[ -d "$ROOT/chump-brain/projects" ]]; then
    log_updated=0
    if [[ -f "${SHIP_LOG_MTIMES:-}" ]]; then
      while read -r path prev_mtime; do
        [[ -f "$path" ]] || continue
        cur_mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || true)
        if [[ -n "$cur_mtime" ]] && [[ "$cur_mtime" -gt "${prev_mtime:-0}" ]]; then
          slug=$(basename "$(dirname "$path")")
          echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]   → project log updated: projects/$slug/log.md" >> "$LOG"
          log_updated=1
        fi
      done < "$SHIP_LOG_MTIMES"
      # New log.md files created this round (not in the pre-round list)
      for f in "$ROOT/chump-brain/projects/"/*/log.md; do
        [[ -f "$f" ]] || continue
        grep -q "^${f} " "$SHIP_LOG_MTIMES" 2>/dev/null && continue
        slug=$(basename "$(dirname "$f")")
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]   → project log updated: projects/$slug/log.md" >> "$LOG"
        log_updated=1
      done
      rm -f "$SHIP_LOG_MTIMES"
    fi
    if [[ ${log_updated:-0} -eq 0 ]]; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]   → no project log updated this round" >> "$LOG"
      if [[ "$status" == "ok" ]] && [[ "${HEARTBEAT_STRICT_LOG:-0}" == "1" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]   warn: ship round ok but no log update (HEARTBEAT_STRICT_LOG=1)" >> "$LOG"
      fi
      if [[ "$status" == "ok" ]] && [[ "${HEARTBEAT_DEBUG:-0}" != "1" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)]   (enable HEARTBEAT_DEBUG=1 and re-run to capture agent output)" >> "$LOG"
      fi
    fi
    # Optional debug: write last N lines of round output to sidecar for investigation
    if [[ "${HEARTBEAT_DEBUG:-0}" == "1" ]] && [[ -n "${out:-}" ]]; then
      DEBUG_ROUND_LOG="$ROOT/logs/heartbeat-ship-round-${round}.log"
      echo "--- Round $round ($round_type) exit_code=$exit_code ---" >> "$DEBUG_ROUND_LOG"
      echo "$out" | tail -80 >> "$DEBUG_ROUND_LOG"
    fi
  fi

  # Retry on transient failure if enabled
  if [[ "$status" != "ok" ]] && [[ "${HEARTBEAT_RETRY:-0}" == "1" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round retry..." >> "$LOG"
    sleep 10
    out=$(run_chump "$prompt" 2>&1) || true
    exit_code=$?
    retry_status="ok"
    [[ $exit_code -ne 0 ]] && retry_status="fail(exit=$exit_code)"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round retry $retry_status" >> "$LOG"
  fi

  [[ $ONE_ROUND -eq 1 ]] && break
  sleep "$INTERVAL_SEC"
done

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ship heartbeat done. $round rounds completed." >> "$LOG"
