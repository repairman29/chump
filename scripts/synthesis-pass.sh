#!/usr/bin/env bash
# synthesis-pass.sh — Periodic synthesis pass for Chump.
#
# Collects session activity since the last pass and writes a structured
# markdown summary to docs/synthesis/synthesis-pass-YYYY-MM-DD-HHMM.md.
# Does NOT call an LLM — the output is a structured data doc for human
# or future-agent consumption.
#
# Usage:
#   ./scripts/synthesis-pass.sh [CHUMP_HOME]
#
# Env knobs:
#   CHUMP_HOME       — repo root (default: parent of this script)
#   CHUMP_DRY_RUN=1  — print what would be written, but don't write the file
#   CHUMP_PR_LIMIT   — max merged PRs to include (default: 30)
#   CHUMP_ALERT_TAIL — lines of ambient.jsonl to read (default: 100)
#
# Schedule: run every 6h via launchd/cron.
# See launchd/com.chump.synthesis-pass.plist for the LaunchAgent config.
#
# Output dir: docs/synthesis/ (created if absent)
# Filename:   synthesis-pass-YYYY-MM-DD-HHMM.md
#
# The last-run timestamp is tracked in docs/synthesis/.last-run so
# consecutive runs compute the right "since" window.

set -euo pipefail
# SIGPIPE (141) is normal when callers like `head` close pipes early.
# Treat it as success so pipefail doesn't abort the script.
trap '' PIPE

ROOT="${1:-${CHUMP_HOME:-$(cd "$(dirname "$0")/.." && pwd)}}"
SYNTH_DIR="$ROOT/docs/synthesis"
STAMP="$(date -u +%Y-%m-%d-%H%M)"
DATESTAMP="$(date -u +%Y-%m-%d)"
OUT="$SYNTH_DIR/synthesis-pass-${STAMP}.md"

DRY_RUN="${CHUMP_DRY_RUN:-0}"
PR_LIMIT="${CHUMP_PR_LIMIT:-30}"
ALERT_TAIL="${CHUMP_ALERT_TAIL:-100}"

LAST_RUN_FILE="$SYNTH_DIR/.last-run"

# ── Determine time window ──────────────────────────────────────────────────────

if [[ -f "$LAST_RUN_FILE" ]]; then
  LAST_RUN_TS="$(cat "$LAST_RUN_FILE")"
  SINCE_LABEL="since last run ($LAST_RUN_TS)"
else
  # First run: look back 6 hours
  LAST_RUN_TS="$(date -u -v-6H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ)"
  SINCE_LABEL="last 6h (first run — no .last-run found)"
fi

NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Collect merged PRs ─────────────────────────────────────────────────────────

if command -v gh >/dev/null 2>&1; then
  MERGED_PRS="$(gh pr list \
    --repo "$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||')" \
    --state merged \
    --limit "$PR_LIMIT" \
    --json number,title,mergedAt,author,headRefName \
    --jq ".[] | select(.mergedAt >= \"$LAST_RUN_TS\") | \"PR #\(.number) [\(.headRefName)] \(.title) — merged \(.mergedAt) by \(.author.login)\"" \
    2>/dev/null || echo "(gh not available or repo not found)")"
  if [[ -z "$MERGED_PRS" ]]; then
    MERGED_PRS="(no PRs merged since $LAST_RUN_TS)"
  fi
else
  MERGED_PRS="(gh CLI not on PATH — install with 'brew install gh')"
fi

# ── Collect recent gap closures from gaps.yaml ─────────────────────────────────

GAPS_FILE="$ROOT/docs/gaps.yaml"
if [[ -f "$GAPS_FILE" ]]; then
  # Extract IDs where closed_date >= LAST_RUN date portion
  LAST_RUN_DATE="${LAST_RUN_TS:0:10}"
  CLOSED_GAPS="$(python3 - "$GAPS_FILE" "$LAST_RUN_DATE" 2>/dev/null <<'PYEOF'
import sys, re

gaps_file = sys.argv[1]
since_date = sys.argv[2]

with open(gaps_file) as f:
    content = f.read()

# Simple regex-based extraction — no full YAML parse needed
entries = re.split(r'^- id:', content, flags=re.MULTILINE)
closed = []
for entry in entries:
    if not entry.strip():
        continue
    id_match = re.match(r'\s*(\S+)', entry)
    if not id_match:
        continue
    gap_id = id_match.group(1)

    status_match = re.search(r'status:\s*(\S+)', entry)
    if not status_match or status_match.group(1) != 'done':
        continue

    date_match = re.search(r"closed_date:\s*['\"]?(\d{4}-\d{2}-\d{2})", entry)
    if not date_match:
        continue

    closed_date = date_match.group(1)
    if closed_date >= since_date:
        title_match = re.search(r'title:\s*(.+)', entry)
        title = title_match.group(1).strip().strip("'\"") if title_match else "(no title)"
        closed.append(f"- {gap_id} ({closed_date}): {title}")

if closed:
    print('\n'.join(closed))
else:
    print(f"(no gaps closed since {since_date})")
PYEOF
)"
else
  CLOSED_GAPS="(docs/gaps.yaml not found at $GAPS_FILE)"
fi

# ── Collect ALERT events from ambient.jsonl ────────────────────────────────────

AMBIENT_FILE="$ROOT/.chump-locks/ambient.jsonl"
if [[ -f "$AMBIENT_FILE" ]]; then
  ALERT_EVENTS="$(tail -"$ALERT_TAIL" "$AMBIENT_FILE" \
    | python3 - "$LAST_RUN_TS" 2>/dev/null <<'PYEOF'
import sys, json

since = sys.argv[1]
alerts = []
other_notable = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue

    ts = ev.get("ts", "")
    if ts < since:
        continue

    kind = ev.get("event", "")
    if kind == "ALERT":
        alert_kind = ev.get("kind", "unknown")
        session = ev.get("session", "?")
        alerts.append(f"  - ALERT kind={alert_kind} session={session} ts={ts}")
    elif kind in ("session_start", "commit"):
        session = ev.get("session", "?")
        if kind == "commit":
            sha = ev.get("sha", "?")[:8]
            gap = ev.get("gap", "?")
            other_notable.append(f"  - commit {sha} gap={gap} session={session} ts={ts}")
        else:
            worktree = ev.get("worktree", "?")
            gap = ev.get("gap", "?")
            other_notable.append(f"  - session_start worktree={worktree} gap={gap} ts={ts}")

out = []
if alerts:
    out.append("**ALERT events (require attention):**")
    out.extend(alerts)
elif not other_notable:
    out.append("(no ALERT events in window)")
if other_notable:
    out.append("**Other notable events:**")
    out.extend(other_notable[:20])  # cap at 20

print('\n'.join(out) if out else "(no events in window)")
PYEOF
)"
else
  ALERT_EVENTS="(no ambient.jsonl at $AMBIENT_FILE — ambient stream not active)"
fi

# ── Collect recent git commits ─────────────────────────────────────────────────

GIT_LOG="$(git -C "$ROOT" log \
  --oneline \
  --after="$LAST_RUN_TS" \
  --format="%h %s" \
  2>/dev/null | head -40 \
  || echo "(git log unavailable)")"
if [[ -z "$GIT_LOG" ]]; then
  GIT_LOG="(no commits since $LAST_RUN_TS)"
fi

# ── Count open gaps ────────────────────────────────────────────────────────────

if [[ -f "$GAPS_FILE" ]]; then
  OPEN_COUNT="$(grep -c '^  status: open' "$GAPS_FILE" 2>/dev/null || echo "?")"
  DONE_COUNT="$(grep -c '^  status: done' "$GAPS_FILE" 2>/dev/null || echo "?")"
else
  OPEN_COUNT="?"
  DONE_COUNT="?"
fi

# ── Build output document ──────────────────────────────────────────────────────

DOC="# Synthesis Pass — ${DATESTAMP}

**Generated:** ${NOW_TS}
**Window:** ${SINCE_LABEL}
**Script:** \`scripts/synthesis-pass.sh\`

> This is an automated data-collection pass. It does NOT call an LLM.
> Use it as a structured briefing before a deep synthesis session, or
> as a lightweight audit trail for the 6h period.

---

## Gaps closed this window

${CLOSED_GAPS}

---

## Merged PRs this window

${MERGED_PRS}

---

## Recent commits

\`\`\`
${GIT_LOG}
\`\`\`

---

## Ambient stream events

${ALERT_EVENTS}

---

## Gap registry snapshot

- Open gaps: **${OPEN_COUNT}**
- Done gaps: **${DONE_COUNT}**

To see open gaps: \`grep -A5 'status: open' docs/gaps.yaml | head -80\`

---

## Next steps for a human or agent reading this

1. Review any ALERT events above — they indicate coordination issues requiring action.
2. Check the closed gaps for follow-up work (new gaps filed? acceptance partially met?).
3. Read the merged PRs to identify any strategic doc updates needed (FACULTY_MAP, RESEARCH_PLAN, etc.).
4. If significant findings landed, consider writing a full session synthesis using \`scripts/generate-sprint-synthesis.sh\`.

---

_Next scheduled run: approximately ${NOW_TS} + 6h via \`launchd/com.chump.synthesis-pass.plist\`_
"

# ── Write or dry-run ───────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "1" ]]; then
  echo "=== CHUMP_DRY_RUN=1 — would write to: $OUT ==="
  echo ""
  echo "$DOC"
  echo ""
  echo "=== (dry run — no file written, no .last-run updated) ==="
  exit 0
fi

mkdir -p "$SYNTH_DIR"
printf '%s\n' "$DOC" > "$OUT"
echo "$NOW_TS" > "$LAST_RUN_FILE"

echo "[synthesis-pass] wrote $OUT" >&2
echo "$OUT"
