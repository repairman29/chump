#!/usr/bin/env bash
# Sprint synthesis generator: reads git log + SQLite since last synthesis, calls chump to
# produce a narrative document, and writes it to docs/syntheses/YYYY-MM-DD.md.
#
# Usage: ./scripts/generate-sprint-synthesis.sh [CHUMP_HOME]
#   CHUMP_DRY_RUN=1  — print context block only; no model call, no file written.
#   CHUMP_BIN=...    — override path to chump binary (default: target/release/rust-agent).
#
# Requires: sqlite3 on PATH; chump binary built (cargo build --release --bin chump).
# Safe read-only on the DB.
set -euo pipefail

ROOT="${1:-${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}}"
DB="$ROOT/sessions/chump_memory.db"
SYNTH_DIR="$ROOT/docs/syntheses"
STAMP="$(date -u +%Y-%m-%d)"
OUT="$SYNTH_DIR/${STAMP}.md"
DRY_RUN="${CHUMP_DRY_RUN:-0}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 not found; install SQLite CLI." >&2
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "No DB at $DB — run Chump once or set CHUMP_HOME." >&2
  exit 1
fi
if [[ ! -d "$SYNTH_DIR" ]]; then
  echo "docs/syntheses/ not found at $SYNTH_DIR — PRODUCT-004 not yet landed." >&2
  exit 1
fi

# Find the most recent dated synthesis to determine span start
LAST_SYNTH_FILE=""
LAST_SYNTH_DATE=""
for f in $(ls "$SYNTH_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md 2>/dev/null | sort); do
  LAST_SYNTH_FILE="$f"
  LAST_SYNTH_DATE=$(basename "$f" .md)
done

if [[ -n "$LAST_SYNTH_DATE" ]]; then
  GIT_SINCE="$LAST_SYNTH_DATE"
  PREV_NOTE="Previous synthesis: $(basename "$LAST_SYNTH_FILE")"
else
  # Fallback: 14-day window when no prior synthesis exists
  GIT_SINCE=$(date -u -v-14d +%Y-%m-%d 2>/dev/null \
    || date -u -d '14 days ago' +%Y-%m-%d 2>/dev/null \
    || echo "")
  [[ -z "$GIT_SINCE" ]] && GIT_SINCE="$STAMP"
  PREV_NOTE="No prior synthesis — using 14-day window"
fi

SPAN_HEADER="${GIT_SINCE} → ${STAMP}"

# ── Data collection ────────────────────────────────────────────────────────────

GIT_LOG=$(git -C "$ROOT" log --oneline --since="$GIT_SINCE" 2>/dev/null | head -60 \
  || echo "(no commits found in range)")

COMPLETED_TASKS=$(sqlite3 -header -column "$DB" \
  "SELECT id, title, substr(notes,1,80) AS notes, updated_at
   FROM chump_tasks
   WHERE status='done' AND updated_at >= '${GIT_SINCE}'
   ORDER BY updated_at DESC LIMIT 30;" \
  2>/dev/null || echo "(chump_tasks unavailable or empty)")

RECENT_EPISODES=$(sqlite3 -header -column "$DB" \
  "SELECT id, happened_at, sentiment, substr(summary,1,120) AS summary
   FROM chump_episodes
   WHERE happened_at >= '${GIT_SINCE}'
   ORDER BY id DESC LIMIT 20;" \
  2>/dev/null || echo "(chump_episodes unavailable or empty)")

EVAL_ROWS=$(sqlite3 -header -column "$DB" \
  "SELECT eval_case_id, model_used, scores_json, recorded_at
   FROM chump_eval_runs
   WHERE recorded_at >= '${GIT_SINCE}'
   ORDER BY recorded_at DESC LIMIT 20;" \
  2>/dev/null || echo "(no eval runs in range)")

OPEN_GAPS=$(awk '/- id:/{id=$3} /status: open/{print id}' \
  "$ROOT/docs/gaps.yaml" 2>/dev/null \
  | head -20 \
  | tr '\n' ',' \
  | sed 's/,$//' \
  || echo "(gaps.yaml unavailable)")

CONTEXT_BLOCK="# Sprint synthesis context block
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Span: $SPAN_HEADER
$PREV_NOTE
DB: $DB

## Git log since $GIT_SINCE

$GIT_LOG

## Completed tasks (since $GIT_SINCE)

$COMPLETED_TASKS

## Recent episodes (since $GIT_SINCE)

$RECENT_EPISODES

## AB / eval study rows (since $GIT_SINCE)

$EVAL_ROWS

## Open gaps (IDs only)

$OPEN_GAPS"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "=== CHUMP_DRY_RUN=1: context block (no model call, no file written) ==="
  echo ""
  echo "$CONTEXT_BLOCK"
  echo ""
  echo "=== Would write to: $OUT ==="
  exit 0
fi

# ── Model call ─────────────────────────────────────────────────────────────────

SYNTH_PROMPT="You are writing a session synthesis for the Chump project. Your output will be saved as a standalone markdown document read by future agents and collaborators who need to orient quickly.

Using the data in the context block below, fill in all nine sections of the synthesis template. Rules:
- Be specific: cite commit SHAs, task IDs, episode sentiments, eval delta numbers wherever available.
- Do not use placeholder text — every section must be grounded in the provided data.
- If a section has no data (e.g., no eval runs this period), write a single sentence saying so.
- Output ONLY the markdown document. Begin with the frontmatter header block (Author, Span, Outcome). End after section 9 (Single-line summary). No preamble, no closing commentary.

The nine sections (format them as in TEMPLATE.md):
1. Scientific / research result — headline empirical finding if any; link to full doc
2. What shipped — bulleted PR list with one-line descriptions
3. Methodology lessons — hard-won lessons that change behavior next session
4. What failed / wasted time — honest table: What | Time lost | Root cause | Prevention
5. Cost breakdown — steps × trials × spend if tracked via cost_ledger.jsonl
6. Gap / state snapshot — open gaps table: ID | Priority | Status | Notes
7. Where to pick up next session — Immediate / Next chips / Bigger projects / Do NOT touch
8. Operational state at end of session — open PRs, active worktrees, cloud budget, main SHA
9. Single-line summary — one sentence usable in a changelog or retrospective

--- CONTEXT ---
$CONTEXT_BLOCK
--- END CONTEXT ---"

# Locate binary: prefer rust-agent (used by heartbeat), fall back to chump
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -x "$ROOT/target/release/rust-agent" ]]; then
    CHUMP_BIN="$ROOT/target/release/rust-agent"
  elif [[ -x "$ROOT/target/release/chump" ]]; then
    CHUMP_BIN="$ROOT/target/release/chump"
  else
    echo "Chump binary not found — build: cargo build --release --bin chump" >&2
    exit 1
  fi
fi

mkdir -p "$SYNTH_DIR"

echo "[generate-sprint-synthesis] span=$SPAN_HEADER bin=$(basename "$CHUMP_BIN")" >&2
env "OPENAI_API_BASE=${OPENAI_API_BASE:-http://localhost:11434/v1}" \
    "OPENAI_API_KEY=${OPENAI_API_KEY:-not-needed}" \
    "OPENAI_MODEL=${OPENAI_MODEL:-qwen2.5:14b}" \
    "$CHUMP_BIN" --chump "$SYNTH_PROMPT" > "$OUT"

echo "[generate-sprint-synthesis] wrote $OUT" >&2

# PRODUCT-006: harvest operational lessons into chump_improvement_targets
# so prompt_assembler.rs surfaces them automatically (no extra prompt injection).
# Disable with CHUMP_HARVEST_LESSONS=0.
if [[ -x "$ROOT/scripts/harvest-synthesis-lessons.sh" ]]; then
  "$ROOT/scripts/harvest-synthesis-lessons.sh" "$OUT" "$ROOT" || true
fi

echo "$OUT"
