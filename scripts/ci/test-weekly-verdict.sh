#!/usr/bin/env bash
# META-1047: weekly-verdict.py composes mission-grade + roadmap-status +
# mission-scoreboard + the factory matrix into ONE verdict (<=3 organ-tagged items,
# synthesis only), APPROVAL on a clean run, delivered weekly to FLEET-RADIO, and the
# first run reproduces the 2026-08-07 outcome-table finding. Fixture inputs; no network.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WV="$ROOT/scripts/coord/weekly-verdict.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── Fixture sources ──────────────────────────────────────────────────────────
grade() { # <effective-grade> <zero-waste-grade>
  printf '{"kind":"mission_grade","effective":{"grade":"%s","count_pickable":3,"count_in_flight":0},"credible":{"grade":"A","count_pickable":4,"count_in_flight":0},"resilient":{"grade":"A","count_pickable":2,"count_in_flight":0},"zero_waste":{"grade":"%s","count_pickable":0,"count_in_flight":1}}' "$1" "$2"
}
# roadmap-status JSON as emitted by META-1045: the 2026-08-07 product-lighthouse 0/0/1 case.
cat > "$T/road-drift.json" <<'J'
{"kind":"roadmap_status","weeks":[],"starved_outcomes":[3],"untraced_p0":["X-1","X-2"],"pillar_coverage":{},
 "outcome_drift":[
  {"outcome_id":"PRODUCT-LH-1","title":"Smuggler","kind":"no_open_gaps","detail":"has a stated definition of done but zero open gaps","open_children":0},
  {"outcome_id":"PRODUCT-LH-2","title":"Olive","kind":"no_open_gaps","detail":"has a stated definition of done but zero open gaps","open_children":0},
  {"outcome_id":"PRODUCT-LH-3","title":"Games","kind":"all_unpickable","detail":"all 1 open gap(s) unpickable: PRODUCT-101 blocked by PRODUCT-100","open_children":1}]}
J
echo '{"kind":"roadmap_status","weeks":[],"starved_outcomes":[],"untraced_p0":[],"outcome_drift":[]}' > "$T/road-clean.json"
printf '═══ VERDICT ═══\n  🟠 DRIFTING — fleet ships but fixes don'"'"'t DEPLOY (MISSION-012).\n' > "$T/sb-drift.txt"
printf '═══ VERDICT ═══\n  🟡 ON-TRACK — mission-weighted + deploying.\n' > "$T/sb-ok.txt"
cat > "$T/matrix.md" <<'M'
# The Software-Factory Matrix

## 1. Matrix — factory layers vs Chump today

| Factory layer | What Chump has | Status | Receipt |
|---|---|---|---|
| **L3 Design** (UI) | a CSS lint | ❌ | gap |
| **L2 Architecture** | RFCs | 🟠 | docs |
| **L6 Operations** | self-deploy | ✅ for itself / 🟠 for shipped products | scoreboard |
| **L4 Engineering** | workers | ✅ | crates |

## 2. Another table

| **L9 Bogus** | x | ❌ | y |
M
grade A A > "$T/grade-ok.json"; grade A A | sed 's/"zero_waste":{"grade":"A"/"zero_waste":{"grade":"A"/' > "$T/grade-clean.json"
grade A F > "$T/grade-f.json"
printf '# matrix with every layer healthy\n\n## 1. Matrix\n\n| Layer | has | Status | r |\n|---|---|---|---|\n| **L4 Engineering** | w | ✅ | c |\n' > "$T/matrix-clean.md"

run() { python3 "$WV" --repo "$T" --shadow-dir "$T/shadow" --ambient "$T/ambient.jsonl" --today 2026-08-07 "$@" 2>"$T/err.txt"; }

# ── 1. Reproduces the 2026-08-07 outcome-table finding, capped at three, organ-tagged ───
out="$(run --no-deliver --mission-grade "$T/grade-f.json" --roadmap-status "$T/road-drift.json" --scoreboard "$T/sb-drift.txt" --matrix "$T/matrix.md")"
n="$(grep -c '^  [0-9]\. \[' <<<"$out")"
[[ "$n" == "3" ]] && grep -q 'thing(s) worth changing' <<<"$out" && ok "at most three things, even with 9+ candidate findings" || bad "item count $n: $out"
grep -q '\[roadmap-status\] Outcome PRODUCT-LH-1 has a stated definition of done but zero open gaps' <<<"$out" \
  && grep -q '\[roadmap-status\] Outcome PRODUCT-LH-2 has a stated definition of done but zero open gaps' <<<"$out" \
  && ok "first run reproduces the 2026-08-07 outcome-table finding (0/0/1 lighthouse outcomes)" || bad "outcome-table finding missing: $out"
grep -qE '^  [0-9]\. \[(roadmap-status|mission-scoreboard|mission-grade|factory-matrix)\] ' <<<"$out" \
  && ! grep -qE '^  [0-9]\. [^[]' <<<"$out" && ok "every line carries the organ that produced it" || bad "untagged line: $out"
head -2 <<<"$out" | tail -1 | grep -q 'PRODUCT-LH-1\|PRODUCT-LH-2\|PRODUCT-LH-3\|Scoreboard' && ok "ranked by severity (outcome-table / scoreboard drift lead)" || bad "ranking: $out"

# ── 2. Every item traces to a mechanical check from a source; nothing invented ──────────
out2="$(run --no-deliver --mission-grade "$T/grade-f.json" --roadmap-status "$T/road-clean.json" --scoreboard "$T/sb-ok.txt" --matrix "$T/matrix.md")"
grep -q '\[mission-grade\] Pillar ZERO-WASTE is graded F' <<<"$out2" && grep -q '\[factory-matrix\] Factory matrix: L3 Design is missing' <<<"$out2" \
  && grep -q 'L2 Architecture is thin' <<<"$out2" && ! grep -q 'L9 Bogus' <<<"$out2" && ! grep -q 'L6 Operations' <<<"$out2" \
  && ok "grade F and matrix ❌/🟠 rows are synthesised (second table ignored; mixed ✅/🟠 row is not 'thin')" || bad "synthesis: $out2"

# ── 3. A clean run emits an explicit APPROVAL and stops ──────────────────────────────────
out3="$(run --no-deliver --mission-grade "$T/grade-ok.json" --roadmap-status "$T/road-clean.json" --scoreboard "$T/sb-ok.txt" --matrix "$T/matrix-clean.md")"
[[ "$(wc -l <<<"$out3" | tr -d ' ')" == "1" ]] && grep -q 'WEEKLY VERDICT — 2026-W32 — APPROVAL' <<<"$out3" \
  && ok "clean run: one explicit APPROVAL line and nothing else" || bad "approval: $out3"

# ── 4. Unreadable sources are reported UNAVAILABLE, never treated as clean ───────────────
run --no-deliver --mission-grade "$T/missing.json" --roadmap-status "$T/road-clean.json" --scoreboard "$T/sb-ok.txt" --matrix "$T/matrix-clean.md" >/dev/null
grep -q 'mission-grade: UNAVAILABLE' "$T/err.txt" && ok "an unreadable organ is reported UNAVAILABLE on stderr" || bad "no UNAVAILABLE notice: $(cat "$T/err.txt")"

# ── 5. Delivery: weekly to FLEET-RADIO (board.log), once per ISO week ────────────────────
run --mission-grade "$T/grade-f.json" --roadmap-status "$T/road-drift.json" --scoreboard "$T/sb-drift.txt" --matrix "$T/matrix.md" >/dev/null
[[ -f "$T/shadow/board.log" ]] && grep -q 'WEEKLY VERDICT — 2026-W32' "$T/shadow/board.log" && [[ "$(wc -l < "$T/shadow/board.log" | tr -d ' ')" == "1" ]] \
  && ok "delivered to FLEET-RADIO's board.log pickup as one line" || bad "board.log: $(cat "$T/shadow/board.log" 2>/dev/null)"
run --mission-grade "$T/grade-f.json" --roadmap-status "$T/road-drift.json" --scoreboard "$T/sb-drift.txt" --matrix "$T/matrix.md" >/dev/null
[[ "$(wc -l < "$T/shadow/board.log" | tr -d ' ')" == "1" ]] && grep -q 'already delivered' "$T/err.txt" \
  && ok "second run in the same ISO week does not re-deliver" || bad "re-delivered within the week"
python3 "$WV" --repo "$T" --shadow-dir "$T/shadow" --ambient "$T/ambient.jsonl" --today 2026-08-14 \
  --mission-grade "$T/grade-f.json" --roadmap-status "$T/road-drift.json" --scoreboard "$T/sb-drift.txt" --matrix "$T/matrix.md" >/dev/null 2>&1
[[ "$(wc -l < "$T/shadow/board.log" | tr -d ' ')" == "2" ]] && grep -q '2026-W33' "$T/shadow/board.log" \
  && ok "the next ISO week delivers again" || bad "next week not delivered"
python3 -c "
import json
rows=[json.loads(l) for l in open('$T/ambient.jsonl')]
assert [r['week'] for r in rows]==['2026-W32','2026-W33'] and all(r['kind']=='weekly_verdict' and r['verdict']=='CHANGES' and r['items']==3 for r in rows), rows
" && ok "kind=weekly_verdict emitted to ambient (week, verdict, items, organs)" || bad "ambient event"

# ── 6. Synthesis only: the tool contains no detectors of its own ─────────────────────────
! grep -qE 'git (log|diff)|\bgh (pr|api)|sqlite3|requests\.|urllib' "$WV" \
  && ok "no new detection: no git/gh/sqlite/network calls in the composer" || bad "composer performs its own detection"

echo "=== weekly verdict: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
