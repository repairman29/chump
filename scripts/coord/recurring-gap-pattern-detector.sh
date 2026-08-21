#!/usr/bin/env bash
# recurring-gap-pattern-detector.sh — INFRA-249 / RESILIENT-365
#
# Surfaces clusters of recently-filed gaps that share significant title
# keywords, signaling a meta-pattern that probably deserves a META-* RCA gap
# covering the class.
#
# Why: reactive filing (file the symptom you observed) misses recurring
# patterns because each incident looks unique in the moment. Per AGENTS.md
# "Filing meta-patterns" section, the periodic RCA pass catches what flow-
# mode misses. This script automates the cluster-detection half so the human
# RCA pass becomes "review the ALERT list" instead of "scan from memory."
#
# RESILIENT-365: the detector was DARK (0 organ units) — it only emitted a
# human-facing ALERT line and stopped there. Nothing opened the RCA, nothing
# filed the root gap, nothing stopped the next symptom PR from shipping.
# This turns the ALERT into a reflex:
#   1. Detect cluster (unchanged INFRA-249 logic above)
#   2. Idempotently file a META RCA gap for the cluster (dedup by keyword,
#      state tracked in pattern-detector-state.json — mirrors
#      cluster-detector.sh's INFRA-1987 dedup pattern)
#   3. Write a symptom-cluster hold record so `gap-reserve.sh` can block (or
#      require explicit linkage to) further gaps that match the same
#      keyword while the RCA is still open — see
#      scripts/coord/gap-pattern-hold-check.sh
#
# Algorithm (deliberately simple):
#   1. Walk docs/gaps/<ID>.yaml, parse opened_date + title for each gap
#   2. Filter to last N days (default 7)
#   3. Tokenize titles: lowercase, drop stopwords, keep words ≥4 chars
#   4. Count keyword frequency across the window
#   5. Cluster = keyword appearing in ≥THRESHOLD gaps (default 3)
#   6. Print + emit ambient ALERT line per cluster
#   7. File (or update) the cluster's META RCA gap + write the hold record
#
# Usage:
#   recurring-gap-pattern-detector.sh [--days 7] [--threshold 3] [--quiet] [--no-rca]
#
# Env:
#   CHUMP_PATTERN_DETECTOR_QUIET=1     # same as --quiet (suppresses stdout, only emits ALERTs)
#   CHUMP_PATTERN_DETECTOR_ALERT_ONLY=1    # same as --no-rca (skip gap-filing + hold reflex; ALERT only)
#   CHUMP_AMBIENT_LOG=<path>           # override ambient.jsonl path (test fixture uses this)
#   CHUMP_PATTERN_DETECTOR_STATE=<path> # override state file path (test fixture uses this)
#   CHUMP_PATTERN_DETECTOR_HOLD=<path>  # override hold file path (test fixture uses this)

set -euo pipefail

DAYS=7
THRESHOLD=3
QUIET=0
NO_RCA=0
if [ "${CHUMP_PATTERN_DETECTOR_QUIET:-}" = "1" ]; then
    QUIET=1
fi
if [ "${CHUMP_PATTERN_DETECTOR_ALERT_ONLY:-}" = "1" ]; then
    NO_RCA=1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --days)      DAYS="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --quiet)     QUIET=1; shift ;;
        --no-rca)    NO_RCA=1; shift ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GAPS_DIR="$REPO_ROOT/docs/gaps"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_FILE="${CHUMP_PATTERN_DETECTOR_STATE:-$REPO_ROOT/.chump-locks/pattern-detector-state.json}"
HOLD_FILE="${CHUMP_PATTERN_DETECTOR_HOLD:-$REPO_ROOT/.chump-locks/pattern-detector-hold.json}"

if [ ! -d "$GAPS_DIR" ]; then
    echo "[pattern-detector] ERROR: $GAPS_DIR not found" >&2
    exit 1
fi

# Cutoff date: today minus DAYS.
if [ "$(uname -s)" = "Darwin" ]; then
    CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%d)
else
    CUTOFF=$(date -u -d "$DAYS days ago" +%Y-%m-%d)
fi
TODAY=$(date -u +%Y-%m-%d)

# Stopwords (common English + Chump jargon that shouldn't anchor a cluster).
# Keep this list small — false positives from over-aggressive stopwording are
# worse than a few noise clusters. Items here are words that appear in many
# gap titles regardless of topic.
STOPWORDS="the and for with from into onto upon over under than that this those these when where what which who whom how why because while during after before above below between among through within without your their there here gaps gap have been into onto over still need needs needed should would could might must will may shall pass fails fail does did done from chump claude cursor goose aider tool tools test tests gone open close closed status field fields make made like more most less item items thing things path paths name names line lines infra only also even just both"

is_stopword() {
    case " $STOPWORDS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Walk recent gaps, build keyword → count + IDs map in a temp file.
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
COUNTS_FILE="$TMPDIR_BASE/counts"
touch "$COUNTS_FILE"

recent_gap_count=0

for yaml_path in "$GAPS_DIR"/*.yaml; do
    [ -f "$yaml_path" ] || continue
    gap_id="$(basename "$yaml_path" .yaml)"

    opened="$(awk '/^[[:space:]]*opened_date:/ {gsub(/[[:space:]]*opened_date:[[:space:]]*/,""); gsub(/[[:space:]'\''"]+/,""); print; exit}' "$yaml_path" 2>/dev/null || true)"

    # Only consider gaps with an opened_date in the window. Gaps with no
    # opened_date (legacy / pre-INFRA-188) are skipped — they're old.
    [ -n "$opened" ] || continue

    if ! [ "$opened" \> "$CUTOFF" ] && [ "$opened" != "$CUTOFF" ]; then
        continue
    fi

    recent_gap_count=$((recent_gap_count + 1))

    title="$(awk '/^[[:space:]]*title:/ {sub(/^[[:space:]]*title:[[:space:]]*/,""); gsub(/^["'\'']/,""); gsub(/["'\'']$/,""); print; exit}' "$yaml_path" 2>/dev/null || true)"
    [ -n "$title" ] || continue

    # Tokenize: lowercase, replace non-alpha with spaces, split.
    tokens=$(echo "$title" | tr 'A-Z' 'a-z' | tr -c 'a-z' ' ')
    for tok in $tokens; do
        # Filter: ≥4 chars, not a stopword.
        [ ${#tok} -ge 4 ] || continue
        if is_stopword "$tok"; then continue; fi
        echo "$tok|$gap_id" >> "$COUNTS_FILE"
    done
done

if [ "$QUIET" -eq 0 ]; then
    echo "[pattern-detector] scanned $recent_gap_count gaps opened in last $DAYS days"
fi

# ── RESILIENT-365 reflex: idempotently file the RCA gap + write the hold ────
# record for a detected cluster. Dedup is keyed by keyword in STATE_FILE so
# a keyword that's still clustering doesn't refile a new RCA gap every run —
# the existing RCA gap's id + gap_ids list are just refreshed.
_file_or_update_rca_gap() {
    keyword="$1"
    cnt="$2"
    id_list="$3"

    existing_gap=""
    if [ -f "$STATE_FILE" ]; then
        existing_gap="$(python3 -c '
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
k = s.get("keywords", {}).get(sys.argv[2])
if k:
    print(k.get("gap_id", ""))
' "$STATE_FILE" "$keyword" 2>/dev/null || true)"
    fi

    gap_id="$existing_gap"
    if [ -z "$gap_id" ]; then
        title="RCA: recurring gap pattern \"$keyword\" — $cnt gaps in ${DAYS}d [$id_list]"
        gap_id="$(CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            chump gap reserve --domain META \
                --title "$title" --priority P1 --effort s \
                --force-duplicate 2>/dev/null | tail -1)"
        gap_id="${gap_id:-UNFILED}"
        if [ "$QUIET" -eq 0 ]; then
            echo "[pattern-detector] RCA: filed $gap_id for keyword \"$keyword\" ($cnt gaps: $id_list)" >&2
        fi
    else
        if [ "$QUIET" -eq 0 ]; then
            echo "[pattern-detector] RCA: keyword \"$keyword\" already has $gap_id — refreshing" >&2
        fi
    fi

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    python3 -c '
import json, sys
path, keyword, gap_id, ts, cnt, id_list = sys.argv[1:7]
try:
    s = json.load(open(path))
except Exception:
    s = {"keywords": {}}
s.setdefault("keywords", {})
prev = s["keywords"].get(keyword, {})
s["keywords"][keyword] = {
    "gap_id": gap_id,
    "first_seen": prev.get("first_seen", ts),
    "last_seen": ts,
    "gap_count": int(cnt),
    "gap_ids": id_list,
}
json.dump(s, open(path, "w"), indent=2)
' "$STATE_FILE" "$keyword" "$gap_id" "$ts" "$cnt" "$id_list" 2>/dev/null || true

    # Block symptom cluster: write/refresh the hold record so gap-reserve.sh
    # (via gap-pattern-hold-check.sh) can require new gaps that still match
    # this keyword to reference the RCA gap instead of shipping the next
    # symptom PR blind.
    mkdir -p "$(dirname "$HOLD_FILE")" 2>/dev/null || true
    python3 -c '
import json, sys
path, keyword, gap_id, ts, cnt, id_list = sys.argv[1:7]
try:
    h = json.load(open(path))
except Exception:
    h = {"holds": {}}
h.setdefault("holds", {})
h["holds"][keyword] = {
    "rca_gap": gap_id,
    "since": ts,
    "gap_count": int(cnt),
    "gap_ids": id_list,
    "advisory": "New gaps titled with \"" + keyword + "\" should reference " + gap_id + " (depends_on) instead of filing another symptom.",
}
json.dump(h, open(path, "w"), indent=2)
' "$HOLD_FILE" "$keyword" "$gap_id" "$ts" "$cnt" "$id_list" 2>/dev/null || true

    ralert_line=$(printf '{"ts":"%s","session":"%s","worktree":"%s","kind":"recurring_gap_pattern_rca_filed","keyword":"%s","gap_count":%d,"window_days":%d,"gap_ids":"%s","rca_gap":"%s"}' \
        "$ts" "${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-pattern-detector}}" "$(basename "$REPO_ROOT")" "$keyword" "$cnt" "$DAYS" "$id_list" "$gap_id")
    echo "$ralert_line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# Group by keyword, count distinct gap IDs per keyword.
clusters_found=0
sort -u "$COUNTS_FILE" | awk -F'|' '
    { count[$1]++; ids[$1] = ids[$1] "," $2 }
    END {
        for (k in count) {
            if (count[k] >= '"$THRESHOLD"') {
                gsub(/^,/, "", ids[k])
                print count[k] "\t" k "\t" ids[k]
            }
        }
    }
' | sort -rn | while IFS=$'\t' read -r cnt keyword id_list; do
    clusters_found=$((clusters_found + 1))
    if [ "$QUIET" -eq 0 ]; then
        echo "[pattern-detector] CLUSTER: \"$keyword\" appears in $cnt gaps in last $DAYS days: $id_list"
    fi
    # Emit ambient ALERT line — JSON shape matches the adversary alert /
    # closer-batcher convention. Best-effort; failure here doesn't fail
    # the script.
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    session=${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-pattern-detector}}
    line=$(printf '{"ts":"%s","session":"%s","worktree":"%s","event":"ALERT","kind":"recurring_gap_pattern","keyword":"%s","gap_count":%d,"window_days":%d,"gap_ids":"%s","note":"%d gaps in last %d days share keyword \"%s\" — consider META-* RCA gap covering the class"}' \
        "$ts" "$session" "$(basename "$REPO_ROOT")" "$keyword" "$cnt" "$DAYS" "$id_list" "$cnt" "$DAYS" "$keyword")
    echo "$line" >> "$AMBIENT_LOG" 2>/dev/null || true

    # RESILIENT-365: turn the ALERT into a reflex — file the RCA gap and
    # write the symptom-cluster hold record. Best-effort: failures here
    # (chump binary unavailable, python3 missing) must not fail the sweep.
    if [ "$NO_RCA" -eq 0 ]; then
        _file_or_update_rca_gap "$keyword" "$cnt" "$id_list" || true
    fi
done

if [ "$QUIET" -eq 0 ] && [ "$clusters_found" -eq 0 ]; then
    echo "[pattern-detector] no clusters found (threshold=$THRESHOLD)"
fi

exit 0
