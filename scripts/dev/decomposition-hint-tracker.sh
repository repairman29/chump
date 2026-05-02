#!/usr/bin/env bash
# decomposition-hint-tracker.sh — FLEET-026 (FLEET-011 v1).
#
# v0 (FLEET-025) emits ambient `decomposition_hint` events from bot-merge.sh
# when a PR exceeds size thresholds. This script reads those events, resolves
# each one against `gh pr list` to determine outcome, and writes a
# normalized row per hint to `.chump/decomposition-outcomes.jsonl`.
#
# Outcomes recorded per hint:
#   - heeded:           hint's branch produced no PR; smaller PRs from same gap
#                       appeared within 6h (operator split before pushing)
#   - landed_clean:     PR landed; no fix-up PR for the same gap within 24h
#                       (signal: the heuristic was a false alarm)
#   - landed_followup:  PR landed; ≥1 fix-up PR for the same gap within 24h
#                       (signal: the heuristic correctly flagged a problem)
#   - pending:          PR still open / hint < 24h old (re-evaluated next run)
#   - skipped:          gap_id missing or unparseable (data-quality issue)
#
# Summary output to stdout:
#   - n_hints           total hints processed
#   - heeded_rate       heeded / (heeded + landed_*)
#   - revealed_correct_rate  landed_followup / (landed_clean + landed_followup)
#
# Usage:
#   scripts/dev/decomposition-hint-tracker.sh                  # process all unresolved
#   scripts/dev/decomposition-hint-tracker.sh --since 7d       # only last 7 days
#   scripts/dev/decomposition-hint-tracker.sh --reset          # clear outcomes file
#
# Designed to run daily via launchd (see scripts/setup/install-decomposition-tracker-launchd.sh).
# Idempotent: outcomes file is keyed by hint timestamp + branch, so reruns
# only update pending → resolved transitions.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then MAIN_REPO="$REPO_ROOT"; else MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"; fi

LOCK_DIR="$MAIN_REPO/.chump-locks"
CHUMP_DIR="$MAIN_REPO/.chump"
OUTCOMES_FILE="$CHUMP_DIR/decomposition-outcomes.jsonl"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

mkdir -p "$CHUMP_DIR"

SINCE_ARG=""
RESET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE_ARG="$2"; shift 2 ;;
        --reset) RESET=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ "$RESET" -eq 1 ]]; then
    : > "$OUTCOMES_FILE"
    echo "[decomposition-tracker] reset $OUTCOMES_FILE" >&2
fi

# ── Pull all decomposition_hint events from ambient (live + archives) ───────
HINT_EVENTS_TMP="$(mktemp -t decomp-hints.XXXXXX)"
trap 'rm -f "$HINT_EVENTS_TMP" "${PRJSON:-}" "${OUTCOMES_TMP:-}"' EXIT

if [[ -n "$SINCE_ARG" ]]; then
    bash "$REPO_ROOT/scripts/dev/ambient-query.sh" decomposition_hint --since "$SINCE_ARG" \
        > "$HINT_EVENTS_TMP" 2>/dev/null || true
else
    bash "$REPO_ROOT/scripts/dev/ambient-query.sh" decomposition_hint \
        > "$HINT_EVENTS_TMP" 2>/dev/null || true
fi

N_HINTS="$(wc -l < "$HINT_EVENTS_TMP" | tr -d ' ')"
if [[ "$N_HINTS" -eq 0 ]]; then
    echo "[decomposition-tracker] no decomposition_hint events found"
    echo "[decomposition-tracker] (FLEET-025 v0 emits these; check that PR has landed)"
    exit 0
fi

# ── Pull current PR state once (network call) ───────────────────────────────
PRJSON="$(mktemp -t prlist.XXXXXX)"
gh pr list --state all --limit 200 \
    --json number,title,state,headRefName,mergeCommit,mergedAt,createdAt,updatedAt \
    > "$PRJSON" 2>/dev/null || echo '[]' > "$PRJSON"

# ── Classify each hint + write outcomes ─────────────────────────────────────
OUTCOMES_TMP="$(mktemp -t outcomes.XXXXXX)"
python3 - "$HINT_EVENTS_TMP" "$PRJSON" "$OUTCOMES_FILE" "$OUTCOMES_TMP" <<'PYEOF'
import json, sys, datetime, collections

hints_path, prjson_path, outcomes_path, out_tmp = sys.argv[1:5]

with open(prjson_path) as f:
    prs = json.load(f)
# Index PRs by branch + by gap (extracted from title)
pr_by_branch = {p["headRefName"]: p for p in prs}
pr_by_gap = collections.defaultdict(list)
import re as _re
GAP_RE = _re.compile(r'\b([A-Z]+-\d{1,4})\b')
for p in prs:
    title = p.get("title") or ""
    for gid in GAP_RE.findall(title):
        pr_by_gap[gid].append(p)

# Existing outcomes (keyed by ts+branch)
existing = {}
try:
    with open(outcomes_path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                row = json.loads(line)
                key = (row.get("hint_ts"), row.get("branch"))
                existing[key] = row
            except Exception:
                continue
except FileNotFoundError:
    pass

now = datetime.datetime.now(datetime.timezone.utc)

def parse_iso(s):
    if not s: return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z","+00:00"))
    except Exception:
        return None

new_outcomes = {}
n_processed = 0
for line in open(hints_path):
    line = line.strip()
    if not line: continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    if ev.get("event") != "decomposition_hint":
        continue
    n_processed += 1
    hint_ts = ev.get("ts","")
    # bot-merge.sh emits the hint with extra fields packed via ambient-emit.sh
    # which surfaces them as top-level keys. Tolerate either packing.
    branch  = ev.get("branch") or ev.get("worktree") or ""
    gap_id  = ev.get("gap")    or ev.get("gap_id")   or ""
    files   = int(ev.get("files",0) or 0)
    loc     = int(ev.get("loc",0)   or 0)
    key = (hint_ts, branch)

    # Already resolved? skip re-classification
    if key in existing and existing[key].get("outcome") not in (None,"pending"):
        new_outcomes[key] = existing[key]
        continue

    pr = pr_by_branch.get(branch)
    hint_dt = parse_iso(hint_ts)
    age_h = (now - hint_dt).total_seconds() / 3600 if hint_dt else 0

    outcome = "pending"
    note = ""

    if pr is None:
        # Branch has no PR (yet). If gap has ≥2 smaller PRs since hint, count as heeded.
        related = [p for p in pr_by_gap.get(gap_id, []) if parse_iso(p.get("createdAt") or "") and parse_iso(p["createdAt"]) > (hint_dt or now)]
        if len(related) >= 2:
            outcome = "heeded"
            note = f"gap {gap_id} produced {len(related)} smaller PR(s) after hint"
        elif age_h > 24:
            outcome = "skipped"
            note = "no PR from branch; no related PRs after 24h — likely abandoned"
        else:
            outcome = "pending"
            note = f"no PR yet ({age_h:.1f}h old)"
    elif pr.get("state") != "MERGED":
        outcome = "pending"
        note = f"PR #{pr['number']} still {pr.get('state','?')}"
    else:
        # PR merged. Look for fix-up PRs same gap, within 24h after merge.
        merged_at = parse_iso(pr.get("mergedAt") or "")
        if not merged_at:
            outcome = "pending"
            note = "PR merged but mergedAt unreadable"
        elif (now - merged_at).total_seconds() / 3600 < 24:
            outcome = "pending"
            note = f"PR #{pr['number']} merged {((now-merged_at).total_seconds()/3600):.1f}h ago — fix-up window not closed"
        else:
            followups = [p for p in pr_by_gap.get(gap_id, [])
                         if p["number"] != pr["number"]
                         and parse_iso(p.get("createdAt") or "")
                         and parse_iso(p["createdAt"]) > merged_at
                         and (parse_iso(p["createdAt"]) - merged_at).total_seconds() < 24*3600]
            if followups:
                outcome = "landed_followup"
                note = f"PR #{pr['number']} landed; {len(followups)} fix-up PR(s) within 24h — heuristic correctly flagged"
            else:
                outcome = "landed_clean"
                note = f"PR #{pr['number']} landed clean; no fix-up — heuristic was a false alarm"

    row = {
        "hint_ts": hint_ts, "branch": branch, "gap_id": gap_id,
        "files": files, "loc": loc,
        "outcome": outcome, "note": note,
        "resolved_at": now.strftime("%Y-%m-%dT%H:%M:%SZ") if outcome != "pending" else None,
    }
    new_outcomes[key] = row

with open(out_tmp, "w") as f:
    for row in new_outcomes.values():
        f.write(json.dumps(row) + "\n")

# Summary stats
counts = collections.Counter(r["outcome"] for r in new_outcomes.values())
heeded = counts.get("heeded", 0)
clean  = counts.get("landed_clean", 0)
followup = counts.get("landed_followup", 0)
pending = counts.get("pending", 0)
skipped = counts.get("skipped", 0)
total_resolved = heeded + clean + followup
heeded_rate = heeded / total_resolved if total_resolved else 0.0
correct_rate = followup / (clean + followup) if (clean + followup) else 0.0

print(f"[decomposition-tracker] processed {n_processed} hint event(s)", file=sys.stderr)
print(f"[decomposition-tracker]   heeded:          {heeded}")
print(f"[decomposition-tracker]   landed_clean:    {clean}  (false alarm)")
print(f"[decomposition-tracker]   landed_followup: {followup}  (heuristic correct)")
print(f"[decomposition-tracker]   pending:         {pending}")
print(f"[decomposition-tracker]   skipped:         {skipped}")
print(f"[decomposition-tracker]   heeded-rate:           {heeded_rate:.0%}  (operator splits before pushing)")
print(f"[decomposition-tracker]   revealed-correct-rate: {correct_rate:.0%}  (ignored hints that needed fix-up)")
print()
print(f"[decomposition-tracker] tuning guidance:")
if total_resolved < 10:
    print(f"  not enough data yet (n={total_resolved} resolved); collect more hints first")
elif correct_rate < 0.30:
    print(f"  revealed-correct rate {correct_rate:.0%} < 30% — heuristic is over-firing; consider raising thresholds")
elif correct_rate > 0.70:
    print(f"  revealed-correct rate {correct_rate:.0%} > 70% — heuristic is missing real problems; consider lowering thresholds")
else:
    print(f"  revealed-correct rate {correct_rate:.0%} in healthy band [30%, 70%]; thresholds look OK")
PYEOF

# Atomic replace
mv "$OUTCOMES_TMP" "$OUTCOMES_FILE"
echo "[decomposition-tracker] outcomes written to $OUTCOMES_FILE" >&2
