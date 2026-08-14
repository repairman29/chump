#!/usr/bin/env bash
# a2a-dead-letter-reaper.sh — INFRA-1946 (INFRA-1862 slice C of E)
#
# Background: a message sent to a dormant inbox (recipient session not
# actively reading) sits unread forever — no reaper, no pager, no closure.
# 2026-05-24 session: 4 curator inboxes accumulated 5K-19K bytes of unread
# dispatches with nobody the wiser. This closes the loop.
#
# Every CHUMP_A2A_DEAD_LETTER_MIN minutes' worth of age (default 30), scan
# .chump-locks/inbox/*.jsonl + their per-session .cursor files. A message is
# "unread" when its byte offset in the inbox file is >= the cursor's last
# advanced offset (the same mechanism chump-inbox.sh uses to decide what's
# new). Any unread message older than CHUMP_A2A_DEAD_LETTER_MIN minutes gets
# appended to .chump-locks/inbox/dead-letter.jsonl (so it's never silently
# lost — delivered, dead-lettered, or flooded-paged, per the AC's done
# definition) and emits kind=a2a_msg_dead_lettered. If this run dead-letters
# more than CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD (default 5) messages, pages
# the operator via operator-recall.sh --condition A2A_DEAD_LETTER_FLOOD.
#
# Usage:
#   scripts/coord/a2a-dead-letter-reaper.sh [--dry-run]
#
# Env:
#   CHUMP_A2A_DEAD_LETTER_MIN              minutes an unread msg sits before it's dead-lettered (default 30)
#   CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD   dead-lettered-this-run count that triggers operator-recall (default 5)
#   CHUMP_A2A_DEAD_LETTER_REAPER=0         disable entirely
#
# Best-effort — always exits 0 (matches the other reapers' cron-safety
# convention), even when 0 messages are dead-lettered.

set -uo pipefail

# INFRA-956: default harness to a schema-valid value.
export CHUMP_AGENT_HARNESS="${CHUMP_AGENT_HARNESS:-manual}"

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LOCK_DIR="${LOCK_DIR:-$REPO_ROOT/.chump-locks}"
INBOX_DIR="$LOCK_DIR/inbox"
AMBIENT="${CHUMP_AMBIENT_PATH:-$LOCK_DIR/ambient.jsonl}"
DEAD_LETTER="$INBOX_DIR/dead-letter.jsonl"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ "${CHUMP_A2A_DEAD_LETTER_REAPER:-1}" == "0" ]]; then
    echo "[a2a-dead-letter-reaper] disabled via CHUMP_A2A_DEAD_LETTER_REAPER=0"
    exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "[a2a-dead-letter-reaper] python3 not found, skipping"; exit 0; }

if [[ ! -d "$INBOX_DIR" ]]; then
    echo "[a2a-dead-letter-reaper] no inbox dir at $INBOX_DIR, nothing to scan"
    exit 0
fi

MIN_AGE_MIN="${CHUMP_A2A_DEAD_LETTER_MIN:-30}"
PAGE_THRESHOLD="${CHUMP_A2A_DEAD_LETTER_PAGE_THRESHOLD:-5}"

# Direct printf to $AMBIENT (matches trunk-sentinel-daemon.sh / pr-shepherd-daemon.sh
# convention) rather than scripts/dev/ambient-emit.sh — that helper validates
# `event` against a small legacy enum (docs/ambient-schema.json) that predates
# most custom kind= events and would silently drop this one.
# INFRA-1287 Pattern 4 (test-event-registry-coverage.sh): named `_emit` so the
# `_emit\s+"[a-zA-Z0-9_]+"` scanner picks up the literal kind= call below as a
# real emit site — same convention as fleet-wedge-handler.sh / active-target-reaper.sh.
# scanner-anchor: "kind":"a2a_msg_dead_lettered"
_emit() {
    local kind="$1" to="$2" sender="$3" age_min="$4" msg_summary="$5"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local esc_summary
    esc_summary="$(printf '%s' "$msg_summary" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read())[1:-1])" 2>/dev/null || printf '%s' "$msg_summary")"
    mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s","to":"%s","sender":"%s","age_min":%s,"msg_summary":"%s"}\n' \
        "$ts" "$kind" "$to" "$sender" "$age_min" "$esc_summary" >> "$AMBIENT" 2>/dev/null || true
}

# Python does the scan + (unless --dry-run) the dead-letter.jsonl append; it
# prints one tab-separated "EMIT\t<to>\t<sender>\t<age_min>\t<summary>" line
# per newly dead-lettered message, followed by a final "COUNT\t<n>" line.
SCAN_OUT="$(python3 - "$INBOX_DIR" "$DEAD_LETTER" "$MIN_AGE_MIN" "$DRY_RUN" <<'PYEOF'
import json, sys, os, glob, datetime

inbox_dir, dead_letter_path, min_age_min, dry_run = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4] == "1"

now = datetime.datetime.now(datetime.timezone.utc)

def parse_ts(ts):
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return None

# dedupe against messages already dead-lettered by a prior run.
seen = set()
if os.path.exists(dead_letter_path):
    with open(dead_letter_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except Exception:
                continue
            k = evt.get("dedupe_key")
            if k:
                seen.add(k)

new_entries = []

for inbox_file in sorted(glob.glob(os.path.join(inbox_dir, "*.jsonl"))):
    if os.path.basename(inbox_file) == "dead-letter.jsonl":
        continue
    session = os.path.basename(inbox_file)[: -len(".jsonl")]
    cursor_file = inbox_file[: -len(".jsonl")] + ".cursor"
    cursor_offset = 0
    if os.path.exists(cursor_file):
        try:
            cursor_offset = int((open(cursor_file).read() or "0").strip() or "0")
        except Exception:
            cursor_offset = 0

    offset = 0
    with open(inbox_file, "rb") as f:
        for raw in f:
            line_start = offset
            offset += len(raw)
            # unread iff this line starts at or after the recipient's cursor.
            if line_start < cursor_offset:
                continue
            text = raw.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            try:
                msg = json.loads(text)
            except Exception:
                continue
            ts = msg.get("ts")
            dt = parse_ts(ts) if ts else None
            if dt is None:
                continue
            age_min = (now - dt).total_seconds() / 60.0
            if age_min < min_age_min:
                continue
            dedupe_key = msg.get("message_id") or "{}:{}:{}:{}".format(
                session, ts, msg.get("corr_id", ""), line_start
            )
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)

            sender = msg.get("session") or msg.get("from") or "unknown"
            kind = msg.get("event") or msg.get("kind") or "unknown"
            body_bits = [
                "{}={}".format(k, msg[k])
                for k in ("gap", "reason", "subject", "commit")
                if msg.get(k)
            ]
            msg_summary = (kind + " " + " ".join(body_bits)).strip()[:200]

            new_entries.append(
                {
                    "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "to": session,
                    "sender": sender,
                    "original_ts": ts,
                    "age_min": round(age_min, 1),
                    "msg_summary": msg_summary,
                    "dedupe_key": dedupe_key,
                    "original_msg": msg,
                }
            )

if new_entries and not dry_run:
    with open(dead_letter_path, "a") as f:
        for entry in new_entries:
            f.write(json.dumps(entry) + "\n")

for entry in new_entries:
    print(
        "EMIT\t{}\t{}\t{}\t{}".format(
            entry["to"], entry["sender"], entry["age_min"], entry["msg_summary"]
        )
    )
print("COUNT\t{}".format(len(new_entries)))
PYEOF
)"

COUNT=0
while IFS=$'\t' read -r _tag a_to a_sender a_age a_summary; do
    case "$_tag" in
        EMIT)
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[a2a-dead-letter-reaper] (dry-run) would dead-letter: to=$a_to sender=$a_sender age_min=$a_age summary=$a_summary"
            else
                _emit "a2a_msg_dead_lettered" "$a_to" "$a_sender" "$a_age" "$a_summary"
                echo "[a2a-dead-letter-reaper] dead-lettered: to=$a_to sender=$a_sender age_min=$a_age"
            fi
            ;;
        COUNT)
            COUNT="$a_to"
            ;;
    esac
done <<<"$SCAN_OUT"

echo "[a2a-dead-letter-reaper] $COUNT message(s) dead-lettered this run (threshold=$PAGE_THRESHOLD, min_age=${MIN_AGE_MIN}m)"

if [[ "$DRY_RUN" -eq 0 && "$COUNT" -gt "$PAGE_THRESHOLD" ]]; then
    if [[ -x "$REPO_ROOT/scripts/dispatch/operator-recall.sh" ]]; then
        CHUMP_AMBIENT_LOG="$AMBIENT" "$REPO_ROOT/scripts/dispatch/operator-recall.sh" \
            --condition A2A_DEAD_LETTER_FLOOD \
            --reason "$COUNT messages dead-lettered in one a2a-dead-letter-reaper run (threshold=$PAGE_THRESHOLD) — dormant inboxes are piling up unread" \
            2>/dev/null || true
    fi
fi

exit 0
