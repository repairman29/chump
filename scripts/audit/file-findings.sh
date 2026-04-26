#!/usr/bin/env bash
# scripts/audit/file-findings.sh — read JSONL findings on stdin (or --in PATH),
# dedup against previously-filed auditor gaps, and file new ones via
# `chump gap reserve`. Updates a strike-count for re-occurring findings — at the
# 5-strike threshold, marks the strike entry for manual escalation (chump gap CLI
# does not currently support priority editing post-reserve).
#
# Strike + dedup storage: .chump/auditor-strikes.json. Schema:
#   { "<finding-key>": { "count": int, "gap_id": str|null, "first_seen": iso8601 } }
# Same finding key maps to the same gap_id across runs. If chump gap list shows
# the gap as no longer open, the entry is treated as un-filed (re-filing is
# desirable — it forces a fresh decision).
#
# Usage:
#   scripts/audit/run-auditor.sh | scripts/audit/file-findings.sh
#   scripts/audit/file-findings.sh --in .chump/auditor-findings-*.jsonl
#   scripts/audit/file-findings.sh --dry-run < findings.jsonl
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

IN_FILE="-"
DRY_RUN=0
ESCALATION_STRIKES="${CHUMP_AUDITOR_ESCALATION_STRIKES:-5}"
MAX_FILES="${CHUMP_AUDITOR_MAX_FILES:-25}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --in) IN_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --escalation-strikes) ESCALATION_STRIKES="$2"; shift 2 ;;
        --max-files) MAX_FILES="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p .chump
STRIKES_FILE=".chump/auditor-strikes.json"
[ -f "$STRIKES_FILE" ] || echo '{}' >"$STRIKES_FILE"

# Pull current open-gap set so we can confirm a key's recorded gap_id is still alive.
GAPS_JSON_FILE="$(mktemp)"
trap 'rm -f "$GAPS_JSON_FILE"' EXIT

if command -v chump >/dev/null 2>&1; then
    chump gap list --json 2>/dev/null >"$GAPS_JSON_FILE"
else
    echo '[]' >"$GAPS_JSON_FILE"
fi

# Read findings
if [ "$IN_FILE" = "-" ]; then
    INPUT="$(cat)"
else
    INPUT="$(cat "$IN_FILE")"
fi

[ -z "$INPUT" ] && { echo "[file-findings] no input findings; exiting." >&2; exit 0; }

filed=0
bumped=0
escalated=0
skipped=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["key"])' 2>/dev/null || true)"
    [ -z "$key" ] && continue

    # Lookup any previously-recorded gap_id for this key, and bump the strike count.
    lookup="$(STRIKES_FILE="$STRIKES_FILE" KEY="$key" GAPS_JSON="$GAPS_JSON_FILE" python3 -c '
import json, os
from datetime import datetime, timezone
p = os.environ["STRIKES_FILE"]
k = os.environ["KEY"]
gp = os.environ["GAPS_JSON"]
with open(p) as f: strikes = json.load(f)
with open(gp) as f: gaps = json.load(f)
open_ids = {g["id"] for g in gaps if g.get("status") == "open"}
e = strikes.get(k)
if e is None or isinstance(e, int):
    # Migrate legacy int form to new dict form.
    e = {"count": e if isinstance(e, int) else 0, "gap_id": None, "first_seen": datetime.now(timezone.utc).isoformat()}
e["count"] = int(e.get("count", 0)) + 1
gid = e.get("gap_id")
existing_id = gid if (gid and gid in open_ids) else ""
strikes[k] = e
with open(p, "w") as f: json.dump(strikes, f, indent=2, sort_keys=True)
print(str(e["count"]) + "\t" + existing_id)
')"
    new_count="${lookup%%	*}"
    existing_id="${lookup#*	}"

    if [ -n "$existing_id" ]; then
        bumped=$((bumped + 1))
        if [ "$new_count" -ge "$ESCALATION_STRIKES" ]; then
            # chump CLI lacks --priority editing; flag escalation in stderr +
            # leave a marker in the strikes file so the human reviewer sees it.
            echo "[file-findings] ESCALATE: $existing_id has $new_count strikes — consider P1 (chump CLI lacks priority edit)" >&2
            escalated=$((escalated + 1))
        fi
        continue
    fi

    title="$(printf '%s' "$line"  | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["title"][:69])')"
    domain="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["domain"])')"
    prio="$(printf '%s' "$line"   | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["priority"])')"
    effort="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["effort"])')"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[file-findings] DRY: would file [$domain] '$title' (P=$prio E=$effort key=$key)" >&2
        skipped=$((skipped + 1))
        continue
    fi

    if [ "$filed" -ge "$MAX_FILES" ]; then
        echo "[file-findings] cap reached (--max-files=$MAX_FILES); deferring '$title' to next cycle" >&2
        skipped=$((skipped + 1))
        continue
    fi

    new_id="$(chump gap reserve --domain "$domain" --title "$title" --priority "$prio" --effort "$effort" 2>/dev/null | tail -1)"
    if [ -z "$new_id" ] || [ "${new_id#*-}" = "$new_id" ]; then
        echo "[file-findings] WARN: gap reserve failed for key=$key" >&2
        skipped=$((skipped + 1))
        continue
    fi

    # Record the key -> gap_id mapping in the strikes file (canonical dedup index).
    STRIKES_FILE="$STRIKES_FILE" KEY="$key" GAP_ID="$new_id" python3 -c '
import json, os
p = os.environ["STRIKES_FILE"]
k = os.environ["KEY"]
gid = os.environ["GAP_ID"]
with open(p) as f: strikes = json.load(f)
e = strikes.get(k, {"count": 1})
if isinstance(e, int): e = {"count": e}
e["gap_id"] = gid
strikes[k] = e
with open(p, "w") as f: json.dump(strikes, f, indent=2, sort_keys=True)
'

    echo "[file-findings] filed $new_id ($title) [key=$key]" >&2
    filed=$((filed + 1))
done <<<"$INPUT"

printf '[file-findings] summary: filed=%d bumped=%d escalated=%d skipped=%d\n' "$filed" "$bumped" "$escalated" "$skipped" >&2
