#!/usr/bin/env bash
# Self-improve heartbeat: run Chump in mixed rounds for a set duration.
# Each round gives Chump a dynamic prompt: work queue, cursor_improve, doc_hygiene (LLM doc/roadmap edits),
# opportunity, research, discovery, battle_qa, weekly COS (Monday), etc.
# Unlike heartbeat-learn.sh (static web-search prompts), this drives real codebase work.
# Doc-only marathon: scripts/dev/heartbeat-doc-hygiene-loop.sh (same prompt as doc_hygiene rounds here).
#
# Requires: Ollama on 11434 (default). TAVILY_API_KEY optional (for research fallback).
# For reliable runs, build first: cargo build --release
#
# Usage:
#   ./scripts/dev/heartbeat-self-improve.sh                           # 8h, round every 8 min (default)
#   HEARTBEAT_INTERVAL=5m ./scripts/dev/heartbeat-self-improve.sh     # go harder: round every 5 min
#   HEARTBEAT_DURATION=4h HEARTBEAT_INTERVAL=30m ./scripts/dev/heartbeat-self-improve.sh
#   HEARTBEAT_QUICK_TEST=1 ./scripts/dev/heartbeat-self-improve.sh    # 2m, 30s interval
#   HEARTBEAT_RETRY=1 ./scripts/dev/heartbeat-self-improve.sh         # retry once per round
#   HEARTBEAT_DRY_RUN=1 ./scripts/dev/heartbeat-self-improve.sh       # skip git push / gh pr create
#
# Logs: logs/heartbeat-self-improve.log (append).
# Safety: By default Chump uses chump/* branches; PRs require human merge.
#         CHUMP_AUTO_PUBLISH=1: push to main and create releases (bump version, tag, push).
#         Set DRY_RUN=1 to skip push/PR/release entirely.
#         Kill switch: touch logs/pause or CHUMP_PAUSED=1.

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
[[ "$CHUMP_TEST_CONFIG" == "max_m4" ]] && [[ -f "$ROOT/scripts/dev/env-max_m4.sh" ]] && source "$ROOT/scripts/dev/env-max_m4.sh"

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
  # With cloud cascade: 5m rounds — cloud absorbs load. Local-only: throttle for memory.
  if [[ "${CHUMP_CASCADE_ENABLED:-0}" == "1" ]]; then
    INTERVAL="${HEARTBEAT_INTERVAL:-5m}"
  elif [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
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

# --- Preflight: 8000 (vLLM-MLX) or 11434 (Ollama). Skip when CHUMP_CLOUD_ONLY=1 (cloud cascade only). ---
model_ready_8000() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || true
}
ollama_ready() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true
}

if [[ -n "${CHUMP_CLOUD_ONLY:-}" ]] && [[ "$CHUMP_CLOUD_ONLY" == "1" ]]; then
  unset -v OPENAI_API_BASE
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Cloud-only: skipping local model preflight." >> "$LOG"
elif [[ "${OPENAI_API_BASE:-}" == *":8000"* ]]; then
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
    if [[ -x "$ROOT/scripts/setup/warm-the-ovens.sh" ]]; then
      "$ROOT/scripts/setup/warm-the-ovens.sh" >> "$LOG" 2>&1 || true
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

# Doc hygiene round — shared with scripts/dev/heartbeat-doc-hygiene-loop.sh
# shellcheck source=doc-hygiene-round-prompt.bash
source "$ROOT/scripts/eval/doc-hygiene-round-prompt.bash"
DOC_HYGIENE_PROMPT=$(doc_hygiene_prompt)

# Sprint synthesis round — fires every CHUMP_SYNTHESIS_INTERVAL rounds (default 10).
# shellcheck source=sprint-synthesis-round-prompt.bash
source "$ROOT/scripts/eval/sprint-synthesis-round-prompt.bash"
SPRINT_SYNTHESIS_PROMPT=$(sprint_synthesis_prompt)
CHUMP_SYNTHESIS_INTERVAL="${CHUMP_SYNTHESIS_INTERVAL:-10}"

WORK_PROMPT="Self-improve round. You are Chump; work autonomously.

${MABEL_SUPERVISION_BLOCK}
1. START: ego read_all. task list (no status filter) to see open, in_progress, blocked.

2. CHECK YOUR OUTSTANDING WORK (if gh available): gh_list_my_prs to see your open PRs. For each open PR: gh_pr_checks (CI status); gh_pr_view_comments to read review comments. If CI failed: create or resume a task to fix. If PR has comments from Jeff: read them and respond or update the code. If a PR was merged: set the related task to done and episode log a win.

3. PICK WORK: in_progress first; else highest-priority open (task list orders by priority) → set in_progress; else re-check blocked. If queue empty → opportunity mode (step 4).

4. OPPORTUNITY MODE (no tasks): (a) read_file docs/strategy/ROADMAP.md and read_file docs/briefs/CHUMP_PROJECT_BRIEF.md to know what to work on; (b) run_cli \"grep -rn TODO src/ --include=\\\"*.rs\\\" | head -20\"; (c) run_cli \"cargo test 2>&1 | tail -30\"; (d) read an unexplored file for improvements. If you find work: task create, then do it.

5. DO THE WORK: read_file/list_dir; patch_file or write_file; then run_cli \"cargo test 2>&1 | tail -40\". If tests fail: fix up to 3 tries, else set task blocked and notify. If you cannot fix in 3 attempts: use git_stash (save) or git_revert (undo last commit) to restore a clean state, then set task blocked and notify. When stuck or need human help, notify Jeff right away with what you need.

$COMMIT_STEP

7. WRAP UP: Set task status (done/blocked/in_progress). episode log (summary, tags, sentiment). Update ego (current_focus, recent_wins, frustrations). notify if something is ready or you are blocked. If you need human help (unblocking, approval, or clarification), use the notify tool immediately to DM the configured user (CHUMP_READY_DM_USER_ID) with exactly what you need.

$RULES_LINE"

# Monday COS pass: gated once per calendar day (local) when CHUMP_WEEKLY_COS_HEARTBEAT is not 0.
WEEKLY_COS_PROMPT='Self-improve round: weekly chief-of-staff (COS) operating pass.

Your assembled context may include a block "COS weekly snapshot (latest file …)" from logs/cos-weekly-*.md when that file exists. If the block is missing or looks stale, run_cli "./scripts/eval/generate-cos-weekly-snapshot.sh" once, then task list again.

1. ego read_all; task list (all statuses). Prefer titles prefixed [COS], blocked items, and anything the snapshot highlights.

2. read_file docs/strategy/PRODUCT_ROADMAP_CHIEF_OF_STAFF.md (skim themes + waves) and read_file docs/strategy/ROADMAP.md for unchecked engineering items. Align open tasks with the current wave.

3. For gaps (roadmap unchecked with no task, many blocked, snapshot shows risk): create or update tasks using the [COS] title prefix and acceptance bullets in notes (see product roadmap W1.3).

4. This round is planning and task hygiene only—no broad code refactors unless a single tiny fix clears a metric or unblock.

5. WRAP UP: episode log (3 bullets: operating picture, top risk, next actions). ego (current_focus for the week). notify Jeff only if you need a human decision.'

OPPORTUNITY_PROMPT="Self-improve round: find opportunities. ego read_all, task list.

Before creating new tasks, check recent failures: episode action=recent_by_sentiment sentiment=frustrating limit=5. If you see a pattern (same type of task keeps failing), avoid creating more like it; instead create a task to investigate WHY that type fails.

Scan (do at least 2): read_file docs/strategy/ROADMAP.md; read_file docs/briefs/CHUMP_PROJECT_BRIEF.md; run_cli \"grep -rn TODO src/ --include=\\\"*.rs\\\" | head -15\"; run_cli \"grep -rn unwrap src/ --include=\\\"*.rs\\\" | grep -v test | grep -v \\\"// ok\\\" | head -15\"; run_cli \"cargo clippy 2>&1 | head -30\"; list_dir src + read_file one unexplored module; run_cli \"cargo test 2>&1 | tail -20\".

Create tasks for real opportunities (max 3): task create with clear title (e.g. \"Fix unwrap in memory_tool\", \"Add unit test for delegate_tool\", or from an unchecked roadmap item). Work on the best one: same flow (edit, cargo test, commit, episode log, ego, notify). $RULES_LINE"

RESEARCH_PROMPT='Self-improve round: learning. ego read_all; episode recent limit 3.

Pick a topic (recent task, Rust/codebase pattern, or Chump-relevant: Discord, SQLite, FTS5, WASM, tool-using agents). web_search 1–2 focused queries. Store 3–5 concise learnings in memory (tag for recall). If a learning suggests a code change: task create. WRAP UP: episode log (what you learned), update ego (curiosities, recent_wins).'

DISCOVERY_PROMPT='Self-improve round: tool discovery. ego read_all (frustrations / gaps). web_search for CLI tools or crates ("best rust CLI tools for X", "brew install X alternative"). Evaluate: maintained, useful, safe. If promising: run_cli "brew install X" or "cargo install X", test. If it works: memory_brain write tools/<name>.md; store in memory; optional task create. Optional: run_cli "./scripts/ci/verify-toolkit.sh --json" for toolkit status.'

# Research brief: structured multi-pass research → stored to brain/research/latest.md for context autoload.
RESEARCH_BRIEF_PROMPT='Self-improve round: research brief. Pick one topic relevant to the current task queue or codebase (e.g. Rust pattern, protocol, library, or something in docs/strategy/ROADMAP.md). ego read_all; task list. Run 2–3 focused web_search queries. Synthesize: what is it, why it matters, how it applies to Chump, and 2–3 actionable takeaways. Then write the findings to brain:
  memory_brain write_file with path "research/latest.md" and content:
    # Research Brief: <topic> (<date>)
    ## Summary
    <1–2 sentences>
    ## Key findings
    - ...
    ## Chump relevance
    - ...
    ## Actions
    - [ ] <if any; else "No immediate action">
  Also store the 3 most important findings as individual memory entries. If findings suggest a task: task create. episode log (topic, outcome). ego update (curiosities or recent_wins). Be concise.'

# Battle QA self-heal: same motion as "run battle QA and fix yourself".
BATTLE_QA_PROMPT='Run battle QA and fix yourself. Call run_battle_qa with max_queries 20. If ok is false: read_file failures_path, fix (patch_file/write_file), re-run; up to 5 fix rounds. No clarification — full instruction. See docs/BATTLE_QA_SELF_FIX.md if needed.'

# Improve product and Chump–Cursor relationship: use Cursor to implement; optionally research first; write rules/docs so Cursor does better.
CURSOR_IMPROVE_PROMPT='Self-improve round: improve the product and the Chump–Cursor relationship. Do not run battle_qa this round. ego read_all; task list.

1. PICK A GOAL: read_file docs/strategy/ROADMAP.md and read_file docs/briefs/CHUMP_PROJECT_BRIEF.md. Pick from: an unchecked item in the roadmap, an open task, a codebase gap, or improving how Chump and Cursor work together (handoffs, prompts, rules). Do not invent your own roadmap—use the files. Use web_search if it helps (1–2 queries); store key findings in memory.

2. MAKE CURSOR BETTER: If it would help Cursor do better in this repo: write or update .cursor/rules/*.mdc, AGENTS.md, or docs Cursor sees (e.g. CURSOR_CLI_INTEGRATION.md, ROADMAP.md, CHUMP_PROJECT_BRIEF.md). Add rules that steer Cursor toward our conventions and the roadmap. Use write_file or patch_file.

3. USE CURSOR TO IMPLEMENT: run_cli with agent --model auto -p "<clear goal from roadmap or task; include 1–2 bullets of context or that Cursor should read docs/strategy/ROADMAP.md and docs/briefs/CHUMP_PROJECT_BRIEF.md>" --force. Pass enough context in -p so Cursor can plan and execute (code, tests, docs). Goal is real product improvement, not just research.

4. WRAP UP: episode log (what you improved, what Cursor did); update ego; set task status if relevant. If you completed a roadmap item, patch_file or write_file docs/strategy/ROADMAP.md to change that item from - [ ] to - [x]. notify if something is ready. If you need human help, use notify to DM the configured user immediately. Be concise.'

# Optional: mutual supervision — Chump checks Mabel's heartbeat when PIXEL_SSH_HOST is set (Mac .env).
PIXEL_HOST="${PIXEL_SSH_HOST:-}"
PIXEL_PORT="${PIXEL_SSH_PORT:-8022}"
MABEL_SUPERVISION_BLOCK=""
if [[ -n "$PIXEL_HOST" ]]; then
  MABEL_SUPERVISION_BLOCK="0. CHECK MABEL (mutual supervision): run_cli \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p ${PIXEL_PORT} ${PIXEL_HOST} 'tail -5 ~/chump/logs/heartbeat-mabel.log'\"
   If the last log line is older than 30 min or shows repeated failures: run_cli \"ssh -o StrictHostKeyChecking=no -p ${PIXEL_PORT} ${PIXEL_HOST} 'cd ~/chump && bash scripts/setup/restart-mabel-heartbeat.sh'\"
   If that restart command exits non-zero, notify Jeff immediately with the error. If exit 0, Mabel heartbeat was restarted; note in episode.
"
fi

# Onboard: when multi-repo enabled, run one repo onboarding per round (brief + architecture in chump-brain/projects). After onboarding, create starter playbook if missing.
ONBOARD_PROMPT='Self-improve round: onboard one repo. Require CHUMP_MULTI_REPO_ENABLED=1. Use run_cli to list repos under ${CHUMP_HOME:-.}/repos (e.g. ls -1). Use memory_brain list_files or read_file to see existing chump-brain/projects/*/brief.md. Pick one repo dir that does not yet have a project brief. Call set_working_repo with that repo path (absolute or repos/DIR), then onboard_repo with path set to that repo. After onboarding, check if projects/{slug}/playbook.md exists (memory_brain read_file). If not, write a starter Code Implementation playbook for that repo using the template in docs/PROJECT_PLAYBOOKS.md. Do at most one onboard per round. If all repos already have briefs, do nothing and episode log "onboard: all repos have briefs".'

# External work: when multi-repo enabled, pick an active project, follow its playbook step by step (create playbook if missing).
EXTERNAL_WORK_PROMPT='Self-improve round: external repo work. Require CHUMP_MULTI_REPO_ENABLED=1.
1. memory_brain list_files projects/ — find active projects.
2. task list — check for project-related tasks.
3. Pick the most urgent active project.
4. memory_brain read_file projects/{slug}/playbook.md — if not found, run Playbook Creation Protocol (docs/PROJECT_PLAYBOOKS.md) to create it first.
5. memory_brain read_file projects/{slug}/log.md — find where you left off.
6. set_working_repo with that project repo path.
7. Execute the next step from the playbook.
8. memory_brain append_file projects/{slug}/log.md with timestamp, step, outcome.
9. git_commit, git_push, gh_create_pr when a step produces shippable code.
10. Episode log what you did.
If no external projects or no urgent task: episode log "external_work: no active project".'

# Review: check GitHub notifications, find PRs awaiting review, post one review via gh_pr_view_comments + model + gh_pr_comment (route: Groq/Cerebras via CHUMP_ROUND_PRIVACY=safe).
REVIEW_PROMPT='Self-improve round: PR review. Use run_cli to run: gh api /notifications --jq ".[] | select(.subject.type==\"PullRequest\" and .reason==\"review_requested\") | .subject.url". For the first such PR (or one you pick): get repo and PR number from the URL, then use gh_pr_view_comments with that repo and PR to fetch diff and existing comments. Write a concise, constructive code review (approve or request changes; call out bugs, style, and improvements). Post it with gh_pr_comment. Do at most one review per round. If no PRs awaiting review, episode log "review: no PRs to review".'

# Orchestrated work: multi-agent decomposition (requires CHUMP_SPAWN_WORKERS_ENABLED=1). Pick a task that needs multiple file changes, decompose_task, spawn_worker per subtask, diff_review, merge_subtask, full test, gh_create_pr.
ORCHESTRATED_WORK_PROMPT='Self-improve round: orchestrated work. Require CHUMP_SPAWN_WORKERS_ENABLED=1. Pick a high-priority task that needs multiple file changes. Read codebase digest (codebase_digest or chump-brain digest). Call decompose_task with task and codebase_digest. For each independent subtask: gh_create_branch with branch_name from decomposition, then spawn_worker with task=description, branch=branch_name, working_dir=repo root. Wait for all workers. For each successful worker run diff_review on that branch diff. For each approved: merge_subtask source_branch into integration branch (e.g. chump/integration or main). Run full test suite (run_cli cargo test or npm test). If green: gh_create_pr with coherent description. If red: identify failing subtask, git_revert or revert that branch, note in PR. Episode log what you did. If no suitable task, do normal work and episode log "orchestrated_work: no multi-file task".'

# Round types cycle: doc_hygiene = LLM doc/roadmap editor (2×); cursor_improve 2×; see scripts/eval/doc-hygiene-round-prompt.bash
# sprint_synthesis fires via the CHUMP_SYNTHESIS_INTERVAL counter gate (default every 10 rounds);
# its position in the array also lets it run naturally when the counter hasn't fired.
ROUND_TYPES=(work work cursor_improve doc_hygiene opportunity work cursor_improve doc_hygiene research work sprint_synthesis discovery battle_qa work research_brief onboard external_work review orchestrated_work)

# Optional lock when on 8000 so only one agent round at a time (reduces OOM). HEARTBEAT_LOCK=0 to disable.
[[ -f "$ROOT/scripts/dev/heartbeat-lock.sh" ]] && source "$ROOT/scripts/dev/heartbeat-lock.sh"
use_heartbeat_lock=0
[[ "${HEARTBEAT_LOCK:-1}" == "1" ]] && [[ "${OPENAI_API_BASE:-}" == *":8000"* ]] && use_heartbeat_lock=1

start_ts=$(date +%s)
round=0
weekly_cos_mark_today=""
synthesis_round_counter=0

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

  # Warm probe cascade slots (when cascade enabled) before each round. For 30-min probe when not running heartbeat, use: cron '*/30 * * * *' chump --warm-probe
  if [[ "${CHUMP_CASCADE_ENABLED:-0}" == "1" ]] && [[ -x "$ROOT/target/release/chump" ]]; then
    env "OPENAI_API_BASE=${OPENAI_API_BASE:-}" "$ROOT/target/release/chump" --warm-probe >> "$LOG" 2>&1 || true
  fi

  round=$((round + 1))
  idx=$(( (round - 1) % ${#ROUND_TYPES[@]} ))
  round_type="${ROUND_TYPES[$idx]}"
  weekly_cos_mark_today=""

  # Check for due scheduled items first (--chump-due prints prompt and marks fired)
  DUE_PROMPT=""
  if [[ -x "$ROOT/target/release/chump" ]]; then
    DUE_PROMPT=$(env "OPENAI_API_BASE=$OPENAI_API_BASE" "$ROOT/target/release/chump" --chump-due 2>/dev/null || true)
  fi

  # Once each Monday (local), between 05:00–22:00, prefer COS weekly pass unless disabled or due item wins.
  stamp_file="$ROOT/logs/.weekly-cos-last-run"
  today=$(date +%Y-%m-%d)
  dow=$(date +%u)
  hour=$(date +%H)
  last_run=$(cat "$stamp_file" 2>/dev/null || true)
  use_weekly_cos=0
  if [[ -z "$DUE_PROMPT" ]] && [[ "${CHUMP_WEEKLY_COS_HEARTBEAT:-1}" != "0" ]] && [[ "$dow" == "1" ]] && [[ "$last_run" != "$today" ]] && [[ 10#$hour -ge 5 ]] && [[ 10#$hour -lt 22 ]]; then
    use_weekly_cos=1
  fi

  # Sprint synthesis interval gate: every CHUMP_SYNTHESIS_INTERVAL non-synthesis rounds,
  # override the scheduled round type to sprint_synthesis. When the array naturally selects
  # sprint_synthesis, also reset the counter so the interval restarts cleanly.
  if [[ "$round_type" == "sprint_synthesis" ]]; then
    synthesis_round_counter=0
  elif [[ -z "$DUE_PROMPT" ]] && [[ "$use_weekly_cos" != "1" ]]; then
    synthesis_round_counter=$((synthesis_round_counter + 1))
    if [[ "$synthesis_round_counter" -ge "$CHUMP_SYNTHESIS_INTERVAL" ]]; then
      synthesis_round_counter=0
      round_type="sprint_synthesis"
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: sprint_synthesis (interval=$CHUMP_SYNTHESIS_INTERVAL reached)" >> "$LOG"
    fi
  fi

  if [[ -n "$DUE_PROMPT" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: running due scheduled item" >> "$LOG"
    prompt="$DUE_PROMPT"
  elif [[ "$use_weekly_cos" == "1" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round: weekly COS heartbeat (Monday gate)" >> "$LOG"
    round_type="weekly_cos"
    prompt="$WEEKLY_COS_PROMPT"
    weekly_cos_mark_today="$today"
  else
  case "$round_type" in
    work)            prompt="$WORK_PROMPT" ;;
    opportunity)     prompt="$OPPORTUNITY_PROMPT" ;;
    research)        prompt="$RESEARCH_PROMPT" ;;
    research_brief)  prompt="$RESEARCH_BRIEF_PROMPT" ;;
    cursor_improve)  prompt="$CURSOR_IMPROVE_PROMPT" ;;
    doc_hygiene)     prompt="$DOC_HYGIENE_PROMPT" ;;
    discovery)       prompt="$DISCOVERY_PROMPT" ;;
    battle_qa)       prompt="$BATTLE_QA_PROMPT" ;;
    onboard)         prompt="$ONBOARD_PROMPT" ;;
    external_work)   prompt="$EXTERNAL_WORK_PROMPT" ;;
    review)          prompt="$REVIEW_PROMPT" ;;
    sprint_synthesis) prompt="$SPRINT_SYNTHESIS_PROMPT" ;;
    orchestrated_work)
      if [[ "${CHUMP_SPAWN_WORKERS_ENABLED:-0}" == "1" ]]; then
        prompt="$ORCHESTRATED_WORK_PROMPT"
      else
        prompt="$WORK_PROMPT"
      fi
      ;;
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
  export CHUMP_CURRENT_ROUND_TYPE="${round_type:-work}"
  export CHUMP_HEARTBEAT_ELAPSED="$elapsed"
  export CHUMP_HEARTBEAT_DURATION="$DURATION_SEC"
  # Privacy: work/cursor_improve/doc_hygiene/battle_qa/review/sprint_synthesis require safe
  # (cascade skips Mistral/Gemini trains-on-data slots; synthesis reads internal task data)
  case "${round_type:-work}" in
    work|cursor_improve|doc_hygiene|battle_qa|review|weekly_cos|sprint_synthesis) export CHUMP_ROUND_PRIVACY=safe ;;
    *) unset -v CHUMP_ROUND_PRIVACY ;;
  esac

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): starting (OPENAI_API_BASE=$OPENAI_API_BASE)" >> "$LOG"
  if [[ -x "$ROOT/target/release/chump" ]]; then
    RUN_CMD=(env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/target/release/chump" --chump "$prompt")
  else
    # Fallback: run-local.sh uses Ollama (11434); run-best.sh hardcodes 8000.
    RUN_CMD=(env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/run-local.sh" --chump "$prompt")
  fi
  if "${RUN_CMD[@]}" >> "$LOG" 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Round $round ($round_type): ok" >> "$LOG"
    if [[ -n "$weekly_cos_mark_today" ]]; then
      echo "$weekly_cos_mark_today" > "$stamp_file"
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Weekly COS stamp: $weekly_cos_mark_today" >> "$LOG"
    fi
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
if [[ -x "$ROOT/target/release/chump" ]]; then
  env "OPENAI_API_BASE=$OPENAI_API_BASE" "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" "$ROOT/target/release/chump" --chump "$SUMMARY_PROMPT" 2>&1 | tee -a "$REPORT_FILE" >> "$LOG" || true
else
  env "OPENAI_API_BASE=$OPENAI_API_BASE" "$ROOT/run-local.sh" --chump "$SUMMARY_PROMPT" 2>&1 | tee -a "$REPORT_FILE" >> "$LOG" || true
fi

echo "Self-improve heartbeat done. Log: $LOG"
