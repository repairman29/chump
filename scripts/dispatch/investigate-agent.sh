#!/usr/bin/env bash
# scripts/dispatch/investigate-agent.sh — INFRA-2357 (META-269 sub-8)
#
# Dispatch an investigate-and-report Sonnet that DOES NOT ship code —
# only reads state and writes a markdown report.
#
# Usage:
#   bash scripts/dispatch/investigate-agent.sh <topic-slug> [report-path] [scope-text]
#
# Examples:
#   bash scripts/dispatch/investigate-agent.sh fix-trunk-dispatcher-silent
#   bash scripts/dispatch/investigate-agent.sh pr-stuck-2929 "" "Investigate why PR #2929 has been stuck"
#
# Default report path: docs/investigations/<topic-slug>-<UTC>.md
#
# Modes:
#   subprocess  — when CHUMP_INVESTIGATE_MODE=subprocess + auth available,
#                 spawn `claude -p` with the brief.
#   signal      — DEFAULT. Write a pending-signal file under .chump-locks/
#                 that SessionStart pickup processes (INFRA-2341 pivot).
#   dryrun      — print the brief that WOULD be dispatched, exit. For tests.
#
# Emits:
#   kind=investigate_dispatched on dispatch (success path)
#   kind=investigate_dryrun on dryrun (test path)
#   kind=investigate_dispatch_failed on auth/script failure
#
# scanner-anchor: "kind":"investigate_dispatched"
# scanner-anchor: "kind":"investigate_dryrun"
# scanner-anchor: "kind":"investigate_dispatch_failed"

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

TOPIC_SLUG="${1:-}"
REPORT_PATH="${2:-}"
SCOPE_TEXT="${3:-Investigate the topic. Read README + docs/process/INVESTIGATE_AGENT_TEMPLATE.md for context.}"

MODE="${CHUMP_INVESTIGATE_MODE:-signal}"
AMBIENT_PATH="${CHUMP_INVESTIGATE_AMBIENT_PATH:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

if [ -z "$TOPIC_SLUG" ]; then
  cat <<EOF >&2
investigate-agent.sh: missing required topic-slug

Usage:
  bash scripts/dispatch/investigate-agent.sh <topic-slug> [report-path] [scope-text]

The topic-slug becomes part of the report filename and ambient event.
Use lowercase letters, digits, dashes only.
EOF
  exit 2
fi

# Validate slug.
if ! [[ "$TOPIC_SLUG" =~ ^[a-z0-9-]+$ ]]; then
  echo "investigate-agent.sh: topic-slug must match [a-z0-9-]+ (got: $TOPIC_SLUG)" >&2
  exit 2
fi

UTC_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ISO_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -z "$REPORT_PATH" ]; then
  REPORT_PATH="docs/investigations/${TOPIC_SLUG}-${UTC_STAMP}.md"
fi

# Resolve absolute report path.
if [[ "$REPORT_PATH" != /* ]]; then
  REPORT_PATH="$REPO_ROOT/$REPORT_PATH"
fi

# Make sure investigations dir exists.
mkdir -p "$(dirname "$REPORT_PATH")"

# Compose the brief (printed to stdout for both subprocess + signal modes).
BRIEF=$(cat <<EOF
ROLE: investigate-and-report-Sonnet (INFRA-2357 / META-269 sub-8)

SCOPE: $SCOPE_TEXT

DURATION: max 15 min wall-clock. If you have not completed all required
checks within 15 min, stop and write what you found so far.

OUTPUT: write to $REPORT_PATH
using the structure from docs/process/INVESTIGATE_AGENT_TEMPLATE.md.
Required sections: Question, Method, Findings, Diagnosis, Recommended next action.

CONSTRAINTS (HARD):
- DO NOT modify any file outside the report path.
- DO NOT run \`chump gap reserve\`, \`chump claim\`, or any chump CLI that mutates state.db.
- DO NOT run \`git commit\`, \`git push\`, \`gh pr create\`, or any state-changing git command.
- DO NOT run \`launchctl bootout\`, \`launchctl bootstrap\`, or any daemon control command.
- You MAY read any file. You MAY run any read-only shell command.
- If you observe a critical bug that needs immediate action, write it in the
  Recommended next action section of the report. DO NOT act on it yourself.

Begin investigation. End with the report file written.
EOF
)

# Helper: emit ambient event.
emit_ambient() {
  local kind="$1"
  local extra_fields="$2"   # e.g.,  ,"mode":"signal"
  local line
  line=$(printf '{"ts":"%s","kind":"%s","source":"investigate-agent","topic":"%s","report_path":"%s"%s}' \
    "$ISO_TS" "$kind" "$TOPIC_SLUG" "$REPORT_PATH" "$extra_fields")
  echo "$line" >> "$AMBIENT_PATH"
  echo "$line"
}

if [ "$MODE" = "dryrun" ]; then
  echo "─── investigate-agent brief (dryrun, mode=$MODE) ────────────────"
  echo "$BRIEF"
  echo "─────────────────────────────────────────────────────────────────"
  emit_ambient "investigate_dryrun" ',"mode":"dryrun"'
  exit 0
fi

if [ "$MODE" = "signal" ]; then
  # Write a pending-signal file that the SessionStart pickup processes
  # (INFRA-2341 pivot — respect Max subscription billing, no claude -p hop).
  SIGNAL_DIR="$REPO_ROOT/.chump-locks"
  mkdir -p "$SIGNAL_DIR"
  SIGNAL_FILE="$SIGNAL_DIR/investigate-pending-${TOPIC_SLUG}-${UTC_STAMP}.json"
  # JSON-encode BRIEF as a string. Prefer python3; fall back to a placeholder
  # if python3 is missing (the brief lives in the dispatch ambient anyway).
  BRIEF_JSON='"brief content elided (no python3 available; see ambient.jsonl)"'
  if command -v python3 >/dev/null 2>&1; then
    BRIEF_JSON=$(printf '%s' "$BRIEF" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
  fi
  cat > "$SIGNAL_FILE" <<EOF
{
  "kind": "investigate_pending",
  "topic": "$TOPIC_SLUG",
  "report_path": "$REPORT_PATH",
  "dispatched_at": "$ISO_TS",
  "brief": $BRIEF_JSON
}
EOF
  echo "✓ investigate dispatch signaled (mode=signal, INFRA-2341)"
  echo "  topic   : $TOPIC_SLUG"
  echo "  signal  : $SIGNAL_FILE"
  echo "  report  : $REPORT_PATH (to be written by Sonnet)"
  echo
  echo "When a Sonnet session reads this signal via SessionStart pickup,"
  echo "it will run the brief above and produce $REPORT_PATH."
  emit_ambient "investigate_dispatched" ',"mode":"signal"'
  exit 0
fi

if [ "$MODE" = "subprocess" ]; then
  # Subprocess mode: spawn claude -p with the brief.
  # Falls back to signal mode if auth missing.
  if ! command -v claude >/dev/null 2>&1; then
    echo "[investigate-agent] WARN: claude CLI missing; falling back to signal mode" >&2
    CHUMP_INVESTIGATE_MODE=signal exec bash "$0" "$TOPIC_SLUG" "$REPORT_PATH" "$SCOPE_TEXT"
  fi
  # Quick auth probe.
  if ! claude -p "say ok" </dev/null >/dev/null 2>&1; then
    echo "[investigate-agent] WARN: claude -p auth dead; falling back to signal mode" >&2
    emit_ambient "investigate_dispatch_failed" ',"reason":"auth_dead"'
    CHUMP_INVESTIGATE_MODE=signal exec bash "$0" "$TOPIC_SLUG" "$REPORT_PATH" "$SCOPE_TEXT"
  fi
  echo "[investigate-agent] dispatching subprocess (mode=subprocess)"
  emit_ambient "investigate_dispatched" ',"mode":"subprocess"'
  # Pipe brief into claude -p — return its exit code.
  exec claude -p "$BRIEF" --dangerously-skip-permissions --output-format text
fi

echo "[investigate-agent] ERROR: unknown mode '$MODE' (want signal|subprocess|dryrun)" >&2
emit_ambient "investigate_dispatch_failed" ',"reason":"bad_mode"'
exit 2
