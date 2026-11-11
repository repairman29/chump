#!/usr/bin/env bash
# INFRA-8072: junk-pr-closer classification + dry-run/protection behavior (fixture-driven, no GitHub).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAIL=0; chk() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }
cat > "$T/prs.json" <<'J'
[{"number":1,"title":"INFRA-1: EFFECTIVE: wire foo into curator role doc","head_ref":"a"},
 {"number":2,"title":"MISSION-009: Resilient pillar starved","head_ref":"b"},
 {"number":3,"title":"INFRA-3: real work","head_ref":"c"},
 {"number":4,"title":"INFRA-4: EFFECTIVE: wire bar into role doc","head_ref":"d"},
 {"number":5,"title":"INFRA-5: something","head_ref":"e"},
 {"number":6,"title":"INFRA-6: something else","head_ref":"f"}]
J
cat > "$T/gaps.json" <<'J'
[{"id":"INFRA-1","status":"superseded","outcome_id":null},
 {"id":"INFRA-3","status":"open","outcome_id":"OUT-1"},
 {"id":"INFRA-4","status":"open","outcome_id":"OUT-2"},
 {"id":"INFRA-5","status":"already_satisfied","outcome_id":null},
 {"id":"INFRA-6","status":"open","outcome_id":null}]
J
export CHUMP_JUNK_PR_FIXTURE="$T/prs.json" CHUMP_JUNK_GAP_FIXTURE="$T/gaps.json" CHUMP_AMBIENT_LOG="$T/amb.jsonl" CHUMP_JUNK_PR_REPO=x/y
OUT="$(bash "$ROOT/scripts/coord/junk-pr-closer.sh" --dry-run 2>&1)"
chk "doc-wiring/superseded PR #1 flagged" 'grep -q "would close #1" <<<"$OUT"'
chk "pillar-starved PR #2 flagged" 'grep -q "would close #2" <<<"$OUT"'
chk "gap already_satisfied PR #5 flagged" 'grep -q "would close #5" <<<"$OUT"'
chk "outcome-linked live gap PR #4 protected despite junk title" '! grep -q "#4" <<<"$OUT"'
chk "real work PR #3 not flagged" '! grep -q "would close #3" <<<"$OUT"'
chk "unrelated PR #6 not flagged" '! grep -q "would close #6" <<<"$OUT"'
chk "count emitted (3 of 6)" 'grep -q "\"kind\":\"junk_pr_closer_scan\",\"candidates\":3,\"open_prs\":6" "$T/amb.jsonl"'
chk "dry-run closes nothing" '! grep -q junk_pr_closed "$T/amb.jsonl"'
exit $FAIL
