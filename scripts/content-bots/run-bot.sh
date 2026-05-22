#!/usr/bin/env bash
# scripts/content-bots/run-bot.sh — INFRA-1695 (META-066 phase 2)
#
# Dispatcher for the Content Bots Suite. Given a bot_id (pmm | docubot |
# evangelist | copybot) and a task payload (file or stdin), invokes the
# appropriate LLM with the bot's system prompt + task and writes the output
# to .chump-locks/content-bots/<run_id>/<bot_id>-output.md.
#
# Reads docs/agents/content-bots/bots.yaml for prompt_path + model_tier
# per bot. Honors the toggle resolver (INFRA-1700) — if the bot is not
# enabled per CHUMP_CONTENT_BOTS env or .chump-config.toml, refuses to
# run with a clear message.
#
# Emits 3 ambient event kinds:
#   content_bot_invoked       — at dispatch time
#   content_bot_output        — on successful generation
#   content_bot_pipeline_step — when --predecessor-output points to an
#                                upstream bot's output (chain coordination)
#
# Usage:
#   scripts/content-bots/run-bot.sh <bot_id> [--task <file>] [--task-stdin]
#                                    [--predecessor-output <file>]
#                                    [--run-id <id>] [--dry-run]
#
# Exit codes:
#   0  success — output written, events emitted
#   2  usage error (bad bot_id or missing task)
#   3  bot not enabled per toggle resolver
#   4  bot_id not in bots.yaml
#   5  prompt_path missing on disk
#   6  LLM invocation failed
#
# Tracked: META-066 (productization), INFRA-1695 (this gap), INFRA-1700
# (resolver), INFRA-1690 (foundation manifests).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOTS_YAML="$REPO_ROOT/docs/agents/content-bots/bots.yaml"
LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

# ── Arg parsing ──────────────────────────────────────────────────────────────
BOT_ID="${1:-}"
shift || true
TASK_FILE=""
TASK_STDIN=0
PREDECESSOR_OUTPUT=""
RUN_ID=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK_FILE="$2"; shift 2 ;;
        --task-stdin) TASK_STDIN=1; shift ;;
        --predecessor-output) PREDECESSOR_OUTPUT="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$BOT_ID" ]]; then
    echo "Usage: $0 <bot_id> [--task <file> | --task-stdin] [--predecessor-output <file>] [--run-id <id>] [--dry-run]" >&2
    exit 2
fi

# ── Bot registry lookup (minimal bots.yaml reader) ──────────────────────────
if [[ ! -f "$BOTS_YAML" ]]; then
    echo "[run-bot] FAIL: bots.yaml not found at $BOTS_YAML (INFRA-1690 foundation missing)" >&2
    exit 4
fi

# Extract prompt_path + model_tier for the requested bot. The reader walks
# the YAML linearly — bots.yaml is small, operator-curated, and parsing
# it without serde_yaml keeps the dispatcher dep-free.
PROMPT_PATH=""
MODEL_TIER=""
in_target=0
while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" == "- bot_id: $BOT_ID" ]]; then
        in_target=1
        continue
    fi
    if [[ "$in_target" == 1 ]]; then
        # Next bot starts → stop
        if [[ "$trimmed" =~ ^-\ bot_id: ]]; then
            break
        fi
        if [[ "$trimmed" =~ ^prompt_path:\ (.+)$ ]]; then
            PROMPT_PATH="${BASH_REMATCH[1]}"
        elif [[ "$trimmed" =~ ^model_tier:\ ([a-z]+) ]]; then
            MODEL_TIER="${BASH_REMATCH[1]}"
        fi
    fi
done < "$BOTS_YAML"

if [[ -z "$PROMPT_PATH" ]]; then
    echo "[run-bot] FAIL: bot_id '$BOT_ID' not found in $BOTS_YAML" >&2
    exit 4
fi

PROMPT_ABS="$REPO_ROOT/$PROMPT_PATH"
if [[ ! -f "$PROMPT_ABS" ]]; then
    echo "[run-bot] FAIL: prompt file missing: $PROMPT_PATH" >&2
    exit 5
fi

# ── Toggle resolver (INFRA-1700 logic, replicated in shell) ─────────────────
# The Rust library content_bots::enabled_set() lives in INFRA-1700. To keep
# the dispatcher independent of the chump binary (so it can run on stale or
# missing-subcommand chump installs), we replicate the same precedence here
# in pure bash:
#   1. CHUMP_CONTENT_BOTS env (csv) — highest; empty-string disables all
#   2. .chump-config.toml [content_bots] enabled = [...] (per-repo opt-in)
#   3. Empty set (default-off-on-missing — foundation invariant)
is_enabled() {
    local target="$1"
    # Env takes precedence (set means "this is the set"; empty disables all)
    if [[ -n "${CHUMP_CONTENT_BOTS+x}" ]]; then
        local IFS=','
        for b in $CHUMP_CONTENT_BOTS; do
            b="${b## }"; b="${b%% }"   # trim
            [[ "$b" == "$target" ]] && return 0
        done
        return 1
    fi
    # Fallback: .chump-config.toml [content_bots] enabled list
    local cfg="$REPO_ROOT/.chump-config.toml"
    [[ -f "$cfg" ]] || return 1
    python3 - "$cfg" "$target" <<'PYEOF' 2>/dev/null
import sys
try:
    import tomllib
except ModuleNotFoundError:
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        sys.exit(1)
try:
    with open(sys.argv[1], 'rb') as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(1)
enabled = (data.get('content_bots') or {}).get('enabled') or []
sys.exit(0 if sys.argv[2] in enabled else 1)
PYEOF
}

if ! is_enabled "$BOT_ID"; then
    echo "[run-bot] FAIL: bot '$BOT_ID' is not enabled per toggle resolver" >&2
    echo "  Enable via: CHUMP_CONTENT_BOTS=$BOT_ID  OR  .chump-config.toml [content_bots] enabled = [\"$BOT_ID\"]" >&2
    exit 3
fi

# ── Run-id + output paths ───────────────────────────────────────────────────
if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(date +%s)-$$"
fi
OUT_DIR="$LOCK_DIR/content-bots/$RUN_ID"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/${BOT_ID}-output.md"

# ── Build the LLM input: system prompt + task payload + upstream context ────
TASK_CONTENT=""
if [[ "$TASK_STDIN" == "1" ]]; then
    TASK_CONTENT="$(cat)"
elif [[ -n "$TASK_FILE" ]] && [[ -f "$TASK_FILE" ]]; then
    TASK_CONTENT="$(cat "$TASK_FILE")"
fi

PREDECESSOR_CONTENT=""
if [[ -n "$PREDECESSOR_OUTPUT" ]] && [[ -f "$PREDECESSOR_OUTPUT" ]]; then
    PREDECESSOR_CONTENT="$(cat "$PREDECESSOR_OUTPUT")"
fi

# ── Ambient: invoked ────────────────────────────────────────────────────────
emit_event() {
    local kind="$1" payload="$2"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s",%s}\n' "$ts" "$kind" "$payload" \
        >> "$AMBIENT" 2>/dev/null || true
}

emit_event "content_bot_invoked" \
    "\"bot_id\":\"$BOT_ID\",\"run_id\":\"$RUN_ID\",\"model_tier\":\"${MODEL_TIER:-sonnet}\""

if [[ -n "$PREDECESSOR_OUTPUT" ]]; then
    pred_bot_id="$(basename "$PREDECESSOR_OUTPUT" -output.md)"
    emit_event "content_bot_pipeline_step" \
        "\"from_bot\":\"$pred_bot_id\",\"to_bot\":\"$BOT_ID\",\"output_path\":\"$PREDECESSOR_OUTPUT\",\"run_id\":\"$RUN_ID\""
fi

# ── Dispatch (dry-run = just describe + exit) ───────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
    cat <<DRYRUN
[run-bot] DRY-RUN summary
  bot_id:                $BOT_ID
  model_tier:            ${MODEL_TIER:-sonnet}
  prompt_path:           $PROMPT_PATH
  run_id:                $RUN_ID
  output_file:           $OUT_FILE
  task_chars:            ${#TASK_CONTENT}
  predecessor_chars:     ${#PREDECESSOR_CONTENT}
  events_emitted:        content_bot_invoked$([ -n "$PREDECESSOR_OUTPUT" ] && echo " + content_bot_pipeline_step")
DRYRUN
    exit 0
fi

# Real dispatch — invoke claude -p with the system prompt + task.
# Without claude on PATH the dispatcher cannot complete; emit a structured
# failure rather than running `claude` and getting a not-found error.
if ! command -v claude >/dev/null 2>&1; then
    echo "[run-bot] FAIL: claude CLI not on PATH (cannot invoke LLM)" >&2
    emit_event "content_bot_output" \
        "\"bot_id\":\"$BOT_ID\",\"run_id\":\"$RUN_ID\",\"status\":\"failed\",\"reason\":\"claude-cli-missing\""
    exit 6
fi

# Compose the full prompt. Claude `-p` (one-shot) takes the user message
# on stdin and the system prompt via --append-system-prompt or via the
# message itself (we use the latter for simplicity + cross-version compat).
{
    cat "$PROMPT_ABS"
    echo ""
    echo "---"
    echo "# Task"
    if [[ -n "$TASK_CONTENT" ]]; then
        echo ""
        printf '%s\n' "$TASK_CONTENT"
    else
        echo ""
        echo "(no task payload — describe what you would produce given the Code Custodian's current output)"
    fi
    if [[ -n "$PREDECESSOR_CONTENT" ]]; then
        echo ""
        echo "---"
        echo "# Upstream context (from $(basename "$PREDECESSOR_OUTPUT" -output.md))"
        echo ""
        printf '%s\n' "$PREDECESSOR_CONTENT"
    fi
} | claude -p > "$OUT_FILE" 2>&1
rc=$?

if [[ $rc -ne 0 ]]; then
    echo "[run-bot] FAIL: claude -p exited $rc — output preserved at $OUT_FILE" >&2
    emit_event "content_bot_output" \
        "\"bot_id\":\"$BOT_ID\",\"run_id\":\"$RUN_ID\",\"status\":\"failed\",\"reason\":\"llm-nonzero\",\"exit_code\":$rc"
    exit 6
fi

# ── Ambient: output ─────────────────────────────────────────────────────────
out_size="$(wc -c < "$OUT_FILE" 2>/dev/null || echo 0)"
emit_event "content_bot_output" \
    "\"bot_id\":\"$BOT_ID\",\"run_id\":\"$RUN_ID\",\"output_path\":\"$OUT_FILE\",\"bytes\":$out_size,\"status\":\"ok\""

echo "[run-bot] OK $BOT_ID → $OUT_FILE ($out_size bytes)"
