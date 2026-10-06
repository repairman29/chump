#!/usr/bin/env bash
# scripts/coord/iter-agenda.sh — META-1034 (META-270 slice): ranked top-5 action
# generator for the fleet's next iteration.
#
# Reads four inputs and writes the 5 highest-ranked next actions, one JSON object
# per line, to .chump-locks/iter-agenda.jsonl (the file is REPLACED each run):
#   1. the current objective   .chump-locks/current-objective.json (chump objective)
#   2. open gaps               `chump gap list --status open --json`
#   3. recent ambient events   .chump-locks/ambient.jsonl (last 200 lines)
#   4. queue size              number of open gaps (override below)
#
# DETERMINISTIC: no wall-clock time, randomness or hash-order dependence in the
# output. Identical inputs produce a byte-identical file (ties break on the
# action id).
#
# Scoring (higher = sooner):
#   no objective set                         95  "set an objective"
#   queue below QUEUE_LOW                    85  "refill the queue"
#   ambient alert/failure kinds              80 + min(count,10)  "investigate <kind>"
#   open gap aligned with the objective      100 + 10*overlap + priority bonus
#   other open gap                           P0 90 / P1 70 / P2 40 / P3 20 (+5 for xs/s)
#   queue above QUEUE_HIGH                   60  "triage the backlog"
#
# Usage: scripts/coord/iter-agenda.sh [--stdout]     (--stdout also prints the rows)
#
# Env (all optional; mostly for tests):
#   CHUMP_OBJECTIVE_FILE           objective JSON (default <repo>/.chump-locks/current-objective.json)
#   CHUMP_ITER_AGENDA_GAPS_JSON    gap list JSON file, instead of `chump gap list`
#   CHUMP_AMBIENT_LOG              ambient log (default <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_ITER_AGENDA_QUEUE_SIZE   integer queue size, instead of the open-gap count
#   CHUMP_ITER_AGENDA_OUT          output file (default <repo>/.chump-locks/iter-agenda.jsonl)
#   CHUMP_ITER_AGENDA_QUEUE_LOW    default 3
#   CHUMP_ITER_AGENDA_QUEUE_HIGH   default 50
set -uo pipefail
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOCKS="$REPO_ROOT/.chump-locks"
OBJ="${CHUMP_OBJECTIVE_FILE:-$LOCKS/current-objective.json}"
AMB="${CHUMP_AMBIENT_LOG:-$LOCKS/ambient.jsonl}"
OUT="${CHUMP_ITER_AGENDA_OUT:-$LOCKS/iter-agenda.jsonl}"

if [[ -n "${CHUMP_ITER_AGENDA_GAPS_JSON:-}" ]]; then
    GAPS_JSON="$(cat "$CHUMP_ITER_AGENDA_GAPS_JSON" 2>/dev/null || echo '[]')"
else
    GAPS_JSON="$(chump gap list --status open --json 2>/dev/null || echo '[]')"
fi

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.tmp.$$"
GAPS_JSON="$GAPS_JSON" OBJ="$OBJ" AMB="$AMB" \
QUEUE_SIZE="${CHUMP_ITER_AGENDA_QUEUE_SIZE:-}" \
QUEUE_LOW="${CHUMP_ITER_AGENDA_QUEUE_LOW:-3}" QUEUE_HIGH="${CHUMP_ITER_AGENDA_QUEUE_HIGH:-50}" \
python3 - > "$TMP" <<'PY'
import collections, json, os, re

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

STOP = {"the", "and", "for", "with", "that", "this", "from", "into", "are", "was", "all",
        "gap", "chump", "add", "make", "slice", "child", "fleet"}

def tokens(text):
    return {t for t in re.findall(r"[a-z][a-z0-9]{2,}", (text or "").lower()) if t not in STOP}

try:
    gaps = json.loads(os.environ.get("GAPS_JSON") or "[]")
    if isinstance(gaps, dict):
        gaps = gaps.get("gaps", [])
except ValueError:
    gaps = []
gaps = [g for g in gaps if isinstance(g, dict) and g.get("id")
        and str(g.get("status", "open")).lower() == "open"]

obj = load_json(os.environ["OBJ"])
has_objective = isinstance(obj, dict) and obj.get("status") != "done"
obj_tokens = set()
if has_objective:
    obj_tokens = tokens(obj.get("text"))
    for c in obj.get("success_criteria") or []:
        obj_tokens |= tokens(c)

q = os.environ.get("QUEUE_SIZE", "").strip()
queue = int(q) if q.isdigit() else len(gaps)
q_low, q_high = int(os.environ["QUEUE_LOW"]), int(os.environ["QUEUE_HIGH"])

# ambient: last 200 lines; count alert-ish kinds.
alerts = collections.Counter()
try:
    with open(os.environ["AMB"], errors="replace") as f:
        lines = f.read().splitlines()[-200:]
except OSError:
    lines = []
for line in lines:
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if not isinstance(ev, dict):
        continue
    kind = str(ev.get("kind") or ev.get("event") or "")
    if re.search(r"alert|fail|red|stall|stuck|halt|exceeded|drift", kind, re.I):
        alerts[kind] += 1

cands = []  # (score, action_id, kind, ref, text, reason)
if not has_objective:
    cands.append((95, "objective:set", "objective", "",
                  "Set a fleet objective: chump objective set \"<text>\" --criterion \"<c>\"",
                  "no active objective"))
if queue < q_low:
    cands.append((85, "queue:refill", "queue", "",
                  f"Refill the queue ({queue} open gap(s)): file or decompose gaps toward the objective",
                  f"queue size {queue} < {q_low}"))
elif queue > q_high:
    cands.append((60, "queue:triage", "queue", "",
                  f"Triage the backlog ({queue} open gaps): close duplicates, re-prioritize",
                  f"queue size {queue} > {q_high}"))
for kind, n in alerts.items():
    cands.append((80 + min(n, 10), f"ambient:{kind}", "ambient", kind,
                  f"Investigate recent '{kind}' events ({n} in the last 200)",
                  f"{n} recent ambient event(s)"))
PRIO = {"P0": 90, "P1": 70, "P2": 40, "P3": 20}
for g in gaps:
    base = PRIO.get(str(g.get("priority", "")).upper(), 30)
    if str(g.get("effort", "")).lower() in ("xs", "s"):
        base += 5
    overlap = len(obj_tokens & tokens(f"{g.get('title', '')} {g.get('description', '')}")) if obj_tokens else 0
    if overlap:
        score = 100 + 10 * overlap + base // 10
        reason = f"aligned with the objective ({overlap} shared term(s)), {g.get('priority', '?')}"
    else:
        score, reason = base, f"{g.get('priority', '?')} open gap"
    cands.append((score, f"gap:{g['id']}", "gap", g["id"],
                  f"Work {g['id']}: {g.get('title', '')}".strip(), reason))

cands.sort(key=lambda c: (-c[0], c[1]))
for rank, (score, aid, kind, ref, text, reason) in enumerate(cands[:5], 1):
    print(json.dumps({"rank": rank, "score": score, "id": aid, "kind": kind, "ref": ref,
                      "action": text, "reason": reason}, sort_keys=True))
PY
rc=$?
if [[ $rc -ne 0 ]]; then rm -f "$TMP"; echo "iter-agenda: generator failed (rc=$rc)" >&2; exit 1; fi
mv "$TMP" "$OUT"
[[ "${1:-}" == "--stdout" ]] && cat "$OUT"
echo "iter-agenda: wrote $(wc -l < "$OUT" | tr -d ' ') action(s) to $OUT" >&2
exit 0
