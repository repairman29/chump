#!/usr/bin/env bash
# ambient-context-inject.sh — FLEET-020
#
# Wired into Claude Code SessionStart and PreToolUse hooks by FLEET-022. Reads
# .chump-locks/ambient.jsonl + active lease files and emits a compact summary
# as Claude Code hook JSON so the agent's first token is already aware of
# sibling sessions, recent commits, and ALERT events — without having to
# remember the manual `tail -30` step in CLAUDE.md.
#
# Output is one of:
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
# (whichever the hook is configured for; passed via $1, defaults to SessionStart)
#
# Environment:
#   CHUMP_AMBIENT_INJECT_N  number of events to tail (default: 30 SessionStart, 10 PreToolUse)
#   CHUMP_AMBIENT_INJECT=0  disable (emits empty additionalContext)
#   CHUMP_AMBIENT_LOG       override ambient.jsonl path
#   CHUMP_AMBIENT_DEBUG=1   echo the rendered context to stderr

set -euo pipefail


# INFRA-956: default harness to a schema-valid value (kills missing_attribution noise).
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

HOOK_EVENT="${1:-SessionStart}"

# ── Resolve repo + lock dir (same logic as ambient-emit.sh) ────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON_PROBE="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON_PROBE" == ".git" ]]; then
    _MAIN_REPO_PROBE="$REPO_ROOT"
else
    _MAIN_REPO_PROBE="$(cd "$_GIT_COMMON_PROBE/.." && pwd)"
fi
_LOCK_DIR_PROBE="$_MAIN_REPO_PROBE/.chump-locks"
_AMBIENT_PROBE="${CHUMP_AMBIENT_LOG:-$_LOCK_DIR_PROBE/ambient.jsonl}"

# ── INFRA-2262: --tick-preamble mode for bash curator-loops ───────────────────
# Bash curator-loops (decompose / handoff / ci-audit / md-links / shepherd) are
# deaf to the fleet wire without an explicit reader. This mode reads ambient
# events since the role's last-seen cursor, filters by role lane + addressed,
# prints a compact [FW] digest to stdout, then advances the cursor.
#
# Usage:  scripts/coord/ambient-context-inject.sh --tick-preamble <role>
# Output: 0..5 lines, one per relevant event. Empty if nothing relevant.
# Exit:   always 0 (failures degrade silently so the calling loop doesn't crash).
if [[ "${1:-}" == "--tick-preamble" ]]; then
    ROLE="${2:-}"
    if [[ -z "$ROLE" ]]; then
        echo "Usage: $0 --tick-preamble <role>" >&2
        exit 0
    fi
    CURSOR_FILE="$_LOCK_DIR_PROBE/${ROLE}-ambient-cursor"
    TOTAL=$(wc -l < "$_AMBIENT_PROBE" 2>/dev/null | tr -d ' ' || echo 0)
    LAST=$(cat "$CURSOR_FILE" 2>/dev/null || echo $((TOTAL > 50 ? TOTAL - 50 : 0)))
    if [[ "$TOTAL" -gt "$LAST" ]]; then
        START=$((LAST + 1))
        sed -n "${START},\$p" "$_AMBIENT_PROBE" 2>/dev/null | \
            ROLE="$ROLE" python3 -c "
import json, os, sys
role = os.environ.get('ROLE', '')
out = []
for line in sys.stdin:
    try:
        d = json.loads(line)
    except Exception:
        continue
    ev = d.get('event') or ''
    if ev not in ('FEEDBACK', 'WARN', 'STUCK', 'DONE', 'INTENT', 'ALERT', 'HANDOFF'):
        continue
    to = d.get('to', '') or ''
    # Fanout (no 'to' or 'to: fleet-wide') OR addressed to this role-curator
    if to and to not in ('fleet-wide', 'operator-76c22455'):
        if f'curator-opus-{role}' not in to:
            continue
    sender = (d.get('session') or d.get('from') or '?')[:30]
    body = (d.get('reason') or d.get('gap') or d.get('corr_id') or '')[:120].replace(chr(10), ' ')
    ts = (d.get('ts') or '?')[11:19]
    out.append(f'[FW {ts}] {ev:8s} {sender:30s} {body}')
for e in out[-5:]:
    print(e)
" 2>/dev/null || true
    fi
    # Advance cursor regardless (best-effort)
    mkdir -p "$_LOCK_DIR_PROBE" 2>/dev/null || true
    printf '%s\n' "$TOTAL" > "$CURSOR_FILE" 2>/dev/null || true
    exit 0
fi

# ── CREDIBLE-084: --tick-outcome mode — emit tick_outcome at end of curator tick
# Wired into each productized loop's tick case AFTER its main command. The
# outcome lets observability + the no-idle-policy audit measure whether
# each tick actually produced something or just heart-beat through.
#
# Usage:  scripts/coord/ambient-context-inject.sh --tick-outcome <role> [exit_code]
# Outcome classification (from env or exit_code):
#   - CHUMP_TICK_OUTCOME=shipped|dispatched_sub|picked_nextbest|none (if set)
#   - exit_code != 0 → blocked_defensible
#   - else → CHUMP_TICK_OUTCOME (default "none")
# Optional CHUMP_TICK_GAP_ID env var attaches a gap_id to the event.
# Exit always 0 so the calling loop doesn't crash on a write failure.
if [[ "${1:-}" == "--tick-outcome" ]]; then
    ROLE="${2:-}"
    EXIT_CODE="${3:-0}"
    if [[ -z "$ROLE" ]]; then
        exit 0
    fi
    if [[ "$EXIT_CODE" -ne 0 ]] 2>/dev/null; then
        OUTCOME="blocked_defensible"
    else
        OUTCOME="${CHUMP_TICK_OUTCOME:-none}"
    fi
    GAP_ID="${CHUMP_TICK_GAP_ID:-}"
    SESSION="${CHUMP_SESSION_ID:-curator-opus-${ROLE}-$(date -u +%Y-%m-%d)}"
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$_LOCK_DIR_PROBE" 2>/dev/null || true
    if [[ -n "$GAP_ID" ]]; then
        printf '{"ts":"%s","kind":"tick_outcome","role":"%s","session":"%s","outcome":"%s","exit_code":%d,"gap_id":"%s"}\n' \
            "$TS" "$ROLE" "$SESSION" "$OUTCOME" "$EXIT_CODE" "$GAP_ID" \
            >> "$_AMBIENT_PROBE" 2>/dev/null || true
    else
        printf '{"ts":"%s","kind":"tick_outcome","role":"%s","session":"%s","outcome":"%s","exit_code":%d}\n' \
            "$TS" "$ROLE" "$SESSION" "$OUTCOME" "$EXIT_CODE" \
            >> "$_AMBIENT_PROBE" 2>/dev/null || true
    fi
    exit 0
fi


_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

# Default tail length depends on hook
default_n=30
[[ "$HOOK_EVENT" == "PreToolUse" ]] && default_n=10
N="${CHUMP_AMBIENT_INJECT_N:-$default_n}"

emit_empty() {
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":""}}\n' "$HOOK_EVENT"
    exit 0
}

# Resolve our session ID so we can hide our own events from the digest
# (also used by the session_start emit below — must be set before the
# kill switch / missing-log short-circuits so first-ever invocations
# still produce the event).
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]] && [[ -f "$REPO_ROOT/.chump-locks/.wt-session-id" ]]; then
    SESSION_ID="$(cat "$REPO_ROOT/.chump-locks/.wt-session-id" 2>/dev/null || true)"
fi

# ── INFRA-102: emit session_start on the SessionStart hook ───────────────────
# CLAUDE.md advertises session_start as one of the ambient.jsonl event kinds
# agents pick up via peripheral vision. The 2026-04-26 audit found a 50-row
# tail with zero session_start events: FLEET-019/022 wired session_end on the
# Stop hook (ambient-session-end.sh) but never wired the symmetric
# session_start emit on the SessionStart hook. This block restores the
# emitter (best-effort, mirrors ambient-session-end.sh).
#
# Runs *before* the CHUMP_AMBIENT_INJECT=0 kill switch and the
# missing-log short-circuit so the event still lands when (a) context
# injection is disabled but agents still want session-start visibility, and
# (b) ambient.jsonl doesn't yet exist (ambient-emit.sh creates it on append).
# Bypass with CHUMP_AMBIENT_SESSION_START_EMIT=0.
if [[ "$HOOK_EVENT" == "SessionStart" ]] \
        && [[ "${CHUMP_AMBIENT_SESSION_START_EMIT:-1}" != "0" ]] \
        && [[ -x "$REPO_ROOT/scripts/dev/ambient-emit.sh" ]]; then
    CHUMP_SESSION_ID="$SESSION_ID" \
        "$REPO_ROOT/scripts/dev/ambient-emit.sh" session_start 2>/dev/null || true
fi

# Kill switch
[[ "${CHUMP_AMBIENT_INJECT:-1}" == "0" ]] && emit_empty
[[ ! -f "$AMBIENT_LOG" ]] && emit_empty

# ── INFRA-1146: roadmap drift inject (SessionStart only) ─────────────────────
# Write inject block to a temp file so multi-line content doesn't confuse the
# Python heredoc env-var quoting within CONTEXT="$(...)".
_ROADMAP_INJECT_FILE=""
if [[ "$HOOK_EVENT" == "SessionStart" ]] \
        && [[ "${CHUMP_ROADMAP_INJECT:-1}" != "0" ]]; then
    _CACHE_FILE="$(dirname "$AMBIENT_LOG")/roadmap-inject.ts"
    _CACHE_STALE=1
    if [[ -f "$_CACHE_FILE" ]]; then
        _CACHE_AGE=$(( $(date +%s) - $(cat "$_CACHE_FILE" 2>/dev/null || echo 0) ))
        [[ "$_CACHE_AGE" -lt 600 ]] && _CACHE_STALE=0
    fi
    if [[ "$_CACHE_STALE" == "1" ]]; then
        _CHUMP_BIN="${CHUMP_BIN:-$(command -v chump 2>/dev/null || echo "")}"
        if [[ -n "$_CHUMP_BIN" && -x "$_CHUMP_BIN" ]]; then
            _ROADMAP_JSON="$("$_CHUMP_BIN" roadmap-status --json --top-starved 3 2>/dev/null || echo "")"
            if [[ -n "$_ROADMAP_JSON" ]]; then
                _INJECT_TMP="$(mktemp 2>/dev/null || echo "")"
                if [[ -n "$_INJECT_TMP" ]]; then
                    printf '%s' "$_ROADMAP_JSON" | python3 -c "
import json, sys
from pathlib import Path
data = json.load(sys.stdin)
out_file = Path(sys.argv[1])
s = data.get('starved_outcomes', [])
u = data.get('untraced_p0', [])
cov = data.get('pillar_coverage', {})
lines = ['=== Roadmap Drift (INFRA-1146) ===']
lines.append('starved_outcomes=' + (','.join(str(x) for x in s[:3]) or 'none'))
lines.append('untraced_p0=' + (','.join(str(x) for x in u[:5]) or 'none'))
lines.append('pillar_coverage: EFFECTIVE={e} CREDIBLE={c} RESILIENT={r} ZERO-WASTE={z}'.format(
    e=cov.get('effective',0), c=cov.get('credible',0),
    r=cov.get('resilient',0), z=cov.get('zero_waste',0)))
lines.append('Run: chump roadmap-status --exit-on-drift  # CI gate')
out_file.write_text('\n'.join(lines))
" "$_INJECT_TMP" 2>/dev/null || true
                    if [[ -s "$_INJECT_TMP" ]]; then
                        _ROADMAP_INJECT_FILE="$_INJECT_TMP"
                        date +%s > "$_CACHE_FILE" 2>/dev/null || true
                        # Emit ambient event
                        _SC=$(printf '%s' "$_ROADMAP_JSON" | python3 -c \
                            "import json,sys; d=json.load(sys.stdin); print(len(d.get('starved_outcomes',[])))" 2>/dev/null || echo 0)
                        _UC=$(printf '%s' "$_ROADMAP_JSON" | python3 -c \
                            "import json,sys; d=json.load(sys.stdin); print(len(d.get('untraced_p0',[])))" 2>/dev/null || echo 0)
                        _TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
                        printf '{"ts":"%s","kind":"roadmap_inject_applied","starved_count":%s,"untraced_p0_count":%s}\n' \
                            "$_TS" "$_SC" "$_UC" >> "$AMBIENT_LOG" 2>/dev/null || true
                    else
                        rm -f "$_INJECT_TMP" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    fi
fi

# ── INFRA-1150: a2a inbox inject (SessionStart only) ─────────────────────────
# Reads .chump-locks/inbox/<session>.jsonl via chump-inbox.sh; dedups by
# (kind, from, gap); renders a "Pending broadcasts" block prepended to the
# agent's context preamble. Closes Silo 4 — agent ↔ operator integration
# burden — by surfacing peer broadcasts at session start so each agent
# sees who is working on what.
#
# EFFECTIVE-029: lane-discipline filter — each role sees own-lane broadcasts +
# cross-lane-tagged (urgent/operator/@all/addressed-to-me) + unrouted (no 'to').
# The reader's lane is derived from the session-id prefix: a session ID of the
# form  curator-opus-<lane>-<date>  (e.g. curator-opus-ci-audit-2026-05-30)
# yields lane "ci-audit".  Non-curator sessions (no curator-opus- prefix) have
# an undeterminable lane — they see ALL broadcasts (fail-open).
# Lane filter is ON by default; set CHUMP_INBOX_LANE_FILTER=0 to disable (see all).
# scanner-anchor: "kind":"inbox_lane_filtered"
#
# Bypass: CHUMP_A2A_INBOX_INJECT=0
# Operator escape: CHUMP_A2A_COORD_DISABLE=1 (master switch from INFRA-1150 AC)
_INBOX_INJECT_FILE=""
if [[ "$HOOK_EVENT" == "SessionStart" ]] \
        && [[ "${CHUMP_A2A_INBOX_INJECT:-1}" != "0" ]] \
        && [[ "${CHUMP_A2A_COORD_DISABLE:-0}" != "1" ]]; then
    _INBOX_CACHE_FILE="$(dirname "$AMBIENT_LOG")/inbox-inject.ts"
    _INBOX_CACHE_STALE=1
    if [[ -f "$_INBOX_CACHE_FILE" ]]; then
        _INBOX_CACHE_AGE=$(( $(date +%s) - $(cat "$_INBOX_CACHE_FILE" 2>/dev/null || echo 0) ))
        [[ "$_INBOX_CACHE_AGE" -lt 600 ]] && _INBOX_CACHE_STALE=0
    fi
    if [[ "$_INBOX_CACHE_STALE" == "1" ]]; then
        _INBOX_SCRIPT="$(dirname "$0")/chump-inbox.sh"
        if [[ -x "$_INBOX_SCRIPT" ]]; then
            # --no-advance: peek without consuming; agent may still want to
            # read these from its own flow. --since cursor: only new since
            # last session start.
            _INBOX_JSON="$("$_INBOX_SCRIPT" read --since cursor --json --no-advance 2>/dev/null || echo "[]")"
            if [[ -n "$_INBOX_JSON" && "$_INBOX_JSON" != "[]" ]]; then
                _INBOX_TMP="$(mktemp 2>/dev/null || echo "")"
                if [[ -n "$_INBOX_TMP" ]]; then
                    printf '%s' "$_INBOX_JSON" | \
                        CHUMP_INBOX_LANE_FILTER="${CHUMP_INBOX_LANE_FILTER:-1}" \
                        SESSION_ID="$SESSION_ID" python3 -c "
import json, sys, os, re
from pathlib import Path
out_file = Path(sys.argv[1])
session_id = os.environ.get('SESSION_ID', '')
lane_filter_on = os.environ.get('CHUMP_INBOX_LANE_FILTER', '1') != '0'

# Derive this reader's lane from session_id: curator-opus-<lane>-<date>
# e.g. curator-opus-ci-audit-2026-05-30 -> 'ci-audit'
# Fail-open: undeterminable lane (non-curator session) -> my_lane = None -> show all
def extract_lane(sid):
    m = re.match(r'^curator-opus-(.+)-\d{4}-\d{2}-\d{2}', sid or '')
    if m:
        return m.group(1)
    # Also accept curator-opus-<lane> with no date suffix (test / synthetic IDs)
    m2 = re.match(r'^curator-opus-(.+)$', sid or '')
    if m2:
        return m2.group(1)
    return None

my_lane = extract_lane(session_id)

def is_visible(m):
    '''EFFECTIVE-029 lane-discipline filter.
    Show a broadcast when any of these hold:
      (a) Lane filter is OFF (CHUMP_INBOX_LANE_FILTER=0)
      (b) Reader lane is undeterminable (fail-open: show everything)
      (c) Sender is on the same lane (sender session contains curator-opus-<my-lane>)
      (d) Addressed to me (to field contains my session_id or my lane)
      (e) Urgency >= WARN (urgent / operator signal)
      (f) Not addressed to any lane (no 'to', or 'to' is fleet-wide/operator/all)
    '''
    if not lane_filter_on:
        return True
    if my_lane is None:
        return True
    # Extract fields
    sender = m.get('session') or m.get('from') or ''
    to_field = m.get('to') or ''
    urgency = (m.get('urgency') or '').upper()
    # (c) same-lane sender
    if f'curator-opus-{my_lane}' in sender:
        return True
    # (d) addressed directly to me or my lane
    if session_id and session_id in to_field:
        return True
    if my_lane and f'curator-opus-{my_lane}' in to_field:
        return True
    # (e) urgent / operator (WARN, CRIT, EMERGENCY) — always surface
    if urgency in ('WARN', 'CRIT', 'EMERGENCY'):
        return True
    # (f) fleet-wide / operator / all / no-to (cross-lane broadcast)
    cross_lane_targets = {'fleet-wide', 'all', '', 'operator'}
    if not to_field or to_field.lower() in cross_lane_targets or to_field.startswith('operator-'):
        return True
    return False

try:
    msgs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(msgs, list) or not msgs:
    sys.exit(0)
# Dedup by (kind, from, gap) — same broadcast from same sender about same
# gap renders once even if repeated.
seen = set()
dedup_all = []
for m in msgs:
    k = (m.get('kind') or m.get('event') or '?',
         m.get('session') or m.get('from') or '?',
         m.get('gap') or '?')
    if k in seen:
        continue
    seen.add(k)
    dedup_all.append(m)
total_before_filter = len(dedup_all)
# Apply lane filter
dedup = [m for m in dedup_all if is_visible(m)]
filtered_out = total_before_filter - len(dedup)
# Cap at 10 to keep preamble readable.
dedup = dedup[:10]
lines = ['=== Pending broadcasts (INFRA-1150 a2a) ===']
for m in dedup:
    ev = m.get('kind') or m.get('event') or '?'
    src = m.get('session') or m.get('from') or '?'
    gap = m.get('gap') or '-'
    note = m.get('note') or m.get('message') or ''
    if len(note) > 80:
        note = note[:77] + '...'
    lines.append(f'[{ev}] {src} gap={gap} {note}')
suffix = f'(showing {len(dedup)} of {len(msgs)} pending'
if lane_filter_on and my_lane is not None and filtered_out > 0:
    suffix += f'; {filtered_out} other-lane hidden — CHUMP_INBOX_LANE_FILTER=0 to see all'
suffix += '; chump-inbox.sh read --since cursor to consume)'
lines.append(suffix)
out_file.write_text('\n'.join(lines))
" "$_INBOX_TMP" 2>/dev/null || true
                    if [[ -s "$_INBOX_TMP" ]]; then
                        _INBOX_INJECT_FILE="$_INBOX_TMP"
                        date +%s > "$_INBOX_CACHE_FILE" 2>/dev/null || true
                        # Emit telemetry: a2a_coord_inbox_consumed (total received)
                        # and inbox_lane_filtered (when lane filter hid ≥1 broadcast).
                        _COUNT=$(printf '%s' "$_INBOX_JSON" | python3 -c \
                            "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)
                        _TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
                        printf '{"ts":"%s","kind":"a2a_coord_inbox_consumed","source":"ambient-context-inject","messages":%s}\n' \
                            "$_TS" "$_COUNT" >> "$AMBIENT_LOG" 2>/dev/null || true
                        # scanner-anchor: "kind":"inbox_lane_filtered"
                        if [[ "${CHUMP_INBOX_LANE_FILTER:-1}" != "0" ]]; then
                            _SHOWN=$(grep -c '^\[' "$_INBOX_TMP" 2>/dev/null || echo 0)
                            if [[ "$_COUNT" -gt "$_SHOWN" ]] 2>/dev/null; then
                                printf '{"ts":"%s","kind":"inbox_lane_filtered","source":"ambient-context-inject","total":%s,"shown":%s,"session":"%s"}\n' \
                                    "$_TS" "$_COUNT" "$_SHOWN" "$SESSION_ID" >> "$AMBIENT_LOG" 2>/dev/null || true
                            fi
                        fi
                    else
                        rm -f "$_INBOX_TMP" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    fi
fi

# ── INFRA-2278: ship-assist context inject (SessionStart only) ───────────────
# Surfaces the top-3 wedge classes from the last 7d VOA reports and a filing
# prompt so every session sees the current friction heatmap without manual
# inspection of docs/process/SHIP_ASSIST_PLAYBOOK.md.
#
# Bypass: CHUMP_SHIP_ASSIST_HOOK=0 (quiet/hermetic sessions)
# Data source: docs/voice/VOA-*.yaml + docs/gaps/VOA-*.yaml
# If < 3 VOAs exist, shows fallback seed classes from VOA-001.
_SHIP_ASSIST_INJECT_FILE=""
if [[ "$HOOK_EVENT" == "SessionStart" ]] \
        && [[ "${CHUMP_SHIP_ASSIST_HOOK:-1}" != "0" ]]; then
    _SA_REPO="${CHUMP_SHIP_ASSIST_REPO:-$MAIN_REPO}"
    _SA_TMP="$(mktemp 2>/dev/null || echo "")"
    if [[ -n "$_SA_TMP" ]]; then
        python3 - "$_SA_TMP" "$_SA_REPO" << 'SA_PY' 2>/dev/null || true
import json, os, sys, time
from pathlib import Path
from datetime import datetime, timezone

out_path = Path(sys.argv[1])
repo_root = Path(sys.argv[2])

now_ts = time.time()
cutoff = now_ts - 7 * 24 * 3600  # last 7 days

# Load yaml lazily (best-effort; fall back to no VOA data on import error)
try:
    import yaml
    _yaml_ok = True
except ImportError:
    _yaml_ok = False

agg = {}  # wedge_class -> {count, minutes_lost}
voa_count = 0

if _yaml_ok:
    # Scan both docs/voice/VOA-*.yaml and docs/gaps/VOA-*.yaml
    for search_dir in [repo_root / "docs" / "voice", repo_root / "docs" / "gaps"]:
        if not search_dir.is_dir():
            continue
        for p in sorted(search_dir.glob("VOA-*.yaml")):
            try:
                doc = yaml.safe_load(p.read_text())
                if not isinstance(doc, dict):
                    continue
                # Check filed_at vs cutoff
                filed_at = doc.get("filed_at", "")
                try:
                    fa_ts = datetime.fromisoformat(str(filed_at).replace("Z", "+00:00")).timestamp()
                    if fa_ts < cutoff:
                        continue
                except Exception:
                    pass  # no date = include anyway
                voa_count += 1
                for obs in doc.get("wedge_observations", []):
                    wc = obs.get("wedge_class", "")
                    ml = int(obs.get("minutes_lost", 0) or 0)
                    if not wc:
                        continue
                    if wc not in agg:
                        agg[wc] = {"count": 0, "minutes_lost": 0}
                    agg[wc]["count"] += 1
                    agg[wc]["minutes_lost"] += ml
            except Exception:
                continue

# Rank by count × minutes_lost
ranked = sorted(agg.items(), key=lambda kv: kv[1]["count"] * kv[1]["minutes_lost"], reverse=True)
top3 = ranked[:3]

lines = ["═══ Ship-assist context (from docs/process/SHIP_ASSIST_PLAYBOOK.md) ═══"]

if top3:
    lines.append("Top-3 wedge classes (last 7 d, ranked by count × minutes_lost):")
    for i, (wc, stats) in enumerate(top3, 1):
        lines.append(f"  {i}. {wc}  (count={stats['count']}, total_minutes_lost={stats['minutes_lost']})")
else:
    # Fallback: seed classes from VOA-001 (the 7 dogfood session wedge classes)
    lines.append("No real VOAs yet — 7 seed classes from VOA-001 (today's dogfood session):")
    seed_classes = [
        "fmt-drift-queue-wide",
        "raw-gh-allowlist-miss",
        "sccache-R2-pair-mismatch",
        "bot-merge-silent-wedge",
        "sonnet-mid-task-stall",
        "claim-force-recover-wip-loss",
        "gap-status-auto-flip-silent-noop",
    ]
    for wc in seed_classes:
        lines.append(f"  - {wc}")

lines.append("")
lines.append("File a wedge when you hit friction:")
lines.append("  chump voice --wedge-class <id> --minutes-lost <N> --workaround \"<text>\" --fix-shape <tooling|doc|gate>")
lines.append("Full taxonomy + tooling inventory + decision flow: docs/process/SHIP_ASSIST_PLAYBOOK.md")

out_path.write_text("\n".join(lines))
SA_PY
        if [[ -s "$_SA_TMP" ]]; then
            _SHIP_ASSIST_INJECT_FILE="$_SA_TMP"
            # Emit kind=ship_assist_context_surfaced (INFRA-2278)
            # scanner-anchor: "kind":"ship_assist_context_surfaced"
            _SA_VOA_COUNT=$(python3 -c "
import sys; lines=open(sys.argv[1]).readlines()
for l in lines:
    if l.startswith('  ') and l.strip().startswith(tuple('123456789')):
        pass
" "$_SA_TMP" 2>/dev/null || echo 0) || true
            _SA_VOA_COUNT="$(python3 -c "
from pathlib import Path
import time
cutoff = time.time() - 7*24*3600
count = 0
for d in [Path('${_SA_REPO}/docs/voice'), Path('${_SA_REPO}/docs/gaps')]:
    if d.is_dir():
        for p in d.glob('VOA-*.yaml'):
            count += 1
print(count)
" 2>/dev/null || echo 0)"
            _SA_TOP_COUNT=$(python3 -c "
from pathlib import Path
content = Path('${_SA_TMP}').read_text()
import re
m = re.search(r'count=(\d+)', content)
print(m.group(1) if m else 0)
" 2>/dev/null || echo 0)
            _TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
            printf '{"ts":"%s","kind":"ship_assist_context_surfaced","voa_count_last_7d":%s,"top_class_count":%s}\n' \
                "$_TS" "${_SA_VOA_COUNT:-0}" "${_SA_TOP_COUNT:-0}" >> "$AMBIENT_LOG" 2>/dev/null || true
        else
            rm -f "$_SA_TMP" 2>/dev/null || true
        fi
    fi
fi

# ── Build the digest in Python (proper JSON parsing + escaping) ───────────────
# Write digest script to a temp file; bash 3.2 on macOS misparses single-quoted
# heredoc bodies inside $() when they contain apostrophes (e.g. "isn't").
_DIGEST_PY="$(mktemp /tmp/chump-ambient-digest-XXXXXX.py)"
cat > "$_DIGEST_PY" << 'PY'
import json, os, sys, time
from pathlib import Path
from datetime import datetime, timezone

ambient = Path(os.environ["AMBIENT_LOG"])
lock_dir = Path(os.environ["LOCK_DIR"])
session_id = os.environ.get("SESSION_ID", "")
hook = os.environ["HOOK_EVENT"]
n = int(os.environ.get("N", "30"))

# Tail last 4096 lines, filter to last n events, parse each as JSON.
lines: list[str] = []
try:
    with ambient.open("rb") as f:
        f.seek(0, 2)
        size = f.tell()
        chunk = 64 * 1024
        buf = b""
        while size > 0 and buf.count(b"\n") < n + 200:
            read = min(chunk, size)
            f.seek(size - read)
            buf = f.read(read) + buf
            size -= read
        lines = buf.decode("utf-8", errors="replace").splitlines()
except Exception:
    lines = []

events = []
for line in lines[-(n + 200):]:
    line = line.strip()
    if not line:
        continue
    try:
        events.append(json.loads(line))
    except Exception:
        continue
events = events[-n:]

# Active leases (exclude ours)
# INFRA-1664: restrict to claim-*.json — real gap-claim leases use the
# `claim-<gap-id>-<pid>-<unix-ts>.json` naming convention. Other files in
# .chump-locks/ (notably curator-filed-*.json idempotence markers from
# META-065, plus bot-merge-*.log/step) must NOT count as sibling leases —
# they were causing the digest to report 47 phantom "active sibling leases"
# every session with 37x INFRA-1149 (the gap that built the curator).
leases = []
for p in sorted(lock_dir.glob("claim-*.json")):
    try:
        data = json.loads(p.read_text())
        if data.get("session_id") == session_id:
            continue
        leases.append(data)
    except Exception:
        continue

# ALERT events from the last 30 min
now_ts = time.time()
alerts = []
for e in events:
    if e.get("event") == "ALERT" or e.get("kind") == "ALERT":
        ts = e.get("ts", "")
        try:
            event_ts = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            if now_ts - event_ts < 30 * 60:
                alerts.append(e)
        except Exception:
            alerts.append(e)

# Sibling sessions in the digest window (exclude ours)
siblings = {}
for e in events:
    s = e.get("session", "")
    if not s or s == session_id:
        continue
    siblings.setdefault(s, {"count": 0, "last_event": "", "last_ts": "", "worktree": e.get("worktree", "")})
    siblings[s]["count"] += 1
    siblings[s]["last_event"] = e.get("event", "")
    siblings[s]["last_ts"] = e.get("ts", "")

# Render compact context block
lines_out = []

# INFRA-1146: prepend roadmap drift block (written to temp file by shell section above).
_roadmap_file = os.environ.get("ROADMAP_INJECT_FILE", "")
if _roadmap_file:
    try:
        _roadmap_block = Path(_roadmap_file).read_text().strip()
        Path(_roadmap_file).unlink(missing_ok=True)
        if _roadmap_block:
            lines_out.append(_roadmap_block)
            lines_out.append("")
    except Exception:
        pass

# INFRA-1150: prepend pending-broadcasts block (written to temp file by shell section above).
_inbox_file = os.environ.get("INBOX_INJECT_FILE", "")
if _inbox_file:
    try:
        _inbox_block = Path(_inbox_file).read_text().strip()
        Path(_inbox_file).unlink(missing_ok=True)
        if _inbox_block:
            lines_out.append(_inbox_block)
            lines_out.append("")
    except Exception:
        pass

# INFRA-1797: surface opus-message inbox (INFRA-1796 CLI) — unread count + 3
# latest previews so cross-Opus DMs aren't missed. Read-only here; explicit
# mark-read remains the operator's responsibility (so a restart mid-read
# doesn't accidentally consume an unprocessed message).
# Bypass: CHUMP_OPUS_INBOX_HOOK=0 (operator-quiet sessions)
if hook == "SessionStart" and os.environ.get("CHUMP_OPUS_INBOX_HOOK", "1") != "0":
    _opus_repo = os.environ.get("REPO_ROOT", ".")
    _opus_inbox_dir = os.environ.get(
        "CHUMP_OPUS_INBOX_DIR",
        os.path.join(_opus_repo, ".chump-locks", "opus-inbox"),
    )
    _opus_session = os.environ.get("CHUMP_SESSION_ID", "")
    _opus_candidates = []
    if _opus_session:
        _safe = _opus_session.replace(":", "_").replace("/", "_")
        _opus_candidates.append(os.path.join(_opus_inbox_dir, "session_" + _safe + ".jsonl"))
    _opus_candidates.append(os.path.join(_opus_inbox_dir, "all-opus.jsonl"))
    _opus_unread = []
    for _path in _opus_candidates:
        if not os.path.isfile(_path):
            continue
        try:
            with open(_path) as _f:
                for _line in _f:
                    _line = _line.strip()
                    if not _line:
                        continue
                    try:
                        _m = json.loads(_line)
                    except Exception:
                        continue
                    if not _m.get("read_at"):
                        _opus_unread.append(_m)
        except Exception:
            pass
    if _opus_unread:
        # scanner-anchor: "kind":"opus_inbox_surfaced" (INFRA-1797)
        # Emit so consumers know unread DMs were surfaced this session.
        try:
            _amb_path = os.environ.get("CHUMP_AMBIENT_LOG", os.path.join(_opus_repo, ".chump-locks", "ambient.jsonl"))
            from datetime import datetime, timezone
            _ts_now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(_amb_path, "a") as _af:
                _af.write('{"ts":"' + _ts_now + '","kind":"opus_inbox_surfaced","unread_count":' + str(len(_opus_unread)) + ',"session":"' + _opus_session + '"}\n')
        except Exception:
            pass
        _opus_unread.sort(key=lambda m: m.get("ts", ""))
        _opus_lines = [
            "═══ Opus inbox (" + str(len(_opus_unread)) + " unread) ═══",
            "  Read with: scripts/coord/opus-message.sh list --unread",
            "  Mark read: scripts/coord/opus-message.sh mark-read <msg-id>",
        ]
        for _m in _opus_unread[-3:]:
            _body = (_m.get("body", "") or "").splitlines()
            _preview = (_body[0] if _body else "")[:100]
            _opus_lines.append(
                "  [{ts}] {mid}  from={src}  to={dst}  ref={ref}".format(
                    ts=_m.get("ts", ""),
                    mid=_m.get("id", "?"),
                    src=_m.get("from", "?"),
                    dst=_m.get("to", "?"),
                    ref=_m.get("ref", "-"),
                )
            )
            if _preview:
                _opus_lines.append("    " + _preview)
        lines_out.append("\n".join(_opus_lines))
        lines_out.append("")

# INFRA-721: SessionStart only — operator-facing fleet brief at the top.
# Prefer `chump fleet brief` (INFRA-721 Rust subcommand); fall back to the
# legacy fleet-brief.sh shell script if the binary isn't on PATH.
# Best-effort; never fail the hook.
if hook == "SessionStart":
    import subprocess, shutil
    repo_root = os.environ.get("REPO_ROOT", ".")
    brief_out = ""
    # Prefer the Rust subcommand (chump fleet brief)
    chump_bin = shutil.which("chump")
    if chump_bin:
        try:
            res = subprocess.run(
                [chump_bin, "fleet", "brief"],
                capture_output=True, text=True, timeout=15,
                env={**os.environ, "CHUMP_REPO": repo_root},
            )
            if res.returncode == 0 and res.stdout.strip():
                brief_out = res.stdout.rstrip()
        except Exception:
            pass
    # Fallback: legacy fleet-brief.sh
    # INFRA-1148: CHUMP_FLEET_BRIEF_INJECT=0 disables the fleet brief block only
    # (CHUMP_AMBIENT_INJECT=0 disables the entire inject; this is narrower).
    fleet_brief_enabled = os.environ.get("CHUMP_FLEET_BRIEF_INJECT", "1") != "0"
    if not brief_out and fleet_brief_enabled:
        brief_script = os.path.join(repo_root, "scripts", "dispatch", "fleet-brief.sh")
        if os.path.exists(brief_script) and os.access(brief_script, os.X_OK):
            try:
                res = subprocess.run(
                    ["bash", brief_script],
                    capture_output=True, text=True, timeout=15,
                )
                if res.returncode == 0 and res.stdout.strip():
                    brief_out = res.stdout.rstrip()
            except Exception:
                pass
    if brief_out:
        lines_out.append(brief_out)
        lines_out.append("")

lines_out.append("=== Ambient stream (FLEET-019 matrix wiring, hook=" + hook + ") ===")
lines_out.append(
    f"Window: last {len(events)} events from .chump-locks/ambient.jsonl  |  "
    f"siblings: {len(siblings)}  |  active leases: {len(leases)}  |  alerts(30m): {len(alerts)}"
)

if alerts:
    lines_out.append("")
    lines_out.append("ALERTS (last 30 min) — read before claiming/editing:")
    for a in alerts[-5:]:
        kind = a.get("kind") or a.get("subkind") or a.get("event")
        note = a.get("note") or a.get("msg") or ""
        sess = a.get("session", "?")
        lines_out.append(f"  - [{a.get('ts','?')}] {kind} session={sess} note={note[:120]}")

if leases:
    lines_out.append("")
    lines_out.append("Active sibling leases (do NOT collide):")
    for l in leases:
        gap = l.get("gap_id") or l.get("purpose") or "?"
        sess = l.get("session_id", "?")
        exp = l.get("expires_at", "?")
        paths = l.get("paths") or []
        path_str = "" if not paths else f"  paths={','.join(paths[:3])}"
        lines_out.append(f"  - {gap}  session={sess}  expires={exp}{path_str}")

if siblings:
    lines_out.append("")
    lines_out.append("Recent sibling activity:")
    for s, info in sorted(siblings.items(), key=lambda kv: kv[1]["last_ts"], reverse=True)[:5]:
        lines_out.append(
            f"  - {s} (worktree={info['worktree']}, {info['count']} events, last={info['last_event']} @ {info['last_ts']})"
        )

# Last few events themselves (for direct visibility on commits / file_edits)
recent_meaningful = [
    e for e in events
    if e.get("event") in ("commit", "file_edit", "ALERT", "INTENT", "session_start")
       and e.get("session") != session_id
]
if recent_meaningful:
    lines_out.append("")
    lines_out.append("Recent meaningful events:")
    for e in recent_meaningful[-8:]:
        kind = e.get("event", "?")
        ts = e.get("ts", "?")
        if kind == "commit":
            tag = f"sha={e.get('sha','?')[:8]} gap={e.get('gap','?')} msg={(e.get('msg','') or '')[:60]}"
        elif kind == "file_edit":
            tag = f"path={e.get('path','?')}"
        elif kind == "INTENT":
            tag = f"gap={e.get('gap','?')}"
        else:
            tag = e.get("note") or e.get("msg") or ""
        lines_out.append(f"  - [{ts}] {kind} {tag}"[:200])

lines_out.append("")
lines_out.append(
    "Tap into the matrix: `tail -50 .chump-locks/ambient.jsonl` for raw stream; "
    "`chump-coord watch` for cross-machine NATS view (FLEET-006). "
    "If you need to act on shared state, re-check this digest before commit/ship."
)

# INFRA-2278: ship-assist context block (additive, bottom of digest).
# Pre-computed by the shell section above; just inject here.
_ship_assist_file = os.environ.get("SHIP_ASSIST_INJECT_FILE", "")
if _ship_assist_file:
    try:
        _sa_block = Path(_ship_assist_file).read_text().strip()
        Path(_ship_assist_file).unlink(missing_ok=True)
        if _sa_block:
            lines_out.append("")
            lines_out.append(_sa_block)
    except Exception:
        pass

context = "\n".join(lines_out)
out = {
    "hookSpecificOutput": {
        "hookEventName": hook,
        "additionalContext": context,
    }
}
sys.stdout.write(json.dumps(out))
PY

CONTEXT="$(
    AMBIENT_LOG="$AMBIENT_LOG" \
    LOCK_DIR="$LOCK_DIR" \
    SESSION_ID="$SESSION_ID" \
    HOOK_EVENT="$HOOK_EVENT" \
    N="$N" \
    REPO_ROOT="$MAIN_REPO" \
    ROADMAP_INJECT_FILE="$_ROADMAP_INJECT_FILE" \
    INBOX_INJECT_FILE="$_INBOX_INJECT_FILE" \
    SHIP_ASSIST_INJECT_FILE="$_SHIP_ASSIST_INJECT_FILE" \
    python3 "$_DIGEST_PY"
)"
rm -f "$_DIGEST_PY"

if [[ "${CHUMP_AMBIENT_DEBUG:-0}" == "1" ]]; then
    printf '%s\n' "$CONTEXT" >&2
fi

printf '%s\n' "$CONTEXT"
