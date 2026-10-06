#!/usr/bin/env bash
# META-1034: iter-agenda.sh reads objective + gaps + ambient + queue size, writes a
# ranked top-5 to iter-agenda.jsonl, and is deterministic for identical inputs.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$REPO_ROOT/scripts/coord/iter-agenda.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

cat > "$T/obj.json" <<'J'
{"objective_id":"OBJ-1","set_by":"t","set_at":"x","text":"Harden the picker policy","success_criteria":["picker policy tested"],"expected_completion":null,"status":"active"}
J
cat > "$T/gaps.json" <<'J'
[
 {"id":"A-1","title":"Unrelated docs cleanup","priority":"P1","effort":"s","status":"open"},
 {"id":"A-2","title":"Picker policy single source","priority":"P3","effort":"m","status":"open"},
 {"id":"A-3","title":"Another P2 thing","priority":"P2","effort":"m","status":"open"},
 {"id":"A-4","title":"P0 outage fix","priority":"P0","effort":"m","status":"open"},
 {"id":"A-5","title":"P3 nicety","priority":"P3","effort":"xs","status":"open"},
 {"id":"A-6","title":"Second P2","priority":"P2","effort":"s","status":"open"},
 {"id":"A-7","title":"Already done","priority":"P0","status":"done"}
]
J
printf '%s\n' '{"kind":"ci_failed","x":1}' '{"kind":"ci_failed"}' '{"kind":"heartbeat"}' 'not json' > "$T/amb.jsonl"
run() { # [VAR=val ...] ; writes $T/out.jsonl
  env CHUMP_REPO_ROOT="$T" CHUMP_OBJECTIVE_FILE="$T/obj.json" CHUMP_ITER_AGENDA_GAPS_JSON="$T/gaps.json" \
      CHUMP_AMBIENT_LOG="$T/amb.jsonl" CHUMP_ITER_AGENDA_OUT="$T/out.jsonl" "$@" bash "$GEN" 2>/dev/null
}
ids() { python3 -c "import json; print(','.join(json.loads(l)['id'] for l in open('$T/out.jsonl')))"; }

run; [[ $? -eq 0 ]] && ok "generator exits 0" || bad "generator failed"
[[ "$(wc -l < "$T/out.jsonl" | tr -d ' ')" == "5" ]] && ok "writes exactly the top 5" || bad "row count: $(wc -l < "$T/out.jsonl")"
[[ "$(ids | cut -d, -f1)" == "gap:A-2" ]] && ok "objective-aligned gap ranks first (even at P3)" || bad "order: $(ids)"
ids | grep -q 'gap:A-4' && ok "P0 gap makes the top 5" || bad "P0 missing: $(ids)"
ids | grep -q 'A-7' && bad "done gap leaked in" || ok "non-open gaps excluded"
ids | grep -q 'ambient:ci_failed' && ok "ambient alert kind produces an investigate action" || bad "ambient action missing: $(ids)"
python3 - "$T/out.jsonl" <<'PY' && ok "rows are ranked 1..5, score-descending, with required fields" || bad "row schema"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert [r["rank"] for r in rows] == [1, 2, 3, 4, 5]
assert all({"rank", "score", "id", "kind", "ref", "action", "reason"} <= set(r) for r in rows)
assert [r["score"] for r in rows] == sorted((r["score"] for r in rows), reverse=True)
PY

cp "$T/out.jsonl" "$T/first.jsonl"; run
cmp -s "$T/first.jsonl" "$T/out.jsonl" && ok "deterministic: identical inputs give byte-identical output" || bad "output changed between identical runs"

run CHUMP_OBJECTIVE_FILE="$T/none.json"
[[ "$(ids | cut -d, -f1)" == "objective:set" ]] && ok "no objective: 'set an objective' ranks first" || bad "no-objective order: $(ids)"
run CHUMP_ITER_AGENDA_QUEUE_SIZE=1
ids | grep -q 'queue:refill' && ok "tiny queue adds a refill action" || bad "refill missing: $(ids)"
run CHUMP_ITER_AGENDA_GAPS_JSON="$T/none.json" CHUMP_AMBIENT_LOG="$T/none.log"
[[ $? -eq 0 ]] && ok "empty gaps + no ambient: still succeeds" || bad "empty inputs crashed"

# META-1036: launchd schedule — 30-min cadence, RunAtLoad, runs the generator.
PLIST="$REPO_ROOT/scripts/launchd/com.chump.iter-agenda.plist"
python3 - "$PLIST" <<'PY' && ok "plist: label, 30-min StartInterval, RunAtLoad=true, runs iter-agenda.sh" || bad "plist schedule wrong"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == "com.chump.iter-agenda", d["Label"]
assert d["StartInterval"] == 1800, d["StartInterval"]
assert d["RunAtLoad"] is True
assert "scripts/coord/iter-agenda.sh" in " ".join(d["ProgramArguments"])
PY

echo "=== iter-agenda: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
