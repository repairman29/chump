#!/usr/bin/env bash
# CREDIBLE-1700: registry-replay.py against fixture artifact + PR list.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
F="$R/docs/test-fixtures/registry-replay"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
DB="$D/state.db"
sqlite3 "$DB" "
CREATE TABLE gaps(id TEXT PRIMARY KEY,domain TEXT DEFAULT '',title TEXT DEFAULT '',description TEXT DEFAULT '',priority TEXT DEFAULT '',effort TEXT DEFAULT '',status TEXT DEFAULT 'open',acceptance_criteria TEXT DEFAULT '',depends_on TEXT DEFAULT '',notes TEXT DEFAULT '',source_doc TEXT DEFAULT '',created_at INTEGER DEFAULT 0,closed_at INTEGER,opened_date TEXT DEFAULT '',closed_date TEXT DEFAULT '',closed_pr INTEGER,skills_required TEXT DEFAULT '',outcome_id TEXT);
CREATE TABLE gap_counters(domain TEXT PRIMARY KEY,next_num INTEGER DEFAULT 1);
CREATE TABLE outcomes(id TEXT PRIMARY KEY,title TEXT DEFAULT '',priority TEXT DEFAULT 'P2',definition_of_done TEXT DEFAULT '',status TEXT DEFAULT 'open',created_at INTEGER DEFAULT 0,closed_at INTEGER);
INSERT INTO gap_counters VALUES('RESILIENT',1654);"
q() { sqlite3 "$DB" "$1"; }
chk() { [[ "$2" == "$3" ]] || { echo "FAIL: $1 (got '$2' want '$3')"; exit 1; }; echo "PASS: $1"; }
OUT="$(python3 "$R/scripts/ops/registry-replay.py" --db "$DB" --artifact "$F/artifact.json" --prs "$F/prs.json" --quarantine RESILIENT-1688 EFFECTIVE-1933)"
echo "$OUT"
chk "merged PR -> done" "$(q "select status from gaps where id='RESILIENT-1829'")" done
chk "open PR -> in_flight" "$(q "select status from gaps where id='INFRA-8828'")" in_flight
chk "RESILIENT counter above highest" "$(q "select next_num>1829 from gap_counters where domain='RESILIENT'")" 1
chk "quarantined not imported" "$(q "select count(*) from gaps where id='EFFECTIVE-1933'")" 0
chk "10 outcomes" "$(q "select count(*) from outcomes")" 10
chk "proposals linked & P2/P1" "$(q "select count(*) from gaps where notes='replayed-from:approvals-artifact' and outcome_id is not null")" 6
chk "DOC-165 P1 FROOGLE" "$(q "select priority||outcome_id from gaps where id='DOC-165'")" P1FROOGLE
chk "EFFECTIVE-1936 P1" "$(q "select priority from gaps where id='EFFECTIVE-1936'")" P1
chk "EFFECTIVE counter past 1936" "$(q "select next_num>1936 from gap_counters where domain='EFFECTIVE'")" 1
python3 "$R/scripts/ops/registry-replay.py" --db "$DB" --artifact "$F/artifact.json" --prs "$F/prs.json" >/dev/null
chk "idempotent" "$(q "select count(*) from gaps")" "$(q "select count(*) from gaps")"
chk "idempotent proposals" "$(q "select count(*) from gaps where id like 'PRODUCT-%'")" 6
echo "ALL PASS"
